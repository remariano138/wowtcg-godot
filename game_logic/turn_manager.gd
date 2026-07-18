class_name TurnManager
extends RefCounted

# Phase sequencing for a 2-player WoW TCG game.
#
# Call start_game() once to begin. Thereafter, call advance_phase() each
# time a priority_window_closed event fires to move to the next phase.
#
# Phase order per turn:
#   ready  → draw → action → end → (next player's ready …)
#
# Priority windows:
#   ready / draw / end  → instants only (enforced by _can_play_non_instant phase check)
#   action              → full window (allies, instants, resources, combat)


# ── Public entry points ────────────────────────────────────────────────────────

static func start_game(state: GameState, first_player: String,
		db = null) -> Array[GameEvent]:
	state.turn_number  = 1
	state.turn_player  = first_player
	state.first_player = first_player
	return _enter_mulligan(state, db)


# Called by the scene once per player when they commit their mulligan decision.
# When all players have decided, executes mulligans simultaneously and starts turn 1.
static func commit_mulligan(state: GameState, player_id: String,
		wants_mulligan: bool, db = null) -> Array[GameEvent]:
	if state.phase != "mulligan":
		return []
	state.mulligan_decided[player_id] = true
	state.mulligan_wants[player_id]   = wants_mulligan
	var events: Array[GameEvent] = [GameEvent.mulligan_committed(player_id, wants_mulligan)]

	# Check if all players have decided.
	var all_decided := true
	for pid in state.players:
		if not state.mulligan_decided.get(pid, false):
			all_decided = false
			break
	if not all_decided:
		return events

	# Execute all mulligans in two phases separated by mulligan_shuffle_done.
	# Phase 1: return cards and shuffle decks.
	var mulligan_pids: Array = []
	for pid in state.players:
		if state.mulligan_wants.get(pid, false):
			var hand := state.cards_in_zone(pid + "_hand").duplicate()
			for card in hand:
				events.append_array(GameLogic.move_card(state, card.instance_id, pid + "_deck"))
			var deck := state.zones.get(pid + "_deck") as Zone
			if deck:
				deck.card_ids.shuffle()
			mulligan_pids.append(pid)
	# Marker: renderer uses this to pause before the draw phase fires.
	events.append(GameEvent.mulligan_shuffle_done())
	# Phase 2: always redraw exactly STARTING_HAND_SIZE cards (rule 103.4).
	for pid in mulligan_pids:
		for _i in GameManager.STARTING_HAND_SIZE:
			events.append_array(_draw_one(state, pid))

	events.append(GameEvent.mulligan_phase_ended())
	events.append_array(_enter_ready(state, db))
	return events


static func advance_phase(state: GameState, db = null) -> Array[GameEvent]:
	match state.phase:
		"ready":  return _enter_draw(state, db)
		"draw":   return _enter_action(state, db)
		"action": return _enter_end(state, db)
		"end":    return _next_turn(state, db)
	return []


# ── Mulligan phase ─────────────────────────────────────────────────────────────

static func _enter_mulligan(state: GameState, _db) -> Array[GameEvent]:
	state.phase           = "mulligan"
	state.mulligan_decided = {}
	state.mulligan_wants   = {}
	# Player order: first player decides first, then opponents clockwise (2-player: just the two).
	var order: Array = [state.first_player]
	for pid in state.players:
		if pid != state.first_player:
			order.append(pid)
	return [GameEvent.mulligan_phase_started(state.first_player, order)]


# ── Phase transitions ──────────────────────────────────────────────────────────

