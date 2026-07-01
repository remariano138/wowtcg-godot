extends Node

# Headless test for Phase 4: priority / chain (interrupt stack).
#
# HOW TO RUN:
#   Scene > New Scene > add this script as root node > Play Scene.
#   Results appear in the Output panel. All lines should say PASS.

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== WoW TCG Engine — Phase 4 Stack Tests ===\n")

	_test_submit_basic()
	_test_consecutive_passes_resolve()
	_test_interrupt_stack()
	_test_fizzle()
	_test_wrong_priority_rejected()
	_test_empty_chain_window_close()
	_test_pending_action_serialization()

	print("\n=== Results: %d passed  %d failed ===" % [_pass, _fail])
	if _fail == 0:
		print("ALL TESTS PASSED ✓")
	else:
		print("SOME TESTS FAILED — see FAIL lines above")
	get_tree().quit()


# ── Assertion helpers ──────────────────────────────────────────────────────────

func ok(cond: bool, name: String) -> void:
	if cond:
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


# ── Shared setup ───────────────────────────────────────────────────────────────

func _make_state() -> GameState:
	var state := GameState.create_new(["p1", "p2"])
	state.turn_number     = 1
	state.turn_player     = "p1"
	state.priority_player = "p1"
	state.phase           = "action"
	return state

func _add_card(state: GameState, instance_id: String, def_id: String,
		owner: String, zone_id: String) -> CardInstance:
	var card := CardInstance.create(instance_id, def_id, owner, zone_id)
	state.cards[instance_id] = card
	var zone := state.zones.get(zone_id) as Zone
	if zone:
		zone.card_ids.append(instance_id)
	return card


# ── Tests ──────────────────────────────────────────────────────────────────────

func _test_submit_basic() -> void:
	print("\n-- submit_action basic --")
	var state := _make_state()
	_add_card(state, "ally1", "ally_def", "p1", "p1_hand")

	var action := PendingAction.make("play_ally", "p1", {"card_id": "ally1"})
	var events := StackResolver.submit_action(state, action)

	# submit now emits card_moved (hand→chain) + action_proposed
	ok(events.any(func(e: GameEvent) -> bool: return e.event_type == "card_moved"),
		"submit: card_moved event (hand → chain)")
	ok(events.any(func(e: GameEvent) -> bool: return e.event_type == "action_proposed"),
		"submit: action_proposed event")
	var proposed := events.filter(func(e: GameEvent) -> bool: return e.event_type == "action_proposed")
	eq(proposed[0].payload["action_type"], "play_ally", "submit: payload action_type")
	# Rule 409.1: card moved to chain zone on proposal.
	eq(state.get_card("ally1").zone_id, "chain",  "submit: card now in chain zone")
	eq(state.pending_actions.size(), 1,    "submit: action on pending stack")
	eq(state.consecutive_passes, 0,        "submit: consecutive_passes reset")
	eq(state.priority_player, "p1",        "submit: proposer keeps priority (410.1)")


func _test_consecutive_passes_resolve() -> void:
	print("\n-- consecutive passes → resolve --")
	var state := _make_state()
	_add_card(state, "ally1", "ally_def", "p1", "p1_hand")

	# P1 submits play_ally.
	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1", {"card_id": "ally1"}))
	eq(state.pending_actions.size(), 1, "resolve: action on chain after submit")
	eq(state.priority_player, "p1",    "resolve: p1 has priority")

	# P1 passes → consecutive_passes=1, priority → P2.
	var e1 := StackResolver.pass_priority(state)
	eq(state.consecutive_passes, 1,        "resolve: consecutive=1 after p1 pass")
	eq(state.priority_player, "p2",        "resolve: priority flipped to p2")
	eq(e1[0].event_type, "priority_passed","resolve: priority_passed event")

	# P2 passes → consecutive_passes=2, chain resolves.
	var e2 := StackResolver.pass_priority(state)
	eq(state.pending_actions.size(), 0,    "resolve: chain empty after resolve")
	eq(state.consecutive_passes, 0,        "resolve: consecutive_passes reset")
	eq(state.priority_player, "p1",        "resolve: turn_player gets priority after resolve")

	# Resolution moved the ally to the ally row.
	var card := state.get_card("ally1")
	eq(card.zone_id, "p1_ally_row",        "resolve: ally in play after resolve")
	ok(card.just_summoned,                 "resolve: just_summoned set")
	ok(e2.any(func(e: GameEvent) -> bool: return e.event_type == "card_moved"),
		"resolve: card_moved event emitted")


