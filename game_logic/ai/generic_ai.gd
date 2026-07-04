class_name GenericAI
extends FullRandomAI

# Deck-agnostic heuristic AI — "less random than FullRandom".
#
# On its own action window it first looks for SAFE KILLS (kill and survive,
# see BaseAI.find_safe_lethals / ai_functions.md):
#   list 1 — legal attackers on board + Ferocity allies in hand (a hand
#            Ferocity ally with a safe kill is played NOW so it can attack)
#   list 2 — all enemy allies on board
# Attackers with safe kills are ranked with sort_valuable_cards and committed
# LEAST valuable first — the cheap attacker goes in first to bait removal and
# counterplays; if uninterrupted the kill still lands. (Later, attacking
# heroes will rank most valuable and naturally attack last.) When the chosen
# attacker has several safe kills, the MOST valuable target dies.
#
# The whole scan re-runs every time this AI gets priority ("rinse and
# repeat"), so it chains safe kills one at a time. When no safe kill exists,
# behaviour falls back to FullRandomAI.


func decide_action(state: GameState, db, player_id: String) -> PendingAction:
	var safe := _safe_lethal_action(state, db, player_id)
	if safe != null:
		return safe
	return super.decide_action(state, db, player_id)


# Returns the next safe-kill action (play a hand Ferocity ally, or propose
# combat), or null when no safe kill is available/legal right now.
func _safe_lethal_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if state.phase != "action" or state.turn_player != player_id:
		return null
	if not state.pending_actions.is_empty():
		return null
	if state.combat_attack_window or state.combat_defend_window:
		return null

	# List 2: enemy allies on board.
	var opp := "p2" if player_id == "p1" else "p1"
	var defenders: Array[String] = []
	for card in state.cards_in_zone(opp + "_ally_row"):
		defenders.append(card.instance_id)
	if defenders.is_empty():
		return null

	# List 1: legal attackers on board + playable Ferocity allies in hand.
	var attackers: Array[String] = []
	var from_hand: Dictionary = {}
	for aid in StackResolver.get_legal_attackers(state, player_id, db):
		if state.get_atk(aid, db) > 0:
			attackers.append(aid)
	for card in state.cards_in_zone(player_id + "_hand"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.card_type != "Ally":
			continue
		if not _has_keyword(def, "ferocity"):
			continue
		var play := PendingAction.make("play_ally", player_id,
				{"card_id": card.instance_id})
		if StackResolver.can_submit(state, play, db):
			attackers.append(card.instance_id)
			from_hand[card.instance_id] = true
	if attackers.is_empty():
		return null

	var pairs := BaseAI.find_safe_lethals(state, db, attackers, defenders)
	if pairs.is_empty():
		return null

	# Distinct attackers with safe kills, most valuable first.
	var atk_ids: Array[String] = []
	for pair in pairs:
		if pair[0] not in atk_ids:
			atk_ids.append(pair[0])
	var ranked := BaseAI.sort_valuable_cards(state, db, atk_ids)

	# Least valuable attacker first (bait removal with the cheap one).
	for i in range(ranked.size() - 1, -1, -1):
		var attacker: String = ranked[i]
		if from_hand.get(attacker, false):
			# Ferocity ally in hand: play it now so it can attack this turn.
			return PendingAction.make("play_ally", player_id,
					{"card_id": attacker})
		# Its safe kills, most valuable target first.
		var targets: Array[String] = []
		for pair in pairs:
			if pair[0] == attacker:
				targets.append(pair[1])
		for target in BaseAI.sort_valuable_cards(state, db, targets):
			var act := PendingAction.make("propose_combat", player_id,
					{"attacker_id": attacker, "defender_id": target})
			# find_safe_lethals is pure math — legality (Elusive, Sarmoth
			# taunt, …) is checked here; fall through on illegal pairs.
			if StackResolver.can_submit(state, act, db):
				return act
	return null


# Discard the LEAST valuable card in hand (sort_valuable_cards, last entry).
func choose_discard_card(state: GameState, db, player_id: String) -> String:
	var hand: Array[String] = []
	for card in state.cards_in_zone(player_id + "_hand"):
		hand.append(card.instance_id)
	if hand.is_empty():
		return ""
	return BaseAI.sort_valuable_cards(state, db, hand).back()


# Resource placement: quests still go face-up first (same as BaseAI priority 1);
# otherwise place the LEAST valuable hand card face-down.
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

	# Priority 1: quest in hand → place face-up (same as BaseAI).
	for card in hand:
		if db:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and def.card_type == "Quest":
				var quest_action := PendingAction.make("place_resource", player_id,
						{"card_id": card.instance_id, "face_up": true})
				if StackResolver.can_submit(state, quest_action, db):
					return quest_action

	# Priority 2: hand > 1 → least valuable card goes face-down.
	if hand.size() <= 1:
		return null
	var ids: Array[String] = []
	for card in hand:
		ids.append(card.instance_id)
	var pick: String = BaseAI.sort_valuable_cards(state, db, ids).back()
	var action := PendingAction.make("place_resource", player_id,
			{"card_id": pick, "face_up": false})
	if StackResolver.can_submit(state, action, db):
		return action
	return null


# Graveyard selections: MOST valuable candidates — bring back your best card,
# or (for enemy-graveyard effects) remove their best. Exception: removing your
# OWN cards from the game (Darrowshire-style cost) takes the LEAST valuable.
func _choose_graveyard_targets(state: GameState, db, _player_id: String,
		gy_req: Dictionary, candidates: Array[String]) -> Array[String]:
	var ranked := BaseAI.sort_valuable_cards(state, db, candidates)
	var take: int = min(int(gy_req.get("max_count", 1)), ranked.size())
	var own_rfg_cost: bool = gy_req.get("dest", "hand") == "rfg" \
			and gy_req.get("owner", "own") == "own"
	if own_rfg_cost:
		var picks: Array[String] = ranked.slice(ranked.size() - take, ranked.size())
		picks.reverse()   # least valuable first, for consistency
		return picks
	return ranked.slice(0, take)


func _has_keyword(def: CardDef, keyword: String) -> bool:
	for k in def.keywords:
		if str(k).to_lower() == keyword:
			return true
	return false
