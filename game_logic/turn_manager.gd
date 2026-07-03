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

static func _enter_mulligan(state: GameState, db) -> Array[GameEvent]:
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
	var events: Array[GameEvent] = []

	# Reset once-per-turn flags.
	var ps := state.players.get(state.turn_player) as PlayerState
	if ps:
		ps.resource_placed_this_turn = false
		# has_used_hero_power intentionally NOT reset here — using the hero power
		# "flips" the hero for the rest of the game; it cannot be reused.

	# Clear summoning sickness and ready all in-play cards for the turn player.
	for card in state.cards_in_play(state.turn_player):
		card.just_summoned = false
		events.append_array(GameLogic.ready_card(state, card.instance_id))
	for card in state.cards_in_zone(state.turn_player + "_resource_row"):
		events.append_array(GameLogic.ready_card(state, card.instance_id))

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
	return events


static func _enter_draw(state: GameState, db) -> Array[GameEvent]:
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


static func _enter_action(state: GameState, db) -> Array[GameEvent]:
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
		if parts.size() < 2 or parts[0].strip_edges() != trigger_key:
			continue
		var amount := int(parts[1])
		events.append_array(GameLogic.heal(state, card.instance_id, amount, db))
	return events


static func _draw_one(state: GameState, player_id: String) -> Array[GameEvent]:
	var deck := state.zones.get(player_id + "_deck") as Zone
	if not deck or deck.card_ids.is_empty():
		return [GameEvent.make("deck_empty", {"player": player_id})]
	var top_id: String = deck.card_ids[0]
	return GameLogic.move_card(state, top_id, player_id + "_hand")
