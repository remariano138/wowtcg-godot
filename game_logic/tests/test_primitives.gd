extends Node

# Headless test for Phase 1 (state classes) and Phase 2 (primitive rules functions).
#
# HOW TO RUN:
#   In Godot editor: Scene > New Scene > add this script as the root node > Play Scene.
#   Results appear in the Output panel at the bottom. All lines should say PASS.
#   No internet, no assets, no scene tree required beyond this node.

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== WoW TCG Engine — Phase 1+2 Tests ===\n")

	_test_card_def()
	_test_card_instance_create()
	_test_buff()
	_test_card_instance_buffs()
	_test_counters()
	_test_zone()
	_test_game_state_zones()
	_test_move_card_basic()
	_test_move_card_graveyard_resets()
	_test_move_card_attachment_cleanup()
	_test_deal_damage_survives()
	_test_deal_damage_fatal()
	_test_heal()
	_test_exhaust_ready()
	_test_add_remove_buff()
	_test_set_counter()
	_test_derived_stats()
	_test_resource_helpers()
	_test_cards_in_play_includes_attachments()
	_test_damage_cap()
	_test_destroy_card()
	_test_discard_card()
	_test_out_of_play_guards()
	_test_serialization_roundtrip()

	print("\n=== Results: %d passed  %d failed ===" % [_pass, _fail])
	if _fail == 0:
		print("ALL TESTS PASSED ✓")
	else:
		print("SOME TESTS FAILED — see FAIL lines above")
	get_tree().quit()


# ── Assertion helpers ──────────────────────────────────────────────────────────

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
# Minimal stand-in for CardDatabase. Satisfies the duck-typed db parameter.

class MockDB extends RefCounted:
	var _defs: Dictionary = {}

	func add(id: String, atk: int, health: int, cost: int = 0) -> void:
		var d := CardDef.new()
		d.card_def_id    = id
		d.printed_atk    = atk
		d.printed_health = health
		d.cost           = cost
		_defs[id] = d

	func get_def(id: String) -> CardDef:
		return _defs.get(id)


# ── Shared setup ───────────────────────────────────────────────────────────────

func _make_state() -> GameState:
	var state := GameState.create_new(["p1", "p2"])
	return state

func _make_db() -> MockDB:
	var db := MockDB.new()
	db.add("ally_3_4", 3, 4)   # 3 ATK / 4 HP
	db.add("ally_2_2", 2, 2)
	db.add("hero_0_30", 0, 30)
	return db

func _add_card(state: GameState, instance_id: String, def_id: String,
		owner: String, zone_id: String) -> CardInstance:
	var card := CardInstance.create(instance_id, def_id, owner, zone_id)
	state.cards[instance_id] = card
	var zone := state.zones.get(zone_id) as Zone
	if zone:
		zone.card_ids.append(instance_id)
	return card


# ── Tests ──────────────────────────────────────────────────────────────────────

func _test_card_def() -> void:
	print("\n-- CardDef --")
	var row := {"name": "Test Ally", "type": "Ally", "atk": "3", "health": "4",
		"cost": "2", "keywords": "Protector, Ferocity", "alignment": "Alliance",
		"subtype": "Human Warrior", "effects": "", "image_path": "", "tags": "",
		"dmg_type": "Melee", "class": "Warrior", "power_text": ""}
	var d := CardDef.from_csv_row("test_001", row)
	eq(d.card_def_id,    "test_001",       "def: id")
	eq(d.card_name,      "Test Ally",      "def: name")
	eq(d.printed_atk,    3,                "def: atk")
	eq(d.printed_health, 4,                "def: health")
	eq(d.cost,           2,                "def: cost")
	ok(d.keywords.has("protector"),        "def: keyword protector (lowercased)")
	ok(d.keywords.has("ferocity"),         "def: keyword ferocity (lowercased)")

	var xrow := {"name": "X Spell", "type": "Ability", "atk": "", "health": "",
		"cost": "1+X", "keywords": "", "alignment": "", "subtype": "",
		"effects": "", "image_path": "", "tags": "", "dmg_type": "", "class": "", "power_text": ""}
	var xd := CardDef.from_csv_row("x_001", xrow)
	ok(xd.cost_x,         "def: cost_x flag")
	eq(xd.cost_base, 1,   "def: cost_base for 1+X")


