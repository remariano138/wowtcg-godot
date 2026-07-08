class_name GenericAI
extends FullRandomAI

# Deck-agnostic heuristic AI — fully deterministic, NO random fallback.
#
# On its own action window decide_action runs a fixed priority pipeline and
# returns ONE action; the engine resolves it and calls again ("rinse and
# repeat"), so a whole turn plays out one step at a time:
#   1. hero lethal    — win now (any attacker/Ferocity-in-hand that kills hero)
#   2. safe lethal     — kill an enemy ally and survive (find_safe_lethals)
#   3. good trade      — 'both die' trade, but only value-even-or-up
#   4. develop         — improve the board (allies, gated powers/removal, ramp)
#   5. hero chip       — poke the enemy hero with leftover attackers
#   6. null            — nothing constructive left → end the turn
#
# Because every action consumes a finite per-turn resource (a ready attacker's
# readiness, a hand card, resources, or the once-per-turn resource flag) and
# never restores one, the option set strictly shrinks and the pipeline is
# guaranteed to reach step 6 — no infinite loop. Combat is re-checked from the
# top after every develop, so a freshly played (Ferocity) attacker or buff can
# open a new fight on the very next call.
#
# See BaseAI.find_safe_lethals / combat_trade_value / ai_functions.md.
# Protector choice (choose_protector) also uses combat_trade_value — see below.


# Enemy hero HP at or below this → "all out": chip with Protectors too, since
# racing to lethal beats holding blockers back.
const HERO_ALL_OUT_HP := 10

# Develop-step priority per action type (higher = played first). This is the
# main tuning surface for non-combat play; see _develop_action.
const _DEVELOP_RANK := {
	"place_resource":  100,   # ramp first — more resources unlock more plays
	"play_ally":        60,   # develop board presence
	"use_ally_power":   40,
	"use_hero_power":   40,
	"play_equipment":   30,
	"use_quest":        20,
}


# Fully deterministic pipeline — GenericAI has NO random fallback. Each call the
# engine hands us priority, we return the single best action, it resolves, and
# we are called again ("rinse and repeat"). The offense steps run top-to-bottom;
# because every action we take consumes a finite per-turn resource (a ready
# attacker's readiness, a hand card, resources, or the once-per-turn resource
# flag) and never restores one, the option set strictly shrinks and the loop is
# guaranteed to reach the final `return null` (end of turn) — no infinite loop.
#
# The "combat → develop → combat" cycle emerges for free: a develop play may put
# a new (Ferocity) attacker or buff on board, and the next call re-checks combat
# from the top before developing again.
func decide_action(state: GameState, db, player_id: String) -> PendingAction:
	# Defensive, deterministic — legal at any priority incl. the opponent's turn.
	var block := armor_prevention_action(state, db, player_id)
	if block != null:
		return block
	var ambush := combat_instant_action(state, db, player_id)
	if ambush != null:
		return ambush

	# Everything below is our own action window only. Outside it (opponent's
	# turn / a pending chain we don't want to answer), we simply pass — no random
	# responses anymore.
	if state.phase != "action" or state.turn_player != player_id \
			or not state.pending_actions.is_empty():
		return null

	# 1. Win now.
	var hero_kill := _hero_lethal_action(state, db, player_id)
	if hero_kill != null:
		return hero_kill
	# 2. Free kills (kill and survive).
	var safe := _safe_lethal_action(state, db, player_id)
	if safe != null:
		return safe
	# 3. Good even/up trades (both die, our card no more valuable than theirs).
	var trade := _trade_action(state, db, player_id)
	if trade != null:
		return trade
	# 4. Improve the board (play allies, gated powers/removal, ramp, quests).
	var develop := _develop_action(state, db, player_id)
	if develop != null:
		return develop
	# 5. Poke the enemy hero with leftover attackers.
	var chip := _hero_chip_action(state, db, player_id)
	if chip != null:
		return chip
	# Nothing constructive left — end the turn.
	return null


