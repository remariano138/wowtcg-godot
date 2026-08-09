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
	var ambush := combat_instant_action(state, db, player_id)
	if ambush != null:
		return ambush
	var flash := instant_protector_action(state, db, player_id)
	if flash != null:
		return flash
	var freeze := hero_disable_action(state, db, player_id)
	if freeze != null:
		return freeze
	var exhaust := exhaust_attacker_action(state, db, player_id)
	if exhaust != null:
		return exhaust
	var power_exhaust := exhaust_attacker_ally_power_action(state, db, player_id)
	if power_exhaust != null:
		return power_exhaust
	var kill_protector := destroy_protector_action(state, db, player_id)
	if kill_protector != null:
		return kill_protector
	var save := save_bounce_action(state, db, player_id)
	if save != null:
		return save
	var cash_in := doomed_sacrifice_action(state, db, player_id)
	if cash_in != null:
		return cash_in
	# Blink dodge (BaseAI) — remove the attacker while our hero defends.
	var dodge := evasion_action(state, db, player_id)
	if dodge != null:
		return dodge
	# Ravenous Bite ATK swing (BaseAI) — only when it flips the open combat.
	var swing := atk_swing_action(state, db, player_id)
	if swing != null:
		return swing
	# Bear Form flash-in (BaseAI) — hero gains protector before the protect point.
	var shift := bear_form_action(state, db, player_id)
	if shift != null:
		return shift

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
	# 1.5. Win now, all-out: no single attacker/Ferocity play is lethal, but
	# swinging with the whole board at once is, and the enemy has no
	# Protector to blunt any of the attacks.
	var all_out_kill := _all_out_hero_lethal_action(state, db, player_id)
	if all_out_kill != null:
		return all_out_kill
	# 1.6. Win now, all-out + a hand spell: the board alone isn't lethal even
	# all-out, but the board PLUS one damage spell in hand is. Attack with
	# everyone first and hold the spell for the last hit — see
	# _all_out_with_spell_hero_lethal_action for why.
	var all_out_spell := _all_out_with_spell_hero_lethal_action(state, db, player_id)
	if all_out_spell != null:
		return all_out_spell
	# 1.7. Win now via Elendril's flip: no lethal on the board yet, but pumping
	# our Ranged weapons (+3 ATK this turn) creates one. Flip first; next call the
	# bonus is live and the lethal detectors above execute the kill with the
	# enhanced weapon. See _ranged_bonus_flip_worth_it.
	var ranged_setup := _ranged_bonus_flip_action(state, db, player_id)
	if ranged_setup != null:
		return ranged_setup
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
		if BaseAI.forecast_atk(state, db, aid) <= 0:
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