func _test_card_instance_create() -> void:
	print("\n-- CardInstance.create --")
	var c := CardInstance.create("inst_001", "ally_3_4", "p1", "p1_hand")
	eq(c.instance_id, "inst_001",  "instance: id")
	eq(c.card_def_id, "ally_3_4", "instance: def_id")
	eq(c.owner,       "p1",       "instance: owner")
	eq(c.controller,  "p1",       "instance: controller defaults to owner")
	eq(c.zone_id,     "p1_hand",  "instance: zone_id")
	ok(not c.is_exhausted,        "instance: not exhausted at creation")
	ok(not c.face_down,           "instance: not face_down at creation")
	eq(c.damage_taken, 0,         "instance: no damage at creation")
	eq(c.attached_to,  "",        "instance: no attachment at creation")


func _test_buff() -> void:
	print("\n-- Buff --")
	var b := Buff.make("test_atk", "src_001", "atk", 2, "while_source_in_play")
	eq(b.buff_id,       "test_atk",            "buff: id")
	eq(b.source_id,     "src_001",             "buff: source")
	eq(b.stat,          "atk",                 "buff: stat")
	eq(b.amount,        2,                     "buff: amount")
	eq(b.duration_type, "while_source_in_play","buff: duration_type")

	var turn_buff := Buff.make("turn_buff", "src", "health", -1, "turns", 3)
	eq(turn_buff.turns_remaining, 3,           "buff: turns_remaining")

	var d := b.to_dict()
	var b2 := Buff.from_dict(d)
	eq(b2.buff_id, b.buff_id,                 "buff: serialization roundtrip")
	eq(b2.amount,  b.amount,                  "buff: serialization amount")


func _test_card_instance_buffs() -> void:
	print("\n-- CardInstance buff helpers --")
	var c := CardInstance.create("inst_buff", "ally_3_4", "p1", "p1_ally_row")
	c.active_buffs.append(Buff.make("aura_atk", "src_a", "atk", 2, "while_source_in_play"))
	c.active_buffs.append(Buff.make("berserk",  "inst_buff", "atk", 1, "while_source_in_play"))
	c.active_buffs.append(Buff.make("restrict", "src_b", "cannot_attack", 1, "turns", 1))

	eq(c.sum_stat("atk"),    3,    "buffs: sum_stat atk")
	eq(c.sum_stat("health"), 0,    "buffs: sum_stat health (none)")
	ok(c.has_restriction("cannot_attack"),   "buffs: has_restriction cannot_attack")
	ok(not c.has_restriction("cannot_protect"), "buffs: no cannot_protect restriction")

	c.remove_buffs_from_source("src_a")
	eq(c.sum_stat("atk"), 1,       "buffs: remove_buffs_from_source leaves others")
	eq(c.active_buffs.size(), 2,   "buffs: correct count after removal")

	# Turn decrement
	c.decrement_turn_buffs()
	ok(not c.has_restriction("cannot_attack"), "buffs: turns buff removed after decrement to 0")


func _test_counters() -> void:
	print("\n-- Counters --")
	var c := CardInstance.create("inst_cnt", "ally_3_4", "p1", "p1_ally_row")
	eq(c.counters.size(), 0,          "counters: empty at creation")
	c.counters["wind"] = 3
	eq(c.counters["wind"], 3,         "counters: set wind=3")
	c.counters["wind"] -= 1
	eq(c.counters["wind"], 2,         "counters: decrement to 2")


func _test_zone() -> void:
	print("\n-- Zone --")
	var z := Zone.make("p1_ally_row", "ally_row", "p1")
	eq(z.zone_id,   "p1_ally_row", "zone: id")
	eq(z.zone_type, "ally_row",    "zone: type")
	eq(z.owner,     "p1",         "zone: owner")
	ok(z.card_ids.is_empty(),      "zone: empty card_ids")


func _test_game_state_zones() -> void:
	print("\n-- GameState standard zones --")
	var state := _make_state()
	for pid in ["p1", "p2"]:
		for ztype in ["deck", "hand", "resource_row", "ally_row", "hero_row", "graveyard", "rfg"]:
			ok(state.zones.has(pid + "_" + ztype), "state: zone %s_%s exists" % [pid, ztype])
	ok(state.zones.has("attached"),                "state: shared attached zone exists")
	eq(state.players.size(), 2,                    "state: two players")


