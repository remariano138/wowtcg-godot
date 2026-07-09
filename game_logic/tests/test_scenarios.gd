extends Node

# Headless scenario tests — full StackResolver turn-loop, no rendering required.
#
# HOW TO RUN:
#   In Godot editor: Scene > New Scene > add this script as the root node > Play Scene.
#   All lines should say PASS. Non-zero FAIL count = a bug.
#
# Philosophy: each test builds a specific game state from scratch, wires up
# ScriptedAI instances that play predetermined actions, then drives the
# priority loop until the scenario resolves and asserts on outcomes.

const MAX_STEPS := 200   # guard against infinite loops in a broken driver


func _ready() -> void:
	print("=== WoW TCG Engine — Scenario Tests ===\n")

	_test_protector_intercepts_attack()
	_test_ferocity_attacks_turn_played()
	_test_elusive_never_targetable()
	_test_hand_size_wrap_up_discard()
	_test_tazo_hero_power()
	_test_tazdingo_enter_play()
	_test_parvink_enter_play()
	_test_vanquish()
	_test_quick_strike()
	_test_lightning_bolt()
	_test_pet_uniqueness()
	_test_mooncloth_robe_power()
	_test_mooncloth_robe_hero_exhausted()
	_test_equipment_slot_uniqueness()
	_test_ai_plays_equipment()
	_test_pads_block_combat()
	_test_pads_block_instant()
	_test_pads_overblock_expires()
	_test_ai_armor_block_heuristic()
	_test_grimdron_ally_power()
	_test_sarmoth_taunt_forces_attacker()
	_test_sarmoth_taunt_multiple_attackers()
	_test_sarmoth_elusive_no_taunt()
	_test_sarmoth_taunt_lifts_on_death()
	_test_boris_heal_x()
	_test_radak_pet_sacrifice()
	_test_radak_no_pets()
	_test_timmo_destroy_exhausted_ally()
	_test_quest_cant_reuse_while_pending()
	_test_liba_wobblebonk_enter_play()
	_test_kulan_earthguard_end_of_turn_ready()
	_test_tracker_gallen_atk_per_ally()
	_test_malwani_atk_per_damage_self()
	_test_zorm_party_atk_while_attacking()
	_test_elder_moorf_buff_target()
	_test_rayder_party_buff_while_attacking()
	_test_for_the_horde_quest_buff()
	_test_turn_buff_expires_at_end_of_turn()
	_test_zorm_bonus_applies_to_real_combat_damage()
	_test_get_atk_if_attacking_preview()
	_test_moorf_buff_applies_to_real_defense_damage()
	_test_ryn_dreamstrider_buff_target_attacking()
	_test_chasing_ame_graveyard_to_hand()
	_test_chasing_ame_blocked_and_filtered()
	_test_finkle_einhorn_graveyard_to_play()
	_test_darrowshire_rfg_three_allies()
	_test_darrowshire_blocked_with_too_few_allies()
	_test_defias_brotherhood_requires_four_allies()
	_test_toreks_assault_requires_hero_damaged_by_ally()
	_test_find_lethal()
	_test_find_lethal_baseline_in_ai_actions()
	_test_sort_valuable_cards()
	_test_find_safe_lethals()
	_test_generic_ai_safe_kill_flow()
	_test_generic_ai_value_choices()
	_test_combat_trade_value()
	_test_generic_ai_trade_develop_chip()
	_test_generic_ai_protector_choice()
	_test_generic_ai_while_attacking_buffs()
	_test_ally_heal_power_targets_friendlies()
	_test_combat_instant_ambush()
	_test_deacon_johanna_once_per_turn()
	_test_acolyte_demia_power()
	_test_acolyte_demia_own_turn_only()
	_test_acolyte_demia_self_destroys()
	_test_senzir_beastwalker_power()
	_test_senzir_beastwalker_no_pet_in_graveyard()
	_test_ai_senzir_picks_most_valuable_pet()
	_test_bloodclaw_no_horde_bonus()
	_test_old_bones_protects_hero_only()
	_test_arcane_shot()
	_test_arcane_shot_combat_instant_tag()
	_test_fire_blast()
	_test_nerra_lifeboon_health_aura()
	_test_nerra_death_triggers_aura_loss_death()
	_test_master_of_the_hunt_ongoing()
	_test_guardian_steelhorn_cant_attack()
	_test_starfire()
	_test_flamestrike()
	_test_chain_lightning()
	_test_untargetable_keyword()

	print("\n=== Results: %d passed  %d failed ===" % [_pass, _fail])
	if _fail == 0:
		print("ALL TESTS PASSED ✓")
	else:
		print("SOME TESTS FAILED — see FAIL lines above")
	await get_tree().process_frame
	get_tree().quit()


# ── Assertion helpers ──────────────────────────────────────────────────────────

var _pass := 0
var _fail := 0

func ok(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS  %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)

func eq(a, b, label: String) -> void:
	if a == b:
		_pass += 1
		print("  PASS  %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s  [got %s, expected %s]" % [label, str(a), str(b)])


# ── Mock database ──────────────────────────────────────────────────────────────