# Step 4 — the best board-improving non-combat play. Reuses BaseAI.get_reasonable_actions
# (which already gates powers to good targets, removal via _destroy_is_worth_it,
# draw-into-full-hand, and smart resource placement), drops every combat proposal,
# and picks by _DEVELOP_RANK then card value. GenericAI has no random fallback, so
# this is where "improve the game state until your options get better" lives.
func _develop_action(state: GameState, db, player_id: String) -> PendingAction:
	var best: PendingAction = null
	var best_key: Array = []
	for act in get_reasonable_actions(state, db, player_id):
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
# for lethal. Protectors that ready at end of turn (ready_self_at_turn_end, e.g.
# Kulan Earthguard) are exempt from the hold-back — they attack AND stay up to
# defend. Chip with the LEAST valuable eligible attacker first, keeping the
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
		if BaseAI.forecast_atk(state, db, aid) <= 0:
			continue
		if hero_id not in StackResolver.get_legal_defenders(state, aid, db):
			continue
		var card := state.get_card(aid)
		if not all_out and card and StackResolver._has_keyword(card, "protector", db) \
				and not StackResolver._has_effect_flag(
					db.get_def(card.card_def_id) as CardDef, "ready_self_at_turn_end"):
			continue   # save Protectors to protect — unless they ready at end of
			# turn (e.g. Kulan Earthguard), in which case attacking is free.
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
	# The hero (Draconian Deflector grant) never competes in the ally buckets —
	# its value key (no ally stats) would make it look like the cheapest fodder
	# and it would chump-block everything. It gets its own gate at the end.
	var ps_self := state.players.get(player_id) as PlayerState
	var hero_id: String = ps_self.hero_instance_id if ps_self else ""
	var hero_in_pool := hero_id != "" and hero_id in pool
	if hero_in_pool:
		pool.erase(hero_id)
	var a_atk := state.get_atk(attacker, db, true)   # attacker's "while attacking" ATK
	if a_atk <= 0:
		return ""   # attacker deals no damage — nothing to prevent
	var a_hp  := state.get_current_hp(attacker, db)
	var d_hp  := state.get_current_hp(defender, db)
	var d_atk := state.get_atk(defender, db)          # the defender isn't attacking

	var defender_dies := a_atk >= d_hp
	var attacker_dies_to_defender := d_atk >= a_hp

	# Protectors this attacker simply can't hurt (Brother Rhone vs an attacking
	# ally). Interposing one costs literally nothing — it can't die and nothing
	# else is spent — so it is an eligible candidate whatever the defender would
	# have suffered, and the ranking below puts it ahead of every stat-based
	# pick. Protecting DOES exhaust it though (602.2), so the block is once per
	# turn: free_block_worth_spending holds it back when this attack is a cheap
	# bait and a strictly bigger ready ally is still waiting.
	var free_blocks: Array[String] = []
	if BaseAI.free_block_worth_spending(state, db, player_id, attacker, defender):
		for p in pool:
			if BaseAI.blocks_for_free(state, db, p, attacker):
				free_blocks.append(p)

	var candidates: Array[String] = []
	if not defender_dies:
		if attacker_dies_to_defender:
			return ""   # the attacker dies to the defender for free — let it happen
		# Neither would die: only worth protecting to KILL the attacker with a
		# protector that survives (safe_lethal from the protector's view).
		for p in pool:
			if BaseAI.combat_trade_value(state, db, p, attacker, false) == "safe_lethal":
				candidates.append(p)
		candidates.append_array(free_blocks)   # or to soak the chip damage for free
	else:
		var ps := state.players.get(player_id) as PlayerState
		if ps != null and defender == ps.hero_instance_id:
			candidates = pool          # lethal on the hero → interpose anything
		else:
			# First choice: a protector that KILLS the attacker and SURVIVES the
			# block (safe_lethal). That's strictly better than the default trade —
			# we save the dying ally, kill the attacker, and lose nothing — so it
			# wins regardless of relative card value.
			for p in pool:
				if BaseAI.combat_trade_value(state, db, p, attacker, false) == "safe_lethal":
					candidates.append(p)
			# Fallback: no free block available — save a dying ally only by
			# spending fodder worth less than it.
			if candidates.is_empty():
				var d_val := BaseAI._card_value_key(state, db, defender)
				for p in pool:
					if BaseAI._card_value_key(state, db, p) < d_val:
						candidates.append(p)
			candidates.append_array(free_blocks)

	# Rank: a block that kills the attacker and survives (safe_lethal) removes a
	# card and so still outranks a free block, which only stops one attack; both
	# beat spending fodder. Within a rank, the least valuable protector wins.
	var best := ""
	var best_key: Array = []
	for p in candidates:
		var rank := 2
		if BaseAI.combat_trade_value(state, db, p, attacker, false) == "safe_lethal":
			rank = 0
		elif p in free_blocks:
			rank = 1
		var pkey: Array = [rank]
		pkey.append_array(BaseAI._card_value_key(state, db, p))
		if best == "" or pkey < best_key:
			best = p
			best_key = pkey

	# Hero-protect gate (Draconian Deflector): only when no ally stepped in,
	# and never into burst range (keep the hero above the all-out threshold
	# after the hit). Worth it when:
	#   • the hero's weapon retaliation KILLS the attacker (safe_lethal — the
	#     defend strike point will fire and choose_strike_weapon always strikes
	#     while protecting), unless the fight was already won for free; or
	#   • an ally would die and it's worth at least the face damage taken
	#     (cost >= incoming ATK) — trade hero HP for board presence.
	if best == "" and hero_in_pool:
		var hero_hp := state.get_current_hp(hero_id, db)
		if hero_hp - a_atk > HERO_ALL_OUT_HP:
			var retaliation_kills := BaseAI.combat_trade_value(
				state, db, hero_id, attacker, false) == "safe_lethal"
			if defender_dies:
				if retaliation_kills or _def_cost(state, db, defender) >= a_atk:
					best = hero_id
			elif retaliation_kills and not attacker_dies_to_defender:
				best = hero_id
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
		if BaseAI.forecast_atk(state, db, aid) < hero_hp:
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


