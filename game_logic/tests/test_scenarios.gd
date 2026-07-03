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
	_test_protector_skipped_hero_takes_damage()
	_test_attacker_destroyed_by_protector()
	_test_no_protector_hero_takes_damage()
	_test_ferocity_attacks_turn_played()
	_test_normal_ally_cannot_attack_turn_played()
	_test_elusive_never_targetable()
	_test_hand_size_wrap_up_discard()
	_test_ai_quest_and_hand_size()
	_test_tazo_hero_power()
	_test_moonshadow_hero_power()
	_test_tazdingo_enter_play()
	_test_parvink_enter_play()
	_test_vanquish()
	_test_timmo_hero_power()
	_test_grennan_hero_power()

	print("\n=== Results: %d passed  %d failed ===" % [_pass, _fail])
	if _fail == 0:
		print("ALL TESTS PASSED ✓")
	else:
		print("SOME TESTS FAILED — see FAIL lines above")
	# One deferred frame lets Godot flush the output buffer before the process exits.
	await get_tree().process_frame
	get_tree().quit()


# ── Assertion helpers ──────────────────────────────────────────────────────────

var _pass := 0
var _fail := 0

func ok(condition: bool, name: String) -> void:
	if condition:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		print("  FAIL  %s" % name)

func eq(a, b, name: String) -> void:
	if a == b:
		_pass += 1
		print("  PASS  %s" % name)
	else:
		_fail += 1
		print("  FAIL  %s  [got %s, expected %s]" % [name, str(a), str(b)])


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

	func quest(def_id: String, cost: int = 0) -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.printed_atk    = 0
		d.printed_health = 0
		d.cost           = cost
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

	func get_def(id: String) -> CardDef:
		return _defs.get(id)


# ── ScriptedAI ─────────────────────────────────────────────────────────────────
# Takes a fixed list of actions to submit, then passes for the rest.
# Protect choices are also predetermined.

class ScriptedAI extends RefCounted:
	var _actions:   Array = []   # Array[PendingAction]
	var _protectors: Array = []  # Array[String] — "" means skip

	func queue_action(a: PendingAction) -> void:
		_actions.append(a)

	func queue_protect(protector_id: String) -> void:
		_protectors.append(protector_id)

	func decide_action(_state: GameState, _db, _player_id: String) -> PendingAction:
		if not _actions.is_empty():
			return _actions.pop_front()
		return null

	func choose_protector(_state: GameState, _db, _player_id: String) -> String:
		if not _protectors.is_empty():
			return _protectors.pop_front()
		return ""   # default: skip protection


# ── RandomAttackerAI ──────────────────────────────────────────────────────────
# Each action phase: attacks a random legal target with a random legal attacker.
# On protect point: always skips (no protection strategy).
# Used to verify that certain cards are NEVER picked as targets by the engine.

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
		return ""   # never protect


# ── Scenario driver ────────────────────────────────────────────────────────────
# Runs the priority loop, handling protect points, until game_over or MAX_STEPS.
# Returns all collected GameEvents.

func _drive(state: GameState, db, p1_ai: ScriptedAI, p2_ai: ScriptedAI) -> Array[GameEvent]:
	var all_events: Array[GameEvent] = []
	var protect_pending := false
	var protect_player  := ""

	for _step in range(MAX_STEPS):
		# Protect point takes priority over the normal priority loop.
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

		# Check terminal condition via game_over event having been collected.
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
				# After phase_changed to action, stop — we only drive one turn's worth.
				# The scenario tests don't need a full game loop.
				if all_events.size() > 5:
					return all_events

	return all_events