func _test_move_card_basic() -> void:
	print("\n-- move_card basic --")
	var state := _make_state()
	_add_card(state, "c1", "ally_3_4", "p1", "p1_hand")

	var events := GameLogic.move_card(state, "c1", "p1_ally_row")
	var card := state.get_card("c1")

	eq(card.zone_id, "p1_ally_row",              "move: card zone updated")
	ok(not state.zones["p1_hand"].card_ids.has("c1"),      "move: removed from source")
	ok(state.zones["p1_ally_row"].card_ids.has("c1"),      "move: added to dest")
	eq(events.size(), 1,                         "move: one event emitted")
	eq(events[0].event_type, "card_moved",       "move: event type")
	eq(events[0].payload["from"], "p1_hand",     "move: event from")
	eq(events[0].payload["to"],   "p1_ally_row", "move: event to")


func _test_move_card_graveyard_resets() -> void:
	print("\n-- move_card graveyard resets --")
	var state := _make_state()
	var card := _add_card(state, "c2", "ally_3_4", "p1", "p1_ally_row")
	card.is_exhausted = true
	card.damage_taken = 3

	var events := GameLogic.move_card(state, "c2", "p1_graveyard")
	ok(not card.is_exhausted,   "graveyard: exhausted cleared")
	eq(card.damage_taken, 0,    "graveyard: damage cleared")
	# Events: card_moved + card_readied
	var types := events.map(func(e: GameEvent) -> String: return e.event_type)
	ok(types.has("card_moved"),   "graveyard: card_moved event")
	ok(types.has("card_readied"), "graveyard: card_readied event")


func _test_move_card_attachment_cleanup() -> void:
	print("\n-- move_card attachment cleanup --")
	var state := _make_state()
	var host := _add_card(state, "host", "ally_3_4", "p1", "p1_ally_row")
	var attach := _add_card(state, "att", "ally_2_2", "p2", "attached")
	attach.attached_to = "host"
	host.attachments.append("att")

	# Move attachment to graveyard (e.g. Cyclone's counters ran out)
	GameLogic.move_card(state, "att", "p2_graveyard")
	eq(attach.attached_to, "",           "attachment: attached_to cleared on leave")
	ok(not host.attachments.has("att"),  "attachment: removed from host.attachments")
	eq(attach.zone_id, "p2_graveyard",   "attachment: zone updated")


func _test_deal_damage_survives() -> void:
	print("\n-- deal_damage (survives) --")
	var state := _make_state()
	var db    := _make_db()
	_add_card(state, "target", "ally_3_4", "p2", "p2_ally_row")  # 4 HP

	var events := GameLogic.deal_damage(state, "src", "target", 2, db)
	var card   := state.get_card("target")

	eq(card.damage_taken, 2,             "damage: damage_taken updated")
	eq(card.zone_id, "p2_ally_row",      "damage: card stays in play")
	var types := events.map(func(e: GameEvent) -> String: return e.event_type)
	ok(types.has("damage_dealt"),        "damage: damage_dealt event")
	ok(types.has("hp_changed"),          "damage: hp_changed event")
	ok(not types.has("card_destroyed"),  "damage: no destruction event")


func _test_deal_damage_fatal() -> void:
	print("\n-- deal_damage (fatal) --")
	var state := _make_state()
	var db    := _make_db()
	_add_card(state, "target", "ally_2_2", "p2", "p2_ally_row")  # 2 HP

	# deal_damage only places damage — it deliberately does NOT destroy the
	# target (see the doc comment on GameLogic.deal_damage): destruction is a
	# separate step so simultaneous combat can land both hits before either
	# fatality check runs. Every real call site (stack_resolver.gd) follows up
	# with check_destroyed/_check_destroyed_trigger — do the same here.
	var events := GameLogic.deal_damage(state, "src", "target", 2, db)
	var card   := state.get_card("target")

	eq(card.zone_id, "p2_ally_row",      "fatal: still in play after deal_damage alone")
	var types := events.map(func(e: GameEvent) -> String: return e.event_type)
	ok(types.has("damage_dealt"),        "fatal: damage_dealt event")
	ok(types.has("hp_changed"),          "fatal: hp_changed event")
	ok(not types.has("card_destroyed"),  "fatal: no destruction event from deal_damage alone")

	events.append_array(GameLogic.check_destroyed(state, "target", "src", db))

	eq(card.zone_id, "p2_graveyard",     "fatal: moved to graveyard after check_destroyed")
	types = events.map(func(e: GameEvent) -> String: return e.event_type)
	ok(types.has("card_destroyed"),      "fatal: card_destroyed event")
	ok(types.has("card_moved"),          "fatal: card_moved event")
	# Graveyard entry should have reset damage
	eq(card.damage_taken, 0,             "fatal: damage cleared on graveyard entry")


