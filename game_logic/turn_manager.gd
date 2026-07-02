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
	return _enter_ready(state, db)


static func advance_phase(state: GameState, db = null) -> Array[GameEvent]:
	match state.phase:
		"ready":  return _enter_draw(state, db)
		"draw":   return _enter_action(state, db)
		"action": return _enter_end(state, db)
		"end":    return _next_turn(state, db)
	return []


# ── Phase transitions ──────────────────────────────────────────────────────────

static func _enter_ready(state: GameState, db) -> Array[GameEvent]:
	state.phase = "ready"
	var events: Array[GameEvent] = []

	# Reset once-per-turn flags.
	var ps := state.players.get(state.turn_player) as PlayerState
	if ps:
		ps.resource_placed_this_turn = false

	# Clear summoning sickness and ready all in-play cards for the turn player.
	for card in state.cards_in_play(state.turn_player):
		card.just_summoned = false
		events.append_array(GameLogic.ready_card(state, card.instance_id))
	for card in state.cards_in_zone(state.turn_player + "_resource_row"):
		events.append_array(GameLogic.ready_card(state, card.instance_id))

	events.append(GameEvent.make("phase_changed", {
		"phase": "ready", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)
	return events


static func _enter_draw(state: GameState, db) -> Array[GameEvent]:
	state.phase = "draw"
	var events: Array[GameEvent] = []
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


static func _draw_one(state: GameState, player_id: String) -> Array[GameEvent]:
	var deck := state.zones.get(player_id + "_deck") as Zone
	if not deck or deck.card_ids.is_empty():
		return [GameEvent.make("deck_empty", {"player": player_id})]
	var top_id: String = deck.card_ids[0]
	return GameLogic.move_card(state, top_id, player_id + "_hand")
