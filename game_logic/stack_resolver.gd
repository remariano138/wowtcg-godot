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

	# Rule 409.1: playing a card moves it from its current zone into the chain.
	match action.action_type:
		"play_ally", "play_instant":
			var card_id: String = action.params.get("card_id", "")
			if card_id != "":
				events.append_array(GameLogic.move_card(state, card_id, "chain"))

	state.pending_actions.push_back(action)
	state.consecutive_passes = 0
	# Rule 410.1: proposer keeps priority (NOT flipped to opponent).

	events.append(GameEvent.make("action_proposed", {
		"action_type": action.action_type,
		"player":      action.source_player,
	}))
	return events


static func pass_priority(state: GameState, db = null) -> Array[GameEvent]:
	state.consecutive_passes += 1
	var events: Array[GameEvent] = []

	# All players passed in succession.
	if state.consecutive_passes >= 2:
		if state.pending_actions.is_empty():
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

	match action.action_type:
		"play_ally":
			return _can_play_non_instant(state, action)
		"play_instant":
			return _can_play_instant(state, action)

	return false   # unknown action type


static func _can_play_non_instant(state: GameState, action: PendingAction) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	# Card must be in hand and controlled by the acting player.
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Rule 409.1: non-instant cards require an empty chain.
	# Phase check (must be action phase) and resource cost deferred to Phase 7.
	return state.pending_actions.is_empty()


static func _can_play_instant(state: GameState, action: PendingAction) -> bool:
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
	return true


# ── Resolution ─────────────────────────────────────────────────────────────────

static func _resolve(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	match action.action_type:
		"play_ally":
			return _resolve_play_ally(state, action)
		"play_instant":
			return _resolve_play_instant(state, action)

	# Unknown action type — should not happen if can_submit gate is correct.
	return [GameEvent.make("action_fizzled", {
		"action_type": action.action_type,
		"reason":      "unknown_action_type",
	})]


static func _resolve_play_ally(state: GameState,
		action: PendingAction) -> Array[GameEvent]:
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
	# TODO Phase 7: exhaust resources equal to card cost here.
	return events


static func _resolve_play_instant(state: GameState,
		action: PendingAction) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var events: Array[GameEvent] = []
	events.append(GameEvent.make("instant_resolved", {
		"card_id": card_id,
		"player":  action.source_player,
	}))
	# Move used instant to its owner's graveyard (card is currently in chain zone).
	var card := state.get_card(card_id)
	if card:
		events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
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

	events.append(GameEvent.make("action_retracted", {
		"action_type": top.action_type,
		"player":      player_id,
	}))
	return events


# ── Helpers ────────────────────────────────────────────────────────────────────

static func _other_player(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id