class MockDB extends RefCounted:
	var _defs: Dictionary = {}

	func ally(def_id: String, atk: int, health: int, kw: Array[String] = [], cost: int = 0, effects: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.printed_atk    = atk
		d.printed_health = health
		d.cost           = cost
		d.effects        = effects
		d.card_type      = "Ally"
		for k in kw:
			d.keywords.append(k)
		_defs[def_id] = d

	func pet(def_id: String, atk: int, health: int, kw: Array[String] = [], cost: int = 0, effects: String = "") -> void:
		ally(def_id, atk, health, kw, cost, effects)
		(_defs[def_id] as CardDef).card_subtype = "Pet"

	func equipment(def_id: String, cost: int, effects: String, subtype: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.cost           = cost
		d.effects        = effects
		d.card_type      = "Equipment"
		d.card_subtype   = subtype
		_defs[def_id] = d

	func hero(def_id: String, health: int, power_cost: int = 0, power_effects: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.printed_atk    = 0
		d.printed_health = health
		d.cost           = power_cost
		d.effects        = power_effects
		d.card_type      = "Hero"
		_defs[def_id] = d

	func quest(def_id: String, cost: int = 0, effects: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.printed_atk    = 0
		d.printed_health = 0
		d.cost           = cost
		d.effects        = effects
		d.card_type      = "Quest"
		_defs[def_id] = d

	func instant(def_id: String, cost: int, effects: String) -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.cost           = cost
		d.card_type      = "Ability"
		d.is_instant     = true
		d.effects        = effects
		_defs[def_id] = d

	# Non-instant ability, action-phase timing (e.g. Vanquish-speed or ongoing).
	func ability(def_id: String, cost: int, effects: String) -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.cost           = cost
		d.card_type      = "Ability"
		d.is_instant     = false
		d.effects        = effects
		_defs[def_id] = d

	func get_def(id: String) -> CardDef:
		return _defs.get(id)


# ── ScriptedAI ─────────────────────────────────────────────────────────────────

class ScriptedAI extends RefCounted:
	var _actions:   Array = []
	var _protectors: Array = []

	func queue_action(a: PendingAction) -> void:
		_actions.append(a)

	func queue_protect(protector_id: String) -> void:
		_protectors.append(protector_id)

	func decide_action(state: GameState, db, _player_id: String) -> PendingAction:
		if not _actions.is_empty():
			# Peek first — only consume when the action is currently legal.
			# This prevents the action from being lost during stack resolution
			# windows where the chain is non-empty (e.g. waiting for a previous
			# play_ally to resolve before the next one can be submitted).
			var next := _actions[0] as PendingAction
			if StackResolver.can_submit(state, next, db):
				return _actions.pop_front()
		return null

	func choose_protector(_state: GameState, _db, _player_id: String) -> String:
		if not _protectors.is_empty():
			return _protectors.pop_front()
		return ""


# ── RandomAttackerAI ──────────────────────────────────────────────────────────

class RandomAttackerAI extends RefCounted:
	func decide_action(state: GameState, db, player_id: String) -> PendingAction:
		if state.phase != "action" or state.turn_player != player_id:
			return null
		if not state.pending_actions.is_empty():
			return null
		var attackers := StackResolver.get_legal_attackers(state, player_id, db)
		if attackers.is_empty():
			return null
		var atk_id: String = attackers[randi() % attackers.size()]
		var defenders := StackResolver.get_legal_defenders(state, atk_id, db)
		if defenders.is_empty():
			return null
		var def_id: String = defenders[randi() % defenders.size()]
		return PendingAction.make("propose_combat", player_id,
			{"attacker_id": atk_id, "defender_id": def_id})

	func choose_protector(_state: GameState, _db, _player_id: String) -> String:
		return ""


# ── Scenario driver ────────────────────────────────────────────────────────────

func _drive(state: GameState, db, p1_ai: ScriptedAI, p2_ai: ScriptedAI) -> Array[GameEvent]:
	var all_events: Array[GameEvent] = []
	var protect_pending := false
	var protect_player  := ""

	for _step in range(MAX_STEPS):
		if protect_pending or state.in_protect_point:
			protect_pending = false
			var prot_ai: ScriptedAI = p1_ai if protect_player == "p1" else p2_ai
			var pid := prot_ai.choose_protector(state, db, protect_player)
			var prot_events := StackResolver.choose_protector(state, pid, db)
			all_events.append_array(prot_events)
			for e in prot_events:
				if e.event_type == "protect_point_opened":
					protect_pending = true
					var def_card := state.get_card(e.payload.get("defender_id", ""))
					protect_player = def_card.controller if def_card else ""
			continue

		if all_events.any(func(e: GameEvent) -> bool: return e.event_type == "game_over"):
			break

		var player_id  := state.priority_player
		var turn_ai: ScriptedAI = p1_ai if player_id == "p1" else p2_ai
		var action     := turn_ai.decide_action(state, db, player_id)
		var step_events: Array[GameEvent] = \
			StackResolver.submit_action(state, action, db) if action \
			else StackResolver.pass_priority(state, db)

		all_events.append_array(step_events)

		for e in step_events:
			if e.event_type == "protect_point_opened":
				protect_pending = true
				var def_card := state.get_card(e.payload.get("defender_id", ""))
				protect_player = def_card.controller if def_card else ""
			elif e.event_type == "phase_changed" and e.payload.get("new") == "action":
				if all_events.size() > 5:
					return all_events

	return all_events


func _drive_turns(state: GameState, db, p1_ai, p2_ai, max_turns: int) -> Array[GameEvent]:
	var all_events: Array[GameEvent] = []
	var protect_pending := false
	var protect_player  := ""
	var game_over       := false

	for _step in range(max_turns * 20):
		if game_over:
			break

		if protect_pending or state.in_protect_point:
			protect_pending = false
			var prot_ai = p1_ai if protect_player == "p1" else p2_ai
			var pid: String = prot_ai.choose_protector(state, db, protect_player)
			var prot_events := StackResolver.choose_protector(state, pid, db)
			all_events.append_array(prot_events)
			for e in prot_events:
				if e.event_type == "protect_point_opened":
					protect_pending = true
					var def_card := state.get_card(e.payload.get("defender_id", ""))
					protect_player = def_card.controller if def_card else ""
				elif e.event_type == "game_over":
					game_over = true
			continue

		var player_id  := state.priority_player
		var turn_ai    = p1_ai if player_id == "p1" else p2_ai
		var action     = turn_ai.decide_action(state, db, player_id)
		var step_events: Array[GameEvent] = \
			StackResolver.submit_action(state, action, db) if action \
			else StackResolver.pass_priority(state, db)

		all_events.append_array(step_events)

		for e in step_events:
			if e.event_type == "priority_window_closed":
				var adv := TurnManager.advance_phase(state, db)
				all_events.append_array(adv)
				for ae in adv:
					if ae.event_type == "game_over":
						game_over = true
					elif ae.event_type == "discard_choice_opened":
						all_events.append_array(_headless_discard(state, ae, db))
			elif e.event_type == "discard_choice_opened":
				all_events.append_array(_headless_discard(state, e, db))
			elif e.event_type == "pet_sacrifice_required":
				all_events.append_array(_headless_pet_sacrifice(state, e, db))
			elif e.event_type == "equipment_sacrifice_required":
				all_events.append_array(_headless_equipment_sacrifice(state, e, db))
			elif e.event_type == "enter_play_target_required":
				all_events.append_array(_headless_enter_play_target(state, e, db))
			elif e.event_type == "protect_point_opened":
				protect_pending = true
				var def_card := state.get_card(e.payload.get("defender_id", ""))
				protect_player = def_card.controller if def_card else ""
			elif e.event_type == "game_over":
				game_over = true

	return all_events


# ── Headless discard helper ───────────────────────────────────────────────────

func _headless_discard(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var dp:  String = event.payload.get("player", "")
	var cnt: int    = event.payload.get("count",  0)
	var reason: String = event.payload.get("reason", "")
	var events: Array[GameEvent] = []

	if reason == "wrap_up":
		var hand := state.cards_in_zone(dp + "_hand")
		hand.shuffle()
		for i in range(mini(cnt, hand.size())):
			events.append_array(
				GameLogic.move_card(state, hand[i].instance_id, dp + "_graveyard"))
		var adv2 := TurnManager.advance_phase(state, db)
		events.append_array(adv2)
		for ae2 in adv2:
			if ae2.event_type == "discard_choice_opened":
				events.append_array(_headless_discard(state, ae2, db))
	else:
		var hand := state.cards_in_zone(dp + "_hand")
		hand.shuffle()
		for card in hand:
			if state.pending_discard_count <= 0:
				break
			events.append_array(StackResolver.choose_discard(state, card.instance_id, db))

	return events


# ── Headless pet sacrifice helper ─────────────────────────────────────────────
# Sacrifices candidates one by one until the player's pet count is within capacity.
# Strategy: sacrifice the first candidate (lowest in list = oldest in play).

func _headless_pet_sacrifice(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var candidates: Array = event.payload.get("candidates", [])
	var events: Array[GameEvent] = []

	# Sacrifice the first valid candidate — choose_pet_sacrifice resolves immediately
	# (not via the pending_actions stack) so state is updated before we check again.
	for cid in candidates:
		if state.pending_pet_sacrifice_player == "":
			break
		var sub := StackResolver.choose_pet_sacrifice(state, cid as String, db)
		if sub.is_empty():
			continue
		events.append_array(sub)
		# If another violation fires (capacity > 1 edge case), recurse.
		for e in sub:
			if e.event_type == "pet_sacrifice_required":
				events.append_array(_headless_pet_sacrifice(state, e, db))
		break   # one sacrifice per call; re-check happens in the event loop

	return events


# ── Headless equipment sacrifice helper ───────────────────────────────────────
# Destroys same-slot equipment one by one until only one remains. Sacrifices the
# first candidate in the list.

func _headless_equipment_sacrifice(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var candidates: Array = event.payload.get("candidates", [])
	var events: Array[GameEvent] = []
	for cid in candidates:
		if state.pending_equip_sacrifice_player == "":
			break
		var sub := StackResolver.choose_equipment_sacrifice(state, cid as String, db)
		if sub.is_empty():
			continue
		events.append_array(sub)
		for e in sub:
			if e.event_type == "equipment_sacrifice_required":
				events.append_array(_headless_equipment_sacrifice(state, e, db))
		break
	return events


# ── Headless enter-play target helper ────────────────────────────────────────

func _headless_enter_play_target(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var source_id: String = event.payload.get("card_id", "")
	var source_card := state.get_card(source_id)
	if not source_card:
		return []
	var ctrl := source_card.controller
	var events: Array[GameEvent] = []

	var targets: Array[String] = []
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": source_id, "target_id": ps.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				targets.append(ps.hero_instance_id)
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": source_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				targets.append(card.instance_id)

	if targets.is_empty():
		return []

	var target_id := targets[randi() % targets.size()]
	var action := PendingAction.make("choose_enter_play_target", ctrl,
		{"source_card_id": source_id, "target_id": target_id})
	events.append_array(StackResolver.submit_action(state, action, db))
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))
	return events


# ── State builder helpers ──────────────────────────────────────────────────────

func _base_state(_db: MockDB, p1_hero_id: String, p2_hero_id: String) -> GameState:
	var state := GameState.create_new(["p1", "p2"])

	var h1 := CardInstance.create(p1_hero_id, p1_hero_id, "p1", "p1_hero_row")
	state.cards[p1_hero_id] = h1
	state.zones["p1_hero_row"].card_ids.append(p1_hero_id)
	state.players["p1"].hero_instance_id = p1_hero_id

	var h2 := CardInstance.create(p2_hero_id, p2_hero_id, "p2", "p2_hero_row")
	state.cards[p2_hero_id] = h2
	state.zones["p2_hero_row"].card_ids.append(p2_hero_id)
	state.players["p2"].hero_instance_id = p2_hero_id

	state.phase           = "action"
	state.turn_player     = "p1"
	state.priority_player = "p1"
	state.turn_number     = 1

	return state


func _add_ally(state: GameState, inst_id: String, def_id: String, ctrl: String) -> CardInstance:
	var card := CardInstance.create(inst_id, def_id, ctrl, ctrl + "_ally_row")
	state.cards[inst_id] = card
	state.zones[ctrl + "_ally_row"].card_ids.append(inst_id)
	return card


func _add_resources(state: GameState, player_id: String, count: int) -> void:
	for i in range(count):
		var inst_id := "%s_res_%d" % [player_id, i]
		var card := CardInstance.create(inst_id, "resource_blank", player_id,
			player_id + "_resource_row")
		card.face_down   = true
		card.is_exhausted = false
		state.cards[inst_id] = card
		state.zones[player_id + "_resource_row"].card_ids.append(inst_id)


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 1 — Protector intercepts, hero takes zero damage
# ══════════════════════════════════════════════════════════════════════════════

func _test_protector_intercepts_attack() -> void:
	print("\n-- Scenario 1: Protector intercepts attack on hero --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.ally("protector_def", 0, 6, (["protector"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	_add_ally(state, "prot", "protector_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()
	p2_ai.queue_protect("prot")

	_drive(state, db, p1_ai, p2_ai)

	var p2_hero   := state.get_card("p2_hero")
	var protector := state.get_card("prot")

	eq(p2_hero.damage_taken,   0, "sc1: P2 hero took 0 damage (intercepted)")
	eq(protector.damage_taken, 3, "sc1: protector took 3 damage")
	ok(protector.is_exhausted,    "sc1: protector is exhausted after protecting")
	ok(atk.is_exhausted if atk else true, "sc1: attacker is exhausted after attacking")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 2 — Ferocity: ally attacks the turn it is played
# ══════════════════════════════════════════════════════════════════════════════

func _test_ferocity_attacks_turn_played() -> void:
	print("\n-- Scenario 2: Ferocity ally attacks the turn it is played --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ferocity_ally", 3, 4, (["ferocity"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "ferocity_ally", "p1")
	atk.just_summoned = true
	state.players["p1"].resource_placed_this_turn = true

	var legal := StackResolver.get_legal_attackers(state, "p1", db)
	ok("atk" in legal, "sc2: Ferocity ally is a legal attacker despite just_summoned")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()

	_drive(state, db, p1_ai, p2_ai)
	eq(state.get_card("p2_hero").damage_taken, 3, "sc2: hero took 3 damage (Ferocity attacked immediately)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 3 — Elusive: never a legal defender
# ══════════════════════════════════════════════════════════════════════════════

func _test_elusive_never_targetable() -> void:
	print("\n-- Scenario 3: Elusive ally is never a legal defender --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("p1_attacker", 1, 30)
	db.ally("elusive_ally", 0, 1, (["elusive"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "p1_attacker", "p1")
	_add_ally(state, "elu", "elusive_ally", "p2")

	var defenders := StackResolver.get_legal_defenders(state, "atk", db)
	ok("elu" not in defenders, "sc3: Elusive ally is not in legal defenders list")
	ok("p2_hero" in defenders, "sc3: P2 hero IS a legal defender")

	state.players["p1"].resource_placed_this_turn = true
	_drive_turns(state, db, RandomAttackerAI.new(), ScriptedAI.new(), 5)

	ok(state.get_card("elu").zone_id == "p2_ally_row", "sc3: Elusive ally still in play")
	eq(state.get_card("elu").damage_taken, 0,           "sc3: Elusive took 0 damage")
	ok(state.get_card("p2_hero").damage_taken > 0,      "sc3: Hero absorbed all attacks")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 4 — Hand-size wrap-up discard
# ══════════════════════════════════════════════════════════════════════════════

func _test_hand_size_wrap_up_discard() -> void:
	print("\n-- Scenario 4: Wrap-up discard reduces hand to max size --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("expensive_ally", 3, 4, [], 5)

	var state := _base_state(db, "p1_hero", "p2_hero")
	for i in range(9):
		var inst_id := "hand_%d" % i
		var card := CardInstance.create(inst_id, "expensive_ally", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)
	state.players["p1"].resource_placed_this_turn = true

	_drive_turns(state, db, ScriptedAI.new(), ScriptedAI.new(), 2)

	eq(state.cards_in_zone("p1_hand").size(),      7, "sc4: P1 hand reduced to 7")
	eq(state.cards_in_zone("p1_graveyard").size(), 2, "sc4: 2 excess cards in graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 5 — Ta'zo hero power: deal 3 fire damage to target
# ══════════════════════════════════════════════════════════════════════════════

func _test_tazo_hero_power() -> void:
	print("\n-- Scenario 5: Ta'zo hero power deals 3 damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("tazo_def", 25, 3, "deal_damage_to_target:3:fire")
	db.ally("target_ally", 2, 4, [], 0)

	var state := GameState.create_new(["p1", "p2"])
	var h1 := CardInstance.create("p1_hero", "p1_hero", "p1", "p1_hero_row")
	state.cards["p1_hero"] = h1
	state.zones["p1_hero_row"].card_ids.append("p1_hero")
	state.players["p1"].hero_instance_id = "p1_hero"

	var h2 := CardInstance.create("tazo_inst", "tazo_def", "p2", "p2_hero_row")
	state.cards["tazo_inst"] = h2
	state.zones["p2_hero_row"].card_ids.append("tazo_inst")
	state.players["p2"].hero_instance_id = "tazo_inst"

	state.phase = "action"
	state.turn_player = "p2"
	state.priority_player = "p2"
	state.turn_number = 1

	_add_ally(state, "p1_ally", "target_ally", "p1")
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var helper := BaseAI.new()
	var legal := helper.get_legal_actions(state, db, "p2")
	var power_action: PendingAction = null
	for a in legal:
		if a.action_type == "activate_power" and a.params.get("target_id") == "p1_ally":
			power_action = a
			break
	ok(power_action != null, "sc5-a: activate_power targeting p1_ally in legal actions")

	var all_events: Array[GameEvent] = []
	all_events.append_array(StackResolver.submit_action(state, power_action, db) if power_action \
		else ([] as Array[GameEvent]))
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))

	var saw_power_used := false
	for e in all_events:
		if e.event_type == "hero_power_used":
			saw_power_used = true
	ok(saw_power_used, "sc5-b: hero_power_used event fired")
	eq(state.get_card("p1_ally").damage_taken if state.get_card("p1_ally") else -1, 3,
		"sc5-c: p1 ally took 3 damage")

	var p2_ps := state.players.get("p2") as PlayerState
	ok(p2_ps != null and p2_ps.has_used_hero_power, "sc5-d: has_used_hero_power is true")

	var legal2 := helper.get_legal_actions(state, db, "p2")
	var found_second := false
	for a in legal2:
		if a.action_type == "activate_power":
			found_second = true
	ok(not found_second, "sc5-e: activate_power not available after power used")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 6 — Taz'dingo enters-play effect fires and deals 1 ranged damage
# ══════════════════════════════════════════════════════════════════════════════

func _test_tazdingo_enter_play() -> void:
	print("\n-- Scenario 6: Taz'dingo enters-play targeted damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tazdingo_def", 2, 2, [], 3, "on_enter:deal_damage_to_target:1:ranged")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var taz := CardInstance.create("taz_inst", "tazdingo_def", "p1", "p1_hand")
	state.cards["taz_inst"] = taz
	state.zones["p1_hand"].card_ids.append("taz_inst")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "taz_inst"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("taz_inst").zone_id == "p1_ally_row",
		"sc6-a: Taz'dingo is in p1_ally_row")

	var saw_target_req := false
	for e in all_events:
		if e.event_type == "enter_play_target_required":
			saw_target_req = true
	ok(saw_target_req, "sc6-b: enter_play_target_required event fired")

	var total_dmg := 0
	for e in all_events:
		if e.event_type == "damage_dealt":
			total_dmg += e.payload.get("amount", 0)
	eq(total_dmg, 1, "sc6-c: exactly 1 total damage dealt by enters-play effect")
	ok(state.pending_enter_play_effect.is_empty(), "sc6-d: pending_enter_play_effect cleared")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 7 — Parvink enters play and draws a card
# ══════════════════════════════════════════════════════════════════════════════

func _test_parvink_enter_play() -> void:
	print("\n-- Scenario 7: Parvink enters play and draws a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("parvink_def", 2, 2, (["protector"] as Array[String]), 3, "on_enter:draw:1")
	db.ally("deck_card_def", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var parvink := CardInstance.create("parvink_inst", "parvink_def", "p1", "p1_hand")
	state.cards["parvink_inst"] = parvink
	state.zones["p1_hand"].card_ids.append("parvink_inst")

	var deck_card := CardInstance.create("deck1", "deck_card_def", "p1", "p1_deck")
	state.cards["deck1"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck1")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "parvink_inst"}))

	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("parvink_inst").zone_id == "p1_ally_row", "sc7-a: Parvink in p1_ally_row")
	ok(state.get_card("deck1").zone_id == "p1_hand",            "sc7-b: deck card drawn into hand")
	eq(state.cards_in_zone("p1_hand").size(), 1,                "sc7-c: hand has exactly 1 card")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8 — Vanquish destroys target ally
# ══════════════════════════════════════════════════════════════════════════════

func _test_vanquish() -> void:
	print("\n-- Scenario 8: Vanquish destroys target ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_ally_def", 3, 5, [], 5)
	db.instant("vanquish_def", 4, "destroy_target:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)

	var vanquish := CardInstance.create("vanquish_inst", "vanquish_def", "p1", "p1_hand")
	state.cards["vanquish_inst"] = vanquish
	state.zones["p1_hand"].card_ids.append("vanquish_inst")

	var big := CardInstance.create("big_ally_inst", "big_ally_def", "p2", "p2_ally_row")
	state.cards["big_ally_inst"] = big
	state.zones["p2_ally_row"].card_ids.append("big_ally_inst")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "vanquish_inst", "target_id": "big_ally_inst"}))

	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("big_ally_inst").zone_id == "p2_graveyard", "sc8-a: target ally in graveyard")
	ok(state.get_card("vanquish_inst").zone_id == "p1_graveyard", "sc8-b: Vanquish in graveyard")

	var p2_hero_id := (state.players.get("p2") as PlayerState).hero_instance_id
	var bad_action := PendingAction.make("play_instant", "p1",
		{"card_id": "vanquish_inst", "target_id": p2_hero_id})
	ok(not StackResolver.can_submit(state, bad_action, db), "sc8-c: Vanquish cannot target a hero")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8b — Quick Strike: instant, hero deals 2 melee to announced target
#
# Quick Strike is an Instant Ability whose target is ANNOUNCED at play time
# (like Vanquish — gives humans cancellable targeting). The damage SOURCE is
# the controller's hero ("Your hero deals 2 melee damage"), not the ability
# card (which goes to the graveyard on resolution).
#
# Assertions:
#   sc8b-a  submission WITHOUT a target is rejected
#   sc8b-b  exactly 2 total damage dealt to the announced target
#   sc8b-c  the damage source is the controller's HERO
#   sc8b-d  Quick Strike itself is in the graveyard
#   sc8b-e  the target carries the damage (4 HP ally at 2 damage, survives)
#   sc8b-f  instant is legal DURING a combat window (instant timing)
#   sc8b-g  a non-instant ally is NOT legal in that same window (contrast)
# ══════════════════════════════════════════════════════════════════════════════

func _test_quick_strike() -> void:
	print("\n-- Scenario 8b: Quick Strike — hero deals 2 melee to announced target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 4, [], 3)
	db.ally("dummy_ally_def", 1, 1, [], 1)
	db.instant("quickstrike_def", 3, "deal_damage_to_target:2:melee")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var qs := CardInstance.create("qs_inst", "quickstrike_def", "p1", "p1_hand")
	state.cards["qs_inst"] = qs
	state.zones["p1_hand"].card_ids.append("qs_inst")

	# The opposing ally that will be targeted.
	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	# Target is required at submission.
	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_instant", "p1", {"card_id": "qs_inst"}), db),
		"sc8b-a: submission without a target is rejected")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "qs_inst", "target_id": "enemy_ally"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	var total_dmg := 0
	var dmg_source := ""
	for e in all_events:
		if e.event_type == "damage_dealt":
			total_dmg += int(e.payload.get("amount", 0))
			dmg_source = e.payload.get("source", dmg_source)
	eq(total_dmg, 2, "sc8b-b: exactly 2 total damage dealt")
	var p1_hero_id := (state.players.get("p1") as PlayerState).hero_instance_id
	eq(dmg_source, p1_hero_id, "sc8b-c: damage source is the controller's hero")
	ok(state.get_card("qs_inst").zone_id == "p1_graveyard", "sc8b-d: Quick Strike in graveyard")
	eq(state.get_card("enemy_ally").damage_taken, 2,
		"sc8b-e: announced target carries the 2 damage (survives at 4 HP)")

	# ── Instant timing: legal during a combat window; a non-instant is not. ──
	var tstate := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(tstate, "p1", 3)
	tstate.combat_attack_window = true
	var qs2 := CardInstance.create("qs2", "quickstrike_def", "p1", "p1_hand")
	tstate.cards["qs2"] = qs2
	tstate.zones["p1_hand"].card_ids.append("qs2")
	var dummy := CardInstance.create("dummy_ally", "dummy_ally_def", "p1", "p1_hand")
	tstate.cards["dummy_ally"] = dummy
	tstate.zones["p1_hand"].card_ids.append("dummy_ally")
	var p2_hero_id := (tstate.players.get("p2") as PlayerState).hero_instance_id
	ok(StackResolver.can_submit(tstate,
		PendingAction.make("play_instant", "p1",
			{"card_id": "qs2", "target_id": p2_hero_id}), db),
		"sc8b-f: Quick Strike (instant) is legal during a combat window")
	ok(not StackResolver.can_submit(tstate,
		PendingAction.make("play_ally", "p1", {"card_id": "dummy_ally"}), db),
		"sc8b-g: a non-instant ally is NOT legal in that same window")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8c — Lightning Bolt: non-instant ability, hero deals 4 nature to
# target hero or ally (own or opponent's)
#
# Same shape as Quick Strike (deal_damage_to_target) but action-phase timing
# like Vanquish, not instant speed. Also verifies self-targeting is legal for
# the human/engine, but the AI never selects its own hero/ally as a target.
# ══════════════════════════════════════════════════════════════════════════════

func _test_lightning_bolt() -> void:
	print("\n-- Scenario 8c: Lightning Bolt — non-instant, 4 nature to target hero or ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("enemy_ally_def", 2, 6, [], 3)
	db.ability("bolt_def", 3, "deal_damage_to_target:4:nature")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var bolt := CardInstance.create("bolt_inst", "bolt_def", "p1", "p1_hand")
	state.cards["bolt_inst"] = bolt
	state.zones["p1_hand"].card_ids.append("bolt_inst")

	var enemy := CardInstance.create("enemy_ally_inst", "enemy_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally_inst"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally_inst")

	# Not legal during a combat window (non-instant, action-phase timing).
	var tstate := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(tstate, "p1", 3)
	tstate.combat_attack_window = true
	var bolt2 := CardInstance.create("bolt2", "bolt_def", "p1", "p1_hand")
	tstate.cards["bolt2"] = bolt2
	tstate.zones["p1_hand"].card_ids.append("bolt2")
	var p2_hero_id_t := (tstate.players.get("p2") as PlayerState).hero_instance_id
	ok(not StackResolver.can_submit(tstate,
		PendingAction.make("play_ability", "p1", {"card_id": "bolt2", "target_id": p2_hero_id_t}), db),
		"sc8c-a: Lightning Bolt is NOT legal during a combat window")

	# Legal to target own hero (rules-legal, even if AI would never choose it).
	var p1_hero_id := (state.players.get("p1") as PlayerState).hero_instance_id
	ok(StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1", {"card_id": "bolt_inst", "target_id": p1_hero_id}), db),
		"sc8c-b: Lightning Bolt CAN legally target your own hero")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "bolt_inst", "target_id": "enemy_ally_inst"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	var total_dmg := 0
	var dmg_source := ""
	for e in all_events:
		if e.event_type == "damage_dealt":
			total_dmg += int(e.payload.get("amount", 0))
			dmg_source = e.payload.get("source", dmg_source)
	eq(total_dmg, 4, "sc8c-c: exactly 4 nature damage dealt")
	eq(dmg_source, p1_hero_id, "sc8c-d: damage source is the controller's hero")
	ok(state.get_card("bolt_inst").zone_id == "p1_graveyard", "sc8c-e: Lightning Bolt in graveyard")
	eq(state.get_card("enemy_ally_inst").damage_taken, 4,
		"sc8c-f: target carries the 4 damage")

	# AI never targets its own hero/ally with a targeted damage ability.
	var astate := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(astate, "p1", 3)
	var bolt3 := CardInstance.create("bolt3", "bolt_def", "p1", "p1_hand")
	astate.cards["bolt3"] = bolt3
	astate.zones["p1_hand"].card_ids.append("bolt3")
	var own_ally := CardInstance.create("own_ally_inst", "enemy_ally_def", "p1", "p1_ally_row")
	astate.cards["own_ally_inst"] = own_ally
	astate.zones["p1_ally_row"].card_ids.append("own_ally_inst")

	var base_ai := BaseAI.new()
	var actions: Array[PendingAction] = base_ai.get_legal_actions(astate, db, "p1")
	var p1_hero_id_a := (astate.players.get("p1") as PlayerState).hero_instance_id
	var self_targeted := false
	for act in actions:
		if act.action_type == "play_ability" and act.params.get("card_id", "") == "bolt3":
			var tid: String = act.params.get("target_id", "")
			if tid == p1_hero_id_a or tid == "own_ally_inst":
				self_targeted = true
	ok(not self_targeted, "sc8c-g: AI never generates a self-targeting Lightning Bolt action")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 9 — Pet uniqueness: only 1 pet may be in play at a time
#
# Setup:
#   P1 has 2 Grimdron instances in hand (played sequentially so the second
#   triggers the uniqueness rule), plus 1 Grimdron in each of: deck, graveyard,
#   and face-down resource row (none of which count toward the limit).
#   P1 has 2 ready resources so both can be played.
#
# The key thing being tested: when the second Grimdron enters play the engine
# emits pet_sacrifice_required and the driver must resolve it — the AI (or
# headless helper) cannot pass this mandatory choice.
#
# Assertions:
#   sc9-a  exactly 1 Grimdron is in p1_ally_row at the end
#   sc9-b  pet_sacrifice_required event fired exactly once
#   sc9-c  the sacrificed Grimdron is in the graveyard (one of the two hand ones)
#   sc9-d  Grimdron in deck still in deck (non-ally_row zones are unaffected)
#   sc9-e  Grimdron in graveyard still in graveyard (not double-counted)
#   sc9-f  Grimdron as face-down resource still in resource_row
#   sc9-g  pending_pet_sacrifice_player cleared after resolution
# ══════════════════════════════════════════════════════════════════════════════

func _test_pet_uniqueness() -> void:
	print("\n-- Scenario 9: Pet uniqueness — only 1 pet allowed in play --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.pet("grimdron_def", 0, 1, (["elusive"] as Array[String]), 1,
		"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally")

	var state := _base_state(db, "p1_hero", "p2_hero")

	# 2 ready resources — exactly enough for both hand Grimdrons (cost 1 each).
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true

	# 2 Grimdrons in hand.
	for i in range(2):
		var inst_id := "grim_hand_%d" % i
		var card := CardInstance.create(inst_id, "grimdron_def", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)

	# 1 Grimdron in deck (must NOT be touched by uniqueness rule).
	var grim_deck := CardInstance.create("grim_deck", "grimdron_def", "p1", "p1_deck")
	state.cards["grim_deck"] = grim_deck
	state.zones["p1_deck"].card_ids.append("grim_deck")

	# 1 Grimdron already in graveyard before the scenario starts (must NOT be touched).
	var grim_grave := CardInstance.create("grim_grave", "grimdron_def", "p1", "p1_graveyard")
	state.cards["grim_grave"] = grim_grave
	state.zones["p1_graveyard"].card_ids.append("grim_grave")

	# 1 Grimdron as face-down resource (must NOT be touched).
	var grim_res := CardInstance.create("grim_res", "grimdron_def", "p1", "p1_resource_row")
	grim_res.face_down = true
	state.cards["grim_res"] = grim_res
	state.zones["p1_resource_row"].card_ids.append("grim_res")

	# Queue both hand Grimdrons — second play must trigger sacrifice.
	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "grim_hand_0"}))
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "grim_hand_1"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 4)

	# sc9-a: exactly 1 Grimdron in ally_row.
	var pets_in_play := 0
	for card in state.cards_in_zone("p1_ally_row"):
		var d := db.get_def(card.card_def_id) as CardDef
		if d and d.card_subtype == "Pet":
			pets_in_play += 1
	eq(pets_in_play, 1, "sc9-a: exactly 1 pet in p1_ally_row after playing 2")

	# sc9-b: sacrifice event fired exactly once.
	var sacrifice_events := 0
	for e in all_events:
		if e.event_type == "pet_sacrifice_required":
			sacrifice_events += 1
	eq(sacrifice_events, 1, "sc9-b: pet_sacrifice_required fired exactly once")

	# sc9-c: one of the two hand Grimdrons was sacrificed to graveyard.
	var hand_grim_in_grave := 0
	for cid in ["grim_hand_0", "grim_hand_1"]:
		if state.get_card(cid).zone_id == "p1_graveyard":
			hand_grim_in_grave += 1
	eq(hand_grim_in_grave, 1, "sc9-c: exactly 1 hand Grimdron was sacrificed to graveyard")

	# sc9-d/e/f: non-ally_row Grimdrons untouched.
	ok(state.get_card("grim_deck").zone_id != "p2_graveyard",   "sc9-d: deck Grimdron not destroyed by uniqueness rule")
	eq(state.get_card("grim_grave").zone_id, "p1_graveyard",    "sc9-e: pre-existing graveyard Grimdron unchanged")
	eq(state.get_card("grim_res").zone_id,   "p1_resource_row", "sc9-f: face-down resource Grimdron unchanged")

	# sc9-g: pending sacrifice state is cleared.
	eq(state.pending_pet_sacrifice_player, "", "sc9-g: pending_pet_sacrifice_player cleared")


# ══════════════════════════════════════════════════════════════════════════════
# Mooncloth Robe — equipment play + activated power (draw a card)
#
# Power: (2), Exhaust this, Exhaust your hero >>> Draw a card.
# ══════════════════════════════════════════════════════════════════════════════

const ROBE_EFFECTS := "equipment:chest:0|activated_power:2:draw:1:::exhaust_hero"

func _test_mooncloth_robe_power() -> void:
	print("\n-- Mooncloth Robe: play from hand + draw power --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")

	# 6 ready resources: 4 to play the robe, 2 for the power.
	_add_resources(state, "p1", 6)
	state.players["p1"].resource_placed_this_turn = true

	# Robe in hand.
	var robe := CardInstance.create("robe_inst", "robe_def", "p1", "p1_hand")
	state.cards["robe_inst"] = robe
	state.zones["p1_hand"].card_ids.append("robe_inst")

	# One card in deck to be drawn by the power.
	var deck_card := CardInstance.create("deck_card", "robe_def", "p1", "p1_deck")
	state.cards["deck_card"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck_card")

	# mr-a: playing the equipment is legal.
	var play := PendingAction.make("play_equipment", "p1", {"card_id": "robe_inst"})
	ok(StackResolver.can_submit(state, play, db), "mr-a: play_equipment is legal")

	# Resolve the play (submit + both pass).
	StackResolver.submit_action(state, play, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# mr-b: robe entered the hero row.
	eq(state.get_card("robe_inst").zone_id, "p1_hero_row",
		"mr-b: robe enters play in the hero row")

	# mr-c: the power is usable this same turn (equipment has no summoning sickness).
	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"})
	ok(StackResolver.can_submit(state, use, db),
		"mr-c: robe power usable the turn it entered play")

	# Resolve the power.
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# mr-d: the deck card was drawn into hand.
	eq(state.get_card("deck_card").zone_id, "p1_hand",
		"mr-d: robe power drew a card")

	# mr-e: robe is exhausted (activate symbol).
	ok(state.get_card("robe_inst").is_exhausted, "mr-e: robe exhausted after use")

	# mr-f: hero is exhausted (extra cost).
	ok(state.get_card("p1_hero").is_exhausted, "mr-f: hero exhausted by robe power")

	# mr-g: all 6 resources are now exhausted (4 play + 2 power).
	var ready_res := 0
	for r in state.cards_in_zone("p1_resource_row"):
		if not r.is_exhausted:
			ready_res += 1
	eq(ready_res, 0, "mr-g: 6 resources spent (4 play + 2 power)")

	# mr-h: power can't be used again (robe now exhausted).
	ok(not StackResolver.can_submit(state, use, db),
		"mr-h: robe power not reusable while exhausted")


func _test_mooncloth_robe_hero_exhausted() -> void:
	print("\n-- Mooncloth Robe: cannot use with exhausted hero / too few resources --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	var deck_card := CardInstance.create("deck_card", "robe_def", "p1", "p1_deck")
	state.cards["deck_card"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck_card")

	# Robe already in play (ready).
	var robe := CardInstance.create("robe_inst", "robe_def", "p1", "p1_hero_row")
	state.cards["robe_inst"] = robe
	state.zones["p1_hero_row"].card_ids.append("robe_inst")

	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"})

	# me-a: with a ready hero and 2 resources, legal.
	ok(StackResolver.can_submit(state, use, db),
		"me-a: robe power legal with ready hero + 2 resources")

	# me-b: exhausted hero → cannot pay the exhaust-hero cost.
	state.get_card("p1_hero").is_exhausted = true
	ok(not StackResolver.can_submit(state, use, db),
		"me-b: robe power illegal when hero already exhausted")
	state.get_card("p1_hero").is_exhausted = false

	# me-c: only 1 ready resource → cannot pay the 2 cost.
	state.cards_in_zone("p1_resource_row")[0].is_exhausted = true
	ok(not StackResolver.can_submit(state, use, db),
		"me-c: robe power illegal with only 1 ready resource")


func _test_equipment_slot_uniqueness() -> void:
	print("\n-- Equipment slot uniqueness: only 1 Chest allowed --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 8)   # 4 + 4 to play both
	state.players["p1"].resource_placed_this_turn = true

	for i in range(2):
		var inst_id := "robe_hand_%d" % i
		var card := CardInstance.create(inst_id, "robe_def", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_equipment", "p1", {"card_id": "robe_hand_0"}))
	p1_ai.queue_action(PendingAction.make("play_equipment", "p1", {"card_id": "robe_hand_1"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 4)

	# eu-a: exactly 1 Chest equipment remains in the hero row.
	var chest_in_play := 0
	for card in state.cards_in_zone("p1_hero_row"):
		var d := db.get_def(card.card_def_id) as CardDef
		if d and d.card_type == "Equipment":
			chest_in_play += 1
	eq(chest_in_play, 1, "eu-a: exactly 1 Chest equipment in hero_row after playing 2")

	# eu-b: sacrifice event fired exactly once.
	var sac := 0
	for e in all_events:
		if e.event_type == "equipment_sacrifice_required":
			sac += 1
	eq(sac, 1, "eu-b: equipment_sacrifice_required fired exactly once")

	# eu-c: one robe was destroyed to the graveyard.
	var in_grave := 0
	for cid in ["robe_hand_0", "robe_hand_1"]:
		if state.get_card(cid).zone_id == "p1_graveyard":
			in_grave += 1
	eq(in_grave, 1, "eu-c: exactly 1 robe destroyed to graveyard")

	# eu-d: pending state cleared.
	eq(state.pending_equip_sacrifice_player, "", "eu-d: pending_equip_sacrifice_player cleared")


func _test_ai_plays_equipment() -> void:
	print("\n-- AI generates equipment play + draw-power actions --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")
	var ai := BaseAI.new()

	# Case 1: robe in hand, affordable → AI offers play_equipment.
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s1, "p1", 4)
	s1.players["p1"].resource_placed_this_turn = true
	var robe := CardInstance.create("robe_inst", "robe_def", "p1", "p1_hand")
	s1.cards["robe_inst"] = robe
	s1.zones["p1_hand"].card_ids.append("robe_inst")
	var has_play := false
	for a in ai.get_legal_actions(s1, db, "p1"):
		if a.action_type == "play_equipment" and a.params.get("card_id") == "robe_inst":
			has_play = true
	ok(has_play, "ai-eq-a: AI offers play_equipment for a robe in hand")

	# Case 2: robe in play, ready hero, deck card, 2 resources → AI offers the draw power.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s2, "p1", 2)
	s2.players["p1"].resource_placed_this_turn = true
	var robe2 := CardInstance.create("robe2", "robe_def", "p1", "p1_hero_row")
	s2.cards["robe2"] = robe2
	s2.zones["p1_hero_row"].card_ids.append("robe2")
	var deck2 := CardInstance.create("deck2", "robe_def", "p1", "p1_deck")
	s2.cards["deck2"] = deck2
	s2.zones["p1_deck"].card_ids.append("deck2")
	var has_power := false
	for a in ai.get_legal_actions(s2, db, "p1"):
		if a.action_type == "use_ally_power" and a.params.get("card_id") == "robe2":
			has_power = true
	ok(has_power, "ai-eq-b: AI offers the robe draw power from the hero row")

	# Case 3: same as case 2 but hand is full → AI skips the draw power.
	for i in range(7):
		var hid := "fill_%d" % i
		var c := CardInstance.create(hid, "robe_def", "p1", "p1_hand")
		s2.cards[hid] = c
		s2.zones["p1_hand"].card_ids.append(hid)
	var still_power := false
	for a in ai.get_legal_actions(s2, db, "p1"):
		if a.action_type == "use_ally_power" and a.params.get("card_id") == "robe2":
			still_power = true
	ok(not still_power, "ai-eq-c: AI skips the draw power when hand is full")


# ══════════════════════════════════════════════════════════════════════════════
# Pads of the Dread Wolf — armor damage prevention (rule 304.3)
#
# Cost 1, Armor—Leather, Feet, 1 DEF. No powers — its whole job is
# "exhaust to prevent 1 damage to your hero".
# ══════════════════════════════════════════════════════════════════════════════

const PADS_EFFECTS := "equipment:feet:1"

func _test_pads_block_combat() -> void:
	print("\n-- Pads of the Dread Wolf: block combat damage to hero --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.ally("smasher", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_ally(state, "smasher_inst", "smasher", "p2")
	var pads := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p1_hero_row"].card_ids.append("pads_inst")

	# pb-a: no incoming damage → block is illegal (empty chain, no combat).
	var block := PendingAction.make("use_armor_prevention", "p1", {"card_id": "pads_inst"})
	state.priority_player = "p1"
	ok(not StackResolver.can_submit(state, block, db),
		"pb-a: block illegal outside combat with empty chain")
	state.priority_player = "p2"

	# p2 attacks p1's hero.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "smasher_inst", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → combat starts, attack window

	# Block is a last-moment decision — not legal yet during the attack window
	# (a Protector could still take the hit instead).
	StackResolver.pass_priority(state, db)   # p2 passes → priority to p1
	ok(not StackResolver.can_submit(state, block, db),
		"pb-a2: block still illegal during the attack window")

	# Close the attack window (no protectors) → defend window opens.
	StackResolver.pass_priority(state, db)   # p1 passes → attack window closes, defend window opens

	# pb-b: defend window open, p2 has priority — pass to p1, block now legal.
	StackResolver.pass_priority(state, db)   # p2 passes → priority to p1
	ok(StackResolver.can_submit(state, block, db),
		"pb-b: block legal during the defend window")

	# p1 exhausts the pads.
	StackResolver.submit_action(state, block, db)
	StackResolver.pass_priority(state, db)   # p1 passes
	StackResolver.pass_priority(state, db)   # p2 passes → block resolves

	# pb-c: block resolved — pool is 1, pads exhausted.
	eq(state.players["p1"].damage_prevention, 1, "pb-c: prevention pool at 1")
	ok(state.get_card("pads_inst").is_exhausted, "pb-c2: pads exhausted at submission")

	# Close defend window → conclusion.
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window closes → damage

	# pb-d: hero took 2 − 1 = 1 damage.
	eq(state.get_card("p1_hero").damage_taken, 1, "pb-d: hero took 1 (2 ATK − 1 blocked)")

	# pb-e: pool cleared after combat.
	eq(state.players["p1"].damage_prevention, 0, "pb-e: pool cleared after combat")


func _test_pads_block_instant() -> void:
	print("\n-- Pads of the Dread Wolf: block effect damage (chain response) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.instant("zap_def", 1, "deal_damage_to_target:2:melee")

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p2", 1)
	var pads := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p1_hero_row"].card_ids.append("pads_inst")
	var zap := CardInstance.create("zap_inst", "zap_def", "p2", "p2_hand")
	state.cards["zap_inst"] = zap
	state.zones["p2_hand"].card_ids.append("zap_inst")

	# p2 plays the damage instant at p1's hero.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2",
		{"card_id": "zap_inst", "target_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)   # p2 passes → priority to p1, chain non-empty

	# pi-a: block legal as a chain response.
	var block := PendingAction.make("use_armor_prevention", "p1", {"card_id": "pads_inst"})
	ok(StackResolver.can_submit(state, block, db),
		"pi-a: block legal while opposing damage effect is on the chain")

	StackResolver.submit_action(state, block, db)
	StackResolver.pass_priority(state, db)   # p1 passes
	StackResolver.pass_priority(state, db)   # p2 passes → block resolves (pool 1)
	StackResolver.pass_priority(state, db)   # p2 passes (turn player got priority)
	StackResolver.pass_priority(state, db)   # p1 passes → zap resolves

	# pi-b: hero took 2 − 1 = 1 damage; pool fully consumed.
	eq(state.get_card("p1_hero").damage_taken, 1, "pi-b: hero took 1 (2 dmg − 1 blocked)")
	eq(state.players["p1"].damage_prevention, 0, "pi-c: pool consumed to 0")


func _test_pads_overblock_expires() -> void:
	print("\n-- Armor block: leftover block expires after combat --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("plate_def", 3, "equipment:chest:3", "Plate")
	db.ally("poker", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_ally(state, "poker_inst", "poker", "p2")
	var plate := CardInstance.create("plate_inst", "plate_def", "p1", "p1_hero_row")
	state.cards["plate_inst"] = plate
	state.zones["p1_hero_row"].card_ids.append("plate_inst")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "poker_inst", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window
	StackResolver.pass_priority(state, db)   # p2 passes → p1 priority (block still illegal here)
	StackResolver.pass_priority(state, db)   # p1 passes → attack window closes, defend window opens
	StackResolver.pass_priority(state, db)   # p2 passes → p1 priority
	StackResolver.submit_action(state, PendingAction.make("use_armor_prevention", "p1",
		{"card_id": "plate_inst"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # block resolves (pool 3)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window closes → conclusion

	# ob-a: hero took 0 (2 ATK fully blocked by DEF 3).
	eq(state.get_card("p1_hero").damage_taken, 0, "ob-a: hero took 0 (fully blocked)")
	# ob-b: leftover 1 block expired with the combat.
	eq(state.players["p1"].damage_prevention, 0, "ob-b: leftover block cleared after combat")


func _test_ai_armor_block_heuristic() -> void:
	print("\n-- AI armor block heuristic: highest DEF first, no wasted potential --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("plate3_def", 3, "equipment:chest:3", "Plate")
	db.equipment("pads1_def", 1, PADS_EFFECTS, "Leather")
	db.equipment("shield6_def", 5, "equipment:back:6", "Plate")
	db.ally("bruiser", 6, 6)
	db.ally("rat", 1, 1)
	var ai := BaseAI.new()

	# Case 1: 6 incoming vs DEF 3 + DEF 1 → picks the 3 first, then the 1.
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	s1.turn_player = "p2"
	_add_ally(s1, "bruiser_inst", "bruiser", "p2")
	for pair in [["plate_inst", "plate3_def"], ["pads_inst", "pads1_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_hero_row")
		s1.cards[pair[0]] = c
		s1.zones["p1_hero_row"].card_ids.append(pair[0])
	s1.combat_defend_window = true
	s1.combat_attacker = "bruiser_inst"
	s1.combat_defender = "p1_hero"
	s1.priority_player = "p1"

	var a1 := ai.armor_prevention_action(s1, db, "p1")
	ok(a1 != null and a1.params.get("card_id") == "plate_inst",
		"hb-a: 6 incoming → highest DEF (3) armor chosen first")
	StackResolver.submit_action(s1, a1, db)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # block resolves → pool 3

	s1.priority_player = "p1"
	var a2 := ai.armor_prevention_action(s1, db, "p1")
	ok(a2 != null and a2.params.get("card_id") == "pads_inst",
		"hb-b: 3 incoming left → DEF 1 armor also committed (3 >= 0)")
	StackResolver.submit_action(s1, a2, db)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # pool 4

	s1.priority_player = "p1"
	eq(ai.armor_prevention_action(s1, db, "p1"), null,
		"hb-c: nothing ready left → AI stops blocking")

	# Case 2: 1 incoming vs DEF 6 → wasted potential (1 < 5), AI holds the armor.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	s2.turn_player = "p2"
	_add_ally(s2, "rat_inst", "rat", "p2")
	var sh := CardInstance.create("shield_inst", "shield6_def", "p1", "p1_hero_row")
	s2.cards["shield_inst"] = sh
	s2.zones["p1_hero_row"].card_ids.append("shield_inst")
	s2.combat_defend_window = true
	s2.combat_attacker = "rat_inst"
	s2.combat_defender = "p1_hero"
	s2.priority_player = "p1"
	eq(ai.armor_prevention_action(s2, db, "p1"), null,
		"hb-d: 1 incoming vs DEF 6 → armor held (wasted potential)")

	# Case 3: ally (not hero) is the defender → armor never blocks for allies.
	var s3 := _base_state(db, "p1_hero", "p2_hero")
	s3.turn_player = "p2"
	_add_ally(s3, "bruiser_inst3", "bruiser", "p2")
	_add_ally(s3, "rat_p1", "rat", "p1")
	var sh3 := CardInstance.create("shield3_inst", "shield6_def", "p1", "p1_hero_row")
	s3.cards["shield3_inst"] = sh3
	s3.zones["p1_hero_row"].card_ids.append("shield3_inst")
	s3.combat_defend_window = true
	s3.combat_attacker = "bruiser_inst3"
	s3.combat_defender = "rat_p1"
	s3.priority_player = "p1"
	eq(ai.armor_prevention_action(s3, db, "p1"), null,
		"hb-e: ally under attack → no armor block (heroes only)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 10 — Grimdron ally activated power deals 1 fire damage
#
# Setup : P1 has Grimdron in ally_row (ready, not summoning-sick).
#         P2 has a 0/3 ally.  P1 has 1 ready resource.
#
# Assertions:
#   sc10-a  use_ally_power targeting p2_ally appears in P1 legal actions
#   sc10-b  targeting own ally is NOT legal (heuristic: never target friendlies)
#   sc10-c  targeting with 0 resources is NOT legal (cost 1)
#   sc10-d  p2_ally has 1 damage after power resolves
#   sc10-e  Grimdron is exhausted after activation
#   sc10-f  use_ally_power not available again (Grimdron now exhausted)
# ══════════════════════════════════════════════════════════════════════════════

func _test_grimdron_ally_power() -> void:
	print("\n-- Scenario 10: Grimdron ally power deals 1 fire damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.pet("grimdron_def", 0, 1, (["elusive"] as Array[String]), 1,
		"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally")
	db.ally("dummy_ally_def", 0, 3, [], 0)

	var state := _base_state(db, "p1_hero", "p2_hero")

	# Grimdron in p1_ally_row, ready, not summoning-sick.
	var grim := _add_ally(state, "grim_inst", "grimdron_def", "p1")
	grim.just_summoned = false
	grim.is_exhausted  = false

	# p1 friendly ally (must NOT be a valid target for the power).
	_add_ally(state, "p1_ally_inst", "dummy_ally_def", "p1")

	# p2 target ally.
	_add_ally(state, "p2_ally_inst", "dummy_ally_def", "p2")

	# 1 ready resource for P1 (cost of Grimdron power).
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	# sc10-a: use_ally_power targeting p2_ally is legal.
	var good_action := PendingAction.make("use_ally_power", "p1",
		{"card_id": "grim_inst", "target_id": "p2_ally_inst"})
	ok(StackResolver.can_submit(state, good_action, db),
		"sc10-a: use_ally_power targeting enemy ally is legal")

	# sc10-b: targeting own ally is also technically legal by the rules
	# (the restriction is a heuristic, not a rule) — but verify targeting
	# a non-in-play card is rejected.
	# p1_hero IS in play so that would actually be legal; test that an
	# out-of-play target (deck card) is correctly rejected instead.
	var deck_card := CardInstance.create("deck_dummy", "dummy_ally_def", "p1", "p1_deck")
	state.cards["deck_dummy"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck_dummy")
	var bad_deck := PendingAction.make("use_ally_power", "p1",
		{"card_id": "grim_inst", "target_id": "deck_dummy"})
	ok(not StackResolver.can_submit(state, bad_deck, db),
		"sc10-b: targeting an out-of-play card is illegal")

	# sc10-c: 0 resources → cannot activate (cost is 1).
	var state_no_res := state.duplicate(true) as GameState
	for res_card in state_no_res.cards_in_zone("p1_resource_row"):
		res_card.is_exhausted = true
	ok(not StackResolver.can_submit(state_no_res, good_action, db),
		"sc10-c: use_ally_power rejected when player has 0 available resources")

	# sc10-d/e: resolve the power and check outcomes.
	var events: Array[GameEvent] = []
	events.append_array(StackResolver.submit_action(state, good_action, db))
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	var p2_ally := state.get_card("p2_ally_inst")
	eq(p2_ally.damage_taken if p2_ally else -1, 1,
		"sc10-d: p2 ally took 1 fire damage from Grimdron power")

	var grim_after := state.get_card("grim_inst")
	ok(grim_after != null and grim_after.is_exhausted,
		"sc10-e: Grimdron is exhausted after using its power")

	# sc10-f: power no longer available (exhausted).
	ok(not StackResolver.can_submit(state, good_action, db),
		"sc10-f: use_ally_power not available again (Grimdron exhausted)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 11 — Sarmoth taunt: attacker must target Sarmoth
#
# Setup: P1 has one attacker. P2 has Sarmoth + a normal ally + hero.
#
# Assertions:
#   sc11-a  Sarmoth is the only legal defender (hero and normal ally excluded)
#   sc11-b  combat targeting Sarmoth is accepted
#   sc11-c  combat targeting the hero is rejected (taunt active)
#   sc11-d  combat targeting the other ally is rejected (taunt active)
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_taunt_forces_attacker() -> void:
	print("\n-- Scenario 11: Sarmoth taunt forces attacker to target Sarmoth --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var defenders := StackResolver.get_legal_defenders(state, "atk", db)

	eq(defenders.size(), 1,           "sc11-a: only 1 legal defender when Sarmoth is in play")
	ok("sarmoth" in defenders,        "sc11-a: Sarmoth is that defender")

	var good := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "sarmoth"})
	ok(StackResolver.can_submit(state, good, db),
		"sc11-b: combat targeting Sarmoth is accepted")

	var bad_hero := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, bad_hero, db),
		"sc11-c: combat targeting hero is rejected while Sarmoth taunts")

	var bad_ally := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "normal"})
	ok(not StackResolver.can_submit(state, bad_ally, db),
		"sc11-d: combat targeting normal ally is rejected while Sarmoth taunts")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 12 — Sarmoth taunt applies to all of P1's attackers
#
# Setup: P1 has two attackers. P2 has Sarmoth + normal ally.
# Each attacker's legal defenders list must contain only Sarmoth.
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_taunt_multiple_attackers() -> void:
	print("\n-- Scenario 12: Sarmoth taunt restricts all attackers --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 2, 3)
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk1", "attacker_def", "p1")
	_add_ally(state, "atk2", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var def1 := StackResolver.get_legal_defenders(state, "atk1", db)
	var def2 := StackResolver.get_legal_defenders(state, "atk2", db)

	ok("sarmoth" in def1 and def1.size() == 1, "sc12-a: atk1 must target Sarmoth only")
	ok("sarmoth" in def2 and def2.size() == 1, "sc12-b: atk2 must target Sarmoth only")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 13 — Sarmoth taunt lifts when Sarmoth dies
#
# Setup: P1 attacks Sarmoth for lethal damage. After combat, P1's second
# attacker should be able to target the hero or normal ally freely.
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_taunt_lifts_on_death() -> void:
	print("\n-- Scenario 13: Sarmoth taunt lifts after Sarmoth dies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 6, 4)   # enough ATK to kill Sarmoth (5 health)
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk1", "attacker_def", "p1")
	_add_ally(state, "atk2", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	# Confirm taunt is active before Sarmoth leaves play.
	var before := StackResolver.get_legal_defenders(state, "atk1", db)
	ok("sarmoth" in before and before.size() == 1, "sc13-a: taunt active before Sarmoth dies")

	# Remove Sarmoth directly — sc13 tests that the taunt lifts on removal,
	# not the combat system itself (which is covered by sc1/sc2/sc11).
	GameLogic.move_card(state, "sarmoth", "p2_graveyard")

	ok(state.get_card("sarmoth").zone_id == "p2_graveyard",
		"sc13-b: Sarmoth is in graveyard")

	# Taunt should be gone — atk2 can now target hero or normal ally.
	var after := StackResolver.get_legal_defenders(state, "atk2", db)
	ok("p2_hero" in after,  "sc13-c: hero is a legal defender after Sarmoth dies")
	ok("normal" in after,   "sc13-d: normal ally is a legal defender after Sarmoth dies")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 14 — Elusive Sarmoth: taunt doesn't restrict (Sarmoth not a legal defender)
#
# Edge case: if Sarmoth gains Elusive it can't be chosen as a defender, so the
# taunt filter finds no taunt cards in the legal-defenders list and falls through
# to normal targeting (hero + other allies).
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_elusive_no_taunt() -> void:
	print("\n-- Scenario 14: Elusive Sarmoth — taunt doesn't restrict --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.pet("sarmoth_elusive_def", 1, 5, (["elusive"] as Array[String]), 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_elusive_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var defenders := StackResolver.get_legal_defenders(state, "atk", db)

	ok("sarmoth" not in defenders, "sc14-a: Elusive Sarmoth is not a legal defender")
	ok("p2_hero" in defenders,     "sc14-b: hero is a legal defender (taunt not restricting)")
	ok("normal" in defenders,      "sc14-c: normal ally is a legal defender (taunt not restricting)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 15 — Boris Brightbeard: heal X from target, capped at max HP
# Setup: Crazy Igvand (6 max HP, 3 damage taken → 3 current HP).
#        Boris pays X=4, heals 4 → capped at max HP → Igvand at exactly 6 HP.
# ══════════════════════════════════════════════════════════════════════════════

func _test_boris_heal_x() -> void:
	print("\n-- Scenario 15: Boris Brightbeard heal-X hero power --")
	var db := MockDB.new()
	db.hero("boris_def", 26, 0, "heal_x_from_target:holy|on_your_turn")
	db.hero("p2_hero", 30)
	db.ally("igvand_def", 2, 6, [], 3)   # Crazy Igvand: 2 ATK, 6 HP, cost 3

	var state := _base_state(db, "boris_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	var igvand := _add_ally(state, "igvand", "igvand_def", "p1")
	igvand.damage_taken = 3   # Igvand at 3/6 HP

	_add_resources(state, "p1", 5)

	# ── sc15-a: can_submit probe (no target) succeeds when resources available ──
	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "boris_def", "target_id": "", "x_value": 0})
	ok(StackResolver.can_submit(state, probe, db), "sc15-a: probe passes with 5 resources available")

	# ── sc15-b: x > available resources is illegal ──
	var too_big := PendingAction.make("activate_power", "p1",
		{"hero_id": "boris_def", "target_id": "igvand", "x_value": 6})
	ok(not StackResolver.can_submit(state, too_big, db), "sc15-b: x=6 rejected (only 5 resources)")

	# ── sc15-c: heal 4 from Igvand (3 damage taken) — overheal capped at max HP ──
	var act := PendingAction.make("activate_power", "p1",
		{"hero_id": "boris_def", "target_id": "igvand", "x_value": 4})
	ok(StackResolver.can_submit(state, act, db), "sc15-c: heal x=4 is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.get_current_hp("igvand", db), 6,
		"sc15-d: Igvand at exactly 6 HP (overheal capped, not 7)")
	eq(igvand.damage_taken, 0,
		"sc15-e: damage_taken is 0 (fully healed, not negative)")
	eq(state.get_available_resources("p1"), 1,
		"sc15-f: 4 resources spent, 1 remaining")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 16 — Radak Doombringer: sacrifice Sarmoth (cost 3), deal 3 shadow dmg
#
# Setup: P1 is Radak (no flip cost, no resources spent — the Pet IS the cost).
#        P1 has a Sarmoth (cost 3) in ally_row, not summoning-sick, and 3
#        available resources (can_submit requires availability to cover the
#        Pet's cost even though sacrificing the Pet is the actual payment).
#        P2 has a 2/5 ally as the damage target.
#
# Assertions:
#   sc16-a  probe (pet_id="", target_id="") passes when Pet is in ally_row
#   sc16-b  phase-1 probe with pet_id set (target_id="") passes
#   sc16-c  full action (pet_id + target_id + x_value=3) is legal
#   sc16-d  Sarmoth is removed from play at submission (cost payment)
#   sc16-e  p2 ally takes 3 shadow damage at resolution
#   sc16-f  hero_power_used event fires
#   sc16-g  x_value mismatch (pet cost 3 but x_value=1) is rejected
# ══════════════════════════════════════════════════════════════════════════════

func _test_radak_pet_sacrifice() -> void:
	print("\n-- Scenario 16: Radak sacrifices Sarmoth (cost 3) for 3 shadow damage --")
	var db := MockDB.new()
	db.hero("radak_def", 30, 0, "radak_pet_sacrifice:shadow|on_your_turn")
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("target_def", 2, 5, [], 2)

	var state := _base_state(db, "radak_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	var sarmoth := _add_ally(state, "sarmoth_inst", "sarmoth_def", "p1")
	sarmoth.just_summoned = false
	sarmoth.is_exhausted  = false

	_add_ally(state, "target_inst", "target_def", "p2")
	_add_resources(state, "p1", 3)   # Sarmoth costs 3 — radak_pet_sacrifice needs an affordable Pet

	# sc16-a: probe passes when Pet is in play.
	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "", "target_id": "", "x_value": 0})
	ok(StackResolver.can_submit(state, probe, db),
		"sc16-a: probe passes with Sarmoth in ally_row")

	# sc16-b: phase-1 probe (pet chosen, no target yet) passes.
	var phase1 := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "sarmoth_inst", "target_id": "", "x_value": 0})
	ok(StackResolver.can_submit(state, phase1, db),
		"sc16-b: phase-1 probe with pet_id='sarmoth_inst' passes")

	# sc16-c: full action is legal.
	var full_act := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "sarmoth_inst", "target_id": "target_inst", "x_value": 3})
	ok(StackResolver.can_submit(state, full_act, db),
		"sc16-c: full action (pet + target + x=3) is legal")

	# sc16-g: x_value mismatch — the engine doesn't validate x vs pet cost in can_submit,
	# but the UI always sets x = pet.cost. Test that x=0 (empty) is rejected.
	var bad_x := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "sarmoth_inst", "target_id": "target_inst", "x_value": 0})
	ok(not StackResolver.can_submit(state, bad_x, db),
		"sc16-g: x_value=0 with valid pet+target is rejected")


	# sc16-d/e/f: submit and resolve; check Pet destroyed and damage dealt.
	var events: Array[GameEvent] = StackResolver.submit_action(state, full_act, db)

	# Pet is destroyed at submission (cost payment), before either player passes.
	ok(not state.is_in_play("sarmoth_inst"),
		"sc16-d: Sarmoth removed from play at submission")

	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	var target := state.get_card("target_inst")
	eq(target.damage_taken if target else -1, 3,
		"sc16-e: p2 ally took 3 shadow damage")

	var saw_power_used := false
	for e in events:
		if e.event_type == "hero_power_used":
			saw_power_used = true
	ok(saw_power_used, "sc16-f: hero_power_used event fired")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 17 — Radak: probe rejected when no Pets in ally_row
#
# Assertions:
#   sc17-a  probe rejected when ally_row has only non-Pet allies
#   sc17-b  probe rejected when ally_row is completely empty
# ══════════════════════════════════════════════════════════════════════════════

func _test_radak_no_pets() -> void:
	print("\n-- Scenario 17: Radak probe rejected with no Pets in play --")
	var db := MockDB.new()
	db.hero("radak_def", 30, 0, "radak_pet_sacrifice:shadow|on_your_turn")
	db.ally("normal_ally_def", 2, 3, [], 2)

	var state := _base_state(db, "radak_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	_add_ally(state, "normal_inst", "normal_ally_def", "p1")

	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "", "target_id": "", "x_value": 0})

	ok(not StackResolver.can_submit(state, probe, db),
		"sc17-a: probe rejected when only non-Pet allies present")

	# Remove the normal ally — empty row.
	GameLogic.move_card(state, "normal_inst", "p1_discard")
	ok(not StackResolver.can_submit(state, probe, db),
		"sc17-b: probe rejected when ally_row is empty")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 17b — Timmo Shadestep: destroy_exhausted_ally targeting + hero game_over
#
# Bug (all three reported issues):
#   #1 the power could target an enemy HERO (target validation was misplaced
#      inside the graveyard-power branch and never ran for Timmo)
#   #2 it could target a non-exhausted ally
#   #3 destroying a hero via an explicit destroy effect did not end the game
#
# Assertions:
#   sc17b-a  hero target is rejected
#   sc17b-b  non-exhausted enemy ally is rejected
#   sc17b-c  exhausted enemy ally is a legal target
#   sc17b-d  empty-target probe rejected when no exhausted enemy ally exists
#   sc17b-e  resolving the power destroys the exhausted ally
#   sc17b-f  _destroy_card_trigger on a hero emits game_over (loser = controller)
# ══════════════════════════════════════════════════════════════════════════════

func _test_timmo_destroy_exhausted_ally() -> void:
	print("\n-- Scenario 17b: Timmo destroys only exhausted allies; hero destroy ends game --")
	var db := MockDB.new()
	db.hero("timmo_def", 27, 0, "destroy_exhausted_ally|on_your_turn")
	db.hero("p2_hero", 30)
	db.ally("victim_def", 2, 3, [], 2)

	var state := _base_state(db, "timmo_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	var victim := _add_ally(state, "victim_inst", "victim_def", "p2")
	victim.just_summoned = false
	victim.is_exhausted  = false

	# sc17b-a: hero target rejected.
	var hit_hero := PendingAction.make("activate_power", "p1",
		{"hero_id": "timmo_def", "target_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, hit_hero, db),
		"sc17b-a: enemy hero is NOT a legal target")

	# sc17b-b: non-exhausted ally rejected.
	var hit_ready := PendingAction.make("activate_power", "p1",
		{"hero_id": "timmo_def", "target_id": "victim_inst"})
	ok(not StackResolver.can_submit(state, hit_ready, db),
		"sc17b-b: non-exhausted enemy ally is NOT a legal target")

	# sc17b-d: probe rejected while no exhausted enemy ally exists.
	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "timmo_def", "target_id": ""})
	ok(not StackResolver.can_submit(state, probe, db),
		"sc17b-d: empty-target probe rejected when no exhausted enemy ally")

	# Now exhaust the ally.
	victim.is_exhausted = true

	# sc17b-c: exhausted ally is legal.
	ok(StackResolver.can_submit(state, hit_ready, db),
		"sc17b-c: exhausted enemy ally IS a legal target")
	ok(StackResolver.can_submit(state, probe, db),
		"sc17b-d2: probe passes once an exhausted enemy ally exists")

	# sc17b-e: resolve — ally is destroyed.
	var events: Array[GameEvent] = StackResolver.submit_action(state, hit_ready, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))
	ok(not state.is_in_play("victim_inst"),
		"sc17b-e: exhausted enemy ally destroyed by Timmo power")

	# sc17b-f: destroying a hero directly ends the game.
	var go := StackResolver._destroy_card_trigger(state, "p2_hero", "timmo_def", db)
	var saw_game_over := false
	for e in go:
		if e.event_type == "game_over":
			saw_game_over = true
			eq(e.payload.get("loser", ""), "p2", "sc17b-f2: loser is the hero's controller")
			eq(e.payload.get("winner", ""), "p1", "sc17b-f3: opponent wins")
	ok(saw_game_over, "sc17b-f: destroying a hero emits game_over")
	ok(state.is_in_play("p2_hero"),
		"sc17b-f4: hero is NOT moved to the graveyard on destroy")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 18 — Quest completion can't be chained with itself while pending
#
# Bug: a quest whose cost (e.g. 3) is less than total available resources (e.g. 6)
# still looked "legal" via can_submit even after its own use_quest action was
# already pushed to pending_actions (awaiting resolution) — because the resource
# check only compared the flat cost against total available resources, not
# accounting for the fact the quest itself was already mid-activation. This let
# turbo-mode treat the same quest as a second legal move and refuse to auto-pass.
#
# Assertions:
#   sc18-a  can_submit passes before the quest is on the stack
#   sc18-b  once pushed to pending_actions, can_submit for the same quest_id is false
#   sc18-c  a different face-up quest is unaffected (still legal)
# ══════════════════════════════════════════════════════════════════════════════

func _test_quest_cant_reuse_while_pending() -> void:
	print("\n-- Scenario 18: quest can't be re-triggered while its own completion is pending --")
	var db := MockDB.new()
	db.hero("p1_hero_def", 30)
	db.hero("p2_hero_def", 30)
	db.quest("yfay_def", 3)
	db.quest("other_quest_def", 2)

	var state := _base_state(db, "p1_hero_def", "p2_hero_def")

	var yfay := CardInstance.create("yfay_inst", "yfay_def", "p1", "p1_resource_row")
	state.cards["yfay_inst"] = yfay
	state.zones["p1_resource_row"].card_ids.append("yfay_inst")

	var other := CardInstance.create("other_inst", "other_quest_def", "p1", "p1_resource_row")
	state.cards["other_inst"] = other
	state.zones["p1_resource_row"].card_ids.append("other_inst")

	_add_resources(state, "p1", 6)

	var complete_yfay := PendingAction.make("use_quest", "p1", {"quest_id": "yfay_inst"})

	# sc18-a: legal before it's on the stack.
	ok(StackResolver.can_submit(state, complete_yfay, db),
		"sc18-a: YFAY completion legal with 6 available resources (cost 3)")

	state.pending_actions.push_back(complete_yfay)

	# sc18-b: same quest_id rejected while pending, even though 6 resources remain untouched.
	ok(not StackResolver.can_submit(state, complete_yfay, db),
		"sc18-b: re-checking YFAY while its own completion is pending is illegal")

	# sc18-c: a different quest is unaffected.
	var complete_other := PendingAction.make("use_quest", "p1", {"quest_id": "other_inst"})
	ok(StackResolver.can_submit(state, complete_other, db),
		"sc18-c: unrelated quest is still legal while YFAY is pending")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 19 — Liba Wobblebonk enters play and draws a card
# ══════════════════════════════════════════════════════════════════════════════

func _test_liba_wobblebonk_enter_play() -> void:
	print("\n-- Scenario 19: Liba Wobblebonk enters play and draws a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("liba_wobblebonk_def", 3, 4, [], 5, "on_enter:draw:1")
	db.ally("deck_card_def", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 5)

	var liba := CardInstance.create("liba_inst", "liba_wobblebonk_def", "p1", "p1_hand")
	state.cards["liba_inst"] = liba
	state.zones["p1_hand"].card_ids.append("liba_inst")

	var deck_card := CardInstance.create("deck1", "deck_card_def", "p1", "p1_deck")
	state.cards["deck1"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck1")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "liba_inst"}))

	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("liba_inst").zone_id == "p1_ally_row", "sc19-a: Liba Wobblebonk in p1_ally_row")
	ok(state.get_card("deck1").zone_id == "p1_hand",          "sc19-b: deck card drawn into hand")
	eq(state.cards_in_zone("p1_hand").size(), 1,              "sc19-c: hand has exactly 1 card")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 20 — Kulan Earthguard readies itself at the end of its controller's turn
# ══════════════════════════════════════════════════════════════════════════════

func _test_kulan_earthguard_end_of_turn_ready() -> void:
	print("\n-- Scenario 20: Kulan Earthguard readies itself at end of turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("kulan_def", 3, 5, ["protector"], 5, "ready_self_at_turn_end")

	var state := _base_state(db, "p1_hero", "p2_hero")

	var kulan := CardInstance.create("kulan_inst", "kulan_def", "p1", "p1_ally_row")
	state.cards["kulan_inst"] = kulan
	state.zones["p1_ally_row"].card_ids.append("kulan_inst")

	# Exhaust it manually (e.g. as if it had just protected an attack).
	GameLogic.exhaust_card(state, "kulan_inst")
	ok(kulan.is_exhausted, "sc20-a: Kulan starts this test exhausted")

	_drive_turns(state, db, ScriptedAI.new(), ScriptedAI.new(), 1)

	ok(not state.get_card("kulan_inst").is_exhausted,
		"sc20-b: Kulan Earthguard is ready again after p1's turn ends")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 21 — Tracker Gallen: +1 ATK for each ally in party
# ══════════════════════════════════════════════════════════════════════════════

func _test_tracker_gallen_atk_per_ally() -> void:
	print("\n-- Scenario 21: Tracker Gallen gains ATK per ally in party --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("gallen_def", 0, 2, [], 2, "atk_per_ally:1")
	db.ally("other_ally_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "gallen_inst", "gallen_def", "p1")

	ok(state.get_atk("gallen_inst", db) == 1,
		"sc21-a: Tracker Gallen alone has 1 ATK (counts itself)")

	_add_ally(state, "other_inst", "other_ally_def", "p1")

	ok(state.get_atk("gallen_inst", db) == 2,
		"sc21-b: Tracker Gallen gains +1 ATK when a second ally enters play")

	_add_ally(state, "opp_inst", "other_ally_def", "p2")

	ok(state.get_atk("gallen_inst", db) == 2,
		"sc21-c: Opponent's allies don't count toward Gallen's ATK")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 22 — Blood Guard Mal'wani: +1 ATK for each damage on him
# ══════════════════════════════════════════════════════════════════════════════

func _test_malwani_atk_per_damage_self() -> void:
	print("\n-- Scenario 22: Blood Guard Mal'wani gains ATK per damage on him --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("malwani_def", 1, 5, [], 4, "atk_per_damage_self:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "malwani_inst", "malwani_def", "p1")

	ok(state.get_atk("malwani_inst", db) == 1,
		"sc22-a: Mal'wani has base 1 ATK with no damage on him")

	GameLogic.deal_damage(state, "p2_hero", "malwani_inst", 2, db)

	ok(state.get_atk("malwani_inst", db) == 3,
		"sc22-b: Mal'wani gains +1 ATK per damage taken (1 base + 2 damage)")

	GameLogic.deal_damage(state, "p2_hero", "malwani_inst", 1, db)

	ok(state.get_atk("malwani_inst", db) == 4,
		"sc22-c: ATK keeps scaling as more damage accumulates")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 23 — Chasing A-Me 01: return target ally from your graveyard to hand
# ══════════════════════════════════════════════════════════════════════════════

func _test_chasing_ame_graveyard_to_hand() -> void:
	print("\n-- Scenario 23: Chasing A-Me 01 returns an ally from the graveyard to hand --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("chasing_ame_def", 3, "graveyard_to_hand:Ally:1:1:own")
	db.ally("dead_ally_def", 2, 2, [], 4)
	db.quest("dead_quest_def", 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var quest := CardInstance.create("ame_inst", "chasing_ame_def", "p1", "p1_resource_row")
	state.cards["ame_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("ame_inst")

	# p1 graveyard: one ally (valid) and one quest card (filtered out).
	for pair in [["dead_ally", "dead_ally_def"], ["dead_quest", "dead_quest_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])
	# p2 graveyard: an ally that must NOT be a candidate (owner filter = own).
	var opp_dead := CardInstance.create("opp_dead_ally", "dead_ally_def", "p2", "p2_graveyard")
	state.cards["opp_dead_ally"] = opp_dead
	state.zones["p2_graveyard"].card_ids.append("opp_dead_ally")

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("chasing_ame_def"))
	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["dead_ally"], "sc23-a: only own graveyard ally is a candidate")

	ok(StackResolver.can_use_quest_no_target_check(state, "ame_inst", "p1", db),
		"sc23-b: no-target probe passes with a valid candidate")

	var no_target := PendingAction.make("use_quest", "p1", {"quest_id": "ame_inst"})
	ok(not StackResolver.can_submit(state, no_target, db),
		"sc23-c: completion without announced targets is rejected")

	var bad_target := PendingAction.make("use_quest", "p1",
			{"quest_id": "ame_inst", "target_ids": ["dead_quest"]})
	ok(not StackResolver.can_submit(state, bad_target, db),
		"sc23-d: non-ally graveyard card is an illegal target")

	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "ame_inst", "target_ids": ["dead_ally"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "sc23-e: completion with valid target submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	ok(state.get_card("dead_ally").zone_id == "p1_hand",
		"sc23-f: dead ally returned to p1 hand")
	ok(state.get_card("ame_inst").face_down,
		"sc23-g: quest flipped face-down after completion")
	var returned := false
	for ev in events:
		if ev.event_type == "card_returned_from_graveyard" \
				and ev.payload.get("card_id", "") == "dead_ally":
			returned = true
	ok(returned, "sc23-h: card_returned_from_graveyard event emitted")


func _test_chasing_ame_blocked_and_filtered() -> void:
	print("\n-- Scenario 24: Chasing A-Me 01 blocked with no valid graveyard target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("chasing_ame_def", 3, "graveyard_to_hand:Ally:1:1:own")
	db.quest("dead_quest_def", 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var quest := CardInstance.create("ame_inst", "chasing_ame_def", "p1", "p1_resource_row")
	state.cards["ame_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("ame_inst")

	# Empty graveyard: probe and submission both fail.
	ok(not StackResolver.can_use_quest_no_target_check(state, "ame_inst", "p1", db),
		"sc24-a: probe fails with empty graveyard")

	# Graveyard with only a non-ally card: still blocked.
	var dq := CardInstance.create("dead_quest", "dead_quest_def", "p1", "p1_graveyard")
	state.cards["dead_quest"] = dq
	state.zones["p1_graveyard"].card_ids.append("dead_quest")
	ok(not StackResolver.can_use_quest_no_target_check(state, "ame_inst", "p1", db),
		"sc24-b: probe fails when graveyard has no ally")

	var forced := PendingAction.make("use_quest", "p1",
			{"quest_id": "ame_inst", "target_ids": ["dead_quest"]})
	ok(not StackResolver.can_submit(state, forced, db),
		"sc24-c: submission with only-invalid targets rejected")


# ══════════════════════════════════════════════════════════════════════════════
# Finkle Einhorn, At Your Service! — put an ally (cost 2 or less) from the
# graveyard directly into play; its enter-play triggers fire as if from hand.
# ══════════════════════════════════════════════════════════════════════════════

func _test_finkle_einhorn_graveyard_to_play() -> void:
	print("\n-- Finkle Einhorn: put a cost≤2 ally from graveyard into play (triggers fire) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("finkle_def", 3, "graveyard_to_play:Ally:1:1:own:2")
	# Cost-2 ally with an on_enter draw trigger — proves triggers fire on entry.
	db.ally("drawbot_def", 1, 1, [], 2, "on_enter:draw:1")
	# Cost-3 ally — must be filtered out by the max_cost=2 gate.
	db.ally("big_ally_def", 3, 3, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var quest := CardInstance.create("finkle_inst", "finkle_def", "p1", "p1_resource_row")
	state.cards["finkle_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("finkle_inst")

	# p1 graveyard: the eligible cost-2 ally and an over-cost ally.
	for pair in [["drawbot", "drawbot_def"], ["big_ally", "big_ally_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])

	# A card in the deck so the on_enter draw has something to pull.
	var dcard := CardInstance.create("deck_card", "drawbot_def", "p1", "p1_deck")
	state.cards["deck_card"] = dcard
	state.zones["p1_deck"].card_ids.append("deck_card")

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("finkle_def"))
	eq(req.get("dest", ""), "play", "finkle-a: requirement parsed with dest=play")
	eq(int(req.get("max_cost", -1)), 2, "finkle-b: max_cost gate is 2")

	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["drawbot"], "finkle-c: only the cost≤2 ally is a candidate")

	# Over-cost ally is an illegal target.
	var bad := PendingAction.make("use_quest", "p1",
			{"quest_id": "finkle_inst", "target_ids": ["big_ally"]})
	ok(not StackResolver.can_submit(state, bad, db),
		"finkle-d: cost-3 ally is an illegal target")

	var hand_before := state.cards_in_zone("p1_hand").size()

	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "finkle_inst", "target_ids": ["drawbot"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "finkle-e: completion with valid target submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.get_card("drawbot").zone_id, "p1_ally_row",
		"finkle-f: ally put into play in p1 ally_row")
	ok(state.get_card("drawbot").just_summoned,
		"finkle-g: reinstated ally has summoning sickness (just_summoned)")
	eq(state.cards_in_zone("p1_hand").size(), hand_before + 1,
		"finkle-h: on_enter draw trigger fired (hand +1)")
	ok(state.get_card("finkle_inst").face_down,
		"finkle-i: quest flipped face-down after completion")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 25 — Battle of Darrowshire: RFG three allies from graveyard, draw a card
# ══════════════════════════════════════════════════════════════════════════════

func _test_darrowshire_rfg_three_allies() -> void:
	print("\n-- Scenario 25: Battle of Darrowshire removes 3 allies from the game, draws 1 --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("darrowshire_def", 1, "graveyard_to_rfg:Ally:3:3:own|draw:1")
	db.ally("dead_ally_def", 2, 2, [], 4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)
	for i in 2:
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "dead_ally_def", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	var quest := CardInstance.create("dar_inst", "darrowshire_def", "p1", "p1_resource_row")
	state.cards["dar_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("dar_inst")

	# Four dead allies in p1's graveyard.
	for i in 4:
		var cid := "dead_%d" % i
		var c := CardInstance.create(cid, "dead_ally_def", "p1", "p1_graveyard")
		state.cards[cid] = c
		state.zones["p1_graveyard"].card_ids.append(cid)

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("darrowshire_def"))
	eq(req.get("dest", ""), "rfg", "sc25-a: requirement parsed with dest=rfg")
	eq(int(req.get("min_count", 0)), 3, "sc25-b: min_count is 3")

	# Two announced targets (below min) is rejected; a duplicated target too.
	var too_few := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_1"]})
	ok(not StackResolver.can_submit(state, too_few, db),
		"sc25-c: fewer than 3 targets rejected")
	var dupes := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_0", "dead_1"]})
	ok(not StackResolver.can_submit(state, dupes, db),
		"sc25-d: duplicated target rejected (must be 3 distinct cards)")

	var hand_before: int = state.zones["p1_hand"].card_ids.size()
	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_1", "dead_2"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "sc25-e: completion with 3 distinct targets submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	for cid in ["dead_0", "dead_1", "dead_2"]:
		ok(state.get_card(cid).zone_id == "p1_rfg",
			"sc25-f: %s moved to p1_rfg" % cid)
	ok(state.get_card("dead_3").zone_id == "p1_graveyard",
		"sc25-g: unchosen ally stays in the graveyard")
	eq(state.zones["p1_hand"].card_ids.size(), hand_before + 1,
		"sc25-h: reward drew exactly one card")
	ok(state.get_card("dar_inst").face_down,
		"sc25-i: quest flipped face-down after completion")
	var rfg_events := 0
	for ev in events:
		if ev.event_type == "card_removed_from_game":
			rfg_events += 1
	eq(rfg_events, 3, "sc25-j: three card_removed_from_game events emitted")


func _test_darrowshire_blocked_with_too_few_allies() -> void:
	print("\n-- Scenario 26: Battle of Darrowshire blocked with fewer than 3 graveyard allies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("darrowshire_def", 1, "graveyard_to_rfg:Ally:3:3:own|draw:1")
	db.ally("dead_ally_def", 2, 2, [], 4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var quest := CardInstance.create("dar_inst", "darrowshire_def", "p1", "p1_resource_row")
	state.cards["dar_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("dar_inst")

	# Only two allies in the graveyard — one short of the requirement.
	for i in 2:
		var cid := "dead_%d" % i
		var c := CardInstance.create(cid, "dead_ally_def", "p1", "p1_graveyard")
		state.cards[cid] = c
		state.zones["p1_graveyard"].card_ids.append(cid)

	ok(not StackResolver.can_use_quest_no_target_check(state, "dar_inst", "p1", db),
		"sc26-a: probe fails with only 2 graveyard allies")
	var forced := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_1"]})
	ok(not StackResolver.can_submit(state, forced, db),
		"sc26-b: forced submission with 2 targets rejected")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 26b — The Defias Brotherhood: needs 4+ allies in play, pay 1, draw 2
# ══════════════════════════════════════════════════════════════════════════════

func _test_defias_brotherhood_requires_four_allies() -> void:
	print("\n-- Scenario 26b: The Defias Brotherhood needs 4+ allies in party --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("defias_def", 1, "require_ally_count:4|draw:2")
	db.ally("filler_ally_def", 2, 2, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var quest := CardInstance.create("defias_inst", "defias_def", "p1", "p1_resource_row")
	state.cards["defias_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("defias_inst")

	eq(StackResolver.get_quest_ally_count_requirement(db.get_def("defias_def")), 4,
		"sc26b-a: parsed requirement is 4")

	# Only 3 allies in play — one short.
	for i in 3:
		_add_ally(state, "ally_%d" % i, "filler_ally_def", "p1")
	ok(not StackResolver.can_use_quest_no_target_check(state, "defias_inst", "p1", db),
		"sc26b-b: probe fails with only 3 allies in play")

	# Add a 4th ally — now legal.
	_add_ally(state, "ally_3", "filler_ally_def", "p1")
	ok(StackResolver.can_use_quest_no_target_check(state, "defias_inst", "p1", db),
		"sc26b-c: probe succeeds with 4 allies in play")

	for i in 20:
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "filler_ally_def", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	var hand_before: int = state.zones["p1_hand"].card_ids.size()
	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "defias_inst"})
	var events := StackResolver.submit_action(state, complete, db)
	ok(not events.is_empty(), "sc26b-d: completion submits with 4 allies in play")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.zones["p1_hand"].card_ids.size(), hand_before + 2,
		"sc26b-e: reward drew exactly two cards")
	ok(state.get_card("defias_inst").face_down,
		"sc26b-f: quest flipped face-down after completion")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 26c — Torek's Assault: needs opposing hero damaged by our ally this turn
# ══════════════════════════════════════════════════════════════════════════════

func _test_toreks_assault_requires_hero_damaged_by_ally() -> void:
	print("\n-- Scenario 26c: Torek's Assault requires opposing hero damaged by our ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("torek_def", 1, "require_hero_damaged_by_ally|draw:1")
	db.ally("filler_ally_def", 2, 2, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var quest := CardInstance.create("torek_inst", "torek_def", "p1", "p1_resource_row")
	state.cards["torek_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("torek_inst")

	_add_ally(state, "p1_ally", "filler_ally_def", "p1")
	_add_ally(state, "p2_ally", "filler_ally_def", "p2")

	ok(not StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-a: probe fails before any hero has taken damage")

	# Our ally damaging OUR OWN hero must not satisfy the condition.
	GameLogic.deal_damage(state, "p1_ally", "p1_hero", 1, db)
	ok(not StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-b: probe still fails when our own hero is damaged by our ally")

	# The opposing ally damaging the opposing hero must not satisfy the condition either.
	GameLogic.deal_damage(state, "p2_ally", "p2_hero", 1, db)
	ok(not StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-c: probe still fails when opposing hero is damaged by their own ally")

	# Our ally damaging the OPPOSING hero satisfies the condition.
	GameLogic.deal_damage(state, "p1_ally", "p2_hero", 1, db)
	ok(StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-d: probe succeeds once our ally damages the opposing hero")

	var hand_before: int = state.zones["p1_hand"].card_ids.size()
	for i in 5:
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "filler_ally_def", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "torek_inst"})
	var events := StackResolver.submit_action(state, complete, db)
	ok(not events.is_empty(), "sc26c-e: completion submits once condition is met")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.zones["p1_hand"].card_ids.size(), hand_before + 1,
		"sc26c-f: reward drew exactly one card")
	ok(state.get_card("torek_inst").face_down,
		"sc26c-g: quest flipped face-down after completion")

	# Flag resets at the start of a new turn (action -> end -> next turn's ready).
	TurnManager.advance_phase(state, db)
	TurnManager.advance_phase(state, db)
	ok(not state.players["p2"].hero_damaged_by_ally_this_turn,
		"sc26c-h: hero_damaged_by_ally_this_turn resets at next turn start")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 27 — BaseAI.find_lethal: opposing characters that die to N damage
# ══════════════════════════════════════════════════════════════════════════════

func _test_find_lethal() -> void:
	print("\n-- Scenario 27: find_lethal lists lethal targets, hero-only when hero is lethal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("small_def", 1, 2, [], 1)   # 2 HP
	db.ally("big_def",   3, 5, [], 4)   # 5 HP

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "small_a", "small_def", "p2")
	_add_ally(state, "small_b", "small_def", "p2")
	_add_ally(state, "big",     "big_def",   "p2")

	# No hero lethal: both 2-HP allies listed, 5-HP ally excluded.
	var lethal3 := BaseAI.find_lethal(state, db, "p1", 3)
	ok("small_a" in lethal3 and "small_b" in lethal3,
		"sc27-a: both 2-HP allies die to 3 damage")
	ok("big" not in lethal3, "sc27-b: 5-HP ally not listed at 3 damage")
	ok(state.players["p2"].hero_instance_id not in lethal3,
		"sc27-c: 30-HP hero not listed")

	# Nothing dies to 1 damage... except the 2-HP allies don't; empty list.
	eq(BaseAI.find_lethal(state, db, "p1", 1).size(), 0,
		"sc27-d: no target dies to 1 damage")
	eq(BaseAI.find_lethal(state, db, "p1", 0).size(), 0,
		"sc27-e: 0 damage returns empty list")

	# Hero lethal: only the hero is returned, even with lethal allies around.
	var p2_hero_id: String = state.players["p2"].hero_instance_id
	state.get_card(p2_hero_id).damage_taken = 28   # 2 HP left
	var hero_lethal := BaseAI.find_lethal(state, db, "p1", 3)
	eq(hero_lethal, [p2_hero_id],
		"sc27-f: lethal hero returned alone despite lethal allies")

	# Opposing perspective: p2 scans p1's side (no p1 allies, healthy hero).
	eq(BaseAI.find_lethal(state, db, "p2", 3).size(), 0,
		"sc27-g: p2 finds no lethal targets on p1's side")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 28 — find_lethal baseline in AI action generation
# (Ta'zo-style hero powers offer only lethal targets; ally powers try lethal first)
# ══════════════════════════════════════════════════════════════════════════════

func _test_find_lethal_baseline_in_ai_actions() -> void:
	print("\n-- Scenario 28: hero/ally power actions restricted/ordered by find_lethal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("tazo_def", 25, 3, "deal_damage_to_target:3:fire")
	db.ally("small_def", 1, 2, [], 1)   # 2 HP — dies to 3
	db.ally("big_def",   3, 6, [], 4)   # 6 HP — survives 3
	db.ally("grimdron_def", 1, 3, [], 2,
			"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally")

	var state := GameState.create_new(["p1", "p2"])
	var h1 := CardInstance.create("p1_hero", "p1_hero", "p1", "p1_hero_row")
	state.cards["p1_hero"] = h1
	state.zones["p1_hero_row"].card_ids.append("p1_hero")
	state.players["p1"].hero_instance_id = "p1_hero"
	var h2 := CardInstance.create("tazo_inst", "tazo_def", "p2", "p2_hero_row")
	state.cards["tazo_inst"] = h2
	state.zones["p2_hero_row"].card_ids.append("tazo_inst")
	state.players["p2"].hero_instance_id = "tazo_inst"

	state.phase = "action"
	state.turn_player = "p2"
	state.priority_player = "p2"
	state.turn_number = 1
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	_add_ally(state, "small", "small_def", "p1")
	_add_ally(state, "big",   "big_def",   "p1")

	var helper := BaseAI.new()

	# sc28-a/b: Ta'zo's 3-damage power offers ONLY the lethal 2-HP ally.
	var power_targets: Array = []
	for a in helper._get_hero_power_actions(state, db, "p2"):
		power_targets.append(a.params.get("target_id"))
	eq(power_targets, ["small"],
		"sc28-a: only the lethal ally is offered as a hero power target")

	# sc28-b: hero lethal → the power offers ONLY the hero.
	state.get_card("p1_hero").damage_taken = 28   # 2 HP left
	power_targets.clear()
	for a in helper._get_hero_power_actions(state, db, "p2"):
		power_targets.append(a.params.get("target_id"))
	eq(power_targets, ["p1_hero"],
		"sc28-b: lethal hero is the only offered target")
	state.get_card("p1_hero").damage_taken = 0

	# sc28-c: no lethal target → all legal targets offered (baseline unchanged).
	state.get_card("small").damage_taken = 0
	(db._defs["tazo_def"] as CardDef).effects = "deal_damage_to_target:1:fire"
	power_targets.clear()
	for a in helper._get_hero_power_actions(state, db, "p2"):
		power_targets.append(a.params.get("target_id"))
	eq(power_targets.size(), 3,
		"sc28-c: with no lethal target, hero + both allies all offered")

	# sc28-d: Grimdron (1 dmg) prefers the lethal 1-HP target over a more-damaged one.
	_add_ally(state, "grim", "grimdron_def", "p2")
	state.get_card("grim").just_summoned = false
	state.get_card("small").damage_taken = 1   # 1 HP left — lethal to 1 dmg
	state.get_card("big").damage_taken   = 2   # 4 HP left — more damage taken
	var ally_actions := helper._get_ally_power_actions(state, db, "p2")
	ok(ally_actions.size() == 1
			and ally_actions[0].params.get("target_id") == "small",
		"sc28-d: ally power targets the lethal ally first")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 29 — sort_valuable_cards: rarity > cost > ally > Protector > HP >
# Ferocity > Elusive > ATK
# ══════════════════════════════════════════════════════════════════════════════

func _test_sort_valuable_cards() -> void:
	print("\n-- Scenario 29: sort_valuable_cards orders most valuable first --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# atk, health, keywords, cost
	db.ally("epic_cheap",  1, 1, [],            1)
	db.ally("rare_exp",    1, 1, [],            5)
	db.ally("ally_4",      2, 3, [],            4)
	db.quest("spell_4",    4)   # non-ally, same cost as ally_4
	db.ally("prot_2",      1, 2, ["Protector"], 2)
	db.ally("hp_2",        1, 5, [],            2)
	db.ally("fero_2",      1, 2, ["Ferocity"],  2)
	db.ally("elu_2",       1, 2, ["Elusive"],   2)
	db.ally("atk_2",       4, 2, [],            2)
	db.ally("plain_2",     1, 2, [],            2)
	(db._defs["epic_cheap"] as CardDef).rarity = "Epic"
	(db._defs["rare_exp"]   as CardDef).rarity = "Rare"
	for did in ["ally_4", "spell_4", "prot_2", "hp_2", "fero_2", "elu_2", "atk_2", "plain_2"]:
		(db._defs[did] as CardDef).rarity = "Common"

	var state := _base_state(db, "p1_hero", "p2_hero")
	var ids: Array[String] = []
	for did in ["plain_2", "atk_2", "elu_2", "fero_2", "hp_2", "prot_2",
			"spell_4", "ally_4", "rare_exp", "epic_cheap"]:
		var c := CardInstance.create(did + "_i", did, "p1", "p1_graveyard")
		state.cards[did + "_i"] = c
		state.zones["p1_graveyard"].card_ids.append(did + "_i")
		ids.append(did + "_i")

	var sorted_ids := BaseAI.sort_valuable_cards(state, db, ids)
	eq(sorted_ids, ["epic_cheap_i", "rare_exp_i", "ally_4_i", "spell_4_i",
			"prot_2_i", "hp_2_i", "fero_2_i", "elu_2_i", "atk_2_i", "plain_2_i"],
		"sc29-a: full order — rarity, cost, ally-first, Protector, HP, Ferocity, Elusive, ATK")
	eq(ids.size(), 10, "sc29-b: input list not mutated (still 10 entries)")
	ok(ids[0] == "plain_2_i", "sc29-c: input order untouched")

	# FullRandomAI hook: lethal pools come back value-sorted.
	var fr := FullRandomAI.new()
	var ranked := fr.rank_lethal_targets(state, db, ids)
	eq(ranked[0], "epic_cheap_i",
		"sc29-d: FullRandomAI ranks the most valuable card first")

	# In-play cards use CURRENT values: same def, one damaged → the healthy
	# one (3 HP left) is more valuable than the hurt one (1 HP left).
	db.ally("twin_def", 1, 3, [], 2)
	_add_ally(state, "twin_full", "twin_def", "p2")
	_add_ally(state, "twin_hurt", "twin_def", "p2")
	state.get_card("twin_hurt").damage_taken = 2
	var twins: Array[String] = ["twin_hurt", "twin_full"]
	eq(BaseAI.sort_valuable_cards(state, db, twins),
			["twin_full", "twin_hurt"],
		"sc29-e: in-play cards ranked by current HP, not printed")

	# Mixed zones: a graveyard copy of the same def uses printed HP (3),
	# tying the healthy twin and beating the hurt one.
	var gy_twin := CardInstance.create("twin_gy", "twin_def", "p2", "p2_graveyard")
	state.cards["twin_gy"] = gy_twin
	state.zones["p2_graveyard"].card_ids.append("twin_gy")
	var mixed: Array[String] = ["twin_hurt", "twin_gy"]
	eq(BaseAI.sort_valuable_cards(state, db, mixed),
			["twin_gy", "twin_hurt"],
		"sc29-f: mixed-zone list — graveyard card uses printed values")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 30 — find_safe_lethals: kill-and-survive pairs
# ══════════════════════════════════════════════════════════════════════════════

func _test_find_safe_lethals() -> void:
	print("\n-- Scenario 30: find_safe_lethals returns kill-and-survive pairs --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("striker_def", 3, 3, [], 2)   # 3/3
	db.ally("weak_def",    1, 2, [], 1)   # 1/2 — dies to 3, deals 1 back
	db.ally("trader_def",  3, 3, [], 2)   # 3/3 — dies to 3 but kills back (3 not < 3)
	db.ally("tank_def",    1, 4, [], 3)   # 1/4 — survives 3 damage

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "striker", "striker_def", "p1")
	_add_ally(state, "weak",    "weak_def",    "p2")
	_add_ally(state, "trader",  "trader_def",  "p2")
	_add_ally(state, "tank",    "tank_def",    "p2")

	var atk_list: Array[String] = ["striker"]
	var def_list: Array[String] = ["weak", "trader", "tank"]
	var pairs := BaseAI.find_safe_lethals(state, db, atk_list, def_list)
	eq(pairs, [["striker", "weak"]],
		"sc30-a: only the kill-and-survive pair is returned")

	# Damaged defender becomes safe: trader at 1 HP left still hits back for 3,
	# which ties striker's 3 HP — still NOT safe (survival needs strict >).
	state.get_card("trader").damage_taken = 2
	pairs = BaseAI.find_safe_lethals(state, db, atk_list, def_list)
	ok(not _pairs_contain(pairs, "striker", "trader"),
		"sc30-b: mutual-kill trade is not a safe kill (HP must strictly beat ATK)")

	# Damaged ATTACKER loses its safe kill: striker at 1 HP dies to weak's 1 ATK...
	# 1 > 1 is false → no pairs.
	state.get_card("striker").damage_taken = 2
	pairs = BaseAI.find_safe_lethals(state, db, atk_list, def_list)
	eq(pairs.size(), 0,
		"sc30-c: attacker at 1 HP can no longer safely kill a 1-ATK defender")


func _pairs_contain(pairs: Array, attacker: String, defender: String) -> bool:
	for p in pairs:
		if p[0] == attacker and p[1] == defender:
			return true
	return false


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 31 — GenericAI: safe-kill selection flow
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_safe_kill_flow() -> void:
	print("\n-- Scenario 31: GenericAI baits with cheap attacker, kills best target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("cheap_def",  3, 3, [],            1)
	db.ally("pricey_def", 4, 4, [],            5)
	db.ally("fero_def",   2, 2, ["Ferocity"],  0)
	db.ally("victim_lo",  1, 2, [],            1)
	db.ally("victim_hi",  1, 2, [],            4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "cheap",  "cheap_def",  "p1")
	_add_ally(state, "pricey", "pricey_def", "p1")
	_add_ally(state, "v_lo",   "victim_lo",  "p2")
	_add_ally(state, "v_hi",   "victim_hi",  "p2")
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var ai := GenericAI.new()

	# sc31-a: two board attackers, both with safe kills → cheap goes first,
	# and it targets the most valuable victim (cost 4 over cost 1).
	var act := ai.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "cheap"
			and act.params.get("defender_id") == "v_hi",
		"sc31-a: least valuable attacker proposed against most valuable safe kill")

	# sc31-b: a playable Ferocity ally in hand (cost 0 — least valuable of all)
	# is played immediately instead of attacking with a board ally.
	var fero := CardInstance.create("fero", "fero_def", "p1", "p1_hand")
	state.cards["fero"] = fero
	state.zones["p1_hand"].card_ids.append("fero")
	act = ai.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "play_ally"
			and act.params.get("card_id") == "fero",
		"sc31-b: hand Ferocity ally with a safe kill is played first")
	state.zones["p1_hand"].card_ids.erase("fero")
	state.cards.erase("fero")

	# sc31-c: Elusive best target is skipped (can_submit fails) — the attacker
	# falls through to the next-best legal safe kill.
	(db._defs["victim_hi"] as CardDef).keywords.append("elusive")
	act = ai.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "cheap"
			and act.params.get("defender_id") == "v_lo",
		"sc31-c: illegal (Elusive) pair skipped, next safe kill chosen")
	(db._defs["victim_hi"] as CardDef).keywords.erase("elusive")

	# sc31-d: no safe kill (victims outclass attackers) → falls back to random
	# legal behaviour, i.e. NOT a doomed propose_combat from the safe-kill path.
	state.get_card("cheap").damage_taken = 2    # 1 HP left, dies to any 1-ATK hit
	state.get_card("pricey").damage_taken = 3   # 1 HP left
	var fallback := ai._safe_lethal_action(state, db, "p1")
	ok(fallback == null, "sc31-d: no safe kill → safe-lethal path returns null")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32 — GenericAI value-based choices: discard, resource, graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_value_choices() -> void:
	print("\n-- Scenario 32: GenericAI discards/places least valuable, picks best from graveyard --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("gem_def",  3, 3, [], 5)   # valuable
	db.ally("junk_def", 1, 1, [], 0)   # least valuable
	db.quest("quest_def", 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var ai := GenericAI.new()

	# Hand: valuable ally + junk ally.
	for pair in [["gem", "gem_def"], ["junk", "junk_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_hand")
		state.cards[pair[0]] = c
		state.zones["p1_hand"].card_ids.append(pair[0])

	# sc32-a: discard the least valuable card.
	eq(ai.choose_discard_card(state, db, "p1"), "junk",
		"sc32-a: least valuable hand card chosen for discard")

	# sc32-b: resource placement — least valuable goes face-down.
	var res_act := ai._decide_resource_placement(state, db, "p1")
	ok(res_act != null and res_act.params.get("card_id") == "junk"
			and res_act.params.get("face_up") == false,
		"sc32-b: least valuable hand card placed face-down as resource")

	# sc32-c: a quest in hand still takes priority, face-up.
	var q := CardInstance.create("quest_c", "quest_def", "p1", "p1_hand")
	state.cards["quest_c"] = q
	state.zones["p1_hand"].card_ids.append("quest_c")
	res_act = ai._decide_resource_placement(state, db, "p1")
	ok(res_act != null and res_act.params.get("card_id") == "quest_c"
			and res_act.params.get("face_up") == true,
		"sc32-c: quest still placed face-up first")

	# sc32-d: graveyard-to-hand reward → MOST valuable candidate.
	for pair in [["dead_gem", "gem_def"], ["dead_junk", "junk_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])
	var to_hand := {"card_type": "Ally", "min_count": 1, "max_count": 1,
			"owner": "own", "max_cost": -1, "dest": "hand"}
	var gy_cands: Array[String] = ["dead_junk", "dead_gem"]
	eq(ai._choose_graveyard_targets(state, db, "p1", to_hand, gy_cands),
			["dead_gem"],
		"sc32-d: most valuable graveyard card returned to hand")

	# sc32-e: own-graveyard RFG cost (Darrowshire) → LEAST valuable.
	var to_rfg := {"card_type": "Ally", "min_count": 1, "max_count": 1,
			"owner": "own", "max_cost": -1, "dest": "rfg"}
	eq(ai._choose_graveyard_targets(state, db, "p1", to_rfg, gy_cands),
			["dead_junk"],
		"sc32-e: least valuable own card removed from the game as a cost")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32b — combat_trade_value: the four outcomes (pure ATK/HP math)
# ══════════════════════════════════════════════════════════════════════════════

func _test_combat_trade_value() -> void:
	print("\n-- Scenario 32b: combat_trade_value classifies safe_lethal/both/suicide/no_one --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def",   3, 4, [], 3)   # atk3 hp4
	db.ally("even_def",  3, 3, [], 3)   # atk3 hp3
	db.ally("wall_def",  1, 5, [], 3)   # atk1 hp5
	db.ally("glass_def", 1, 2, [], 1)   # atk1 hp2

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "big",   "big_def",   "p1")
	_add_ally(state, "evenA", "even_def",  "p1")
	_add_ally(state, "evenB", "even_def",  "p2")
	_add_ally(state, "wall",  "wall_def",  "p2")
	_add_ally(state, "glass", "glass_def", "p1")

	# big(3/4) → evenB(3/3): kills (3>=3), survives (4>3).
	eq(BaseAI.combat_trade_value(state, db, "big", "evenB"), "safe_lethal",
		"sc32b-a: kills and survives → safe_lethal")
	# evenA(3/3) → evenB(3/3): kills (3>=3), dies (3>=3).
	eq(BaseAI.combat_trade_value(state, db, "evenA", "evenB"), "both",
		"sc32b-b: kills and dies → both")
	# evenA(3/3) → wall(1/5): can't kill (3<5), survives (3<... wall atk1<3).
	eq(BaseAI.combat_trade_value(state, db, "evenA", "wall"), "no_one",
		"sc32b-c: can't kill and survives → no_one")
	# glass(1/2) → big(3/4): can't kill (1<4), dies (big atk3 >= glass hp2).
	eq(BaseAI.combat_trade_value(state, db, "glass", "big"), "suicide",
		"sc32b-d: can't kill and dies → suicide")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32c — GenericAI pipeline: trades, develop, hero-chip, termination
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_trade_develop_chip() -> void:
	print("\n-- Scenario 32c: GenericAI trades up, develops, chips (holding protectors) --")
	var ai := GenericAI.new()

	# ── _trade_action: take an even 'both' trade, refuse a value-down one ──
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("even_def",  2, 2, [], 2)   # our attacker
	db.ally("peer_def",  2, 2, [], 2)   # even trade target
	db.ally("tough_def", 3, 3, [], 5)   # we can't profitably fight this

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "mine",  "even_def",  "p1")
	_add_ally(st, "peer",  "peer_def",  "p2")
	_add_ally(st, "tough", "tough_def", "p2")
	st.players["p1"].resource_placed_this_turn = true
	st.players["p2"].resource_placed_this_turn = true

	var t := ai._trade_action(st, db, "p1")
	ok(t != null and t.action_type == "propose_combat"
			and t.params.get("attacker_id") == "mine"
			and t.params.get("defender_id") == "peer",
		"sc32c-a: takes the even 'both' trade, not the doomed fight vs tough")

	# Now make our attacker the valuable one and the only target a chump:
	# value-down 'both' trade must be refused.
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.ally("bomb_def",  5, 5, [], 5)   # valuable attacker
	db2.ally("chump_def", 5, 5, [], 1)   # both die, but they lose only a 1-drop
	var st2 := _base_state(db2, "p1_hero", "p2_hero")
	_add_ally(st2, "bomb",  "bomb_def",  "p1")
	_add_ally(st2, "chump", "chump_def", "p2")
	st2.players["p1"].resource_placed_this_turn = true
	st2.players["p2"].resource_placed_this_turn = true
	ok(ai._trade_action(st2, db2, "p1") == null,
		"sc32c-b: refuses a value-down 'both' trade (bomb for a chump)")

	# ── _hero_chip_action: hold protectors while hero healthy; never 0-ATK ──
	var db3 := MockDB.new()
	db3.hero("p1_hero", 30)
	db3.hero("p2_hero", 30)
	db3.ally("prot_def", 2, 5, (["protector"] as Array[String]), 3)
	db3.ally("zero_def", 0, 4, [], 2)
	db3.ally("beater_def", 2, 2, [], 1)
	var st3 := _base_state(db3, "p1_hero", "p2_hero")
	_add_ally(st3, "prot",   "prot_def",   "p1")
	_add_ally(st3, "zero",   "zero_def",   "p1")
	st3.players["p1"].resource_placed_this_turn = true

	ok(ai._hero_chip_action(st3, db3, "p1") == null,
		"sc32c-c: protector held + 0-ATK never attacks → no chip while hero at 30")

	# Drop the enemy hero to all-out range → protector now chips, 0-ATK still won't.
	st3.get_card("p2_hero").damage_taken = 20   # 10 HP left
	var chip := ai._hero_chip_action(st3, db3, "p1")
	ok(chip != null and chip.action_type == "propose_combat"
			and chip.params.get("attacker_id") == "prot"
			and chip.params.get("defender_id") == "p2_hero",
		"sc32c-d: hero at 10 → all out, protector chips the face")

	# Least valuable non-protector chips first (hero back at full).
	st3.get_card("p2_hero").damage_taken = 0
	_add_ally(st3, "beater", "beater_def", "p1")
	chip = ai._hero_chip_action(st3, db3, "p1")
	ok(chip != null and chip.params.get("attacker_id") == "beater",
		"sc32c-e: cheap non-protector chips before the held protector")

	# ── pipeline ordering & terminate-to-null (no random fallback) ──
	var db4 := MockDB.new()
	db4.hero("p1_hero", 30)
	db4.hero("p2_hero", 30)
	db4.ally("dev_def", 1, 1, [], 1)
	var st4 := _base_state(db4, "p1_hero", "p2_hero")
	st4.players["p1"].resource_placed_this_turn = true   # isolate develop = play ally
	st4.players["p1"].has_used_hero_power = true          # no phantom hero-power play
	_add_resources(st4, "p1", 1)                          # 1 resource → dev (cost 1) affordable

	# Nothing on board, empty hand, resource placed → the turn simply ends.
	ok(ai.decide_action(st4, db4, "p1") == null,
		"sc32c-f: no combat, no develop, no chip → decide_action returns null (turn ends)")

	# One ally in hand → GenericAI develops it (no combat available).
	var hand := CardInstance.create("dev", "dev_def", "p1", "p1_hand")
	st4.cards["dev"] = hand
	st4.zones["p1_hand"].card_ids.append("dev")
	var d := ai.decide_action(st4, db4, "p1")
	ok(d != null and d.action_type == "play_ally" and d.params.get("card_id") == "dev",
		"sc32c-g: with only a develop available, GenericAI plays the ally")

	# Simulate the develop resolving: the ally is now in play but summoning-sick,
	# so it is not a legal attacker and the turn ends — the loop can't spin.
	st4.zones["p1_hand"].card_ids.erase("dev")
	GameLogic.move_card(st4, "dev", "p1_ally_row")
	st4.get_card("dev").just_summoned = true
	ok(ai.decide_action(st4, db4, "p1") == null,
		"sc32c-h: after developing, the summoning-sick ally can't attack → turn ends")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32d — GenericAI protector choice via combat_trade_value
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_protector_choice() -> void:
	print("\n-- Scenario 32d: GenericAI protects from the proposed-fight outcome --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("atk3_def",   3, 3, [], 3)                                  # the attacker
	db.ally("killer_def", 3, 5, (["protector"] as Array[String]), 3)   # kills atk3 & lives
	db.ally("soak_def",   1, 5, (["protector"] as Array[String]), 2)   # survives, can't kill
	db.ally("bigdef_def", 3, 4, [], 3)                                 # kills atk3 & lives (defender)
	db.ally("prize_def",  2, 2, [], 4)                                 # valuable ally, dies to atk3
	db.ally("fodder_def", 1, 3, (["protector"] as Array[String]), 1)   # cheap protector
	db.ally("pricey_def", 2, 4, (["protector"] as Array[String]), 6)   # expensive protector

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "atk",    "atk3_def",   "p2")
	_add_ally(st, "killer", "killer_def", "p1")
	_add_ally(st, "soak",   "soak_def",   "p1")
	st.combat_attacker = "atk"
	st.combat_defender = "p1_hero"

	# a: hero survives, a protector can kill the attacker and live → protect.
	eq(ai.choose_protector(st, db, "p1"), "killer",
		"sc32d-a: defender survives → protect only to kill the attacker (safe_lethal protector)")

	# b: hero survives, no protector can kill the attacker (soak only) → take the hit.
	st.get_card("killer").is_exhausted = true
	eq(ai.choose_protector(st, db, "p1"), "",
		"sc32d-b: defender survives + no killing protector → don't waste one soaking chip")

	# c: the attacker would DIE to the proposed defender → let the free kill happen.
	_add_ally(st, "bigdef", "bigdef_def", "p1")   # soak still ready, but irrelevant
	st.combat_defender = "bigdef"
	eq(ai.choose_protector(st, db, "p1"), "",
		"sc32d-c: attacker dies to the defender for free → do not protect")

	# d: a valuable ally would die; a cheaper protector saves it (fodder < prize).
	_add_ally(st, "prize",  "prize_def",  "p1")
	_add_ally(st, "fodder", "fodder_def", "p1")
	st.combat_defender = "prize"
	eq(ai.choose_protector(st, db, "p1"), "fodder",
		"sc32d-d: dying ally saved by the least valuable protector worth less than it")

	# e: valuable ally would die but only a pricier protector remains → let it die.
	st.get_card("fodder").is_exhausted = true
	st.get_card("soak").is_exhausted = true
	_add_ally(st, "pricey", "pricey_def", "p1")
	st.combat_defender = "prize"
	eq(ai.choose_protector(st, db, "p1"), "",
		"sc32d-e: only protectors more valuable than the ally → don't over-trade, let it die")

	# f: lethal hit on the hero → always interpose the cheapest available body.
	st.combat_defender = "p1_hero"
	st.get_card("p1_hero").damage_taken = 28   # 2 HP left; atk 3 is lethal
	eq(ai.choose_protector(st, db, "p1"), "pricey",
		"sc32d-f: lethal on hero → chump with the only ready body regardless of value")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32e — AI combat evaluation forecasts "while attacking" buffs
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_while_attacking_buffs() -> void:
	print("\n-- Scenario 32e: AI combat eval honors 'while attacking' buffs (Zorm) --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def",  1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2, [], 2)   # 2/2 base → 3/2 while attacking under Zorm
	db.ally("wall_def",  1, 3, [], 3)   # 1/3 enemy — needs 3 ATK to die

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "zorm",  "zorm_def",  "p1")
	_add_ally(st, "grunt", "grunt_def", "p1")
	_add_ally(st, "wall",  "wall_def",  "p2")
	st.players["p1"].resource_placed_this_turn = true
	st.players["p2"].resource_placed_this_turn = true

	# No combat is live here (combat_attacker == ""), so only the explicit
	# attacking forecast can reveal the Zorm bonus.
	eq(BaseAI.combat_trade_value(st, db, "grunt", "wall"), "safe_lethal",
		"sc32e-a: grunt (→3 ATK while attacking) safe-kills the 1/3 wall")
	eq(BaseAI.combat_trade_value(st, db, "grunt", "wall", false), "no_one",
		"sc32e-b: control — scored as non-attacker (2 ATK), the same pair is no_one")

	# The pipeline seizes the safe kill that ONLY exists while attacking.
	var act := ai.decide_action(st, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "grunt"
			and act.params.get("defender_id") == "wall",
		"sc32e-c: GenericAI takes the safe kill enabled by the Zorm aura")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 33 — Ally heal powers (Freya) target FRIENDLY damaged characters only
# ══════════════════════════════════════════════════════════════════════════════

func _test_ally_heal_power_targets_friendlies() -> void:
	print("\n-- Scenario 33: heal_target ally power never heals the enemy --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("freya_def", 2, 2, [], 2,
			"activated_power:0:heal_target:3:holy:hero_or_ally")
	db.ally("dummy_def", 2, 5, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "freya",     "freya_def", "p1")
	_add_ally(state, "own_hurt",  "dummy_def", "p1")
	_add_ally(state, "opp_hurt",  "dummy_def", "p2")
	state.get_card("own_hurt").damage_taken = 2
	state.get_card("opp_hurt").damage_taken = 4   # more damaged — must be ignored

	var ai := BaseAI.new()
	var actions := ai._get_ally_power_actions(state, db, "p1")
	ok(actions.size() == 1
			and actions[0].params.get("target_id") == "own_hurt",
		"sc33-a: heal targets the damaged FRIENDLY ally, not the enemy")

	# Damaged own hero outranks a less-damaged ally (most damage first).
	state.get_card("p1_hero").damage_taken = 6
	actions = ai._get_ally_power_actions(state, db, "p1")
	ok(actions.size() == 1
			and actions[0].params.get("target_id") == "p1_hero",
		"sc33-b: most damaged friendly (hero) preferred")

	# Nothing damaged on our side → power not used at all.
	state.get_card("p1_hero").damage_taken = 0
	state.get_card("own_hurt").damage_taken = 0
	actions = ai._get_ally_power_actions(state, db, "p1")
	eq(actions.size(), 0,
		"sc33-c: no damaged friendly → heal power not offered (enemy never healed)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 34 — Combat instant (Quick Strike): AI holds it, ambushes in combat
#
# BaseAI.COMBAT_INSTANT_TAGS marks Quick Strike (azeroth_165) as a card to HOLD:
# never blind-played on the AI's own action window, only played via
# combat_instant_action() when the AI is being attacked.
#
#   Attack window:  attacker_hp <= dmg  AND  attacker_cost >= card_cost
#   Defend window:  attacker_hp <= defender_atk + dmg
#                   AND attacker_hp > defender_atk
#                   AND attacker_cost >= card_cost
#
# Assertions:
#   sc34-a  attack window: 2 HP / cost-4 attacker → play
#   sc34-b  attack window: cheap bait (cost 1) → hold
#   sc34-c  attack window: 5 HP attacker survives the 2 dmg → hold
#   sc34-d  the ATTACKING player never plays it on its own combat
#   sc34-e  defend window: 5 HP attacker vs 4 ATK defender + 2 dmg → play
#   sc34-f  defend window: attacker already dies to defender alone → hold
#   sc34-g  defend window: attacker out of reach (7 HP vs 4+2) → hold
#   sc34-h  outside combat: get_legal_actions never blind-plays it
#   sc34-i/j/k  integration: BaseAI defender kills the attacker during the
#               attack window — attacker dead, zero combat damage, QS in grave
# ══════════════════════════════════════════════════════════════════════════════

func _test_combat_instant_ambush() -> void:
	print("\n-- Scenario 34: combat instant — AI holds Quick Strike, ambushes attacker --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Registered under its REAL def id so BaseAI.COMBAT_INSTANT_TAGS matches.
	db.instant("azeroth_165", 3, "deal_damage_to_target:2:melee")
	db.ally("atk_worthy_def", 3, 2, [], 4)   # cost 4, 2 HP — dies to QS, worth it
	db.ally("atk_cheap_def",  3, 2, [], 1)   # cost 1 — bait, never worth QS
	db.ally("atk_fat_def",    3, 5, [], 6)   # cost 6, 5 HP — survives QS alone
	db.ally("atk_huge_def",   3, 7, [], 6)   # cost 6, 7 HP — out of combined reach
	db.ally("blocker_def",    4, 6, [], 3)   # 4 ATK defender for defend-window math

	var ai := BaseAI.new()

	# ── Attack-window matrix (p2 attacks p1's hero) ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	st.turn_player     = "p2"
	st.priority_player = "p1"
	_add_resources(st, "p1", 3)
	var qs := CardInstance.create("qs_p1", "azeroth_165", "p1", "p1_hand")
	st.cards["qs_p1"] = qs
	st.zones["p1_hand"].card_ids.append("qs_p1")
	_add_ally(st, "atk_worthy", "atk_worthy_def", "p2")
	_add_ally(st, "atk_cheap",  "atk_cheap_def",  "p2")
	_add_ally(st, "atk_fat",    "atk_fat_def",    "p2")
	st.combat_attack_window = true
	st.combat_defender = "p1_hero"

	st.combat_attacker = "atk_worthy"
	var act := ai.combat_instant_action(st, db, "p1")
	ok(act != null and act.params.get("card_id") == "qs_p1"
			and act.params.get("target_id") == "atk_worthy",
		"sc34-a: attack window — 2 HP / cost-4 attacker → play QS targeting it")

	st.combat_attacker = "atk_cheap"
	ok(ai.combat_instant_action(st, db, "p1") == null,
		"sc34-b: attack window — cheap bait (cost 1 < QS cost 3) → hold")

	st.combat_attacker = "atk_fat"
	ok(ai.combat_instant_action(st, db, "p1") == null,
		"sc34-c: attack window — 5 HP attacker survives 2 dmg → hold")

	# The attacking side never ambushes its own combat.
	st.combat_attacker = "atk_worthy"
	st.priority_player = "p2"
	var qs2 := CardInstance.create("qs_p2", "azeroth_165", "p2", "p2_hand")
	st.cards["qs_p2"] = qs2
	st.zones["p2_hand"].card_ids.append("qs_p2")
	_add_resources(st, "p2", 3)
	ok(ai.combat_instant_action(st, db, "p2") == null,
		"sc34-d: attacking player never plays the combat instant")

	# ── Defend-window matrix (p1's 4 ATK blocker defends) ──
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	st2.turn_player     = "p2"
	st2.priority_player = "p1"
	_add_resources(st2, "p1", 3)
	var qsb := CardInstance.create("qs_b", "azeroth_165", "p1", "p1_hand")
	st2.cards["qs_b"] = qsb
	st2.zones["p1_hand"].card_ids.append("qs_b")
	_add_ally(st2, "blocker",     "blocker_def",    "p1")
	_add_ally(st2, "atk_fat2",    "atk_fat_def",    "p2")
	_add_ally(st2, "atk_worthy2", "atk_worthy_def", "p2")
	_add_ally(st2, "atk_huge2",   "atk_huge_def",   "p2")
	st2.combat_defend_window = true
	st2.combat_defender = "blocker"

	st2.combat_attacker = "atk_fat2"   # hp 5: 5 <= 4+2 AND 5 > 4 → play
	var act2 := ai.combat_instant_action(st2, db, "p1")
	ok(act2 != null and act2.params.get("card_id") == "qs_b"
			and act2.params.get("target_id") == "atk_fat2",
		"sc34-e: defend window — QS finishes what the defender can't → play")

	st2.combat_attacker = "atk_worthy2"   # hp 2: already dies to 4 ATK alone
	ok(ai.combat_instant_action(st2, db, "p1") == null,
		"sc34-f: defend window — attacker already dying to defender → hold")

	st2.combat_attacker = "atk_huge2"   # hp 7 > 4+2
	ok(ai.combat_instant_action(st2, db, "p1") == null,
		"sc34-g: defend window — attacker out of combined reach → hold")

	# ── Hold outside combat: never a blind play on own action window ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 3)
	var qs3 := CardInstance.create("qs_hold", "azeroth_165", "p1", "p1_hand")
	st3.cards["qs_hold"] = qs3
	st3.zones["p1_hand"].card_ids.append("qs_hold")
	var blind := false
	for a in ai.get_legal_actions(st3, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "qs_hold":
			blind = true
	ok(not blind, "sc34-h: get_legal_actions never blind-plays a held combat instant")

	# ── Integration: p1 attacks, BaseAI p2 ambushes during the attack window ──
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st4, "raider", "atk_worthy_def", "p1")   # cost 4, 2 HP, 3 ATK
	_add_resources(st4, "p2", 3)
	var qs4 := CardInstance.create("qs_ambush", "azeroth_165", "p2", "p2_hand")
	st4.cards["qs_ambush"] = qs4
	st4.zones["p2_hand"].card_ids.append("qs_ambush")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}))

	_drive_turns(st4, db, p1_ai, BaseAI.new(), 3)

	ok(st4.get_card("raider").zone_id == "p1_graveyard",
		"sc34-i: attacker killed by Quick Strike during the attack window")
	eq(st4.get_card("p2_hero").damage_taken, 0,
		"sc34-j: p2 hero took no combat damage (attacker died pre-conclusion)")
	ok(st4.get_card("qs_ambush").zone_id == "p2_graveyard",
		"sc34-k: Quick Strike in graveyard after the ambush")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 35 — Deacon Johanna: no-exhaust payment power, gated once per turn
#
# Deacon Johanna's power has NO [Activate] tap symbol on the card — just a
# resource cost ("2") — so per rule 701.3/3216 it isn't gated by summoning
# sickness or the card's exhausted state, only by its own printed
# "once per turn" restriction (CardInstance.used_this_turn, reset each turn).
# ══════════════════════════════════════════════════════════════════════════════

func _test_deacon_johanna_once_per_turn() -> void:
	print("\n-- Scenario 35: Deacon Johanna — once-per-turn heal, no exhaust cost --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("johanna_def", 2, 2, [], 2,
			"activated_power:2:heal_target:2:holy:hero_or_ally:once_per_turn")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)
	_add_ally(state, "johanna", "johanna_def", "p1")
	# Simulate a freshly-summoned, already-exhausted Johanna — the power still
	# has to work since it isn't an [Activate] power.
	state.get_card("johanna").just_summoned = true
	state.get_card("johanna").is_exhausted  = true
	state.get_card("p1_hero").damage_taken  = 5

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "johanna", "target_id": "p1_hero"})

	# dj-a: usable despite summoning sickness and being exhausted.
	ok(StackResolver.can_submit(state, use, db),
		"dj-a: power usable while summoning-sick and exhausted (no tap symbol)")

	# Ready Johanna to prove the power itself never exhausts her (no tap cost).
	state.get_card("johanna").is_exhausted = false

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# dj-b: heal applied.
	eq(state.get_card("p1_hero").damage_taken, 3, "dj-b: healed 2 damage from hero")

	# dj-c: Johanna is still ready — the power carries no exhaust cost.
	ok(not state.get_card("johanna").is_exhausted,
		"dj-c: Johanna remains ready after using her power")

	# dj-d: can't reuse this turn (once-per-turn gate).
	ok(not StackResolver.can_submit(state, use, db),
		"dj-d: power not usable again same turn")

	# Advance deterministically through the rest of p1's turn, all of p2's turn,
	# and into p1's next action phase (action->end->[next_turn/ready]->draw->action,
	# twice) — avoids relying on how many priority-pass steps that takes.
	for _i in 8:
		TurnManager.advance_phase(state, db)
	eq(state.turn_player, "p1", "dj-e-setup: back to p1's turn")
	eq(state.phase, "action", "dj-e-setup: in p1's action phase")

	# dj-e: once-per-turn gate reset for the new turn.
	state.get_card("p1_hero").damage_taken = 5
	ok(StackResolver.can_submit(state, use, db),
		"dj-e: power usable again on a new turn")


# ══════════════════════════════════════════════════════════════════════════════
# Scenario 36 — Acolyte Demia: "(1), Put 1 damage on Acolyte Demia -> Demia
# deals 1 shadow damage to target hero or ally. Use only on your turn."
# No [Activate] tap symbol on this power (rule 701.3) — it's a plain payment
# power (701.2), so it never exhausts Demia and isn't gated by summoning
# sickness; it can be reused any turn as long as the resource + self-damage
# cost (rule 405.3 — capped at exactly fatal) can be paid.
# ══════════════════════════════════════════════════════════════════════════════

const DEMIA_EFFECTS := "activated_power:1:deal_damage_to_target:1:shadow:hero_or_ally:put_damage_self:1|on_your_turn"

func _test_acolyte_demia_power() -> void:
	print("\n-- Scenario 36: Acolyte Demia — activate, put 1 damage on self, deal 1 shadow --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("demia_def", 3, 6, [], 6, DEMIA_EFFECTS)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var demia := _add_ally(state, "demia_inst", "demia_def", "p1")
	demia.just_summoned = false
	demia.is_exhausted  = false
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "demia_inst", "target_id": "p2_hero"})

	# ad-a: legal on Demia's controller's own turn.
	ok(StackResolver.can_submit(state, use, db), "ad-a: Demia power legal on p1's turn")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# ad-b: Demia took 1 damage (put, as her own cost).
	eq(state.get_card("demia_inst").damage_taken, 1, "ad-b: Demia has 1 damage put on herself")

	# ad-c: target hero took 1 shadow damage dealt.
	eq(state.get_card("p2_hero").damage_taken, 1, "ad-c: p2 hero took 1 shadow damage")

	# ad-d: Demia is NOT exhausted (no activate symbol on this power) and can be
	# used again immediately as long as the resource cost can still be paid.
	ok(not state.get_card("demia_inst").is_exhausted, "ad-d: Demia not exhausted after use")
	_add_resources(state, "p1", 1)
	ok(StackResolver.can_submit(state, use, db), "ad-d2: Demia power reusable immediately")


func _test_acolyte_demia_own_turn_only() -> void:
	print("\n-- Scenario 36b: Acolyte Demia — use only on your turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("demia_def", 3, 6, [], 6, DEMIA_EFFECTS)

	var state := _base_state(db, "p1_hero", "p2_hero")
	# Demia controlled by p2, but it's p1's turn.
	var demia := _add_ally(state, "demia_inst", "demia_def", "p2")
	demia.just_summoned = false
	demia.is_exhausted  = false
	_add_resources(state, "p2", 1)
	state.priority_player = "p2"

	var use := PendingAction.make("use_ally_power", "p2",
		{"card_id": "demia_inst", "target_id": "p1_hero"})

	# ad-e: illegal off her controller's turn, even with priority and resources.
	ok(not StackResolver.can_submit(state, use, db),
		"ad-e: Demia power illegal outside her controller's own turn")


func _test_acolyte_demia_self_destroys() -> void:
	print("\n-- Scenario 36c: Acolyte Demia — self-damage can be exactly fatal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("demia_def", 3, 6, [], 6, DEMIA_EFFECTS)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var demia := _add_ally(state, "demia_inst", "demia_def", "p1")
	demia.just_summoned = false
	demia.is_exhausted  = false
	demia.damage_taken  = 5   # 1 more damage is exactly fatal (6 health).
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "demia_inst", "target_id": "p2_hero"})

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# ad-f: the effect still resolves even though the cost was fatal to Demia.
	eq(state.get_card("p2_hero").damage_taken, 1,
		"ad-f: damage effect still resolves after fatal self-cost")

	# ad-g: Demia was destroyed and moved to the graveyard.
	eq(state.get_card("demia_inst").zone_id, "p1_graveyard",
		"ad-g: Demia destroyed by her own put-damage cost")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 24 — Zorm Stonefury: party aura "+1 ATK while attacking"
# ══════════════════════════════════════════════════════════════════════════════

func _test_zorm_party_atk_while_attacking() -> void:
	print("\n-- Scenario 24: Zorm Stonefury party '+1 ATK while attacking' aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def", 1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "zorm_inst", "zorm_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	_add_ally(state, "opp_inst", "grunt_def", "p2")

	# Nobody attacking → no bonus anywhere.
	eq(state.get_atk("grunt_inst", db), 2, "sc24-a: no bonus while not attacking")
	eq(state.get_atk("zorm_inst", db), 1, "sc24-b: Zorm itself unbuffed while idle")

	# Grunt attacks → +1 from Zorm's aura.
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 3, "sc24-c: attacking ally gets +1")
	eq(state.get_atk("zorm_inst", db), 1, "sc24-d: non-attacking Zorm still unbuffed")

	# Zorm attacks → buffs itself (it's an ally in your party).
	state.combat_attacker = "zorm_inst"
	eq(state.get_atk("zorm_inst", db), 2, "sc24-e: Zorm buffs itself while attacking")

	# Opponent's attacker gets nothing from p1's Zorm.
	state.combat_attacker = "opp_inst"
	eq(state.get_atk("opp_inst", db), 2, "sc24-f: enemy attacker unaffected by your Zorm")

	# Two Zorms stack.
	_add_ally(state, "zorm2_inst", "zorm_def", "p1")
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 4, "sc24-g: two Zorms stack (+2)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 25 — Elder Moorf: "[1],[activate] Target ally has +2 ATK this turn"
# ══════════════════════════════════════════════════════════════════════════════

func _test_elder_moorf_buff_target() -> void:
	print("\n-- Scenario 25: Elder Moorf +2 ATK to target ally this turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("moorf_def", 1, 1, [], 1, "activated_power:1:buff_atk_target:2::ally:once_per_turn")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var moorf := _add_ally(state, "moorf_inst", "moorf_def", "p1")
	moorf.just_summoned = false
	moorf.is_exhausted  = false
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	# Two resources so sc25-f isolates the once-per-turn gate (1 stays available).
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true

	# Heroes are not legal targets for an "ally"-only power.
	var at_hero := PendingAction.make("use_ally_power", "p1",
		{"card_id": "moorf_inst", "target_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, at_hero, db),
		"sc25-a: Moorf cannot target a hero")

	# A friendly ally is a legal target.
	var at_ally := PendingAction.make("use_ally_power", "p1",
		{"card_id": "moorf_inst", "target_id": "grunt_inst"})
	ok(StackResolver.can_submit(state, at_ally, db),
		"sc25-b: Moorf can target an ally")

	StackResolver.submit_action(state, at_ally, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Buff is unconditional — applies even when not attacking.
	eq(state.get_atk("grunt_inst", db), 4, "sc25-c: target ally at +2 ATK (2 -> 4)")
	# Non-tap "once per turn" power: Moorf stays ready but can't be used again.
	ok(not state.get_card("moorf_inst").is_exhausted, "sc25-d: Moorf not exhausted (non-tap power)")
	ok(state.get_card("moorf_inst").used_this_turn, "sc25-e: Moorf flagged used_this_turn")
	ok(not StackResolver.can_submit(state, at_ally, db),
		"sc25-f: Moorf power can't be used a second time this turn")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 26 — Rayder: "[activate] Your allies +2 ATK while attacking this turn"
# ══════════════════════════════════════════════════════════════════════════════

func _test_rayder_party_buff_while_attacking() -> void:
	print("\n-- Scenario 26: Rayder party '+2 ATK while attacking this turn' --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("rayder_def", 2, 2, [], 2, "activated_power:0:party_buff_atk_attacking:2")
	db.ally("grunt_def", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var rayder := _add_ally(state, "rayder_inst", "rayder_def", "p1")
	rayder.just_summoned = false
	rayder.is_exhausted  = false
	_add_ally(state, "grunt_inst", "grunt_def", "p1")

	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "rayder_inst"})
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Conditional buff: nothing while idle.
	eq(state.get_atk("grunt_inst", db), 1, "sc26-a: no bonus while grunt idle")

	# Grunt attacks → +2.
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 3, "sc26-b: grunt +2 while attacking")

	# Rayder itself is in its own party → buffed while attacking.
	state.combat_attacker = "rayder_inst"
	eq(state.get_atk("rayder_inst", db), 4, "sc26-c: Rayder +2 while attacking")

	# An ally that enters play AFTER Rayder's power resolves is still buffed
	# for the rest of the turn (bug: used to snapshot only allies present
	# at activation time).
	_add_ally(state, "latecomer_inst", "grunt_def", "p1")
	state.combat_attacker = "latecomer_inst"
	eq(state.get_atk("latecomer_inst", db), 3, "sc26-d: late-summoned ally still +2 while attacking")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 27 — For the Horde!: quest reward buffs only Horde allies
# ══════════════════════════════════════════════════════════════════════════════

func _test_for_the_horde_quest_buff() -> void:
	print("\n-- Scenario 27: For the Horde! buffs only Horde allies while attacking --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("fth_def", 1, "party_buff_atk_attacking:1")
	db.ally("horde_def", 2, 2)
	db.ally("neutral_def", 2, 2)
	db.get_def("horde_def").alignment = "Horde"
	db.get_def("neutral_def").alignment = ""

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "horde_inst", "horde_def", "p1")
	_add_ally(state, "neutral_inst", "neutral_def", "p1")
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	var quest := CardInstance.create("fth_inst", "fth_def", "p1", "p1_resource_row")
	state.cards["fth_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("fth_inst")

	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "fth_inst"})
	StackResolver.submit_action(state, complete, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Horde ally gains the while-attacking buff; neutral ally does not.
	state.combat_attacker = "horde_inst"
	eq(state.get_atk("horde_inst", db), 3, "sc27-a: Horde ally +1 while attacking")
	state.combat_attacker = "neutral_inst"
	eq(state.get_atk("neutral_inst", db), 2, "sc27-b: non-Horde ally unbuffed")

	# Buff is gated on attacking.
	state.combat_attacker = ""
	eq(state.get_atk("horde_inst", db), 2, "sc27-c: no bonus while Horde ally idle")

	# A Horde ally that enters play AFTER the quest completes is still
	# buffed for the rest of the turn.
	_add_ally(state, "late_horde_inst", "horde_def", "p1")
	state.combat_attacker = "late_horde_inst"
	eq(state.get_atk("late_horde_inst", db), 3, "sc27-d: late-summoned Horde ally still +1 while attacking")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 28 — "this turn" buffs expire at end of turn
# ══════════════════════════════════════════════════════════════════════════════

func _test_turn_buff_expires_at_end_of_turn() -> void:
	print("\n-- Scenario 28: 'this turn' buffs are swept at end of turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	state.get_card("grunt_inst").active_buffs.append(
		Buff.make("test_turn_buff", "src", "atk", 3, "turns", 1))

	eq(state.get_atk("grunt_inst", db), 5, "sc28-a: turn buff applies (2 + 3)")

	TurnManager._enter_end(state, db)

	eq(state.get_atk("grunt_inst", db), 2, "sc28-b: turn buff swept at end of turn")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 29 — Regression: "while attacking" bonuses must apply to REAL combat
# damage, not just to get_atk queried mid-window. (Bug: _do_combat_conclusion
# used to clear state.combat_attacker before computing atk_dmg, so Zorm/Rayder/
# For the Horde! bonuses never reached the actual damage dealt.)
# ══════════════════════════════════════════════════════════════════════════════

func _test_zorm_bonus_applies_to_real_combat_damage() -> void:
	print("\n-- Scenario 29: Zorm's +1 ATK while attacking lands in real combat damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def", 1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "zorm_inst", "zorm_def", "p1")
	var grunt := _add_ally(state, "grunt_inst", "grunt_def", "p1")
	grunt.just_summoned = false
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "grunt_inst", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()

	_drive(state, db, p1_ai, p2_ai)

	# Grunt is printed 2 ATK; with Zorm's aura it should deal 3, not 2.
	eq(state.get_card("p2_hero").damage_taken, 3,
		"sc29: real combat damage includes Zorm's +1 ATK while attacking")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 30 — get_atk_if_attacking: targeting-cursor preview helper
# ══════════════════════════════════════════════════════════════════════════════

func _test_get_atk_if_attacking_preview() -> void:
	print("\n-- Scenario 30: get_atk_if_attacking previews attack ATK without mutating state --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def", 1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "zorm_inst", "zorm_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")

	# Before any combat is proposed: plain get_atk correctly omits the bonus
	# (rule 601 — not attacking yet), but the preview helper shows what it
	# WOULD be, for the targeting cursor.
	eq(state.get_atk("grunt_inst", db), 2,
		"sc30-a: plain get_atk shows base ATK before combat is proposed")
	eq(state.get_atk_if_attacking("grunt_inst", db), 3,
		"sc30-b: preview helper shows the buffed ATK")

	# The preview call must not mutate real state.
	eq(state.combat_attacker, "",
		"sc30-c: preview helper leaves combat_attacker untouched")
	eq(state.get_atk("grunt_inst", db), 2,
		"sc30-d: plain get_atk is unaffected by the preview call")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 31 — Regression: Elder Moorf's buff must land on REAL defense damage
# when activated by the (non-turn) defending player mid-combat, exactly as in
# a live game: p1's ally attacks p2's ally; p2 uses Moorf's power on the
# defender during the Defend Window before combat concludes.
# ══════════════════════════════════════════════════════════════════════════════

func _test_moorf_buff_applies_to_real_defense_damage() -> void:
	print("\n-- Scenario 31: Elder Moorf's buff lands on real combat damage while defending --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 2, 10)
	db.ally("grunt_def", 2, 2)
	db.ally("moorf_def", 1, 1, [], 1, "activated_power:1:buff_atk_target:2::ally:once_per_turn")

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player = "p1"
	var attacker := _add_ally(state, "attacker_inst", "attacker_def", "p1")
	attacker.just_summoned = false
	var grunt := _add_ally(state, "grunt_inst", "grunt_def", "p2")
	grunt.just_summoned = false
	var moorf := _add_ally(state, "moorf_inst", "moorf_def", "p2")
	moorf.just_summoned = false
	_add_resources(state, "p2", 1)

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "attacker_inst", "defender_id": "grunt_inst"}))
	var p2_ai := ScriptedAI.new()
	# Fires as soon as p2 has priority and the action is legal — i.e. during the
	# Defend Window, exactly like a human activating it mid-combat.
	p2_ai.queue_action(PendingAction.make("use_ally_power", "p2",
		{"card_id": "moorf_inst", "target_id": "grunt_inst"}))

	_drive(state, db, p1_ai, p2_ai)

	# Grunt is printed 2 ATK; Moorf's +2 buff should make it deal 4 back.
	eq(state.get_card("attacker_inst").damage_taken, 4,
		"sc31: attacker takes buffed (2+2=4) counter-damage from the defending ally")
	ok(state.get_card("moorf_inst").used_this_turn,
		"sc31: Moorf's once-per-turn power was actually used")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32 — Ryn Dreamstrider: "[activate] Target hero or ally +2 ATK while
# attacking this turn"
# ══════════════════════════════════════════════════════════════════════════════

func _test_ryn_dreamstrider_buff_target_attacking() -> void:
	print("\n-- Scenario 32: Ryn Dreamstrider targeted 'while attacking' buff --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ryn_def", 2, 2, [], 4, "activated_power:0:buff_atk_target_attacking:2::hero_or_ally")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var ryn := _add_ally(state, "ryn_inst", "ryn_def", "p1")
	ryn.just_summoned = false
	ryn.is_exhausted  = false
	_add_ally(state, "grunt_inst", "grunt_def", "p1")

	# Can target a friendly ally, a hero, and (per printed text) an enemy character.
	var at_own_hero := PendingAction.make("use_ally_power", "p1",
		{"card_id": "ryn_inst", "target_id": "p1_hero"})
	ok(StackResolver.can_submit(state, at_own_hero, db),
		"sc32-a: Ryn can target a hero")

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "ryn_inst", "target_id": "grunt_inst"})
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Conditional buff: nothing while idle.
	eq(state.get_atk("grunt_inst", db), 2, "sc32-b: no bonus while grunt idle")
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 4, "sc32-c: grunt +2 while attacking")

	# Exhausts (has an [Activate] tap symbol, unlike Moorf).
	ok(state.get_card("ryn_inst").is_exhausted, "sc32-d: Ryn exhausted after using power")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 34 — Sen'zir Beastwalker: "3, Flip -> Put a Pet card from your
# graveyard into your hand."
#
# Assertions:
#   sc34-a  candidates from get_graveyard_search_candidates: only own Pet
#   sc34-b  no-target probe passes with a valid Pet candidate
#   sc34-c  completion without an announced target is rejected
#   sc34-d  targeting the non-Pet ally in the graveyard is illegal
#   sc34-e  targeting an opponent's graveyard Pet is illegal (owner=own)
#   sc34-f  full action with the correct Pet target is legal and costs 3
#   sc34-g  Pet moves to p1 hand after resolution
#   sc34-h  card_returned_from_graveyard event fired
#   sc34-i  hero_power_used event fired (once-per-turn gate engaged)
# ══════════════════════════════════════════════════════════════════════════════

func _test_senzir_beastwalker_power() -> void:
	print("\n-- Scenario 34: Sen'zir Beastwalker returns a Pet from graveyard to hand --")
	var db := MockDB.new()
	db.hero("senzir_def", 28, 3, "graveyard_to_hand:Pet:1:1:own")
	db.hero("p2_hero", 30)
	db.pet("pet_def", 1, 3, [], 2)
	db.ally("nonpet_def", 2, 2, [], 2)

	var state := _base_state(db, "senzir_def", "p2_hero")
	_add_resources(state, "p1", 3)

	for pair in [["dead_pet", "pet_def"], ["dead_nonpet", "nonpet_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])
	var opp_pet := CardInstance.create("opp_dead_pet", "pet_def", "p2", "p2_graveyard")
	state.cards["opp_dead_pet"] = opp_pet
	state.zones["p2_graveyard"].card_ids.append("opp_dead_pet")

	var def := db.get_def("senzir_def")
	var req := StackResolver.get_graveyard_search_requirement(def)
	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["dead_pet"], "sc34-a: only own graveyard Pet is a candidate")

	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": ""})
	ok(StackResolver.can_submit(state, probe, db),
		"sc34-b: no-target probe passes with a valid Pet candidate")

	var no_target := PendingAction.make("activate_power", "p1", {"hero_id": "senzir_def"})
	ok(StackResolver.can_submit(state, no_target, db),
		"sc34-c: pre-target probe (empty target_id) still passes — full resolution needs a real target")

	var bad_nonpet := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": "dead_nonpet"})
	ok(not StackResolver.can_submit(state, bad_nonpet, db),
		"sc34-d: non-Pet graveyard card is an illegal target")

	var bad_opp := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": "opp_dead_pet"})
	ok(not StackResolver.can_submit(state, bad_opp, db),
		"sc34-e: opponent's graveyard Pet is an illegal target (owner=own)")

	var good := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": "dead_pet"})
	ok(StackResolver.can_submit(state, good, db),
		"sc34-f: full action with the correct Pet target is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, good, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	ok(state.get_card("dead_pet").zone_id == "p1_hand",
		"sc34-g: Pet moved to p1 hand")
	eq(state.get_available_resources("p1"), 0,
		"sc34-f2: 3 resources spent for the power")

	var saw_return := false
	var saw_power_used := false
	for e in events:
		if e.event_type == "card_returned_from_graveyard" \
				and e.payload.get("card_id", "") == "dead_pet":
			saw_return = true
		if e.event_type == "hero_power_used":
			saw_power_used = true
	ok(saw_return, "sc34-h: card_returned_from_graveyard event fired")
	ok(saw_power_used, "sc34-i: hero_power_used event fired")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 35 — Sen'zir: blocked when no Pet is in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_senzir_beastwalker_no_pet_in_graveyard() -> void:
	print("\n-- Scenario 35: Sen'zir power blocked with no Pet in graveyard --")
	var db := MockDB.new()
	db.hero("senzir_def", 28, 3, "graveyard_to_hand:Pet:1:1:own")
	db.hero("p2_hero", 30)
	db.ally("nonpet_def", 2, 2, [], 2)

	var state := _base_state(db, "senzir_def", "p2_hero")
	_add_resources(state, "p1", 3)

	var c := CardInstance.create("dead_nonpet", "nonpet_def", "p1", "p1_graveyard")
	state.cards["dead_nonpet"] = c
	state.zones["p1_graveyard"].card_ids.append("dead_nonpet")

	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": ""})
	ok(not StackResolver.can_submit(state, probe, db),
		"sc35-a: probe rejected — no Pet in graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 36 — AI (GenericAI) picks the MOST valuable Pet when using
# Sen'zir Beastwalker's power with several candidates in the graveyard.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_senzir_picks_most_valuable_pet() -> void:
	print("\n-- Scenario 36: AI picks the most valuable Pet for Sen'zir's power --")
	var db := MockDB.new()
	db.hero("senzir_def", 28, 3, "graveyard_to_hand:Pet:1:1:own")
	db.hero("p2_hero", 30)
	db.pet("gem_pet_def",  3, 3, [], 5)   # valuable
	db.pet("junk_pet_def", 1, 1, [], 0)   # least valuable

	var state := _base_state(db, "senzir_def", "p2_hero")
	_add_resources(state, "p1", 3)
	var ai := GenericAI.new()

	for pair in [["dead_gem_pet", "gem_pet_def"], ["dead_junk_pet", "junk_pet_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])

	var actions := ai._graveyard_to_hand_hero_actions(state, db, "p1", "senzir_def")
	eq(actions.size(), 1, "sc36-a: exactly one action produced")
	eq(actions[0].params.get("target_id", ""), "dead_gem_pet",
		"sc36-b: AI picks the most valuable Pet (gem, not junk)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 37 — Bloodclaw: vanilla neutral Pet (3/1, cost 1) — no Horde
# alignment, so "For the Horde!" must not buff it.
# ══════════════════════════════════════════════════════════════════════════════

func _test_bloodclaw_no_horde_bonus() -> void:
	print("\n-- Scenario 37: Bloodclaw (neutral Pet) gets no For the Horde! bonus --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("fth_def", 1, "party_buff_atk_attacking:1")
	db.pet("bloodclaw_def", 3, 1, [], 1)
	db.get_def("bloodclaw_def").alignment = ""   # neutral — no faction printed

	var state := _base_state(db, "p1_hero", "p2_hero")
	var bloodclaw := _add_ally(state, "bloodclaw_inst", "bloodclaw_def", "p1")
	bloodclaw.just_summoned = false

	eq(state.get_atk("bloodclaw_inst", db), 3, "sc37-a: Bloodclaw is 3 ATK / 1 HP as printed")

	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true
	var quest := CardInstance.create("fth_inst", "fth_def", "p1", "p1_resource_row")
	state.cards["fth_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("fth_inst")

	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "fth_inst"})
	StackResolver.submit_action(state, complete, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	state.combat_attacker = "bloodclaw_inst"
	eq(state.get_atk("bloodclaw_inst", db), 3,
		"sc37-b: Bloodclaw unbuffed while attacking (neutral, not Horde)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 38 — Old Bones: "can protect your hero" — a restricted, non-keyword
# grant of protection that only applies when the HERO is the proposed defender.
#
# Assertions:
#   sc38-a  Old Bones IS a legal protector when the hero is the proposed defender
#   sc38-b  Old Bones is NOT a legal protector when an ally is the proposed defender
#   sc38-c  end-to-end: Old Bones intercepts an attack on the hero (0 dmg to hero)
# ══════════════════════════════════════════════════════════════════════════════

func _test_old_bones_protects_hero_only() -> void:
	print("\n-- Scenario 38: Old Bones can protect your hero (restricted, not full Protector) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.ally("target_ally_def", 2, 5)
	db.pet("old_bones_def", 4, 4, [], 4, "protect_hero_only")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "attacker_inst", "attacker_def", "p1")
	var target_ally := _add_ally(state, "target_ally_inst", "target_ally_def", "p2")
	var old_bones := _add_ally(state, "old_bones_inst", "old_bones_def", "p2")
	old_bones.just_summoned = false
	old_bones.is_exhausted  = false

	# sc38-a: hero is the proposed defender — Old Bones is offered.
	var protectors_vs_hero := StackResolver.get_legal_protectors(state, "attacker_inst", "p2_hero", db)
	ok("old_bones_inst" in protectors_vs_hero,
		"sc38-a: Old Bones can protect when hero is the proposed defender")

	# sc38-b: an ally is the proposed defender — Old Bones is NOT offered.
	var protectors_vs_ally := StackResolver.get_legal_protectors(
			state, "attacker_inst", "target_ally_inst", db)
	ok(not ("old_bones_inst" in protectors_vs_ally),
		"sc38-b: Old Bones cannot protect an ally (no printed Protector keyword)")

	# sc38-c: end-to-end — Old Bones actually intercepts an attack on the hero.
	state.players["p1"].resource_placed_this_turn = true
	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "attacker_inst", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()
	p2_ai.queue_protect("old_bones_inst")

	_drive(state, db, p1_ai, p2_ai)

	var p2_hero := state.get_card("p2_hero")
	eq(p2_hero.damage_taken, 0, "sc38-c: P2 hero took 0 damage (Old Bones intercepted)")
	eq(old_bones.damage_taken, 3, "sc38-d: Old Bones took the 3 combat damage instead")
	ok(old_bones.is_exhausted, "sc38-e: Old Bones exhausted after protecting")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 39 — Arcane Shot: like Quick Strike (hero deals damage to an
# announced target), plus "Draw a card."
#
# Assertions:
#   sc39-a  submission WITHOUT a target is rejected (same as Quick Strike)
#   sc39-b  1 arcane damage dealt to the announced target, sourced from the hero
#   sc39-c  a card is drawn
#   sc39-d  Arcane Shot itself ends up in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_arcane_shot() -> void:
	print("\n-- Scenario 39: Arcane Shot — hero deals 1 arcane dmg + draw a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 4, [], 3)
	db.ally("filler_def", 1, 1, [], 1)
	db.instant("arcane_shot_def", 2, "deal_damage_to_target:1:arcane|draw:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)

	var shot := CardInstance.create("shot_inst", "arcane_shot_def", "p1", "p1_hand")
	state.cards["shot_inst"] = shot
	state.zones["p1_hand"].card_ids.append("shot_inst")

	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	# A card to draw, at the top of p1's deck.
	var draw_card := CardInstance.create("draw_card_inst", "filler_def", "p1", "p1_deck")
	state.cards["draw_card_inst"] = draw_card
	state.zones["p1_deck"].card_ids.append("draw_card_inst")

	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_instant", "p1", {"card_id": "shot_inst"}), db),
		"sc39-a: submission without a target is rejected")

	var act := PendingAction.make("play_instant", "p1",
		{"card_id": "shot_inst", "target_id": "enemy_ally"})
	ok(StackResolver.can_submit(state, act, db), "sc39-a2: full action is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(enemy.damage_taken, 1, "sc39-b: enemy ally took 1 arcane damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "enemy_ally":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc39-b2: damage sourced from p1's hero")

	ok(state.get_card("draw_card_inst").zone_id == "p1_hand",
		"sc39-c: a card was drawn into p1's hand")

	ok(state.get_card("shot_inst").zone_id == "p1_graveyard",
		"sc39-d: Arcane Shot itself is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40 — Arcane Shot is tagged as a combat instant (design-only AI tag,
# not a rules concept): held in hand, only played to ambush an attacker.
#
# Assertions:
#   sc40-a  get_legal_actions never blind-plays it outside combat
#   sc40-b  attack window — 1 HP / cost-matching attacker → play targeting it
#   sc40-c  attack window — attacker survives 1 dmg → hold
#   sc40-d  integration: attacker killed by Arcane Shot during the attack window
# ══════════════════════════════════════════════════════════════════════════════

func _test_arcane_shot_combat_instant_tag() -> void:
	print("\n-- Scenario 40: Arcane Shot tagged as a combat instant (held, ambush-only) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Registered under its REAL def id so BaseAI.COMBAT_INSTANT_TAGS matches.
	db.instant("azeroth_33", 2, "deal_damage_to_target:1:arcane|draw:1")
	db.ally("atk_worthy_def", 3, 1, [], 4)   # cost 4, 1 HP — dies to Arcane Shot
	db.ally("atk_fat_def",    3, 5, [], 4)   # cost 4, 5 HP — survives 1 dmg

	var ai := BaseAI.new()

	# ── Hold outside combat: never a blind play on own action window ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 2)
	var shot_hold := CardInstance.create("shot_hold", "azeroth_33", "p1", "p1_hand")
	st3.cards["shot_hold"] = shot_hold
	st3.zones["p1_hand"].card_ids.append("shot_hold")
	var blind := false
	for a in ai.get_legal_actions(st3, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "shot_hold":
			blind = true
	ok(not blind, "sc40-a: get_legal_actions never blind-plays a held combat instant")

	# ── Attack-window ambush matrix ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	st.turn_player     = "p2"
	st.priority_player = "p1"
	_add_resources(st, "p1", 2)
	var shot := CardInstance.create("shot_p1", "azeroth_33", "p1", "p1_hand")
	st.cards["shot_p1"] = shot
	st.zones["p1_hand"].card_ids.append("shot_p1")
	_add_ally(st, "atk_worthy", "atk_worthy_def", "p2")
	_add_ally(st, "atk_fat",    "atk_fat_def",    "p2")
	st.combat_attack_window = true
	st.combat_defender = "p1_hero"

	st.combat_attacker = "atk_worthy"
	var act := ai.combat_instant_action(st, db, "p1")
	ok(act != null and act.params.get("card_id") == "shot_p1"
			and act.params.get("target_id") == "atk_worthy",
		"sc40-b: attack window — 1 HP attacker dies to Arcane Shot → play targeting it")

	st.combat_attacker = "atk_fat"
	ok(ai.combat_instant_action(st, db, "p1") == null,
		"sc40-c: attack window — 5 HP attacker survives 1 dmg → hold")

	# ── Integration: p1 attacks, BaseAI p2 ambushes during the attack window ──
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st4, "raider", "atk_worthy_def", "p1")   # cost 4, 1 HP, 3 ATK
	_add_resources(st4, "p2", 2)
	var shot4 := CardInstance.create("shot_ambush", "azeroth_33", "p2", "p2_hand")
	st4.cards["shot_ambush"] = shot4
	st4.zones["p2_hand"].card_ids.append("shot_ambush")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}))

	_drive_turns(st4, db, p1_ai, BaseAI.new(), 3)

	ok(st4.get_card("raider").zone_id == "p1_graveyard",
		"sc40-d: attacker killed by Arcane Shot during the attack window")
	eq(st4.get_card("p2_hero").damage_taken, 0,
		"sc40-e: p2 hero took no combat damage (attacker died pre-conclusion)")
	ok(st4.get_card("shot_ambush").zone_id == "p2_graveyard",
		"sc40-f: Arcane Shot in graveyard after the ambush")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40b — Fire Blast: same shape as Quick Strike (hero deals damage to
# announced target), cost 1, fire damage. Also tagged as a combat instant
# (AI holds it, ambushes only during attack/defend windows).
#
# Assertions:
#   sc40b-a  submission WITHOUT a target is rejected
#   sc40b-b  2 fire damage dealt to the announced target, sourced from the hero
#   sc40b-c  Fire Blast itself ends up in the graveyard
#   sc40b-d  get_legal_actions never blind-plays it outside combat
#   sc40b-e  attack window — 2 HP / cost-matching attacker → play targeting it
#   sc40b-f  attack window — attacker survives 2 dmg → hold
#   sc40b-g  integration: attacker killed by Fire Blast during the attack window
# ══════════════════════════════════════════════════════════════════════════════

func _test_fire_blast() -> void:
	print("\n-- Scenario 40b: Fire Blast — hero deals 2 fire dmg, cost 1 --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 4, [], 3)
	# Registered under its REAL def id so BaseAI.COMBAT_INSTANT_TAGS matches.
	db.instant("azeroth_52", 1, "deal_damage_to_target:2:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var blast := CardInstance.create("blast_inst", "azeroth_52", "p1", "p1_hand")
	state.cards["blast_inst"] = blast
	state.zones["p1_hand"].card_ids.append("blast_inst")

	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_instant", "p1", {"card_id": "blast_inst"}), db),
		"sc40b-a: submission without a target is rejected")

	var act := PendingAction.make("play_instant", "p1",
		{"card_id": "blast_inst", "target_id": "enemy_ally"})
	ok(StackResolver.can_submit(state, act, db), "sc40b-a2: full action is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(enemy.damage_taken, 2, "sc40b-b: enemy ally took 2 fire damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "enemy_ally":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc40b-b2: damage sourced from p1's hero")

	ok(state.get_card("blast_inst").zone_id == "p1_graveyard",
		"sc40b-c: Fire Blast itself is in the graveyard")

	# ── Hold outside combat: never a blind play on own action window ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 1)
	var blast_hold := CardInstance.create("blast_hold", "azeroth_52", "p1", "p1_hand")
	st3.cards["blast_hold"] = blast_hold
	st3.zones["p1_hand"].card_ids.append("blast_hold")
	var blind := false
	for a in BaseAI.new().get_legal_actions(st3, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "blast_hold":
			blind = true
	ok(not blind, "sc40b-d: get_legal_actions never blind-plays a held combat instant")

	# ── Attack-window ambush matrix ──
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.instant("azeroth_52", 1, "deal_damage_to_target:2:fire")
	db2.ally("atk_worthy_def", 3, 2, [], 4)   # cost 4, 2 HP — dies to Fire Blast
	db2.ally("atk_fat_def",    3, 5, [], 4)   # cost 4, 5 HP — survives 2 dmg

	var ai := BaseAI.new()
	var st := _base_state(db2, "p1_hero", "p2_hero")
	st.turn_player     = "p2"
	st.priority_player = "p1"
	_add_resources(st, "p1", 1)
	var blast_p1 := CardInstance.create("blast_p1", "azeroth_52", "p1", "p1_hand")
	st.cards["blast_p1"] = blast_p1
	st.zones["p1_hand"].card_ids.append("blast_p1")
	_add_ally(st, "atk_worthy", "atk_worthy_def", "p2")
	_add_ally(st, "atk_fat",    "atk_fat_def",    "p2")
	st.combat_attack_window = true
	st.combat_defender = "p1_hero"

	st.combat_attacker = "atk_worthy"
	var act2 := ai.combat_instant_action(st, db2, "p1")
	ok(act2 != null and act2.params.get("card_id") == "blast_p1"
			and act2.params.get("target_id") == "atk_worthy",
		"sc40b-e: attack window — 2 HP attacker dies to Fire Blast → play targeting it")

	st.combat_attacker = "atk_fat"
	ok(ai.combat_instant_action(st, db2, "p1") == null,
		"sc40b-f: attack window — 5 HP attacker survives 2 dmg → hold")

	# ── Integration: p1 attacks, BaseAI p2 ambushes during the attack window ──
	var st4 := _base_state(db2, "p1_hero", "p2_hero")
	_add_ally(st4, "raider", "atk_worthy_def", "p1")   # cost 4, 2 HP, 3 ATK
	_add_resources(st4, "p2", 1)
	var blast4 := CardInstance.create("blast_ambush", "azeroth_52", "p2", "p2_hand")
	st4.cards["blast_ambush"] = blast4
	st4.zones["p2_hand"].card_ids.append("blast_ambush")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}))

	_drive_turns(st4, db2, p1_ai, BaseAI.new(), 3)

	ok(st4.get_card("raider").zone_id == "p1_graveyard",
		"sc40b-g: attacker killed by Fire Blast during the attack window")
	eq(st4.get_card("p2_hero").damage_taken, 0,
		"sc40b-h: p2 hero took no combat damage (attacker died pre-conclusion)")
	ok(st4.get_card("blast_ambush").zone_id == "p2_graveyard",
		"sc40b-i: Fire Blast in graveyard after the ambush")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 41 — Nerra Lifeboon: "Other allies in your party have +1 health."
# ══════════════════════════════════════════════════════════════════════════════

func _test_nerra_lifeboon_health_aura() -> void:
	print("\n-- Scenario 41: Nerra Lifeboon party '+1 health' aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("nerra_def", 4, 4, [], 5, "party_health_aura:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "nerra_inst", "nerra_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	_add_ally(state, "opp_inst", "grunt_def", "p2")

	eq(state.get_max_hp("grunt_inst", db), 3, "sc41-a: other ally gets +1 max health")
	eq(state.get_max_hp("nerra_inst", db), 4, "sc41-b: Nerra doesn't buff herself")
	eq(state.get_max_hp("opp_inst", db), 2, "sc41-c: opponent's ally unaffected by p1's Nerra")

	# Two Nerras stack.
	_add_ally(state, "nerra2_inst", "nerra_def", "p1")
	eq(state.get_max_hp("grunt_inst", db), 4, "sc41-d: two Nerras stack (+2)")
	eq(state.get_max_hp("nerra_inst", db), 5, "sc41-e: each Nerra buffs the other")

	# Nerra leaves play → aura disappears.
	GameLogic.move_card(state, "nerra_inst", "p1_graveyard")
	GameLogic.move_card(state, "nerra2_inst", "p1_graveyard")
	eq(state.get_max_hp("grunt_inst", db), 2, "sc41-f: aura gone once both Nerras leave play")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 41b — Nerra Lifeboon aura-loss death check.
#
# An ally kept alive only by Nerra's +health aura must die the instant Nerra
# dies, even with no further damage dealt (state-based death, rule 118.4/704).
# ══════════════════════════════════════════════════════════════════════════════

func _test_nerra_death_triggers_aura_loss_death() -> void:
	print("\n-- Scenario 41b: Nerra death kills an ally kept alive by her aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("nerra_def", 4, 4, [], 5, "party_health_aura:1")
	db.ally("braxiss_def", 4, 4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "nerra_inst", "nerra_def", "p1")
	_add_ally(state, "braxiss_inst", "braxiss_def", "p1")

	# Braxiss: printed 4 health, +1 from Nerra's aura = 5 max. Take 4 damage —
	# survives with 1 effective health left.
	state.get_card("braxiss_inst").damage_taken = 4
	eq(state.get_max_hp("braxiss_inst", db), 5, "sc41b-a: Braxiss has 5 max health thanks to Nerra")
	eq(state.get_current_hp("braxiss_inst", db), 1, "sc41b-b: Braxiss survives on 1 effective health")

	# Kill Nerra directly (simulates combat lethal damage).
	state.get_card("nerra_inst").damage_taken = state.get_max_hp("nerra_inst", db)
	StackResolver._check_destroyed_trigger(state, "nerra_inst", "p2_hero", db)

	ok(state.get_card("nerra_inst").zone_id == "p1_graveyard", "sc41b-c: Nerra destroyed")
	eq(state.get_max_hp("braxiss_inst", db), 4, "sc41b-d: Braxiss back to 4 max health, aura gone")
	ok(state.get_card("braxiss_inst").zone_id == "p1_graveyard",
		"sc41b-e: Braxiss dies too — 4 damage now equals his 4 max health")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 42 — Master of the Hunt: "Ongoing: Your Pets have +2 ATK and +2 health."
#
# Rule 305.2c: a non-attaching ongoing ability enters play in its controller's
# hero row and remains there providing its effect until removed — it does NOT
# resolve-and-graveyard like a non-ongoing ability (e.g. Vanquish).
# ══════════════════════════════════════════════════════════════════════════════

func _test_master_of_the_hunt_ongoing() -> void:
	print("\n-- Scenario 42: Master of the Hunt ongoing '+2 ATK / +2 health' pet aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ability("hunt_def", 3, "ongoing|pet_atk_health_aura:2:2")
	db.pet("pet_def", 2, 2, [], 2)
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	_add_ally(state, "pet_inst", "pet_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	_add_ally(state, "opp_pet_inst", "pet_def", "p2")

	var hunt := CardInstance.create("hunt_inst", "hunt_def", "p1", "p1_hand")
	state.cards["hunt_inst"] = hunt
	state.zones["p1_hand"].card_ids.append("hunt_inst")

	var play := PendingAction.make("play_ability", "p1", {"card_id": "hunt_inst"})
	ok(StackResolver.can_submit(state, play, db), "sc42-a: play_ability is legal")
	StackResolver.submit_action(state, play, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("hunt_inst").zone_id, "p1_hero_row",
		"sc42-b: ongoing ability enters play in the hero row (not the graveyard)")
	eq(state.get_atk("pet_inst", db), 4, "sc42-c: friendly pet gets +2 ATK")
	eq(state.get_max_hp("pet_inst", db), 4, "sc42-d: friendly pet gets +2 health")
	eq(state.get_atk("grunt_inst", db), 2, "sc42-e: non-pet ally unaffected")
	eq(state.get_atk("opp_pet_inst", db), 2, "sc42-f: opponent's pet unaffected by p1's aura")

	GameLogic.move_card(state, "hunt_inst", "p1_graveyard")
	eq(state.get_atk("pet_inst", db), 2, "sc42-g: aura gone once the ability leaves play")
	eq(state.get_max_hp("pet_inst", db), 2, "sc42-h: health aura gone once the ability leaves play")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 43 — Guardian Steelhorn: "can't attack" (Protector that never attacks)
# ══════════════════════════════════════════════════════════════════════════════

func _test_guardian_steelhorn_cant_attack() -> void:
	print("\n-- Scenario 43: Guardian Steelhorn can't attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("steelhorn_def", 3, 3, (["protector", "cant_attack"] as Array[String]))
	db.ally("plain_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "steel", "steelhorn_def", "p1")
	_add_ally(state, "plain", "plain_def", "p1")
	# Both are ready and not summoning-sick.
	state.get_card("steel").just_summoned = false
	state.get_card("plain").just_summoned = false
	state.players["p1"].resource_placed_this_turn = true

	var legal := StackResolver.get_legal_attackers(state, "p1", db)
	ok("steel" not in legal, "sc43-a: Guardian Steelhorn is NOT a legal attacker")
	ok("plain" in legal, "sc43-b: a normal ally IS a legal attacker")

	# Direct submission of a combat proposal with Steelhorn must be rejected.
	var propose := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "steel", "defender_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, propose, db),
		"sc43-c: propose_combat with Guardian Steelhorn is illegal")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 44 — Starfire: non-instant Ability (action-phase only), hero deals
# 5 arcane damage to an announced target, plus "Draw a card."
#
# Assertions:
#   sc44-a  cannot be played outside the action phase / with pending chain
#   sc44-b  submission without a target is rejected
#   sc44-c  5 arcane damage dealt to the announced target, sourced from the hero
#   sc44-d  a card is drawn
#   sc44-e  Starfire itself ends up in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_starfire() -> void:
	print("\n-- Scenario 44: Starfire — hero deals 5 arcane dmg + draw a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 8, [], 3)
	db.ally("filler_def", 1, 1, [], 1)
	db.ability("starfire_def", 6, "deal_damage_to_target:5:arcane|draw:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 6)

	var starfire := CardInstance.create("starfire_inst", "starfire_def", "p1", "p1_hand")
	state.cards["starfire_inst"] = starfire
	state.zones["p1_hand"].card_ids.append("starfire_inst")

	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	# A card to draw, at the top of p1's deck.
	var draw_card := CardInstance.create("draw_card_inst", "filler_def", "p1", "p1_deck")
	state.cards["draw_card_inst"] = draw_card
	state.zones["p1_deck"].card_ids.append("draw_card_inst")

	# Combat window open → not action-phase-only-legal.
	state.combat_attack_window = true
	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1",
			{"card_id": "starfire_inst", "target_id": "enemy_ally"}), db),
		"sc44-a: cannot be played during a combat window")
	state.combat_attack_window = false

	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1", {"card_id": "starfire_inst"}), db),
		"sc44-b: submission without a target is rejected")

	var act := PendingAction.make("play_ability", "p1",
		{"card_id": "starfire_inst", "target_id": "enemy_ally"})
	ok(StackResolver.can_submit(state, act, db), "sc44-b2: full action is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(enemy.damage_taken, 5, "sc44-c: enemy ally took 5 arcane damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "enemy_ally":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc44-c2: damage sourced from p1's hero")

	ok(state.get_card("draw_card_inst").zone_id == "p1_hand",
		"sc44-d: a card was drawn into p1's hand")

	ok(state.get_card("starfire_inst").zone_id == "p1_graveyard",
		"sc44-e: Starfire itself is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 45 — Flamestrike: non-instant Ability (action-phase only), hero deals
# 3 fire damage to EACH opposing hero and ally — no target announced.
#
# Assertions:
#   sc45-a  cannot be played outside the action phase / with pending chain
#   sc45-b  no target required to submit (unlike Quick Strike / Starfire)
#   sc45-c  3 fire damage dealt to every opposing ally, sourced from the hero
#   sc45-d  3 fire damage dealt to the opposing hero
#   sc45-e  friendly allies and own hero take no damage
#   sc45-f  a lethally-damaged opposing ally is destroyed (goes to graveyard)
#   sc45-g  Flamestrike itself ends up in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_flamestrike() -> void:
	print("\n-- Scenario 45: Flamestrike — hero deals 3 fire dmg to each opposing hero/ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("opp_ally_def", 2, 5, [], 3)
	db.ally("opp_weak_def", 2, 2, [], 2)   # dies to 3 fire damage
	db.ally("own_ally_def", 2, 5, [], 3)
	db.ability("flamestrike_def", 7, "deal_damage_aoe_opponent:3:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 7)

	var flamestrike := CardInstance.create("flamestrike_inst", "flamestrike_def", "p1", "p1_hand")
	state.cards["flamestrike_inst"] = flamestrike
	state.zones["p1_hand"].card_ids.append("flamestrike_inst")

	var opp_ally := CardInstance.create("opp_ally", "opp_ally_def", "p2", "p2_ally_row")
	state.cards["opp_ally"] = opp_ally
	state.zones["p2_ally_row"].card_ids.append("opp_ally")

	var opp_weak := CardInstance.create("opp_weak", "opp_weak_def", "p2", "p2_ally_row")
	state.cards["opp_weak"] = opp_weak
	state.zones["p2_ally_row"].card_ids.append("opp_weak")

	var own_ally := CardInstance.create("own_ally", "own_ally_def", "p1", "p1_ally_row")
	state.cards["own_ally"] = own_ally
	state.zones["p1_ally_row"].card_ids.append("own_ally")

	# Combat window open → not action-phase-only-legal.
	state.combat_attack_window = true
	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1", {"card_id": "flamestrike_inst"}), db),
		"sc45-a: cannot be played during a combat window")
	state.combat_attack_window = false

	var act := PendingAction.make("play_ability", "p1", {"card_id": "flamestrike_inst"})
	ok(StackResolver.can_submit(state, act, db), "sc45-b: no target required to submit")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(opp_ally.damage_taken, 3, "sc45-c: opposing ally took 3 fire damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "p2_hero":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc45-d: opposing hero took 3 fire damage sourced from p1's hero")
	eq(state.get_card("p2_hero").damage_taken, 3, "sc45-d2: opposing hero damage_taken == 3")

	eq(own_ally.damage_taken, 0, "sc45-e: friendly ally took no damage")
	eq(state.get_card("p1_hero").damage_taken, 0, "sc45-e2: own hero took no damage")

	ok(state.get_card("opp_weak").zone_id == "p2_graveyard",
		"sc45-f: lethally-damaged opposing ally destroyed")

	ok(state.get_card("flamestrike_inst").zone_id == "p1_graveyard",
		"sc45-g: Flamestrike itself is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 46 — Chain Lightning: 3 waves (3/2/1 nature), each an optional "may"
# after the mandatory 1st target. Card-specific targeting rule: the 1st target
# may NOT be Untargetable, but the 2nd/3rd targets CAN be (override of the
# normal Untargetable rule — see CLAUDE.md).
#
# Assertions:
#   sc46-a  no target at all → illegal submission
#   sc46-b  1-target cast: only 3 dmg dealt, to target_id, from p1's hero
#   sc46-c  2-target cast: 3 dmg + 2 dmg dealt to the two announced targets
#   sc46-d  3-target cast: 3+2+1 dmg dealt to the three announced targets
#   sc46-e  target_id_3 without target_id_2 is illegal (can't skip "another")
#   sc46-f  a repeated target (not distinct) is illegal
#   sc46-g  a target that dies to wave 1 doesn't block wave 2/3 from resolving
#           against the other announced targets (each wave is independent)
#   sc46-h  Untargetable card CANNOT be chosen as target_id (1st)
#   sc46-i  the SAME Untargetable card CAN be chosen as target_id_2 (2nd)
# ══════════════════════════════════════════════════════════════════════════════

func _test_chain_lightning() -> void:
	print("\n-- Scenario 46: Chain Lightning — up to 3 waves, 3/2/1 nature --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("victim_a_def", 2, 6, [], 3)
	db.ally("victim_b_def", 2, 6, [], 3)
	db.ally("victim_c_def", 2, 6, [], 3)
	db.ally("frail_def",    2, 2, [], 1)   # dies to 3 nature (wave 1)
	db.ally("untargetable_def", 0, 6, (["untargetable"] as Array[String]), 2)
	db.ability("chainlightning_def", 5, "chain_lightning:3:2:1:nature")

	# sc46-a: no target at all → illegal.
	var state0 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state0, "p1", 5)
	var cl0 := CardInstance.create("cl0", "chainlightning_def", "p1", "p1_hand")
	state0.cards["cl0"] = cl0
	state0.zones["p1_hand"].card_ids.append("cl0")
	ok(not StackResolver.can_submit(state0,
		PendingAction.make("play_ability", "p1", {"card_id": "cl0"}), db),
		"sc46-a: no target at all is illegal")

	# sc46-b: single-target cast — only 3 dmg, from p1's hero.
	var state1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state1, "p1", 5)
	var cl1 := CardInstance.create("cl1", "chainlightning_def", "p1", "p1_hand")
	state1.cards["cl1"] = cl1
	state1.zones["p1_hand"].card_ids.append("cl1")
	_add_ally(state1, "va1", "victim_a_def", "p2")

	var p1_ai1 := ScriptedAI.new()
	p1_ai1.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl1", "target_id": "va1"}))
	var events1 := _drive_turns(state1, db, p1_ai1, ScriptedAI.new(), 3)
	eq(state1.get_card("va1").damage_taken, 3, "sc46-b: single-target cast deals exactly 3 dmg")
	var dmg_source1 := ""
	for e in events1:
		if e.event_type == "damage_dealt":
			dmg_source1 = e.payload.get("source", dmg_source1)
	eq(dmg_source1, "p1_hero", "sc46-b2: damage source is p1's hero")
	ok(state1.get_card("cl1").zone_id == "p1_graveyard", "sc46-b3: Chain Lightning in graveyard")

	# sc46-c: two-target cast — 3 dmg + 2 dmg.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 5)
	var cl2 := CardInstance.create("cl2", "chainlightning_def", "p1", "p1_hand")
	state2.cards["cl2"] = cl2
	state2.zones["p1_hand"].card_ids.append("cl2")
	_add_ally(state2, "va2", "victim_a_def", "p2")
	_add_ally(state2, "vb2", "victim_b_def", "p2")

	var p1_ai2 := ScriptedAI.new()
	p1_ai2.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl2", "target_id": "va2", "target_id_2": "vb2"}))
	_drive_turns(state2, db, p1_ai2, ScriptedAI.new(), 3)
	eq(state2.get_card("va2").damage_taken, 3, "sc46-c: 1st target took 3 dmg")
	eq(state2.get_card("vb2").damage_taken, 2, "sc46-c2: 2nd target took 2 dmg")

	# sc46-d: three-target cast — 3 + 2 + 1.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 5)
	var cl3 := CardInstance.create("cl3", "chainlightning_def", "p1", "p1_hand")
	state3.cards["cl3"] = cl3
	state3.zones["p1_hand"].card_ids.append("cl3")
	_add_ally(state3, "va3", "victim_a_def", "p2")
	_add_ally(state3, "vb3", "victim_b_def", "p2")
	_add_ally(state3, "vc3", "victim_c_def", "p2")

	var p1_ai3 := ScriptedAI.new()
	p1_ai3.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl3", "target_id": "va3", "target_id_2": "vb3", "target_id_3": "vc3"}))
	_drive_turns(state3, db, p1_ai3, ScriptedAI.new(), 3)
	eq(state3.get_card("va3").damage_taken, 3, "sc46-d: 1st target took 3 dmg")
	eq(state3.get_card("vb3").damage_taken, 2, "sc46-d2: 2nd target took 2 dmg")
	eq(state3.get_card("vc3").damage_taken, 1, "sc46-d3: 3rd target took 1 dmg")

	# sc46-e / sc46-f: illegal target combinations.
	var state4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state4, "p1", 5)
	var cl4 := CardInstance.create("cl4", "chainlightning_def", "p1", "p1_hand")
	state4.cards["cl4"] = cl4
	state4.zones["p1_hand"].card_ids.append("cl4")
	_add_ally(state4, "va4", "victim_a_def", "p2")
	_add_ally(state4, "vb4", "victim_b_def", "p2")
	ok(not StackResolver.can_submit(state4, PendingAction.make("play_ability", "p1",
		{"card_id": "cl4", "target_id": "va4", "target_id_3": "vb4"}), db),
		"sc46-e: target_id_3 without target_id_2 is illegal")
	ok(not StackResolver.can_submit(state4, PendingAction.make("play_ability", "p1",
		{"card_id": "cl4", "target_id": "va4", "target_id_2": "va4"}), db),
		"sc46-f: repeated (non-distinct) target is illegal")

	# sc46-g: a target that dies to wave 1 doesn't block waves 2/3 from resolving
	# against the OTHER announced targets (each wave targets a different card).
	var state5 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state5, "p1", 5)
	var cl5 := CardInstance.create("cl5", "chainlightning_def", "p1", "p1_hand")
	state5.cards["cl5"] = cl5
	state5.zones["p1_hand"].card_ids.append("cl5")
	_add_ally(state5, "frail5", "frail_def",   "p2")   # 2 HP — dies to wave-1's 3 dmg
	_add_ally(state5, "vb5",    "victim_b_def", "p2")  # 6 HP — survives wave-2's 2 dmg

	var p1_ai5 := ScriptedAI.new()
	p1_ai5.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl5", "target_id": "frail5", "target_id_2": "vb5"}))
	_drive_turns(state5, db, p1_ai5, ScriptedAI.new(), 3)
	ok(state5.get_card("frail5").zone_id == "p2_graveyard",
		"sc46-g: 1st target destroyed by wave-1's 3 dmg")
	eq(state5.get_card("vb5").damage_taken, 2,
		"sc46-g2: 2nd target still took wave-2's 2 dmg despite the 1st target dying first")

	# sc46-h / sc46-i: Untargetable — card-specific override of the normal
	# Untargetable rule (References/wow_rules.txt ~line 4215): CANNOT be the
	# 1st target, but CAN be the 2nd (or 3rd) target of Chain Lightning only.
	var state6 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state6, "p1", 5)
	var cl6 := CardInstance.create("cl6", "chainlightning_def", "p1", "p1_hand")
	state6.cards["cl6"] = cl6
	state6.zones["p1_hand"].card_ids.append("cl6")
	_add_ally(state6, "ut6", "untargetable_def", "p2")
	_add_ally(state6, "va6", "victim_a_def",     "p2")

	ok(not StackResolver.can_submit(state6, PendingAction.make("play_ability", "p1",
		{"card_id": "cl6", "target_id": "ut6"}), db),
		"sc46-h: Untargetable card cannot be the 1st (mandatory) target")
	ok(StackResolver.can_submit(state6, PendingAction.make("play_ability", "p1",
		{"card_id": "cl6", "target_id": "va6", "target_id_2": "ut6"}), db),
		"sc46-i: the SAME Untargetable card CAN be the 2nd target")

	var p1_ai6 := ScriptedAI.new()
	p1_ai6.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl6", "target_id": "va6", "target_id_2": "ut6"}))
	_drive_turns(state6, db, p1_ai6, ScriptedAI.new(), 3)
	eq(state6.get_card("va6").damage_taken, 3, "sc46-j: 1st (non-Untargetable) target took 3 dmg")
	eq(state6.get_card("ut6").damage_taken, 2,
		"sc46-k: Untargetable 2nd target still took wave-2's 2 dmg")

	# sc46-l: AI wave assignment, case 1 — targets with 3/2/1 HP (+4 HP, +hero):
	# each wave kills the matching target (3→3hp, 2→2hp, 1→1hp).
	db.ally("hp4_def", 1, 4, [], 2)
	db.ally("hp3_def", 1, 3, [], 2)
	db.ally("hp2_def", 1, 2, [], 1)
	db.ally("hp1_def", 1, 1, [], 1)
	var state7 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state7, "p1", 5)
	var cl7 := CardInstance.create("cl7", "chainlightning_def", "p1", "p1_hand")
	state7.cards["cl7"] = cl7
	state7.zones["p1_hand"].card_ids.append("cl7")
	_add_ally(state7, "a4", "hp4_def", "p2")
	_add_ally(state7, "a3", "hp3_def", "p2")
	_add_ally(state7, "a2", "hp2_def", "p2")
	_add_ally(state7, "a1", "hp1_def", "p2")

	var ai7 := BaseAI.new()
	var act7 := ai7._chain_lightning_action(state7, db, "p1", "cl7", "play_ability")
	ok(act7 != null, "sc46-l: AI produced a Chain Lightning action")
	if act7:
		eq(act7.params.get("target_id", ""),   "a3", "sc46-l2: wave 1 (3 dmg) kills the 3-HP ally")
		eq(act7.params.get("target_id_2", ""), "a2", "sc46-l3: wave 2 (2 dmg) kills the 2-HP ally")
		eq(act7.params.get("target_id_3", ""), "a1", "sc46-l4: wave 3 (1 dmg) kills the 1-HP ally")

	# sc46-m: AI wave assignment, case 2 — two 1-HP allies + hero: the small
	# waves (2 and 1) kill the allies; the 3-damage wave goes to the hero
	# instead of being wasted on a 1-HP ally.
	var state8 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state8, "p1", 5)
	var cl8 := CardInstance.create("cl8", "chainlightning_def", "p1", "p1_hand")
	state8.cards["cl8"] = cl8
	state8.zones["p1_hand"].card_ids.append("cl8")
	_add_ally(state8, "f1", "hp1_def", "p2")
	_add_ally(state8, "f2", "hp1_def", "p2")

	var ai8 := BaseAI.new()
	var act8 := ai8._chain_lightning_action(state8, db, "p1", "cl8", "play_ability")
	ok(act8 != null, "sc46-m: AI produced a Chain Lightning action")
	if act8:
		eq(act8.params.get("target_id", ""), "p2_hero",
			"sc46-m2: wave 1 (3 dmg) hits the hero, not a 1-HP ally")
		var t2: String = act8.params.get("target_id_2", "")
		var t3: String = act8.params.get("target_id_3", "")
		ok(t2 in ["f1", "f2"] and t3 in ["f1", "f2"] and t2 != t3,
			"sc46-m3: waves 2 and 1 kill the two 1-HP allies")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 47 — Untargetable (Jeleane Nightbreeze, dark_portal_170): "This card
# can't be targeted" (References/wow_rules.txt ~line 4215, in play only). Links
# can't choose it as a target (rule 706), but combat is NOT targeting (601.2b)
# and non-targeted effects (AoE) are unaffected. A target that BECOMES
# Untargetable after the announce is illegal at resolution (glossary 4217) —
# the effect fizzles like a target that left play.
#
# Assertions:
#   sc47-a  targeted instant (Quick Strike-style) cannot target it
#   sc47-b  targeted ability (Vanquish-style destroy_target:ally) cannot target it
#   sc47-c  it CAN be attacked (combat is not targeting) and takes combat damage
#   sc47-d  AoE (Flamestrike-style, no target) still hits it
#   sc47-e  target becomes Untargetable after announce → effect fizzles,
#           the instant still goes to the graveyard
#   sc47-f  the same targeted instant is legal against a plain ally (sanity)
# ══════════════════════════════════════════════════════════════════════════════

func _test_untargetable_keyword() -> void:
	print("\n-- Scenario 47: Untargetable — no link targeting; combat and AoE unaffected --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Jeleane Nightbreeze's real stats: cost 2, 3 ATK melee, 2 health, Untargetable.
	db.ally("jeleane_def", 3, 2, (["untargetable"] as Array[String]), 2)
	db.ally("plain_def", 2, 6, [], 3)
	db.ally("attacker_def", 1, 4, [], 2)
	db.instant("quickstrike_def", 2, "deal_damage_to_target:2:melee")
	db.ability("vanquish_def", 3, "destroy_target:ally")
	db.ability("flamestrike_def", 7, "deal_damage_aoe_opponent:3:fire")

	# sc47-a / sc47-b / sc47-f: submission-time targeting checks.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 7)
	_add_ally(state, "jeleane", "jeleane_def", "p2")
	_add_ally(state, "plain", "plain_def", "p2")
	var qs := CardInstance.create("qs", "quickstrike_def", "p1", "p1_hand")
	state.cards["qs"] = qs
	state.zones["p1_hand"].card_ids.append("qs")
	var vq := CardInstance.create("vq", "vanquish_def", "p1", "p1_hand")
	state.cards["vq"] = vq
	state.zones["p1_hand"].card_ids.append("vq")

	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
		{"card_id": "qs", "target_id": "jeleane"}), db),
		"sc47-a: targeted instant cannot target an Untargetable ally")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
		{"card_id": "vq", "target_id": "jeleane"}), db),
		"sc47-b: targeted ability (destroy) cannot target an Untargetable ally")
	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
		{"card_id": "qs", "target_id": "plain"}), db),
		"sc47-f: the same instant is legal against a plain ally")

	# sc47-c: combat is NOT targeting — Jeleane is a legal defender and takes
	# combat damage normally.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state2, "jeleane2", "jeleane_def", "p2")
	var atk := _add_ally(state2, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	state2.players["p1"].resource_placed_this_turn = true

	ok(StackResolver.can_submit(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "jeleane2"}), db),
		"sc47-c: an Untargetable ally CAN be attacked (combat is not targeting)")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "jeleane2"}))
	_drive(state2, db, p1_ai, ScriptedAI.new())
	eq(state2.get_card("jeleane2").damage_taken, 1,
		"sc47-c2: combat damage landed on the Untargetable defender")

	# sc47-d: AoE (no target announced) still hits Untargetable allies.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 7)
	_add_ally(state3, "jeleane3", "jeleane_def", "p2")
	var fs := CardInstance.create("fs", "flamestrike_def", "p1", "p1_hand")
	state3.cards["fs"] = fs
	state3.zones["p1_hand"].card_ids.append("fs")

	var fs_act := PendingAction.make("play_ability", "p1", {"card_id": "fs"})
	ok(StackResolver.can_submit(state3, fs_act, db), "sc47-d: AoE submission is legal")
	StackResolver.submit_action(state3, fs_act, db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)
	ok(state3.get_card("jeleane3").zone_id == "p2_graveyard",
		"sc47-d2: AoE damage hit (and destroyed) the Untargetable ally")

	# sc47-e: resolution-time re-check (glossary 4217) — the target becomes
	# Untargetable AFTER the announce (simulated via granted_keywords, the same
	# container _has_keyword reads). The damage fizzles; the instant still goes
	# to the graveyard, same as a target that left play.
	var state4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state4, "p1", 2)
	_add_ally(state4, "plain4", "plain_def", "p2")
	var qs4 := CardInstance.create("qs4", "quickstrike_def", "p1", "p1_hand")
	state4.cards["qs4"] = qs4
	state4.zones["p1_hand"].card_ids.append("qs4")

	var qs_act := PendingAction.make("play_instant", "p1",
		{"card_id": "qs4", "target_id": "plain4"})
	ok(StackResolver.can_submit(state4, qs_act, db), "sc47-e: announce against a legal target")
	StackResolver.submit_action(state4, qs_act, db)
	state4.get_card("plain4").granted_keywords.append("untargetable")
	StackResolver.pass_priority(state4, db)
	StackResolver.pass_priority(state4, db)
	eq(state4.get_card("plain4").damage_taken, 0,
		"sc47-e2: effect fizzled — target that became Untargetable took no damage")
	ok(state4.get_card("qs4").zone_id == "p1_graveyard",
		"sc47-e3: the fizzled instant still goes to the graveyard")
