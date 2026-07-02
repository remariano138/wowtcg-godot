extends Node2D

# Phase 7a — Turn loop: ready → draw → action → end → (opponent's turn …)
#
# HOW TO RUN:
#   Open phase7_test.tscn > Play Scene.
#
# CONTROLS:
#   Click a green card in your hand  → plays it
#   Spacebar / Enter                 → pass priority
#   Escape                           → retract last chain entry
#
# WHAT THIS PROVES:
#   Phases cycle correctly (ready→draw→action→end→next player).
#   Non-instant cards are locked during ready/draw/end windows.
#   Non-instant cards in hand stay grey until action phase; instants stay green.
#   Draw step draws mechanically (no visual yet — Phase 7c).
#   TurnManager + StackResolver + FullRandomAI all cooperate.

const AI_THINK_TIME := 0.5

var _state:  GameState
var _db:     CardDatabase
var _renderer: BoardRenderer
var _router: InputRouter
var _ai:     FullRandomAI
var _ai_timer:   Timer
var _status:     Label
var _priority_label: Label
var _phase_label:    Label
var _pass_btn:   Button
var _cancel_btn: Button
var _context_menu: PopupMenu
var _context_actions: Array   # Array of {label, action, enabled}
var _end_turn_dialog: ConfirmationDialog
var _p1_played_this_action_phase: bool = false


func _ready() -> void:
	_build_scene()
	_setup_game_state()


# ── Scene construction ─────────────────────────────────────────────────────────

func _build_scene() -> void:
	# Scene is 1600×1050: board occupies y=0..895, UI strip y=900..1050.
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.13, 0.16)
	bg.size  = Vector2(1600, 1050)
	add_child(bg)

	# ── Board zone labels (left gutter x=20) ──────────────────────────────────────
	# Zones are centred at x=700. Labels sit ~13px above each anchor.
	_add_label("P2 hand",         Vector2(20,  52), 11, Color(0.5, 0.35, 0.35))
	_add_label("P2 resource row", Vector2(20, 177), 11, Color(0.5, 0.5,  0.35))
	_add_label("P2 ally row",     Vector2(20, 307), 11, Color(0.45, 0.45, 0.6))
	_add_label("P1 ally row",     Vector2(20, 557), 11, Color(0.45, 0.6,  0.45))
	_add_label("P1 resource row", Vector2(20, 682), 11, Color(0.45, 0.55, 0.35))
	_add_label("Your hand (P1)",  Vector2(20, 832), 11, Color(0.45, 0.6,  0.45))

	# ── Deck + graveyard labels (right side, same y as their player's hand) ────────
	_add_label("P2 graveyard", Vector2(1130,  52), 11, Color(0.5, 0.4, 0.4))
	_add_label("P2 deck",      Vector2(1280,  52), 11, Color(0.4, 0.4, 0.5))
	_add_label("P1 graveyard", Vector2(1130, 832), 11, Color(0.4, 0.5, 0.4))
	_add_label("P1 deck",      Vector2(1280, 832), 11, Color(0.4, 0.4, 0.5))

	# Status label must exist before renderer.set_status_label is called below.
	_status = _add_label("", Vector2(20, 972), 13, Color(0.5, 0.8, 0.5))

	# Renderer
	_renderer = BoardRenderer.new()
	add_child(_renderer)

	# Zone anchors — 130px between each centre; p1_hand at y=845 (bottom edge 900).
	_renderer.register_zone("p2_hand",         _make_anchor(Vector2(700,  65)))
	_renderer.register_zone("p2_resource_row", _make_anchor(Vector2(700, 195)))
	_renderer.register_zone("p2_ally_row",     _make_anchor(Vector2(700, 325)))
	_renderer.register_zone("chain",           _make_anchor(Vector2(700, 455)))
	_renderer.register_zone("p1_ally_row",     _make_anchor(Vector2(700, 585)))
	_renderer.register_zone("p1_resource_row", _make_anchor(Vector2(700, 715)))
	_renderer.register_zone("p1_hand",         _make_anchor(Vector2(700, 845)))
	_renderer.register_zone("p2_graveyard",    _make_anchor(Vector2(1200,  65)))
	_renderer.register_zone("p2_deck",         _make_anchor(Vector2(1350,  65)))
	_renderer.register_zone("p1_graveyard",    _make_anchor(Vector2(1200, 845)))
	_renderer.register_zone("p1_deck",         _make_anchor(Vector2(1350, 845)))

	_renderer.set_status_label(_status)

	_router = InputRouter.new()
	add_child(_router)
	_renderer.set_input_router(_router)

	# ── UI strip (y=900..1050) ─────────────────────────────────────────────────────
	# Left: phase / priority / status  |  Centre: Cancel + Pass  |  Right: hints

	_phase_label    = _add_label("", Vector2(20, 910), 20, Color(0.9, 0.85, 0.45))
	_priority_label = _add_label("", Vector2(20, 944), 16, Color(0.9, 0.85, 0.3))
	# _status already created above (needed by renderer before this block)

	_cancel_btn = Button.new()
	_cancel_btn.text     = "Cancel  [Esc]"
	_cancel_btn.position = Vector2(530, 918)
	_cancel_btn.size     = Vector2(160, 40)
	_cancel_btn.visible  = false
	_cancel_btn.pressed.connect(_on_cancel_btn_pressed)
	add_child(_cancel_btn)

	_pass_btn = Button.new()
	_pass_btn.text     = "Pass Priority  [Space]"
	_pass_btn.position = Vector2(700, 918)
	_pass_btn.size     = Vector2(220, 40)
	_pass_btn.pressed.connect(_on_pass_btn_pressed)
	add_child(_pass_btn)

	_add_label("Left-click = play/place  ·  Right-click = all options  ·  Esc = retract",
		Vector2(530, 972), 11, Color(0.4, 0.4, 0.4))

	_ai_timer = Timer.new()
	_ai_timer.wait_time = AI_THINK_TIME
	_ai_timer.one_shot  = true
	_ai_timer.timeout.connect(_do_ai_turn)
	add_child(_ai_timer)

	_context_menu = PopupMenu.new()
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)

	_renderer.card_right_clicked.connect(_on_card_right_clicked)

	_end_turn_dialog = ConfirmationDialog.new()
	_end_turn_dialog.title = "Wrap up without playing?"
	_end_turn_dialog.dialog_text = "You haven't played anything this turn.\nMove to end phase anyway?"
	_end_turn_dialog.ok_button_text     = "Yes, wrap up"
	_end_turn_dialog.cancel_button_text = "No, I'll play something"
	_end_turn_dialog.confirmed.connect(_on_end_turn_confirmed)
	add_child(_end_turn_dialog)

	EventBus.game_event.connect(_on_game_event)