static func _enter_ready(state: GameState, db) -> Array[GameEvent]:
	state.phase = "ready"
	var events: Array[GameEvent] = [GameEvent.turn_changed(state.turn_number, state.turn_player)]

	# Reset once-per-turn flags.
	var ps := state.players.get(state.turn_player) as PlayerState
	if ps:
		ps.resource_placed_this_turn = false
		# has_used_hero_power intentionally NOT reset here — using the hero power
		# "flips" the hero for the rest of the game; it cannot be reused.

	# Safety: leftover armor block never survives into a new turn (rule 304.3
	# block is scoped to the window/combat it was declared in).
	for pid in state.players:
		var p := state.players[pid] as PlayerState
		if p:
			p.damage_prevention = 0
			p.hero_damaged_by_ally_this_turn = false
			p.party_atk_buffs_this_turn.clear()
			# "This turn" strike discount (Gorebelly) never survives into a new turn.
			p.melee_strike_discount = 0
			# Elendril's "+3 ATK to Ranged weapons this turn" likewise expires.
			p.ranged_weapon_atk_bonus = 0

	# Clear summoning sickness and ready all in-play cards for the turn player.
	for card in state.cards_in_play(state.turn_player):
		card.just_summoned = false
		if _ready_blocked(state, card, db):
			continue
		events.append_array(GameLogic.ready_card(state, card.instance_id))
	for card in state.cards_in_zone(state.turn_player + "_resource_row"):
		events.append_array(GameLogic.ready_card(state, card.instance_id))

	# Reset once-per-turn power gates for every in-play card (both players' —
	# these powers aren't turn-restricted, e.g. Deacon Johanna).
	for pid in state.players:
		for card in state.cards_in_play(pid):
			card.used_this_turn = false
			# "attacks for the first time each turn" trigger gate (Windseer Tarus).
			card.counters.erase("attacked_this_turn")

	# Triggered effects: "at the start of each turn" (all players' in-play chars).
	for pid in state.players:
		for card in state.cards_in_play(pid):
			events.append_array(_apply_start_of_turn_effects(state, card, pid, db, true))
	# Triggered effects: "at the start of your turn" (only the turn player's chars).
	for card in state.cards_in_play(state.turn_player):
		events.append_array(_apply_start_of_turn_effects(state, card, state.turn_player, db, false))

	events.append(GameEvent.make("phase_changed", {
		"phase": "ready", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)

	# Ongoing Totem "at the start of each turn" targeted damage (Searing Totem).
	# Collected AFTER the window opens so the pending targeting choice sits on top
	# of a normal ready window; the scene resolves it (choose_enter_play_target)
	# before priority can advance. Turn player's totems fire first (rule 501.1a).
	events.append_array(_collect_ongoing_turn_triggers(state, db))
	return events


static func _enter_draw(state: GameState, _db) -> Array[GameEvent]:
	state.phase = "draw"
	var events: Array[GameEvent] = []
	# Rule 501.2b: first player skips the draw step on the very first turn.
	var is_first_turn_first_player: bool = (state.turn_number == 1 and state.turn_player == state.first_player)
	if not is_first_turn_first_player:
		events.append_array(_draw_one(state, state.turn_player))
	events.append(GameEvent.make("phase_changed", {
		"phase": "draw", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)
	return events


static func _enter_action(state: GameState, _db) -> Array[GameEvent]:
	state.phase = "action"
	var events: Array[GameEvent] = []
	events.append(GameEvent.make("phase_changed", {
		"phase": "action", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)
	return events


static func _enter_end(state: GameState, db) -> Array[GameEvent]:
	state.phase = "end"
	var events: Array[GameEvent] = []

	# Triggered effects: "at the end of your turn" (only the turn player's chars).
	for card in state.cards_in_play(state.turn_player):
		events.append_array(_apply_end_of_turn_effects(state, card, db))

	# Expire "this turn" buffs (duration_type == "turns"). Sweep every card in
	# play for both players — a "this turn" modifier ends at end of turn no
	# matter whose card it sits on.
	for pid in state.players:
		for card in state.cards_in_play(pid):
			card.decrement_turn_buffs()

	events.append(GameEvent.make("phase_changed", {
		"phase": "end", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)
	return events


static func _next_turn(state: GameState, db) -> Array[GameEvent]:
	# Rule 503.2a: wrap-up step — discard to max hand size before turn advances.
	var outgoing := state.turn_player
	var ps := state.players.get(outgoing) as PlayerState
	var hand_count := state.cards_in_zone(outgoing + "_hand").size()
	var max_hand := ps.max_hand_size if ps else 7
	var excess := hand_count - max_hand
	if excess > 0:
		state.pending_discard_player = outgoing
		state.pending_discard_count  = excess
		# Phase stays "end" — scene handles discards then calls advance_phase("end") again.
		return [GameEvent.discard_choice_opened(outgoing, excess, "wrap_up")]

	state.turn_number += 1
	for pid in state.players:
		if pid != state.turn_player:
			state.turn_player = pid
			break
	return _enter_ready(state, db)


# ── Helpers ────────────────────────────────────────────────────────────────────

# Entangling Roots: a card hosting an attachment with `attached_cannot_ready`
# ("Attached ally can't ready during its controller's ready step") skips the
# ready step. Only the ready STEP is blocked — explicit ready effects
# (e.g. ready_self_at_turn_end) still work. Live read — never cached.
static func _ready_blocked(state: GameState, card: CardInstance, db) -> bool:
	if not db:
		return false
	for att_id in card.attachments:
		var att := state.get_card(att_id)
		if not att or att.zone_id != "attached":
			continue
		var att_def := db.get_def(att.card_def_id) as CardDef
		if not att_def:
			continue
		for seg in att_def.effects.split("|"):
			if seg.strip_edges() == "attached_cannot_ready":
				return true
	return false


static func _open_window(state: GameState) -> void:
	state.priority_player    = state.turn_player
	state.consecutive_passes = 0


# Parse the effects string and fire any start-of-turn triggers.
# each_turn=true  → only fire "heal_at_each_turn_start" entries (any player's turn)
# each_turn=false → only fire "heal_at_turn_start" entries (controller's turn only)
static func _apply_start_of_turn_effects(state: GameState, card: CardInstance,
		_player_id: String, db, each_turn: bool) -> Array[GameEvent]:
	if not db:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.effects == "":
		return []
	var events: Array[GameEvent] = []
	var trigger_key := "heal_at_each_turn_start" if each_turn else "heal_at_turn_start"
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		var key := parts[0].strip_edges()
		# Infernal: "At the start of your turn, discard a card, or target opponent
		# gains control of [this]." Opens a pending choice the scene must resolve
		# via StackResolver.choose_control_discard / decline_control_discard.
		# Resolved immediately with no priority window — see data/rules_deviations.md
		# "Infernal" for why this deviates from rule 501.1a's chain-based trigger.
		# Wazzuli Wildmender: "At the start of your turn, [this] heals AMOUNT damage
		# from each hero and ally in your party."
		if not each_turn and key == "heal_party_at_turn_start":
			var heal_amt := int(parts[1]) if parts.size() > 1 else 1
			var pid := card.controller
			for ally in state.cards_in_zone(pid + "_ally_row"):
				events.append_array(GameLogic.heal(state, ally.instance_id, heal_amt, db, card.instance_id))
			var party_hero := state.get_hero(pid)
			if party_hero:
				events.append_array(GameLogic.heal(state, party_hero.instance_id, heal_amt, db, card.instance_id))
			continue
		# Fireball: "Ongoing: At the start of your turn, your hero deals 1 fire
		# damage to attached character." No choice — the target is the host, so
		# the trigger fires inline (packet pipeline: armor-preventable, and
		# fire-typed so World in Flames doubling applies).
		if not each_turn and key == "attached_damage_turn_start":
			var burn_amt := int(parts[1]) if parts.size() > 1 else 1
			var burn_type := parts[2].to_lower().strip_edges() if parts.size() > 2 else ""
			var caster_hero := state.get_hero(card.controller)
			if caster_hero and card.attached_to != "" \
					and state.is_in_play(card.attached_to):
				events.append_array(StackResolver.defer_packets(state, db, [{
					"source": caster_hero.instance_id, "target": card.attached_to,
					"amount": burn_amt, "dmg_type": burn_type,
				}]))
			continue
		if not each_turn and key == "turn_start_discard_or_give_control":
			state.pending_control_discard_player = card.controller
			state.pending_control_discard_ids.append(card.instance_id)
			events.append(GameEvent.control_discard_choice_opened(
				card.controller, card.instance_id))
			continue
		if parts.size() < 2 or key != trigger_key:
			continue
		var amount := int(parts[1])
		events.append_array(GameLogic.heal(state, card.instance_id, amount, db, card.instance_id))
	return events


# Scan every in-play card for ongoing "at the start of each turn" targeted-damage
# triggers (Totems). Build the queue in rule-501.1a order (turn player's totems
# first), then open the first one (emits totem_target_required); the rest wait in
# state.pending_ongoing_triggers.
# The trigger resolves immediately (mandatory target choice, no priority window)
# rather than going on the chain — see data/rules_deviations.md "Searing Totem".
static func _collect_ongoing_turn_triggers(state: GameState, db) -> Array[GameEvent]:
	if not db:
		return []
	state.pending_ongoing_triggers.clear()
	# Order: turn player first, then the other player(s).
	var ordered_pids: Array = [state.turn_player]
	for pid in state.players:
		if pid != state.turn_player:
			ordered_pids.append(pid)
	for pid in ordered_pids:
		for card in state.cards_in_play(pid):
			var def := db.get_def(card.card_def_id) as CardDef
			if not def or def.effects == "":
				continue
			for entry in def.effects.split("|"):
				var parts := entry.strip_edges().split(":")
				if parts[0].strip_edges() != "ongoing_damage_each_turn":
					continue
				var amount := int(parts[1]) if parts.size() > 1 else 0
				var dmg_type := parts[2].to_lower().strip_edges() if parts.size() > 2 else ""
				if amount <= 0:
					continue
				state.pending_ongoing_triggers.append({
					"card_id": card.instance_id,
					"amount": amount,
					"dmg_type": dmg_type,
				})
	return StackResolver._open_next_totem_trigger(state, db)


# Parse the effects string and fire any end-of-turn triggers.
static func _apply_end_of_turn_effects(state: GameState, card: CardInstance, db) -> Array[GameEvent]:
	if not db:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.effects == "":
		return []
	var events: Array[GameEvent] = []
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		match parts[0].strip_edges():
			"ready_self_at_turn_end":
				events.append_array(GameLogic.ready_card(state, card.instance_id))
			"end_of_turn_damage_opposing":
				# Infernal: "At the end of your turn, [this] deals AMOUNT DMG_TYPE
				# damage to each opposing hero and ally."
				# Packets go through the prevention machinery (rule 717.2c) —
				# the opposing hero's controller may exhaust DEF armor first.
				# The end-phase priority window that follows is hard-blocked
				# until the point resolves, so nothing advances early.
				var amount := int(parts[1]) if parts.size() > 1 else 1
				var opp := ""
				for pid in state.players:
					if pid != card.controller:
						opp = pid
						break
				if opp == "":
					continue
				var packets: Array = []
				for target in state.cards_in_zone(opp + "_ally_row").duplicate():
					packets.append({"source": card.instance_id,
						"target": target.instance_id, "amount": amount})
				var opp_hero := state.get_hero(opp)
				if opp_hero:
					packets.append({"source": card.instance_id,
						"target": opp_hero.instance_id, "amount": amount})
				events.append_array(StackResolver.defer_packets(state, db, packets))
	return events


static func _draw_one(state: GameState, player_id: String) -> Array[GameEvent]:
	var deck := state.zones.get(player_id + "_deck") as Zone
	if not deck or deck.card_ids.is_empty():
		return [GameEvent.make("deck_empty", {"player": player_id})]
	var top_id: String = deck.card_ids[0]
	return GameLogic.move_card(state, top_id, player_id + "_hand")
