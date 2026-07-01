class_name BaseAI
extends RefCounted

# Abstract base for all AI players.
#
# Subclasses must override decide_action().
# get_legal_actions() is a shared utility all subclasses can call.


# Return a PendingAction to submit, or null to pass priority.
# Called once each time this player has priority.
func decide_action(_state: GameState, _db, _player_id: String) -> PendingAction:
	return null


# ── Shared utility ─────────────────────────────────────────────────────────────

# Returns every legal action the player can submit right now.
# Checks hand cards against all known action types via StackResolver.can_submit.
func get_legal_actions(state: GameState, db, player_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	for card in state.cards_in_zone(player_id + "_hand"):
		var action_type := _action_type_for(card, db)
		if action_type == "":
			continue
		var action := PendingAction.make(action_type, player_id,
				{"card_id": card.instance_id})
		if StackResolver.can_submit(state, action, db):
			result.append(action)
	return result


func _action_type_for(card: CardInstance, db) -> String:
	if not db:
		return "play_ally"
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return ""
	return "play_instant" if def.is_instant else "play_ally"