func _make_anchor(pos: Vector2) -> Node2D:
	var a := Node2D.new()
	a.global_position = pos
	add_child(a)
	return a


func _add_label(text: String, pos: Vector2, size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = pos
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	add_child(lbl)
	return lbl


# ── Game state setup ───────────────────────────────────────────────────────────

func _setup_game_state() -> void:
	_state = GameState.create_new(["p1", "p2"])

	# Real database — only engine_status=implemented cards are loaded.
	_db = CardDatabase.new()
	_db.load_csv("res://data/cards.csv")

	# Mock-only cards (no CSV row yet): instants and quest placeholder.
	_db.add_def(_make_mock_def("mock_quick_shot", "Quick Shot",  0, 0, true,  "Ability"))
	_db.add_def(_make_mock_def("mock_dark_bolt",  "Dark Bolt",   0, 0, true,  "Ability"))
	_db.add_def(_make_mock_def("mock_quest",      "Forest Camp", 0, 0, false, "Quest"))

	# P1 hand: 2× Kor Cindervein (Alliance, 3/3) + 1 instant + 2 quests
	_add_hand_card("p1_ally_a",  "azeroth_192",    "p1", Vector2(700, 845))
	_add_hand_card("p1_ally_b",  "azeroth_192",    "p1", Vector2(700, 845))
	_add_hand_card("p1_inst_a",  "mock_quick_shot","p1", Vector2(700, 845))
	_add_hand_card("p1_quest_a", "mock_quest",     "p1", Vector2(700, 845))
	_add_hand_card("p1_quest_b", "mock_quest",     "p1", Vector2(700, 845))

	# P2 hand: 1× Vaerik Proudhoof (Horde, 5/3) + 1 instant
	_add_hand_card("p2_ally_a", "azeroth_262",   "p2", Vector2(700, 65))
	_add_hand_card("p2_inst_a", "mock_dark_bolt","p2", Vector2(700, 65))

	# Decks: real cards where implemented, mocks otherwise
	_add_deck_card("p1_deck_1", "azeroth_192",    "p1")
	_add_deck_card("p1_deck_2", "azeroth_192",    "p1")
	_add_deck_card("p1_deck_3", "mock_quick_shot","p1")
	_add_deck_card("p2_deck_1", "azeroth_262",    "p2")
	_add_deck_card("p2_deck_2", "azeroth_262",    "p2")
	_add_deck_card("p2_deck_3", "mock_dark_bolt", "p2")

	# Spread starting hand cards before the first event fires.
	_renderer.relayout_zone("p1_hand")
	_renderer.relayout_zone("p2_hand")


	_router.setup(_state, _db, "p1")
	_ai = FullRandomAI.new()

	# Start the game — fires phase_changed (ready) which sets up the first window
	var events := TurnManager.start_game(_state, "p1", _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()


func _add_hand_card(inst_id: String, def_id: String, owner: String,
		screen_pos: Vector2) -> void:
	var def: CardDef = _db.get_def(def_id)
	var stats := "%d/%d" % [def.printed_atk, def.printed_health]
	var color  := Color(0.25, 0.45, 0.75) if owner == "p1" else Color(0.5, 0.25, 0.25)

	var card := CardInstance.create(inst_id, def_id, owner, owner + "_hand")
	_state.cards[inst_id] = card
	_state.zones[owner + "_hand"].card_ids.append(inst_id)

	var node := CardNode.create(inst_id, def.card_name, stats, color)
	node.global_position = screen_pos
	add_child(node)
	_renderer.register_card(inst_id, node)
	_renderer.place_card_in_zone(inst_id, owner + "_hand")


func _add_deck_card(inst_id: String, def_id: String, owner: String) -> void:
	var card := CardInstance.create(inst_id, def_id, owner, owner + "_deck")
	_state.cards[inst_id] = card
	_state.zones[owner + "_deck"].card_ids.append(inst_id)
	# No visual node — renderer skips these until Phase 7c introduces card drawing visuals


# ── UI refresh ─────────────────────────────────────────────────────────────────

func _refresh_ui() -> void:
	_update_priority_label()
	_update_phase_label()
	_router.refresh_highlights()
	_update_pass_btn()
	_update_cancel_btn()


func _update_phase_label() -> void:
	var names := {
		"ready": "Ready Step", "draw": "Draw Step",
		"action": "Action Phase", "end": "End Phase",
	}
	var phase_str: String = names.get(_state.phase, _state.phase)
	_phase_label.text = "Turn %d  ·  %s  ·  %s's turn" % [
		_state.turn_number, phase_str, _state.turn_player]


func _update_priority_label() -> void:
	var who        := _state.priority_player
	var chain_size := _state.pending_actions.size()
	var chain_str  := "chain empty" if chain_size == 0 else "chain: %d" % chain_size
	_priority_label.text = "Priority: %s   (%s)" % [who, chain_str]
	_priority_label.add_theme_color_override("font_color",
		Color(0.4, 0.9, 0.4) if who == "p1" else Color(0.9, 0.5, 0.4))


func _update_cancel_btn() -> void:
	_cancel_btn.visible = StackResolver.can_retract(_state, "p1")


func _update_pass_btn() -> void:
	var my_turn    := _state.priority_player == "p1"
	var has_plays  := not _router.get_playable_card_ids().is_empty()
	var chain_busy := not _state.pending_actions.is_empty()
	var in_action  := _state.phase == "action"

	_pass_btn.disabled = not my_turn

	if not my_turn:
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif not has_plays:
		_pass_btn.text     = "No legal play — Must Pass  [Space]"
		_pass_btn.modulate = Color(1.0, 0.35, 0.35)
	elif chain_busy:
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(1.0, 1.0, 1.0)
	elif in_action:
		_pass_btn.text     = "Wrap Up  [Space]"
		_pass_btn.modulate = Color(0.65, 0.65, 0.65)
	elif _state.phase == "end":
		_pass_btn.text     = "End Turn  [Space]"
		_pass_btn.modulate = Color(0.65, 0.65, 0.65)
	else:
		# Ready/draw phase, chain empty — passing closes a short mandatory window
		_pass_btn.text     = "Pass  [Space]"
		_pass_btn.modulate = Color(0.65, 0.65, 0.65)


# ── Button handlers ────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	# Intercept spacebar here (via _input, not _unhandled_input) so we can gate
	# the pass through _try_pass() before InputRouter's _unhandled_input fires.
	# Godot 4 processes _unhandled_input children-first, so InputRouter would
	# consume the event before this scene's _unhandled_input ever ran.
	if event.is_action_pressed("ui_accept"):
		_try_pass()
		get_viewport().set_input_as_handled()


func _on_cancel_btn_pressed() -> void:
	_router.retract_last_action()


func _on_pass_btn_pressed() -> void:
	_try_pass()


# Gate for human passing: shows a confirmation if they'd end their action phase
# without having played a single card or instant this turn.
func _try_pass() -> void:
	if not _state or _state.priority_player != "p1":
		return
	var needs_confirm := (
		_state.turn_player == "p1"
		and _state.phase == "action"
		and _state.pending_actions.is_empty()
		and not _p1_played_this_action_phase
	)
	if needs_confirm:
		_end_turn_dialog.popup_centered()
	else:
		_router.pass_priority_action()
		_blink_pass_btn()


func _on_end_turn_confirmed() -> void:
	# Player confirmed they want to pass — do it for them (no need to press again).
	_router.pass_priority_action()
	_blink_pass_btn()


func _blink_pass_btn() -> void:
	_pass_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.4))
	_pass_btn.add_theme_stylebox_override("normal", _make_stylebox(Color(0.15, 0.45, 0.15)))
	var t := create_tween()
	t.tween_interval(0.25)
	t.tween_callback(func() -> void:
		_pass_btn.remove_theme_color_override("font_color")
		_pass_btn.remove_theme_stylebox_override("normal"))