# Step 3 — trade a board attacker into an enemy ally where BOTH die, but only
# when the ally we give up is no more valuable than the one we kill (never trade
# a bomb for a chump). Among accepted trades: kill the most valuable target,
# giving up the least valuable attacker.
func _trade_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var opp := "p2" if player_id == "p1" else "p1"
	var best: PendingAction = null
	var best_key: Array = []
	for aid in StackResolver.get_legal_attackers(state, player_id, db):
		if state.get_atk(aid, db, true) <= 0:
			continue
		for did in StackResolver.get_legal_defenders(state, aid, db):
			# Enemy allies only — the hero is handled by _hero_chip_action.
			var dcard := state.get_card(did)
			if not dcard or dcard.zone_id != opp + "_ally_row":
				continue
			if BaseAI.combat_trade_value(state, db, aid, did) != "both":
				continue
			# Value-even-or-up only: our attacker must be <= the target's value.
			var a_val := BaseAI._card_value_key(state, db, aid)
			var d_val := BaseAI._card_value_key(state, db, did)
			if a_val > d_val:
				continue
			var act := PendingAction.make("propose_combat", player_id,
					{"attacker_id": aid, "defender_id": did})
			if not StackResolver.can_submit(state, act, db):
				continue
			# Rank: most valuable target first, then least valuable attacker.
			var key := [d_val, _negated_key(a_val)]
			if best == null or key > best_key:
				best = act
				best_key = key
	return best


# Step 4 — the best board-improving non-combat play. Reuses BaseAI.get_legal_actions
# (which already gates powers to good targets, removal via _destroy_is_worth_it,
# draw-into-full-hand, and smart resource placement), drops every combat proposal,
# and picks by _DEVELOP_RANK then card value. GenericAI has no random fallback, so
# this is where "improve the game state until your options get better" lives.
func _develop_action(state: GameState, db, player_id: String) -> PendingAction:
	var best: PendingAction = null
	var best_key: Array = []
	for act in get_legal_actions(state, db, player_id):
		if act.action_type == "propose_combat":
			continue
		var rank: int = _DEVELOP_RANK.get(act.action_type, 10)
		# Within a rank, prefer the more valuable card involved (bigger ally,
		# pricier removal target, …).
		var cid: String = act.params.get("card_id",
				act.params.get("quest_id", act.params.get("target_id", "")))
		var key := [rank, BaseAI._card_value_key(state, db, cid) if cid != "" else []]
		if best == null or key > best_key:
			best = act
			best_key = key
	return best


# Step 5 — attack the enemy hero with leftover ready attackers (ATK > 0 only;
# a 0-ATK attacker can never help). Hold Protectors back to defend UNLESS the
# enemy hero is at/under HERO_ALL_OUT_HP, in which case we go all out to race
# for lethal. Chip with the LEAST valuable eligible attacker first, keeping the
# better cards free to respond.
func _hero_chip_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var opp := "p2" if player_id == "p1" else "p1"
	var ps_opp := state.players.get(opp) as PlayerState
	if not ps_opp or ps_opp.hero_instance_id == "" \
			or not state.is_in_play(ps_opp.hero_instance_id):
		return null
	var hero_id := ps_opp.hero_instance_id
	var all_out: bool = state.get_current_hp(hero_id, db) <= HERO_ALL_OUT_HP

	var best: String = ""
	var best_val: Array = []
	for aid in StackResolver.get_legal_attackers(state, player_id, db):
		if state.get_atk(aid, db, true) <= 0:
			continue
		if hero_id not in StackResolver.get_legal_defenders(state, aid, db):
			continue
		var card := state.get_card(aid)
		if not all_out and card and StackResolver._has_keyword(card, "protector", db):
			continue   # save Protectors to protect
		var val := BaseAI._card_value_key(state, db, aid)
		# Least valuable first → best_val is the current minimum.
		if best == "" or val < best_val:
			best = aid
			best_val = val
	if best == "":
		return null
	var act := PendingAction.make("propose_combat", player_id,
			{"attacker_id": best, "defender_id": hero_id})
	return act if StackResolver.can_submit(state, act, db) else null