func _test_interrupt_stack() -> void:
	print("\n-- interrupt stack (two actions, inner resolves first) --")
	var state := _make_state()
	_add_card(state, "ally1", "ally_def", "p1", "p1_hand")
	_add_card(state, "intr1", "inst_def", "p2", "p2_hand")

	# P1 proposes play_ally → P1 keeps priority.
	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1", {"card_id": "ally1"}))
	eq(state.priority_player, "p1",          "interrupt: p1 still has priority")

	# P1 passes → priority → P2.
	StackResolver.pass_priority(state)
	eq(state.priority_player, "p2",          "interrupt: priority passed to p2")

	# P2 proposes instant (interrupt) → P2 keeps priority.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2", {"card_id": "intr1"}))
	eq(state.pending_actions.size(), 2,      "interrupt: two links on chain")
	eq(state.priority_player, "p2",          "interrupt: p2 keeps priority after interrupt")
	eq(state.consecutive_passes, 0,          "interrupt: consecutive_passes reset by new action")

	# P2 passes → consecutive=1 → P1.
	StackResolver.pass_priority(state)
	eq(state.consecutive_passes, 1,          "interrupt: consecutive=1")
	eq(state.priority_player, "p1",          "interrupt: priority → p1")

	# P1 passes → consecutive=2 → INNER action (instant) resolves first.
	var e := StackResolver.pass_priority(state)
	eq(state.pending_actions.size(), 1,      "interrupt: inner resolved, outer remains")
	eq(state.priority_player, "p1",          "interrupt: turn_player gets priority")
	ok(e.any(func(ev: GameEvent) -> bool: return ev.event_type == "instant_resolved"),
		"interrupt: instant_resolved event")

	# Now resolve the outer action: P1 passes, P2 passes.
	StackResolver.pass_priority(state)       # P1 → consecutive=1, priority → P2
	var e2 := StackResolver.pass_priority(state)  # P2 → consecutive=2, play_ally resolves
	eq(state.pending_actions.size(), 0,      "interrupt: outer resolved, chain empty")
	ok(e2.any(func(ev: GameEvent) -> bool: return ev.event_type == "card_moved"),
		"interrupt: outer play_ally card_moved")


func _test_fizzle() -> void:
	print("\n-- action fizzles when card leaves hand --")
	var state := _make_state()
	_add_card(state, "ally1", "ally_def", "p1", "p1_hand")

	# P1 proposes play_ally → card moves to chain zone.
	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1", {"card_id": "ally1"}))
	eq(state.get_card("ally1").zone_id, "chain", "fizzle: card in chain after submit")

	# Before it resolves, move the card out of chain (e.g. destroyed by interrupt).
	GameLogic.move_card(state, "ally1", "p1_graveyard")

	# Both players pass → action resolves but fizzles.
	StackResolver.pass_priority(state)
	var e := StackResolver.pass_priority(state)
	ok(e.any(func(ev: GameEvent) -> bool: return ev.event_type == "action_fizzled"),
		"fizzle: action_fizzled event when card not in chain at resolution")
	var card := state.get_card("ally1")
	eq(card.zone_id, "p1_graveyard",        "fizzle: card stays in graveyard")


func _test_wrong_priority_rejected() -> void:
	print("\n-- action rejected when not your priority --")
	var state := _make_state()
	_add_card(state, "ally2", "ally_def", "p2", "p2_hand")

	# P2 tries to submit while P1 has priority — should be rejected.
	var action := PendingAction.make("play_ally", "p2", {"card_id": "ally2"})
	var events := StackResolver.submit_action(state, action)

	eq(events.size(), 0,                    "wrong_priority: rejected (no events)")
	eq(state.pending_actions.size(), 0,     "wrong_priority: chain still empty")
	eq(state.priority_player, "p1",         "wrong_priority: priority unchanged")


func _test_empty_chain_window_close() -> void:
	print("\n-- empty chain: all pass → window closes (410.4b) --")
	var state := _make_state()
	# No actions proposed — chain is empty from the start.

	# P1 passes → consecutive=1, priority → P2.
	var e1 := StackResolver.pass_priority(state)
	eq(e1[0].event_type, "priority_passed", "window_close: first pass flips priority")
	eq(state.priority_player, "p2",         "window_close: p2 gets priority")

	# P2 passes → consecutive=2, chain empty → window closes.
	var e2 := StackResolver.pass_priority(state)
	eq(e2[0].event_type, "priority_window_closed", "window_close: window_closed event")
	eq(e2[0].payload["phase"], "action",    "window_close: payload has phase")
	eq(state.consecutive_passes, 0,         "window_close: consecutive_passes reset")
	eq(state.priority_player, "p1",         "window_close: turn_player gets priority")


func _test_pending_action_serialization() -> void:
	print("\n-- PendingAction serialization roundtrip --")
	var a := PendingAction.make("play_ally", "p1", {"card_id": "ally1", "target": "p2_hero"})
	var d := a.to_dict()
	var a2 := PendingAction.from_dict(d)

	eq(a2.action_type,   "play_ally",  "serial: action_type")
	eq(a2.source_player, "p1",         "serial: source_player")
	eq(a2.params.get("card_id", ""),   "ally1", "serial: params card_id")
	eq(a2.params.get("target", ""),    "p2_hero","serial: params target")