func _make_stylebox(color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.corner_radius_top_left    = 4
	s.corner_radius_top_right   = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	return s


# ── AI ─────────────────────────────────────────────────────────────────────────

func _do_ai_turn() -> void:
	if _state.priority_player != "p2":
		return
	var action := _ai.decide_action(_state, _db, "p2")
	var events: Array[GameEvent]
	if action != null:
		events = StackResolver.submit_action(_state, action, _db)
	else:
		events = StackResolver.pass_priority(_state, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()


# ── Event reactions ────────────────────────────────────────────────────────────

func _on_game_event(event: GameEvent) -> void:
	match event.event_type:
		"priority_passed":
			if event.payload.get("player", "") == "p2":
				_blink_pass_btn()
			_refresh_ui()
			_schedule_next_turn()
		"action_proposed":
			if event.payload.get("player") == "p1":
				_p1_played_this_action_phase = true
			_refresh_ui()
			_schedule_next_turn()
		"card_moved":
			_refresh_ui()
			if event.payload.get("from", "") == "chain":
				_schedule_next_turn()
		"action_retracted":
			_refresh_ui()
		"phase_changed":
			if event.payload.get("phase") == "action" and event.payload.get("turn_player") == "p1":
				_p1_played_this_action_phase = false
			_refresh_ui()
		"priority_window_closed":
			# Defer so this event finishes dispatching before TurnManager fires new ones.
			call_deferred("_on_window_closed")
		"deck_empty":
			_set_status("Deck empty for %s" % event.payload.get("player", "?"))


func _on_window_closed() -> void:
	var events := TurnManager.advance_phase(_state, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()


func _on_card_right_clicked(instance_id: String) -> void:
	_context_actions = _router.get_context_actions(instance_id)
	if _context_actions.is_empty():
		return
	_context_menu.clear()
	for i in _context_actions.size():
		var entry: Dictionary = _context_actions[i]
		if entry["enabled"]:
			_context_menu.add_item(entry["label"], i)
		else:
			_context_menu.add_item(entry["label"], i)
			_context_menu.set_item_disabled(_context_menu.item_count - 1, true)
	_context_menu.popup_on_parent(Rect2(get_viewport().get_mouse_position(), Vector2.ZERO))


func _on_context_menu_id_pressed(id: int) -> void:
	if id < 0 or id >= _context_actions.size():
		return
	var entry: Dictionary = _context_actions[id]
	_router.handle_context_action(entry["action"])
	_refresh_ui()


func _schedule_next_turn() -> void:
	if _state.priority_player == "p2" and not _ai_timer.time_left > 0:
		_ai_timer.start()


func _set_status(text: String) -> void:
	if _status:
		_status.text = text


# ── Mock card helper ───────────────────────────────────────────────────────────

static func _make_mock_def(id: String, name: String, atk: int, health: int,
		instant: bool, ctype: String) -> CardDef:
	var d := CardDef.new()
	d.card_def_id    = id
	d.card_name      = name
	d.printed_atk    = atk
	d.printed_health = health
	d.is_instant     = instant
	d.card_type      = ctype
	return d
