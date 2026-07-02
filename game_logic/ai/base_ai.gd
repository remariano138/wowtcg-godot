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


# Return true if this AI wants to mulligan its opening hand.
# Base heuristic: mulligan if the hand contains no quests or locations.
func wants_mulligan(state: GameState, db, player_id: String) -> bool:
	for card in state.cards_in_zone(player_id + "_hand"):
		if not db:
			return false
		var def := db.get_def(card.card_def_id) as CardDef
		if def and (def.card_type == "Quest" or def.card_type == "Location"):
			return false   # found at least one quest/location — keep
	return true   # no quest or location → mulligan


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

	# Quest completions (face-up quests in resource row whose cost is payable).
	for card in state.cards_in_zone(player_id + "_resource_row"):
		if card.face_down:
			continue
		if db:
			var def := db.get_def(card.card_def_id) as CardDef
			if not def or def.card_type != "Quest":
				continue
		var action := PendingAction.make("use_quest", player_id,
				{"quest_id": card.instance_id})
		if StackResolver.can_submit(state, action, db):
			result.append(action)

	# Combat proposals (only valid in action phase with empty chain, so check once).
	if state.phase == "action" and state.turn_player == player_id \
			and state.pending_actions.is_empty():
		for atk_id in StackResolver.get_legal_attackers(state, player_id, db):
			if state.get_atk(atk_id, db) <= 0:
				continue   # never propose combat with a 0-ATK attacker
			for def_id in StackResolver.get_legal_defenders(state, atk_id, db):
				result.append(PendingAction.make("propose_combat", player_id,
					{"attacker_id": atk_id, "defender_id": def_id}))

	# Hero power activations.
	result.append_array(_get_hero_power_actions(state, db, player_id))

	# Resource placement — smart selection: quest face-up first, else most-copied face-down.
	var res_action := _decide_resource_placement(state, db, player_id)
	if res_action != null:
		result.append(res_action)

	return result


# Returns the best resource placement action for this player, or null if none is appropriate.
# Priority 1 — Quest in hand: place one at random face-up.
# Priority 2 — Hand > 1 card: place face-down the card with the most copies in hand
#              (random tiebreak). Avoids placing the last card and leaving hand empty.
func _decide_resource_placement(state: GameState, db, player_id: String) -> PendingAction:
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.resource_placed_this_turn:
		return null
	if state.phase != "action" or state.turn_player != player_id:
		return null
	if not state.pending_actions.is_empty():
		return null

	var hand := state.cards_in_zone(player_id + "_hand")
	if hand.is_empty():
		return null

	# Priority 1: quest in hand → place face-up.
	var quests: Array[CardInstance] = []
	for card in hand:
		if db:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and def.card_type == "Quest":
				quests.append(card)
	if not quests.is_empty():
		var pick := quests[randi() % quests.size()]
		var action := PendingAction.make("place_resource", player_id,
			{"card_id": pick.instance_id, "face_up": true})
		if StackResolver.can_submit(state, action, db):
			return action

	# Priority 2: if hand > 1, place most-duplicated card face-down.
	if hand.size() <= 1:
		return null

	var counts: Dictionary = {}
	for card in hand:
		counts[card.card_def_id] = counts.get(card.card_def_id, 0) + 1
	var max_count: int = 0
	for did in counts:
		if (counts[did] as int) > max_count:
			max_count = counts[did]
	var candidates: Array[CardInstance] = []
	for card in hand:
		if counts[card.card_def_id] == max_count:
			candidates.append(card)
	var pick := candidates[randi() % candidates.size()]
	var action := PendingAction.make("place_resource", player_id,
		{"card_id": pick.instance_id, "face_up": false})
	if StackResolver.can_submit(state, action, db):
		return action

	return null


# Rule 602.2: the defending player may exhaust a ready Protector to intercept,
# or return "" to skip protection.  Called by the scene after protect_point_opened.
# Base behaviour: protect with the highest current HP protector (random on tie).
func choose_protector(state: GameState, db, _player_id: String) -> String:
	var protectors := StackResolver.get_legal_protectors(
		state, state.combat_attacker, state.combat_defender, db)
	if protectors.is_empty():
		return ""
	var best_id := protectors[0]
	var best_hp := state.get_current_hp(best_id, db)
	for i in range(1, protectors.size()):
		var hp := state.get_current_hp(protectors[i], db)
		if hp > best_hp:
			best_hp = hp
			best_id = protectors[i]
		elif hp == best_hp and randi() % 2 == 0:
			best_id = protectors[i]
	return best_id


# Returns activate_power actions for the player's hero.
# For targeted powers, one action is created per valid target.
# For untargeted powers, one action is created with no target_id.
func _get_hero_power_actions(state: GameState, db, player_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return result
	var hero_id := ps.hero_instance_id
	var needs_target := _hero_power_needs_target(state, db, hero_id)

	if needs_target:
		# One action per valid target (any in-play hero or ally).
		for pid in state.players:
			var ps2 := state.players.get(pid) as PlayerState
			if ps2 and ps2.hero_instance_id != "":
				var action := PendingAction.make("activate_power", player_id,
					{"hero_id": hero_id, "target_id": ps2.hero_instance_id})
				if StackResolver.can_submit(state, action, db):
					result.append(action)
		for card in state.cards_in_zone(player_id + "_ally_row"):
			var action := PendingAction.make("activate_power", player_id,
				{"hero_id": hero_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, action, db):
				result.append(action)
		for card in state.cards_in_zone(_other_player_id(state, player_id) + "_ally_row"):
			var action := PendingAction.make("activate_power", player_id,
				{"hero_id": hero_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, action, db):
				result.append(action)
	else:
		var action := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": ""})
		if StackResolver.can_submit(state, action, db):
			result.append(action)

	return result


func _hero_power_needs_target(state: GameState, db, hero_id: String) -> bool:
	if not db:
		return false
	var hero := state.get_card(hero_id)
	if not hero:
		return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def:
		return false
	for entry in def.effects.split("|"):
		if entry.strip_edges().begins_with("deal_damage_to_target"):
			return true
	return false


func _other_player_id(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id


func _action_type_for(card: CardInstance, db) -> String:
	if not db:
		return "play_ally"
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return ""
	if def.card_type == "Quest":
		return ""   # quests go to resource row via place_resource, never play_ally
	return "play_instant" if def.is_instant else "play_ally"