# Elendril's flip ("[1] → Your Ranged weapons have +3 ATK this turn"). Flip only
# when the board has NO lethal now but WOULD have one once the bonus lands — the
# bonus only touches Ranged weapons, so it can only matter through a ranged
# weapon strike. We temporarily apply the bonus and re-ask the same lethal
# detectors the AI uses downstream (so after flipping, the regular hero-lethal /
# all-out heuristics execute the kill with the enhanced weapon). Requires enough
# resources for the flip PLUS at least one ranged strike, so the flip can't
# strand the AI unable to actually swing.
# The flip action itself, if flipping enables a lethal that isn't there now.
func _ranged_bonus_flip_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "" or ps.has_used_hero_power:
		return null
	var hero_id := ps.hero_instance_id
	if not _hero_power_is(state, db, hero_id, "ranged_weapon_atk_bonus"):
		return null
	if not _ranged_bonus_flip_worth_it(state, db, player_id, hero_id):
		return null
	var act := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": ""})
	return act if StackResolver.can_submit(state, act, db) else null


func _ranged_bonus_flip_worth_it(state: GameState, db, player_id: String,
		hero_id: String) -> bool:
	if not db:
		return false
	var ps := state.players.get(player_id) as PlayerState
	if not ps:
		return false
	var hero := state.get_card(hero_id)
	var hero_def := db.get_def(hero.card_def_id) as CardDef if hero else null
	if not hero_def:
		return false
	var amount := 0
	for entry in hero_def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "ranged_weapon_atk_bonus":
			amount = int(parts[1]) if parts.size() > 1 else 0
	if amount == 0:
		return false
	# Need a ready ranged weapon in play and resources for flip + a ranged strike.
	var flip_cost: int = maxi(hero_def.cost, 0)
	var cheapest_strike := _cheapest_ranged_strike_cost(state, db, player_id)
	if cheapest_strike < 0:
		return false
	if flip_cost + cheapest_strike > state.get_available_resources(player_id):
		return false
	# Already lethal? Don't burn the flip — the normal heuristics win anyway.
	if _has_hero_lethal(state, db, player_id):
		return false
	# Would the bonus create a lethal? Apply it live, re-check, restore.
	ps.ranged_weapon_atk_bonus += amount
	var enabled := _has_hero_lethal(state, db, player_id)
	ps.ranged_weapon_atk_bonus -= amount
	return enabled


func _has_hero_lethal(state: GameState, db, player_id: String) -> bool:
	return _hero_lethal_action(state, db, player_id) != null \
		or _all_out_hero_lethal_action(state, db, player_id) != null


# Cheapest strike cost among the player's ready Ranged weapons in play, or -1 if
# none. Mirrors get_strike_cost (which applies any discounts).
func _cheapest_ranged_strike_cost(state: GameState, db, player_id: String) -> int:
	var best := -1
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if card.is_exhausted:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.dmg_type != "Ranged":
			continue
		if StackResolver._weapon_info(def).is_empty():
			continue
		var cost := StackResolver.get_strike_cost(state, player_id, def)
		if cost >= 0 and (best < 0 or cost < best):
			best = cost
	return best


# "All out" — no single attacker is lethal (checked above), but attacking with
# EVERY ready ally at once is, and the enemy board has zero Protectors to
# absorb any of the swings. Attacking with everything — including allies that
# would normally be held back to protect next turn — wins the game outright,
# so it outranks safe kills, trades, and development just like straight hero
# lethal. Re-evaluated on every call: as attackers exhaust and the enemy
# hero's HP drops (each combat window resolves independently), the pipeline
# keeps returning attacks as long as the remaining math still adds up.
func _all_out_hero_lethal_action(state: GameState, db, player_id: String) -> PendingAction:
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

	# Any enemy Protector can intercept one of our attacks, breaking the "every
	# swing connects" assumption below — bail out entirely.
	for card in state.cards_in_zone(opp + "_ally_row"):
		if StackResolver._has_keyword(card, "protector", db):
			return null

	var hero_hp := state.get_current_hp(hero_id, db)
	# Block absorbs damage before it reaches the hero, so the required total
	# ATK is hp PLUS whatever the enemy can still block, not minus.
	var threshold := hero_hp + _enemy_available_hero_block(state, db, opp)

	var attackers: Array[String] = []
	var total_atk := 0
	for aid in StackResolver.get_legal_attackers(state, player_id, db):
		var atk := BaseAI.forecast_atk(state, db, aid)   # "while attacking" bonuses + weapon strike
		if atk <= 0:
			continue
		if hero_id not in StackResolver.get_legal_defenders(state, aid, db):
			continue
		attackers.append(aid)
		total_atk += atk

	if attackers.is_empty() or total_atk < threshold:
		return null   # attacking with the whole board still doesn't kill

	# Least valuable attacker first (mirrors _hero_chip_action) — no reason to
	# risk the more valuable cards first when every swing is going through.
	var best := ""
	var best_val: Array = []
	for aid in attackers:
		var val := BaseAI._card_value_key(state, db, aid)
		if best == "" or val < best_val:
			best = aid
			best_val = val

	var act := PendingAction.make("propose_combat", player_id,
			{"attacker_id": best, "defender_id": hero_id})
	return act if StackResolver.can_submit(state, act, db) else null


