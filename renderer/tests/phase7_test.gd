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
var _gm:     GameManager
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
	# Scene is 1600×1050: board occupies y=0..850, UI strip y=900..1050.
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.13, 0.16)
	bg.size  = Vector2(1600, 1050)
	add_child(bg)

	# ── Board zone labels (left gutter x=20) ──────────────────────────────────────
	_add_label("P2 hand",         Vector2(20,  52), 11, Color(0.5, 0.35, 0.35))
	_add_label("P2 resource row", Vector2(20, 182), 11, Color(0.5, 0.5,  0.35))
	_add_label("P2 ally row",     Vector2(20, 312), 11, Color(0.45, 0.45, 0.6))
	_add_label("P1 ally row",     Vector2(20, 572), 11, Color(0.45, 0.6,  0.45))
	_add_label("P1 resource row", Vector2(20, 702), 11, Color(0.45, 0.55, 0.35))
	_add_label("Your hand (P1)",  Vector2(20, 832), 11, Color(0.45, 0.6,  0.45))

	# ── Right column labels (graveyard x=1130, deck/hero x=1280) ─────────────────
	_add_label("P2 grave",  Vector2(1130,  52), 11, Color(0.5, 0.4, 0.4))
	_add_label("P2 deck",   Vector2(1280,  52), 11, Color(0.4, 0.4, 0.5))
	_add_label("P2 hero",   Vector2(1280, 182), 11, Color(0.5, 0.4, 0.5))
	_add_label("P1 grave",  Vector2(1130, 832), 11, Color(0.4, 0.5, 0.4))
	_add_label("P1 hero",   Vector2(1280, 702), 11, Color(0.4, 0.5, 0.45))
	_add_label("P1 deck",   Vector2(1280, 832), 11, Color(0.4, 0.4, 0.5))

	# Status label must exist before renderer.set_status_label is called below.
	_status = _add_label("", Vector2(20, 972), 13, Color(0.5, 0.8, 0.5))

	# Renderer
	_renderer = BoardRenderer.new()
	add_child(_renderer)

	# Zone anchors.
	# Board rows (centre x=700): p2_hand → p2_resource → p2_ally → chain → p1_ally → p1_resource → p1_hand
	# Right column (x=1350): p2_deck at top, p2_hero just below; p1_deck at bottom, p1_hero just above.
	# Graveyard at x=1200, same y as the player's hand.
	_renderer.register_zone("p2_hand",         _make_anchor(Vector2(700,  65)))
	_renderer.register_zone("p2_resource_row", _make_anchor(Vector2(700, 195)))
	_renderer.register_zone("p2_ally_row",     _make_anchor(Vector2(700, 325)))
	_renderer.register_zone("chain",           _make_anchor(Vector2(700, 455)))
	_renderer.register_zone("p1_ally_row",     _make_anchor(Vector2(700, 585)))
	_renderer.register_zone("p1_resource_row", _make_anchor(Vector2(700, 715)))
	_renderer.register_zone("p1_hand",         _make_anchor(Vector2(700, 845)))
	_renderer.register_zone("p2_graveyard",    _make_anchor(Vector2(1200,  65)))
	_renderer.register_zone("p2_deck",         _make_anchor(Vector2(1350,  65)))
	_renderer.register_zone("p2_hero_row",     _make_anchor(Vector2(1350, 195)))
	_renderer.register_zone("p1_graveyard",    _make_anchor(Vector2(1200, 845)))
	_renderer.register_zone("p1_deck",         _make_anchor(Vector2(1350, 845)))
	_renderer.register_zone("p1_hero_row",     _make_anchor(Vector2(1350, 715)))

	_renderer.set_status_label(_status)

	# ── Deck slot card-back sprites ────────────────────────────────────────────────
	_add_deck_back_sprite(Vector2(1350,  65))  # p2 deck
	_add_deck_back_sprite(Vector2(1350, 845))  # p1 deck

	_router = InputRouter.new()
	add_child(_router)
	_renderer.set_input_router(_router)
	_router.targeting_started.connect(_on_targeting_started)
	_router.targeting_cancelled.connect(_on_targeting_cancelled)
	_router.discard_mode_started.connect(_on_discard_mode_started)
	_router.discard_mode_ended.connect(_on_discard_mode_ended)

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