# Multi-turn variant: runs full turn cycles (ready→draw→action→end→…) until
# game_over fires or max_turns is exhausted.
# Both AIs are duck-typed — accepts ScriptedAI or RandomAttackerAI.
func _drive_turns(state: GameState, db, p1_ai, p2_ai, max_turns: int) -> Array[GameEvent]:
	var all_events: Array[GameEvent] = []
	var protect_pending := false
	var protect_player  := ""
	var game_over       := false   # flag avoids O(n²) scan of all_events

	for _step in range(max_turns * 20):   # ~20 steps per turn on average
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
						all_events.append_array(
							_headless_discard(state, ae, db))
			elif e.event_type == "discard_choice_opened":
				# Card-effect discard (e.g. Donation of Wool reward).
				all_events.append_array(_headless_discard(state, e, db))
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
# Handles any discard_choice_opened event (wrap_up or card_effect) by randomly
# discarding the required number of cards from the player's hand.
# For wrap_up: also calls advance_phase("end") a second time to proceed past it.
func _headless_discard(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var dp:  String = event.payload.get("player", "")
	var cnt: int    = event.payload.get("count",  0)
	var reason: String = event.payload.get("reason", "")
	var events: Array[GameEvent] = []

	if reason == "wrap_up":
		# Move cards directly (wrap-up bypasses StackResolver.choose_discard).
		var hand := state.cards_in_zone(dp + "_hand")
		hand.shuffle()
		for i in range(mini(cnt, hand.size())):
			events.append_array(
				GameLogic.move_card(state, hand[i].instance_id, dp + "_graveyard"))
		# Phase is still "end" — advance again so the turn actually ends.
		var adv2 := TurnManager.advance_phase(state, db)
		events.append_array(adv2)
		for ae2 in adv2:
			if ae2.event_type == "discard_choice_opened":
				events.append_array(_headless_discard(state, ae2, db))
	else:
		# Card-effect discard: use choose_discard so pending state is tracked correctly.
		var hand := state.cards_in_zone(dp + "_hand")
		hand.shuffle()
		for card in hand:
			if state.pending_discard_count <= 0:
				break
			events.append_array(StackResolver.choose_discard(state, card.instance_id, db))

	return events


# ── Headless enter-play target helper ────────────────────────────────────────
# Called when an enters-play targeted effect fires (e.g. Taz'dingo).
# Picks a random valid target for the controlling player and resolves the effect.
func _headless_enter_play_target(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var source_id: String = event.payload.get("card_id", "")
	var source_card := state.get_card(source_id)
	if not source_card:
		return []
	var ctrl := source_card.controller
	var events: Array[GameEvent] = []

	# Collect all valid targets.
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

	# Place heroes.
	var h1 := CardInstance.create(p1_hero_id, p1_hero_id, "p1", "p1_hero_row")
	state.cards[p1_hero_id] = h1
	state.zones["p1_hero_row"].card_ids.append(p1_hero_id)
	state.players["p1"].hero_instance_id = p1_hero_id

	var h2 := CardInstance.create(p2_hero_id, p2_hero_id, "p2", "p2_hero_row")
	state.cards[p2_hero_id] = h2
	state.zones["p2_hero_row"].card_ids.append(p2_hero_id)
	state.players["p2"].hero_instance_id = p2_hero_id

	# Set phase to action with P1's turn and priority.
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


# Add N ready (non-exhausted) face-down resource cards to a player's resource row.
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
# Setup : P1 has a 3/4 ally.  P2 has a 0/6 Protector ally and a 30-HP hero.
# Script: P1 attacks P2's hero.  P2's AI protects with the Protector.
# Expect: hero untouched (0 damage), protector takes 3 damage, attacker takes 0.
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

	# Give P1 enough resources to pass cost checks (combat has no cost but
	# StackResolver may check turn_player; set resources anyway for robustness).
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))

	var p2_ai := ScriptedAI.new()
	p2_ai.queue_protect("prot")   # P2 will protect with the Protector

	_drive(state, db, p1_ai, p2_ai)

	var p2_hero  := state.get_card("p2_hero")
	var protector := state.get_card("prot")
	var attacker  := state.get_card("atk")

	eq(p2_hero.damage_taken,  0, "sc1: P2 hero took 0 damage (intercepted)")
	eq(protector.damage_taken, 3, "sc1: protector took 3 damage (attacker's ATK)")
	eq(attacker.damage_taken,  0, "sc1: attacker took 0 (protector has 0 ATK)")
	ok(protector.is_exhausted,    "sc1: protector is exhausted after protecting")
	ok(atk.is_exhausted if atk else true,
		"sc1: attacker is exhausted after attacking")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 2 — P2 skips protection, hero takes damage
# Same setup, but P2's AI passes on the protect point.
# Expect: hero takes 3 damage, protector untouched.
# ══════════════════════════════════════════════════════════════════════════════

