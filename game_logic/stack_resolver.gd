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
		"play_ally", "play_instant", "play_ability", "play_equipment":
			var card_id: String = action.params.get("card_id", "")
			if card_id != "":
				events.append_array(GameLogic.move_card(state, card_id, "chain"))
				events.append_array(_pay_cost(state, card_id, action.source_player, db))
				# Stat tracking: a card was played from hand (excludes resources,
				# which are a separate branch below). See StatTracker.
				events.append(GameEvent.card_played(action.source_player, card_id))
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
		"use_armor_prevention":
			# Cost is exhausting the armor — paid at submission (rule 304.3),
			# so the same armor can't be committed twice while on the chain.
			var armor_id: String = action.params.get("card_id", "")
			if armor_id != "":
				events.append_array(GameLogic.exhaust_card(state, armor_id))
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
					elif def and _power_effect_is(def, "heal_x_from_target"):
						var x_val: int = action.params.get("x_value", 0)
						if x_val > 0:
							events.append_array(_pay_resources(state, action.source_player, x_val))
					elif def and _power_effect_is(def, "radak_pet_sacrifice"):
						# Pay X resources and destroy the chosen Pet as costs.
						var pet_id: String = action.params.get("pet_id", "")
						var x_val: int = action.params.get("x_value", 0)
						if x_val > 0:
							events.append_array(_pay_resources(state, action.source_player, x_val))
						if pet_id != "" and state.is_in_play(pet_id):
							events.append_array(_destroy_card_trigger(state, pet_id, hero_id, db))
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
	# A pending discard-or-give-control choice (Infernal) must be resolved via
	# choose_control_discard / decline_control_discard before priority can move.
	if state.pending_control_discard_player != "":
		return []
	# A pending reveal-and-pick choice is mandatory — resolve it via
	# choose_reveal_pick() before priority can move.
	if state.pending_reveal_pick_player != "":
		return []
	# A pending strike decision (602.1 / 602.3) must be resolved via
	# choose_strike() before priority can move.
	if state.pending_strike_player != "":
		return []
	# A pending ready-on-attack decision (Windseer Tarus) must be resolved via
	# choose_ready_on_attack() before priority can move.
	if state.pending_ready_player != "":
		return []
	# A pending Totem start-of-turn target choice (Searing Totem) must be resolved
	# via choose_totem_target() before priority can move.
	if state.pending_totem_target_player != "":
		return []
	state.consecutive_passes += 1
	var events: Array[GameEvent] = []

	# All players passed in succession.
	if state.consecutive_passes >= 2:
		if state.pending_actions.is_empty():
			# Safety: can't close the window while an enters-play effect needs a target.
			if not state.pending_enter_play_effect.is_empty():
				state.consecutive_passes = 0
				state.priority_player    = _pending_effect_controller(state)
				return []   # stall — scene must handle enter_play_target_required
			# Rule 602.1/602.3: combat window transitions take priority over phase advance.
			state.consecutive_passes = 0
			state.priority_player    = state.turn_player
			if state.combat_attack_window:
				state.combat_attack_window = false
				events.append_array(_close_attack_window(state, db))
				return events
			if state.combat_defend_window:
				state.combat_defend_window = false
				events.append_array(_do_combat_conclusion(state, db))
				return events
			# Rule 410.4b: chain empty → window closes, phase advances.
			_clear_damage_prevention(state)   # window over — unspent block expires
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
		# A pending enters-play target choice is a MANDATORY choice belonging to
		# the effect's controller — hand priority there so the choice can be
		# submitted (can_submit blocks everything else anyway). Matters when the
		# effect's controller is NOT the turn player (e.g. a combat instant like
		# Quick Strike played by the defending player during a combat window).
		if not state.pending_enter_play_effect.is_empty():
			state.priority_player = _pending_effect_controller(state)
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

	# Pending enters-play target choice blocks everything except resolving it —
	# but once the choice is announced (sitting on the chain), armor block is a
	# legal response to the incoming damage (rule 304.3).
	if not state.pending_enter_play_effect.is_empty() \
			and action.action_type != "choose_enter_play_target":
		if not (action.action_type == "use_armor_prevention"
				and _enter_play_choice_on_chain(state)):
			return false

	# Pet uniqueness violation blocks everything until resolved via choose_pet_sacrifice().
	if state.pending_pet_sacrifice_player != "":
		return false

	# Equipment slot uniqueness violation blocks everything until resolved via
	# choose_equipment_sacrifice().
	if state.pending_equip_sacrifice_player != "":
		return false

	# Name-based (Unique tag) uniqueness violation blocks everything until resolved
	# via choose_unique_sacrifice().
	if state.pending_unique_sacrifice_player != "":
		return false

	# Infernal-style discard-or-give-control choice blocks everything until
	# resolved via choose_control_discard() / decline_control_discard().
	if state.pending_control_discard_player != "":
		return false

	# Reveal-and-pick quest reward blocks everything until resolved via
	# choose_reveal_pick().
	if state.pending_reveal_pick_player != "":
		return false

	# Strike point (602.1 / 602.3) blocks everything until resolved via choose_strike().
	if state.pending_strike_player != "":
		return false

	# Ready-on-attack point (Windseer Tarus) blocks everything until resolved via
	# choose_ready_on_attack().
	if state.pending_ready_player != "":
		return false

	# Ongoing Totem start-of-turn target choice blocks everything until resolved
	# via choose_totem_target().
	if state.pending_totem_target_player != "":
		return false

	match action.action_type:
		"play_ally":
			return _can_play_non_instant(state, action, db)
		"play_equipment":
			return _can_play_equipment(state, action, db)
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
		"use_armor_prevention":
			return _can_use_armor_prevention(state, action, db)
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
	# Card must actually be an Ally — Abilities and Instants have their own action types.
	var def: CardDef = null
	if db:
		def = db.get_def(card.card_def_id) as CardDef
		if def and def.card_type != "Ally":
			return false
	# Instant Ally (e.g. Tristan Rapidstrike): the Instant tag overrides non-instant
	# timing (rule 409.1) — playable any time its controller has priority, including
	# combat windows, the opponent's turn, and in response to a non-empty chain.
	# It still resolves as a normal ally (enters the ally_row with summoning sickness,
	# which does NOT prevent protecting — 601.2a restricts attackers only).
	if def == null or not def.is_instant:
		# Rule 502.1 / 1199: non-instants require the NON-COMBAT action phase — illegal
		# during attack or defend windows even though phase == "action" and chain is empty.
		if state.phase != "action":
			return false
		if state.combat_attack_window or state.combat_defend_window:
			return false
		if state.turn_player != action.source_player:
			return false
		if not state.pending_actions.is_empty():
			return false
	# Rule 412.2: player must be able to afford the cost.
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(action.source_player):
		return false
	return true


# Equipment (armor/item/weapon) — same action-phase timing as an ally, but the
# card type must be Equipment and it enters the hero row (rule 304.1 / 303.1).
static func _can_play_equipment(state: GameState, action: PendingAction,
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
	# Rule 502.1 / 1199: only the non-combat action phase, chain empty, your turn.
	if state.phase != "action":
		return false
	if state.combat_attack_window or state.combat_defend_window:
		return false
	if state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.card_type != "Equipment":
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
			if not _is_legal_target(state, target_id, db):
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
	# Instant Ability (e.g. Searing Totem): the Instant tag overrides non-instant
	# timing (rule 409.1) — playable any time its controller has priority. A
	# non-instant Ability keeps action-phase / turn-player / empty-chain timing.
	var play_def := db.get_def(card.card_def_id) as CardDef if db else null
	if play_def == null or not play_def.is_instant:
		if state.phase != "action": return false
		if state.combat_attack_window or state.combat_defend_window: return false
		if state.turn_player != action.source_player: return false
		if not state.pending_actions.is_empty(): return false
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(action.source_player):
		return false
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and _has_effect_flag_prefix(def, "chain_lightning"):
			if not _can_play_chain_lightning(state, action, db): return false
		elif def and _instant_needs_target(def):
			var target_id: String = action.params.get("target_id", "")
			if not _is_legal_target(state, target_id, db): return false
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
	# Instant Ability: priority-only timing (mirrors _can_play_ability above).
	var play_def := db.get_def(card.card_def_id) as CardDef if db else null
	if play_def == null or not play_def.is_instant:
		if state.phase != "action": return false
		if state.combat_attack_window or state.combat_defend_window: return false
		if state.turn_player != player_id: return false
		if not state.pending_actions.is_empty(): return false
	else:
		if state.priority_player != player_id: return false
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(player_id):
		return false
	return true


# Timing-only check (no target required) for targeted instants (Quick Strike).
# Used by the renderer to highlight the card green in hand before the player
# has chosen a target. Instant timing: any priority window, no phase/turn gate.
static func can_play_instant_no_target_check(state: GameState,
		card_id: String, player_id: String, db) -> bool:
	if state.priority_player != player_id: return false
	if not state.pending_enter_play_effect.is_empty(): return false
	if state.pending_pet_sacrifice_player != "": return false
	if state.pending_equip_sacrifice_player != "": return false
	if state.pending_unique_sacrifice_player != "": return false
	var card := state.get_card(card_id)
	if not card: return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand": return false
	if card.controller != player_id: return false
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(player_id):
		return false
	return true


static func _instant_needs_target(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["destroy_target", "deal_damage_to_target", "exhaust_target"]:
			return true
	return false


static func _instant_targets_ally_only(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["destroy_target", "exhaust_target"] \
				and parts.size() > 1 and parts[1] == "ally":
			return true
	return false


# Whether an in-play card is a legal "hero or ally" target: a hero (card_type
# "Hero") or an ally-row card. Excludes equipment (also hero_row) and
# resources/graveyard/etc.
static func _is_hero_or_ally(state: GameState, target_id: String, db) -> bool:
	if not state.is_in_play(target_id):
		return false
	if _is_ally(state, target_id):
		return true
	if db:
		var card := state.get_card(target_id)
		var def := db.get_def(card.card_def_id) as CardDef if card else null
		if def and def.card_type == "Hero":
			return true
	return false


# Whether a card can be chosen as (or remain) a link target (rule 706): it must
# be in play and — unless the caller opts out — must not have the Untargetable
# keyword (glossary ~4215: "This card can't be targeted", in play only).
# allow_untargetable is for card-specific slots that select rather than target
# (e.g. Chain Lightning's 2nd/3rd targets). Combat is NOT targeting (601.2b)
# and non-targeted effects (AoE) never go through this check.
static func _is_legal_target(state: GameState, target_id: String, db,
		allow_untargetable := false) -> bool:
	if target_id == "" or not state.is_in_play(target_id):
		return false
	if not allow_untargetable:
		var card := state.get_card(target_id)
		if card and _has_keyword(card, "untargetable", db):
			return false
	return true


# Chain Lightning (azeroth_106): up to 3 announced targets, in printed order.
# target_id (mandatory), target_id_2 / target_id_3 (optional "may" targets).
static func _chain_lightning_targets(action: PendingAction) -> Array[String]:
	var result: Array[String] = []
	var t1: String = action.params.get("target_id", "")
	var t2: String = action.params.get("target_id_2", "")
	var t3: String = action.params.get("target_id_3", "")
	if t1 != "":
		result.append(t1)
	if t2 != "":
		result.append(t2)
	if t3 != "":
		result.append(t3)
	return result


# Validates a Chain Lightning target announcement (card-specific — see CLAUDE.md).
# 1st target: must be a legal hero-or-ally target and may NOT be Untargetable
# (card-specific override of the normal Untargetable rule). 2nd/3rd targets:
# must be a legal hero-or-ally target, distinct from all previously chosen
# targets for this cast, but MAY be Untargetable. target_id_3 requires
# target_id_2 to also be set (can't skip "another" in the printed order).
static func _can_play_chain_lightning(state: GameState, action: PendingAction, db) -> bool:
	var target_id:   String = action.params.get("target_id",   "")
	var target_id_2: String = action.params.get("target_id_2", "")
	var target_id_3: String = action.params.get("target_id_3", "")
	if target_id == "":
		return false
	if not _is_hero_or_ally(state, target_id, db):
		return false
	if not _is_legal_target(state, target_id, db):
		return false
	if target_id_3 != "" and target_id_2 == "":
		return false
	if target_id_2 != "":
		if target_id_2 == target_id:
			return false
		if not _is_hero_or_ally(state, target_id_2, db):
			return false
		# allow_untargetable: this slot selects rather than targets
		# (card-specific exception — see comment above).
		if not _is_legal_target(state, target_id_2, db, true):
			return false
	if target_id_3 != "":
		if target_id_3 == target_id or target_id_3 == target_id_2:
			return false
		if not _is_hero_or_ally(state, target_id_3, db):
			return false
		# allow_untargetable: this slot selects rather than targets
		# (card-specific exception — see comment above).
		if not _is_legal_target(state, target_id_3, db, true):
			return false
	return true


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
	# Rule 412.1a: turn player's NON-COMBAT action phase only, chain empty.
	if state.phase != "action":
		return false
	if state.combat_attack_window or state.combat_defend_window:
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
		"play_equipment":
			return _resolve_play_equipment(state, action, db)
		"play_ability":
			if db and _is_ongoing_ability(state, action.params.get("card_id", ""), db):
				return _resolve_play_ongoing_ability(state, action, db)
			return _resolve_play_instant(state, action, db)   # non-ongoing: apply effect → graveyard
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
		"use_armor_prevention":
			return _resolve_use_armor_prevention(state, action, db)
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
		var fizzle_events: Array[GameEvent] = []
		fizzle_events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_ally", "reason": "card_left_chain",
		}))
		if zone and zone.zone_type != "graveyard":
			fizzle_events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
		return fizzle_events

	return _bring_ally_into_play(state, card_id, db)