func _test_heal() -> void:
	print("\n-- heal --")
	var state := _make_state()
	var db    := _make_db()
	var card  := _add_card(state, "h1", "ally_3_4", "p1", "p1_ally_row")  # 4 HP
	card.damage_taken = 3  # at 1 HP

	var events := GameLogic.heal(state, "h1", 2, db)
	eq(card.damage_taken, 1,           "heal: partial heal")
	eq(events.size(), 1,               "heal: one event")
	eq(events[0].event_type, "hp_changed", "heal: hp_changed event")

	# Overheal: healing more than damage should cap at 0 damage
	GameLogic.heal(state, "h1", 10, db)
	eq(card.damage_taken, 0,           "heal: capped at full HP")

	# No-op on full HP
	var no_events := GameLogic.heal(state, "h1", 1, db)
	eq(no_events.size(), 0,            "heal: no event when already full")


func _test_exhaust_ready() -> void:
	print("\n-- exhaust_card / ready_card --")
	var state := _make_state()
	var card  := _add_card(state, "e1", "ally_3_4", "p1", "p1_ally_row")

	var e1 := GameLogic.exhaust_card(state, "e1")
	ok(card.is_exhausted,              "exhaust: card exhausted")
	eq(e1[0].event_type, "card_exhausted", "exhaust: event type")

	var e2 := GameLogic.exhaust_card(state, "e1")  # no-op
	eq(e2.size(), 0,                   "exhaust: no-op if already exhausted")

	var e3 := GameLogic.ready_card(state, "e1")
	ok(not card.is_exhausted,          "ready: card readied")
	eq(e3[0].event_type, "card_readied", "ready: event type")

	var e4 := GameLogic.ready_card(state, "e1")  # no-op
	eq(e4.size(), 0,                   "ready: no-op if already ready")


func _test_add_remove_buff() -> void:
	print("\n-- add_buff / remove_buffs_from_source --")
	var state := _make_state()
	_add_card(state, "b1", "ally_3_4", "p1", "p1_ally_row")

	var buff := Buff.make("zorm_atk", "zorm_inst", "atk", 1, "while_source_in_play")
	var e1 := GameLogic.add_buff(state, "b1", buff)
	eq(e1[0].event_type, "buff_added",   "buff_add: event type")
	eq(state.get_card("b1").sum_stat("atk"), 1, "buff_add: stat applied")

	var e2 := GameLogic.remove_buffs_from_source(state, "b1", "zorm_inst")
	eq(e2[0].event_type, "buff_removed", "buff_remove: event type")
	eq(state.get_card("b1").sum_stat("atk"), 0, "buff_remove: stat gone")


func _test_set_counter() -> void:
	print("\n-- set_counter --")
	var state := _make_state()
	_add_card(state, "cyc", "ally_2_2", "p2", "attached")

	var e1 := GameLogic.set_counter(state, "cyc", "wind", 3)
	eq(e1[0].payload["new"], 3,           "counter: set to 3")
	eq(state.get_card("cyc").counters["wind"], 3, "counter: stored")

	var e2 := GameLogic.set_counter(state, "cyc", "wind", 2)
	eq(e2[0].payload["old"], 3,           "counter: old value in event")
	eq(e2[0].payload["new"], 2,           "counter: new value in event")

	# Setting to 0 removes the key
	GameLogic.set_counter(state, "cyc", "wind", 0)
	ok(not state.get_card("cyc").counters.has("wind"), "counter: key removed at 0")

	# No-op if value unchanged
	GameLogic.set_counter(state, "cyc", "charge", 1)
	var e3 := GameLogic.set_counter(state, "cyc", "charge", 1)
	eq(e3.size(), 0,                      "counter: no event if unchanged")


