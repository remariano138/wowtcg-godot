extends Node2D

# Phase 5 — Human input path wired to StackResolver.
#
# HOW TO RUN:
#   Scene > New Scene > Node2D root > attach this script > Play Scene.
#
# CONTROLS:
#   Click a green card in your hand  → plays it (submit_action)
#   Spacebar / Enter                 → pass priority
#   Escape                           → retract last chain entry (only while you still have priority)
#
# WHAT TO EXPECT:
#   Your cards (bottom) turn green when it's your turn to act.
#   Click one to play it — it slides to your ally row.
#   Press Space to pass. Opponent (AI) automatically passes after a short delay.
#   Status bar shows whose priority it is and what's on the chain.
#   Cards are only highlighted when you have priority.
#
# WHAT THIS PROVES:
#   Human input and AI input both funnel through submit_action / pass_priority.
#   InputRouter uses the same can_submit validators as StackResolver —
#   no duplicate rules logic in the UI.

const AI_THINK_TIME := 0.5   # seconds before AI passes

var _state: GameState
var _db: _MockDB
var _renderer: BoardRenderer
var _router: InputRouter
var _ai_timer: Timer
var _status: Label
var _priority_label: Label
var _pass_btn: Button
var _cancel_btn: Button


func _ready() -> void:
	_build_scene()
	_setup_game_state()
	_start_priority_window()


# ── Scene construction ─────────────────────────────────────────────────────────

func _build_scene() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.13, 0.16)
	bg.size  = Vector2(1600, 900)
	add_child(bg)

	# Title
	_add_label("Phase 5 — Human Input via InputRouter + StackResolver",
		Vector2(20, 14), 20, Color(0.85, 0.85, 0.85))
	_add_label("Click a green card to play it.  Spacebar = pass priority.",
		Vector2(20, 40), 13, Color(0.55, 0.55, 0.55))

	# Priority indicator — kept above the chain zone row
	_priority_label = _add_label("Priority: p1", Vector2(600, 380), 20,
		Color(0.9, 0.85, 0.3))

	# Status bar (bottom)
	_status = _add_label("", Vector2(20, 860), 14, Color(0.5, 0.8, 0.5))

	# Zone labels
	_add_label("P2 ally row",    Vector2(450, 195), 12, Color(0.45, 0.45, 0.6))
	_add_label("P1 ally row",    Vector2(450, 595), 12, Color(0.45, 0.6,  0.45))
	_add_label("Your hand (P1)", Vector2(280, 738), 12, Color(0.45, 0.6,  0.45))
	_add_label("P2 graveyard",   Vector2(1390, 130), 11, Color(0.5, 0.4, 0.4))
	_add_label("P1 graveyard",   Vector2(1390, 730), 11, Color(0.4, 0.5, 0.4))

	# Renderer
	_renderer = BoardRenderer.new()
	add_child(_renderer)

	# Register zone anchors
	_renderer.register_zone("p1_ally_row",  _make_anchor(Vector2(800, 620)))
	_renderer.register_zone("p2_ally_row",  _make_anchor(Vector2(800, 220)))
	_renderer.register_zone("chain",        _make_anchor(Vector2(800, 455)))
	_renderer.register_zone("p1_hand",      _make_anchor(Vector2(440, 760)))
	_renderer.register_zone("p2_hand",      _make_anchor(Vector2(795, 100)))
	_renderer.register_zone("p1_graveyard", _make_anchor(Vector2(1480, 750)))
	_renderer.register_zone("p2_graveyard", _make_anchor(Vector2(1480, 150)))

	# Status label for renderer
	_renderer.set_status_label(_status)

	# InputRouter
	_router = InputRouter.new()
	add_child(_router)
	_renderer.set_input_router(_router)

	# Cancel button — hidden until there is something to retract
	_cancel_btn = Button.new()
	_cancel_btn.text     = "Cancel  [Esc]"
	_cancel_btn.position = Vector2(390, 820)
	_cancel_btn.size     = Vector2(160, 46)
	_cancel_btn.visible  = false
	_cancel_btn.pressed.connect(_on_cancel_btn_pressed)
	add_child(_cancel_btn)

	# Pass Priority button
	_pass_btn = Button.new()
	_pass_btn.text     = "Pass Priority  [Space]"
	_pass_btn.position = Vector2(660, 820)
	_pass_btn.size     = Vector2(260, 46)
	_pass_btn.pressed.connect(_on_pass_btn_pressed)
	add_child(_pass_btn)

	# AI timer
	_ai_timer = Timer.new()
	_ai_timer.wait_time = AI_THINK_TIME
	_ai_timer.one_shot  = true
	_ai_timer.timeout.connect(_do_ai_turn)
	add_child(_ai_timer)

	# React to events to update priority label and trigger AI
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
	_state.turn_number     = 1
	_state.turn_player     = "p1"
	_state.priority_player = "p1"
	_state.phase           = "action"

	_db = _MockDB.new()
	_db.add("swift_wolf",  2, 3, "Swift Wolf",   false)
	_db.add("iron_guard",  3, 4, "Iron Guard",   false)
	_db.add("frost_mage",  1, 2, "Frost Mage",   false)
	_db.add("quick_shot",  0, 0, "Quick Shot",   true)   # P1 instant
	_db.add("shadow_rogue",2, 2, "Shadow Rogue", false)
	_db.add("ambush",      0, 0, "Ambush",       true)   # P2 instant

	# P1 hand — two allies + one instant
	_add_hand_card("p1_ally_a", "swift_wolf", "p1", Vector2(310, 760))
	_add_hand_card("p1_ally_b", "iron_guard", "p1", Vector2(440, 760))
	_add_hand_card("p1_inst_a", "quick_shot", "p1", Vector2(570, 760))

	# P2 hand — one ally + one instant (AI will play the instant when chain non-empty)
	_add_hand_card("p2_ally_a", "shadow_rogue", "p2", Vector2(730, 100))
	_add_hand_card("p2_inst_a", "ambush",       "p2", Vector2(860, 100))

	_router.setup(_state, _db, "p1")


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