# Move an ally into its controller's ally_row and fire its enter-play effects.
# Shared by normal play (_resolve_play_ally) and effects that put an ally into
# play from elsewhere (e.g. Finkle Einhorn's graveyard reward) — the on_enter
# triggers fire identically regardless of where the ally came from.
static func _bring_ally_into_play(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card:
		return []

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
					"discard_opponent":
						var n := int(parts[2]) if parts.size() > 2 else 1
						var opp := _other_player(state, card.controller)
						var opp_hand := state.cards_in_zone(opp + "_hand")
						if not opp_hand.is_empty():
							state.pending_discard_player = opp
							state.pending_discard_count  = n
							events.append(GameEvent.discard_choice_opened(opp, n, "card_effect"))
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

	# Watcher Mal'wi: "When an opposing ally enters play, [this] deals N ranged
	# damage to it." Any in-play card an OPPONENT of the entering ally controls
	# with the `damage_opposing_ally_on_enter:AMOUNT:DMG_TYPE` flag reacts here.
	# Resolved immediately (like the on_enter effects above), not via the chain —
	# see data/rules_deviations.md "Watcher Mal'wi".
	if db:
		for other_pid in state.players:
			if other_pid == card.controller:
				continue
			for watcher in state.cards_in_play(other_pid):
				var wdef := db.get_def(watcher.card_def_id) as CardDef
				if not wdef or wdef.effects == "":
					continue
				for seg in wdef.effects.split("|"):
					var wp := seg.strip_edges().split(":")
					if wp[0].strip_edges() != "damage_opposing_ally_on_enter":
						continue
					if not state.is_in_play(card_id):
						break   # entering ally already destroyed by an earlier watcher
					# wp[2] is the damage type (ranged) — flavor only; deal_damage
					# doesn't track a combat/effect damage type.
					var amt := int(wp[1]) if wp.size() > 1 else 1
					events.append_array(GameLogic.deal_damage(
						state, watcher.instance_id, card_id, amt, db))
					events.append_array(_check_destroyed_trigger(
						state, card_id, watcher.instance_id, db))

	# Check pet uniqueness (414.3b) — must happen after the card is in play.
	events.append_array(_check_pet_uniqueness(state, card_id, db))
	# Check name-based (Unique tag) uniqueness (414.3a) — Lady Jaina Proudmoore.
	events.append_array(_check_unique_uniqueness(state, card_id, db))

	return events


static func _resolve_play_equipment(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "play_equipment", "reason": "card_not_found",
		})]
	# Re-validate: card must still be on the chain (711.1); otherwise it fizzles.
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "chain":
		var fizzle_events: Array[GameEvent] = []
		fizzle_events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_equipment", "reason": "card_left_chain",
		}))
		if zone and zone.zone_type != "graveyard":
			fizzle_events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
		return fizzle_events

	var events: Array[GameEvent] = []
	# Rule 304.1 / 303.1: equipment enters play in its controller's hero row.
	events.append_array(GameLogic.move_card(state, card_id, card.controller + "_hero_row"))

	# Check equipment slot uniqueness (414.3) — must happen after it's in play.
	events.append_array(_check_equipment_uniqueness(state, card_id, db))
	# Check name-based (Unique tag) uniqueness (414.3a) — e.g. a Unique weapon.
	events.append_array(_check_unique_uniqueness(state, card_id, db))

	return events


# Rule 305.2a: an ability is ongoing if the bold word "Ongoing" appears in its
# text box. We tag that in the effects string with a leading "ongoing" segment.
static func _is_ongoing_ability(state: GameState, card_id: String, db) -> bool:
	var card := state.get_card(card_id)
	if not card:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return false
	return is_ongoing_def(def)


# Static def-only variant of _is_ongoing_ability — used by the renderer / AI
# action-type dispatch, which have a CardDef but no live card_id.
static func is_ongoing_def(def: CardDef) -> bool:
	if not def:
		return false
	for seg in def.effects.split("|"):
		if seg.strip_edges() == "ongoing":
			return true
	return false


# Rule 305.3: a Totem is an ability ally that enters the ally_row, can't be
# proposed as an attacker, and can be attacked/targeted like an ally. We tag it
# with a "totem[:element]" segment in the effects string.
static func is_totem_def(def: CardDef) -> bool:
	if not def:
		return false
	for seg in def.effects.split("|"):
		if seg.strip_edges() == "totem" or seg.strip_edges().begins_with("totem:"):
			return true
	return false


static func _resolve_play_ongoing_ability(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "play_ability", "reason": "card_not_found",
		})]
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "chain":
		var fizzle_events: Array[GameEvent] = []
		fizzle_events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_ability", "reason": "card_left_chain",
		}))
		if zone and zone.zone_type != "graveyard":
			fizzle_events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
		return fizzle_events

	var events: Array[GameEvent] = []
	var def := db.get_def(card.card_def_id) as CardDef if db else null
	# Rule 305.3: a Totem is an ability ALLY — it enters the controller's ally_row
	# (so it can be attacked/targeted like an ally), not the hero row. It carries
	# summoning sickness like any other ally (irrelevant to attacking — totems
	# can't attack — but it means it isn't ready to be tapped for anything else).
	if def and is_totem_def(def):
		events.append_array(GameLogic.move_card(state, card_id, card.controller + "_ally_row"))
		card.just_summoned = true
		return events
	# Rule 305.2c: any other non-attaching ongoing ability enters play in its
	# controller's hero row and remains there (providing its continuous
	# effect) until removed from play — it does not resolve-and-graveyard
	# like a non-ongoing ability.
	events.append_array(GameLogic.move_card(state, card_id, card.controller + "_hero_row"))
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
						# Re-check at resolution (rule 706 / glossary 4217): the
						# effect fizzles if the target left play OR became
						# Untargetable after the announce.
						if _is_legal_target(state, target_id, db):
							events.append_array(
								_destroy_card_trigger(state, target_id, card_id, db))
					"exhaust_target":
						# "Exhaust target ally." (Exhaustion). Re-check at resolution
						# (706): fizzles if the ally left play / became Untargetable.
						# exhaust_card no-ops if it's already exhausted. Played in
						# response to a combat proposal and aimed at the attacker, the
						# 601.3 recheck then fizzles the proposal (attacker not ready).
						if _is_legal_target(state, target_id, db) \
								and _is_ally(state, target_id):
							events.append_array(GameLogic.exhaust_card(state, target_id))
					"deal_damage_to_target":
						# "Your hero deals N <type> damage to target hero or ally."
						# (Quick Strike). Target is announced at play time (rule 601-style;
						# gives humans cancellable targeting). The HERO is the damage
						# source per the card text, not this ability card. If the target
						# left play before resolution, the damage fizzles (711.1) and the
						# card still goes to the graveyard below.
						var amount := int(parts[1]) if parts.size() > 1 else 0
						var ps := state.players.get(action.source_player) as PlayerState
						var hero_id: String = ps.hero_instance_id if ps else ""
						if hero_id != "" and amount > 0 \
								and _is_legal_target(state, target_id, db):
							events.append_array(GameLogic.deal_damage(
								state, hero_id, target_id, amount, db))
							var t_card := state.get_card(target_id)
							if t_card and state.get_current_hp(target_id, db) <= 0:
								var t_zone := state.zones.get(t_card.zone_id) as Zone
								if t_zone and t_zone.zone_type == "hero_row":
									events.append(GameEvent.game_over(
										_other_player(state, t_card.controller), t_card.controller))
								else:
									events.append_array(
										_check_destroyed_trigger(state, target_id, hero_id, db))
							else:
								# Optional 4th field: restriction(s) applied to a character
								# "dealt damage this way" that survives — Frostbolt
								# (cannot_attack), Frost Shock (cannot_attack+cannot_protect).
								# Restrictions last until end of the current turn (turns:1).
								if parts.size() > 3 and state.is_in_play(target_id):
									events.append_array(_apply_damage_riders(
										state, target_id, hero_id, parts[3]))
					"chain_lightning":
						# "Your hero deals A1 <type> damage to target hero or ally. Your
						# hero may deal A2 <type> damage to another hero or ally. Your
						# hero may deal A3 <type> damage to another hero or ally."
						# (Chain Lightning). Up to 3 targets are announced at play time
						# (target_id/target_id_2/target_id_3); each wave resolves in
						# printed order, with its own destruction/game-over check before
						# the next wave — a target destroyed by an earlier wave simply
						# can't be hit again (711.1), it doesn't invalidate the cast.
						var cl_amounts: Array[int] = [
							int(parts[1]) if parts.size() > 1 else 0,
							int(parts[2]) if parts.size() > 2 else 0,
							int(parts[3]) if parts.size() > 3 else 0,
						]
						var cl_ps := state.players.get(action.source_player) as PlayerState
						var cl_hero_id: String = cl_ps.hero_instance_id if cl_ps else ""
						var cl_targets := _chain_lightning_targets(action)
						if cl_hero_id != "":
							for i in cl_targets.size():
								var cl_target_id: String = cl_targets[i]
								var cl_amount: int = cl_amounts[i] if i < cl_amounts.size() else 0
								# Rule 706 re-check per wave. Waves 2/3 select rather
								# than target (card-specific exception), so only the
								# 1st wave also fizzles on became-Untargetable.
								if cl_amount <= 0 \
										or not _is_legal_target(state, cl_target_id, db, i > 0):
									continue
								events.append_array(GameLogic.deal_damage(
									state, cl_hero_id, cl_target_id, cl_amount, db))
								var cl_t_card := state.get_card(cl_target_id)
								if cl_t_card and state.get_current_hp(cl_target_id, db) <= 0:
									var cl_t_zone := state.zones.get(cl_t_card.zone_id) as Zone
									if cl_t_zone and cl_t_zone.zone_type == "hero_row":
										events.append(GameEvent.game_over(
											_other_player(state, cl_t_card.controller), cl_t_card.controller))
									else:
										events.append_array(_check_destroyed_trigger(
											state, cl_target_id, cl_hero_id, db))
					"draw":
						# "Draw a card." (Arcane Shot) — unconditional, no target needed.
						var draw_n := int(parts[1]) if parts.size() > 1 else 1
						for _i in draw_n:
							events.append_array(_draw_one(state, action.source_player))
					"deal_damage_aoe_opponent":
						# "Your hero deals N <type> damage to each opposing hero and
						# ally." (Flamestrike) — no target needed, hits every
						# character the opponent controls.
						var aoe_amount := int(parts[1]) if parts.size() > 1 else 0
						var ps2 := state.players.get(action.source_player) as PlayerState
						var hero_id2: String = ps2.hero_instance_id if ps2 else ""
						var opp2 := _other_player(state, action.source_player)
						var opp_targets: Array[String] = []
						var opp_ps2 := state.players.get(opp2) as PlayerState
						if opp_ps2 and opp_ps2.hero_instance_id != "":
							opp_targets.append(opp_ps2.hero_instance_id)
						for opp_ally in state.cards_in_zone(opp2 + "_ally_row"):
							opp_targets.append(opp_ally.instance_id)
						if hero_id2 != "" and aoe_amount > 0:
							for t_id in opp_targets:
								events.append_array(GameLogic.deal_damage(
									state, hero_id2, t_id, aoe_amount, db))
								var t_card2 := state.get_card(t_id)
								if t_card2 and state.get_current_hp(t_id, db) <= 0:
									var t_zone2 := state.zones.get(t_card2.zone_id) as Zone
									if t_zone2 and t_zone2.zone_type == "hero_row":
										events.append(GameEvent.game_over(
											_other_player(state, t_card2.controller), t_card2.controller))
									else:
										events.append_array(
											_check_destroyed_trigger(state, t_id, hero_id2, db))
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
			# extra_cost may itself carry a colon-separated amount (e.g.
			# "put_damage_self:1"), so rejoin everything past field 6.
			var extra_parts := parts.slice(6) if parts.size() > 6 else PackedStringArray()
			return {
				"resource_cost": int(parts[1]) if parts.size() > 1 else 0,
				"effect":        parts[2] if parts.size() > 2 else "",
				"amount":        int(parts[3]) if parts.size() > 3 else 0,
				"dmg_type":      parts[4] if parts.size() > 4 else "",
				"targets":       parts[5] if parts.size() > 5 else "",
				"extra_cost":    ":".join(extra_parts) if extra_parts.size() > 0 else "",
			}
	return {}


# Parse the "equipment:SLOT:DEF" segment from a CardDef's effects string.
# Returns {} if the card isn't equipment (per its recipe).
static func _equipment_info(def: CardDef) -> Dictionary:
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "equipment":
			return {
				"slot": (parts[1].strip_edges() if parts.size() > 1 else "").to_lower(),
				"def":  int(parts[2]) if parts.size() > 2 else 0,
			}
	return {}


# ── Weapons and striking (rules 303, 602.1, 602.3) ────────────────────────────
#
# Effects segment "weapon:STRIKE_COST" marks an Equipment card as a weapon
# (alongside its "equipment:SLOT:DEF" segment, which drives play + slot
# uniqueness). The weapon's ATK is the CSV atk column; damage type is the CSV
# dmg_type column ("Melee" gates Gorebelly's strike discount).
#
# Striking (303.2) doesn't use the chain: at exactly two moments — as the
# combat step starts for the attacking player (602.1) and as the defender
# enters combat for the defending player (602.3) — a hero's controller may
# exhaust a weapon + pay its strike cost to associate it with that hero for
# the combat. While associated, the hero gets +weapon ATK (303.2b, live in
# GameState.get_atk). Only heroes are wielders; the hero may be exhausted;
# one weapon per combat (303.2c).

# Parse the "weapon:STRIKE_COST" segment. Returns {} if the card isn't a weapon.
static func _weapon_info(def: CardDef) -> Dictionary:
	if not def:
		return {}
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "weapon":
			return {"strike_cost": int(parts[1]) if parts.size() > 1 else 0}
	return {}