func _add_deck_back_sprite(pos: Vector2) -> void:
	var back: Texture2D = load(CardNode.CARD_BACK_PATH)
	if not back:
		return
	var tex := TextureRect.new()
	tex.texture      = back
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tex.size         = Vector2(CardNode.W, CardNode.H)
	tex.position     = pos - Vector2(CardNode.W * 0.5, CardNode.H * 0.5)
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tex)


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
	# Real database — only engine_status=implemented cards are loaded.
	_db = CardDatabase.new()
	_db.load_csv("res://data/cards.csv")

	# Mock-only cards (no CSV row yet): instants and quest placeholder.
	_db.add_def(_make_mock_def("mock_quick_shot", "Quick Shot", 0, 0, true, "Ability"))
	_db.add_def(_make_mock_def("mock_dark_bolt",  "Dark Bolt",  0, 0, true, "Ability"))

	# ── P1 deck (Alliance) ────────────────────────────────────────────────────────
	# 4× Your Fortune Awaits You (Quest, draw 1 on completion)
	# 4× Crazy Igvand (Protector, 0/6)
	# 4× Warden Tonarin (Elusive + Protector, 1/1)
	# 4× Apprentice Teep (Elusive, 2/1)
	# 4× Latro Abiectus (Elusive, 3/2)
	# 2× Braxiss the Sleeper (Elusive, 6/4)
	# 1× Quick Shot (instant placeholder)
	# Filler: azeroth_192 (Kor Cindervein — solid ally for testing)
	var p1_cards: Array[String] = [
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",   # Your Fortune Awaits You
		"azeroth_180", "azeroth_180", "azeroth_180", "azeroth_180",   # Crazy Igvand
		"azeroth_222", "azeroth_222", "azeroth_222", "azeroth_222",   # Warden Tonarin
		"azeroth_176", "azeroth_176", "azeroth_176", "azeroth_176",   # Apprentice Teep
		"azeroth_197", "azeroth_197", "azeroth_197", "azeroth_197",   # Latro Abiectus
		"azeroth_179", "azeroth_179",                                  # Braxiss the Sleeper
		"mock_quick_shot",
		"azeroth_175", "azeroth_175", "azeroth_175", "azeroth_175",
		"azeroth_228", "azeroth_228", "azeroth_228", "azeroth_228",
	]
	while p1_cards.size() < 60:
		p1_cards.append("azeroth_192")
	var deck_p1 := Deck.make("azeroth_6", p1_cards)

	# ── P2 deck (Horde) ───────────────────────────────────────────────────────────
	# 4× Your Fortune Awaits You (neutral quest, both sides can run it)
	# 4× Fa'tafi (Protector, 3/6, heals 1 each turn)
	# 4× Ka'tali Stonetusk (Protector, 1/2, heals 1 on your turn)
	# 4× Kagra of the Crossroads (Ferocity, 1/2)
	# 4× Vesh'ral (Ferocity, 3/1)
	# 2× Moko Hunts-at-Dawn (Ferocity, 5/4)
	# 1× Dark Bolt (instant placeholder)
	# Filler: azeroth_262 (Vaerik Proudhoof)
	var p2_cards: Array[String] = [
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",   # Your Fortune Awaits You
		"azeroth_236", "azeroth_236", "azeroth_236", "azeroth_236",   # Fa'tafi
		"azeroth_248", "azeroth_248", "azeroth_248", "azeroth_248",   # Ka'tali Stonetusk
		"azeroth_246", "azeroth_246", "azeroth_246", "azeroth_246",   # Kagra of the Crossroads
		"azeroth_264", "azeroth_264", "azeroth_264", "azeroth_264",   # Vesh'ral
		"azeroth_252", "azeroth_252",                                  # Moko Hunts-at-Dawn
		"mock_dark_bolt",
		"azeroth_175", "azeroth_175", "azeroth_175", "azeroth_175",
		"azeroth_228", "azeroth_228", "azeroth_228", "azeroth_228",
	]
	while p2_cards.size() < 60:
		p2_cards.append("azeroth_262")
	var deck_p2 := Deck.make("azeroth_15", p2_cards)

	# GameManager builds the full state: creates zones, places heroes, shuffles
	# decks, draws 7-card starting hands.
	_gm = GameManager.new()
	_gm.setup(_db)
	_gm.add_player("p1", GameManager.HUMAN, deck_p1)
	_gm.add_player("p2", GameManager.AI,    deck_p2)
	_state = _gm.build_state()

	# Seed deck counts before any card_moved events fire.
	for pid in ["p1", "p2"]:
		var dz: String = pid + "_deck"
		var dzone := _state.zones.get(dz) as Zone
		if dzone:
			_renderer.init_deck_count(dz, dzone.card_ids.size())

	# Spawn CardNodes for heroes and starting hands.
	_spawn_zone_nodes("p1_hero_row", Vector2(1350, 715), Color(0.25, 0.45, 0.75))
	_spawn_zone_nodes("p2_hero_row", Vector2(1350, 195), Color(0.5, 0.25, 0.25))
	_spawn_zone_nodes("p1_hand",     Vector2(700,  845), Color(0.25, 0.45, 0.75))
	_spawn_zone_nodes("p2_hand",     Vector2(700,   65), Color(0.5, 0.25, 0.25))

	# Init hero HP bars at full health.
	for pid in ["p1", "p2"]:
		var ps := _state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var max_hp := _state.get_max_hp(ps.hero_instance_id, _db)
			_renderer.init_hero_bar(pid, ps.hero_instance_id, max_hp)

	# Spread starting hand cards before the first event fires.
	_renderer.relayout_zone("p1_hand")
	_renderer.relayout_zone("p2_hand")

	_router.setup(_state, _db, "p1")
	_ai = FullRandomAI.new()

	# Start the game — fires phase_changed (ready) which sets up the first window.
	var events := TurnManager.start_game(_state, "p1", _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()


# Spawn CardNode visuals for every card currently in a zone.
# Cards drawn later will be spawned by _on_game_event("card_moved").
func _spawn_zone_nodes(zone_id: String, spawn_pos: Vector2, color: Color) -> void:
	var zone := _state.zones.get(zone_id) as Zone
	if not zone:
		return
	for inst_id in zone.card_ids:
		_spawn_card_node(inst_id, spawn_pos, color)


func _spawn_card_node(inst_id: String, spawn_pos: Vector2, color: Color) -> void:
	if _renderer.has_card_node(inst_id):
		return
	var card := _state.get_card(inst_id)
	if not card:
		return
	var def := _db.get_def(card.card_def_id) as CardDef
	if not def:
		return
	var stats := "%d/%d" % [def.printed_atk, def.printed_health]
	var node  := CardNode.create(inst_id, def.card_name, stats, color, def.image_path)
	node.global_position = spawn_pos
	add_child(node)
	_renderer.register_card(inst_id, node)
	_renderer.place_card_in_zone(inst_id, card.zone_id)


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
	var has_plays  := _router.has_any_legal_play()
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
			# A card drawn from deck needs a fresh CardNode spawned at the hand anchor.
			var to_zone: String = event.payload.get("to", "")
			var moved_id: String = event.payload.get("card", "")
			if to_zone.ends_with("_hand") and not _renderer.has_card_node(moved_id):
				var card := _state.get_card(moved_id)
				if card:
					var is_p1 := card.owner == "p1"
					var spawn_pos := Vector2(700, 845) if is_p1 else Vector2(700, 65)
					var color := Color(0.25, 0.45, 0.75) if is_p1 else Color(0.5, 0.25, 0.25)
					_spawn_card_node(moved_id, spawn_pos, color)
					# Renderer's _animate_move already ran before this node existed,
					# so trigger the layout manually now that the node is registered.
					_renderer.relayout_zone(to_zone)
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
		"protect_point_opened":
			_handle_protect_point(event.payload)
		"discard_choice_opened":
			_handle_discard_choice(event.payload)
		"game_over":
			_handle_game_over(event.payload)


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


# ── Targeting ──────────────────────────────────────────────────────────────────

func _on_discard_mode_started(count: int) -> void:
	_set_status("Choose %d card(s) to discard — click a green hand card" % count)
	_refresh_ui()


func _on_discard_mode_ended() -> void:
	_set_status("")
	_refresh_ui()


func _handle_discard_choice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var count: int = payload.get("count", 1)
	if player == "p2":
		# AI: discard random hand card(s) immediately.
		for _i in count:
			var hand := _state.cards_in_zone("p2_hand")
			if hand.is_empty():
				break
			var pick: CardInstance = hand[randi() % hand.size()]
			var events := StackResolver.choose_discard(_state, pick.instance_id, _db)
			EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human (p1): enter discard mode — green highlights + click to resolve.
		_router.start_discard_mode(count)


func _on_targeting_started(attacker_id: String) -> void:
	var def: CardDef = _db.get_def((_state.get_card(attacker_id) as CardInstance).card_def_id)
	var name_str := def.card_name if def else attacker_id
	_set_status("⚔ %s attacking — select a target  [Esc to cancel]" % name_str)
	_refresh_ui()


func _on_targeting_cancelled() -> void:
	_set_status("")
	_refresh_ui()


# ── Protect point ──────────────────────────────────────────────────────────────

func _handle_protect_point(payload: Dictionary) -> void:
	var defender_id: String    = payload.get("defender_id", "")
	var protectors: Array      = payload.get("legal_protectors", [])
	var defender := _state.get_card(defender_id)
	if not defender:
		return
	var defending_player := defender.controller

	if defending_player == "p2":
		# AI decides immediately.
		var protector_id := _ai.choose_protector(_state, _db, "p2")
		var events := StackResolver.choose_protector(_state, protector_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human player (p1): show a popup listing legal protectors + Skip.
		_show_protect_popup(protectors)


func _show_protect_popup(protectors: Array) -> void:
	var popup := PopupMenu.new()
	for i in protectors.size():
		var cid: String = protectors[i]
		var card := _state.get_card(cid)
		var label := cid
		if card and _db:
			var def: CardDef = _db.get_def(card.card_def_id)
			if def:
				label = def.card_name
		popup.add_item("Protect with: %s" % label, i)
	popup.add_separator()
	popup.add_item("Skip — do not protect", protectors.size())
	popup.id_pressed.connect(func(id: int) -> void:
		popup.queue_free()
		var protector_id := protectors[id] if id < protectors.size() else ""
		var events := StackResolver.choose_protector(_state, protector_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn())
	add_child(popup)
	popup.popup_centered()


# ── Game over ──────────────────────────────────────────────────────────────────

func _handle_game_over(payload: Dictionary) -> void:
	var winner: String = payload.get("winner", "?")
	var dialog := AcceptDialog.new()
	dialog.title = "Game Over"
	dialog.dialog_text = "★ %s wins!" % winner.to_upper()
	dialog.confirmed.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


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
