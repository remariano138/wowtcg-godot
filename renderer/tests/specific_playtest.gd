extends "res://renderer/tests/playtest.gd"

# ── Specific repro scene ────────────────────────────────────────────────────────
#
# Puts P1 (human) at a combat ATTACK WINDOW where the ONLY legal response is
# Elder Moorf's activated power ("(1) -> target ally has +2 ATK this turn").
#
# WHY: in a real game you'd have to draw + play Elder Moorf and then be attacked
# with nothing else to do — rare and slow. This scene guarantees the exact state
# so you can verify the power is recognised as a legal play (the window HOLDS and
# Elder Moorf highlights green) rather than being Turbo-skipped.
#
# HOW TO RUN: open specific_playtest.tscn > Play Scene. It skips the menu.
#
# WHAT TO LOOK FOR (press L for the game log):
#   FIXED  → log shows "priority held for you (attack window opened)" and Elder
#            Moorf lights up green. Right-click it → "Activate Power" is enabled.
#   BUG    → log shows "Turbo skipped attack window opened (no legal response)"
#            and combat marches on to damage without stopping. That means the
#            engine still doesn't count Elder Moorf's power as a legal play —
#            check whether P1 has ready (unexhausted) resources at that moment.

const MOORF_DEF    := "azeroth_235"   # Elder Moorf, 1/1 — power: (1) target ally +2 ATK, once/turn
const ATTACKER_DEF := "azeroth_192"   # Kor Cindervein, 3/3 vanilla — the AI's attacker
const P1_DECK := "alliance_boris_test"
const P2_DECK := "horde_tazo_test"


func _ready() -> void:
	super._ready()
	# Skip the menu — jump straight into the scripted scenario.
	if _menu_layer:
		_menu_layer.visible = false
	_p1_type = "human"
	_p2_type = "recommended"
	_p1_ai   = null
	_p2_ai   = _make_ai("recommended", P2_DECK)   # so the AI can act once you pass
	_last_p1_deck_id = P1_DECK
	_last_p2_deck_id = P2_DECK
	_setup_specific_scenario()


func _setup_specific_scenario() -> void:
	# ── Database (real cards + the mock instants the parent scene expects) ─────
	_db = CardDatabase.new()
	_db.load_csv("res://data/cards.csv")
	_db.add_def(_make_mock_def("mock_quick_shot", "Quick Shot", 0, 0, true, "Ability"))
	_db.add_def(_make_mock_def("mock_dark_bolt",  "Dark Bolt",  0, 0, true, "Ability"))

	# ── Base game (heroes, decks, 7-card hands) via GameManager ──────────────
	_gm = GameManager.new()
	_gm.setup(_db)
	_gm.add_player("p1", GameManager.HUMAN, DeckManager.get_runtime_deck(P1_DECK))
	_gm.add_player("p2", GameManager.AI,    DeckManager.get_runtime_deck(P2_DECK))
	_state = _gm.build_state()

	# ── Transform into the scenario BEFORE any card nodes are spawned ────────
	# 1. Empty both hands (into their decks) so no hand card is a legal play.
	for pid in ["p1", "p2"]:
		var hand := _state.zones[pid + "_hand"] as Zone
		var deck := _state.zones[pid + "_deck"] as Zone
		for cid in hand.card_ids.duplicate():
			_state.get_card(cid).zone_id = pid + "_deck"
			deck.card_ids.append(cid)
		hand.card_ids.clear()

	# 2. Give P1 three READY resources (pulled from the deck so they carry real
	#    defs). Elder Moorf's power costs 1 — this guarantees affordability.
	var p1_deck := _state.zones["p1_deck"] as Zone
	var p1_res  := _state.zones["p1_resource_row"] as Zone
	for _i in range(3):
		var cid: String = p1_deck.card_ids.pop_back()
		var c := _state.get_card(cid)
		c.zone_id      = "p1_resource_row"
		c.face_down    = true
		c.is_exhausted = false
		p1_res.card_ids.append(cid)
	_state.players["p1"].resource_placed_this_turn = true

	# 3. Elder Moorf into P1's ally row — ready, no summoning sickness, unused.
	var moorf := CardInstance.create("scn_moorf", MOORF_DEF, "p1", "p1_ally_row")
	moorf.just_summoned  = false
	moorf.is_exhausted   = false
	moorf.used_this_turn = false
	_state.cards["scn_moorf"] = moorf
	_state.zones["p1_ally_row"].card_ids.append("scn_moorf")

	# 4. The AI's attacker into P2's ally row — exhausted (an attacker exhausts as
	#    combat starts) with no summoning sickness.
	var attacker := CardInstance.create("scn_attacker", ATTACKER_DEF, "p2", "p2_ally_row")
	attacker.just_summoned = false
	attacker.is_exhausted  = true
	_state.cards["scn_attacker"] = attacker
	_state.zones["p2_ally_row"].card_ids.append("scn_attacker")

	# ── Renderer: deck counts, card nodes for every visible zone, HP bars ─────
	for pid in ["p1", "p2"]:
		var dz := _state.zones.get(pid + "_deck") as Zone
		if dz:
			_renderer.init_deck_count(pid + "_deck", dz.card_ids.size())
	for zone_id in ["p1_hero_row", "p1_hand", "p1_ally_row", "p1_resource_row", "p1_graveyard",
					"p2_hero_row", "p2_hand", "p2_ally_row", "p2_resource_row", "p2_graveyard",
					"chain"]:
		var color := Color(0.25, 0.45, 0.75) if zone_id.begins_with("p1") else Color(0.5, 0.25, 0.25)
		if zone_id == "chain":
			color = Color(1.0, 1.0, 1.0)
		_spawn_zone_nodes(zone_id, color)
	for pid in ["p1", "p2"]:
		var ps := _state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			_renderer.register_hero_card(pid, ps.hero_instance_id)
			_renderer.init_hero_bar(pid, ps.hero_instance_id, _state.get_max_hp(ps.hero_instance_id, _db))
	_renderer.relayout_zone("p1_ally_row")
	_renderer.relayout_zone("p2_ally_row")
	_renderer.relayout_zone("p1_resource_row")

	_router.setup(_state, _db, "p1")

	# ── Fabricate the combat state: P2's attacker is mid-attack on P1's hero,
	#    the attack window is open, and P1 (human) holds priority — the exact
	#    moment Elder Moorf's power should be offered. ─────────────────────────
	var p1_hero: String = _state.players["p1"].hero_instance_id
	_state.turn_player          = "p2"
	_state.phase                = "action"
	_state.combat_attacker      = "scn_attacker"
	_state.combat_defender      = p1_hero
	_state.combat_attack_window = true
	_state.priority_player      = "p1"
	_state.consecutive_passes   = 1   # P2 (turn player) already passed in this window

	_log_entry("[color=#8cf][b]Scenario:[/b] P2's Kor Cindervein is attacking your hero.[/color]")
	_log_entry("[color=#8cf]Your ONLY legal play is Elder Moorf's power. It should highlight green and hold the window.[/color]")

	# Emit the visual combat events; their handlers refresh highlights and run the
	# priority-hold logic (_drain_passes). If the fix works the window holds here.
	EventBus.emit_events([
		GameEvent.combat_started("scn_attacker", p1_hero),
		GameEvent.attack_window_opened("scn_attacker", p1_hero),
	])
	_refresh_ui()
	_drain_passes()