# Effective strike cost for player_id (applies the pending melee discount).
static func get_strike_cost(state: GameState, player_id: String, def: CardDef) -> int:
	var info := _weapon_info(def)
	if info.is_empty():
		return -1
	var cost: int = info.get("strike_cost", 0)
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.melee_strike_discount > 0 and def.dmg_type.to_lower() == "melee":
		cost = max(0, cost - ps.melee_strike_discount)
	return cost


# Weapons player_id could strike with right now for the given wielder:
# ready weapons in the hero row whose (discounted) strike cost is affordable.
# Empty if the wielder isn't that player's hero or already struck this combat
# (303.2c — one weapon per combat).
static func get_strikeable_weapons(state: GameState, player_id: String,
		wielder_id: String, db) -> Array[String]:
	var result: Array[String] = []
	if not db:
		return result
	var ps := state.players.get(player_id) as PlayerState
	# Only heroes are wielders (303.2), and only the hero's own controller strikes.
	if not ps or ps.hero_instance_id != wielder_id:
		return result
	if not (state.combat_struck_weapons.get(wielder_id, []) as Array).is_empty():
		return result
	var available := state.get_available_resources(player_id)
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if card.is_exhausted:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		var cost := get_strike_cost(state, player_id, def)
		if cost >= 0 and cost <= available:
			result.append(card.instance_id)
	return result


# Opens a strike point for the wielder's controller if any strike is possible.
# Returns [] (and leaves state untouched) when there's nothing to offer, so
# callers fall through to opening the attack/defend window directly.
static func _open_strike_point(state: GameState, wielder_id: String,
		side: String, db) -> Array[GameEvent]:
	var wielder := state.get_card(wielder_id)
	if not wielder:
		return []
	var weapons := get_strikeable_weapons(state, wielder.controller, wielder_id, db)
	if weapons.is_empty():
		return []
	state.pending_strike_player     = wielder.controller
	state.pending_strike_weapon_ids = weapons
	state.pending_strike_side      = side
	return [GameEvent.strike_point_opened(wielder.controller, wielder_id, weapons, side)]


# Entry point for the strike decision (NOT chain-based — called directly by the
# scene, like choose_protector). weapon_id == "" means decline to strike.
# Pays the cost (exhaust weapon + resources, 303.2), records the association,
# then opens the window the strike point was holding up.
static func choose_strike(state: GameState, weapon_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_strike_player == "":
		return []
	var player_id := state.pending_strike_player
	var side      := state.pending_strike_side
	var offered   := state.pending_strike_weapon_ids
	state.pending_strike_player     = ""
	state.pending_strike_weapon_ids = []
	state.pending_strike_side       = ""

	var events: Array[GameEvent] = []
	var wielder_id := state.combat_attacker if side == "attack" else state.combat_defender
	if weapon_id != "" and weapon_id in offered and state.is_in_play(weapon_id) \
			and state.is_in_play(wielder_id) and db:
		var weapon := state.get_card(weapon_id)
		var def := db.get_def(weapon.card_def_id) as CardDef
		var cost := get_strike_cost(state, player_id, def)
		if cost >= 0 and cost <= state.get_available_resources(player_id) \
				and not weapon.is_exhausted:
			var ps := state.players.get(player_id) as PlayerState
			if ps and ps.melee_strike_discount > 0 and def.dmg_type.to_lower() == "melee":
				ps.melee_strike_discount = 0   # "the next time" — consumed
			events.append_array(GameLogic.exhaust_card(state, weapon_id))
			if cost > 0:
				events.append_array(_pay_resources(state, player_id, cost))
			var struck: Array = state.combat_struck_weapons.get(wielder_id, [])
			struck.append(weapon_id)
			state.combat_struck_weapons[wielder_id] = struck
			events.append(GameEvent.weapon_struck(player_id, wielder_id, weapon_id, cost))

	# Open the window this strike point was holding up.
	if side == "attack":
		state.combat_attack_window = true
		events.append(GameEvent.attack_window_opened(
			state.combat_attacker, state.combat_defender))
	else:
		state.combat_defend_window = true
		events.append(GameEvent.defend_window_opened(
			state.combat_attacker, state.combat_defender))
	return events


# ── Armor damage prevention (rule 304.3) ──────────────────────────────────────
#
# Exhaust a ready armor with DEF > 0 to add its DEF to the controller's
# damage_prevention pool ("current block"). Block is committed BEFORE damage
# resolves: legal only while damage is actually incoming — during combat
# windows / the protect point, or while a chain is pending (responding to a
# damage effect like Quick Strike). No summoning-sickness check ("regardless
# of how long it's been under your control").

# Is player_id's hero actually the target of incoming damage right now?
# Two sources (rule 304.3 — armor only blocks damage aimed at the hero):
#   • Combat — the Defend Window is open with our hero as the final combat_defender.
#     Not the Attack Window or protect point: until the protect point resolves,
#     a Protector could still take the hit instead of the hero, so blocking
#     earlier would be premature (and isn't legal).
#   • Chain  — an opposing damage effect on pending_actions targets our hero
#     (e.g. Quick Strike, Grimdron's power) — legal any time, combat or not.
static func has_incoming_hero_damage(state: GameState, db, player_id: String) -> bool:
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return false
	var hero_id := ps.hero_instance_id
	if state.combat_defend_window \
			and state.combat_defender == hero_id \
			and state.is_in_play(state.combat_attacker):
		return true
	# Combat retaliation (rule 603.1) — our hero is the attacker (striking with a
	# weapon) and the defender deals combat damage back at conclusion. Wait for
	# the defend window (the defender is locked in after the protect point).
	# Long-Range attackers take no retaliation, so there's nothing to block.
	if state.combat_defend_window \
			and state.combat_attacker == hero_id \
			and state.is_in_play(state.combat_defender) \
			and db and state.get_atk(state.combat_defender, db) > 0:
		var atk_card := state.get_card(hero_id)
		if not (_has_keyword(atk_card, "long_range", db) \
				or _struck_weapon_grants_long_range(state, hero_id, db)):
			return true
	for act in state.pending_actions:
		if act.source_player == player_id:
			continue
		if not db:
			continue
		# Enter-play targeted damage (e.g. Taz'dingo) — the target choice sits on
		# the chain as choose_enter_play_target; the effect lives in
		# pending_enter_play_effect (cleared only at resolution).
		if act.action_type == "choose_enter_play_target":
			if act.params.get("target_id", "") == hero_id \
					and (state.pending_enter_play_effect.get("effect", "") as String)\
						.begins_with("deal_damage_to_target"):
				return true
			continue
		var src := state.get_card(act.params.get("card_id", ""))
		var def := db.get_def(src.card_def_id) as CardDef if src else null
		if not def:
			continue
		match act.action_type:
			"play_instant", "play_ability":
				if act.params.get("target_id", "") == hero_id \
						and _has_effect_flag_prefix(def, "deal_damage_to_target"):
					return true
				if _has_effect_flag_prefix(def, "chain_lightning") \
						and hero_id in _chain_lightning_targets(act):
					return true
			"use_ally_power":
				if act.params.get("target_id", "") != hero_id:
					continue
				var ap := _ally_activated_power(def)
				if (ap.get("effect", "") as String) == "deal_damage_to_target":
					return true
	return false


static func _enter_play_choice_on_chain(state: GameState) -> bool:
	for a in state.pending_actions:
		if (a as PendingAction).action_type == "choose_enter_play_target":
			return true
	return false


static func _has_effect_flag_prefix(def: CardDef, prefix: String) -> bool:
	for segment in def.effects.split("|"):
		if segment.strip_edges().split(":")[0] == prefix:
			return true
	return false


static func _can_use_armor_prevention(state: GameState, action: PendingAction,
		db = null) -> bool:
	if state.priority_player != action.source_player:
		return false
	# Only meaningful while our hero is actually the target of incoming damage.
	if not has_incoming_hero_damage(state, db, action.source_player):
		return false
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card or card.controller != action.source_player:
		return false
	if card.is_exhausted:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hero_row":
		return false
	if not db:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.card_type != "Equipment":
		return false
	return int(_equipment_info(def).get("def", 0)) > 0


static func _resolve_use_armor_prevention(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card or not db:
		return [GameEvent.make("action_fizzled",
			{"action_type": "use_armor_prevention", "reason": "card_not_found"})]
	var def := db.get_def(card.card_def_id) as CardDef
	var def_value := int(_equipment_info(def).get("def", 0)) if def else 0
	var ps := state.players.get(action.source_player) as PlayerState
	if not ps or def_value <= 0:
		return [GameEvent.make("action_fizzled",
			{"action_type": "use_armor_prevention", "reason": "no_defense_value"})]
	ps.damage_prevention += def_value
	return [GameEvent.armor_prevention_used(
		action.source_player, card_id, def_value, ps.damage_prevention)]


# Unspent block expires when the threat it was declared against is gone.
static func _clear_damage_prevention(state: GameState) -> void:
	for pid in state.players:
		var ps := state.players[pid] as PlayerState
		if ps:
			ps.damage_prevention = 0


# ── Ally activated power — validation ─────────────────────────────────────────

static func _can_use_ally_power(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Requires priority and action phase. A non-empty chain is allowed: activated ally
	# powers are instant-speed (rule 701.3) and may respond to something already on the
	# chain (e.g. Freya Lightsworn healing in response to Ta'zo's damage power). The
	# empty-chain gate applies only to "on_your_turn" (sorcery-speed) powers below.
	# No "turn_player" restriction either — ally powers without "use only on your turn"
	# work on either player's turn (e.g. Grimdron blocking in an opponent's window).
	if state.priority_player != action.source_player:
		return false
	if state.phase != "action":
		return false
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card or card.controller != action.source_player:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	# Allies use their power from the ally row; equipment (e.g. Mooncloth Robe)
	# from the hero row. Both are validated through this same path.
	if not zone or not (zone.zone_type in ["ally_row", "hero_row"]):
		return false
	if not db:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return false
	var ap := _ally_activated_power(def)
	if ap.is_empty():
		return false
	# "Use only on your turn" (e.g. Acolyte Demia) — same convention as hero
	# powers (_power_effect_is(def, "on_your_turn")), as a standalone segment.
	# Also used for engine-only deviations where the printed text has no such
	# restriction but it's true by construction (e.g. Rayder — see
	# data/rules_deviations.md).
	if _power_effect_is(def, "on_your_turn"):
		if state.turn_player != action.source_player:
			return false
		if not state.pending_actions.is_empty():
			return false
	var extra_cost_str: String = ap.get("extra_cost", "")
	var once_per_turn: bool = extra_cost_str == "once_per_turn"
	# put_damage_self (e.g. Acolyte Demia) has no [Activate] tap symbol either —
	# its cost is just the resource + self-damage, so it's a plain payment power
	# (701.2), not an activated power (701.3). No summoning sickness, no exhaust.
	var no_activate_symbol: bool = extra_cost_str.begins_with("put_damage_self") \
		or extra_cost_str == "no_activate"
	if once_per_turn:
		# No [Activate] tap symbol on this power (rule 701.3/3216): it isn't gated
		# by summoning sickness or the card's exhausted state, only by its own
		# printed "once per turn" text.
		if card.used_this_turn:
			return false
	elif not no_activate_symbol:
		# Rule 701.3: summoning sickness applies to activated powers for allies.
		# Equipment are not characters and never carry summoning sickness, so this
		# only ever gates allies (equipment never sets just_summoned).
		if card.just_summoned:
			return false
		if card.is_exhausted:
			return false
	if state.get_available_resources(action.source_player) < int(ap.get("resource_cost", 0)):
		return false
	# Extra, card-specific costs baked into the power (e.g. Mooncloth Robe also
	# exhausts your hero). If the hero can't pay, the power can't be used.
	if not _can_pay_extra_power_cost(state, action.source_player, ap.get("extra_cost", ""), db):
		return false
	# Targeted effects require a valid in-play target. `_skip_target_check` (used
	# by has_any_legal_play / highlight probes, mirroring the instant/quest
	# no-target-check helpers) validates everything EXCEPT the specific target,
	# since the target is picked interactively after the power is chosen.
	var skip_target: bool = action.params.get("_skip_target_check", false)
	var targets_kind: String = ap.get("targets", "")
	if skip_target:
		return true
	if targets_kind in ["hero_or_ally", "ally", "friendly_ally"]:
		var target_id: String = action.params.get("target_id", "")
		if not _is_legal_target(state, target_id, db):
			return false
		# "ally" powers (Elder Moorf buff, Augustus destroy) may only target
		# allies, not heroes. "friendly_ally" (Bizzik's sacrifice cost) further
		# requires the ally be in the source player's own party.
		if targets_kind in ["ally", "friendly_ally"] and not _is_ally(state, target_id):
			return false
		if targets_kind == "friendly_ally":
			var t_card := state.get_card(target_id)
			if not t_card or t_card.controller != action.source_player:
				return false
	elif targets_kind == "hero_or_ally_two":
		# Hierophant Caydiem: damage target_id, heal a different heal_target_id
		# (rule 706.1 — "another target" can't repeat the first).
		var target_id2: String = action.params.get("target_id", "")
		var heal_target_id: String = action.params.get("heal_target_id", "")
		if not _is_legal_target(state, target_id2, db):
			return false
		if not _is_legal_target(state, heal_target_id, db):
			return false
		if heal_target_id == target_id2:
			return false
	return true


# Whether an in-play card sits in an ally row (i.e. is an ally on the board).
static func _is_ally(state: GameState, card_id: String) -> bool:
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	return zone != null and zone.zone_type == "ally_row"


# Whether a power's extra cost token can currently be paid.
static func _can_pay_extra_power_cost(state: GameState, player_id: String,
		extra_cost: String, db = null) -> bool:
	var token := extra_cost.split(":")[0] if extra_cost != "" else ""
	match token:
		"", null:
			return true
		"exhaust_hero":
			var ps := state.players.get(player_id) as PlayerState
			var hero_id: String = ps.hero_instance_id if ps else ""
			if hero_id == "":
				return false
			var hero := state.get_card(hero_id)
			return hero != null and not hero.is_exhausted
		"put_damage_self", "activate_put_damage_self":
			# Rule 405.3: damage put on a character can't exceed its remaining
			# health, but it CAN be exactly fatal — always payable while the
			# source is in play (checked by the caller). activate_put_damage_self
			# (Kena Shadowbrand) is the same self-damage cost but keeps the
			# [Activate] tap symbol (the source also exhausts).
			return true
		"rfg_allies":
			# Augustus Corpsemonger: remove N ally cards in your graveyard from
			# the game. Payable only if the graveyard holds at least N of them.
			var need := int(extra_cost.split(":")[1]) if extra_cost.split(":").size() > 1 else 0
			return _count_graveyard_allies(state, player_id, db) >= need
		"sacrifice_ally":
			# Bizzik Sparkcog: destroy an ally in your party as a cost. Payable
			# while you control at least one ally (Bizzik himself qualifies).
			return not state.cards_in_zone(player_id + "_ally_row").is_empty()
	return true


# Count ally cards sitting in player_id's graveyard (Augustus Corpsemonger cost).
static func _count_graveyard_allies(state: GameState, player_id: String, db) -> int:
	var n := 0
	if not db:
		return 0
	for card in state.cards_in_zone(player_id + "_graveyard"):
		var def := db.get_def(card.card_def_id) as CardDef
		if def and def.card_type == "Ally":
			n += 1
	return n


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
	var extra_cost: String = ap.get("extra_cost", "")
	# Resource cost already paid at submission time (in submit_action).
	if extra_cost == "once_per_turn":
		# No [Activate] tap symbol on this power — don't exhaust the source,
		# just mark it used until the once-per-turn flag resets next turn.
		card.used_this_turn = true
	elif extra_cost.begins_with("put_damage_self") or extra_cost == "no_activate":
		# No [Activate] tap symbol on this power either (e.g. Acolyte Demia,
		# Hierophant Caydiem) — the source never exhausts and can be reused
		# any time it's affordable.
		pass
	else:
		# Exhaust the source at resolution (the activate symbol).
		events.append_array(GameLogic.exhaust_card(state, card_id))
	# Pay any extra card-specific cost (e.g. Mooncloth Robe also exhausts the hero).
	if extra_cost == "exhaust_hero":
		var ps := state.players.get(action.source_player) as PlayerState
		var hero_id: String = ps.hero_instance_id if ps else ""
		if hero_id != "":
			events.append_array(GameLogic.exhaust_card(state, hero_id))
	elif extra_cost.begins_with("put_damage_self") \
			or extra_cost.begins_with("activate_put_damage_self"):
		# Rule 405.3: put (not deal) damage on the source itself (Acolyte Demia;
		# Kena Shadowbrand). Can be exactly fatal — check destruction after paying.
		var put_parts := extra_cost.split(":")
		var put_amount: int = int(put_parts[1]) if put_parts.size() > 1 else 1
		events.append_array(GameLogic.put_damage(state, card_id, put_amount, db))
		events.append_array(_check_destroyed_trigger(state, card_id, card_id, db))
	elif extra_cost.begins_with("rfg_allies"):
		# Augustus Corpsemonger: remove N ally cards in your graveyard from the
		# game (rule 415.7a — owner's RFG zone). The specific cards are auto-
		# chosen in graveyard order (see data/rules_deviations.md — the player
		# doesn't pick which dead allies leave, only a cost is paid).
		var rfg_n := int(extra_cost.split(":")[1]) if extra_cost.split(":").size() > 1 else 0
		var removed := 0
		for gy_card in state.cards_in_zone(action.source_player + "_graveyard"):
			if removed >= rfg_n:
				break
			var gy_def := db.get_def(gy_card.card_def_id) as CardDef
			if gy_def and gy_def.card_type == "Ally":
				events.append_array(GameLogic.move_card(state, gy_card.instance_id, gy_card.owner + "_rfg"))
				events.append(GameEvent.card_removed_from_game(gy_card.instance_id, action.source_player))
				removed += 1
	elif extra_cost == "sacrifice_ally":
		# Bizzik Sparkcog: destroy a chosen ally in your party as a cost. The
		# target_id names the sacrifice (may be Bizzik himself).
		var sac_id: String = action.params.get("target_id", "")
		if _is_ally(state, sac_id):
			events.append_array(_destroy_card_trigger(state, sac_id, card_id, db))
	events.append(GameEvent.make("ally_power_used",
		{"ally_id": card_id, "player": action.source_player,
			"target_id": action.params.get("target_id", "")}))

	match ap.get("effect", ""):
		"draw":
			var n: int = int(ap.get("amount", 1))
			for _i in n:
				events.append_array(_draw_one(state, card.controller))
		"discard_opponent":
			# Hypnotic Blade: "Target player discards a card." The target is
			# auto-chosen as the opponent (discarding yourself is never useful in
			# a duel — see data/rules_deviations.md "Hypnotic Blade"). Reuses the
			# Mias the Putrid pending-discard machinery.
			var disc_n: int = int(ap.get("amount", 1))
			var disc_opp := _other_player(state, card.controller)
			if not state.cards_in_zone(disc_opp + "_hand").is_empty():
				state.pending_discard_player = disc_opp
				state.pending_discard_count  = disc_n
				events.append(GameEvent.discard_choice_opened(disc_opp, disc_n, "card_effect"))
		"destroy_ally":
			# Augustus Corpsemonger: "Destroy target ally." Re-check at resolution
			# (rule 706 / glossary 4217) — fizzle if the target left play or
			# became Untargetable after the announce.
			var destroy_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, destroy_id, db) and _is_ally(state, destroy_id):
				events.append_array(_destroy_card_trigger(state, destroy_id, card_id, db))
		"exhaust_target":
			# Galahandra, Keeper of the Silent Grove: "1, [Activate] -> Exhaust
			# target ally." Re-check at resolution (706): fizzles if the ally
			# left play / became Untargetable. exhaust_card no-ops if already
			# exhausted. Same interrupt role as Exhaustion (azeroth_159), but
			# as a repeatable ally power instead of a one-shot instant.
			var exhaust_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, exhaust_id, db) and _is_ally(state, exhaust_id):
				events.append_array(GameLogic.exhaust_card(state, exhaust_id))
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
		"deal_damage_to_target":
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			# Rule 706 re-check: fizzle if the target left play or became Untargetable.
			if _is_legal_target(state, target_id, db):
				events.append_array(GameLogic.deal_damage(state, card_id, target_id, amount, db))
				var t_card := state.get_card(target_id)
				if t_card and state.get_current_hp(target_id, db) <= 0:
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if t_zone and t_zone.zone_type == "hero_row":
						events.append(GameEvent.game_over(
							_other_player(state, t_card.controller), t_card.controller))
					else:
						events.append_array(_check_destroyed_trigger(state, target_id, card_id, db))
		"heal_target":
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, target_id, db):
				events.append_array(GameLogic.heal(state, target_id, amount, db, card_id))
		"buff_atk_target":
			# Elder Moorf: "Target ally has +X ATK this turn."
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			var target := state.get_card(target_id)
			if target and _is_legal_target(state, target_id, db) \
					and _is_ally(state, target_id):
				var buff := Buff.make("moorf_atk", card_id, "atk", amount, "turns", 1)
				events.append_array(GameLogic.add_buff(state, target_id, buff))
		"party_buff_atk_attacking":
			# Rayder: "Allies in your party have +X ATK while attacking this
			# turn." Tracked player-side (not per-card) so it also covers
			# allies that enter play later this turn.
			var amount: int = int(ap.get("amount", 0))
			var ps := state.players.get(card.controller) as PlayerState
			if ps:
				ps.party_atk_buffs_this_turn.append({"amount": amount, "alignment": ""})
				events.append(GameEvent.party_atk_buff_added(card.controller, amount, ""))
		"buff_atk_target_attacking":
			# Ryn Dreamstrider: "Target hero or ally has +X ATK while attacking this turn."
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, target_id, db):
				var buff := Buff.make("ryn_atk", card_id, "atk", amount,
						"turns", 1, "while_attacking")
				events.append_array(GameLogic.add_buff(state, target_id, buff))
		"deal_damage_and_heal":
			# Hierophant Caydiem: deals AMOUNT damage to target_id and heals
			# AMOUNT from a different heal_target_id.
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			var heal_target_id: String = action.params.get("heal_target_id", "")
			if _is_legal_target(state, target_id, db):
				events.append_array(GameLogic.deal_damage(state, card_id, target_id, amount, db))
				var t_card := state.get_card(target_id)
				if t_card and state.get_current_hp(target_id, db) <= 0:
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if t_zone and t_zone.zone_type == "hero_row":
						events.append(GameEvent.game_over(
							_other_player(state, t_card.controller), t_card.controller))
					else:
						events.append_array(_check_destroyed_trigger(state, target_id, card_id, db))
			if _is_legal_target(state, heal_target_id, db):
				events.append_array(GameLogic.heal(state, heal_target_id, amount, db, card_id))

	return events