# ── Priority window management ─────────────────────────────────────────────────

func _on_cancel_btn_pressed() -> void:
	_router.retract_last_action()


func _on_pass_btn_pressed() -> void:
	_router.pass_priority_action()
	_blink_pass_btn()


func _blink_pass_btn() -> void:
	_pass_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.4))
	_pass_btn.add_theme_stylebox_override("normal",
		_make_stylebox(Color(0.15, 0.45, 0.15)))
	var t := create_tween()
	t.tween_interval(0.25)
	t.tween_callback(func() -> void:
		_pass_btn.remove_theme_color_override("font_color")
		_pass_btn.remove_theme_stylebox_override("normal"))


func _make_stylebox(color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color            = color
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	return s


func _start_priority_window() -> void:
	_update_priority_label()
	_router.refresh_highlights()
	_update_pass_btn()
	_update_cancel_btn()
	if _state.priority_player == "p2":
		_ai_timer.start()


func _update_priority_label() -> void:
	var who := _state.priority_player
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

	_pass_btn.disabled = not my_turn

	if not my_turn:
		# Not your turn — greyed, disabled.
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)

	elif not has_plays:
		# Your priority, nothing legal to play — must pass.
		# Rule 410: you can always pass, and with nothing to play you must.
		_pass_btn.text     = "No legal play — Must Pass  [Space]"
		_pass_btn.modulate = Color(1.0, 0.35, 0.35)

	elif not chain_busy:
		# Your priority, chain empty, have legal plays.
		# Passing here (+ opponent passes) closes the window / ends the phase.
		# Visually subdued: primary action is to play something, not pass.
		_pass_btn.text     = "Pass Turn  [Space]"
		_pass_btn.modulate = Color(0.65, 0.65, 0.65)

	else:
		# Your priority, something on the chain, have legal responses.
		# Passing is a real choice — white / active.
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(1.0, 1.0, 1.0)


# ── AI (always passes) ─────────────────────────────────────────────────────────

func _do_ai_turn() -> void:
	if _state.priority_player != "p2":
		return

	# If the chain is non-empty and P2 has an instant in hand, play it.
	if not _state.pending_actions.is_empty():
		for card in _state.cards_in_zone("p2_hand"):
			var def: CardDef = _db.get_def(card.card_def_id)
			if def and def.is_instant:
				var action := PendingAction.make("play_instant", "p2",
						{"card_id": card.instance_id})
				if StackResolver.can_submit(_state, action, _db):
					var play_events := StackResolver.submit_action(_state, action, _db)
					EventBus.emit_events(play_events)
					_update_priority_label()
					_router.refresh_highlights()
					_update_pass_btn()
					_update_cancel_btn()
					_schedule_next_turn()
					return

	# Otherwise pass.
	var events := StackResolver.pass_priority(_state, _db)
	EventBus.emit_events(events)
	_update_priority_label()
	_router.refresh_highlights()


# ── Event reactions ────────────────────────────────────────────────────────────

func _on_game_event(event: GameEvent) -> void:
	_update_priority_label()
	_update_pass_btn()
	_update_cancel_btn()
	match event.event_type:
		"priority_passed":
			if event.payload.get("player", "") == "p2":
				_blink_pass_btn()
			_schedule_next_turn()
		"action_proposed":
			_schedule_next_turn()
		"card_moved":
			# After chain resolves (card moved out of chain), check for auto-pass.
			if event.payload.get("from", "") == "chain":
				_schedule_next_turn()
		"action_retracted":
			_router.refresh_highlights()
		"priority_window_closed":
			_start_priority_window()


func _schedule_next_turn() -> void:
	if _state.priority_player == "p2":
		_ai_timer.start()
	# Human always passes manually — never auto-pass. Auto-passing would reveal
	# whether the human has legal responses, leaking hand information.


# ── Mock database ──────────────────────────────────────────────────────────────

class _MockDB extends RefCounted:
	var _defs: Dictionary = {}

	func add(id: String, atk: int, health: int, card_name: String,
			instant: bool) -> void:
		var d := CardDef.new()
		d.card_def_id    = id
		d.card_name      = card_name
		d.printed_atk    = atk
		d.printed_health = health
		d.is_instant     = instant
		_defs[id] = d

	func get_def(id: String) -> CardDef:
		return _defs.get(id)