func _test_protector_skipped_hero_takes_damage() -> void:
	print("\n-- Scenario 2: P2 skips protection, hero takes the hit --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.ally("protector_def", 0, 6, (["protector"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "attacker_def", "p1")
	_add_ally(state, "prot", "protector_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))

	var p2_ai := ScriptedAI.new()
	p2_ai.queue_protect("")   # P2 skips — hero takes the hit

	_drive(state, db, p1_ai, p2_ai)

	var p2_hero   := state.get_card("p2_hero")
	var protector := state.get_card("prot")

	eq(p2_hero.damage_taken,   3, "sc2: P2 hero took 3 damage")
	eq(protector.damage_taken, 0, "sc2: protector untouched")
	ok(not protector.is_exhausted, "sc2: protector not exhausted (didn't protect)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 3 — Protector dies, attacker survives
# P1 has a 5/4 ally.  P2's protector is 2/3.
# Expect: protector destroyed (5 ≥ 3), attacker survives (2 < 4).
# ══════════════════════════════════════════════════════════════════════════════

func _test_attacker_destroyed_by_protector() -> void:
	print("\n-- Scenario 3: Protector kills the attacker --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("weak_attacker", 2, 2)    # 2 ATK / 2 HP
	db.ally("strong_prot",   3, 4, (["protector"] as Array[String]))  # 3 ATK / 4 HP Protector

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "weak_attacker", "p1")
	_add_ally(state, "prot", "strong_prot", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))

	var p2_ai := ScriptedAI.new()
	p2_ai.queue_protect("prot")

	_drive(state, db, p1_ai, p2_ai)

	var attacker  := state.get_card("atk")
	var protector := state.get_card("prot")
	var p2_hero   := state.get_card("p2_hero")

	eq(attacker.zone_id,  "p1_graveyard", "sc3: attacker destroyed (took 3, had 2 HP)")
	eq(protector.damage_taken, 2,         "sc3: protector took 2 (attacker ATK)")
	ok(protector.zone_id == "p2_ally_row","sc3: protector survived (4 HP > 2 dmg)")
	eq(p2_hero.damage_taken, 0,           "sc3: hero untouched")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 4 — No allies, hero takes direct damage
# P2 has no allies — protect point never opens, hero takes full damage.
# ══════════════════════════════════════════════════════════════════════════════

func _test_no_protector_hero_takes_damage() -> void:
	print("\n-- Scenario 4: No protectors available, hero takes direct hit --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 4, 5)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "attacker_def", "p1")
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))

	var p2_ai := ScriptedAI.new()   # no protect queued — protect point won't open anyway

	_drive(state, db, p1_ai, p2_ai)

	var p2_hero := state.get_card("p2_hero")
	eq(p2_hero.damage_taken, 4, "sc4: hero took 4 damage (no intercept)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 5 — Ferocity: ally attacks the turn it is played
# A Ferocity 3/4 ally is placed in play with just_summoned=true (simulating
# having been played this turn).  It must appear in get_legal_attackers and
# deal its damage immediately.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ferocity_attacks_turn_played() -> void:
	print("\n-- Scenario 5: Ferocity ally attacks the turn it is played --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ferocity_ally", 3, 4, (["ferocity"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "ferocity_ally", "p1")
	atk.just_summoned = true   # freshly played this turn

	state.players["p1"].resource_placed_this_turn = true

	var legal := StackResolver.get_legal_attackers(state, "p1", db)
	ok("atk" in legal, "sc5: Ferocity ally is a legal attacker despite just_summoned")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))

	var p2_ai := ScriptedAI.new()

	_drive(state, db, p1_ai, p2_ai)

	eq(state.get_card("p2_hero").damage_taken, 3, "sc5: hero took 3 damage (Ferocity attacked immediately)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 6 — No Ferocity: normal ally cannot attack the turn it is played
# Same setup, ally has no Ferocity.  just_summoned=true must exclude it from
# legal attackers.
# ══════════════════════════════════════════════════════════════════════════════

func _test_normal_ally_cannot_attack_turn_played() -> void:
	print("\n-- Scenario 6: Normal ally cannot attack the turn it is played --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("vanilla_ally", 3, 4)   # no keywords

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "vanilla_ally", "p1")
	atk.just_summoned = true

	var legal := StackResolver.get_legal_attackers(state, "p1", db)
	ok("atk" not in legal, "sc6: normal ally is NOT a legal attacker when just_summoned")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 7 — Elusive: never a legal defender
# P1 has a 1/30 ally (effectively immortal attacker).
# P2 has a 0/1 Elusive ally and a 30 HP hero.
# P1's RandomAttackerAI can only legally target the hero (Elusive is excluded).
# We run 5 turns — enough to prove the pattern without a long loop.
# After 5 P1 turns: hero should have exactly 5 damage, Elusive untouched.
# ══════════════════════════════════════════════════════════════════════════════

func _test_elusive_never_targetable() -> void:
	print("\n-- Scenario 7: Elusive ally is never a legal defender --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("p1_attacker", 1, 30)   # survives all combats
	db.ally("elusive_ally", 0, 1, (["elusive"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "p1_attacker", "p1")
	_add_ally(state, "elu", "elusive_ally", "p2")

	# Confirm Elusive is excluded from legal defenders right away.
	var defenders := StackResolver.get_legal_defenders(state, "atk", db)
	ok("elu" not in defenders, "sc7: Elusive ally is not in legal defenders list")
	ok("p2_hero" in defenders, "sc7: P2 hero IS a legal defender")

	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := RandomAttackerAI.new()
	var p2_ai := ScriptedAI.new()

	# 5 P1 turns × 1 ATK = 5 damage to the hero. Hero (30 HP) survives so no game_over fires.
	_drive_turns(state, db, p1_ai, p2_ai, 5)

	var elusive := state.get_card("elu")
	var p2_hero := state.get_card("p2_hero")

	ok(elusive.zone_id == "p2_ally_row", "sc7: Elusive ally still in play (never attacked)")
	eq(elusive.damage_taken, 0,           "sc7: Elusive took 0 damage")
	# Hero should have absorbed all attacks; Elusive was never a legal target.
	# Exact count varies with step budget — we only need "non-zero" and "Elusive = 0".
	ok(p2_hero.damage_taken > 0,          "sc7: Hero took damage (all attacks went to hero, Elusive untouched)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8 — Hand-size wrap-up: excess cards discarded before turn advances
# Rule 503.2a: at wrap-up the turn player discards down to max hand size (7).
# Setup : P1 has 9 unplayable cards in hand (cost 5, 0 resources),
#         resource_placed_this_turn=true so no legal action exists.
#         P2 is a blank.
# Script: both players pass everything → wrap-up fires → P1 discards 2.
# Expect: p1_hand.size() == 7, p1_graveyard.size() == 2.
# ══════════════════════════════════════════════════════════════════════════════

func _test_hand_size_wrap_up_discard() -> void:
	print("\n-- Scenario 8: Wrap-up discard reduces hand to max size --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("expensive_ally", 3, 4, [], 5)   # cost 5 — unplayable with 0 resources

	var state := _base_state(db, "p1_hero", "p2_hero")

	# Give P1 9 hand cards (all cost 5, unplayable with 0 resources).
	for i in range(9):
		var inst_id := "hand_%d" % i
		var card := CardInstance.create(inst_id, "expensive_ally", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)

	# Block resource placement so P1 has no legal action at all.
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()   # no actions queued — always passes
	var p2_ai := ScriptedAI.new()

	_drive_turns(state, db, p1_ai, p2_ai, 2)

	var hand_size  := state.cards_in_zone("p1_hand").size()
	var grave_size := state.cards_in_zone("p1_graveyard").size()

	eq(hand_size,  7, "sc8: P1 hand reduced to 7 after wrap-up discard")
	eq(grave_size, 2, "sc8: 2 excess cards in graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 9 — AI quest completion + hand-size wrap-up (combined)
#
# Setup:
#   P1: hero, 9 unplayable hand cards (cost 5), resource_placed=true,
#       1 ally in play (gives P2 a legal attack target).
#   P2: hero, 1 ally in play (legal attacker), 1 face-up quest in resource row
#       (cost 0, completable immediately).
#
# Part A — AI completes the quest:
#   We inspect get_legal_actions() for P2 and confirm the quest appears.
#   ScriptedAI queues exactly that action; after one action phase the quest
#   must be face-down (completed).
#
# Part B — hand-size wrap-up:
#   After P2's turn ends (no excess), P1's turn starts.  P1 holds 9 unplayable
#   cards and passes everything → wrap-up discards 2 → P1 hand must be 7.
#
# Assertions (5 total):
#   sc9-a  quest appears in P2's legal actions
#   sc9-b  quest is face-down after P2 completes it
#   sc9-c  quest card is still in P2 resource row (not destroyed)
#   sc9-d  P1 hand == 7 after wrap-up
#   sc9-e  P1 graveyard == 2 (the discarded excess)
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_quest_and_hand_size() -> void:
	print("\n-- Scenario 9: AI completes quest + P1 wrap-up discard --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("cheap_ally",     2, 3, [], 0)   # in play — no cost needed
	db.ally("expensive_ally", 3, 4, [], 5)   # hand cards — unplayable
	db.quest("free_quest", 0)                # P2's quest, cost 0

	var state := _base_state(db, "p1_hero", "p2_hero")

	# P1: 9 unplayable hand cards + 1 ally in play (legal defender for P2).
	for i in range(9):
		var inst_id := "p1_hand_%d" % i
		var card := CardInstance.create(inst_id, "expensive_ally", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)
	_add_ally(state, "p1_ally", "cheap_ally", "p1")
	state.players["p1"].resource_placed_this_turn = true

	# P2: 1 ally in play (legal attacker) + 1 face-up quest in resource row.
	_add_ally(state, "p2_ally", "cheap_ally", "p2")
	var quest_card := CardInstance.create("p2_quest", "free_quest", "p2", "p2_resource_row")
	quest_card.face_down = false
	state.cards["p2_quest"] = quest_card
	state.zones["p2_resource_row"].card_ids.append("p2_quest")
	state.players["p2"].resource_placed_this_turn = true   # quest is the only action

	# It is P2's turn so _can_use_quest passes the priority check.
	state.turn_player     = "p2"
	state.priority_player = "p2"

	# Part A — verify the quest appears in legal actions.
	var p2_ai_helper := BaseAI.new()
	var legal := p2_ai_helper.get_legal_actions(state, db, "p2")
	var quest_action: PendingAction = null
	for a in legal:
		if a.action_type == "use_quest" and a.params.get("quest_id") == "p2_quest":
			quest_action = a
			break
	ok(quest_action != null, "sc9-a: use_quest appears in P2 legal actions")

	# Part B — ScriptedAI queues the quest then passes; P1 always passes.
	var p2_ai := ScriptedAI.new()
	if quest_action:
		p2_ai.queue_action(quest_action)

	var p1_ai := ScriptedAI.new()   # always passes

	_drive_turns(state, db, p1_ai, p2_ai, 3)

	var quest_inst := state.get_card("p2_quest")
	ok(quest_inst != null and quest_inst.face_down, "sc9-b: quest is face-down after completion")
	ok(quest_inst != null and quest_inst.zone_id == "p2_resource_row",
		"sc9-c: completed quest stays in resource row")

	var hand_size  := state.cards_in_zone("p1_hand").size()
	var grave_size := state.cards_in_zone("p1_graveyard").size()
	eq(hand_size,  7, "sc9-d: P1 hand reduced to 7 after wrap-up discard")
	eq(grave_size, 2, "sc9-e: 2 excess cards in P1 graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 10 — Ta'zo hero power: deal 3 fire damage to target
#
# Setup : P1 has a 2/4 ally.  P2 has Ta'zo (cost 3, deal_damage_to_target:3:fire)
#         with 3 ready resources.
# Script: ScriptedAI queues activate_power targeting P1's ally.
#
# Assertions:
#   sc10-a  activate_power for Ta'zo appears in P2's legal actions (target = p1 ally)
#   sc10-b  P1 ally has 3 damage after resolution
#   sc10-c  P2's has_used_hero_power is true after activation
#   sc10-d  No second activate_power action available (power already used)
#   sc10-e  hero_power_used event fires during submission
# ══════════════════════════════════════════════════════════════════════════════

func _test_tazo_hero_power() -> void:
	print("\n-- Scenario 10: Ta'zo hero power deals 3 damage --")
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

	state.phase           = "action"
	state.turn_player     = "p2"
	state.priority_player = "p2"
	state.turn_number     = 1

	# P1 ally — the target.
	_add_ally(state, "p1_ally", "target_ally", "p1")

	# 3 ready resources for P2 (cost of Ta'zo power).
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# sc10-a: confirm activate_power appears in legal actions targeting p1_ally.
	var helper := BaseAI.new()
	var legal := helper.get_legal_actions(state, db, "p2")
	var power_action: PendingAction = null
	for a in legal:
		if a.action_type == "activate_power" and a.params.get("target_id") == "p1_ally":
			power_action = a
			break
	ok(power_action != null, "sc10-a: activate_power targeting p1_ally appears in legal actions")

	# Submit queues to chain and fires hero_power_used immediately.
	var all_sc10: Array[GameEvent] = []
	all_sc10.append_array(StackResolver.submit_action(state, power_action, db) if power_action \
		else ([] as Array[GameEvent]))
	# Two pass_priority calls resolve the chain.
	all_sc10.append_array(StackResolver.pass_priority(state, db))
	all_sc10.append_array(StackResolver.pass_priority(state, db))

	# sc10-e: hero_power_used event fires during submission.
	var saw_power_used := false
	for e in all_sc10:
		if e.event_type == "hero_power_used":
			saw_power_used = true
	ok(saw_power_used, "sc10-e: hero_power_used event fired during submission")

	# sc10-b: 3 damage applied after resolution.
	var p1_ally := state.get_card("p1_ally")
	eq(p1_ally.damage_taken if p1_ally else -1, 3, "sc10-b: p1 ally took 3 damage from Ta'zo power")

	# sc10-c: flag is set.
	var p2_ps := state.players.get("p2") as PlayerState
	ok(p2_ps != null and p2_ps.has_used_hero_power, "sc10-c: has_used_hero_power is true after activation")

	# sc10-d: no second activate_power available.
	var legal2 := helper.get_legal_actions(state, db, "p2")
	var found_second := false
	for a in legal2:
		if a.action_type == "activate_power":
			found_second = true
	ok(not found_second, "sc10-d: activate_power not available after power already used")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 11 — Moonshadow hero power: shuffle hand into deck and draw same count
#
# Setup : P1 has Moonshadow (cost 3, shuffle_hand_draw) with 3 ready resources
#         and 5 cards in hand.  Deck has 10 additional cards.
# Script: ScriptedAI queues activate_power (no target).
#
# Assertions:
#   sc11-a  activate_power (untargeted) appears in P1 legal actions
#   sc11-b  hand size is still 5 after activation (drew back what was shuffled)
#   sc11-c  deck_shuffled event fires
#   sc11-d  has_used_hero_power is true
#   sc11-e  P1 cannot use hero power again same turn
# ══════════════════════════════════════════════════════════════════════════════

func _test_moonshadow_hero_power() -> void:
	print("\n-- Scenario 11: Moonshadow hero power shuffles hand and redraws --")
	var db := MockDB.new()
	db.hero("moon_def", 27, 3, "shuffle_hand_draw")
	db.hero("p2_hero", 30)
	db.ally("filler_ally", 1, 1, [], 0)   # filler def for hand/deck cards

	var state := GameState.create_new(["p1", "p2"])

	var h1 := CardInstance.create("moon_inst", "moon_def", "p1", "p1_hero_row")
	state.cards["moon_inst"] = h1
	state.zones["p1_hero_row"].card_ids.append("moon_inst")
	state.players["p1"].hero_instance_id = "moon_inst"

	var h2 := CardInstance.create("p2_hero", "p2_hero", "p2", "p2_hero_row")
	state.cards["p2_hero"] = h2
	state.zones["p2_hero_row"].card_ids.append("p2_hero")
	state.players["p2"].hero_instance_id = "p2_hero"

	state.phase           = "action"
	state.turn_player     = "p1"
	state.priority_player = "p1"
	state.turn_number     = 1

	# 5 cards in P1 hand.
	for i in range(5):
		var inst_id := "p1_hand_%d" % i
		var card := CardInstance.create(inst_id, "filler_ally", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)

	# 10 cards in P1 deck.
	for i in range(10):
		var inst_id := "p1_deck_%d" % i
		var card := CardInstance.create(inst_id, "filler_ally", "p1", "p1_deck")
		state.cards[inst_id] = card
		state.zones["p1_deck"].card_ids.append(inst_id)

	# 3 ready resources for P1.
	_add_resources(state, "p1", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# sc11-a: activate_power (no target) appears in legal actions.
	var helper := BaseAI.new()
	var legal := helper.get_legal_actions(state, db, "p1")
	var power_action: PendingAction = null
	for a in legal:
		if a.action_type == "activate_power" and a.params.get("target_id", "") == "":
			power_action = a
			break
	ok(power_action != null, "sc11-a: untargeted activate_power appears in legal actions")

	# Submit queues to chain; two pass_priority calls resolve it.
	var all_sc11: Array[GameEvent] = []
	if power_action:
		all_sc11.append_array(StackResolver.submit_action(state, power_action, db))
	all_sc11.append_array(StackResolver.pass_priority(state, db))
	all_sc11.append_array(StackResolver.pass_priority(state, db))

	# sc11-b: hand size unchanged (shuffled 5 back, drew 5).
	var hand_after := state.cards_in_zone("p1_hand").size()
	eq(hand_after, 5, "sc11-b: hand size still 5 after shuffle-and-draw")

	# sc11-c: deck_shuffled event was emitted.
	var saw_shuffle := false
	for e in all_sc11:
		if e.event_type == "deck_shuffled":
			saw_shuffle = true
	ok(saw_shuffle, "sc11-c: deck_shuffled event fired during activation")

	# sc11-d: flag set.
	var p1_ps := state.players.get("p1") as PlayerState
	ok(p1_ps != null and p1_ps.has_used_hero_power, "sc11-d: has_used_hero_power is true")

	# sc11-e: no second activate_power available.
	var legal2 := helper.get_legal_actions(state, db, "p1")
	var found_second := false
	for a in legal2:
		if a.action_type == "activate_power":
			found_second = true
	ok(not found_second, "sc11-e: activate_power not available after power already used")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 12 — Taz'dingo enters-play effect fires and deals 1 ranged damage
# Setup : P1 has Taz'dingo in hand (cost 3), 3 resources.  P2 has a 30-HP hero.
# Script: P1 plays Taz'dingo; headless loop picks p2 hero as target.
# Expect: Taz'dingo is in p1_ally_row; p2 hero took exactly 1 damage.
# ══════════════════════════════════════════════════════════════════════════════

func _test_tazdingo_enter_play() -> void:
	print("\n-- Scenario 12: Taz'dingo enters-play targeted damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tazdingo_def", 2, 2, [], 3, "on_enter:deal_damage_to_target:1:ranged")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	# Put Taz'dingo in p1's hand.
	var taz := CardInstance.create("taz_inst", "tazdingo_def", "p1", "p1_hand")
	state.cards["taz_inst"] = taz
	state.zones["p1_hand"].card_ids.append("taz_inst")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "taz_inst"}))
	var p2_ai := ScriptedAI.new()

	var all_events := _drive_turns(state, db, p1_ai, p2_ai, 3)

	# sc12-a: Taz'dingo is in ally_row (entered play successfully).
	var taz_card := state.get_card("taz_inst")
	ok(taz_card != null and taz_card.zone_id == "p1_ally_row",
		"sc12-a: Taz'dingo is in p1_ally_row")

	# sc12-b: enter_play_target_required event was emitted.
	var saw_target_req := false
	for e in all_events:
		if e.event_type == "enter_play_target_required":
			saw_target_req = true
	ok(saw_target_req, "sc12-b: enter_play_target_required event fired")

	# sc12-c: exactly 1 ranged damage was dealt to any target (heroes or Taz'dingo itself are all valid).
	var total_dmg := 0
	for e in all_events:
		if e.event_type == "damage_dealt":
			total_dmg += e.payload.get("amount", 0)
	eq(total_dmg, 1, "sc12-c: exactly 1 total damage dealt by Taz'dingo enters-play effect")

	# sc12-d: pending_enter_play_effect cleared after resolution.
	ok(state.pending_enter_play_effect.is_empty(),
		"sc12-d: pending_enter_play_effect cleared after resolution")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 13 — Parvink enters play and draws a card for her controller
# Setup : P1 has Parvink in hand (cost 3), 3 resources, 1 card in deck,
#         starting hand size 0 so the draw is clearly measurable.
# Expect: Parvink is in p1_ally_row; p1 hand has exactly 1 card.
# ══════════════════════════════════════════════════════════════════════════════

func _test_parvink_enter_play() -> void:
	print("\n-- Scenario 13: Parvink enters play and draws a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("parvink_def", 2, 2, (["protector"] as Array[String]), 3, "on_enter:draw:1")
	db.ally("deck_card_def", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	# Put Parvink in p1's hand.
	var parvink := CardInstance.create("parvink_inst", "parvink_def", "p1", "p1_hand")
	state.cards["parvink_inst"] = parvink
	state.zones["p1_hand"].card_ids.append("parvink_inst")

	# Put one card in p1's deck (the card that will be drawn).
	var deck_card := CardInstance.create("deck1", "deck_card_def", "p1", "p1_deck")
	state.cards["deck1"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck1")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "parvink_inst"}))
	var p2_ai := ScriptedAI.new()

	_drive_turns(state, db, p1_ai, p2_ai, 3)

	# sc13-a: Parvink is in ally_row.
	var parv := state.get_card("parvink_inst")
	ok(parv != null and parv.zone_id == "p1_ally_row",
		"sc13-a: Parvink is in p1_ally_row")

	# sc13-b: deck card was drawn into p1 hand.
	var drawn := state.get_card("deck1")
	ok(drawn != null and drawn.zone_id == "p1_hand",
		"sc13-b: deck card drawn into p1_hand")

	# sc13-c: p1 hand has exactly 1 card (just the drawn one; Parvink left hand on play).
	eq(state.cards_in_zone("p1_hand").size(), 1,
		"sc13-c: p1 hand has exactly 1 card after draw")


func _test_vanquish() -> void:
	print("\n-- Scenario 14: Vanquish destroys target ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_ally_def", 3, 5, [], 5)   # p2 ally: cost 5, out of reach of combat
	db.instant("vanquish_def", 4, "destroy_target:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)

	# Put Vanquish in p1's hand.
	var vanquish := CardInstance.create("vanquish_inst", "vanquish_def", "p1", "p1_hand")
	state.cards["vanquish_inst"] = vanquish
	state.zones["p1_hand"].card_ids.append("vanquish_inst")

	# Put a big ally in p2's ally row.
	var big := CardInstance.create("big_ally_inst", "big_ally_def", "p2", "p2_ally_row")
	state.cards["big_ally_inst"] = big
	state.zones["p2_ally_row"].card_ids.append("big_ally_inst")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "vanquish_inst", "target_id": "big_ally_inst"}))
	var p2_ai := ScriptedAI.new()

	_drive_turns(state, db, p1_ai, p2_ai, 3)

	# sc14-a: target ally is in graveyard.
	var target := state.get_card("big_ally_inst")
	ok(target != null and target.zone_id == "p2_graveyard",
		"sc14-a: target ally moved to p2_graveyard")

	# sc14-b: Vanquish itself is in graveyard after resolution.
	var spell := state.get_card("vanquish_inst")
	ok(spell != null and spell.zone_id == "p1_graveyard",
		"sc14-b: Vanquish moved to p1_graveyard after resolution")

	# sc14-c: targeting a hero is rejected (destroy_target:ally = allies only).
	var p2_hero_id := (state.players.get("p2") as PlayerState).hero_instance_id
	var bad_action := PendingAction.make("play_instant", "p1",
		{"card_id": "vanquish_inst", "target_id": p2_hero_id})
	ok(not StackResolver.can_submit(state, bad_action, db),
		"sc14-c: Vanquish cannot target a hero")


func _test_timmo_hero_power() -> void:
	print("\n-- Scenario 15: Timmo Shadestep hero power destroys exhausted ally --")
	var db := MockDB.new()
	db.hero("timmo_def", 27, 5, "destroy_exhausted_ally")
	db.hero("p2_hero_def", 30)
	db.ally("target_def", 2, 3, [], 3)

	var state := _base_state(db, "timmo_def", "p2_hero_def")
	_add_resources(state, "p1", 5)

	# Put an exhausted ally in p2's row.
	var target := CardInstance.create("target_inst", "target_def", "p2", "p2_ally_row")
	target.is_exhausted = true
	state.cards["target_inst"] = target
	state.zones["p2_ally_row"].card_ids.append("target_inst")

	# Put a ready ally in p2's row (must NOT be a legal target).
	var ready_ally := CardInstance.create("ready_inst", "target_def", "p2", "p2_ally_row")
	ready_ally.is_exhausted = false
	state.cards["ready_inst"] = ready_ally
	state.zones["p2_ally_row"].card_ids.append("ready_inst")

	var timmo_id := (state.players.get("p1") as PlayerState).hero_instance_id

	# sc15-a: exhausted ally is a legal target.
	var good_action := PendingAction.make("activate_power", "p1",
		{"hero_id": timmo_id, "target_id": "target_inst"})
	ok(StackResolver.can_submit(state, good_action, db),
		"sc15-a: exhausted ally is a legal target for Timmo power")

	# sc15-b: ready ally is NOT a legal target.
	var bad_ready := PendingAction.make("activate_power", "p1",
		{"hero_id": timmo_id, "target_id": "ready_inst"})
	ok(not StackResolver.can_submit(state, bad_ready, db),
		"sc15-b: ready ally is not a legal target for Timmo power")

	# sc15-c: hero is NOT a legal target.
	var p2_hero_id := (state.players.get("p2") as PlayerState).hero_instance_id
	var bad_hero := PendingAction.make("activate_power", "p1",
		{"hero_id": timmo_id, "target_id": p2_hero_id})
	ok(not StackResolver.can_submit(state, bad_hero, db),
		"sc15-c: hero is not a legal target for Timmo power")

	# sc15-d: power resolves — exhausted ally is destroyed.
	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(good_action)
	var p2_ai := ScriptedAI.new()
	_drive_turns(state, db, p1_ai, p2_ai, 3)

	var destroyed := state.get_card("target_inst")
	ok(destroyed != null and destroyed.zone_id == "p2_graveyard",
		"sc15-d: exhausted ally moved to graveyard after Timmo power")


func _test_grennan_hero_power() -> void:
	print("\n-- Scenario 16: Grennan Stormspeaker hero power deals damage and heals --")
	var db := MockDB.new()
	db.hero("grennan_def", 29, 5, "deal_damage_and_heal:3:nature:3")
	db.hero("p2_hero_def", 30)
	db.ally("ally_def", 2, 3, [], 3)

	var state := _base_state(db, "grennan_def", "p2_hero_def")
	_add_resources(state, "p1", 5)

	# Put an ally in p2's row (damage target).
	var p2_ally := CardInstance.create("p2_ally_inst", "ally_def", "p2", "p2_ally_row")
	state.cards["p2_ally_inst"] = p2_ally
	state.zones["p2_ally_row"].card_ids.append("p2_ally_inst")

	# Put an ally in p1's row (heal target).
	var p1_ally := CardInstance.create("p1_ally_inst", "ally_def", "p1", "p1_ally_row")
	p1_ally.damage_taken = 2   # wounded so heal has visible effect
	state.cards["p1_ally_inst"] = p1_ally
	state.zones["p1_ally_row"].card_ids.append("p1_ally_inst")

	var grennan_id := (state.players.get("p1") as PlayerState).hero_instance_id
	var p2_hero_id := (state.players.get("p2") as PlayerState).hero_instance_id

	# sc16-a: untargeted activate_power is not legal.
	var no_target := PendingAction.make("activate_power", "p1",
		{"hero_id": grennan_id, "target_id": "", "heal_target_id": ""})
	ok(not StackResolver.can_submit(state, no_target, db),
		"sc16-a: untargeted Grennan power is illegal")

	# sc16-b: targeting p2 hero as dmg target + p1 ally as heal target is legal.
	var good_action := PendingAction.make("activate_power", "p1",
		{"hero_id": grennan_id, "target_id": p2_hero_id, "heal_target_id": "p1_ally_inst"})
	ok(StackResolver.can_submit(state, good_action, db),
		"sc16-b: hero dmg target + ally heal target is legal")

	# sc16-c: same target for both dmg and heal is illegal.
	var same_target := PendingAction.make("activate_power", "p1",
		{"hero_id": grennan_id, "target_id": p2_hero_id, "heal_target_id": p2_hero_id})
	ok(not StackResolver.can_submit(state, same_target, db),
		"sc16-c: same card for dmg and heal targets is illegal")

	# sc16-d: power resolves — p2 hero takes 3 damage, p1 ally heals 2 (capped at max).
	var p2_hero_hp_before := state.get_current_hp(p2_hero_id, db)
	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(good_action)
	var p2_ai := ScriptedAI.new()
	_drive_turns(state, db, p1_ai, p2_ai, 3)

	var p2_hero_card := state.get_card(p2_hero_id)
	eq(p2_hero_card.damage_taken, 3,
		"sc16-d: p2 hero took 3 damage from Grennan power")

	var p1_ally_card := state.get_card("p1_ally_inst")
	eq(p1_ally_card.damage_taken, 0,
		"sc16-e: p1 ally healed back to full (damage_taken=0)")
