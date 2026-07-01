extends Node2D

# Phase 3 visual test — proves the event-driven renderer architecture.
#
# HOW TO RUN:
#   Scene > New Scene > Node2D root > attach this script > Play Scene.
#
# WHAT TO EXPECT:
#   A blue card rectangle sitting in "p1_hand" (left zone).
#   Four buttons at the bottom.
#   - "Play to ally row"  : card slides to the right zone
#   - "Exhaust"           : card rotates 90°
#   - "Ready"             : card rotates back
#   - "Deal 2 damage"     : red "-2" floats up from the card
#
# WHAT THIS PROVES:
#   The test logic never touches the card node directly.
#   It calls GameLogic → gets events → hands them to EventBus.
#   BoardRenderer reacts and animates. Zero direct node manipulation.

var _state: GameState
var _db: _MockDB
var _card_id := "phase3_card"

# Zone anchor nodes — also used by the renderer
var _zone_hand: Node2D
var _zone_ally: Node2D
var _card_visual: Node2D


func _ready() -> void:
	_build_scene()
	_setup_game_state()


# ── Scene construction ─────────────────────────────────────────────────────────

func _build_scene() -> void:
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.14, 0.16)
	bg.size  = Vector2(1600, 1200)
	add_child(bg)

	# Zone A — hand (left)
	_zone_hand = _make_zone_anchor(Vector2(420, 500), "p1_hand")

	# Zone B — ally row (right)
	_zone_ally = _make_zone_anchor(Vector2(1000, 500), "p1_ally_row")

	# Card visual — starts at hand position
	_card_visual = _make_card_visual(Vector2(380, 445), "Test Ally", "3 / 4")

	# Renderer — registered after nodes exist
	var renderer := BoardRenderer.new()
	add_child(renderer)
	renderer.register_zone("p1_hand",     _zone_hand)
	renderer.register_zone("p1_ally_row", _zone_ally)
	renderer.register_zone("p1_graveyard", _make_zone_anchor(Vector2(200, 500), "p1_graveyard"))
	renderer.register_card(_card_id, _card_visual)

	# Buttons
	_make_button("Play to ally row", Vector2(400,  750), _on_play_pressed)
	_make_button("Exhaust",          Vector2(620,  750), _on_exhaust_pressed)
	_make_button("Ready",            Vector2(780,  750), _on_ready_pressed)
	_make_button("Deal 2 damage",    Vector2(900,  750), _on_damage_pressed)
	_make_button("Destroy (in play)",Vector2(1080, 750), _on_destroy_pressed)
	_make_button("Discard (hand)",   Vector2(1270, 750), _on_discard_pressed)

	# Title
	var title := Label.new()
	title.text = "Phase 3 — Event Bus + Renderer test"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	title.position = Vector2(30, 20)
	add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Buttons call GameLogic → emit events → BoardRenderer animates. No direct node manipulation."
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	subtitle.position = Vector2(30, 50)
	add_child(subtitle)


func _make_zone_anchor(pos: Vector2, zone_id: String) -> Node2D:
	var anchor := Node2D.new()
	anchor.global_position = pos
	add_child(anchor)

	# Visual indicator for the zone
	var rect := ColorRect.new()
	rect.size     = Vector2(120, 160)
	rect.position = Vector2(-60, -80)
	rect.color    = Color(0.2, 0.25, 0.3, 0.6)
	anchor.add_child(rect)

	var label := Label.new()
	label.text = zone_id
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
	label.position = Vector2(-55, 88)
	anchor.add_child(label)

	return anchor


func _make_card_visual(pos: Vector2, card_name: String, stats: String) -> Node2D:
	var pivot := Node2D.new()
	pivot.global_position = pos + Vector2(40, 55)  # pivot at card centre
	add_child(pivot)

	var rect := ColorRect.new()
	rect.size     = Vector2(80, 110)
	rect.position = Vector2(-40, -55)
	rect.color    = Color(0.25, 0.45, 0.75)
	pivot.add_child(rect)

	var border := ColorRect.new()
	border.size     = Vector2(76, 106)
	border.position = Vector2(-38, -53)
	border.color    = Color(0.15, 0.3, 0.55)
	pivot.add_child(border)

	var name_label := Label.new()
	name_label.text = card_name
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.position = Vector2(-35, -50)
	pivot.add_child(name_label)

	var stats_label := Label.new()
	stats_label.text = stats
	stats_label.add_theme_font_size_override("font_size", 14)
	stats_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	stats_label.position = Vector2(-20, 25)
	pivot.add_child(stats_label)

	return pivot


func _make_button(label: String, pos: Vector2, callback: Callable) -> void:
	var btn := Button.new()
	btn.text     = label
	btn.position = pos
	btn.pressed.connect(callback)
	add_child(btn)


# ── Game state setup ───────────────────────────────────────────────────────────

func _setup_game_state() -> void:
	_state = GameState.create_new(["p1", "p2"])
	_db    = _MockDB.new()
	_db.add("ally_3_4", 3, 4)

	var card := CardInstance.create(_card_id, "ally_3_4", "p1", "p1_hand")
	_state.cards[_card_id] = card
	_state.zones["p1_hand"].card_ids.append(_card_id)


# ── Button handlers — GameLogic only, no node access ──────────────────────────

func _on_play_pressed() -> void:
	var events := GameLogic.move_card(_state, _card_id, "p1_ally_row")
	EventBus.emit_events(events)

func _on_exhaust_pressed() -> void:
	var events := GameLogic.exhaust_card(_state, _card_id)
	EventBus.emit_events(events)

func _on_ready_pressed() -> void:
	var events := GameLogic.ready_card(_state, _card_id)
	EventBus.emit_events(events)

func _on_damage_pressed() -> void:
	var events := GameLogic.deal_damage(_state, "src", _card_id, 2, _db)
	EventBus.emit_events(events)

func _on_destroy_pressed() -> void:
	# Rule 415.9d: destroy moves from play to graveyard, no damage events.
	var events := GameLogic.destroy_card(_state, _card_id, "test_effect")
	EventBus.emit_events(events)

func _on_discard_pressed() -> void:
	# Rule 415.9e: discard reveals from hand then moves to graveyard.
	# Move card back to hand first if it's not there already.
	var card := _state.get_card(_card_id)
	if card and card.zone_id != "p1_hand":
		EventBus.emit_events(GameLogic.move_card(_state, _card_id, "p1_hand"))
	var events := GameLogic.discard_card(_state, _card_id)
	EventBus.emit_events(events)


# ── Mock database (same pattern as headless test) ─────────────────────────────

class _MockDB extends RefCounted:
	var _defs: Dictionary = {}
	func add(id: String, atk: int, health: int) -> void:
		var d := CardDef.new()
		d.card_def_id    = id
		d.printed_atk    = atk
		d.printed_health = health
		_defs[id] = d
	func get_def(id: String) -> CardDef:
		return _defs.get(id)