# ── Combat — validation ────────────────────────────────────────────────────────

static func _can_propose_combat(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Rule 601.1: non-combat action phase only, chain empty, turn player.
	if state.phase != "action":
		return false
	if state.combat_attack_window or state.combat_defend_window or state.in_protect_point:
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
		# "Opposing allies can't attack." (Lady Jaina) — locks allies only, not heroes.
		if _allies_attack_locked(state, attacker.controller, db):
			return false
	# Rule 305.3a: Totems can't be proposed as attackers.
	if db and is_totem_def(db.get_def(attacker.card_def_id) as CardDef):
		return false
	# "can't attack" allies (e.g. Guardian Steelhorn) can never propose combat.
	if _has_keyword(attacker, "cant_attack", db):
		return false
	# "Can't attack this turn" restriction buff (e.g. Litori Frostburn).
	if attacker.has_restriction("cannot_attack"):
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
	# Taunt check: if any legal defender has sarmoth_taunt, only that card is valid.
	if defender_id not in get_legal_defenders(state, attacker_id, db):
		return false
	return true


# ── Combat — query helpers (called by AI and InputRouter) ─────────────────────

# Returns instance_ids of all legal attackers the player can propose right now.
# Does NOT check phase/chain — callers apply that context.
static func get_legal_attackers(state: GameState, player_id: String, db) -> Array[String]:
	var result: Array[String] = []
	# Hero (rule 301.3: no summoning sickness; still must be ready per 601.2a).
	# Also require ATK > 0 OR an affordable, ready weapon to strike with — a
	# 0 ATK hero that can't strike deals no damage and exhausts for nothing;
	# treat as not a legal attacker (practical gate, not an explicit rule, but
	# avoids pointless/confusing highlights and AI plays).
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.hero_instance_id != "":
		var hero := state.get_card(ps.hero_instance_id)
		if hero and not hero.is_exhausted \
				and (state.get_atk(hero.instance_id, db) > 0
					or not get_strikeable_weapons(state, player_id, hero.instance_id, db).is_empty()) \
				and not _has_keyword(hero, "cant_attack", db) \
				and not hero.has_restriction("cannot_attack"):
			result.append(hero.instance_id)
	# "Opposing allies can't attack." (Lady Jaina) locks ALL of this player's
	# allies — evaluated once here, applied in the ally loop below.
	var allies_locked := _allies_attack_locked(state, player_id, db)
	# Allies (rule 302.2: just_summoned unless Ferocity).
	for card in state.cards_in_zone(player_id + "_ally_row"):
		if allies_locked:
			continue
		if card.is_exhausted:
			continue
		# Rule 305.3a: Totems can't be proposed as attackers.
		if db and is_totem_def(db.get_def(card.card_def_id) as CardDef):
			continue
		if card.just_summoned and not _has_keyword(card, "ferocity", db):
			continue
		# "can't attack" allies (e.g. Guardian Steelhorn) are never legal attackers.
		if _has_keyword(card, "cant_attack", db):
			continue
		if card.has_restriction("cannot_attack"):
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
	# sarmoth_taunt: if a taunt card is among the legal defenders, restrict to taunt cards only.
	if db:
		var taunt_ids: Array[String] = []
		for id in result:
			var c := state.get_card(id)
			if c and _has_effect_flag(db.get_def(c.card_def_id) as CardDef, "sarmoth_taunt"):
				taunt_ids.append(id)
		if not taunt_ids.is_empty():
			return taunt_ids
	return result


# Returns instance_ids of all characters that can protect this combat (rule 602.2).
# The defending player chooses whether to use one of these — it is NOT mandatory.
static func get_legal_protectors(state: GameState, _attacker_id: String,
		defender_id: String, db) -> Array[String]:
	var defender := state.get_card(defender_id)
	if not defender:
		return []
	var defending_player := defender.controller
	var defender_zone := state.zones.get(defender.zone_id) as Zone
	var defender_is_hero := defender_zone and defender_zone.zone_type == "hero_row"
	var result: Array[String] = []
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(defending_player + zone_suffix):
			if card.instance_id == defender_id:
				continue  # 602.2b: a proposed defender can't protect itself
			if card.is_exhausted:
				continue  # must be ready (will be exhausted when it protects)
			# "Can't protect this turn" restriction buff (Frost Shock).
			if card.has_restriction("cannot_protect"):
				continue
			if _has_keyword(card, "protector", db):
				result.append(card.instance_id)
				continue
			# Draconian Deflector-style grant: an in-play card with
			# hero_has_protector gives its controller's HERO Protector.
			if db:
				var ps := state.players.get(defending_player) as PlayerState
				if ps and card.instance_id == ps.hero_instance_id \
						and _hero_has_protector_grant(state, defending_player, db):
					result.append(card.instance_id)
					continue
			# Old Bones-style restricted grant: "can protect your hero" — only
			# usable when the hero is the proposed defender, not for allies.
			if defender_is_hero and db:
				var cdef := db.get_def(card.card_def_id) as CardDef
				if cdef and _has_effect_flag(cdef, "protect_hero_only"):
					result.append(card.instance_id)
	return result


# "Opposing allies can't attack." (Lady Jaina Proudmoore): true when the given
# player's OPPONENT controls an in-play card carrying the opposing_allies_cant_attack
# effect flag. A continuous static effect — evaluated live, never cached — that
# stops the player's allies (not their hero) from being proposed as attackers.
static func _allies_attack_locked(state: GameState, player_id: String, db) -> bool:
	if not db:
		return false
	var opp := _other_player(state, player_id)
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(opp + zone_suffix):
			if _has_effect_flag(db.get_def(card.card_def_id) as CardDef, "opposing_allies_cant_attack"):
				return true
	return false


# Donna Calister (azeroth_181): "When an opposing hero or ally attacks, ready
# Donna Calister." Called as a combat step starts. Readies every exhausted
# in-play card carrying the `ready_on_opposing_attack` effect flag whose
# controller is NOT the attacking player (i.e. the attacker is "opposing" to
# them). Non-targeted, no cost — resolved immediately rather than via the chain.
static func _ready_on_opposing_attack(state: GameState, attacker_id: String,
		db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if not db:
		return events
	var attacker := state.get_card(attacker_id)
	if not attacker:
		return events
	var defender_side := _other_player(state, attacker.controller)
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(defender_side + zone_suffix):
			if _has_effect_flag(db.get_def(card.card_def_id) as CardDef, "ready_on_opposing_attack"):
				events.append_array(GameLogic.ready_card(state, card.instance_id))
	return events


# Apply a damaged-target restriction rider (Frostbolt / Frost Shock). field is a
# "+"-joined list of restriction names (e.g. "cannot_attack+cannot_protect").
# Each becomes a restriction Buff lasting until the end of this turn (turns:1),
# reusing the same machinery as Litori Frostburn's target_cant_attack flip.
static func _apply_damage_riders(state: GameState, target_id: String,
		source_id: String, field: String) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var target := state.get_card(target_id)
	if not target:
		return events
	for restriction in field.split("+"):
		var r := restriction.strip_edges()
		if r == "":
			continue
		target.active_buffs.append(Buff.make(
			"frost_" + r + "_this_turn", source_id, r, 1, "turns", 1))
		if r == "cannot_attack":
			events.append(GameEvent.cant_attack_applied(target_id, source_id))
		elif r == "cannot_protect":
			events.append(GameEvent.cant_protect_applied(target_id, source_id))
	return events


# "Your hero has protector" (Draconian Deflector): true when any in-play card
# in the player's hero_row carries the hero_has_protector effect flag.
static func _hero_has_protector_grant(state: GameState, player_id: String, db) -> bool:
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if _has_effect_flag(db.get_def(card.card_def_id) as CardDef, "hero_has_protector"):
			return true
	return false


static func _has_effect_flag(def: CardDef, flag: String) -> bool:
	if not def:
		return false
	for segment in def.effects.split("|"):
		if segment.strip_edges() == flag:
			return true
	return false


# True if a weapon struck by wielder_id this combat carries the
# "strike_grants_long_range" effects flag (Ancient Bone Bow).
static func _struck_weapon_grants_long_range(state: GameState, wielder_id: String, db) -> bool:
	if not db or wielder_id == "":
		return false
	for weapon_id in state.combat_struck_weapons.get(wielder_id, []) as Array:
		var def := db.get_def(state.get_card(weapon_id).card_def_id) as CardDef
		if def and "strike_grants_long_range" in def.effects.split("|"):
			return true
	return false


static func _has_keyword(card: CardInstance, keyword: String, db) -> bool:
	if keyword in card.granted_keywords:
		return true
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and keyword in def.keywords:
			return true
	return false


# ── Combat window helpers ──────────────────────────────────────────────────────

# Called when the Attack Window closes (both players passed, chain empty).
# Runs the protect point or opens the Defend Window.
static func _close_attack_window(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	# Rule 602.2: if either combatant left play during the window, go to conclusion.
	if not state.is_in_play(state.combat_attacker) \
			or not state.is_in_play(state.combat_defender):
		events.append_array(_do_combat_conclusion(state, db))
		return events
	# Protect point — still not using the chain (rule 602.2).
	var protectors := get_legal_protectors(state, state.combat_attacker, state.combat_defender, db)
	if not protectors.is_empty():
		state.in_protect_point = true
		events.append(GameEvent.protect_point_opened(
			state.combat_attacker, state.combat_defender, protectors))
	else:
		events.append_array(_open_defend_window(state, db))
	return events


# Opens the Defend Window (rule 602.3): the proposed defender becomes the defender
# and both players get another priority window before damage. If the defender is
# a hero whose controller can strike with a weapon, the defending strike point
# opens first (602.3 — "at this time and only at this time", no chain).
static func _open_defend_window(state: GameState, db = null) -> Array[GameEvent]:
	# If either combatant left play, skip straight to conclusion.
	if not state.is_in_play(state.combat_attacker) \
			or not state.is_in_play(state.combat_defender):
		return _do_combat_conclusion(state, db)
	var strike := _open_strike_point(state, state.combat_defender, "defend", db)
	if not strike.is_empty():
		return strike
	state.combat_defend_window = true
	return [GameEvent.defend_window_opened(state.combat_attacker, state.combat_defender)]


# ── Combat — resolution ────────────────────────────────────────────────────────

static func _resolve_propose_combat(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var attacker_id: String = action.params.get("attacker_id", "")
	var defender_id: String = action.params.get("defender_id", "")
	var attacker := state.get_card(attacker_id)
	var defender := state.get_card(defender_id)

	# Rule 601.3: recheck legality as proposal resolves.
	# If either combatant is gone or now illegal, proposal fizzles — NO exhaust.
	# A "can't attack this turn" modifier applied in response (e.g. Litori
	# Frostburn) makes the proposal illegal here — the attacker never exhausts
	# and combat never starts. Once the combat step HAS started (attack window
	# open), the same modifier is too late to stop it (602.1: the attacker is
	# already attacking; "can't attack" is not a remove-from-combat effect).
	if not attacker or not defender \
			or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id) \
			or attacker.is_exhausted \
			or _has_keyword(attacker, "cant_attack", db) \
			or attacker.has_restriction("cannot_attack") \
			or _has_keyword(defender, "elusive", db):
		return [GameEvent.make("action_fizzled", {
			"action_type": "propose_combat", "reason": "illegal_at_resolution",
		})]

	# Rule 602.1: combat step starts — attacker exhausts now, then Attack Window opens.
	var events: Array[GameEvent] = []
	state.combat_attacker = attacker_id
	state.combat_defender = defender_id
	events.append_array(GameLogic.exhaust_card(state, attacker_id))
	events.append(GameEvent.combat_started(attacker_id, defender_id))
	# Donna Calister: "When an opposing hero or ally attacks, ready Donna
	# Calister." Triggers off the attack (any attacker), for the non-attacking
	# side. Non-targeted, no cost — resolved immediately as the combat step
	# starts (before the strike point / attack window) so she's ready to
	# protect this same combat. See data/rules_deviations.md "Donna Calister".
	events.append_array(_ready_on_opposing_attack(state, attacker_id, db))
	# Rule 602.1: the attacking player can strike with weapons now (and only
	# now), before the attack window opens. Doesn't use the chain.
	var strike := _open_strike_point(state, attacker_id, "attack", db)
	if not strike.is_empty():
		events.append_array(strike)
		return events
	# Windseer Tarus: "When [this] attacks for the first time each turn, you may
	# pay X. If you do, ready him." Opens a pending choice mirroring the strike
	# point, before the attack window (the trigger fires as the combat step starts).
	# Resolved immediately, not via the chain — see data/rules_deviations.md
	# "Windseer Tarus".
	var ready_pt := _open_ready_on_attack_point(state, attacker_id, db)
	if not ready_pt.is_empty():
		events.append_array(ready_pt)
		return events
	state.combat_attack_window = true
	events.append(GameEvent.attack_window_opened(attacker_id, defender_id))
	return events


# Opens a ready-on-attack point (Windseer Tarus) for the attacker's controller if
# the attacker has the `ready_on_attack:COST` flag, this is its first attack this
# turn, and the controller can afford COST. Marks the once-per-turn trigger as
# fired (whether or not the player ends up paying). Returns [] when nothing to
# offer, so the caller falls through to opening the attack window directly.
static func _open_ready_on_attack_point(state: GameState, attacker_id: String,
		db) -> Array[GameEvent]:
	if not db:
		return []
	var atk := state.get_card(attacker_id)
	if not atk:
		return []
	var def := db.get_def(atk.card_def_id) as CardDef
	if not def or def.effects == "":
		return []
	var cost := -1
	for seg in def.effects.split("|"):
		var p := seg.strip_edges().split(":")
		if p[0].strip_edges() == "ready_on_attack":
			cost = int(p[1]) if p.size() > 1 else 0
			break
	if cost < 0:
		return []
	# "for the first time each turn" — only offer once per turn.
	if int(atk.counters.get("attacked_this_turn", 0)) > 0:
		return []
	atk.counters["attacked_this_turn"] = 1
	if state.get_available_resources(atk.controller) < cost:
		return []
	state.pending_ready_player  = atk.controller
	state.pending_ready_card_id = attacker_id
	state.pending_ready_cost    = cost
	return [GameEvent.ready_on_attack_opened(atk.controller, attacker_id, cost)]


# Entry point for the ready-on-attack decision (NOT chain-based — called directly
# by the scene, like choose_strike). pay == false means decline. Pays the cost and
# readies the attacker (it stays the combat_attacker, so this combat proceeds; it's
# ready again afterward to attack a second time), then opens the held attack window.
static func choose_ready_on_attack(state: GameState, pay: bool,
		db = null) -> Array[GameEvent]:
	if state.pending_ready_player == "":
		return []
	var player_id := state.pending_ready_player
	var card_id   := state.pending_ready_card_id
	var cost      := state.pending_ready_cost
	state.pending_ready_player  = ""
	state.pending_ready_card_id = ""
	state.pending_ready_cost    = 0

	var events: Array[GameEvent] = []
	if pay and state.is_in_play(card_id) \
			and state.get_available_resources(player_id) >= cost:
		if cost > 0:
			events.append_array(_pay_resources(state, player_id, cost))
		events.append_array(GameLogic.ready_card(state, card_id))
		events.append(GameEvent.readied_on_attack(player_id, card_id, cost))

	# Open the attack window this ready point was holding up.
	state.combat_attack_window = true
	events.append(GameEvent.attack_window_opened(
		state.combat_attacker, state.combat_defender))
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
		state.combat_protector = protector_id
		events.append(GameEvent.protect_chosen(protector_id, defending_player))
	else:
		events.append(GameEvent.protect_chosen("", defending_player))

	# Rule 602.3: protect point concludes, now open the Defend Window.
	events.append_array(_open_defend_window(state, db))
	return events


# Rule 603: simultaneous damage + PPP + win check.
static func _do_combat_conclusion(state: GameState, db = null) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender

	var attacker := state.get_card(attacker_id) if attacker_id != "" else null
	var defender := state.get_card(defender_id) if defender_id != "" else null

	# Rule 603.1b: if either side is gone, no damage.
	if not attacker or not defender \
			or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id):
		state.combat_attacker = ""
		state.combat_defender = ""
		state.combat_protector = ""
		state.combat_struck_weapons.clear()   # 303.2a — associations end with the combat step
		events.append(GameEvent.combat_concluded(attacker_id, defender_id, 0, 0))
		_clear_damage_prevention(state)   # threat gone — unspent block expires
		return events

	# Rule 603.1: both deal damage simultaneously.
	# Capture ATK values BEFORE applying any damage to either side, and before
	# clearing combat_attacker below — "while attacking" modifiers (Zorm,
	# Rayder, For the Horde!) key off state.combat_attacker in get_atk, so it
	# must still be set while these are computed.
	var atk_dmg := state.get_atk(attacker_id, db)   # to defender
	var def_dmg := state.get_atk(defender_id, db)   # to attacker (0 for heroes, per 205.1)
	# Rule glossary "Long-Range": while attacking, defenders can't deal combat damage.
	# Ancient Bone Bow grants long-range for the combat when the wielder strikes it.
	if _has_keyword(attacker, "long_range", db) \
			or _struck_weapon_grants_long_range(state, attacker_id, db):
		def_dmg = 0
	state.combat_attacker = ""
	state.combat_defender = ""
	state.combat_protector = ""
	state.combat_struck_weapons.clear()   # 303.2a — associations end with the combat step
	events.append(GameEvent.combat_concluded(attacker_id, defender_id, atk_dmg, def_dmg))

	# Apply both damage packets first (deal_damage no longer auto-destroys),
	# then check fatalities on both after — true simultaneity.
	events.append_array(GameLogic.deal_damage(state, attacker_id, defender_id, atk_dmg, db))
	events.append_array(GameLogic.deal_damage(state, defender_id, attacker_id, def_dmg, db))
	_clear_damage_prevention(state)   # combat over — unspent block expires

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


# ── Graveyard search (generic query API) ──────────────────────────────────────
#
# Effects segments: graveyard_to_hand:TYPE:MIN:MAX:OWNER[:MAX_COST]
#                    graveyard_to_rfg:TYPE:MIN:MAX:OWNER[:MAX_COST]
#   TYPE     — card_type filter ("Ally", "Ability", …) or "any"
#   MIN/MAX  — how many cards must/may be chosen (min=max for exact counts)
#   OWNER    — whose graveyard(s): "own", "opponent", or "both"
#   MAX_COST — optional printed-cost ceiling (omit or -1 for no limit)
# _to_hand returns the chosen cards to the controller's hand;
# _to_rfg removes them from the game (rule 415.7 — owner's RFG zone).

# Parse the graveyard-search requirement off a card def. {} if the def has none.
static func get_graveyard_search_requirement(def: CardDef) -> Dictionary:
	if not def or def.effects == "":
		return {}
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		var key := parts[0].strip_edges()
		if parts.size() >= 5 and (key == "graveyard_to_hand" or key == "graveyard_to_rfg" \
				or key == "graveyard_to_play"):
			var dest := "hand"
			if key == "graveyard_to_rfg":
				dest = "rfg"
			elif key == "graveyard_to_play":
				dest = "play"
			return {
				"card_type": parts[1].strip_edges(),
				"min_count": int(parts[2]),
				"max_count": int(parts[3]),
				"owner":     parts[4].strip_edges(),
				"max_cost":  int(parts[5]) if parts.size() >= 6 else -1,
				"dest":      dest,
				"source":    "graveyard",
			}
		# Deck search (The Missing Diplomat): deck_to_hand:TYPE:MIN:MAX[:MAX_COST].
		# Always searches the completer's own deck; the deck is shuffled afterward
		# (rule 413.2). MIN 0 means the reward may find nothing (rule 413.3) — the
		# quest still completes, it just does nothing.
		if parts.size() >= 4 and key == "deck_to_hand":
			return {
				"card_type": parts[1].strip_edges(),
				"min_count": int(parts[2]),
				"max_count": int(parts[3]),
				"owner":     "own",
				"max_cost":  int(parts[4]) if parts.size() >= 5 else -1,
				"dest":      "hand",
				"source":    "deck",
			}
	return {}


# Minimum ally-row party size required to complete a quest (e.g. The Defias
# Brotherhood: "require_ally_count:4"). Returns 0 if the quest has no such gate.
static func get_quest_ally_count_requirement(def: CardDef) -> int:
	if not def or def.effects == "":
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() >= 2 and parts[0].strip_edges() == "require_ally_count":
			return int(parts[1])
	return 0


# Torek's Assault-style condition: an opposing hero must have been dealt
# damage this turn by an ally in the quest controller's party.
static func quest_requires_hero_damaged_by_ally(def: CardDef) -> bool:
	if not def or def.effects == "":
		return false
	for entry in def.effects.split("|"):
		if entry.strip_edges() == "require_hero_damaged_by_ally":
			return true
	return false


# Engine-only restriction (NOT in the printed rules — see data/rules_deviations.md):
# some quests are only ever useful on the controller's own turn (e.g. For the
# Horde!, whose reward only affects attacking allies). Restricting completion
# to the turn player also lets the AI skip evaluating them off-turn.
static func quest_requires_turn_player(def: CardDef) -> bool:
	if not def or def.effects == "":
		return false
	for entry in def.effects.split("|"):
		if entry.strip_edges() == "require_turn_player":
			return true
	return false


# All graveyard cards matching a requirement, from player_id's point of view.
static func get_graveyard_search_candidates(state: GameState, player_id: String,
		req: Dictionary, db) -> Array[String]:
	var result: Array[String] = []
	if req.is_empty() or not db:
		return result
	# Deck-search rewards (The Missing Diplomat) look through the completer's own
	# deck rather than a graveyard. Same type/cost filtering below.
	var zone_suffix := "_graveyard"
	if req.get("source", "graveyard") == "deck":
		zone_suffix = "_deck"
	var owner: String = req.get("owner", "own")
	var gy_players: Array[String] = []
	if owner == "own" or owner == "both":
		gy_players.append(player_id)
	if owner == "opponent" or owner == "both":
		gy_players.append(_other_player(state, player_id))
	var type_filter: String = req.get("card_type", "any")
	var max_cost: int = req.get("max_cost", -1)
	for gy_player in gy_players:
		for card in state.cards_in_zone(gy_player + zone_suffix):
			var def := db.get_def(card.card_def_id) as CardDef
			if not def:
				continue
			if type_filter != "any" and type_filter != "" \
					and def.card_type != type_filter and def.card_subtype != type_filter:
				continue
			if max_cost >= 0 and def.cost > max_cost:
				continue
			result.append(card.instance_id)
	return result


# Probe: could this quest be completed if valid graveyard targets were supplied?
# Used by UI highlights and AI before the player has chosen targets.
static func can_use_quest_no_target_check(state: GameState, quest_id: String,
		player_id: String, db) -> bool:
	var probe := PendingAction.make("use_quest", player_id,
			{"quest_id": quest_id, "_skip_target_check": true})
	return can_submit(state, probe, db)


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
	# Can't chain this quest's completion with itself while it's already pending.
	for pending in state.pending_actions:
		var p_action := pending as PendingAction
		if p_action and p_action.action_type == "use_quest" \
				and p_action.params.get("quest_id", "") == quest_id:
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
	# Party-size gating condition (e.g. The Defias Brotherhood: 4+ allies).
	var ally_req := get_quest_ally_count_requirement(def)
	if ally_req > 0 \
			and state.cards_in_zone(action.source_player + "_ally_row").size() < ally_req:
		return false
	# Torek's Assault-style condition: opposing hero damaged by our ally this turn.
	if quest_requires_hero_damaged_by_ally(def):
		var opp_ps := state.players.get(_other_player(state, action.source_player)) as PlayerState
		if not opp_ps or not opp_ps.hero_damaged_by_ally_this_turn:
			return false
	# Engine-only deviation — see data/rules_deviations.md.
	if quest_requires_turn_player(def) and state.turn_player != action.source_player:
		return false
	# Graveyard-target rewards: targets are announced with the completion (rule 601-style
	# targeting) and must be legal now. Blocked entirely when too few candidates exist.
	var gy_req := get_graveyard_search_requirement(def)
	if not gy_req.is_empty():
		var candidates := get_graveyard_search_candidates(state, action.source_player, gy_req, db)
		if candidates.size() < int(gy_req.get("min_count", 1)):
			return false
		if action.params.get("_skip_target_check", false):
			return true
		var targets: Array = action.params.get("target_ids", [])
		if targets.size() < int(gy_req.get("min_count", 1)) \
				or targets.size() > int(gy_req.get("max_count", 1)):
			return false
		for tid in targets:
			if tid not in candidates or targets.count(tid) > 1:
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
			events.append_array(_apply_quest_reward(state, action.source_player, def.effects, db,
					action.params.get("target_ids", [])))

	return events


# Parse and execute a quest reward string. Format: "key:value" entries, pipe-separated.
# Effects that require player input (discard_from_hand) set pending state and emit
# a choice event; the caller must handle that event before continuing.
static func _apply_quest_reward(state: GameState, player_id: String,
		effects_str: String, db, target_ids: Array = []) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if effects_str == "":
		return events
	for entry in effects_str.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() < 2:
			continue
		match parts[0].strip_edges():
			"party_buff_atk_attacking":
				# For the Horde!: "Horde allies in your party have +X ATK
				# while attacking this turn." Tracked player-side (not
				# per-card) so it also covers Horde allies that enter play
				# later this turn.
				var amount := int(parts[1])
				var ps := state.players.get(player_id) as PlayerState
				if ps:
					ps.party_atk_buffs_this_turn.append({"amount": amount, "alignment": "Horde"})
					events.append(GameEvent.party_atk_buff_added(player_id, amount, "Horde"))
			"draw":
				var n := int(parts[1])
				for _i in n:
					events.append_array(_draw_one(state, player_id))
			"discard_from_hand":
				var n := int(parts[1])
				state.pending_discard_player = player_id
				state.pending_discard_count  = n
				events.append(GameEvent.discard_choice_opened(player_id, n))
			"graveyard_to_hand":
				# Targets were validated at announcement; re-check they are still
				# in a graveyard at resolution (fizzle per-card otherwise).
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "graveyard":
						continue
					events.append_array(GameLogic.move_card(state, tid, player_id + "_hand"))
					events.append(GameEvent.card_returned_from_graveyard(tid, player_id))
			"graveyard_to_play":
				# Finkle Einhorn: put a chosen ally from graveyard directly into
				# play. Re-check each target is still in a graveyard, set its
				# controller to the completer, then bring it into play so its
				# enter-play triggers fire exactly as if played from hand.
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "graveyard":
						continue
					t_card.controller = player_id
					events.append_array(_bring_ally_into_play(state, tid, db))
			"graveyard_to_rfg":
				# Same re-check as graveyard_to_hand; cards go to their owner's
				# RFG zone (rule 415.7a) instead of the hand.
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "graveyard":
						continue
					events.append_array(GameLogic.move_card(state, tid, t_card.owner + "_rfg"))
					events.append(GameEvent.card_removed_from_game(tid, player_id))
			"reveal_pick":
				# Big Game Hunter / Kibler's Exotic Pets / Zapped Giants: reveal the
				# top N cards; the controller puts a revealed card of the required
				# type into hand and the rest go to the bottom of the deck. The pick
				# is a mandatory post-resolution choice (choose_reveal_pick) when at
				# least one matching card is revealed.
				var want_type := parts[1].strip_edges()
				var reveal_n := int(parts[2]) if parts.size() > 2 else 1
				events.append_array(_reveal_pick(state, player_id, want_type, reveal_n, db))
			"deck_to_hand":
				# The Missing Diplomat: search your deck, reveal the chosen ally,
				# put it into your hand. Re-check each target is still in the
				# player's deck at resolution (fizzle per-card otherwise). Rule
				# 413.2/415.3b: the owner shuffles the deck after the search — do
				# so even if no card was found (the deck was still searched).
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "deck":
						continue
					events.append(GameEvent.card_revealed_from_deck(tid, player_id))
					events.append_array(GameLogic.move_card(state, tid, player_id + "_hand"))
				# The deck is always searched when this reward runs, even if the
				# player found nothing to take.
				var deck_zone := state.zones.get(player_id + "_deck") as Zone
				if deck_zone:
					deck_zone.card_ids.shuffle()
					events.append(GameEvent.make("deck_shuffled", {"player": player_id}))
	return events


# Reveal the top N cards of the player's deck for a "reveal_pick" quest reward.
# Cards stay physically at the top of the deck; if any match `want_type`, set the
# pending choice and emit reveal_pick_opened (the scene resolves it via
# choose_reveal_pick). If none match, all revealed cards go straight to the
# bottom of the deck with no choice.
static func _reveal_pick(state: GameState, player_id: String, want_type: String,
		n: int, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var deck := state.zones.get(player_id + "_deck") as Zone
	if not deck or deck.card_ids.is_empty():
		events.append(GameEvent.make("deck_empty", {"player": player_id}))
		return events
	var count: int = min(n, deck.card_ids.size())
	var revealed: Array[String] = []
	for i in count:
		revealed.append(deck.card_ids[i])
	var selectable: Array[String] = []
	for cid in revealed:
		events.append(GameEvent.card_revealed_from_deck(cid, player_id))
		var c := state.get_card(cid)
		var d := db.get_def(c.card_def_id) as CardDef if c and db else null
		if d and d.card_type == want_type:
			selectable.append(cid)
	if selectable.is_empty():
		# Nothing of the required type — put every revealed card on the bottom in
		# revealed order (deck→deck move erases from the top and appends to the end).
		for cid in revealed:
			events.append_array(GameLogic.move_card(state, cid, player_id + "_deck"))
		return events
	state.pending_reveal_pick_player = player_id
	state.pending_reveal_pick_ids = selectable
	state.pending_reveal_pick_all = revealed
	events.append(GameEvent.reveal_pick_opened(player_id, selectable, revealed, want_type))
	return events


# Entry point: the controller has chosen which revealed card to keep. The picked
# card goes to hand; every other revealed card goes to the bottom of the deck in
# revealed order. Called directly by the scene (not via submit_action), like
# choose_pet_sacrifice. card_id must be one of the selectable (matching) cards.
static func choose_reveal_pick(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_reveal_pick_player == "":
		return []
	if card_id not in state.pending_reveal_pick_ids:
		return []   # must pick a card of the required type
	var player_id := state.pending_reveal_pick_player
	var revealed := state.pending_reveal_pick_all.duplicate()
	# Clear pending state up front so subsequent moves can't re-enter this path.
	state.pending_reveal_pick_player = ""
	state.pending_reveal_pick_ids = []
	state.pending_reveal_pick_all = []

	var events: Array[GameEvent] = []
	events.append_array(GameLogic.move_card(state, card_id, player_id + "_hand"))
	events.append(GameEvent.make("reveal_pick_resolved", {
		"player": player_id, "card_id": card_id,
	}))
	for cid: String in revealed:
		if cid == card_id:
			continue
		events.append_array(GameLogic.move_card(state, cid, player_id + "_deck"))
	return events


# Entry point: player (or AI) has chosen a card to discard.
static func choose_discard(state: GameState, card_id: String,
		_db = null) -> Array[GameEvent]:
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


# ── Discard-or-give-control choice (Infernal) ─────────────────────────────────
# "At the start of your turn, discard a card, or target opponent gains control
# of [this]." Called directly by the scene (not via submit_action), like
# choose_pet_sacrifice — but unlike a mandatory discard, the player may decline.

# Player chose to discard a hand card and keep control of the source.
static func choose_control_discard(state: GameState, card_id: String,
		_db = null) -> Array[GameEvent]:
	if state.pending_control_discard_player == "" \
			or state.pending_control_discard_ids.is_empty():
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_control_discard_player:
		return []
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return []

	var events: Array[GameEvent] = []
	events.append_array(GameLogic.discard_card(state, card_id))
	state.pending_control_discard_ids.pop_front()
	_advance_control_discard_queue(state, events)
	return events


# Player declined to discard — the opponent gains control of the source
# (rule 401.3: the new controller moves it to his ally row). just_summoned is
# set because an ally can't attack or use powers unless it has been under its
# controller's control continuously since the start of their turn.
static func decline_control_discard(state: GameState,
		db = null) -> Array[GameEvent]:
	if state.pending_control_discard_player == "" \
			or state.pending_control_discard_ids.is_empty():
		return []
	var events: Array[GameEvent] = []
	var source_id: String = state.pending_control_discard_ids.pop_front()
	var source := state.get_card(source_id)
	if source and state.is_in_play(source_id):
		var old_ctrl := source.controller
		var new_ctrl := _other_player(state, old_ctrl)
		source.controller = new_ctrl
		source.just_summoned = true
		events.append_array(GameLogic.move_card(state, source_id, new_ctrl + "_ally_row"))
		events.append(GameEvent.control_changed(source_id, old_ctrl, new_ctrl))
		# The source may be a Pet (Infernal is) — new controller's pet capacity
		# can now be violated exactly as if a second pet entered play.
		events.append_array(_check_pet_uniqueness(state, source_id, db))
	_advance_control_discard_queue(state, events)
	return events


static func _advance_control_discard_queue(state: GameState,
		events: Array[GameEvent]) -> void:
	if state.pending_control_discard_ids.is_empty():
		state.pending_control_discard_player = ""
	else:
		events.append(GameEvent.control_discard_choice_opened(
			state.pending_control_discard_player,
			state.pending_control_discard_ids[0]))


static func choose_pet_sacrifice(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_pet_sacrifice_player == "":
		return []
	if card_id not in state.pending_pet_sacrifice_ids:
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_pet_sacrifice_player:
		return []
	return _resolve_choose_pet_sacrifice(state,
		PendingAction.make("choose_pet_sacrifice", state.pending_pet_sacrifice_player,
			{"card_id": card_id}),
		db)


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
	# Hero powers are instants by default (rule 701.3) — usable any time player has
	# priority, INCLUDING in response to something already on the chain (so a player
	# can react to e.g. Ta'zo's damage power). Powers with "on_your_turn" in effects
	# are sorcery-speed: they also require turn player + action phase + empty chain
	# (that empty-chain gate is applied in the "on_your_turn" block below).
	if state.priority_player != action.source_player:
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
		if not state.pending_actions.is_empty():
			return false
	# Must be able to afford the cost.
	var cost: int = max(def.cost, 0)
	if cost > state.get_available_resources(action.source_player):
		return false
	# If this power targets something, the target must be valid.
	var target_id: String = action.params.get("target_id", "")
	var is_gy_power := _power_effect_is(def, "graveyard_to_hand")
	if target_id != "" and not is_gy_power:
		if not _is_legal_target(state, target_id, db):
			return false
	if is_gy_power:
		var gy_req := get_graveyard_search_requirement(def)
		if gy_req.is_empty():
			return false
		var gy_candidates := get_graveyard_search_candidates(state, action.source_player, gy_req, db)
		if gy_candidates.size() < int(gy_req.get("min_count", 1)):
			return false
		if target_id != "" and target_id not in gy_candidates:
			return false
	if _power_effect_is(def, "deal_damage_and_heal"):
		# target_id = damage target, heal_target_id = heal target; both must be in play and different.
		if target_id != "":
			var heal_target_id: String = action.params.get("heal_target_id", "")
			# Heals are targeted too ("target hero or ally") — Untargetable blocks them.
			if not _is_legal_target(state, heal_target_id, db):
				return false
			if heal_target_id == target_id:
				return false
	# destroy_exhausted_ally: target must be an exhausted ally (not a hero).
	if _power_effect_is(def, "destroy_exhausted_ally"):
		if target_id == "":
			# Pre-targeting probe: pass if any exhausted enemy ally exists.
			var opp3 := "p2" if action.source_player == "p1" else "p1"
			var has_exhausted_ally := false
			for tc: CardInstance in state.cards_in_play(opp3):
				var tz := state.zones.get(tc.zone_id) as Zone
				if tz and tz.zone_type == "ally_row" and tc.is_exhausted:
					has_exhausted_ally = true
					break
			if not has_exhausted_ally:
				return false
		else:
			var t_card := state.get_card(target_id)
			if not t_card or not t_card.is_exhausted:
				return false
			var t_zone := state.zones.get(t_card.zone_id) as Zone
			if not t_zone or t_zone.zone_type != "ally_row":
				return false
	# deal_7_minus_hand_to_hero: target must be a hero (in hero_row).
	if _power_effect_is(def, "deal_7_minus_hand_to_hero"):
		if target_id == "":
			# Pre-targeting probe: pass if there's at least one enemy hero alive.
			var opp2 := "p2" if action.source_player == "p1" else "p1"
			var ps2 := state.players.get(opp2) as PlayerState
			if not ps2 or ps2.hero_instance_id == "" or not state.is_in_play(ps2.hero_instance_id):
				return false
		else:
			var t_card2 := state.get_card(target_id)
			if not t_card2:
				return false
			var t_zone2 := state.zones.get(t_card2.zone_id) as Zone
			if not t_zone2 or t_zone2.zone_type != "hero_row":
				return false
	# deal_x_damage_to_ally: target must be an ally, x_value >= 1, hero must survive the self-damage.
	if _power_effect_is(def, "deal_x_damage_to_ally"):
		if target_id == "":
			# Pre-targeting probe (context menu): check hero can survive x=1 and a valid target exists.
			if state.get_current_hp(hero_id, db) <= 1:
				return false
			var opp := "p2" if action.source_player == "p1" else "p1"
			var has_target := false
			for tc: CardInstance in state.cards_in_play(opp):
				var tz := state.zones.get(tc.zone_id) as Zone
				if tz and tz.zone_type == "ally_row":
					has_target = true
					break
			if not has_target:
				return false
		else:
			var t_card := state.get_card(target_id)
			if not t_card:
				return false
			var t_zone := state.zones.get(t_card.zone_id) as Zone
			if not t_zone or t_zone.zone_type != "ally_row":
				return false
			var x_value: int = action.params.get("x_value", 0)
			if x_value < 1:
				return false
			if x_value >= state.get_current_hp(hero_id, db):
				return false
	if _power_effect_is(def, "heal_x_from_target"):
		if target_id == "":
			# Pre-targeting probe: need at least 1 resource and a valid target in play.
			if state.get_available_resources(action.source_player) < 1:
				return false
		else:
			if not state.is_in_play(target_id):
				return false
			var x_value: int = action.params.get("x_value", 0)
			if x_value < 1:
				return false
			if x_value > state.get_available_resources(action.source_player):
				return false
	if _power_effect_is(def, "radak_pet_sacrifice"):
		var pet_id: String = action.params.get("pet_id", "")
		if pet_id == "" and target_id == "":
			# Pre-targeting probe: need at least one Pet whose cost we can afford.
			var affordable_pet := false
			var avail := state.get_available_resources(action.source_player)
			for c in state.cards_in_zone(action.source_player + "_ally_row"):
				var d := db.get_def(c.card_def_id) as CardDef
				if d and d.card_subtype == "Pet" and d.cost >= 1 and d.cost <= avail:
					affordable_pet = true
					break
			if not affordable_pet:
				return false
		elif pet_id != "" and target_id == "":
			# Phase 1→2 probe: pet must be owned, in play, and its cost must be affordable.
			if not state.is_in_play(pet_id):
				return false
			var pet_card := state.get_card(pet_id)
			if not pet_card or pet_card.controller != action.source_player:
				return false
			var pet_def := db.get_def(pet_card.card_def_id) as CardDef
			if not pet_def or pet_def.card_subtype != "Pet":
				return false
			if pet_def.cost < 1 or pet_def.cost > state.get_available_resources(action.source_player):
				return false
		else:
			# Full action: validate pet, resource cost, and damage target.
			if not state.is_in_play(pet_id) or not state.is_in_play(target_id):
				return false
			var pet_card2 := state.get_card(pet_id)
			if not pet_card2 or pet_card2.controller != action.source_player:
				return false
			var pet_def2 := db.get_def(pet_card2.card_def_id) as CardDef
			if not pet_def2 or pet_def2.card_subtype != "Pet":
				return false
			var x_value: int = action.params.get("x_value", 0)
			if x_value < 1 or x_value != pet_def2.cost:
				return false
			if x_value > state.get_available_resources(action.source_player):
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
				# Rule 706 re-check: fizzle if the target left play or became Untargetable.
				if not _is_legal_target(state, target_id, db):
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
			"deal_7_minus_hand_to_hero":
				# Format: deal_7_minus_hand_to_hero:DMG_TYPE
				# Damage = max(7 - hand size of target hero's controller, 0).
				if _is_legal_target(state, target_id, db):
					var t_card := state.get_card(target_id)
					var hand_size := state.cards_in_zone(t_card.controller + "_hand").size()
					var amount2: int = max(7 - hand_size, 0)
					if amount2 > 0:
						events.append_array(GameLogic.deal_damage(
							state, hero_id, target_id, amount2, db))
						if state.get_current_hp(target_id, db) <= 0:
							events.append(GameEvent.game_over(
								_other_player(state, t_card.controller), t_card.controller))
			"deal_x_damage_to_ally":
				# Format: deal_x_damage_to_ally:DMG_TYPE
				# x_value is chosen by the player; paid as self-damage before effect resolves.
				var x_value: int = action.params.get("x_value", 0)
				if x_value >= 1 and _is_legal_target(state, target_id, db):
					# Self-damage on the hero (paid as part of cost).
					events.append_array(GameLogic.deal_damage(state, hero_id, hero_id, x_value, db))
					# Damage to target ally.
					events.append_array(GameLogic.deal_damage(state, hero_id, target_id, x_value, db))
					var t_card := state.get_card(target_id)
					if t_card and state.get_current_hp(target_id, db) <= 0:
						events.append_array(_check_destroyed_trigger(state, target_id, hero_id, db))
			"target_cant_attack":
				# Litori Frostburn: "Target hero or ally can't attack this turn."
				# Rule 706 re-check: fizzle if the target left play or became Untargetable.
				# Does NOT remove an existing attacker from combat (602.4) — its bite
				# is via the 601.3 legality recheck when played in response to a
				# combat proposal still on the chain.
				if _is_legal_target(state, target_id, db):
					var ca_card := state.get_card(target_id)
					ca_card.active_buffs.append(Buff.make(
						"cant_attack_this_turn", hero_id, "cannot_attack", 1, "turns", 1))
					events.append(GameEvent.cant_attack_applied(target_id, hero_id))
			"heal_x_from_target":
				# X resources are already paid at submission. Heal X from target.
				var x_value: int = action.params.get("x_value", 0)
				if x_value >= 1 and _is_legal_target(state, target_id, db):
					events.append_array(GameLogic.heal(state, target_id, x_value, db, hero_id))
			"graveyard_to_hand":
				# Format: graveyard_to_hand:TYPE:MIN:MAX:OWNER[:MAX_COST] (hero-power use).
				# Re-check the target is still in a graveyard at resolution.
				if target_id != "":
					var gy_card := state.get_card(target_id)
					if gy_card:
						var gy_zone := state.zones.get(gy_card.zone_id) as Zone
						if gy_zone and gy_zone.zone_type == "graveyard":
							events.append_array(GameLogic.move_card(state, target_id, action.source_player + "_hand"))
							events.append(GameEvent.card_returned_from_graveyard(target_id, action.source_player))
			"radak_pet_sacrifice":
				# Pet already destroyed at submission. Deal x_value shadow damage to target.
				var x_value: int = action.params.get("x_value", 0)
				if x_value >= 1 and _is_legal_target(state, target_id, db):
					events.append_array(GameLogic.deal_damage(state, hero_id, target_id, x_value, db))
					var t_card := state.get_card(target_id)
					if t_card and state.get_current_hp(target_id, db) <= 0:
						var t_zone := state.zones.get(t_card.zone_id) as Zone
						if t_zone and t_zone.zone_type == "hero_row":
							events.append(GameEvent.game_over(
								_other_player(state, t_card.controller), t_card.controller))
						else:
							events.append_array(_check_destroyed_trigger(state, target_id, hero_id, db))
			"melee_strike_discount":
				# Gorebelly: "You pay (3) less the next time you strike with a
				# Melee weapon this turn." Consumed by the next melee strike;
				# cleared at the start of every turn.
				var disc_amount := int(parts[1]) if parts.size() > 1 else 0
				var disc_ps := state.players.get(action.source_player) as PlayerState
				if disc_ps and disc_amount > 0:
					disc_ps.melee_strike_discount += disc_amount
					events.append(GameEvent.strike_discount_gained(
						action.source_player, disc_amount))
			"ranged_weapon_atk_bonus":
				# Elendril: "Your Ranged weapons have +3 ATK this turn." Player-
				# tracked (PlayerState.ranged_weapon_atk_bonus), applied in
				# GameState.get_atk; cleared at the start of every turn.
				var rw_amount := int(parts[1]) if parts.size() > 1 else 0
				var rw_ps := state.players.get(action.source_player) as PlayerState
				if rw_ps and rw_amount != 0:
					rw_ps.ranged_weapon_atk_bonus += rw_amount
					events.append(GameEvent.ranged_weapon_bonus_gained(
						action.source_player, rw_amount))
			"shuffle_hand_draw":
				events.append_array(
					GameLogic.shuffle_hand_into_deck_and_draw(state, action.source_player))
			"destroy_exhausted_ally":
				if _is_legal_target(state, target_id, db):
					events.append_array(_destroy_card_trigger(state, target_id, hero_id, db))
			"deal_damage_and_heal":
				# Format: deal_damage_and_heal:DMG_AMOUNT:DMG_TYPE:HEAL_AMOUNT
				var dmg_amount  := int(parts[1]) if parts.size() > 1 else 0
				var heal_amount := int(parts[3]) if parts.size() > 3 else 0
				var heal_target_id: String = action.params.get("heal_target_id", "")
				if _is_legal_target(state, target_id, db):
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
				if _is_legal_target(state, heal_target_id, db):
					events.append_array(GameLogic.heal(state, heal_target_id, heal_amount, db, hero_id))
	return events


# ── Enters-play targeted effect ────────────────────────────────────────────────

static func _can_choose_enter_play_target(state: GameState, action: PendingAction,
		db = null) -> bool:
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
	if not _is_legal_target(state, target_id, db):
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
			# Rule 706 re-check: fizzle if the target left play or became Untargetable.
			if not _is_legal_target(state, target_id, db):
				return events
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


# ── Ongoing Totem "start of each turn" targeted damage (Searing Totem) ──────────
# A direct-call mandatory choice (like choose_strike / choose_reveal_pick), NOT a
# chain action — the trigger fires during the ready step, outside normal priority.

# Peek the front pending totem trigger, skipping any whose source left play
# (711.1), and mark its controller as the player who must pick a target. Returns
# the totem_target_required event, or [] (and clears the pending marker) when the
# queue is empty. Called by turn-start collection and after each resolution.
static func _open_next_totem_trigger(state: GameState, db) -> Array[GameEvent]:
	while not state.pending_ongoing_triggers.is_empty():
		var trigger: Dictionary = state.pending_ongoing_triggers[0]
		var source_id: String = trigger.get("card_id", "")
		var source := state.get_card(source_id)
		if not source or not state.is_in_play(source_id):
			state.pending_ongoing_triggers.pop_front()
			continue
		state.pending_totem_target_player = source.controller
		return [GameEvent.totem_target_required(
			source_id, source.controller,
			trigger.get("dmg_type", ""), int(trigger.get("amount", 0)))]
	state.pending_totem_target_player = ""
	return []


# Resolve the active totem trigger: the controller deals its damage to the chosen
# hero or ally, then the next queued trigger (if any) opens. target_id must be a
# legal hero or ally in play. Direct call — no chain, no priority pass.
static func choose_totem_target(state: GameState, target_id: String, db) -> Array[GameEvent]:
	if state.pending_totem_target_player == "" or state.pending_ongoing_triggers.is_empty():
		return []
	var trigger: Dictionary = state.pending_ongoing_triggers.pop_front()
	state.pending_totem_target_player = ""
	var source_id: String = trigger.get("card_id", "")
	var amount := int(trigger.get("amount", 0))
	var events: Array[GameEvent] = []
	# 706 re-check: the source must still be in play and the target legal.
	if state.is_in_play(source_id) and amount > 0 and _is_legal_target(state, target_id, db):
		events.append_array(GameLogic.deal_damage(state, source_id, target_id, amount, db))
		var t_card := state.get_card(target_id)
		if t_card and state.get_current_hp(target_id, db) <= 0:
			var t_zone := state.zones.get(t_card.zone_id) as Zone
			if t_zone and t_zone.zone_type == "hero_row":
				events.append(GameEvent.game_over(
					_other_player(state, t_card.controller), t_card.controller))
			else:
				events.append_array(_check_destroyed_trigger(state, target_id, source_id, db))
	# Open the next queued totem trigger, if any.
	events.append_array(_open_next_totem_trigger(state, db))
	return events


# Legal targets for a totem trigger: every hero and ally in play (rule: "target
# hero or ally"), subject to the standard targeting restrictions (untargetable).
static func get_totem_targets(state: GameState, db) -> Array[String]:
	var result: Array[String] = []
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "" and _is_legal_target(state, ps.hero_instance_id, db):
			result.append(ps.hero_instance_id)
		for ally in state.cards_in_zone(pid + "_ally_row"):
			if _is_legal_target(state, ally.instance_id, db):
				result.append(ally.instance_id)
	return result


# ── Helpers ────────────────────────────────────────────────────────────────────

static func _other_player(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id


# Controller of the source card of the pending enters-play effect.
# Falls back to the turn player if the source card can't be resolved.
static func _pending_effect_controller(state: GameState) -> String:
	var src := state.get_card(state.pending_enter_play_effect.get("card_id", ""))
	return src.controller if src else state.turn_player


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
	var card := state.get_card(card_id)
	var controller := card.controller if card else ""
	var events := GameLogic.check_destroyed(state, card_id, source_id, db)
	for e in events:
		if e.event_type == "card_destroyed" and e.payload.get("card", "") == card_id:
			events.append_array(_fire_on_destroyed(state, card_id, db))
			if controller != "":
				events.append_array(_check_aura_loss_deaths(state, controller, card_id, db))
			break
	return events


# When a card leaves play, any max-health aura it granted (party_health_aura,
# pet_atk_health_aura, ...) disappears immediately. Allies that were only
# alive because of that bonus must die now (rule 118.4/704 state-based death),
# not survive until the next damage event. Re-checks the departed card's own
# controller's board for anyone now at 0 or fewer effective health.
static func _check_aura_loss_deaths(state: GameState, controller: String,
		source_id: String, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	for card in state.cards_in_zone(controller + "_ally_row"):
		if state.get_current_hp(card.instance_id, db) <= 0:
			events.append_array(_check_destroyed_trigger(state, card.instance_id, source_id, db))
	return events


# Wrapper: destroy_card always fires on_destroyed (explicit removal effect).
# Heroes are a special case — an explicit destroy effect on a hero ends the game
# (that hero's controller loses) and the hero does NOT move to the graveyard.
static func _destroy_card_trigger(state: GameState, card_id: String,
		source_id: String, db) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if card and state.is_in_play(card_id) and db:
		var cdef := db.get_def(card.card_def_id) as CardDef
		if cdef and cdef.card_type == "Hero":
			var loser := card.controller
			var winner := "p2" if loser == "p1" else "p1"
			return [GameEvent.game_over(winner, loser)]
	var controller := card.controller if card else ""
	var events := GameLogic.destroy_card(state, card_id, source_id)
	if not events.is_empty():
		events.append_array(_fire_on_destroyed(state, card_id, db))
		if controller != "":
			events.append_array(_check_aura_loss_deaths(state, controller, card_id, db))
	return events


# ── Pet uniqueness (rule 414.3b) ──────────────────────────────────────────────

static func _check_pet_uniqueness(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.card_subtype != "Pet":
		return []
	# Gather all pets in controller's ally_row (only ally_row counts — 414.1).
	var pet_ids: Array[String] = []
	for c in state.cards_in_zone(card.controller + "_ally_row"):
		var d := db.get_def(c.card_def_id) as CardDef
		if d and d.card_subtype == "Pet":
			pet_ids.append(c.instance_id)
	var ps := state.players.get(card.controller) as PlayerState
	var capacity: int = ps.pet_capacity if ps else 1
	if pet_ids.size() <= capacity:
		return []
	# Violation: player must sacrifice until at most pet_capacity pets remain.
	state.pending_pet_sacrifice_player = card.controller
	state.pending_pet_sacrifice_ids.assign(pet_ids)
	var typed_ids: Array[String] = []
	typed_ids.assign(pet_ids)
	return [GameEvent.pet_sacrifice_required(card.controller, typed_ids)]


static func _can_choose_pet_sacrifice(state: GameState, action: PendingAction) -> bool:
	if state.pending_pet_sacrifice_player == "":
		return false
	if action.source_player != state.pending_pet_sacrifice_player:
		return false
	var chosen: String = action.params.get("card_id", "")
	return chosen in state.pending_pet_sacrifice_ids


static func _resolve_choose_pet_sacrifice(state: GameState, action: PendingAction,
		db) -> Array[GameEvent]:
	var chosen: String = action.params.get("card_id", "")
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(state, chosen, chosen, db))
	state.pending_pet_sacrifice_ids.erase(chosen)
	# Re-check: still a violation if more pets remain than capacity allows.
	var ps2 := state.players.get(state.pending_pet_sacrifice_player) as PlayerState
	var capacity2: int = ps2.pet_capacity if ps2 else 1
	var surviving_pets: Array[String] = []
	for cid in state.pending_pet_sacrifice_ids:
		if state.is_in_play(cid):
			surviving_pets.append(cid)
	if surviving_pets.size() <= capacity2:
		state.pending_pet_sacrifice_player = ""
		state.pending_pet_sacrifice_ids.clear()
	else:
		state.pending_pet_sacrifice_ids.assign(surviving_pets)
		var typed_ids: Array[String] = []
		typed_ids.assign(surviving_pets)
		events.append(GameEvent.pet_sacrifice_required(
			state.pending_pet_sacrifice_player, typed_ids))
	return events


# ── Equipment slot uniqueness (rule 414.3) ────────────────────────────────────
# Only one equipment may occupy a given slot (Chest, Back, Neck, …). When a
# second same-slot equipment enters play, the controller must destroy equipment
# until only one remains — mirrors the Pet uniqueness immediate-choice flow.

static func _check_equipment_uniqueness(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return []
	var info := _equipment_info(def)
	var slot: String = info.get("slot", "")
	if slot == "":
		return []
	# Gather all equipment in the controller's hero row that conflicts with this
	# card: same slot (414.3), or Two-Handed vs Off-Hand (414.3c — a Two-Handed
	# weapon carries the `two_handed` effects flag and occupies both hands, so it
	# can't coexist with an off_hand-slot equipment).
	var two_handed := _has_effect_flag(def, "two_handed")
	var same_slot_ids: Array[String] = []
	for c in state.cards_in_zone(card.controller + "_hero_row"):
		var d := db.get_def(c.card_def_id) as CardDef
		if not d or d.card_type != "Equipment":
			continue
		var d_slot: String = _equipment_info(d).get("slot", "")
		if d_slot == slot \
				or (two_handed and d_slot == "off_hand") \
				or (slot == "off_hand" and _has_effect_flag(d, "two_handed")):
			same_slot_ids.append(c.instance_id)
	if same_slot_ids.size() <= 1:
		return []
	state.pending_equip_sacrifice_player = card.controller
	state.pending_equip_sacrifice_ids.assign(same_slot_ids)
	var typed_ids: Array[String] = []
	typed_ids.assign(same_slot_ids)
	return [GameEvent.equipment_sacrifice_required(card.controller, typed_ids)]


# Called directly by the scene (not via submit_action), like choose_pet_sacrifice.
static func choose_equipment_sacrifice(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_equip_sacrifice_player == "":
		return []
	if card_id not in state.pending_equip_sacrifice_ids:
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_equip_sacrifice_player:
		return []
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(state, card_id, card_id, db))
	state.pending_equip_sacrifice_ids.erase(card_id)
	# Re-check: still a violation if more than one same-slot equipment remains.
	var surviving: Array[String] = []
	for cid in state.pending_equip_sacrifice_ids:
		if state.is_in_play(cid):
			surviving.append(cid)
	if surviving.size() <= 1:
		state.pending_equip_sacrifice_player = ""
		state.pending_equip_sacrifice_ids.clear()
	else:
		state.pending_equip_sacrifice_ids.assign(surviving)
		var typed_ids: Array[String] = []
		typed_ids.assign(surviving)
		events.append(GameEvent.equipment_sacrifice_required(
			state.pending_equip_sacrifice_player, typed_ids))
	return events


# ── Name-based uniqueness (rule 414.3a — the "Unique" tag) ────────────────────
# A player may not control two or more in-play cards that share a name and both
# carry the Unique tag (keywords column "Unique"). On violation the controller
# must destroy duplicates until only one same-named copy remains. Mirrors the Pet
# / Equipment uniqueness immediate-choice flow (non-interruptible; resolved via
# choose_unique_sacrifice(), a direct call — never through the chain).

static func _check_unique_uniqueness(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or "unique" not in def.keywords or def.card_name == "":
		return []
	# Gather every same-named Unique card this player controls in play. Unique
	# characters/equipment live in the ally_row or hero_row (414.1 — "in play").
	var dup_ids: Array[String] = []
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for c in state.cards_in_zone(card.controller + zone_suffix):
			var d := db.get_def(c.card_def_id) as CardDef
			if d and "unique" in d.keywords and d.card_name == def.card_name:
				dup_ids.append(c.instance_id)
	if dup_ids.size() <= 1:
		return []
	state.pending_unique_sacrifice_player = card.controller
	state.pending_unique_sacrifice_ids.assign(dup_ids)
	var typed_ids: Array[String] = []
	typed_ids.assign(dup_ids)
	return [GameEvent.unique_sacrifice_required(card.controller, typed_ids)]


# Called directly by the scene (not via submit_action), like choose_pet_sacrifice.
# card_id must be one of the same-named Unique cards in the violation set.
static func choose_unique_sacrifice(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_unique_sacrifice_player == "":
		return []
	if card_id not in state.pending_unique_sacrifice_ids:
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_unique_sacrifice_player:
		return []
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(state, card_id, card_id, db))
	state.pending_unique_sacrifice_ids.erase(card_id)
	# Re-check: still a violation if more than one same-named copy remains in play.
	var surviving: Array[String] = []
	for cid in state.pending_unique_sacrifice_ids:
		if state.is_in_play(cid):
			surviving.append(cid)
	if surviving.size() <= 1:
		state.pending_unique_sacrifice_player = ""
		state.pending_unique_sacrifice_ids.clear()
	else:
		state.pending_unique_sacrifice_ids.assign(surviving)
		var typed_ids: Array[String] = []
		typed_ids.assign(surviving)
		events.append(GameEvent.unique_sacrifice_required(
			state.pending_unique_sacrifice_player, typed_ids))
	return events