func _test_derived_stats() -> void:
	print("\n-- derived stats (get_atk / get_current_hp) --")
	var state := _make_state()
	var db    := _make_db()
	var card  := _add_card(state, "d1", "ally_3_4", "p1", "p1_ally_row")  # 3 ATK / 4 HP

	eq(state.get_atk("d1", db),        3, "derived: base atk")
	eq(state.get_max_hp("d1", db),     4, "derived: base max_hp")
	eq(state.get_current_hp("d1", db), 4, "derived: full current_hp")

	card.active_buffs.append(Buff.make("bonus", "src", "atk", 2, "permanent"))
	eq(state.get_atk("d1", db), 5,        "derived: atk with buff")

	card.damage_taken = 2
	eq(state.get_current_hp("d1", db), 2, "derived: current_hp after damage")

	card.active_buffs.append(Buff.make("hp_pen", "src2", "health", -1, "permanent"))
	eq(state.get_max_hp("d1", db),     3, "derived: max_hp with health debuff")
	eq(state.get_current_hp("d1", db), 1, "derived: current_hp with debuff + damage")


func _test_resource_helpers() -> void:
	print("\n-- resource helpers --")
	var state := _make_state()
	_add_card(state, "r1", "ally_3_4", "p1", "p1_resource_row")
	_add_card(state, "r2", "ally_2_2", "p1", "p1_resource_row")
	state.get_card("r1").face_down = true
	state.get_card("r2").face_down = true

	eq(state.get_total_resources("p1"),     2, "resources: total count")
	eq(state.get_available_resources("p1"), 2, "resources: both ready")

	GameLogic.exhaust_card(state, "r1")
	eq(state.get_available_resources("p1"), 1, "resources: one exhausted")

	# Face-up quest: add a face-up card to resource row
	var q := _add_card(state, "q1", "ally_3_4", "p1", "p1_resource_row")
	q.face_down = false
	eq(state.get_face_up_resources("p1").size(), 1, "resources: one face-up")
	eq(state.count_face_up_resources_by_def("p1", "ally_3_4"), 1, "resources: quest count by def")


func _test_cards_in_play_includes_attachments() -> void:
	print("\n-- cards_in_play includes attachments --")
	var state := _make_state()
	_add_card(state, "ally1", "ally_3_4", "p1", "p1_ally_row")
	var cyclone := _add_card(state, "cyc", "ally_2_2", "p2", "attached")
	cyclone.controller = "p2"

	var p1_play := state.cards_in_play("p1")
	var p2_play := state.cards_in_play("p2")

	ok(p1_play.any(func(c: CardInstance) -> bool: return c.instance_id == "ally1"),
		"in_play: p1 ally included")
	ok(p2_play.any(func(c: CardInstance) -> bool: return c.instance_id == "cyc"),
		"in_play: p2 attachment (Cyclone) included")
	ok(not p1_play.any(func(c: CardInstance) -> bool: return c.instance_id == "cyc"),
		"in_play: Cyclone not in p1 play (controller=p2)")


func _test_damage_cap() -> void:
	print("\n-- damage cap (rule 405.3) --")
	var state := _make_state()
	var db    := _make_db()
	var card  := _add_card(state, "cap1", "ally_2_2", "p1", "p1_ally_row")  # 2 HP
	card.damage_taken = 1  # 1 HP remaining

	var events := GameLogic.deal_damage(state, "src", "cap1", 5, db)
	# Only 1 damage should be placed (fatal), excess lost
	var dmg_event: GameEvent = null
	for e in events:
		if e.event_type == "damage_dealt":
			dmg_event = e
	ok(dmg_event != null,                    "cap: damage_dealt event fired")
	eq(dmg_event.payload["amount"], 1,       "cap: reported amount is capped (1, not 5)")
	# card moved to graveyard (damage_taken cleared there) — check via events instead
	ok(events.any(func(e: GameEvent) -> bool:
		return e.event_type == "damage_dealt" and e.payload["amount"] == 1),
		"cap: only 1 damage placed (not 6)")
	# deal_damage doesn't destroy on its own (see _test_deal_damage_fatal) — the
	# caller runs check_destroyed as a separate state-based check.
	events.append_array(GameLogic.check_destroyed(state, "cap1", "src", db))
	ok(events.any(func(e: GameEvent) -> bool: return e.event_type == "card_destroyed"),
		"cap: card destroyed at fatal via check_destroyed")