# "All out, finish with a spell" — the board alone isn't lethal even
# all-out (checked above), but the board PLUS one damage spell in hand
# together clear the threshold, and the enemy has no Protector. Allies
# attack FIRST; the spell is held back and only actually played once every
# legal attacker has swung. Reasoning: if the attack sequence gets
# interrupted (protector flashed in, instant-speed heal, etc.) and the hero
# ends up not dying this turn after all, the spell is still in hand and free
# to answer whatever the board looks like afterward, instead of having been
# burned on a hero that wasn't going to die anyway.
#
# Only one spell needs to close the gap, and each candidate is checked with
# can_submit — i.e. actually payable with resources left THIS turn. That
# stops the AI from treating a hand of several copies of the same spell as
# though all of them were available at once (which would make it easy to
# bait an all-in attack that doesn't kill, spending the whole hand for
# nothing against a deck that can heal back up).
func _all_out_with_spell_hero_lethal_action(state: GameState, db, player_id: String) -> PendingAction:
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

	# Same Protector guard as the pure all-out check — one Protector can
	# absorb an attack, breaking the "every swing connects" assumption.
	for card in state.cards_in_zone(opp + "_ally_row"):
		if StackResolver._has_keyword(card, "protector", db):
			return null

	var hero_hp := state.get_current_hp(hero_id, db)
	var threshold := hero_hp + _enemy_available_hero_block(state, db, opp)

	var attackers: Array[String] = []
	var total_atk := 0
	for aid in StackResolver.get_legal_attackers(state, player_id, db):
		var atk := BaseAI.forecast_atk(state, db, aid)   # "while attacking" bonuses + weapon strike
		if atk <= 0:
			continue
		if hero_id not in StackResolver.get_legal_defenders(state, aid, db):
			continue
		attackers.append(aid)
		total_atk += atk

	# Find the biggest damage spell in hand that's legal AND affordable right
	# now, and would close the gap together with the remaining attackers.
	var finisher: PendingAction = null
	var finisher_dmg := 0
	for card in state.cards_in_zone(player_id + "_hand"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var action_type := _action_type_for(card, db)
		if action_type != "play_instant" and action_type != "play_ability":
			continue
		var dmg := BaseAI._combat_instant_dmg(def)
		if dmg <= 0:
			continue
		var act := PendingAction.make(action_type, player_id,
				{"card_id": card.instance_id, "target_id": hero_id})
		if not StackResolver.can_submit(state, act, db):
			continue   # not legal/affordable this turn — doesn't count
		if total_atk + dmg >= threshold and dmg > finisher_dmg:
			finisher = act
			finisher_dmg = dmg

	if finisher == null:
		return null   # no spell in hand can close the gap right now

	# Allies attack first — hold the spell for the last hit.
	if not attackers.is_empty():
		var best := ""
		var best_val: Array = []
		for aid in attackers:
			var val := BaseAI._card_value_key(state, db, aid)
			if best == "" or val < best_val:
				best = aid
				best_val = val
		var atk_act := PendingAction.make("propose_combat", player_id,
				{"attacker_id": best, "defender_id": hero_id})
		return atk_act if StackResolver.can_submit(state, atk_act, db) else null

	# Every legal attacker has already swung this turn — deliver the finisher.
	return finisher


# Enemy hero's total available damage prevention right now: any pool already
# built at an open prevention point plus the DEF of every ready armor they
# could still exhaust when the packet lands (rule 717.2c — an all-out read
# must assume they use everything available).
func _enemy_available_hero_block(state: GameState, db, opp: String) -> int:
	var ps := state.players.get(opp) as PlayerState
	var block: int = ps.damage_prevention if ps else 0
	for card in state.cards_in_zone(opp + "_hero_row"):
		if card.is_exhausted:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.card_type != "Equipment":
			continue
		var dv := int(StackResolver._equipment_info(def).get("def", 0))
		if dv > 0:
			block += dv
	return block


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
		if BaseAI.forecast_atk(state, db, aid) > 0:
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