# Protector choice (defending) — decided from the PROPOSED fight (the incoming
# attacker vs. the character it actually declared against), not the protector in
# isolation. Protecting exhausts the protector, so we only step in when it pays:
#
#   If the proposed defender would SURVIVE the hit:
#     • the attacker would die to the defender → do NOT protect (we already win
#       this fight for free — let the attacker throw itself away);
#     • otherwise, protect only if a protector would KILL the attacker and live
#       (safe_lethal for the protector); else take the hit.
#   If the proposed defender would DIE:
#     • the hero (losing it loses the game) → always interpose the cheapest body;
#     • an ally → interpose only a protector worth LESS than that ally (spend
#       cheap fodder to save something more valuable; never the reverse).
#
# Within a chosen bucket the LEAST valuable eligible protector is used. A 0-ATK
# attacker is never worth protecting. "While attacking" bonuses land on the
# attacker (it is the attacker) via get_atk(..., true) / combat_trade_value.
func choose_protector(state: GameState, db, player_id: String) -> String:
	var attacker := state.combat_attacker
	var defender := state.combat_defender
	if attacker == "" or defender == "":
		return ""
	var pool := StackResolver.get_legal_protectors(state, attacker, defender, db)
	if pool.is_empty():
		return ""
	var a_atk := state.get_atk(attacker, db, true)   # attacker's "while attacking" ATK
	if a_atk <= 0:
		return ""   # attacker deals no damage — nothing to prevent
	var a_hp  := state.get_current_hp(attacker, db)
	var d_hp  := state.get_current_hp(defender, db)
	var d_atk := state.get_atk(defender, db)          # the defender isn't attacking

	var defender_dies := a_atk >= d_hp
	var attacker_dies_to_defender := d_atk >= a_hp

	var candidates: Array[String] = []
	if not defender_dies:
		if attacker_dies_to_defender:
			return ""   # the attacker dies to the defender for free — let it happen
		# Neither would die: only worth protecting to KILL the attacker with a
		# protector that survives (safe_lethal from the protector's view).
		for p in pool:
			if BaseAI.combat_trade_value(state, db, p, attacker, false) == "safe_lethal":
				candidates.append(p)
	else:
		var ps := state.players.get(player_id) as PlayerState
		if ps != null and defender == ps.hero_instance_id:
			candidates = pool          # lethal on the hero → interpose anything
		else:
			# Save a dying ally only with a protector worth less than it.
			var d_val := BaseAI._card_value_key(state, db, defender)
			for p in pool:
				if BaseAI._card_value_key(state, db, p) < d_val:
					candidates.append(p)

	# Use the least valuable eligible protector.
	var best := ""
	var best_val: Array = []
	for p in candidates:
		var pval := BaseAI._card_value_key(state, db, p)
		if best == "" or pval < best_val:
			best = p
			best_val = pval
	return best


# Negates each element of a value key so ascending sorts (least valuable first)
# can be expressed with the same `>` comparison used everywhere else.
func _negated_key(key: Array) -> Array:
	var out: Array = []
	for v in key:
		out.append(-v if (v is int or v is float) else v)
	return out


# Highest priority of all: if any legal attacker — already on board, or a
# Ferocity ally playable from hand this turn — can deal lethal damage to the
# enemy hero right now, attack it. Winning the game outranks safe kills,
# survival math, and the random fallback entirely; unlike _safe_lethal_action
# this does NOT require the attacker to survive the swing.
func _hero_lethal_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if state.phase != "action" or state.turn_player != player_id:
		return null
	if not state.pending_actions.is_empty():
		return null
	if state.combat_attack_window or state.combat_defend_window:
		return null

	var opp := "p2" if player_id == "p1" else "p1"
	var ps_opp := state.players.get(opp) as PlayerState
	if not ps_opp or ps_opp.hero_instance_id == "" \
			or not state.is_in_play(ps_opp.hero_instance_id):
		return null
	var hero_id := ps_opp.hero_instance_id
	var hero_hp := state.get_current_hp(hero_id, db)

	# Board attackers that can already swing this turn (forecast "while
	# attacking" bonuses — they apply the moment combat is proposed).
	for aid in StackResolver.get_legal_attackers(state, player_id, db):
		if state.get_atk(aid, db, true) < hero_hp:
			continue
		if hero_id not in StackResolver.get_legal_defenders(state, aid, db):
			continue
		var act := PendingAction.make("propose_combat", player_id,
				{"attacker_id": aid, "defender_id": hero_id})
		if StackResolver.can_submit(state, act, db):
			return act

	# Ferocity allies in hand: play now so they can swing this same turn.
	for card in state.cards_in_zone(player_id + "_hand"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.card_type != "Ally":
			continue
		if not _has_keyword(def, "ferocity"):
			continue
		if def.printed_atk < hero_hp:
			continue
		var play := PendingAction.make("play_ally", player_id,
				{"card_id": card.instance_id})
		if StackResolver.can_submit(state, play, db):
			return play
	return null


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
		if state.get_atk(aid, db, true) > 0:
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