func _test_destroy_card() -> void:
	print("\n-- destroy_card (rule 415.9d) --")
	var state := _make_state()
	var card  := _add_card(state, "d1", "ally_3_4", "p1", "p1_ally_row")
	card.damage_taken = 2  # has some damage — should arrive in graveyard clean

	var events := GameLogic.destroy_card(state, "d1", "some_effect")
	eq(card.zone_id, "p1_graveyard",         "destroy: moved to owner graveyard")
	ok(events.any(func(e: GameEvent) -> bool: return e.event_type == "card_destroyed"),
		"destroy: card_destroyed event")
	ok(events.any(func(e: GameEvent) -> bool: return e.event_type == "card_moved"),
		"destroy: card_moved event")
	ok(not events.any(func(e: GameEvent) -> bool: return e.event_type == "damage_dealt"),
		"destroy: no damage_dealt event")
	eq(card.damage_taken, 0,                 "destroy: damage cleared on graveyard entry")

	# Cannot destroy a card not in play
	_add_card(state, "hand1", "ally_2_2", "p1", "p1_hand")
	var e2 := GameLogic.destroy_card(state, "hand1")
	eq(e2.size(), 0,                         "destroy: no-op on card in hand")


func _test_discard_card() -> void:
	print("\n-- discard_card (rule 415.9e) --")
	var state := _make_state()
	_add_card(state, "h1", "ally_3_4", "p1", "p1_hand")

	var events := GameLogic.discard_card(state, "h1")
	var card   := state.get_card("h1")
	eq(card.zone_id, "p1_graveyard",         "discard: moved to owner graveyard")
	ok(events.any(func(e: GameEvent) -> bool: return e.event_type == "card_revealed"),
		"discard: card_revealed event fired")
	ok(events.any(func(e: GameEvent) -> bool: return e.event_type == "card_moved"),
		"discard: card_moved event")

	# Cannot discard a card in play
	_add_card(state, "a1", "ally_2_2", "p1", "p1_ally_row")
	var e2 := GameLogic.discard_card(state, "a1")
	eq(e2.size(), 0,                         "discard: no-op on card in play")


func _test_out_of_play_guards() -> void:
	print("\n-- out-of-play guards --")
	var state := _make_state()
	var db    := _make_db()
	_add_card(state, "hand_card", "ally_3_4", "p1", "p1_hand")

	var e1 := GameLogic.exhaust_card(state, "hand_card")
	eq(e1.size(), 0,   "guard: cannot exhaust card in hand")

	var e2 := GameLogic.deal_damage(state, "src", "hand_card", 2, db)
	eq(e2.size(), 0,   "guard: cannot damage card in hand")

	var e3 := GameLogic.ready_card(state, "hand_card")
	eq(e3.size(), 0,   "guard: ready no-ops on non-exhausted (also out of play)")

	var e5 := GameLogic.heal(state, "hand_card", 1, db)
	eq(e5.size(), 0,   "guard: cannot heal card in hand")

	# Graveyard is also out of play
	_add_card(state, "gy_card", "ally_2_2", "p1", "p1_graveyard")
	var e4 := GameLogic.deal_damage(state, "src", "gy_card", 1, db)
	eq(e4.size(), 0,   "guard: cannot damage card in graveyard")


func _test_serialization_roundtrip() -> void:
	print("\n-- serialization roundtrip --")
	var state := _make_state()
	var db    := _make_db()
	var card  := _add_card(state, "s1", "ally_3_4", "p1", "p1_ally_row")
	card.damage_taken = 2
	card.is_exhausted = true
	card.active_buffs.append(Buff.make("test_buf", "src", "atk", 1, "turns", 2))
	card.counters["wind"] = 3
	card.granted_keywords.append("elusive")

	var dict   := state.to_dict()
	var state2 := GameState.from_dict(dict)
	var card2  := state2.get_card("s1")

	eq(card2.damage_taken,  2,         "serial: damage_taken")
	ok(card2.is_exhausted,             "serial: is_exhausted")
	eq(card2.active_buffs.size(), 1,   "serial: buff count")
	eq(card2.active_buffs[0].buff_id, "test_buf", "serial: buff_id")
	eq(card2.active_buffs[0].turns_remaining, 2,   "serial: turns_remaining")
	eq(card2.counters.get("wind", 0), 3, "serial: counter")
	ok(card2.granted_keywords.has("elusive"), "serial: granted_keywords")
	eq(state2.zones["p1_ally_row"].card_ids.size(), 1, "serial: zone card_ids")
	eq(state2.get_current_hp("s1", db), 2, "serial: derived HP after roundtrip")
