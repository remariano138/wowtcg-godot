class_name StackResolver
extends RefCounted

# Priority and chain (interrupt stack) management — rule 410.
#
# Entry points (called by both Human input and AI — same API for both):
#   submit_action(state, action, db) — propose an action; pushes to chain if legal
#   pass_priority(state, db)         — pass; resolves top of chain when all pass
#
# Architecture invariants (same as GameLogic primitives):
#   - Never touches Godot nodes or the event bus
#   - Returns Array[GameEvent]; caller emits
#   - All state mutations go through GameLogic primitives where possible
#
# Rule 410 summary implemented here:
#   - Proposer KEEPS priority after adding to chain (410.1).
#   - All players pass in succession → topmost link resolves → turn player
#     gets priority in a new window (410.4a).
#   - Chain empty + all pass → window closes, phase advances (410.4b).
#   - PPP (pre-priority processing, 410.5-410.6) is stubbed — will be
#     filled in when we implement fatal-damage destruction, uniqueness
#     checks, etc.


# ── Entry points ───────────────────────────────────────────────────────────────

static func submit_action(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	if not can_submit(state, action, db):
		return []

	var events: Array[GameEvent] = []

	# Rule 409.1 / 412.1a: card moves from hand to chain on submission.
	# Resource costs are paid at submission time (before chain), not at resolution.
	match action.action_type:
		"play_ally", "play_instant", "play_ability":
			var card_id: String = action.params.get("card_id", "")
			if card_id != "":
				events.append_array(GameLogic.move_card(state, card_id, "chain"))
				events.append_array(_pay_cost(state, card_id, action.source_player, db))
		"place_resource":
			var card_id: String = action.params.get("card_id", "")
			if card_id != "":
				events.append_array(GameLogic.move_card(state, card_id, "chain"))
			var ps := state.players.get(action.source_player) as PlayerState
			if ps:
				ps.resource_placed_this_turn = true
		"use_quest":
			# Pay the quest's resource cost from the player's resource row.
			# The quest itself does NOT exhaust — it flips face-down on resolution.
			var quest_id: String = action.params.get("quest_id", "")
			if quest_id != "" and db:
				var q_card := state.get_card(quest_id)
				if q_card:
					var def := db.get_def(q_card.card_def_id) as CardDef
					if def:
						events.append_array(_pay_resources(state, action.source_player, max(def.cost, 0) as int))
		"use_ally_power":
			# Pay the ally power's resource cost at submission time, same as play_ally.
			var ap_card_id: String = action.params.get("card_id", "")
			if ap_card_id != "" and db:
				var ap_card := state.get_card(ap_card_id)
				var ap_def  := db.get_def(ap_card.card_def_id) as CardDef if ap_card else null
				var ap_data := _ally_activated_power(ap_def) if ap_def else {}
				var ap_cost := int(ap_data.get("resource_cost", 0))
				if ap_cost > 0:
					events.append_array(_pay_resources(state, action.source_player, ap_cost))
		"activate_power":
			# Pay the hero power's resource cost; mark power as used.
			var hero_id: String = action.params.get("hero_id", "")
			if hero_id != "" and db:
				var h_card := state.get_card(hero_id)
				if h_card:
					var def := db.get_def(h_card.card_def_id) as CardDef
					if def and def.cost > 0:
						events.append_array(_pay_resources(state, action.source_player, def.cost))
			var ps := state.players.get(action.source_player) as PlayerState
			if ps:
				ps.has_used_hero_power = true
			events.append(GameEvent.hero_power_used(action.source_player, hero_id))

	state.pending_actions.push_back(action)
	state.consecutive_passes = 0
	# Rule 410.1: proposer keeps priority (NOT flipped to opponent).

	var proposed_payload := {
		"action_type": action.action_type,
		"player":      action.source_player,
		"card_id":     action.params.get("card_id", ""),
		"face_up":     action.params.get("face_up", true),
		"attacker_id": action.params.get("attacker_id", ""),
		"defender_id": action.params.get("defender_id", ""),
	}
	events.append(GameEvent.make("action_proposed", proposed_payload))
	return events


static func pass_priority(state: GameState, db = null) -> Array[GameEvent]:
	state.consecutive_passes += 1
	var events: Array[GameEvent] = []

	# All players passed in succession.
	if state.consecutive_passes >= 2:
		if state.pending_actions.is_empty():
			# Safety: can't close the window while an enters-play effect needs a target.
			if not state.pending_enter_play_effect.is_empty():
				state.consecutive_passes = 0
				state.priority_player    = state.turn_player
				return []   # stall — scene must handle enter_play_target_required
			# Rule 410.4b: chain empty → window closes, phase advances.
			state.consecutive_passes = 0
			state.priority_player    = state.turn_player
			events.append(GameEvent.make("priority_window_closed", {
				"phase": state.phase,
			}))
			return events

		# Rule 410.4a: topmost link resolves; turn player gets priority.
		var top: PendingAction = state.pending_actions.pop_back()
		state.consecutive_passes = 0
		# PPP stub: in a future phase, run pre-priority checks (410.5) here
		# before the turn player gets priority post-resolution.
		events.append_array(_resolve(state, top, db))
		state.priority_player = state.turn_player
		return events

	# Not yet all passed — pass priority clockwise (2-player: flip).
	state.priority_player = _other_player(state, state.priority_player)
	events.append(GameEvent.make("priority_passed", {
		"player": state.priority_player,
	}))
	return events


# ── Validation ─────────────────────────────────────────────────────────────────

static func can_submit(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Must be the acting player's priority.
	if action.source_player != state.priority_player:
		return false

	# Pending enters-play target choice blocks everything except resolving it.
	if not state.pending_enter_play_effect.is_empty() \
			and action.action_type != "choose_enter_play_target":
		return false

	match action.action_type:
		"play_ally":
			return _can_play_non_instant(state, action, db)
		"play_ability":
			return _can_play_ability(state, action, db)
		"play_instant":
			return _can_play_instant(state, action, db)
		"place_resource":
			return _can_place_resource(state, action, db)
		"propose_combat":
			return _can_propose_combat(state, action, db)
		"use_quest":
			return _can_use_quest(state, action, db)
		"activate_power":
			return _can_activate_power(state, action, db)
		"use_ally_power":
			return _can_use_ally_power(state, action, db)
		"choose_enter_play_target":
			return _can_choose_enter_play_target(state, action, db)

	return false   # unknown action type


static func _can_play_non_instant(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Rule 409.1: non-instants require the turn player's action phase, chain empty.
	if state.phase != "action":
		return false
	if state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	# Card must actually be an Ally — Abilities and Instants have their own action types.
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and def.card_type != "Ally":
			return false
	# Rule 412.2: player must be able to afford the cost.
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(action.source_player):
		return false
	return true


static func _can_play_instant(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Instants can be played any time you have priority (409.1 / 410.2).
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(action.source_player):
		return false
	# Validate target for targeted effects.
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and _instant_needs_target(def):
			var target_id: String = action.params.get("target_id", "")
			if target_id == "" or not state.is_in_play(target_id):
				return false
			if _instant_targets_ally_only(def):
				var t_zone := state.zones.get(state.get_card(target_id).zone_id) as Zone
				if not t_zone or t_zone.zone_type != "ally_row":
					return false
	return true


# Non-instant ability (e.g. Vanquish): action-phase timing like an ally, effect+graveyard
# resolution like an instant.
static func _can_play_ability(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card: return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand": return false
	if card.controller != action.source_player: return false
	if state.phase != "action": return false
	if state.turn_player != action.source_player: return false
	if not state.pending_actions.is_empty(): return false
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(action.source_player):
		return false
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and _instant_needs_target(def):
			var target_id: String = action.params.get("target_id", "")
			if target_id == "" or not state.is_in_play(target_id): return false
			if _instant_targets_ally_only(def):
				var t_card := state.get_card(target_id)
				if t_card:
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "ally_row": return false
	return true


# Timing-only check (no target required). Used by the renderer to decide whether to
# highlight the card green in hand before the player has chosen a target.
static func can_play_ability_no_target_check(state: GameState,
		card_id: String, player_id: String, db) -> bool:
	var card := state.get_card(card_id)
	if not card: return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand": return false
	if card.controller != player_id: return false
	if state.phase != "action": return false
	if state.turn_player != player_id: return false
	if not state.pending_actions.is_empty(): return false
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(player_id):
		return false
	return true


static func _instant_needs_target(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["destroy_target"]:
			return true
	return false


static func _instant_targets_ally_only(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "destroy_target" and parts.size() > 1 and parts[1] == "ally":
			return true
	return false


static func _can_place_resource(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Rule 412.1a: turn player's action phase only, chain empty.
	if state.phase != "action":
		return false
	if state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	# Rule 412.1: once per turn.
	var ps := state.players.get(action.source_player) as PlayerState
	if ps and ps.resource_placed_this_turn:
		return false
	# Face-up placement (quests/locations only — rule 412.1b).
	var face_up: bool = action.params.get("face_up", false)
	if face_up and db:
		var def: CardDef = db.get_def(card.card_def_id)
		if def and def.card_type != "Quest" and def.card_type != "Location":
			return false
	return true


# ── Resolution ─────────────────────────────────────────────────────────────────

static func _resolve(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	match action.action_type:
		"play_ally":
			return _resolve_play_ally(state, action, db)
		"play_ability":
			return _resolve_play_instant(state, action, db)   # same: apply effect → graveyard
		"play_instant":
			return _resolve_play_instant(state, action, db)
		"place_resource":
			return _resolve_place_resource(state, action)
		"propose_combat":
			return _resolve_propose_combat(state, action, db)
		"use_quest":
			return _resolve_use_quest(state, action, db)
		"activate_power":
			return _resolve_activate_power(state, action, db)
		"use_ally_power":
			return _resolve_use_ally_power(state, action, db)
		"choose_enter_play_target":
			return _resolve_choose_enter_play_target(state, action, db)

	# Unknown action type — should not happen if can_submit gate is correct.
	return [GameEvent.make("action_fizzled", {
		"action_type": action.action_type,
		"reason":      "unknown_action_type",
	})]


static func _resolve_play_ally(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)

	# Re-validate: card must still be in the chain zone.
	# If it was interrupted/removed, it fizzles and goes to graveyard (rule 711.1).
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "play_ally", "reason": "card_not_found",
		})]
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "chain":
		var events: Array[GameEvent] = []
		events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_ally", "reason": "card_left_chain",
		}))
		if zone and zone.zone_type != "graveyard":
			events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
		return events

	var events: Array[GameEvent] = []
	var target_zone_id: String = card.controller + "_ally_row"
	events.append_array(GameLogic.move_card(state, card_id, target_zone_id))
	card.just_summoned = true

	# Check for on_enter triggered effects.
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and def.effects != "":
			for entry in def.effects.split("|"):
				var parts := entry.strip_edges().split(":")
				if parts.is_empty() or parts[0].strip_edges() != "on_enter":
					continue
				var effect_key := parts[1].strip_edges() if parts.size() > 1 else ""
				match effect_key:
					"draw":
						var n := int(parts[2]) if parts.size() > 2 else 1
						for _i in n:
							events.append_array(_draw_one(state, card.controller))
					"deal_damage_to_target":
						var amount := int(parts[2]) if parts.size() > 2 else 0
						var dmg_type := parts[3].to_lower().strip_edges() if parts.size() > 3 else ""
						state.pending_enter_play_effect = {
							"card_id": card_id,
							"effect": "deal_damage_to_target:%d:%s" % [amount, dmg_type],
							"dmg_type": dmg_type,
							"amount": amount,
						}
						events.append(GameEvent.enter_play_target_required(
							card_id, dmg_type, amount))

	return events


static func _resolve_play_instant(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id:   String = action.params.get("card_id",   "")
	var target_id: String = action.params.get("target_id", "")
	var events: Array[GameEvent] = []
	events.append(GameEvent.make("instant_resolved", {
		"card_id": card_id, "player": action.source_player,
	}))
	# Dispatch effects from the card definition.
	if db:
		var card := state.get_card(card_id)
		var def  := db.get_def(card.card_def_id) as CardDef if card else null
		if def and def.effects != "":
			for entry in def.effects.split("|"):
				var parts := entry.strip_edges().split(":")
				match parts[0].strip_edges():
					"destroy_target":
						if target_id != "" and state.is_in_play(target_id):
							events.append_array(
								_destroy_card_trigger(state, target_id, card_id, db))
	# Move used instant to its owner's graveyard (card is currently in chain zone).
	var card2 := state.get_card(card_id)
	if card2:
		events.append_array(GameLogic.move_card(state, card_id, card2.owner + "_graveyard"))
	return events


static func _resolve_place_resource(state: GameState,
		action: PendingAction) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var face_up: bool   = action.params.get("face_up", false)
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "place_resource", "reason": "card_not_found",
		})]
	var events: Array[GameEvent] = []
	card.face_down = not face_up
	events.append_array(GameLogic.move_card(state, card_id, card.controller + "_resource_row"))
	events.append(GameEvent.make("resource_placed", {
		"card_id": card_id, "player": card.controller, "face_up": face_up,
	}))
	return events


# Exhaust resources to pay a card's play cost (rule 412.2).
# Auto-selects ready resources; face-up/face-down both valid.
static func _pay_cost(state: GameState, card_id: String,
		player_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var cost: int = state.get_play_cost(card_id, db)
	if cost <= 0:
		return []
	var events: Array[GameEvent] = []
	for res_card in state.cards_in_zone(player_id + "_resource_row"):
		if cost <= 0:
			break
		if not res_card.is_exhausted:
			events.append_array(GameLogic.exhaust_card(state, res_card.instance_id))
			cost -= 1
	return events


# Pay an arbitrary resource cost (used for activated powers whose cost isn't the card's play cost).
static func _pay_resource_cost(state: GameState, player_id: String,
		amount: int) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var remaining := amount
	for res_card in state.cards_in_zone(player_id + "_resource_row"):
		if remaining <= 0:
			break
		if not res_card.is_exhausted:
			events.append_array(GameLogic.exhaust_card(state, res_card.instance_id))
			remaining -= 1
	return events


# Parse the first "activated_power" segment from a CardDef's effects string.
# Returns {} if none found.
static func _ally_activated_power(def: CardDef) -> Dictionary:
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "activated_power":
			return {
				"resource_cost": int(parts[1]) if parts.size() > 1 else 0,
				"effect":        parts[2] if parts.size() > 2 else "",
				"amount":        int(parts[3]) if parts.size() > 3 else 0,
				"dmg_type":      parts[4] if parts.size() > 4 else "",
				"targets":       parts[5] if parts.size() > 5 else "",
			}
	return {}


# ── Ally activated power — validation ─────────────────────────────────────────

static func _can_use_ally_power(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Only on action phase, priority player's turn, empty chain.
	if state.priority_player != action.source_player:
		return false
	if state.phase != "action" or state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card or card.controller != action.source_player:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "ally_row":
		return false
	# Rule 701.3: summoning sickness applies to activated powers for allies.
	if card.just_summoned:
		return false
	if card.is_exhausted:
		return false
	if not db:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return false
	var ap := _ally_activated_power(def)
	if ap.is_empty():
		return false
	if state.get_available_resources(action.source_player) < int(ap.get("resource_cost", 0)):
		return false
	# Targeted effects require a valid in-play target.
	if ap.get("targets", "") in ["hero_or_ally"]:
		var target_id: String = action.params.get("target_id", "")
		if target_id == "" or not state.is_in_play(target_id):
			return false
	return true


# ── Ally activated power — resolution ─────────────────────────────────────────

static func _resolve_use_ally_power(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled",
			{"action_type": "use_ally_power", "reason": "card_not_found"})]
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return []
	var ap := _ally_activated_power(def)
	if ap.is_empty():
		return []

	var events: Array[GameEvent] = []
	# Resource cost already paid at submission time (in submit_action).
	# Just exhaust the ally at resolution (the activate symbol).
	events.append_array(GameLogic.exhaust_card(state, card_id))
	events.append(GameEvent.make("ally_power_used",
		{"ally_id": card_id, "player": action.source_player}))

	match ap.get("effect", ""):
		"deal_damage_aoe":
			var amount: int = int(ap.get("amount", 0))
			var opp := _other_player(state, card.controller)
			var targets: Array[String] = []
			var opp_ps := state.players.get(opp) as PlayerState
			if opp_ps and opp_ps.hero_instance_id != "":
				targets.append(opp_ps.hero_instance_id)
			for ally in state.cards_in_zone(opp + "_ally_row"):
				targets.append(ally.instance_id)
			for t_id in targets:
				events.append_array(GameLogic.deal_damage(state, card_id, t_id, amount, db))
				var t_card := state.get_card(t_id)
				if t_card and state.get_current_hp(t_id, db) <= 0:
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if t_zone and t_zone.zone_type == "hero_row":
						events.append(GameEvent.game_over(
							_other_player(state, t_card.controller), t_card.controller))
					else:
						events.append_array(_check_destroyed_trigger(state, t_id, card_id, db))
		"heal_target":
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			if target_id != "" and state.is_in_play(target_id):
				events.append_array(GameLogic.heal(state, target_id, amount, db))

	return events


# ── Combat — validation ────────────────────────────────────────────────────────

static func _can_propose_combat(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Rule 601.1: action phase only, chain empty, turn player.
	if state.phase != "action":
		return false
	if state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	var attacker_id: String = action.params.get("attacker_id", "")
	var defender_id: String = action.params.get("defender_id", "")
	var attacker := state.get_card(attacker_id)
	var defender := state.get_card(defender_id)
	if not attacker or not defender:
		return false
	# Attacker must be controlled by the acting player.
	if attacker.controller != action.source_player:
		return false
	# Attacker must be in play (ally_row or hero_row).
	if not state.is_in_play(attacker_id):
		return false
	# Rule 601.2a: attacker must be ready.
	if attacker.is_exhausted:
		return false
	# Rule 601.2a / 302.2: ally summoning sickness (heroes immune per 301.3).
	var att_zone := state.zones.get(attacker.zone_id) as Zone
	if att_zone and att_zone.zone_type == "ally_row":
		if attacker.just_summoned and not _has_keyword(attacker, "ferocity", db):
			return false
	# Defender must be controlled by the opponent.
	if defender.controller == action.source_player:
		return false
	# Defender must be in play.
	if not state.is_in_play(defender_id):
		return false
	# Rule 601.2b: defender must not be Elusive.
	if _has_keyword(defender, "elusive", db):
		return false
	return true


# ── Combat — query helpers (called by AI and InputRouter) ─────────────────────

# Returns instance_ids of all legal attackers the player can propose right now.
# Does NOT check phase/chain — callers apply that context.
static func get_legal_attackers(state: GameState, player_id: String, db) -> Array[String]:
	var result: Array[String] = []
	# Hero (rule 301.3: no summoning sickness; still must be ready per 601.2a).
	# Also require ATK > 0 — a 0 ATK hero with no weapon deals no damage and
	# exhausts for nothing; treat as not a legal attacker (practical gate, not
	# an explicit rule, but avoids pointless/confusing highlights and AI plays).
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.hero_instance_id != "":
		var hero := state.get_card(ps.hero_instance_id)
		if hero and not hero.is_exhausted and state.get_atk(hero.instance_id, db) > 0:
			result.append(hero.instance_id)
	# Allies (rule 302.2: just_summoned unless Ferocity).
	for card in state.cards_in_zone(player_id + "_ally_row"):
		if card.is_exhausted:
			continue
		if card.just_summoned and not _has_keyword(card, "ferocity", db):
			continue
		result.append(card.instance_id)
	return result


# Returns instance_ids of all legal defenders the given attacker can target.
static func get_legal_defenders(state: GameState, attacker_id: String, db) -> Array[String]:
	var attacker := state.get_card(attacker_id)
	if not attacker:
		return []
	var opp := _other_player(state, attacker.controller)
	var result: Array[String] = []
	for card in state.cards_in_zone(opp + "_ally_row"):
		if not _has_keyword(card, "elusive", db):
			result.append(card.instance_id)
	var ps := state.players.get(opp) as PlayerState
	if ps and ps.hero_instance_id != "":
		var hero := state.get_card(ps.hero_instance_id)
		if hero and not _has_keyword(hero, "elusive", db):
			result.append(hero.instance_id)
	return result


# Returns instance_ids of all characters that can protect this combat (rule 602.2).
# The defending player chooses whether to use one of these — it is NOT mandatory.
static func get_legal_protectors(state: GameState, attacker_id: String,
		defender_id: String, db) -> Array[String]:
	var defender := state.get_card(defender_id)
	if not defender:
		return []
	var defending_player := defender.controller
	var result: Array[String] = []
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(defending_player + zone_suffix):
			if card.instance_id == defender_id:
				continue  # 602.2b: a proposed defender can't protect itself
			if card.is_exhausted:
				continue  # must be ready (will be exhausted when it protects)
			if _has_keyword(card, "protector", db):
				result.append(card.instance_id)
	return result


static func _has_keyword(card: CardInstance, keyword: String, db) -> bool:
	if keyword in card.granted_keywords:
		return true
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and keyword in def.keywords:
			return true
	return false


# ── Combat — resolution ────────────────────────────────────────────────────────

static func _resolve_propose_combat(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var attacker_id: String = action.params.get("attacker_id", "")
	var defender_id: String = action.params.get("defender_id", "")
	var attacker := state.get_card(attacker_id)
	var defender := state.get_card(defender_id)

	# Rule 601.3: recheck legality as proposal resolves.
	# If either combatant is gone or now illegal, proposal fizzles — NO exhaust.
	if not attacker or not defender \
			or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id) \
			or attacker.is_exhausted \
			or _has_keyword(defender, "elusive", db):
		return [GameEvent.make("action_fizzled", {
			"action_type": "propose_combat", "reason": "illegal_at_resolution",
		})]

	# Rule 602.1: combat step starts — attacker exhausts now.
	var events: Array[GameEvent] = []
	state.combat_attacker = attacker_id
	state.combat_defender = defender_id
	events.append_array(GameLogic.exhaust_card(state, attacker_id))
	events.append(GameEvent.combat_started(attacker_id, defender_id))

	# Rule 602.2: protect point — any ready Protector controlled by defending player
	# may be exhausted to intercept. The defending player chooses, or skips.
	var protectors := get_legal_protectors(state, attacker_id, defender_id, db)
	if protectors.is_empty():
		# No protectors available: proceed directly to conclusion.
		events.append_array(_do_combat_conclusion(state, db))
	else:
		state.in_protect_point = true
		events.append(GameEvent.protect_point_opened(attacker_id, defender_id, protectors))
	return events


# Entry point for the protect-point decision (NOT chain-based — called directly
# by the scene after the defending player makes their choice).
# protector_id == "" means the defending player chose to skip protection.
static func choose_protector(state: GameState, protector_id: String,
		db = null) -> Array[GameEvent]:
	if not state.in_protect_point:
		return []
	state.in_protect_point = false

	var events: Array[GameEvent] = []
	var defender := state.get_card(state.combat_defender)
	var defending_player := defender.controller if defender else ""

	if protector_id != "" and state.is_in_play(protector_id):
		# Rule 602.2: exhaust the protector; it becomes the new defender.
		events.append_array(GameLogic.exhaust_card(state, protector_id))
		state.combat_defender = protector_id
		events.append(GameEvent.protect_chosen(protector_id, defending_player))
	else:
		events.append(GameEvent.protect_chosen("", defending_player))

	events.append_array(_do_combat_conclusion(state, db))
	return events


# Rule 603: simultaneous damage + PPP + win check.
static func _do_combat_conclusion(state: GameState, db = null) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	state.combat_attacker = ""
	state.combat_defender = ""

	var attacker := state.get_card(attacker_id) if attacker_id != "" else null
	var defender := state.get_card(defender_id) if defender_id != "" else null

	# Rule 603.1b: if either side is gone, no damage.
	if not attacker or not defender \
			or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id):
		events.append(GameEvent.combat_concluded(attacker_id, defender_id, 0, 0))
		return events

	# Rule 603.1: both deal damage simultaneously.
	# Capture ATK values BEFORE applying any damage to either side.
	var atk_dmg := state.get_atk(attacker_id, db)   # to defender
	var def_dmg := state.get_atk(defender_id, db)   # to attacker (0 for heroes, per 205.1)
	events.append(GameEvent.combat_concluded(attacker_id, defender_id, atk_dmg, def_dmg))

	# Apply both damage packets first (deal_damage no longer auto-destroys),
	# then check fatalities on both after — true simultaneity.
	events.append_array(GameLogic.deal_damage(state, attacker_id, defender_id, atk_dmg, db))
	events.append_array(GameLogic.deal_damage(state, defender_id, attacker_id, def_dmg, db))

	# PPP: state-based destruction check after both packets have landed.
	for cid in [defender_id, attacker_id]:
		var card := state.get_card(cid)
		if not card or not state.is_in_play(cid):
			continue
		if state.get_current_hp(cid, db) > 0:
			continue
		var zone := state.zones.get(card.zone_id) as Zone
		if zone and zone.zone_type == "hero_row":
			events.append(GameEvent.game_over(
				_other_player(state, card.controller), card.controller))
		else:
			events.append_array(_check_destroyed_trigger(state, cid, attacker_id, db))

	return events


# ── Quest completion ───────────────────────────────────────────────────────────

static func _can_use_quest(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Quest completion is an activated power — usable any time player has priority.
	if action.source_player != state.priority_player:
		return false
	var quest_id: String = action.params.get("quest_id", "")
	var card := state.get_card(quest_id)
	if not card or card.controller != action.source_player:
		return false
	# Must be a face-up (not yet completed) quest in the resource row.
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "resource_row":
		return false
	if card.face_down:
		return false
	if not db:
		return true
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.card_type != "Quest":
		return false
	# Check additional resource cost (e.g. "Pay 1" on A Donation of Wool).
	var resource_cost: int = max(def.cost, 0)
	if resource_cost > state.get_available_resources(action.source_player):
		return false
	return true


static func _resolve_use_quest(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var quest_id: String = action.params.get("quest_id", "")
	var card := state.get_card(quest_id)
	if not card or card.face_down:
		return [GameEvent.make("action_fizzled", {
			"action_type": "use_quest", "reason": "quest_already_used",
		})]

	var events: Array[GameEvent] = []

	# Flip the quest face-down — it becomes a blank resource (no longer completable).
	card.face_down = true
	events.append(GameEvent.make("quest_completed", {
		"quest_id": quest_id,
		"player":   action.source_player,
	}))

	# Apply effects from the CardDef's effects string.
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def:
			events.append_array(_apply_quest_reward(state, action.source_player, def.effects, db))

	return events


# Parse and execute a quest reward string. Format: "key:value" entries, pipe-separated.
# Effects that require player input (discard_from_hand) set pending state and emit
# a choice event; the caller must handle that event before continuing.
static func _apply_quest_reward(state: GameState, player_id: String,
		effects_str: String, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if effects_str == "":
		return events
	for entry in effects_str.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() < 2:
			continue
		match parts[0].strip_edges():
			"draw":
				var n := int(parts[1])
				for _i in n:
					events.append_array(_draw_one(state, player_id))
			"discard_from_hand":
				var n := int(parts[1])
				state.pending_discard_player = player_id
				state.pending_discard_count  = n
				events.append(GameEvent.discard_choice_opened(player_id, n))
	return events


# Entry point: player (or AI) has chosen a card to discard.
static func choose_discard(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_discard_count <= 0 or state.pending_discard_player == "":
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return []
	if card.controller != state.pending_discard_player:
		return []

	var events: Array[GameEvent] = []
	events.append_array(GameLogic.discard_card(state, card_id))
	state.pending_discard_count -= 1
	if state.pending_discard_count <= 0:
		state.pending_discard_player = ""
		state.pending_discard_count  = 0
	else:
		# More discards still needed — reopen choice.
		events.append(GameEvent.discard_choice_opened(
			state.pending_discard_player, state.pending_discard_count))
	return events


static func _draw_one(state: GameState, player_id: String) -> Array[GameEvent]:
	var deck := state.zones.get(player_id + "_deck") as Zone
	if not deck or deck.card_ids.is_empty():
		return [GameEvent.make("deck_empty", {"player": player_id})]
	return GameLogic.move_card(state, deck.card_ids[0], player_id + "_hand")


# Exhaust N ready resources for a player (generic cost payment without a card reference).
static func _pay_resources(state: GameState, player_id: String,
		cost: int) -> Array[GameEvent]:
	if cost <= 0:
		return []
	var events: Array[GameEvent] = []
	for res_card in state.cards_in_zone(player_id + "_resource_row"):
		if cost <= 0:
			break
		if not res_card.is_exhausted:
			events.append_array(GameLogic.exhaust_card(state, res_card.instance_id))
			cost -= 1
	return events


# ── Retract ────────────────────────────────────────────────────────────────────

# Cancel the last chain entry — only legal while the proposer still has priority
# and has not yet passed (consecutive_passes == 0).  Returns [] if not retractable.
static func can_retract(state: GameState, player_id: String) -> bool:
	if state.pending_actions.is_empty():
		return false
	if state.priority_player != player_id:
		return false
	if state.consecutive_passes != 0:
		return false
	var top: PendingAction = state.pending_actions.back()
	return top.source_player == player_id


static func retract_last(state: GameState, player_id: String,
		db = null) -> Array[GameEvent]:
	if not can_retract(state, player_id):
		return []

	var top: PendingAction = state.pending_actions.pop_back()
	var events: Array[GameEvent] = []

	# Move card back from chain zone to player's hand.
	var card_id: String = top.params.get("card_id", "")
	if card_id != "":
		events.append_array(GameLogic.move_card(state, card_id, player_id + "_hand"))

	# Refund resources exhausted at submission time (rule 412.2 costs are paid on
	# chain entry, so retraction must undo them — mirrors _pay_cost exactly).
	if top.action_type == "use_ally_power" and db:
		var ap_card_id2: String = top.params.get("card_id", "")
		if ap_card_id2 != "":
			var ap_card2 := state.get_card(ap_card_id2)
			var ap_def2  := db.get_def(ap_card2.card_def_id) as CardDef if ap_card2 else null
			var ap_data2 := _ally_activated_power(ap_def2) if ap_def2 else {}
			var ap_cost2 := int(ap_data2.get("resource_cost", 0))
			for res_card in state.cards_in_zone(player_id + "_resource_row"):
				if ap_cost2 <= 0:
					break
				if res_card.is_exhausted:
					events.append_array(GameLogic.ready_card(state, res_card.instance_id))
					ap_cost2 -= 1
	if top.action_type in ["play_ally", "play_instant", "play_ability"] and db and card_id != "":
		var cost: int = state.get_play_cost(card_id, db)
		for res_card in state.cards_in_zone(player_id + "_resource_row"):
			if cost <= 0:
				break
			if res_card.is_exhausted:
				events.append_array(GameLogic.ready_card(state, res_card.instance_id))
				cost -= 1

	# Undo resource_placed_this_turn flag if a place_resource was retracted.
	if top.action_type == "place_resource":
		var ps := state.players.get(player_id) as PlayerState
		if ps:
			ps.resource_placed_this_turn = false

	events.append(GameEvent.make("action_retracted", {
		"action_type": top.action_type,
		"player":      player_id,
	}))
	return events


# ── Hero power ─────────────────────────────────────────────────────────────────

static func _can_activate_power(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Hero powers are instants by default (rule 701.3) — usable any time player has priority.
	# Powers with "on_your_turn" in effects also require turn player + action phase + empty chain.
	if state.priority_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	var ps := state.players.get(action.source_player) as PlayerState
	if not ps or ps.has_used_hero_power:
		return false
	# Hero must be alive (in hero_row).
	var hero_id: String = action.params.get("hero_id", "")
	var hero := state.get_card(hero_id)
	if not hero or not state.is_in_play(hero_id):
		return false
	if not db:
		return true
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def or def.card_type != "Hero":
		return false
	# "on_your_turn" in effects = "Use only on your turn": action phase, turn player, chain empty.
	if _power_effect_is(def, "on_your_turn"):
		if state.phase != "action" or state.turn_player != action.source_player:
			return false
	# Must be able to afford the cost.
	var cost: int = max(def.cost, 0)
	if cost > state.get_available_resources(action.source_player):
		return false
	# If this power targets something, the target must be valid.
	var target_id: String = action.params.get("target_id", "")
	if target_id != "":
		if not state.is_in_play(target_id):
			return false
		# destroy_exhausted_ally: target must be an exhausted ally (not a hero).
		if _power_effect_is(def, "destroy_exhausted_ally"):
			var t_card := state.get_card(target_id)
			if not t_card or not t_card.is_exhausted:
				return false
			var t_zone := state.zones.get(t_card.zone_id) as Zone
			if not t_zone or t_zone.zone_type != "ally_row":
				return false
		if _power_effect_is(def, "deal_damage_and_heal"):
			# target_id = damage target, heal_target_id = heal target; both must be in play and different.
			var heal_target_id: String = action.params.get("heal_target_id", "")
			if heal_target_id == "" or not state.is_in_play(heal_target_id):
				return false
			if heal_target_id == target_id:
				return false
	return true


static func _power_effect_is(def: CardDef, effect_key: String) -> bool:
	for entry in def.effects.split("|"):
		if entry.strip_edges().split(":")[0].strip_edges() == effect_key:
			return true
	return false


static func _resolve_activate_power(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var hero_id:   String = action.params.get("hero_id",   "")
	var target_id: String = action.params.get("target_id", "")
	var hero := state.get_card(hero_id)
	if not hero or not db:
		return []
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def:
		return []

	var events: Array[GameEvent] = []
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.is_empty() or parts[0] == "":
			continue
		match parts[0].strip_edges():
			"deal_damage_to_target":
				# Format: deal_damage_to_target:AMOUNT:DMG_TYPE
				if target_id == "":
					continue
				var amount := int(parts[1]) if parts.size() > 1 else 0
				events.append_array(GameLogic.deal_damage(
					state, hero_id, target_id, amount, db))
				# Destruction check immediately (not simultaneous — it's a spell).
				var t_card := state.get_card(target_id)
				if t_card and state.get_current_hp(target_id, db) <= 0:
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if t_zone and t_zone.zone_type == "hero_row":
						events.append(GameEvent.game_over(
							_other_player(state, t_card.controller), t_card.controller))
					else:
						events.append_array(
							_check_destroyed_trigger(state, target_id, hero_id, db))
			"shuffle_hand_draw":
				events.append_array(
					GameLogic.shuffle_hand_into_deck_and_draw(state, action.source_player))
			"destroy_exhausted_ally":
				if target_id != "" and state.is_in_play(target_id):
					events.append_array(_destroy_card_trigger(state, target_id, hero_id, db))
			"deal_damage_and_heal":
				# Format: deal_damage_and_heal:DMG_AMOUNT:DMG_TYPE:HEAL_AMOUNT
				var dmg_amount  := int(parts[1]) if parts.size() > 1 else 0
				var heal_amount := int(parts[3]) if parts.size() > 3 else 0
				var heal_target_id: String = action.params.get("heal_target_id", "")
				if target_id != "":
					events.append_array(GameLogic.deal_damage(
						state, hero_id, target_id, dmg_amount, db))
					var t_card := state.get_card(target_id)
					if t_card and state.get_current_hp(target_id, db) <= 0:
						var t_zone := state.zones.get(t_card.zone_id) as Zone
						if t_zone and t_zone.zone_type == "hero_row":
							events.append(GameEvent.game_over(
								_other_player(state, t_card.controller), t_card.controller))
						else:
							events.append_array(
								_check_destroyed_trigger(state, target_id, hero_id, db))
				if heal_target_id != "" and state.is_in_play(heal_target_id):
					events.append_array(GameLogic.heal(state, heal_target_id, heal_amount, db))
	return events


# ── Enters-play targeted effect ────────────────────────────────────────────────

static func _can_choose_enter_play_target(state: GameState, action: PendingAction,
		_db = null) -> bool:
	if state.pending_enter_play_effect.is_empty():
		return false
	var source_id: String = action.params.get("source_card_id", "")
	if source_id != state.pending_enter_play_effect.get("card_id", ""):
		return false
	var source_card := state.get_card(source_id)
	if not source_card or source_card.controller != action.source_player:
		return false
	# Only one choose_enter_play_target can be on the chain at a time.
	for a in state.pending_actions:
		if (a as PendingAction).action_type == "choose_enter_play_target":
			return false
	var target_id: String = action.params.get("target_id", "")
	if target_id == "" or not state.is_in_play(target_id):
		return false
	return true


static func _resolve_choose_enter_play_target(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var source_id: String = action.params.get("source_card_id", "")
	var target_id: String = action.params.get("target_id", "")
	var effect_dict: Dictionary = state.pending_enter_play_effect
	state.pending_enter_play_effect = {}

	var events: Array[GameEvent] = []
	var effect_str: String = effect_dict.get("effect", "")
	var parts := effect_str.split(":")
	if parts.is_empty():
		return events
	match parts[0]:
		"deal_damage_to_target":
			var amount := int(parts[1]) if parts.size() > 1 else 0
			events.append_array(GameLogic.deal_damage(state, source_id, target_id, amount, db))
			var t_card := state.get_card(target_id)
			if t_card and state.get_current_hp(target_id, db) <= 0:
				var t_zone := state.zones.get(t_card.zone_id) as Zone
				if t_zone and t_zone.zone_type == "hero_row":
					events.append(GameEvent.game_over(
						_other_player(state, t_card.controller), t_card.controller))
				else:
					events.append_array(
						_check_destroyed_trigger(state, target_id, source_id, db))
	return events


# ── Helpers ────────────────────────────────────────────────────────────────────

static func _other_player(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id


# Fire any "on_destroyed" effects declared in the card's effects string.
# Called AFTER the card has already moved to the graveyard (rule 703.3c).
# Format: on_destroyed:deal_damage_aoe:AMOUNT:DMG_TYPE:opposing
static func _fire_on_destroyed(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.effects == "":
		return []

	var events: Array[GameEvent] = []
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] != "on_destroyed":
			continue
		if parts.size() < 2:
			continue
		match parts[1]:
			"deal_damage_aoe":
				# on_destroyed:deal_damage_aoe:AMOUNT:DMG_TYPE:opposing
				var amount := int(parts[2]) if parts.size() > 2 else 1
				var opp    := _other_player(state, card.controller)
				var targets: Array[String] = []
				var opp_ps := state.players.get(opp) as PlayerState
				if opp_ps and opp_ps.hero_instance_id != "":
					targets.append(opp_ps.hero_instance_id)
				for ally in state.cards_in_zone(opp + "_ally_row"):
					targets.append(ally.instance_id)
				for t_id in targets:
					events.append_array(GameLogic.deal_damage(state, card_id, t_id, amount, db))
					var t_card := state.get_card(t_id)
					if t_card and state.get_current_hp(t_id, db) <= 0:
						var t_zone := state.zones.get(t_card.zone_id) as Zone
						if t_zone and t_zone.zone_type == "hero_row":
							events.append(GameEvent.game_over(
								_other_player(state, t_card.controller), t_card.controller))
						else:
							# No recursive on_destroyed for AoE secondary kills.
							events.append_array(
								GameLogic.check_destroyed(state, t_id, card_id, db))
	return events


# Wrapper: check_destroyed + on_destroyed trigger if the card actually died.
static func _check_destroyed_trigger(state: GameState, card_id: String,
		source_id: String, db) -> Array[GameEvent]:
	var events := GameLogic.check_destroyed(state, card_id, source_id, db)
	for e in events:
		if e.event_type == "card_destroyed" and e.payload.get("card", "") == card_id:
			events.append_array(_fire_on_destroyed(state, card_id, db))
			break
	return events


# Wrapper: destroy_card always fires on_destroyed (explicit removal effect).
static func _destroy_card_trigger(state: GameState, card_id: String,
		source_id: String, db) -> Array[GameEvent]:
	var events := GameLogic.destroy_card(state, card_id, source_id)
	if not events.is_empty():
		events.append_array(_fire_on_destroyed(state, card_id, db))
	return events
