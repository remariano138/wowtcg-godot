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


# ── Shared utilities ───────────────────────────────────────────────────────────

# Returns every legal action the player can submit right now (hand plays + combat).
func get_legal_actions(state: GameState, db, player_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []

	# Hand card plays.
	for card in state.cards_in_zone(player_id + "_hand"):
		var action_type := _action_type_for(card, db)
		if action_type == "":
			continue
		var action := PendingAction.make(action_type, player_id,
				{"card_id": card.instance_id})
		if StackResolver.can_submit(state, action, db):
			result.append(action)

	# Combat proposals (only valid in action phase with empty chain, so check once).
	if state.phase == "action" and state.turn_player == player_id \
			and state.pending_actions.is_empty():
		for atk_id in StackResolver.get_legal_attackers(state, player_id, db):
			# Never attack with a 0 ATK character — no damage dealt, just exhausts them.
			# An advanced AI subclass can override this if it has tactical reasons.
			if state.get_atk(atk_id, db) == 0:
				continue
			for def_id in StackResolver.get_legal_defenders(state, atk_id, db):
				result.append(PendingAction.make("propose_combat", player_id,
					{"attacker_id": atk_id, "defender_id": def_id}))

	return result


# Rule 602.2: the defending player may exhaust a ready Protector to intercept,
# or return "" to skip protection.  Called by the scene after protect_point_opened.
# Base behaviour: always skip (safe but passive).
func choose_protector(_state: GameState, _db, _player_id: String) -> String:
	return ""


func _action_type_for(card: CardInstance, db) -> String:
	if not db:
		return "play_ally"
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return ""
	return "play_instant" if def.is_instant else "play_ally"
