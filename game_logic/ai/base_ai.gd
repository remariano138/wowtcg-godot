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
		if action_type in ["play_instant", "play_ability"] and db:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and StackResolver._instant_needs_target(def):
				# Targeted spell: one action per valid target.
				result.append_array(_targeted_instant_actions(state, db, player_id, card.instance_id))
				continue
		var action := PendingAction.make(action_type, player_id,
				{"card_id": card.instance_id})
		if StackResolver.can_submit(state, action, db):
			result.append(action)

	# Quest completions (face-up quests in resource row whose cost is payable).
	# Skip during combat windows — completing quests mid-combat is never useful and
	# prevents the attack/defend window from advancing cleanly.
	if not state.combat_attack_window and not state.combat_defend_window:
		for card in state.cards_in_zone(player_id + "_resource_row"):
			if card.face_down:
				continue
			if db:
				var def := db.get_def(card.card_def_id) as CardDef
				if not def or def.card_type != "Quest":
					continue
			var params := {"quest_id": card.instance_id}
			# Graveyard-target rewards: announce targets with the completion.
			# Target choice is an overridable hook (see _choose_graveyard_targets).
			if db:
				var q_def := db.get_def(card.card_def_id) as CardDef
				var gy_req := StackResolver.get_graveyard_search_requirement(q_def)
				if not gy_req.is_empty():
					var candidates := StackResolver.get_graveyard_search_candidates(
							state, player_id, gy_req, db)
					params["target_ids"] = _choose_graveyard_targets(
							state, db, player_id, gy_req, candidates)
			var action := PendingAction.make("use_quest", player_id, params)
			if StackResolver.can_submit(state, action, db):
				result.append(action)

	# Combat proposals (only valid in action phase with empty chain and no combat window open).
	if state.phase == "action" and state.turn_player == player_id \
			and state.pending_actions.is_empty() \
			and not state.combat_attack_window and not state.combat_defend_window:
		for atk_id in StackResolver.get_legal_attackers(state, player_id, db):
			if state.get_atk(atk_id, db) <= 0:
				continue   # never propose combat with a 0-ATK attacker
			for def_id in StackResolver.get_legal_defenders(state, atk_id, db):
				result.append(PendingAction.make("propose_combat", player_id,
					{"attacker_id": atk_id, "defender_id": def_id}))

	# Ally activated powers.
	result.append_array(_get_ally_power_actions(state, db, player_id))

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
	var dup_pick := candidates[randi() % candidates.size()]
	var dup_action := PendingAction.make("place_resource", player_id,
		{"card_id": dup_pick.instance_id, "face_up": false})
	if StackResolver.can_submit(state, dup_action, db):
		return dup_action

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
func _get_ally_power_actions(state: GameState, db, player_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	if state.phase != "action" or state.turn_player != player_id:
		return result
	if not state.pending_actions.is_empty():
		return result
	for card in state.cards_in_zone(player_id + "_ally_row"):
		if card.is_exhausted or card.just_summoned:
			continue
		if not db:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var ap := StackResolver._ally_activated_power(def)
		if ap.is_empty():
			continue
		if ap.get("targets", "") in ["hero_or_ally"]:
			var is_heal: bool = ap.get("effect", "") == "heal_target"
			var candidates: Array[String] = []
			if is_heal:
				# Heal: FRIENDLY damaged characters only — never heal the enemy.
				var ps_own := state.players.get(player_id) as PlayerState
				if ps_own and ps_own.hero_instance_id != "" \
						and state.get_card(ps_own.hero_instance_id).damage_taken > 0:
					candidates.append(ps_own.hero_instance_id)
				for ally in state.cards_in_zone(player_id + "_ally_row"):
					if ally.damage_taken > 0:
						candidates.append(ally.instance_id)
				if candidates.is_empty():
					continue   # nothing worth healing — don't waste the power
			else:
				# Damage: only consider enemy characters (never self-target friendlies).
				var opp := "p2" if player_id == "p1" else "p1"
				for ally in state.cards_in_zone(opp + "_ally_row"):
					candidates.append(ally.instance_id)
				var ps_opp := state.players.get(opp) as PlayerState
				if ps_opp and ps_opp.hero_instance_id != "":
					candidates.append(ps_opp.hero_instance_id)
			candidates.sort_custom(func(a: String, b: String) -> bool:
				var ca := state.get_card(a)
				var cb := state.get_card(b)
				var a_dmg := ca.damage_taken if ca else 0
				var b_dmg := cb.damage_taken if cb else 0
				return a_dmg > b_dmg)
			# Baseline: lethal targets first (hero-only when hero is lethal —
			# see find_lethal / ai_functions.md), ranked by the subclass hook,
			# then the remaining candidates in most-damaged order.
			var lethal := find_lethal(state, db, player_id, int(ap.get("amount", 0)))
			var lethal_pool: Array[String] = []
			for tid in candidates:
				if tid in lethal:
					lethal_pool.append(tid)
			var ordered: Array[String] = rank_lethal_targets(state, db, lethal_pool)
			for tid in candidates:
				if tid not in ordered:
					ordered.append(tid)
			for target_id in ordered:
				var act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": target_id})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
					break
		else:
			var action := PendingAction.make("use_ally_power", player_id,
				{"card_id": card.instance_id})
			if StackResolver.can_submit(state, action, db):
				result.append(action)
	return result


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
		# deal_x_damage_to_ally: pick best target and optimal X.
		if _hero_power_is(state, db, hero_id, "deal_x_damage_to_ally"):
			result.append_array(_x_damage_ally_actions(state, db, player_id, hero_id))
		# deal_7_minus_hand_to_hero: only fire when damage > 0 (enemy hand has < 7 cards).
		elif _hero_power_is(state, db, hero_id, "deal_7_minus_hand_to_hero"):
			var opp_id2 := _other_player_id(state, player_id)
			var opp_hand := state.cards_in_zone(opp_id2 + "_hand").size()
			var dmg2: int = max(7 - opp_hand, 0)
			if dmg2 > 0:
				var opp_ps2 := state.players.get(opp_id2) as PlayerState
				if opp_ps2 and opp_ps2.hero_instance_id != "":
					var action := PendingAction.make("activate_power", player_id,
						{"hero_id": hero_id, "target_id": opp_ps2.hero_instance_id})
					if StackResolver.can_submit(state, action, db):
						result.append(action)
		elif _hero_power_is(state, db, hero_id, "heal_x_from_target"):
			result.append_array(_x_heal_actions(state, db, player_id, hero_id))
		elif _hero_power_is(state, db, hero_id, "radak_pet_sacrifice"):
			result.append_array(_radak_sacrifice_actions(state, db, player_id, hero_id))
		# deal_damage_and_heal needs two distinct targets — enumerate all valid pairs.
		elif _hero_power_is(state, db, hero_id, "deal_damage_and_heal"):
			result.append_array(_damage_and_heal_actions(state, db, player_id, hero_id))
		else:
			# Single-target powers: enemy targets only (never damage/destroy own cards).
			var is_destroy_power := _hero_power_is(state, db, hero_id, "destroy_exhausted_ally")
			var power_cost := _hero_power_cost(state, db, hero_id)
			var opp_id3 := _other_player_id(state, player_id)
			var opp_ps3 := state.players.get(opp_id3) as PlayerState
			var legal: Array[PendingAction] = []
			var legal_ids: Array[String] = []
			if opp_ps3 and opp_ps3.hero_instance_id != "":
				var action := PendingAction.make("activate_power", player_id,
					{"hero_id": hero_id, "target_id": opp_ps3.hero_instance_id})
				if StackResolver.can_submit(state, action, db):
					legal.append(action)
					legal_ids.append(opp_ps3.hero_instance_id)
			for card in state.cards_in_zone(opp_id3 + "_ally_row"):
				var action := PendingAction.make("activate_power", player_id,
					{"hero_id": hero_id, "target_id": card.instance_id})
				if not StackResolver.can_submit(state, action, db):
					continue
				if is_destroy_power and not _destroy_is_worth_it(state, db, player_id, card.instance_id, power_cost):
					continue
				legal.append(action)
				legal_ids.append(card.instance_id)
			# Baseline for damage powers (e.g. Ta'zo): when any legal target dies
			# to this damage, offer ONLY lethal targets — so even a random AI
			# picks a kill (the hero alone if the hero is lethal). See
			# find_lethal / ai_functions.md.
			var dmg_amount := _hero_power_damage_amount(state, db, hero_id)
			if dmg_amount > 0:
				var lethal_pool: Array[String] = []
				for tid in find_lethal(state, db, player_id, dmg_amount):
					if tid in legal_ids:
						lethal_pool.append(tid)
				if not lethal_pool.is_empty():
					# Commit to the best-ranked kill (subclass hook decides "best").
					var top: String = rank_lethal_targets(state, db, lethal_pool)[0]
					legal = [legal[legal_ids.find(top)]]
			result.append_array(legal)
	else:
		var action := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": ""})
		if StackResolver.can_submit(state, action, db):
			result.append(action)

	return result


func _hero_power_is(state: GameState, db, hero_id: String, effect_key: String) -> bool:
	var hero := state.get_card(hero_id)
	if not hero or not db:
		return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def:
		return false
	return StackResolver._power_effect_is(def, effect_key)


# Picks the best (target, x_value) pair for deal_x_damage_to_ally powers.
# X heuristic: min(enemy ally current HP, hero HP - 1), floored at 1.
# Prefers: lethal hit on highest-cost target; among non-lethal, maximize damage.
# Protector ties are broken the same as _best_damage_target.
func _x_damage_ally_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	var hero_hp := state.get_current_hp(hero_id, db)
	if hero_hp <= 1:
		return []   # Can't use without killing self (x >= 1 required, x < hero_hp).
	var max_x := hero_hp - 1
	var opp_id := _other_player_id(state, player_id)
	# Gather enemy allies and their current HP.
	var candidates: Array = []
	for card in state.cards_in_zone(opp_id + "_ally_row"):
		candidates.append(card.instance_id)
	if candidates.is_empty():
		return []
	# Sort by: lethal first (highest cost wins ties), then most damage dealt.
	candidates.sort_custom(func(a: String, b: String) -> bool:
		var hp_a: int = state.get_current_hp(a, db)
		var hp_b: int = state.get_current_hp(b, db)
		var x_a: int = min(hp_a, max_x)
		var x_b: int = min(hp_b, max_x)
		var lethal_a: bool = x_a >= hp_a
		var lethal_b: bool = x_b >= hp_b
		if lethal_a != lethal_b:
			return lethal_a
		# Both lethal or both non-lethal: prefer highest cost, then protector.
		var da := _card_def(state, db, a)
		var db_ := _card_def(state, db, b)
		var cost_a := da.cost if da else 0
		var cost_b := db_.cost if db_ else 0
		if cost_a != cost_b:
			return cost_a > cost_b
		var prot_a: bool = da != null and "Protector" in da.keywords
		var prot_b: bool = db_ != null and "Protector" in db_.keywords
		return prot_a and not prot_b
	)
	for target_id in candidates:
		var target_hp := state.get_current_hp(target_id, db)
		# Use the minimum X that kills, or max affordable if non-lethal.
		var x_value: int = min(target_hp, max_x)
		if x_value < 1:
			continue
		var act := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": target_id, "x_value": x_value})
		if StackResolver.can_submit(state, act, db):
			return [act]
	return []


# heal_x_from_target AI: find the most-damaged friendly target; heal it for
# min(damage_on_target, available_resources). Only fires if target has damage.
# Hero is preferred over allies (keeping the hero alive matters most).
func _x_heal_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	var avail := state.get_available_resources(player_id)
	if avail < 1:
		return []
	# Collect damaged friendly targets: hero first, then allies.
	var candidates: Array[String] = []
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.hero_instance_id != "" and state.is_in_play(ps.hero_instance_id):
		candidates.append(ps.hero_instance_id)
	for card in state.cards_in_zone(player_id + "_ally_row"):
		candidates.append(card.instance_id)
	# Pick the target with the most damage taken (max_hp - current_hp).
	var best_target := ""
	var best_damage := 0
	for tid in candidates:
		var max_hp := state.get_max_hp(tid, db)
		var cur_hp := state.get_current_hp(tid, db)
		var dmg_on := max_hp - cur_hp
		if dmg_on > best_damage:
			best_damage = dmg_on
			best_target = tid
	if best_target == "" or best_damage < 3:
		return []
	var x_value: int = min(best_damage, avail)
	var act := PendingAction.make("activate_power", player_id,
		{"hero_id": hero_id, "target_id": best_target, "x_value": x_value})
	if StackResolver.can_submit(state, act, db):
		return [act]
	return []


# radak_pet_sacrifice AI: one action per owned Pet (AI sees each sacrifice as a distinct option).
# For each Pet, pairs with the best damage target for that Pet's cost as X.
# Skips Pets whose cost is 0 (X=0 deals no damage).
func _radak_sacrifice_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	var opp_id := _other_player_id(state, player_id)
	# Collect enemy targets for damage heuristic.
	var all_targets: Array[String] = []
	var opp_ps := state.players.get(opp_id) as PlayerState
	if opp_ps and opp_ps.hero_instance_id != "":
		all_targets.append(opp_ps.hero_instance_id)
	for card in state.cards_in_zone(opp_id + "_ally_row"):
		all_targets.append(card.instance_id)
	if all_targets.is_empty():
		return []

	var result: Array[PendingAction] = []
	for pet_card in state.cards_in_zone(player_id + "_ally_row"):
		var pet_def := _card_def(state, db, pet_card.instance_id)
		if not pet_def or pet_def.card_subtype != "Pet":
			continue
		var x_value: int = pet_def.cost
		if x_value < 1:
			continue
		var best_target := _best_damage_target(state, db, player_id, all_targets, x_value)
		if best_target == "":
			continue
		var act := PendingAction.make("activate_power", player_id, {
			"hero_id":   hero_id,
			"pet_id":    pet_card.instance_id,
			"target_id": best_target,
			"x_value":   x_value,
		})
		if StackResolver.can_submit(state, act, db):
			result.append(act)
	return result


# Use the targeted-damage and targeted-heal heuristics to pick the single best
# (dmg_target, heal_target) pair for deal_damage_and_heal powers.
func _damage_and_heal_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	# Parse damage amount from effect string (format: deal_damage_and_heal:DMG:type:HEAL).
	var def := _card_def(state, db, hero_id)
	var damage := 3
	if def:
		var parts := def.effects.split(":")
		if parts.size() > 1:
			damage = int(parts[1])

	# Collect every in-play character.
	var all_ids: Array[String] = []
	for pid in state.players:
		var ps2 := state.players.get(pid) as PlayerState
		if ps2 and ps2.hero_instance_id != "":
			all_ids.append(ps2.hero_instance_id)
		for card in state.cards_in_zone(pid + "_ally_row"):
			all_ids.append(card.instance_id)

	# Find valid damage targets — enemy only (never damage own characters).
	var valid_dmg: Array[String] = []
	for dmg_id in all_ids:
		var dmg_card := state.get_card(dmg_id)
		if not dmg_card or dmg_card.controller == player_id:
			continue
		for heal_id in all_ids:
			if heal_id == dmg_id:
				continue
			var act := PendingAction.make("activate_power", player_id,
				{"hero_id": hero_id, "target_id": dmg_id, "heal_target_id": heal_id})
			if StackResolver.can_submit(state, act, db):
				valid_dmg.append(dmg_id)
				break

	if valid_dmg.is_empty():
		return []

	var best_dmg := _best_damage_target(state, db, player_id, valid_dmg, damage)
	if best_dmg == "":
		return []

	# Find valid heal targets for the chosen damage target — friendly only.
	var valid_heal: Array[String] = []
	for heal_id in all_ids:
		if heal_id == best_dmg:
			continue
		var heal_card := state.get_card(heal_id)
		if not heal_card or heal_card.controller != player_id:
			continue
		var act := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": best_dmg, "heal_target_id": heal_id})
		if StackResolver.can_submit(state, act, db):
			valid_heal.append(heal_id)

	if valid_heal.is_empty():
		return []

	var best_heal := _best_heal_target(state, db, player_id, valid_heal)
	if best_heal == "":
		return []

	var final_act := PendingAction.make("activate_power", player_id,
		{"hero_id": hero_id, "target_id": best_dmg, "heal_target_id": best_heal})
	if StackResolver.can_submit(state, final_act, db):
		return [final_act]
	return []


# Damage dealt by a deal_damage_to_target hero power (format:
# deal_damage_to_target:AMOUNT:DMG_TYPE). 0 if the hero has no such power.
func _hero_power_damage_amount(state: GameState, db, hero_id: String) -> int:
	var def := _card_def(state, db, hero_id)
	if not def:
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "deal_damage_to_target":
			return int(parts[1]) if parts.size() > 1 else 0
	return 0


func _hero_power_cost(state: GameState, db, hero_id: String) -> int:
	var def := _card_def(state, db, hero_id)
	return def.cost if def else 0


# ── sort_valuable_cards ─────────────────────────────────────────────────────
# See game_logic/ai/ai_functions.md for the full contract.
# Sorts card instance ids from most to least valuable (simple printed-stats
# heuristic): rarity > cost > allies-before-non-allies > Protector > HP >
# Ferocity > Elusive > ATK > random.
const _RARITY_RANK := {"epic": 3, "rare": 2, "uncommon": 1, "common": 0}

static func sort_valuable_cards(state: GameState, db,
		card_ids: Array[String]) -> Array[String]:
	var result: Array[String] = card_ids.duplicate()
	result.shuffle()   # random final tiebreak — everything else is deterministic
	result.sort_custom(func(a: String, b: String) -> bool:
		return _card_value_key(state, db, a) > _card_value_key(state, db, b))
	return result


# Lexicographic value key for sort_valuable_cards. Non-allies zero out the
# combat fields, so at equal rarity+cost an ally always outranks a non-ally.
# HP/ATK use current values for in-play cards (a 3-HP-left target is worth
# more than a 1-HP-left one), printed values for out-of-play cards (graveyard).
static func _card_value_key(state: GameState, db, cid: String) -> Array:
	var card := state.get_card(cid)
	var def: CardDef = db.get_def(card.card_def_id) if (card and db) else null
	if not def:
		return [0, 0, 0, 0, 0, 0, 0, 0]
	var kw: Array[String] = []
	for k in def.keywords:
		kw.append(str(k).to_lower())
	var is_ally := def.card_type == "Ally"
	var hp  := def.printed_health
	var atk := def.printed_atk
	if state.is_in_play(cid):
		hp  = state.get_current_hp(cid, db)
		atk = state.get_atk(cid, db)
	return [
		_RARITY_RANK.get(def.rarity.to_lower(), 0),
		def.cost,
		1 if is_ally else 0,
		1 if is_ally and "protector" in kw else 0,
		hp if is_ally else 0,
		1 if is_ally and "ferocity" in kw else 0,
		1 if is_ally and "elusive" in kw else 0,
		atk if is_ally else 0,
	]


# Hook: pick graveyard targets for a quest reward (Chasing A-Me, Darrowshire).
# Base heuristic: to hand → highest-cost candidates (best card back);
# to RFG → lowest-cost ones (removing your own cards is a cost, not a gain).
# Subclasses may override (GenericAI uses sort_valuable_cards).
func _choose_graveyard_targets(state: GameState, db, _player_id: String,
		gy_req: Dictionary, candidates: Array[String]) -> Array[String]:
	var picks := candidates.duplicate()
	var to_rfg: bool = gy_req.get("dest", "hand") == "rfg"
	picks.sort_custom(func(a, b):
		if to_rfg:
			return _def_cost(state, db, a) < _def_cost(state, db, b)
		return _def_cost(state, db, a) > _def_cost(state, db, b))
	var take: int = min(int(gy_req.get("max_count", 1)), picks.size())
	return picks.slice(0, take)


# Hook: pick the card to discard when this player must discard (wrap-up or
# card effect). Called once per card by the scene. Base heuristic: lowest-cost
# non-quest/location card; fall back to a random quest/location.
func choose_discard_card(state: GameState, db, player_id: String) -> String:
	var hand := state.cards_in_zone(player_id + "_hand")
	if hand.is_empty():
		return ""
	var non_resource: Array[String] = []
	var resource_only: Array[String] = []
	for card in hand:
		var def: CardDef = db.get_def(card.card_def_id) if db else null
		if def and def.card_type in ["Quest", "Location"]:
			resource_only.append(card.instance_id)
		else:
			non_resource.append(card.instance_id)
	if not non_resource.is_empty():
		non_resource.sort_custom(func(a, b) -> bool:
			return _def_cost(state, db, a) < _def_cost(state, db, b))
		return non_resource[0]
	return resource_only[randi() % resource_only.size()]


# Hook: order a find_lethal pool before this AI commits to a target.
# Base keeps the incoming order (hero first, then ally_row order); subclasses
# decide if and when to apply a real heuristic (FullRandomAI sorts by
# sort_valuable_cards so it always kills the most valuable target).
func rank_lethal_targets(state: GameState, db,
		lethal: Array[String]) -> Array[String]:
	return lethal


# ── find_lethal ────────────────────────────────────────────────────────────
# See game_logic/ai/ai_functions.md for the full contract.
# Returns opposing in-play characters that would die to `damage` points
# (current HP <= damage). If the opposing HERO is lethal, returns ONLY the
# hero — killing the hero wins the game, nothing else matters.
static func find_lethal(state: GameState, db, player_id: String,
		damage: int) -> Array[String]:
	var result: Array[String] = []
	if damage <= 0:
		return result
	var opp := "p2" if player_id == "p1" else "p1"
	var ps_opp := state.players.get(opp) as PlayerState
	if ps_opp and ps_opp.hero_instance_id != "" \
			and state.is_in_play(ps_opp.hero_instance_id) \
			and state.get_current_hp(ps_opp.hero_instance_id, db) <= damage:
		result.append(ps_opp.hero_instance_id)
		return result
	for card in state.cards_in_zone(opp + "_ally_row"):
		if state.get_current_hp(card.instance_id, db) <= damage:
			result.append(card.instance_id)
	return result


# ── find_safe_lethals ───────────────────────────────────────────────────────
# See game_logic/ai/ai_functions.md for the full contract.
# For every (attacker, defender) combination, keeps the pairs where the
# attacker kills AND survives:
#   attacker current ATK >= defender current HP
#   attacker current HP  >  defender current ATK
# Returns an Array of [attacker_id, defender_id] pairs. Pure math — no
# combat-legality check (Elusive, exhaustion, …); callers filter with
# can_submit / get_legal_defenders.
static func find_safe_lethals(state: GameState, db, attackers: Array[String],
		defenders: Array[String]) -> Array:
	var result: Array = []
	for a in attackers:
		var a_atk := state.get_atk(a, db)
		var a_hp  := state.get_current_hp(a, db)
		for d in defenders:
			if a_atk >= state.get_current_hp(d, db) \
					and a_hp > state.get_atk(d, db):
				result.append([a, d])
	return result


# ── Targeted damage heuristic ──────────────────────────────────────────────
# Picks the best damage target from a list of candidate instance IDs.
# Priority 0 — lethal on enemy hero.
# Priority 1 — any lethal hit; tiebreak: highest HP → highest cost →
#              Protector → Elusive → first in list.
# Priority 2 — no lethal: maximize effective damage dealt (min(dmg, cur_hp)).
func _best_damage_target(state: GameState, db, player_id: String,
		candidates: Array[String], damage: int) -> String:
	if candidates.is_empty():
		return ""
	var enemy_pid := _other_player_id(state, player_id)
	var ep := state.players.get(enemy_pid) as PlayerState
	var enemy_hero_id: String = ep.hero_instance_id if ep else ""

	# Priority 0: lethal on enemy hero (find_lethal returns only the hero then).
	var lethal_scan := find_lethal(state, db, player_id, damage)
	if lethal_scan.size() == 1 and lethal_scan[0] == enemy_hero_id \
			and enemy_hero_id in candidates:
		return enemy_hero_id

	var lethal: Array[String] = []
	var non_lethal: Array[String] = []
	for c in candidates:
		if state.get_current_hp(c, db) <= damage:
			lethal.append(c)
		else:
			non_lethal.append(c)

	if not lethal.is_empty():
		lethal.sort_custom(func(a: String, b: String) -> bool:
			var hp_a := state.get_current_hp(a, db)
			var hp_b := state.get_current_hp(b, db)
			if hp_a != hp_b:
				return hp_a > hp_b
			var da := _card_def(state, db, a)
			var db_ := _card_def(state, db, b)
			var cost_a := da.cost if da else 0
			var cost_b := db_.cost if db_ else 0
			if cost_a != cost_b:
				return cost_a > cost_b
			var prot_a: bool = da != null and "Protector" in da.keywords
			var prot_b: bool = db_ != null and "Protector" in db_.keywords
			if prot_a != prot_b:
				return prot_a
			var elu_a: bool = da != null and "Elusive" in da.keywords
			var elu_b: bool = db_ != null and "Elusive" in db_.keywords
			return elu_a and not elu_b
		)
		return lethal[0]

	# Priority 2: maximize effective damage.
	non_lethal.sort_custom(func(a: String, b: String) -> bool:
		return min(damage, state.get_current_hp(a, db)) > min(damage, state.get_current_hp(b, db))
	)
	return non_lethal[0]


# ── Targeted heal heuristic ────────────────────────────────────────────────
# Picks the most damaged friendly character from candidates.
# Allies are preferred over the hero, UNLESS the hero is at ≤ 1/3 of its max HP
# (then the hero's survival outweighs keeping an ally).
func _best_heal_target(state: GameState, db, player_id: String,
		candidates: Array[String]) -> String:
	if candidates.is_empty():
		return ""
	var ps := state.players.get(player_id) as PlayerState
	var hero_id: String = ps.hero_instance_id if ps else ""
	var hero_low_hp := false
	if hero_id != "" and hero_id in candidates:
		hero_low_hp = state.get_current_hp(hero_id, db) <= 12

	var best := candidates[0]
	for i in range(1, candidates.size()):
		var cid := candidates[i]
		var cid_card := state.get_card(cid)
		if not cid_card:
			continue
		var cid_is_hero := (cid == hero_id)
		var best_is_hero := (best == hero_id)
		# Bucket preference.
		if hero_low_hp:
			if cid_is_hero and not best_is_hero:
				best = cid
				continue
			if not cid_is_hero and best_is_hero:
				continue
		else:
			if not cid_is_hero and best_is_hero:
				best = cid
				continue
			if cid_is_hero and not best_is_hero:
				continue
		# Same bucket: most damage_taken wins.
		var best_card := state.get_card(best)
		if best_card and cid_card.damage_taken > best_card.damage_taken:
			best = cid
	return best


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
		var key := entry.strip_edges().split(":")[0].strip_edges()
		if key in ["deal_damage_to_target", "destroy_exhausted_ally", "deal_damage_and_heal", "deal_x_damage_to_ally", "deal_7_minus_hand_to_hero", "heal_x_from_target", "radak_pet_sacrifice"]:
			return true
	return false


func _other_player_id(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id


func _targeted_instant_actions(state: GameState, db, player_id: String,
		card_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	var spell_card := state.get_card(card_id)
	var spell_def  := db.get_def(spell_card.card_def_id) as CardDef if spell_card else null

	var opp := "p2" if player_id == "p1" else "p1"
	for ally in state.cards_in_zone(opp + "_ally_row"):
		var act := PendingAction.make("play_instant", player_id,
			{"card_id": card_id, "target_id": ally.instance_id})
		if not StackResolver.can_submit(state, act, db):
			continue
		if spell_def and _effect_is_destroy_ally(spell_def) \
				and not _destroy_is_worth_it(state, db, player_id, ally.instance_id, spell_def.cost):
			continue
		result.append(act)
	# Heroes are valid targets only if the spell allows it (destroy_target:ally excludes them).
	if spell_def and not _effect_is_destroy_ally(spell_def):
		var ps_opp := state.players.get(opp) as PlayerState
		if ps_opp and ps_opp.hero_instance_id != "":
			var act := PendingAction.make("play_instant", player_id,
				{"card_id": card_id, "target_id": ps_opp.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(act)
	return result


# Returns true if this spell's effects include destroy_target:ally.
func _effect_is_destroy_ally(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "destroy_target" and parts.size() > 1 and parts[1] == "ally":
			return true
	return false


# A destroy effect is "worth it" on a target if:
#   - Target's cost >= spell cost (value-neutral or better trade)
#   - AND no single ready friendly ally can solo-kill it in combat (ATK >= target current HP)
# Un-attackable targets (Elusive, "can't attack" effects, etc.) fail the solo-lethal check
# naturally since get_legal_defenders won't include them — no special keyword check needed.
func _destroy_is_worth_it(state: GameState, db, player_id: String,
		target_id: String, spell_cost: int) -> bool:
	var t_def  := _card_def(state, db, target_id)
	var t_cost := t_def.cost if t_def else 0
	if t_cost < spell_cost:
		return false
	var t_hp := state.get_current_hp(target_id, db)
	return not _has_solo_lethal_attacker(state, db, player_id, target_id, t_hp)


# Returns true if any single ready ally controlled by player_id can legally attack
# target_id and has ATK >= target's current HP (solo kill without needing another attacker).
func _has_solo_lethal_attacker(state: GameState, db, player_id: String,
		target_id: String, target_hp: int) -> bool:
	for ally in state.cards_in_play(player_id):
		if state.get_atk(ally.instance_id, db) >= target_hp:
			var legal := StackResolver.get_legal_defenders(state, ally.instance_id, db)
			if target_id in legal:
				return true
	return false


func _card_def(state: GameState, db, card_id: String) -> CardDef:
	var card := state.get_card(card_id)
	if not card or not db:
		return null
	return db.get_def(card.card_def_id) as CardDef


func _def_cost(state: GameState, db, card_id: String) -> int:
	var def := _card_def(state, db, card_id)
	return def.cost if def else 0


func _action_type_for(card: CardInstance, db) -> String:
	if not db:
		return "play_ally"
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return ""
	if def.card_type in ["Quest", "Location"]:
		return ""   # go to resource row via place_resource
	if def.card_type == "Ally":
		return "play_ally"
	if def.is_instant:
		return "play_instant"
	if def.card_type == "Ability":
		return "play_ability"
	return ""
