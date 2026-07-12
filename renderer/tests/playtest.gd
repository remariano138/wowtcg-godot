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

# NOT a "thinking" pause. _ai_timer exists purely to (a) defer each AI beat off the
# call stack so back-to-back passes don't recurse/freeze the frame, and (b) stay
# cancellable via _ai_timer.stop() (protect windows). Human-facing pacing lives in
# GameTiming (see below) — keep this a tiny scheduler tick, not a pacing knob.
const AI_THINK_TIME       := 0.001
# How often the self-healing reconcile pass runs (snaps crooked cards back to
# their true exhausted/ready orientation once animations settle).
const RECONCILE_TICK      := 0.3
# Pause durations live in game_logic/timing.gd (GameTiming) so they can all be tuned
# together via GameTiming.animation_speed (see the in-game Speed slider).

# Deck lists live in res://decks/ and are served by DeckManager — this scene
# only picks ids.
const DECK_RANDOM := "random"
const CAT_ALL         := 0
const CAT_RECOMMENDED := 1
const CATEGORY_LABELS := ["All decks", "Recommended for AI"]

var _state:  GameState
var _db:     CardDatabase
var _gm:     GameManager
var _renderer: BoardRenderer
var _router: InputRouter
var _ai_timer:   Timer
var _reconcile_timer: Timer
var _speed_slider: HSlider
var _speed_value_label: Label
var _draining: bool = false  # true while _drain_passes is running

# Per-player type + AI instance (null = human).
var _p1_type: String = "human"
var _p2_type: String = "recommended"
var _p1_ai:   Object = null
var _p2_ai:   Object = null

# ── Menu ───────────────────────────────────────────────────────────────────────
var _menu_layer:  CanvasLayer
var _p1_type_opt: OptionButton
var _p1_deck_opt: OptionButton
var _p2_type_opt: OptionButton
var _p2_deck_opt: OptionButton
var _p1_cat_opt:  OptionButton
var _p2_cat_opt:  OptionButton
var _p1_strategy_label: Label
var _p2_strategy_label: Label
var _p1_deck_ids: Array[String] = []   # dropdown index -> deck_id (last entry = DECK_RANDOM)
var _p2_deck_ids: Array[String] = []
var _p1_ai_types: Array[String] = []   # dropdown index -> type string ("human", "recommended", or an ai_id)
var _p2_ai_types: Array[String] = []
var _avoid_mirror_cb: CheckBox
var _menu_error_label: Label
var _status:     Label
var _priority_label: Label
var _phase_label:    Label
var _pass_btn:   Button
var _cancel_btn: Button
var _resource_label: Label
var _mulligan_panel:       VBoxContainer
var _mulligan_order_label: Label
var _mulligan_ready_btn:   Button
var _mulligan_btn:         Button
var _mulligan_hint_label:  Label
var _p1_has_mulliganed:    bool = false
var _context_menu: PopupMenu
var _context_actions: Array   # Array of {label, action, enabled}
# ── X-select dialog (Dizdemona-style "put X damage on herself" powers) ─────────
var _x_dialog:       Panel
var _x_label:        Label
var _x_input:        LineEdit
var _x_ok_btn:       Button
var _x_hero_id:      String = ""
var _x_max:          int = 0
# ── Graveyard browser (quest rewards targeting graveyard cards) ────────────────
var _gy_dialog:        Panel
var _gy_dimmer:        ColorRect
var _gy_title:         Label
var _gy_scroll:        ScrollContainer
var _gy_card_grid:     GridContainer
var _gy_confirm_btn:   Button
var _gy_cancel_btn:    Button
var _gy_selected:      Array = []       # instance_ids currently picked
var _gy_min:           int = 1
var _gy_max:           int = 1
var _gy_view_only:     bool = false     # true = examine mode (no selection, no router call)
var _gy_peek_active:   bool = false     # true = alt+hover peek (non-modal, no dimmer/buttons)
var _gy_reveal_mode:   bool = false     # true = reveal-and-pick quest (choose_reveal_pick, no cancel)
var _end_turn_dialog: ConfirmationDialog
var _p1_played_this_action_phase: bool = false
var _game_over: bool = false
var _last_p1_deck_id: String = ""
var _last_p2_deck_id: String = ""

# ── Game log ───────────────────────────────────────────────────────────────────
var _log: RichTextLabel
var _log_bg: ColorRect
var _log_visible: bool = true  # press L to toggle
var _log_in_mulligan: bool = false
var _pending_exhaust: Dictionary = {}  # player_id -> count of resources exhausted, not yet logged

# ── Control panel ──────────────────────────────────────────────────────────────
var _turbo_mode: bool = true
# One-shot "auto-pass this combat" toggle (set by pressing F during a combat
# window). Auto-passes the human's attack/defend windows until the opponent
# responds (adds a link to the chain), then clears so the human can react.
var _auto_pass_combat: bool = false
# One-shot "wrap up my turn" burst set by Ctrl+Space. Auto-passes every empty
# priority window belonging to the human (ready/draw/action/end phases, and
# any chain link the human just added themselves) regardless of Turbo/Tactical
# mode, until either a real decision appears for the human (pending choice,
# opponent adds a chain link they must respond to) or their own next main
# action window is reached — whichever comes first, that's the stop.
var _wrap_up_active: bool = false
# "Nothing changed" tracking (mode-independent — runs ahead of Turbo/Tactical,
# see _human_has_new_info): identity of the chain-top PendingAction and a
# generation counter for combat window transitions, both captured the last
# time the human was actually stopped to make a decision. Object identity
# (get_instance_id) is used for the chain top since PendingAction has no id.
var _last_seen_chain_top_iid: int = 0
var _window_generation: int = 0
var _last_seen_window_gen: int = 0
var _turbo_btn:  Button
var _tactical_btn: Button
var _mode_desc_label: Label

# ── Protect point (inline panel UI) ───────────────────────────────────────────
var _in_protect_mode: bool = false
var _protect_protectors: Array = []
var _protect_nodes: Array[Node] = []
var _protect_defender_id: String = ""
var _protect_attacker_id: String = ""

# Strike point (rules 602.1 / 602.3) — inline weapon-strike choice, mirrors
# the protect-point UI.
var _in_strike_mode: bool = false
var _strike_weapon_ids: Array = []
var _strike_nodes: Array[Node] = []

# ── Combat window highlight (attacker/defender in red during attack/defend windows) ──
var _combat_highlight_ids: Array = []


func _ready() -> void:
	_build_scene()
	_build_menu()


# ── Scene construction ─────────────────────────────────────────────────────────

func _build_scene() -> void:
	# Scene is 1920×1080: board occupies y=0..950, UI strip y=960..1080.
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.13, 0.16)
	bg.size  = Vector2(1920, 1080)
	add_child(bg)

	# ── Game log panel (left gutter, replaces zone labels) ────────────────────────
	_log_bg = ColorRect.new()
	_log_bg.color    = Color(0.07, 0.09, 0.12, 0.88)
	_log_bg.position = Vector2(5, 5)
	_log_bg.size     = Vector2(248, 950)
	_log_bg.visible  = _log_visible
	add_child(_log_bg)

	_log = RichTextLabel.new()
	_log.bbcode_enabled  = true
	_log.scroll_active   = true
	_log.position        = Vector2(8, 8)
	_log.size            = Vector2(242, 944)
	_log.add_theme_font_size_override("normal_font_size", 10)
	_log.visible         = _log_visible
	add_child(_log)

	# ── Right column labels (graveyard x=1590, deck x=1750) ──────────────────────
	_add_label("P2 grave",  Vector2(1590,  52), 11, Color(0.5, 0.4, 0.4))
	_add_label("P2 deck",   Vector2(1750,  52), 11, Color(0.4, 0.4, 0.5))
	_add_label("P1 grave",  Vector2(1590, 832), 11, Color(0.4, 0.5, 0.4))
	_add_label("P1 deck",   Vector2(1750, 832), 11, Color(0.4, 0.4, 0.5))

	# Status label must exist before renderer.set_status_label is called below.
	# Positioned under the pass button (centered) once the control panel is built below.
	_status = _add_label("", Vector2(760, 1025), 15, Color(0.5, 0.8, 0.5))
	_status.size = Vector2(400, 40)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Renderer
	_renderer = BoardRenderer.new()
	add_child(_renderer)

	# Zone anchors.
	# Board rows (centre x=1000): p2_hand → p2_resource → p2_hero → p2_ally → chain
	#   → p1_ally → p1_hero → p1_resource → p1_hand
	# hero_row sits between ally_row and resource_row (rule 415.8a: hero card,
	# equipment, and non-attaching ongoing abilities all live in the hero row).
	# Right column (x=1820): p2_deck at top; p1_deck at bottom.
	# Graveyard at x=1640, same y as the player's hand.
	# Row centres are spaced CardNode.H + 10px apart so full rows never overlap
	# a neighbouring row, regardless of which rows are empty or filled. Every
	# row anchor is a fixed constant — no runtime repositioning depends on
	# another zone's contents.
	_renderer.register_zone("p2_hand",         _make_anchor(Vector2(1000,  35)))
	_renderer.register_zone("p2_resource_row", _make_anchor(Vector2(1000, 165)))
	_renderer.register_zone("p2_hero_row",     _make_anchor(Vector2(1000, 280)))
	_renderer.register_zone("p2_ally_row",     _make_anchor(Vector2(1000, 395)))
	_renderer.register_zone("chain",           _make_anchor(Vector2(1000, 455)))
	_renderer.register_zone("p1_ally_row",     _make_anchor(Vector2(1000, 505)))
	_renderer.register_zone("p1_hero_row",     _make_anchor(Vector2(1000, 620)))
	_renderer.register_zone("p1_resource_row", _make_anchor(Vector2(1000, 735)))
	_renderer.register_zone("p1_hand",         _make_anchor(Vector2(1000, 895)))
	_renderer.register_zone("p2_graveyard",    _make_anchor(Vector2(1640,  35)))
	_renderer.register_zone("p2_deck",         _make_anchor(Vector2(1820,  35)))
	_renderer.register_zone("p1_graveyard",    _make_anchor(Vector2(1640, 875)))
	_renderer.register_zone("p1_deck",         _make_anchor(Vector2(1820, 875)))

	# Hero card itself stays pinned to the side column, above the deck, at the
	# same height as its hero_row (equipment / ongoing abilities live there instead).
	_renderer.register_zone("p2_hero_card",    _make_anchor(Vector2(1820, 280)))
	_renderer.register_zone("p1_hero_card",    _make_anchor(Vector2(1820, 620)))

	_renderer.set_status_label(_status)

	# ── Deck slot card-back sprites ────────────────────────────────────────────────
	for deck_zone in ["p1_deck", "p2_deck"]:
		var deck_anchor := _renderer.zone_anchors.get(deck_zone) as Node2D
		if deck_anchor:
			_add_deck_back_sprite(deck_anchor.global_position)

	_router = InputRouter.new()
	add_child(_router)
	_renderer.set_input_router(_router)
	_router.targeting_started.connect(_on_targeting_started)
	_router.targeting_cancelled.connect(_on_targeting_cancelled)
	_router.totem_target_resolved.connect(_on_totem_target_resolved)
	_router.discard_mode_started.connect(_on_discard_mode_started)
	_router.discard_mode_ended.connect(_on_discard_mode_ended)
	_router.pet_sacrifice_mode_ended.connect(_on_pet_sacrifice_mode_ended)
	_router.control_discard_mode_ended.connect(_on_control_discard_mode_ended)
	_router.equipment_sacrifice_mode_ended.connect(_on_equipment_sacrifice_mode_ended)
	_router.x_select_requested.connect(_on_x_select_requested)
	_router.graveyard_select_requested.connect(_on_graveyard_select_requested)
	_router.graveyard_examine_requested.connect(_on_graveyard_examine_requested)
	_router.graveyard_peek_requested.connect(_on_graveyard_peek_requested)
	_router.graveyard_peek_closed.connect(_on_graveyard_peek_closed)
	_build_x_dialog()
	_build_graveyard_dialog()

	# ── Control panel (y=960..1080) ───────────────────────────────────────────────
	# Panel background — added before labels/buttons so it renders behind them.
	var ctrl_panel := Panel.new()
	ctrl_panel.position = Vector2(0, 960)
	ctrl_panel.size     = Vector2(1920, 120)
	add_child(ctrl_panel)

	var sep_line := ColorRect.new()
	sep_line.color    = Color(0.28, 0.33, 0.38)
	sep_line.position = Vector2(0, 960)
	sep_line.size     = Vector2(1920, 2)
	add_child(sep_line)

	# ── Left section: Turn / Priority / Announcer ──────────────────────────────
	_phase_label    = _add_label("", Vector2(16, 971), 19, Color(0.9, 0.85, 0.45))
	_priority_label = _add_label("", Vector2(120, 1003), 15, Color(0.9, 0.85, 0.3))
	# _status now lives under the pass button (centre section) instead of here.
	_add_label("Log [L]", Vector2(16, 1003), 13, Color(0.55, 0.55, 0.6))

	# ── VSep 1 ─────────────────────────────────────────────────────────────────
	var vsep1 := ColorRect.new()
	vsep1.color    = Color(0.28, 0.33, 0.38)
	vsep1.position = Vector2(624, 968)
	vsep1.size     = Vector2(2, 110)
	add_child(vsep1)

	# ── Centre section: Cancel + Pass ──────────────────────────────────────────
	_cancel_btn = Button.new()
	_cancel_btn.text     = "Cancel  [Esc]"
	_cancel_btn.position = Vector2(648, 981)
	_cancel_btn.size     = Vector2(160, 40)
	_cancel_btn.visible  = false
	_cancel_btn.pressed.connect(_on_cancel_btn_pressed)
	add_child(_cancel_btn)

	_pass_btn = Button.new()
	_pass_btn.text     = "Pass Priority  [Space]"
	_pass_btn.position = Vector2(845, 981)
	_pass_btn.size     = Vector2(230, 40)
	_pass_btn.pressed.connect(_on_pass_btn_pressed)
	add_child(_pass_btn)

	# Resource-placement indicator (aligned with the pass button, to its left).
	_resource_label = _add_label("", Vector2(648, 981), 15, Color(1.0, 0.3, 0.3))
	_resource_label.size = Vector2(190, 40)
	_resource_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_resource_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	# ── Mulligan panel (replaces pass area during mulligan phase) ──────────────
	_mulligan_panel = VBoxContainer.new()
	_mulligan_panel.position = Vector2(760, 420)
	_mulligan_panel.custom_minimum_size = Vector2(400, 110)
	_mulligan_panel.visible  = false
	add_child(_mulligan_panel)

	_mulligan_order_label = Label.new()
	_mulligan_order_label.add_theme_font_size_override("font_size", 14)
	_mulligan_order_label.add_theme_color_override("font_color", Color(0.9, 0.78, 0.35))
	_mulligan_order_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mulligan_panel.add_child(_mulligan_order_label)

	_mulligan_ready_btn = Button.new()
	_mulligan_ready_btn.text = "Ready  (keep hand)"
	_mulligan_ready_btn.pressed.connect(func() -> void: _commit_mulligan(false))
	_mulligan_panel.add_child(_mulligan_ready_btn)

	_mulligan_btn = Button.new()
	_mulligan_btn.text = "Mulligan  (shuffle & redraw)"
	_mulligan_btn.pressed.connect(func() -> void: _commit_mulligan(true))
	_mulligan_panel.add_child(_mulligan_btn)

	# ── VSep 2 ─────────────────────────────────────────────────────────────────
	var vsep2 := ColorRect.new()
	vsep2.color    = Color(0.28, 0.33, 0.38)
	vsep2.position = Vector2(1296, 968)
	vsep2.size     = Vector2(2, 110)
	add_child(vsep2)

	# ── Right section: Speed Mode selector ─────────────────────────────────────
	_add_label("SPEED MODE  [T]", Vector2(1330, 971), 10, Color(0.55, 0.55, 0.55))

	var mode_group := ButtonGroup.new()

	_turbo_btn = Button.new()
	_turbo_btn.text          = "Turbo"
	_turbo_btn.position      = Vector2(1330, 987)
	_turbo_btn.size          = Vector2(110, 36)
	_turbo_btn.toggle_mode   = true
	_turbo_btn.button_group  = mode_group
	_turbo_btn.button_pressed = true
	_turbo_btn.toggled.connect(func(on: bool) -> void: if on: _set_turbo_mode(true))
	add_child(_turbo_btn)

	_tactical_btn = Button.new()
	_tactical_btn.text         = "Tactical"
	_tactical_btn.position     = Vector2(1330, 1027)
	_tactical_btn.size         = Vector2(110, 36)
	_tactical_btn.toggle_mode  = true
	_tactical_btn.button_group = mode_group
	_tactical_btn.toggled.connect(func(on: bool) -> void: if on: _set_turbo_mode(false))
	add_child(_tactical_btn)

	_mode_desc_label = _add_label("Auto-pass all 'no legal play'",
		Vector2(1330, 1067), 10, Color(0.42, 0.52, 0.42))

	# Mirrors the resource-placement indicator on the other side of the pass button
	# (resource label: x=648, same y as the button); now docked to the right of
	# the speed mode selector.
	_mulligan_hint_label = _add_label(
		"Left-click = play/place\nRight-click = options\nEsc = retract\nCtrl+Space = wrap up / end turn\nF = auto-pass combat windows",
		Vector2(1470, 979), 11, Color(0.38, 0.38, 0.38))
	_mulligan_hint_label.size = Vector2(200, 96)
	_mulligan_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_mulligan_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_mulligan_hint_label.visible = false

	# ── Far right: Animation speed slider (scales every GameTiming pause live) ──
	# animation_speed: 0 = instant (no pauses), 1 = base timing, up to 3x slower.
	var speed_lbl := _add_label("Speed", Vector2(1690, 971), 10, Color(0.55, 0.55, 0.55))
	speed_lbl.size = Vector2(180, 16)
	_speed_slider = HSlider.new()
	_speed_slider.position   = Vector2(1690, 995)
	_speed_slider.size       = Vector2(180, 24)
	_speed_slider.min_value  = 0.0
	_speed_slider.max_value  = 3.0
	_speed_slider.step       = 0.1
	_speed_slider.value      = GameTiming.animation_speed
	_speed_slider.value_changed.connect(func(v: float) -> void:
		GameTiming.animation_speed = v
		if _speed_value_label:
			_speed_value_label.text = "%.1fx" % v)
	add_child(_speed_slider)
	_speed_value_label = _add_label("%.1fx" % GameTiming.animation_speed,
		Vector2(1690, 1025), 11, Color(0.6, 0.6, 0.65))

	_ai_timer = Timer.new()
	_ai_timer.wait_time = AI_THINK_TIME
	_ai_timer.one_shot  = true
	_ai_timer.timeout.connect(_do_ai_turn)
	add_child(_ai_timer)

	# Self-healing reconcile: repeatedly snap any settled-but-crooked card back to
	# its true orientation. Idempotent + skips in-flight animations, so a plain
	# recurring tick is robust without precise idle detection.
	_reconcile_timer = Timer.new()
	_reconcile_timer.wait_time = RECONCILE_TICK
	_reconcile_timer.one_shot  = false
	_reconcile_timer.timeout.connect(func() -> void:
		if _renderer and _state:
			_renderer.reconcile_from_state(_state))
	add_child(_reconcile_timer)
	_reconcile_timer.start()

	_context_menu = PopupMenu.new()
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)

	_renderer.card_right_clicked.connect(_on_card_right_clicked)
	_renderer.card_clicked.connect(_on_card_clicked_scene)

	_end_turn_dialog = ConfirmationDialog.new()
	_end_turn_dialog.title = "Wrap up without playing?"
	_end_turn_dialog.dialog_text = "You haven't played anything this turn.\nMove to end phase anyway?"
	_end_turn_dialog.ok_button_text     = "Yes, wrap up"
	_end_turn_dialog.cancel_button_text = "No, I'll play something"
	_end_turn_dialog.confirmed.connect(_on_end_turn_confirmed)
	add_child(_end_turn_dialog)

	if not EventBus.game_event.is_connected(_on_game_event):
		EventBus.game_event.connect(_on_game_event)


# ── Menu ───────────────────────────────────────────────────────────────────────

func _build_menu() -> void:
	_menu_layer = CanvasLayer.new()
	_menu_layer.layer = 20
	add_child(_menu_layer)

	var overlay := ColorRect.new()
	overlay.color = Color(0.05, 0.07, 0.09, 0.88)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_layer.add_child(overlay)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-280, -170)
	panel.custom_minimum_size = Vector2(560, 340)
	_menu_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	panel.add_child(vbox)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 18)
	margin.add_child(inner)

	var title := Label.new()
	title.text = "WoW TCG — Match Setup"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	inner.add_child(title)

	var ai_ids := DeckManager.list_ai_profile_ids()
	_p1_ai_types = ["human", "recommended"]
	_p1_ai_types.append_array(ai_ids)
	_p2_ai_types = ["recommended"]
	_p2_ai_types.append_array(ai_ids)
	var p1_labels: Array[String] = ["Human", "Recommended AI"]
	for id in ai_ids:
		p1_labels.append(_ai_profile_label(id))
	var p2_labels: Array[String] = ["Recommended AI"]
	for id in ai_ids:
		p2_labels.append(_ai_profile_label(id))

	inner.add_child(_player_row("Player 1", p1_labels, 0,
		CAT_ALL,
		func(opt): _p1_type_opt = opt, func(opt): _p1_cat_opt = opt, func(opt): _p1_deck_opt = opt))
	_p1_strategy_label = _make_strategy_label()
	inner.add_child(_p1_strategy_label)
	inner.add_child(_player_row("Player 2", p2_labels, 0,
		CAT_RECOMMENDED,
		func(opt): _p2_type_opt = opt, func(opt): _p2_cat_opt = opt, func(opt): _p2_deck_opt = opt))
	_p2_strategy_label = _make_strategy_label()
	inner.add_child(_p2_strategy_label)
	_p1_cat_opt.item_selected.connect(func(idx): _repopulate_deck_opt("p1", idx))
	_p2_cat_opt.item_selected.connect(func(idx): _repopulate_deck_opt("p2", idx))
	_p1_deck_opt.item_selected.connect(func(_idx): _update_strategy_label("p1"))
	_p2_deck_opt.item_selected.connect(func(_idx): _update_strategy_label("p2"))
	_repopulate_deck_opt("p1", CAT_ALL)
	_repopulate_deck_opt("p2", CAT_RECOMMENDED)

	_avoid_mirror_cb = CheckBox.new()
	_avoid_mirror_cb.text = "Avoid mirror matches"
	_avoid_mirror_cb.button_pressed = true
	inner.add_child(_avoid_mirror_cb)

	_menu_error_label = Label.new()
	_menu_error_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	_menu_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_error_label.visible = false
	inner.add_child(_menu_error_label)

	var btn_box := HBoxContainer.new()
	btn_box.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_box.add_theme_constant_override("separation", 16)
	inner.add_child(btn_box)

	var quick_btn := Button.new()
	quick_btn.text = "Quick Start"
	quick_btn.custom_minimum_size = Vector2(140, 40)
	quick_btn.pressed.connect(_on_quick_start)
	btn_box.add_child(quick_btn)

	var start_btn := Button.new()
	start_btn.text = "Start Game"
	start_btn.custom_minimum_size = Vector2(140, 40)
	start_btn.pressed.connect(_on_start_game)
	btn_box.add_child(start_btn)


func _player_row(label_text: String, type_items: Array, type_default: int,
		cat_default: int,
		type_cb: Callable, cat_cb: Callable, deck_cb: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(74, 0)
	row.add_child(lbl)

	var type_opt := OptionButton.new()
	type_opt.custom_minimum_size = Vector2(145, 0)
	for item in type_items:
		type_opt.add_item(item)
	type_opt.selected = type_default
	row.add_child(type_opt)
	type_cb.call(type_opt)

	var cat_opt := OptionButton.new()
	cat_opt.custom_minimum_size = Vector2(160, 0)
	for item in CATEGORY_LABELS:
		cat_opt.add_item(item)
	cat_opt.selected = cat_default
	row.add_child(cat_opt)
	cat_cb.call(cat_opt)

	var dlbl := Label.new()
	dlbl.text = "Deck:"
	row.add_child(dlbl)

	var deck_opt := OptionButton.new()
	deck_opt.custom_minimum_size = Vector2(185, 0)
	row.add_child(deck_opt)
	deck_cb.call(deck_opt)

	return row


# Display label for an ai_profiles/*.json id, e.g. "ai_generic" -> "Generic AI".
func _ai_profile_label(ai_id: String) -> String:
	var stem := ai_id.trim_prefix("ai_")
	return "%s AI" % stem.capitalize()


# Deck ids for one category dropdown value ("Random" sentinel not included).
func _deck_ids_for_category(cat_index: int) -> Array[String]:
	var index := DeckManager.get_available_decks()
	if cat_index == CAT_RECOMMENDED:
		return index.recommended_ai.duplicate()
	return index.all()


func _repopulate_deck_opt(player_key: String, cat_index: int) -> void:
	var opt := _p1_deck_opt if player_key == "p1" else _p2_deck_opt
	var stored: Array[String] = []
	opt.clear()
	for deck_id in _deck_ids_for_category(cat_index):
		var deck_def := DeckManager.load_deck(deck_id)
		if deck_def == null:
			continue
		stored.append(deck_id)
		opt.add_item(deck_def.display_name)
	stored.append(DECK_RANDOM)
	opt.add_item("Random")
	opt.selected = stored.size() - 1   # default to Random
	if player_key == "p1":
		_p1_deck_ids = stored
	else:
		_p2_deck_ids = stored
	_update_strategy_label(player_key)


# A muted, wrapping one-line strategy blurb shown under a player's deck picker.
func _make_strategy_label() -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(520, 0)
	return lbl


# Show the selected deck's strategy blurb (blank for Random / no strategy).
func _update_strategy_label(player_key: String) -> void:
	var opt := _p1_deck_opt if player_key == "p1" else _p2_deck_opt
	var ids := _p1_deck_ids if player_key == "p1" else _p2_deck_ids
	var lbl := _p1_strategy_label if player_key == "p1" else _p2_strategy_label
	if lbl == null or opt.selected < 0 or opt.selected >= ids.size():
		return
	var deck_id := ids[opt.selected]
	var text := ""
	if deck_id != DECK_RANDOM:
		var deck_def := DeckManager.load_deck(deck_id)
		if deck_def != null:
			text = deck_def.strategy
	lbl.text = text


# Resolve both deck picks, honoring "avoid mirror matches". Returns
# [p1_deck_id, p2_deck_id], or [] if the matchup is a refused mirror.
func _resolve_matchup(p1_pick: String, p1_pool: Array[String],
		p2_pick: String, p2_pool: Array[String], avoid_mirror: bool) -> Array[String]:
	if p1_pick != DECK_RANDOM and p2_pick != DECK_RANDOM:
		if avoid_mirror and p1_pick == p2_pick:
			return []
		return [p1_pick, p2_pick]

	var r1 := p1_pick
	if r1 == DECK_RANDOM:
		var pool := p1_pool.duplicate()
		pool.erase(DECK_RANDOM)
		if avoid_mirror and p2_pick != DECK_RANDOM:
			pool.erase(p2_pick)
		if pool.is_empty():
			return []
		r1 = pool.pick_random()

	var r2 := p2_pick
	if r2 == DECK_RANDOM:
		var pool := p2_pool.duplicate()
		pool.erase(DECK_RANDOM)
		if avoid_mirror:
			pool.erase(r1)
		if pool.is_empty():
			return []
		r2 = pool.pick_random()

	return [r1, r2]


func _show_menu_error(msg: String) -> void:
	_menu_error_label.text = msg
	_menu_error_label.visible = true


func _on_quick_start() -> void:
	_menu_error_label.visible = false
	var resolved := _resolve_matchup(
		DECK_RANDOM, _deck_ids_for_category(CAT_ALL),
		DECK_RANDOM, _deck_ids_for_category(CAT_RECOMMENDED),
		_avoid_mirror_cb.button_pressed)
	if resolved.is_empty():
		_show_menu_error("No non-mirror matchup possible — uncheck 'Avoid mirror matches'.")
		return
	_launch_game("human", resolved[0], "recommended", resolved[1])


func _on_start_game() -> void:
	_menu_error_label.visible = false
	var resolved := _resolve_matchup(
		_p1_deck_ids[_p1_deck_opt.selected], _p1_deck_ids,
		_p2_deck_ids[_p2_deck_opt.selected], _p2_deck_ids,
		_avoid_mirror_cb.button_pressed)
	if resolved.is_empty():
		_show_menu_error("Mirror match — pick different decks or uncheck 'Avoid mirror matches'.")
		return
	_launch_game(_p1_ai_types[_p1_type_opt.selected], resolved[0],
				 _p2_ai_types[_p2_type_opt.selected], resolved[1])


func _launch_game(p1_type: String, p1_deck_id: String,
		p2_type: String, p2_deck_id: String) -> void:
	_log.clear()
	_log_in_mulligan = false
	_pending_exhaust.clear()
	_menu_layer.visible = false
	_p1_type = p1_type
	_p2_type = p2_type
	_last_p1_deck_id = p1_deck_id
	_last_p2_deck_id = p2_deck_id
	_p1_ai   = _make_ai(p1_type, p1_deck_id)
	_p2_ai   = _make_ai(p2_type, p2_deck_id)
	_setup_game_state(DeckManager.get_runtime_deck(p1_deck_id),
					  DeckManager.get_runtime_deck(p2_deck_id))


# type is "" / "human" (no AI), "recommended" (deck's recommended_ai_id), or
# an ai_profiles/*.json id (e.g. "ai_generic") straight from the dropdown.
func _make_ai(type: String, deck_id: String) -> Object:
	match type:
		"", "human":   return null
		"recommended": return DeckManager.make_ai_for_deck(deck_id)
		_:
			var profile := DeckManager.load_ai_profile(type)
			return profile.make_ai() if profile else null


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

func _setup_game_state(deck_p1: Deck, deck_p2: Deck) -> void:
	# Real database — only engine_status=implemented cards are loaded.
	_db = CardDatabase.new()
	_db.load_csv("res://data/cards.csv")

	# Mock-only cards (no CSV row yet): instants and quest placeholder.
	_db.add_def(_make_mock_def("mock_quick_shot", "Quick Shot", 0, 0, true, "Ability"))
	_db.add_def(_make_mock_def("mock_dark_bolt",  "Dark Bolt",  0, 0, true, "Ability"))

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

	# Spawn CardNodes for all zones that can contain visible cards.
	for zone_id in ["p1_hero_row", "p1_hand", "p1_ally_row", "p1_resource_row", "p1_graveyard",
					"p2_hero_row", "p2_hand", "p2_ally_row", "p2_resource_row", "p2_graveyard",
					"chain"]:
		var color := Color(0.25, 0.45, 0.75) if zone_id.begins_with("p1") else Color(0.5, 0.25, 0.25)
		if zone_id == "chain":
			color = Color(1.0, 1.0, 1.0)
		_spawn_zone_nodes(zone_id, color)

	# Init hero HP bars at full health.
	for pid in ["p1", "p2"]:
		var ps := _state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			_renderer.register_hero_card(pid, ps.hero_instance_id)
			var max_hp := _state.get_max_hp(ps.hero_instance_id, _db)
			_renderer.init_hero_bar(pid, ps.hero_instance_id, max_hp)

	# Spread starting hand cards before the first event fires.
	_renderer.relayout_zone("p1_hand")
	_renderer.relayout_zone("p2_hand")

	_router.setup(_state, _db, "p1")

	# Randomize who goes first.
	var first_player: String = "p1" if randi() % 2 == 0 else "p2"

	# Start the game — fires phase_changed (ready) which sets up the first window.
	var events := TurnManager.start_game(_state, first_player, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


# Spawn CardNode visuals for every card currently in a zone.
# Cards drawn later will be spawned by _on_game_event("card_moved").
func _spawn_zone_nodes(zone_id: String, color: Color) -> void:
	var zone := _state.zones.get(zone_id) as Zone
	if not zone:
		return
	var anchor := _renderer.zone_anchors.get(zone_id) as Node2D
	var spawn_pos := anchor.global_position if anchor else Vector2.ZERO
	for inst_id in zone.card_ids:
		_spawn_card_node(inst_id, spawn_pos, color)


func _spawn_card_node(inst_id: String, spawn_pos: Vector2, color: Color) -> void:
	if _renderer.has_card_node(inst_id):
		return
	var card := _state.get_card(inst_id)
	if not card:
		return
	var def := _db.get_def(card.card_def_id) as CardDef
	var node: CardNode
	if not def:
		push_warning("_spawn_card_node: no CardDef for '%s' (card_def_id=%s) — showing placeholder" % [inst_id, card.card_def_id])
		node = CardNode.create(inst_id, "?? " + card.card_def_id, "MISSING DEF", Color(0.4, 0.4, 0.4))
	else:
		var stats := "%d/%d" % [def.printed_atk, def.printed_health]
		node = CardNode.create(inst_id, def.card_name, stats, color, def.image_path)
	node.global_position = spawn_pos
	add_child(node)
	_renderer.register_card(inst_id, node)
	_renderer.place_card_in_zone(inst_id, card.zone_id)


# ── UI refresh ─────────────────────────────────────────────────────────────────

func _refresh_ui() -> void:
	_update_priority_label()
	_update_phase_label()
	if not _in_protect_mode and not _in_strike_mode:
		_router.refresh_highlights()
	_update_pass_btn()
	_update_cancel_btn()
	# Self-healing hand fans: reconcile renderer bookkeeping with game state
	# (no-op when already correct — see BoardRenderer.sync_zone_with_state).
	if _state and _renderer:
		for hand_zone_id in ["p1_hand", "p2_hand"]:
			var hz := _state.zones.get(hand_zone_id) as Zone
			if hz:
				_renderer.sync_zone_with_state(hand_zone_id, hz.card_ids)


func _turn_label(turn_number: int) -> String:
	var round_num: int = (turn_number + 1) / 2
	var suffix: String = "a" if turn_number % 2 == 1 else "b"
	return "%d%s" % [round_num, suffix]


func _update_phase_label() -> void:
	var names := {
		"mulligan": "Mulligan",
		"ready": "Ready Step", "draw": "Draw Step",
		"action": "Action Phase", "end": "End Phase",
	}
	var phase_str: String = names.get(_state.phase, _state.phase)
	_phase_label.text = "Turn %s  ·  %s  ·  %s's turn" % [
		_turn_label(_state.turn_number), phase_str, _state.turn_player]


func _update_priority_label() -> void:
	var who := _state.priority_player
	var chain_str: String
	if _state.pending_actions.is_empty():
		chain_str = "Chain : empty"
	else:
		var items: Array[String] = []
		for a in _state.pending_actions:
			items.append(_describe_pending_action(a as PendingAction))
		chain_str = "Chain : " + ", ".join(items)
	_priority_label.text = "Priority: %s\n%s" % [who, chain_str]
	_priority_label.add_theme_color_override("font_color",
		Color(0.4, 0.9, 0.4) if who == "p1" else Color(0.9, 0.5, 0.4))


func _describe_pending_action(action: PendingAction) -> String:
	if action.action_type == "propose_combat":
		return "%s attacks %s" % [
			_log_card(action.params.get("attacker_id", "")),
			_log_card(action.params.get("defender_id", "")),
		]
	var name := _pending_action_card_name(action)
	match action.action_type:
		"play_ally":            return "Play %s" % name
		"play_instant":         return "%s (instant)" % name
		"play_ability":         return "%s (ability)" % name
		"play_equipment":       return "Equip %s" % name
		"place_resource":       return "Resource: %s" % name
		"use_quest":            return "Quest: %s" % name
		"use_armor_prevention": return "Block: %s" % name
		"use_ally_power":       return "%s (power)" % name
		"activate_power":       return "%s (hero power)" % name
		_:                      return "%s (%s)" % [name, action.action_type]


func _pending_action_card_name(action: PendingAction) -> String:
	var card_id: String = action.params.get("card_id", "")
	if card_id == "":
		card_id = action.params.get("quest_id", "")
	if card_id == "":
		card_id = action.params.get("hero_id", "")
	if card_id == "" or not _db:
		return action.action_type
	var card := _state.get_card(card_id)
	if not card:
		return action.action_type
	var def := _db.get_def(card.card_def_id) as CardDef
	return def.card_name if def else action.action_type


func _update_cancel_btn() -> void:
	_cancel_btn.visible = StackResolver.can_retract(_state, "p1")


func _update_resource_label() -> void:
	if not _resource_label:
		return
	if _state.turn_player != "p1":
		_resource_label.text = "not my turn"
		_resource_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		return
	var ps: PlayerState = _state.players.get("p1")
	if ps and ps.resource_placed_this_turn:
		_resource_label.text = "resource placed"
		_resource_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.35))
	else:
		_resource_label.text = "resource to be placed"
		_resource_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))


func _update_pass_btn() -> void:
	_update_resource_label()
	var my_turn    := _state.priority_player == "p1"
	var has_plays  := _router.has_any_legal_play()
	var chain_busy := not _state.pending_actions.is_empty()
	var in_action  := _state.phase == "action"
	var in_attack  := _state.combat_attack_window
	var in_defend  := _state.combat_defend_window
	var is_p1_turn := _state.turn_player == "p1"

	_pass_btn.disabled = not my_turn or _state.pending_pet_sacrifice_player == "p1" \
		or _state.pending_equip_sacrifice_player == "p1" \
		or _state.pending_control_discard_player == "p2"

	if _state.pending_control_discard_player == "p1":
		# Infernal choice: the pass button is the DECLINE option (give control).
		_pass_btn.disabled = false
		_pass_btn.text     = "Give up control  [Ctrl+Space]"
		_pass_btn.modulate = Color(1.0, 0.6, 0.0)
	elif _state.pending_pet_sacrifice_player == "p1":
		_pass_btn.text     = "Sacrifice a pet  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif _state.pending_equip_sacrifice_player == "p1":
		_pass_btn.text     = "Destroy equipment  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif _router.is_awaiting_chain_lightning_optional_target():
		_pass_btn.text     = "Skip target  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif not my_turn:
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif not has_plays:
		# Wrap-up / end-turn passes require Ctrl+Space (plain Space can't end your
		# turn — prevents accidental skips); other passes stay on Space.
		if in_action:
			_pass_btn.text = "No legal play — Wrap Up  [Ctrl+Space]"
		elif _state.phase == "end":
			_pass_btn.text = "No legal play — %s  [Ctrl+Space]" \
					% ("End Turn" if is_p1_turn else "Take Turn")
		else:
			_pass_btn.text = "No legal play — Pass  [Space]"
		_pass_btn.modulate = Color(1.0, 0.35, 0.35)
	elif chain_busy:
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(1.0, 1.0, 1.0)
	elif in_attack:
		_pass_btn.text     = "Attack window : fight on!  [Space] · auto-pass [F]"
		_pass_btn.modulate = Color(1.0, 0.6, 0.0)
	elif in_defend:
		_pass_btn.text     = "Defense window : fight on!  [Space] · auto-pass [F]"
		_pass_btn.modulate = Color(1.0, 0.6, 0.0)
	elif in_action:
		_pass_btn.text     = "Wrap Up  [Ctrl+Space]"
		_pass_btn.modulate = Color(0.65, 0.65, 0.65)
	elif _state.phase == "end":
		_pass_btn.text     = ("End Turn  [Ctrl+Space]" if is_p1_turn else "Take Turn  [Ctrl+Space]")
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
	# Ctrl+Space is the ONLY way to wrap up / end the turn from the keyboard. Plain
	# Space never ends the turn (see the wrap-up guard below), so it can't be pressed
	# by accident. Ctrl+Space is a deliberate two-key combo → skip the confirm dialog.
	# (A modifier makes the physical event stop matching the plain-Space "ui_accept"
	# action, so it needs its own branch by keycode.)
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE \
			and event.ctrl_pressed:
		if (_x_dialog and _x_dialog.visible) \
				or (_gy_dialog and _gy_dialog.visible and not _gy_peek_active):
			get_viewport().set_input_as_handled()
			return
		# Infernal: Ctrl+Space gives up control (declines the discard). Gated behind
		# Ctrl so a stray plain-Space can't hand the card to the opponent by mistake.
		# Handled on its own (NOT via the wrap-up burst) so giving up control doesn't
		# also try to end the turn — it's a start-of-turn choice, the turn continues.
		if _state.pending_control_discard_player == "p1":
			_router.decline_control_discard()
			_refresh_ui()
			_schedule_next_turn()
			get_viewport().set_input_as_handled()
			return
		_wrap_up_active = true
		_try_pass(true)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_accept"):
		# If the X dialog is open, Enter confirms it (the LineEdit grabs Enter via text_submitted,
		# but we also handle it here for the case where focus has drifted to the OK button).
		if _x_dialog and _x_dialog.visible:
			_confirm_x_value(_x_input.text)
			get_viewport().set_input_as_handled()
			return
		# Graveyard browser open: Space must not pass priority underneath the modal.
		if _gy_dialog and _gy_dialog.visible and not _gy_peek_active:
			get_viewport().set_input_as_handled()
			return
		# Plain Space must not end the turn — that requires Ctrl+Space. Absorb it
		# so an accidental tap can't skip the turn.
		if _is_wrap_up_pass():
			_set_status("Press Ctrl+Space to wrap up / end your turn")
			get_viewport().set_input_as_handled()
			return
		# Same protection for Infernal's give-up-control: plain Space must not
		# hand the card to the opponent. Ctrl+Space (or clicking the pass
		# button / a hand card to discard) is required.
		if _state.pending_control_discard_player == "p1":
			_set_status("Press Ctrl+Space to give up control, or click a card to discard")
			get_viewport().set_input_as_handled()
			return
		_try_pass()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		# Escape: close the X dialog (cancels the whole power use).
		if _x_dialog and _x_dialog.visible:
			_x_dialog.visible = false
			CardNode.input_blocked = false
			_router.cancel_targeting()
			_set_status("")
			get_viewport().set_input_as_handled()
			return
		# Escape: close/cancel the graveyard browser.
		if _gy_dialog and _gy_dialog.visible and not _gy_peek_active:
			_on_gy_cancel_pressed()
			get_viewport().set_input_as_handled()
			return
	# T toggles Turbo ⇄ Tactical. Chaining multiple instants (e.g. two Quick Strikes
	# against a 4-HP attacker) needs Tactical, since Turbo auto-passes after each of the
	# human's own chain links. Toggle to Tactical, play the chain, pass manually, then
	# toggle back. Ignored while the X-value dialog is open (the user may be typing).
	elif event is InputEventKey and event.pressed and event.keycode == KEY_T \
			and not (_x_dialog and _x_dialog.visible):
		_toggle_speed_mode()
		get_viewport().set_input_as_handled()
	# L toggles the game log panel (hidden by default so it doesn't clutter the board).
	elif event is InputEventKey and event.pressed and event.keycode == KEY_L \
			and not (_x_dialog and _x_dialog.visible):
		_log_visible = not _log_visible
		_log_bg.visible = _log_visible
		_log.visible    = _log_visible
		get_viewport().set_input_as_handled()
	# F during one of the human's combat windows: auto-pass the attack AND defend
	# windows in one go, stopping only if the opponent responds. (F, not C — C is
	# the graveyard-confirm key.)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F \
			and not (_gy_dialog and _gy_dialog.visible) \
			and not (_x_dialog and _x_dialog.visible) \
			and _can_auto_pass_combat():
		_auto_pass_combat = true
		_set_status("Auto-passing combat — will stop if the opponent responds")
		_drain_passes()
		get_viewport().set_input_as_handled()
	# C confirms the graveyard selection (matches the "Confirm (C)" button).
	elif event is InputEventKey and event.pressed and event.keycode == KEY_C \
			and _gy_dialog and _gy_dialog.visible and not _gy_peek_active:
		if not _gy_view_only and not _gy_confirm_btn.disabled:
			_on_gy_confirm_pressed()
		get_viewport().set_input_as_handled()
	# Right-click outside the graveyard dialog → cancel/close it.
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
			and event.pressed and _gy_dialog and _gy_dialog.visible and not _gy_peek_active:
		if not _gy_dialog.get_global_rect().has_point(get_viewport().get_mouse_position()):
			_on_gy_cancel_pressed()
			get_viewport().set_input_as_handled()
	# Right-click on empty space while targeting → cancel targeting.
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
			and event.pressed and _router and _router._targeting_source != "":
		_router.cancel_targeting()
		get_viewport().set_input_as_handled()


func _on_cancel_btn_pressed() -> void:
	_router.retract_last_action()


func _on_pass_btn_pressed() -> void:
	_try_pass()


# Gate for human passing: shows a confirmation if they'd end their action phase
# without having played a single card or instant this turn.
func _try_pass(skip_confirm: bool = false) -> void:
	if not _state or _p1_type != "human":
		return
	# Infernal choice pending for the human: Space/pass = decline the discard
	# and give the opponent control of the source.
	if _state.pending_control_discard_player == "p1":
		_router.decline_control_discard()
		_refresh_ui()
		_schedule_next_turn()
		return
	if _state.priority_player != "p1":
		return
	var needs_confirm := (
		_state.turn_player == "p1"
		and _state.phase == "action"
		and _state.pending_actions.is_empty()
		and not _p1_played_this_action_phase
	)
	if needs_confirm and not skip_confirm:
		_end_turn_dialog.popup_centered()
	else:
		_router.pass_priority_action()
		_blink_pass_btn()
		# The pass may have resolved a chained action (quest, hero/ally power…)
		# whose resolution events don't include "priority_passed" or a
		# "card_moved" from the chain — nothing else re-arms the AI timer.
		_schedule_next_turn()
		_maybe_turbo_pass()


func _on_end_turn_confirmed() -> void:
	# Player confirmed they want to pass — do it for them (no need to press again).
	_router.pass_priority_action()
	_blink_pass_btn()
	_schedule_next_turn()
	_maybe_turbo_pass()


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


# ── Game log ───────────────────────────────────────────────────────────────────

func _log_card(id: String) -> String:
	if not _state:
		return id
	var card := _state.get_card(id)
	if not card:
		return id
	if _db:
		var def := _db.get_def(card.card_def_id) as CardDef
		if def:
			return def.card_name
	return card.card_def_id


func _log_player(pid: String) -> String:
	return "P1" if pid == "p1" else "P2"


func _log_entry(text: String) -> void:
	_log.append_text(text + "\n")
	_log.scroll_to_line(_log.get_line_count())


func _flush_pending_exhaust(skip_player: String = "") -> void:
	for p in _pending_exhaust.keys().duplicate():
		if p == skip_player:
			continue
		var n: int = _pending_exhaust[p]
		if n > 0:
			var col := "#888"
			_log_entry("[color=%s]%s exhausts %d resource%s[/color]" % [col, _log_player(p), n, ("" if n == 1 else "s")])
		_pending_exhaust.erase(p)


func _log_event(event: GameEvent) -> void:
	if event.event_type == "card_exhausted":
		if _state:
			var ci := _state.get_card(event.payload.get("card", ""))
			if ci and ci.zone_id.ends_with("_resource_row"):
				var card_owner: String = ci.owner
				_pending_exhaust[card_owner] = _pending_exhaust.get(card_owner, 0) + 1
		return
	if event.event_type != "card_moved" or _log_in_mulligan:
		_flush_pending_exhaust()
	match event.event_type:
		"turn_changed":
			var n: int    = event.payload.get("turn", 0)
			var p: String = _log_player(event.payload.get("player", ""))
			_log_entry("\n[color=#d4af37]═══════════════[/color]")
			_log_entry("[color=#d4af37][b][font_size=15]Turn %s · %s[/font_size][/b][/color]" % [_turn_label(n), p])
			_log_entry("[color=#d4af37]═══════════════[/color]")
		"phase_changed":
			var ph: String = event.payload.get("new", "")
			match ph:
				"draw":
					_log_entry("[color=#555]draw phase[/color]")
				"action":
					_log_entry("[color=#555]action phase[/color]")
		"mulligan_phase_started":
			_log_in_mulligan = true
			_log_entry("[color=#888]── Mulligan ──[/color]")
		"mulligan_committed":
			var p: String    = _log_player(event.payload.get("player", ""))
			var wants: bool  = event.payload.get("mulligan", false)
			var msg := "%s %s" % [p, ("mulligans" if wants else "keeps hand")]
			_log_entry("[color=#888]%s[/color]" % msg)
		"card_moved":
			if _log_in_mulligan:
				return
			var from_z: String = event.payload.get("from", "")
			var to_z:   String = event.payload.get("to", "")
			var cid:    String = event.payload.get("card", "")
			if from_z.ends_with("_deck") and to_z.ends_with("_hand"):
				var card_owner := cid.split("_")[0] if "_" in cid else "p?"
				if _state:
					var ci := _state.get_card(cid)
					if ci:
						card_owner = ci.owner
				var col := "#7af" if card_owner == "p1" else "#fa8"
				_log_entry("[color=%s]%s draws a card[/color]" % [col, _log_player(card_owner)])
			elif from_z.ends_with("_hand") and (to_z.ends_with("_ally_row") or to_z.ends_with("_hero_row")):
				var card_owner := ""
				if _state:
					var ci := _state.get_card(cid)
					if ci:
						card_owner = ci.owner
				_flush_pending_exhaust(card_owner)
				var col := "#7af" if card_owner == "p1" else "#fa8"
				var n: int = _pending_exhaust.get(card_owner, 0)
				_pending_exhaust.erase(card_owner)
				if n > 0:
					_log_entry("[color=%s]%s exhausts %d resource%s to play [b]%s[/b][/color]" % [col, _log_player(card_owner), n, ("" if n == 1 else "s"), _log_card(cid)])
				else:
					_log_entry("[color=%s]%s plays [b]%s[/b][/color]" % [col, _log_player(card_owner), _log_card(cid)])
		"resource_placed":
			var p:  String = _log_player(event.payload.get("player", ""))
			var face_up: bool = event.payload.get("face_up", false)
			if face_up:
				var cid: String = event.payload.get("card_id", "")
				_log_entry("[color=#888]%s places %s face-up[/color]" % [p, _log_card(cid)])
			else:
				_log_entry("[color=#888]%s places a card face-down[/color]" % p)
		"action_proposed":
			if event.payload.get("action_type", "") == "propose_combat":
				var p: String = _log_player(event.payload.get("player", ""))
				var patt: String = _log_card(event.payload.get("attacker_id", ""))
				var pdef: String = _log_card(event.payload.get("defender_id", ""))
				_log_entry("[color=#fc8]%s proposes: %s attacks %s[/color]" % [p, patt, pdef])
		"action_fizzled":
			if event.payload.get("action_type", "") == "propose_combat":
				_log_entry("[color=#a66]-- combat proposal fizzled --[/color]")
		"combat_started":
			var att: String = _log_card(event.payload.get("attacker_id", ""))
			var def: String = _log_card(event.payload.get("defender_id", ""))
			_log_entry("[color=#fc8][b]%s ⚔ %s[/b][/color]" % [att, def])
		"attack_window_opened":
			_window_generation += 1
			_set_status("⚔ Attack window — you may respond before protect")
			_set_combat_highlight(event.payload.get("attacker_id", ""), event.payload.get("defender_id", ""))
			_refresh_ui()
			# The pass that resolved propose_combat may have been the human's, in
			# which case no priority_passed event follows and nothing else drives
			# the AI — same reason defend_window_opened drains below.
			_drain_passes()
		"defend_window_opened":
			_window_generation += 1
			_set_status("⚔ Defend window — you may respond before damage")
			# Defender may now be a protector that swapped in during protect point,
			# so re-highlight rather than assume the attack-window pair still holds.
			_set_combat_highlight(event.payload.get("attacker_id", ""), event.payload.get("defender_id", ""))
			_refresh_ui()
			_drain_passes()  # human chose protector; drain the defend window
		"damage_dealt":
			var src:    String = _log_card(event.payload.get("source", ""))
			var tgt:    String = _log_card(event.payload.get("target", ""))
			var amt:    int    = event.payload.get("amount", 0)
			_log_entry("[color=#f66]%s receives %d dmg from %s[/color]" % [tgt, amt, src])
		"hp_changed":
			var old_hp: int = event.payload.get("old_hp", 0)
			var new_hp: int = event.payload.get("new_hp", 0)
			if new_hp > old_hp:
				var tgt_name: String = _log_card(event.payload.get("card", ""))
				var src_id:   String = event.payload.get("source", "")
				var healed:   int    = new_hp - old_hp
				if src_id != "":
					var src_name: String = _log_card(src_id)
					_log_entry("[color=#8f8]%s healed %s for %d hp[/color]" % [src_name, tgt_name, healed])
				else:
					_log_entry("[color=#8f8]%s healed for %d hp[/color]" % [tgt_name, healed])
		"card_destroyed":
			var card_name: String = _log_card(event.payload.get("card",   ""))
			var source: String = event.payload.get("source", "")
			if source != "":
				var src_name: String = _log_card(source)
				_log_entry("[color=#f44][b]%s destroyed by %s[/b][/color]" % [card_name, src_name])
			else:
				_log_entry("[color=#f44][b]%s destroyed[/b][/color]" % card_name)
		"instant_resolved":
			var p: String   = _log_player(event.payload.get("player", ""))
			var cid: String = event.payload.get("card_id", "")
			var col := "#7af" if event.payload.get("player", "") == "p1" else "#fa8"
			_log_entry("[color=%s]%s plays [b]%s[/b][/color]" % [col, p, _log_card(cid)])
		"hero_power_used":
			var p: String = _log_player(event.payload.get("player", ""))
			_log_entry("[color=#aef]%s hero power[/color]" % p)
		"ally_power_used":
			var p: String   = _log_player(event.payload.get("player", ""))
			var cid: String = event.payload.get("ally_id", "")
			var target_id: String = event.payload.get("target_id", "")
			if target_id != "":
				_log_entry("[color=#aef]%s activated [b]%s[/b] on %s[/color]" % [p, _log_card(cid), _log_card(target_id)])
			else:
				_log_entry("[color=#aef]%s activated [b]%s[/b][/color]" % [p, _log_card(cid)])
		"quest_completed":
			var p:  String = _log_player(event.payload.get("player", ""))
			var cid: String = event.payload.get("quest_id", "")
			_log_entry("[color=#af8]%s completes %s[/color]" % [p, _log_card(cid)])
		"reveal_pick_resolved":
			var rp:  String = _log_player(event.payload.get("player", ""))
			var rcid: String = event.payload.get("card_id", "")
			_log_entry("[color=#af8]%s takes %s (rest to bottom of deck)[/color]" % [rp, _log_card(rcid)])
		"armor_prevention_used":
			var p:  String = _log_player(event.payload.get("player", ""))
			var cid: String = event.payload.get("card_id", "")
			var d:   int    = event.payload.get("def", 0)
			_log_entry("[color=#9cf]%s exhausts [b]%s[/b] to block %d dmg[/color]" % [p, _log_card(cid), d])
		"damage_prevented":
			var tgt: String = _log_card(event.payload.get("target_id", ""))
			var amt: int    = event.payload.get("amount", 0)
			_log_entry("[color=#9cf]%s blocks %d dmg[/color]" % [tgt, amt])
		"game_over":
			var winner: String = _log_player(event.payload.get("winner", ""))
			_log_entry("\n[color=#d4af37][b]═══ %s WINS ═══[/b][/color]" % winner)


# ── AI ─────────────────────────────────────────────────────────────────────────

func _do_ai_turn() -> void:
	if _game_over:
		return
	if _state.in_protect_point or _in_protect_mode:
		return
	var pid := _state.priority_player
	var ai: Object = _p1_ai if pid == "p1" else _p2_ai
	if ai == null:
		return   # human's turn
	var action: PendingAction = ai.decide_action(_state, _db, pid)
	var events: Array[GameEvent]
	if action != null:
		events = StackResolver.submit_action(_state, action, _db)
	else:
		events = StackResolver.pass_priority(_state, _db)
	await EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()


# ── Event reactions ────────────────────────────────────────────────────────────

func _on_game_event(event: GameEvent) -> void:
	_log_event(event)
	match event.event_type:
		"priority_passed":
			if event.payload.get("player", "") == "p2":
				_blink_pass_btn()
			_refresh_ui()
			var _in_chain := not _state.pending_actions.is_empty()
			if _state.combat_attack_window or _state.combat_defend_window or _in_chain:
				_drain_passes()
			else:
				_schedule_next_turn()
				_maybe_turbo_pass()
		"action_proposed":
			if event.payload.get("player") == "p1":
				_p1_played_this_action_phase = true
			if event.payload.get("action_type", "") == "propose_combat":
				_set_proposed_combat_highlight(
					event.payload.get("attacker_id", ""), event.payload.get("defender_id", ""))
			_refresh_ui()
			_drain_passes()
		"card_moved":
			# A card drawn from deck needs a fresh CardNode spawned at the hand anchor.
			var to_zone: String   = event.payload.get("to", "")
			var from_zone: String = event.payload.get("from", "")
			var moved_id: String  = event.payload.get("card", "")
			# Sound: draw = deck→hand (card grab); play = hand→anywhere else.
			if from_zone.ends_with("_deck") and to_zone.ends_with("_hand"):
				SoundManager.play_random("SFX_CardGrab")
			elif from_zone.ends_with("_hand") and not to_zone.ends_with("_hand"):
				SoundManager.play_random("SFX_CardMoveFast")
			# Show summoning-sickness badge when an ally enters the ally_row from hand.
			if to_zone.ends_with("_ally_row") and from_zone.ends_with("_hand") and _state and _db:
				var sick_card := _state.get_card(moved_id)
				if sick_card and sick_card.just_summoned:
					var sick_def := _db.get_def(sick_card.card_def_id) as CardDef
					var is_ferocity := sick_def != null and "ferocity" in sick_def.keywords
					var sick_cn := _renderer.card_nodes.get(moved_id) as CardNode
					if sick_cn:
						sick_cn.show_sick_badge(is_ferocity)
			if to_zone.ends_with("_hand") and not _renderer.has_card_node(moved_id):
				var card := _state.get_card(moved_id)
				if card:
					var is_p1 := card.owner == "p1"
					var hand_zone := "p1_hand" if is_p1 else "p2_hand"
					var hand_anchor := _renderer.zone_anchors.get(hand_zone) as Node2D
					var spawn_pos := hand_anchor.global_position if hand_anchor else (Vector2(1000, 875) if is_p1 else Vector2(1000, 35))
					var color := Color(0.25, 0.45, 0.75) if is_p1 else Color(0.5, 0.25, 0.25)
					_spawn_card_node(moved_id, spawn_pos, color)
					# Renderer's _animate_move already ran before this node existed,
					# so trigger the layout manually now that the node is registered.
					_renderer.relayout_zone(to_zone)
			_refresh_ui()
			if event.payload.get("from", "") == "chain":
				_schedule_next_turn()
		"action_retracted":
			if event.payload.get("action_type", "") == "propose_combat":
				_clear_combat_highlight()
			_refresh_ui()
		"action_fizzled":
			if event.payload.get("action_type", "") == "propose_combat":
				_clear_combat_highlight()
			_refresh_ui()
			_maybe_turbo_pass()
		"phase_changed":
			if event.payload.get("new") == "action" and event.payload.get("player") == "p1":
				_p1_played_this_action_phase = false
			_refresh_ui()
			_maybe_turbo_pass()
		"priority_window_closed":
			# Defer so this event finishes dispatching before TurnManager fires new ones.
			call_deferred("_on_window_closed")
		"deck_empty":
			_set_status("Deck empty for %s" % event.payload.get("player", "?"))
		"combat_concluded":
			if _in_protect_mode:
				_resolve_protection("")   # safety: clean up any orphaned protect UI
			_clear_combat_highlight()
			_set_status("")
			_refresh_ui()
			_schedule_next_turn()
		"protect_point_opened":
			_window_generation += 1
			_handle_protect_point(event.payload)
		"strike_point_opened":
			_window_generation += 1
			_handle_strike_point(event.payload)
		"weapon_struck":
			var w_card := _state.get_card(event.payload.get("weapon_id", ""))
			var w_def: CardDef = _db.get_def(w_card.card_def_id) if w_card else null
			_set_status("⚔ %s strikes with %s" % [event.payload.get("player", "?"),
				w_def.card_name if w_def else "a weapon"])
			_refresh_ui()
		"discard_choice_opened":
			_handle_discard_choice(event.payload)
		"pet_sacrifice_required":
			_handle_pet_sacrifice(event.payload)
		"control_discard_choice_opened":
			_handle_control_discard(event.payload)
		"equipment_sacrifice_required":
			_handle_equipment_sacrifice(event.payload)
		"reveal_pick_opened":
			_handle_reveal_pick(event.payload)
		"enter_play_target_required":
			_handle_enter_play_target(event.payload)
		"totem_target_required":
			_handle_totem_target(event.payload)
		"mulligan_phase_started":
			_handle_mulligan_started(event.payload)
		"mulligan_committed":
			pass
		"mulligan_phase_ended":
			_log_in_mulligan = false
			_mulligan_panel.visible      = false
			_pass_btn.visible            = true
			_mulligan_hint_label.visible = true
		"game_over":
			_handle_game_over(event.payload)
	_refresh_atk_badges()


# Recompute the current ATK of every in-play ally/hero and show/hide the
# buff badge on its CardNode accordingly. Called after every event since
# buffs can appear, disappear, or gate on combat state ("while_attacking")
# without a dedicated event of their own.
func _refresh_atk_badges() -> void:
	if not _state or not _db:
		return
	for pid in _state.players:
		for zone_suffix in ["_ally_row", "_hero_row"]:
			for card in _state.cards_in_zone(pid + zone_suffix):
				var cn := _renderer.card_nodes.get(card.instance_id) as CardNode
				if not cn:
					continue
				var def := _db.get_def(card.card_def_id) as CardDef
				if not def:
					continue
				cn.update_atk(_state.get_atk(card.instance_id, _db), def.printed_atk,
						_state.get_atk_if_attacking(card.instance_id, _db))
				cn.update_hp(_state.get_max_hp(card.instance_id, _db), def.printed_health)


func _on_window_closed() -> void:
	var events := TurnManager.advance_phase(_state, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()


func _handle_mulligan_started(payload: Dictionary) -> void:
	var first: String = payload.get("first_player", "")
	_p1_has_mulliganed = false

	# Show the mulligan panel for the human player; hide the normal pass button.
	if _p1_type == "human":
		_pass_btn.visible        = false
		_mulligan_panel.visible  = true
		_mulligan_btn.disabled   = false
		_mulligan_order_label.text = \
			"You go first!" if first == "p1" else "Opponent goes first."

	# All AI players commit immediately (always keep — simple heuristic).
	var player_order: Array = payload.get("player_order", [])
	if player_order.is_empty():
		for pid in _state.players:
			player_order.append(pid)
	for pid in player_order:
		if _state.mulligan_decided.get(pid, false):
			continue   # already committed (e.g. chain reaction)
		var pid_type := _p1_type if pid == "p1" else _p2_type
		if pid_type != "human":
			var pid_ai: Object = _p1_ai if pid == "p1" else _p2_ai
			var wants: bool = pid_ai.wants_mulligan(_state, _db, pid) if pid_ai else false
			var events := TurnManager.commit_mulligan(_state, pid, wants, _db)
			_emit_mulligan_events(events)


func _commit_mulligan(wants: bool) -> void:
	if wants:
		_p1_has_mulliganed    = true
		_mulligan_btn.disabled = true
	var events := TurnManager.commit_mulligan(_state, "p1", wants, _db)
	_emit_mulligan_events(events)
	_refresh_ui()


# Emit mulligan events in two phases separated by mulligan_shuffle_done.
# Phase 1 (hand→deck + shuffle marker) fires immediately.
# Phase 2 (deck→hand + game start) fires after a short delay so the renderer
# has time to finish the hand→deck animations before redraw nodes arrive.
func _emit_mulligan_events(events: Array[GameEvent]) -> void:
	var split := -1
	for i in events.size():
		if events[i].event_type == "mulligan_shuffle_done":
			split = i
			break
	if split == -1:
		EventBus.emit_events(events)
		return
	EventBus.emit_events(events.slice(0, split + 1))
	_refresh_ui()
	var phase2: Array[GameEvent] = events.slice(split + 1)
	get_tree().create_timer(0.45).timeout.connect(func() -> void:
		EventBus.emit_events(phase2)
		_refresh_ui()
		_schedule_next_turn()
		_maybe_turbo_pass())


func _on_card_right_clicked(instance_id: String) -> void:
	# Right-click during targeting always cancels — no context menu mid-targeting.
	if _router and _router._targeting_source != "":
		_router.cancel_targeting()
		return
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
	_set_status("Choose %d card(s) to discard — click a highlighted hand card" % count)
	_refresh_ui()


func _on_discard_mode_ended() -> void:
	_set_status("")
	_refresh_ui()
	if _discard_reason == "wrap_up":
		_discard_reason = "card_effect"
		call_deferred("_on_window_closed")
	else:
		_schedule_next_turn()
		_maybe_turbo_pass()


var _discard_reason: String = "card_effect"


func _on_control_discard_mode_ended() -> void:
	_set_status("")
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


func _on_pet_sacrifice_mode_ended() -> void:
	_set_status("")
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


func _on_equipment_sacrifice_mode_ended() -> void:
	_set_status("")
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


func _handle_equipment_sacrifice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var candidates: Array = payload.get("candidates", [])
	var player_type := _p1_type if player == "p1" else _p2_type
	if player_type != "human":
		# AI: keep the highest-cost equipment, destroy the rest.
		var keep_id := _pick_ai_equipment_keep(player, candidates)
		for cid: String in candidates:
			if cid == keep_id:
				continue
			var events := StackResolver.choose_equipment_sacrifice(_state, cid, _db)
			if not events.is_empty():
				EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: highlight all same-slot equipment; click one to destroy it.
		_router.start_equipment_sacrifice_mode(candidates)
		_set_status("Slot limit exceeded — click a highlighted equipment to destroy it")
		_refresh_ui()


# Returns the instance_id the AI wants to KEEP (the others get destroyed).
# Strategy: keep highest-cost equipment; tie-break by first in list.
func _pick_ai_equipment_keep(_player_id: String, candidates: Array) -> String:
	var best_id: String = candidates[0] if not candidates.is_empty() else ""
	var best_cost := -1
	for cid: String in candidates:
		var c := _state.get_card(cid)
		var def := _db.get_def(c.card_def_id) as CardDef if c and _db else null
		var cost := def.cost if def else 0
		if cost > best_cost:
			best_cost = cost
			best_id = cid
	return best_id


func _handle_discard_choice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var count: int     = payload.get("count", 1)
	_discard_reason    = payload.get("reason", "card_effect")
	if player == "p2":
		# AI: the AI instance picks each discard (BaseAI: lowest-cost non-quest;
		# GenericAI: least valuable via sort_valuable_cards).
		for _i in count:
			var pick_id := ""
			if _p2_ai is BaseAI:
				pick_id = (_p2_ai as BaseAI).choose_discard_card(_state, _db, "p2")
			else:
				var pick := _pick_ai_discard("p2")
				pick_id = pick.instance_id if pick else ""
			if pick_id == "":
				break
			var events := StackResolver.choose_discard(_state, pick_id, _db)
			EventBus.emit_events(events)
		_refresh_ui()
		if _discard_reason == "wrap_up":
			# Wrap-up done — advance to next player's turn.
			call_deferred("_on_window_closed")
		else:
			_schedule_next_turn()
	else:
		# Human (p1): enter discard mode — green highlights + click to resolve.
		_router.start_discard_mode(count)


# Returns the CardInstance the AI should discard from player_id's hand.
# Priority: lowest-cost non-quest/location card; fall back to random quest/location.
func _pick_ai_discard(player_id: String) -> CardInstance:
	var hand := _state.cards_in_zone(player_id + "_hand")
	if hand.is_empty():
		return null
	var non_resource: Array = []
	var resource_only: Array = []
	for card in hand:
		var def: CardDef = _db.get_def(card.card_def_id) if _db else null
		if def and def.card_type in ["Quest", "Location"]:
			resource_only.append(card)
		else:
			non_resource.append(card)
	if not non_resource.is_empty():
		non_resource.sort_custom(func(a, b) -> bool:
			var da: CardDef = _db.get_def(a.card_def_id) if _db else null
			var db_: CardDef = _db.get_def(b.card_def_id) if _db else null
			return (da.cost if da else 0) < (db_.cost if db_ else 0))
		return non_resource[0]
	return resource_only[randi() % resource_only.size()]


# Infernal: "discard a card, or target opponent gains control of [this]."
# Unlike a mandatory discard, the player may decline (Space / pass button).
func _handle_control_discard(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var source_id: String = payload.get("source", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	if player_type != "human":
		# AI: a 6-drop body is almost always worth a spare card — discard the
		# least valuable hand card; decline (give control) only with an empty hand.
		var ai: Object = _p1_ai if player == "p1" else _p2_ai
		var pick_id := ""
		if not _state.cards_in_zone(player + "_hand").is_empty():
			if ai is BaseAI:
				pick_id = (ai as BaseAI).choose_discard_card(_state, _db, player)
			else:
				var pick := _pick_ai_discard(player)
				pick_id = pick.instance_id if pick else ""
		var events := StackResolver.choose_control_discard(_state, pick_id, _db) \
				if pick_id != "" else StackResolver.decline_control_discard(_state, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_router.start_control_discard_mode(source_id)
		_set_status("%s: click a card to discard, or press Space to give the opponent control"
				% _log_card(source_id))
		_refresh_ui()


func _handle_pet_sacrifice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var candidates: Array = payload.get("candidates", [])
	var player_type := _p1_type if player == "p1" else _p2_type
	if player_type != "human":
		# AI: pick which pet to sacrifice (keep the best one, remove the rest).
		var keep_id := _pick_ai_pet_keep(player, candidates)
		for cid: String in candidates:
			if cid == keep_id:
				continue
			var events := StackResolver.choose_pet_sacrifice(_state, cid, _db)
			if not events.is_empty():
				EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: highlight all candidate pets; click one to sacrifice it.
		_router.start_pet_sacrifice_mode(candidates)
		_set_status("Pet limit exceeded — click a highlighted pet to sacrifice it")
		_refresh_ui()


# Returns the instance_id the AI wants to KEEP (the others get sacrificed).
# Strategy: keep highest-cost pet; tie-break by highest current HP; then random.
func _pick_ai_pet_keep(_player_id: String, candidates: Array) -> String:
	if candidates.is_empty():
		return ""
	var best: String = candidates[0]
	var best_cost := -1
	var best_hp := -1
	for cid: String in candidates:
		var card := _state.get_card(cid)
		if not card:
			continue
		var def: CardDef = _db.get_def(card.card_def_id) if _db else null
		var cost: int = def.cost if def else 0
		var hp: int = _state.get_current_hp(cid, _db)
		if cost > best_cost or (cost == best_cost and hp > best_hp):
			best_cost = cost
			best_hp = hp
			best = cid
	return best


# Reveal-and-pick quest reward (Big Game Hunter / Kibler's Exotic Pets / Zapped
# Giants): the top cards were revealed and at least one matches the required type.
# The controller keeps one; the rest go to the bottom of the deck.
func _handle_reveal_pick(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var selectable: Array = payload.get("selectable", [])
	var revealed: Array = payload.get("revealed", [])
	var card_type: String = payload.get("card_type", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	if player_type != "human":
		# AI keeps the most valuable revealed card of the required type.
		var pick_id := _pick_ai_reveal(selectable)
		var events := StackResolver.choose_reveal_pick(_state, pick_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: reuse the browser modal, but as a mandatory single pick (no cancel).
		_open_gy_dialog(selectable, false,
				"Revealed top %d — choose a %s card to keep (rest go to bottom of deck)"
						% [revealed.size(), card_type], 1, 1)
		_gy_reveal_mode = true
		_gy_cancel_btn.visible = false
		_set_status("Choose a %s card to put into your hand" % card_type)
		_refresh_ui()


# AI reveal-pick: keep the highest-cost card, tie-broken by total stats.
func _pick_ai_reveal(candidates: Array) -> String:
	if candidates.is_empty():
		return ""
	var best: String = candidates[0]
	var best_score := -999999
	for cid: String in candidates:
		var card := _state.get_card(cid)
		if not card:
			continue
		var def: CardDef = _db.get_def(card.card_def_id) if _db else null
		if not def:
			continue
		var score: int = def.cost * 100 + def.printed_atk + def.printed_health
		if score > best_score:
			best_score = score
			best = cid
	return best


func _handle_enter_play_target(payload: Dictionary) -> void:
	var card_id: String  = payload.get("card_id", "")
	var dmg_type: String = payload.get("dmg_type", "")
	var amount: int      = payload.get("amount", 0)
	var card := _state.get_card(card_id)
	if not card:
		return
	var ctrl := card.controller
	var ctrl_type := _p1_type if ctrl == "p1" else _p2_type
	if ctrl_type != "human":
		# AI picks a random valid target — opponents only, never self-harm.
		var opp := "p2" if ctrl == "p1" else "p1"
		var targets: Array = []
		var ps_opp := _state.players.get(opp) as PlayerState
		if ps_opp and ps_opp.hero_instance_id != "":
			var act := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": card_id, "target_id": ps_opp.hero_instance_id})
			if StackResolver.can_submit(_state, act, _db):
				targets.append(ps_opp.hero_instance_id)
		for ally in _state.cards_in_zone(opp + "_ally_row"):
			var act := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": card_id, "target_id": ally.instance_id})
			if StackResolver.can_submit(_state, act, _db):
				targets.append(ally.instance_id)
		if not targets.is_empty():
			# Prefer targets that die to this damage. find_lethal returns only the
			# hero when the hero is lethal (see game_logic/ai/ai_functions.md).
			var lethal := BaseAI.find_lethal(_state, _db, ctrl, amount)
			var pool: Array[String] = []
			for tid in lethal:
				if tid in targets:
					pool.append(tid)
			var target_id: String
			if not pool.is_empty():
				# The controlling AI ranks the kills; take its top pick.
				var ai_obj: Object = _p1_ai if ctrl == "p1" else _p2_ai
				if ai_obj is BaseAI:
					pool = (ai_obj as BaseAI).rank_lethal_targets(_state, _db, pool)
				target_id = pool[0]
			else:
				target_id = targets[randi() % targets.size()]
			var action := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": card_id, "target_id": target_id})
			var events := StackResolver.submit_action(_state, action, _db)
			EventBus.emit_events(events)
			var pass_events := StackResolver.pass_priority(_state, _db)
			EventBus.emit_events(pass_events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: enter targeting mode to pick a target.
		_router.start_enter_play_targeting(card_id, dmg_type, amount)
		_refresh_ui()


# Ongoing Totem "at the start of each turn" targeted damage (Searing Totem). The
# totem's controller must pick a hero or ally. Mandatory, direct-call resolution.
func _handle_totem_target(payload: Dictionary) -> void:
	var card_id: String  = payload.get("card_id", "")
	var ctrl: String     = payload.get("player", "")
	var dmg_type: String = payload.get("dmg_type", "")
	var amount: int      = payload.get("amount", 0)
	var ctrl_type := _p1_type if ctrl == "p1" else _p2_type
	if ctrl_type != "human":
		# AI picks a target: prefer an opposing character it can kill with this
		# damage, else the opposing hero. Never self-harm (AI convention).
		var opp := "p2" if ctrl == "p1" else "p1"
		var targets: Array[String] = []
		var ps_opp := _state.players.get(opp) as PlayerState
		if ps_opp and ps_opp.hero_instance_id != "":
			targets.append(ps_opp.hero_instance_id)
		for ally in _state.cards_in_zone(opp + "_ally_row"):
			targets.append(ally.instance_id)
		var legal := StackResolver.get_totem_targets(_state, _db)
		targets = targets.filter(func(t): return t in legal)
		var target_id := ""
		if not targets.is_empty():
			var lethal := BaseAI.find_lethal(_state, _db, ctrl, amount)
			var pool: Array[String] = []
			for tid in lethal:
				if tid in targets:
					pool.append(tid)
			if not pool.is_empty():
				var ai_obj: Object = _p1_ai if ctrl == "p1" else _p2_ai
				if ai_obj is BaseAI:
					pool = (ai_obj as BaseAI).rank_lethal_targets(_state, _db, pool)
				target_id = pool[0]
			else:
				target_id = targets[0]   # default: opposing hero (first in list)
		var events := StackResolver.choose_totem_target(_state, target_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: enter targeting mode to pick the target hero or ally.
		_router.start_totem_targeting(card_id, dmg_type, amount)
		_refresh_ui()


# A human finished picking a Totem trigger's target (or the queue advanced). Resume
# driving the turn; if another totem trigger is now pending, its handler already
# restarted targeting and _schedule_next_turn no-ops on the pending guard.
func _on_totem_target_resolved() -> void:
	_refresh_ui()
	_schedule_next_turn()


func _on_targeting_started(source_id: String, dmg_type: String, _dmg_amount: int) -> void:
	var card := _state.get_card(source_id) as CardInstance
	var def: CardDef = _db.get_def(card.card_def_id) if card else null
	var name_str := def.card_name if def else source_id
	if dmg_type == "heal":
		_set_status("✚ %s — select a target to heal  [Esc to cancel]" % name_str)
	else:
		_set_status("⚔ %s — select a target  [Esc to cancel]" % name_str)
	_refresh_ui()


func _on_targeting_cancelled() -> void:
	_set_status("")
	# If an enters-play effect is still pending, targeting is mandatory — restart it.
	# Exception: if a choose_enter_play_target action is already on the chain, the human
	# already picked a target; don't restart (pending_enter_play_effect clears later when
	# both players pass and the action resolves).
	if _state and not _state.pending_enter_play_effect.is_empty():
		var target_queued := false
		for a in _state.pending_actions:
			if (a as PendingAction).action_type == "choose_enter_play_target":
				target_queued = true
				break
		if not target_queued:
			var eff := _state.pending_enter_play_effect
			_router.start_enter_play_targeting(
				eff.get("card_id", ""), eff.get("dmg_type", ""), eff.get("amount", 0))
			return
	_refresh_ui()


# ── X-select dialog ────────────────────────────────────────────────────────────

func _build_x_dialog() -> void:
	_x_dialog = Panel.new()
	_x_dialog.visible = false
	_x_dialog.custom_minimum_size = Vector2(280, 120)
	_x_dialog.z_index = 20
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 12)
	_x_dialog.add_child(vbox)

	_x_label = Label.new()
	_x_label.text = "Choose X (1 – ?):"
	_x_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_x_label)

	_x_input = LineEdit.new()
	_x_input.placeholder_text = "enter X"
	_x_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_x_input.text_submitted.connect(_on_x_submitted)
	vbox.add_child(_x_input)

	_x_ok_btn = Button.new()
	_x_ok_btn.text = "OK"
	_x_ok_btn.pressed.connect(_on_x_ok_pressed)
	vbox.add_child(_x_ok_btn)

	add_child(_x_dialog)


func _on_x_select_requested(hero_id: String, max_x: int) -> void:
	_x_hero_id = hero_id
	_x_max = max_x
	_x_label.text = "Choose X (1 – %d):" % max_x
	_x_input.text = ""
	# Centre the dialog in the viewport.
	var vp := get_viewport().get_visible_rect().size
	_x_dialog.position = (vp - _x_dialog.custom_minimum_size) * 0.5
	_x_dialog.visible = true
	CardNode.input_blocked = true
	_x_input.grab_focus()
	var hero_card := _router.state.get_card(hero_id) if _router.state else null
	var hero_def: CardDef = _router.db.get_def(hero_card.card_def_id) if hero_card and _router.db else null
	if hero_def and StackResolver._power_effect_is(hero_def, "heal_x_from_target"):
		_set_status("Enter X resources to pay — Boris heals X from target hero or ally")
	else:
		_set_status("Enter X damage Dizdemona deals to herself and to target ally")


func _on_x_submitted(text: String) -> void:
	_confirm_x_value(text)


func _on_x_ok_pressed() -> void:
	_confirm_x_value(_x_input.text)


func _confirm_x_value(text: String) -> void:
	var x := text.strip_edges().to_int()
	if x < 1 or x > _x_max:
		_x_input.text = ""
		_x_input.placeholder_text = "1 – %d" % _x_max
		_x_input.grab_focus()
		return
	_x_dialog.visible = false
	CardNode.input_blocked = false
	_set_status("")
	_router.confirm_x_value(x)


# ── Graveyard browser dialog ───────────────────────────────────────────────────
# Modal overlay: fans out candidate graveyard cards; click toggles selection,
# Confirm submits via InputRouter.confirm_graveyard_selection.

const GY_CARD_SIZE := Vector2(150, 210)

func _build_graveyard_dialog() -> void:
	_gy_dimmer = ColorRect.new()
	_gy_dimmer.color = Color(0, 0, 0, 0.6)
	_gy_dimmer.size = Vector2(1920, 1080)
	_gy_dimmer.visible = false
	_gy_dimmer.z_index = 19
	add_child(_gy_dimmer)

	_gy_dialog = Panel.new()
	_gy_dialog.visible = false
	_gy_dialog.z_index = 20
	add_child(_gy_dialog)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 16)
	vbox.add_theme_constant_override("separation", 12)
	_gy_dialog.add_child(vbox)

	_gy_title = Label.new()
	_gy_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gy_title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(_gy_title)

	# Cards wrap into rows; the scroll container caps the dialog height when
	# the graveyard grows large.
	_gy_scroll = ScrollContainer.new()
	_gy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_gy_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_gy_scroll)

	_gy_card_grid = GridContainer.new()
	_gy_card_grid.add_theme_constant_override("h_separation", 14)
	_gy_card_grid.add_theme_constant_override("v_separation", 14)
	_gy_card_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gy_scroll.add_child(_gy_card_grid)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 24)
	vbox.add_child(btn_row)

	_gy_confirm_btn = Button.new()
	_gy_confirm_btn.text = "Confirm (C)"
	_gy_confirm_btn.custom_minimum_size = Vector2(140, 36)
	_gy_confirm_btn.pressed.connect(_on_gy_confirm_pressed)
	btn_row.add_child(_gy_confirm_btn)

	_gy_cancel_btn = Button.new()
	_gy_cancel_btn.text = "Cancel (Esc)"
	_gy_cancel_btn.custom_minimum_size = Vector2(140, 36)
	_gy_cancel_btn.pressed.connect(_on_gy_cancel_pressed)
	btn_row.add_child(_gy_cancel_btn)


func _on_graveyard_select_requested(quest_id: String, candidate_ids: Array,
		min_count: int, max_count: int) -> void:
	var quest_card := _state.get_card(quest_id)
	var quest_def: CardDef = _db.get_def(quest_card.card_def_id) if quest_card else null
	var quest_name := quest_def.card_name if quest_def else "Quest"
	var count_str := ("%d" % min_count) if min_count == max_count \
			else "%d – %d" % [min_count, max_count]
	var source := "graveyard"
	if quest_def and StackResolver.get_graveyard_search_requirement(quest_def).get("source", "graveyard") == "deck":
		source = "deck"
	_open_gy_dialog(candidate_ids, false,
			"%s — choose %s card(s) from your %s" % [quest_name, count_str, source],
			min_count, max_count)


func _on_graveyard_examine_requested(graveyard_player: String, card_ids: Array) -> void:
	var who := "Your" if graveyard_player == "p1" else "Opponent's"
	_open_gy_dialog(card_ids, true,
			"%s graveyard — %d card(s)" % [who, card_ids.size()], 0, 0)


# Alt+hover peek: same visual as examine, but non-modal (no dimmer, no buttons)
# so it can't steal hover away from the graveyard card driving it, and closes
# the instant Alt is released or the cursor leaves the pile.
func _on_graveyard_peek_requested(graveyard_player: String, card_ids: Array) -> void:
	var who := "Your" if graveyard_player == "p1" else "Opponent's"
	_open_gy_dialog(card_ids, true,
			"%s graveyard — %d card(s)" % [who, card_ids.size()], 0, 0, false)


func _on_graveyard_peek_closed() -> void:
	if _gy_peek_active:
		_close_gy_dialog()


# Shared open path for both selection and examine modes. Sizes the dialog to
# the card count: cards wrap at GY_MAX_COLS per row, height is capped and the
# grid scrolls beyond that.
const GY_MAX_COLS := 9
const GY_MAX_DIALOG_H := 920

func _open_gy_dialog(card_ids: Array, view_only: bool, title: String,
		min_count: int, max_count: int, modal: bool = true) -> void:
	_gy_selected.clear()
	_gy_view_only = view_only
	_gy_peek_active = not modal
	_gy_min = min_count
	_gy_max = max_count
	_gy_title.text = title

	for child in _gy_card_grid.get_children():
		child.queue_free()
	var count: int = max(card_ids.size(), 1)
	var cols: int = clamp(count, 1, GY_MAX_COLS)
	_gy_card_grid.columns = cols
	for cid in card_ids:
		_gy_card_grid.add_child(_make_gy_card_button(cid as String))

	_gy_confirm_btn.visible = not view_only and modal
	_gy_cancel_btn.visible = modal
	_gy_cancel_btn.text = "Close (Esc)" if view_only else "Cancel (Esc)"
	# Peek mode must never block board input — no dimmer, and the panel itself
	# lets clicks/hover pass through to the cards underneath.
	_gy_dialog.mouse_filter = Control.MOUSE_FILTER_STOP if modal else Control.MOUSE_FILTER_IGNORE

	# Size to content: width from columns, height from rows (capped → scrolls).
	var rows: int = ceili(float(count) / cols)
	var content_w: int = cols * int(GY_CARD_SIZE.x + 14) + 60
	var content_h: int = rows * int(GY_CARD_SIZE.y + 14) + 140
	_gy_dialog.size = Vector2(max(content_w, 480), min(content_h, GY_MAX_DIALOG_H))
	_gy_dialog.position = (Vector2(1920, 1080) - _gy_dialog.size) * 0.5
	_gy_dimmer.visible = modal
	_gy_dialog.visible = true
	CardNode.input_blocked = modal
	_update_gy_confirm()


func _make_gy_card_button(instance_id: String) -> Button:
	var card := _state.get_card(instance_id)
	var def: CardDef = _db.get_def(card.card_def_id) if card else null
	var btn := Button.new()
	btn.custom_minimum_size = GY_CARD_SIZE
	btn.toggle_mode = not _gy_view_only
	btn.clip_text = true
	var tex_path := "res://" + def.image_path.replace("\\", "/") if def and def.image_path != "" else ""
	if tex_path != "" and ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		btn.icon = tex
		btn.expand_icon = true
	else:
		btn.text = "%s\n(%d) %s" % [def.card_name if def else instance_id,
				def.cost if def else 0, def.card_type if def else ""]
	if not _gy_view_only:
		btn.toggled.connect(func(pressed: bool) -> void:
			if pressed:
				if _gy_selected.size() >= _gy_max:
					btn.set_pressed_no_signal(false)   # over the limit — refuse the pick
					return
				_gy_selected.append(instance_id)
			else:
				_gy_selected.erase(instance_id)
			_update_gy_confirm())
	return btn


func _update_gy_confirm() -> void:
	_gy_confirm_btn.disabled = _gy_selected.size() < _gy_min \
			or _gy_selected.size() > _gy_max


func _on_gy_confirm_pressed() -> void:
	if _gy_view_only or _gy_confirm_btn.disabled:
		return
	if _gy_reveal_mode:
		var pick: String = _gy_selected[0] if not _gy_selected.is_empty() else ""
		_close_gy_dialog()
		var events := StackResolver.choose_reveal_pick(_state, pick, _db)
		EventBus.emit_events(events)
		_set_status("")
		_refresh_ui()
		_schedule_next_turn()
		return
	_close_gy_dialog()
	_router.confirm_graveyard_selection(_gy_selected.duplicate())
	_refresh_ui()


func _on_gy_cancel_pressed() -> void:
	if _gy_reveal_mode:
		return  # mandatory reveal-pick — no cancel
	var was_view_only := _gy_view_only
	_close_gy_dialog()
	if not was_view_only:
		_router.cancel_graveyard_selection()
	_refresh_ui()


func _close_gy_dialog() -> void:
	_gy_reveal_mode = false
	_gy_dialog.visible = false
	_gy_dimmer.visible = false
	CardNode.input_blocked = false
	_gy_view_only = false
	_gy_peek_active = false


# ── Combat window highlight ─────────────────────────────────────────────────────

# Red-outlines the attacker + current defender for the duration of the attack/
# defend windows, so the human can see who's fighting and decide whether to
# respond (e.g. Quick Strike) before protect point / damage. Called again on
# defend_window_opened since the defender may have swapped to a protector.
#
# Deferred one frame: the callers (attack_window_opened / defend_window_opened
# handlers) call _refresh_ui()/_drain_passes() right after this, which routes
# through _router.refresh_highlights() -> BoardRenderer._on_highlights_updated,
# and that unconditionally overwrites every card node's outline — wiping the
# red outline set here if applied synchronously (same issue protect point
# works around with _apply_protect_outlines).
func _set_combat_highlight(attacker_id: String, defender_id: String) -> void:
	call_deferred("_apply_combat_highlight", attacker_id, defender_id)


func _apply_combat_highlight(attacker_id: String, defender_id: String) -> void:
	if not (_state.combat_attack_window or _state.combat_defend_window):
		return   # window already closed before this frame fired
	_clear_combat_highlight()
	if attacker_id != "":
		_renderer.set_card_outline(attacker_id, true, Color(1.0, 0.2, 0.2))
		_combat_highlight_ids.append(attacker_id)
	if defender_id != "" and defender_id != attacker_id:
		_renderer.set_card_outline(defender_id, true, Color(1.0, 0.2, 0.2))
		_combat_highlight_ids.append(defender_id)


func _clear_combat_highlight() -> void:
	for cid in _combat_highlight_ids:
		_renderer.set_card_outline(cid, false)
	_combat_highlight_ids.clear()


# Same red outline as _set_combat_highlight, but for a combat PROPOSAL still
# sitting on the chain (601.1) — before the combat step / attack window even
# exists, so it can't gate on combat_attack_window/combat_defend_window like
# _apply_combat_highlight does. Guards instead on the proposal still being the
# top of the chain, so a deferred call that lands after the proposal already
# resolved (or fizzled — e.g. Litori) doesn't paint a stale outline.
func _set_proposed_combat_highlight(attacker_id: String, defender_id: String) -> void:
	call_deferred("_apply_proposed_combat_highlight", attacker_id, defender_id)


func _apply_proposed_combat_highlight(attacker_id: String, defender_id: String) -> void:
	if _state.pending_actions.is_empty():
		return
	var top: PendingAction = _state.pending_actions.back()
	if top.action_type != "propose_combat" \
			or top.params.get("attacker_id", "") != attacker_id \
			or top.params.get("defender_id", "") != defender_id:
		return
	_clear_combat_highlight()
	if attacker_id != "":
		_renderer.set_card_outline(attacker_id, true, Color(1.0, 0.2, 0.2))
		_combat_highlight_ids.append(attacker_id)
	if defender_id != "" and defender_id != attacker_id:
		_renderer.set_card_outline(defender_id, true, Color(1.0, 0.2, 0.2))
		_combat_highlight_ids.append(defender_id)


# ── Protect point ──────────────────────────────────────────────────────────────

func _handle_protect_point(payload: Dictionary) -> void:
	var attacker_id: String    = payload.get("attacker_id", "")
	var defender_id: String    = payload.get("defender_id", "")
	var protectors: Array      = payload.get("legal_protectors", [])
	var defender := _state.get_card(defender_id)
	if not defender:
		return
	var defending_player := defender.controller

	var defending_type := _p1_type if defending_player == "p1" else _p2_type
	var defending_ai: Object = _p1_ai if defending_player == "p1" else _p2_ai
	if defending_type != "human":
		# AI decides immediately.
		var protector_id: String = defending_ai.choose_protector(_state, _db, defending_player)
		var events := StackResolver.choose_protector(_state, protector_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human player (p1): show inline protect UI over the pass button.
		_show_protect_inline(protectors, attacker_id, defender_id)


func _show_protect_inline(protectors: Array, attacker_id: String, defender_id: String) -> void:
	_in_protect_mode      = true
	_protect_protectors   = protectors
	_protect_defender_id  = defender_id
	_protect_attacker_id  = attacker_id
	_ai_timer.stop()   # prevent AI from acting while human is choosing a protector
	_pass_btn.visible  = false
	_cancel_btn.visible = false

	# Resolve display names for attacker and defender.
	var atk_name := attacker_id
	var atk_card := _state.get_card(attacker_id)
	if atk_card and _db:
		var atk_def := _db.get_def(atk_card.card_def_id) as CardDef
		if atk_def:
			atk_name = atk_def.card_name
	var def_name := defender_id
	var def_card2 := _state.get_card(defender_id)
	if def_card2 and _db:
		var def_def := _db.get_def(def_card2.card_def_id) as CardDef
		if def_def:
			def_name = def_def.card_name

	# Centre everything on the same axis as the pass button (x=960).
	const CENTER_X := 960
	const BTN_W    := 170
	const BTN_GAP  := 10
	const SKIP_W   := 100
	const SKIP_GAP := 20

	# Total row width: protector buttons + gaps between them + gap before skip + skip.
	var n          := protectors.size()
	var row_width: int = n * BTN_W + max(n - 1, 0) * BTN_GAP + SKIP_GAP + SKIP_W
	@warning_ignore("integer_division")
	var btn_x      := CENTER_X - row_width / 2

	# Header: who is attacking whom — centred over the button row.
	var header_lbl := "%s is attacking %s — PROTECT?" % [atk_name, def_name]
	var header := Label.new()
	header.text = header_lbl
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color(0.9, 0.5, 0.2))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.size     = Vector2(row_width + 100, 20)
	@warning_ignore("integer_division")
	header.position = Vector2(CENTER_X - (row_width + 100) / 2, 968)
	add_child(header)
	_protect_nodes.append(header)

	# One button per legal protector.
	for cid in protectors:
		var card := _state.get_card(cid)
		var btn_label: String = cid
		if card and _db:
			var def: CardDef = _db.get_def(card.card_def_id)
			if def:
				btn_label = def.card_name
		var btn := Button.new()
		btn.text     = btn_label
		btn.position = Vector2(btn_x, 987)
		btn.size     = Vector2(BTN_W, 36)
		var captured_id: String = cid
		btn.pressed.connect(func() -> void: _resolve_protection(captured_id))
		add_child(btn)
		_protect_nodes.append(btn)
		btn_x += BTN_W + BTN_GAP

	# Skip button.
	var skip := Button.new()
	skip.text     = "Skip"
	skip.position = Vector2(btn_x + SKIP_GAP - BTN_GAP, 987)
	skip.size     = Vector2(SKIP_W, 36)
	skip.pressed.connect(func() -> void: _resolve_protection(""))
	add_child(skip)
	_protect_nodes.append(skip)

	# Defer outline setup one frame so it lands after any synchronous _refresh_ui
	# calls that follow EventBus.emit_events() in the caller.
	var captured_atk: String = attacker_id
	var captured_def: String = defender_id
	var captured_prot: Array = protectors.duplicate()
	call_deferred("_apply_protect_outlines", captured_atk, captured_def, captured_prot)


func _apply_protect_outlines(atk_id: String, def_id: String, prot_ids: Array) -> void:
	if not _in_protect_mode:
		return   # protect point was already resolved before this frame fired
	_renderer.highlight_cards(prot_ids)
	_renderer.set_card_outline(atk_id, true, Color(1.0, 0.2, 0.2))
	_renderer.set_card_outline(def_id, true, Color(1.0, 0.2, 0.2))


func _resolve_protection(protector_id: String) -> void:
	_in_protect_mode = false
	_protect_protectors = []
	for n in _protect_nodes:
		n.queue_free()
	_protect_nodes.clear()
	_pass_btn.visible = true
	_renderer.set_card_outline(_protect_attacker_id, false)
	_renderer.set_card_outline(_protect_defender_id, false)
	_protect_attacker_id = ""
	_protect_defender_id = ""
	_router.refresh_highlights()

	var events := StackResolver.choose_protector(_state, protector_id, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	# NOTE: do NOT call _drain_passes() here. choose_protector's emitted events
	# already self-drive: defend_window_opened / combat_concluded / strike_point_opened
	# each run their own handler (which drains or schedules) synchronously inside
	# emit_events above. A second drain here would re-evaluate the SAME defend window
	# that drain #1 just deliberately held for the human — but drain #1 marked the
	# window generation as seen, so drain #2 reads "nothing changed" and Layer-2
	# auto-passes it, silently skipping the human's defend window (e.g. a held
	# Freya Lightsworn heal after protecting with Igvand).


func _on_card_clicked_scene(instance_id: String) -> void:
	if _in_protect_mode and instance_id in _protect_protectors:
		_resolve_protection(instance_id)
	elif _in_strike_mode and instance_id in _strike_weapon_ids:
		_resolve_strike(instance_id)


# ── Strike point (rules 602.1 / 602.3) ─────────────────────────────────────────

func _handle_strike_point(payload: Dictionary) -> void:
	var striking_player: String = payload.get("player", "")
	var weapon_ids: Array       = payload.get("weapon_ids", [])
	var side: String            = payload.get("side", "attack")

	var striking_type := _p1_type if striking_player == "p1" else _p2_type
	var striking_ai: Object = _p1_ai if striking_player == "p1" else _p2_ai
	if striking_type != "human":
		# AI decides immediately (BaseAI.choose_strike_weapon).
		var weapon_id: String = striking_ai.choose_strike_weapon(_state, _db, striking_player)
		var events := StackResolver.choose_strike(_state, weapon_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	elif side == "attack" and _router.preferred_strike_weapon in weapon_ids:
		# Human attacked via a specific weapon's "Attack" menu — auto-strike with
		# it instead of prompting again (the weapon was already the player's pick).
		var weapon_id: String = _router.preferred_strike_weapon
		_router.preferred_strike_weapon = ""
		var events := StackResolver.choose_strike(_state, weapon_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_drain_passes()
	else:
		_router.preferred_strike_weapon = ""
		_show_strike_inline(weapon_ids, side)


func _show_strike_inline(weapon_ids: Array, side: String) -> void:
	_in_strike_mode    = true
	_strike_weapon_ids = weapon_ids
	_ai_timer.stop()   # no AI actions while the human is deciding
	_pass_btn.visible   = false
	_cancel_btn.visible = false

	const CENTER_X := 960
	const BTN_W    := 200
	const BTN_GAP  := 10
	const SKIP_W   := 120
	const SKIP_GAP := 20

	var n := weapon_ids.size()
	var row_width: int = n * BTN_W + max(n - 1, 0) * BTN_GAP + SKIP_GAP + SKIP_W
	@warning_ignore("integer_division")
	var btn_x := CENTER_X - row_width / 2

	var header := Label.new()
	header.text = "Strike with a weapon? (%s)" % \
		("attacking" if side == "attack" else "defending")
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color(0.9, 0.5, 0.2))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.size     = Vector2(row_width + 100, 20)
	@warning_ignore("integer_division")
	header.position = Vector2(CENTER_X - (row_width + 100) / 2, 968)
	add_child(header)
	_strike_nodes.append(header)

	for cid in weapon_ids:
		var btn_label: String = cid
		var card := _state.get_card(cid)
		if card and _db:
			var def: CardDef = _db.get_def(card.card_def_id)
			if def:
				var cost := StackResolver.get_strike_cost(_state, _state.pending_strike_player, def)
				btn_label = "%s  (+%d ATK, %d)" % [def.card_name, _state.get_atk(cid, _db), cost]
		var btn := Button.new()
		btn.text     = btn_label
		btn.position = Vector2(btn_x, 987)
		btn.size     = Vector2(BTN_W, 36)
		var captured_id: String = cid
		btn.pressed.connect(func() -> void: _resolve_strike(captured_id))
		add_child(btn)
		_strike_nodes.append(btn)
		btn_x += BTN_W + BTN_GAP

	var skip := Button.new()
	skip.text     = "Don't strike"
	skip.position = Vector2(btn_x + SKIP_GAP - BTN_GAP, 987)
	skip.size     = Vector2(SKIP_W, 36)
	skip.pressed.connect(func() -> void: _resolve_strike(""))
	add_child(skip)
	_strike_nodes.append(skip)

	# Highlight the strikeable weapons (deferred, same reason as protect outlines).
	var captured_ids: Array = weapon_ids.duplicate()
	call_deferred("_apply_strike_highlights", captured_ids)


func _apply_strike_highlights(weapon_ids: Array) -> void:
	if not _in_strike_mode:
		return   # already resolved before this frame fired
	_renderer.highlight_cards(weapon_ids)


func _resolve_strike(weapon_id: String) -> void:
	_in_strike_mode    = false
	_strike_weapon_ids = []
	for n in _strike_nodes:
		n.queue_free()
	_strike_nodes.clear()
	_pass_btn.visible = true
	_router.refresh_highlights()

	var events := StackResolver.choose_strike(_state, weapon_id, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	# NOTE: no _drain_passes() here — same reasoning as _resolve_protection.
	# choose_strike opens the held window (attack_window_opened / defend_window_opened),
	# whose handler drains synchronously inside emit_events above. A second drain
	# would re-read the just-held window as "already seen" and Layer-2 auto-pass it.


# ── Game over ──────────────────────────────────────────────────────────────────

func _handle_game_over(payload: Dictionary) -> void:
	if _game_over:
		return   # already handled — game_over can fire twice if both heroes die simultaneously
	_game_over = true
	_ai_timer.stop()
	var winner: String = payload.get("winner", "?")
	var dialog := ConfirmationDialog.new()
	dialog.title            = "Game Over"
	dialog.dialog_text      = "★  %s  wins!" % winner.to_upper()
	dialog.get_ok_button().text     = "Rematch"
	dialog.get_cancel_button().text = "Leave Game"
	dialog.confirmed.connect(_on_rematch)
	dialog.canceled.connect(func() -> void: get_tree().quit())
	add_child(dialog)
	dialog.popup_centered()


func _on_rematch() -> void:
	for child in get_children():
		child.queue_free()
	await get_tree().process_frame
	_game_over                    = false
	_p1_played_this_action_phase  = false
	_in_protect_mode              = false
	_protect_nodes                = []
	_in_strike_mode               = false
	_strike_nodes                 = []
	_p1_has_mulliganed            = false
	_p1_ai = _make_ai(_p1_type, _last_p1_deck_id)
	_p2_ai = _make_ai(_p2_type, _last_p2_deck_id)
	_build_scene()
	_setup_game_state(DeckManager.get_runtime_deck(_last_p1_deck_id),
					  DeckManager.get_runtime_deck(_last_p2_deck_id))


func _schedule_next_turn() -> void:
	if _draining or _game_over:
		return
	if _state.pending_discard_count > 0:
		return  # wait for discard resolution before advancing
	if _state.pending_pet_sacrifice_player != "":
		return  # wait for pet sacrifice before advancing
	if _state.pending_equip_sacrifice_player != "":
		return  # wait for equipment sacrifice before advancing
	if _state.pending_control_discard_player != "":
		return  # wait for the discard-or-give-control choice before advancing
	if _state.pending_reveal_pick_player != "":
		return  # wait for the reveal-and-pick quest choice before advancing
	if _state.pending_totem_target_player != "":
		return  # wait for the Totem start-of-turn target choice before advancing
	var pid := _state.priority_player
	var pid_type := _p1_type if pid == "p1" else _p2_type
	if pid_type != "human" \
			and not _ai_timer.time_left > 0 \
			and not _state.in_protect_point \
			and not _in_protect_mode \
			and _state.pending_strike_player == "" \
			and not _in_strike_mode:
		_ai_timer.start()


# ── Speed mode ─────────────────────────────────────────────────────────────────

func _toggle_speed_mode() -> void:
	# Flip Turbo ⇄ Tactical by driving the toggle buttons. Their `toggled` signals call
	# _set_turbo_mode (updating the description label and, for Turbo, possibly auto-passing),
	# and the shared ButtonGroup keeps the pair mutually exclusive, so the UI stays in sync.
	if _turbo_mode:
		_tactical_btn.button_pressed = true
	else:
		_turbo_btn.button_pressed = true


func _set_turbo_mode(on: bool) -> void:
	_turbo_mode = on
	if _mode_desc_label:
		_mode_desc_label.text = "Auto-pass all 'no legal play'" if on \
			else "Manual control — all phases"
		_mode_desc_label.add_theme_color_override("font_color",
			Color(0.42, 0.52, 0.42) if on else Color(0.52, 0.42, 0.42))
	if on:
		_maybe_turbo_pass()


func _drain_passes() -> void:
	if _draining:
		return
	_draining = true
	_ai_timer.stop()
	var had_combat_conclusion  := false
	var had_ai_chain_play      := false
	var limit := 30
	while limit > 0:
		limit -= 1
		if _game_over or _state.in_protect_point or _in_protect_mode \
				or _state.pending_strike_player != "" or _in_strike_mode:
			break
		if _state.pending_discard_count > 0 or _state.pending_pet_sacrifice_player != "" \
				or _state.pending_equip_sacrifice_player != "" \
				or _state.pending_control_discard_player != "" \
				or _state.pending_reveal_pick_player != "" \
				or _state.pending_totem_target_player != "":
			_wrap_up_active = false
			break
		var in_combat     := _state.combat_attack_window or _state.combat_defend_window
		var chain_pending := not _state.pending_actions.is_empty()
		if not in_combat and not chain_pending:
			break
		var pid := _state.priority_player
		var pid_type := _p1_type if pid == "p1" else _p2_type
		var events: Array[GameEvent] = []
		if pid_type == "human":
			# Turbo auto-passes the human's own just-added top chain link even when they
			# hold a legal instant (LIFO — they'll regain priority if the opponent reacts).
			var owns_top := _player_owns_top_of_chain(pid)
			# C one-shot: auto-pass this player's combat windows until the opponent
			# responds. An opponent link on the chain (not owned by us) means they
			# played something → stop, clear the flag, and hand control back.
			if _auto_pass_combat and pid == "p1":
				if chain_pending and not owns_top:
					_auto_pass_combat = false
					break
				if not (in_combat or owns_top):
					_auto_pass_combat = false
					break
				_mark_priority_info_seen()
				events = StackResolver.pass_priority(_state, _db)
			elif not owns_top and not _human_has_new_info(pid):
				# Layer 2 (mode-independent "nothing changed" auto-pass): the chain
				# top isn't a new opponent link and no combat window transition
				# happened since we last looked. The engine still requires the
				# pass, there's just nothing new to prompt the human about —
				# so auto-pass regardless of Turbo/Tactical.
				_mark_priority_info_seen()
				events = StackResolver.pass_priority(_state, _db)
			elif not owns_top and (_turbo_mode or _wrap_up_active) \
					and not _router.has_any_legal_play():
				# Layer 3 (Turbo / wrap-up burst): something changed, but there's
				# nothing you could legally play in response — so skip the window
				# instead of stopping. This is Turbo's whole job ("auto-pass all
				# 'no legal play'"). In Tactical (no burst) we fall through to the
				# hold below so the player can still watch the window open.
				if in_combat:
					_log_entry("[color=#667]-- Turbo skipped %s (no legal response) --[/color]" \
							% _describe_priority_stop_reason())
				_mark_priority_info_seen()
				events = StackResolver.pass_priority(_state, _db)
			elif not owns_top:
				# Something changed AND you have a legal response (or you're in
				# Tactical mode): stop and hand priority to the human. New opponent
				# chain link, or a combat window transition (e.g. defend window
				# opened: you may now want to commit a buff you held back in case
				# of a Protector). Documented stop for a wrap-up burst / Turbo.
				_log_entry("[color=#889]-- priority held for you (%s) --[/color]" % \
						_describe_priority_stop_reason())
				_mark_priority_info_seen()
				_wrap_up_active = false
				break
			elif not (_turbo_mode or _wrap_up_active):
				break
			else:
				_mark_priority_info_seen()
				events = StackResolver.pass_priority(_state, _db)
		else:
			var ai: Object = _p1_ai if pid == "p1" else _p2_ai
			if not ai:
				break
			var action: PendingAction = ai.decide_action(_state, _db, pid)
			if action != null:
				events = StackResolver.submit_action(_state, action, _db)
			else:
				events = StackResolver.pass_priority(_state, _db)
		if events.is_empty():
			break
		await EventBus.emit_events(events)
		_refresh_ui()
		# Track whether a resolution delay is warranted after the drain.
		for e: GameEvent in events:
			if e.event_type == "combat_concluded":
				had_combat_conclusion = true
				_auto_pass_combat = false  # one-shot per combat
			elif e.event_type == "card_moved" and e.payload.get("from", "") == "chain":
				var cid: String = e.payload.get("card", "")
				var moved_card := _state.get_card(cid)
				if moved_card:
					var owner_type := _p1_type if moved_card.controller == "p1" else _p2_type
					if owner_type != "human":
						had_ai_chain_play = true
	_draining = false
	var delay := GameTiming.resolution_delay() if (had_combat_conclusion or had_ai_chain_play) else 0.0
	if delay > 0.0:
		get_tree().create_timer(delay).timeout.connect(
			func() -> void: _schedule_next_turn(); _maybe_turbo_pass())
	else:
		_schedule_next_turn()
		_maybe_turbo_pass()


func _maybe_turbo_pass() -> void:
	if _draining or not (_turbo_mode or _wrap_up_active) or not _state or not _router:
		return
	if _in_protect_mode:
		return
	if _state.pending_discard_count > 0:
		_wrap_up_active = false
		return
	if _state.pending_pet_sacrifice_player != "":
		_wrap_up_active = false
		return
	if _state.pending_control_discard_player != "":
		_wrap_up_active = false
		return
	if _state.priority_player != "p1" or _p1_type != "human":
		return
	# Combat windows and a non-empty chain are _drain_passes's exclusive domain
	# (it owns the full Layer 2 / Layer 3 decision there — hold, or Turbo-skip
	# on no legal play). Re-deriving the same "new info?" verdict here would
	# race against the marker _drain_passes just set, always reading back
	# "nothing new" and passing straight through a window that was correctly
	# held open a moment ago.
	if _state.combat_attack_window or _state.combat_defend_window \
			or not _state.pending_actions.is_empty():
		return
	var phase := _state.phase
	# Never auto-pass the human's own main action window (chain empty, no combat):
	# that pass ends the turn and requires an explicit Wrap Up, even with no legal play.
	# For a Ctrl+Space wrap-up burst, reaching this window again means the burst
	# carried the human all the way to their own next real decision point — stop.
	if _is_p1_main_action_window():
		_wrap_up_active = false
		return
	# Opponent's action-phase wrap-up window (chain empty, no combat window): always
	# skip it, legal plays or not — the human still gets the real end-of-turn window
	# right after, so there's nothing lost by not stopping here too.
	if _is_opponent_action_window():
		call_deferred("_do_turbo_pass")
		return
	# Auto-pass when there's nothing to play, during ready/draw (instants are so rare
	# there that Turbo skips them — switch to Tactical to play powers early), OR when
	# the human just added the top chain link themselves (see _player_owns_top_of_chain).
	if not _human_has_new_info("p1") or phase == "ready" or phase == "draw" \
			or _player_owns_top_of_chain("p1"):
		call_deferred("_do_turbo_pass")
	else:
		# A new opponent chain link or a combat window transition happened
		# since we last looked — that's the documented stop, independent of
		# whether a legal play happens to exist.
		_mark_priority_info_seen()
		_wrap_up_active = false


func _player_owns_top_of_chain(pid: String) -> bool:
	# Turbo: after a player adds a link to the chain (quest/power/instant), rule 410.1
	# keeps priority with the proposer. There's no reason to respond to your own just-
	# added link before the opponent gets a chance — if they react, you regain priority
	# with the opponent's link on top (LIFO) and can respond then. So auto-pass even when
	# holding a legal instant. This is safe because priority sits at a player with their
	# own link on top ONLY right after they added it: any later return of priority is
	# either post-resolution (link gone) or with an opponent link on top. Works on or off
	# the human's turn, since it keys off who added the top link.
	if _state.pending_actions.is_empty():
		return false
	var top: PendingAction = _state.pending_actions.back()
	return top != null and top.source_player == pid


# "Something happened" since the human last got to decide, per the layer-2
# auto-pass rule: a NEW opponent-owned chain link on top (not the same one
# they already saw/passed on), or a combat window transition (attack ->
# protect point -> defend -> resolved). Explicitly NOT included: legal-play
# existence, resources entering play, or non-chain forced/triggered effects
# (e.g. Taz'dingo, Infernal's end-of-turn burn) — those open no counterplay
# window, so passing through them shouldn't cost the human an extra ask.
func _human_has_new_info(pid: String) -> bool:
	if not _state.pending_actions.is_empty():
		var top: PendingAction = _state.pending_actions.back()
		# Placing a resource adds a link to the chain (rule 410.3), but in this
		# ruleset the human never responds to it — treat it as not-actionable so
		# it never prompts (per design). Everything else the opponent adds counts.
		if top.source_player != pid and top.action_type != "place_resource" \
				and top.get_instance_id() != _last_seen_chain_top_iid:
			return true
	# A combat-window transition only counts while a combat window is actually
	# open. Once combat is over the gen counter is stale (the window it referred
	# to is closed), so it must not linger as phantom "new info" at the next
	# phase-boundary window — that was forcing a second wrap-up press.
	if _state.combat_attack_window or _state.combat_defend_window:
		return _window_generation != _last_seen_window_gen
	return false


# Human-readable reason for a priority stop, for the game log — same
# criteria as _human_has_new_info, split out for display.
func _describe_priority_stop_reason() -> String:
	if not _state.pending_actions.is_empty():
		var top: PendingAction = _state.pending_actions.back()
		if top != null and top.source_player != "p1" \
				and top.action_type != "place_resource" \
				and top.get_instance_id() != _last_seen_chain_top_iid:
			if top.action_type == "propose_combat":
				return "opponent proposes %s attacks %s" % [
					_log_card(top.params.get("attacker_id", "")),
					_log_card(top.params.get("defender_id", "")),
				]
			return "opponent added %s to the chain" % top.action_type
	if _window_generation != _last_seen_window_gen:
		if _state.combat_defend_window:
			return "defend window opened"
		if _state.combat_attack_window:
			return "attack window opened"
		return "protect point"
	return "unknown"


# Call when the human is actually stopped/shown a decision, so the next
# drain pass doesn't re-flag the same chain top / window as "new."
func _mark_priority_info_seen() -> void:
	if not _state.pending_actions.is_empty():
		_last_seen_chain_top_iid = _state.pending_actions.back().get_instance_id()
	else:
		_last_seen_chain_top_iid = 0
	_last_seen_window_gen = _window_generation


# True when a plain-Space pass would END the human's turn (wrap up the action
# phase or take/end during the end phase). These are gated behind Ctrl+Space so
# a stray Space tap can't skip the turn. Pending choices (control-discard decline,
# sacrifices) are NOT wrap-ups — those keep their own Space handling.
func _is_wrap_up_pass() -> bool:
	if not _state or _state.priority_player != "p1" or _state.turn_player != "p1":
		return false
	if _state.pending_control_discard_player == "p1" \
			or _state.pending_pet_sacrifice_player == "p1" \
			or _state.pending_equip_sacrifice_player == "p1":
		return false
	if not _state.pending_actions.is_empty():
		return false
	if _state.combat_attack_window or _state.combat_defend_window or _state.in_protect_point:
		return false
	return _state.phase == "action" or _state.phase == "end"


# True when the human currently holds priority in one of their own combat
# windows — the moment pressing C to auto-pass the rest of combat makes sense.
func _can_auto_pass_combat() -> bool:
	return _state != null and _p1_type == "human" \
		and _state.priority_player == "p1" \
		and (_state.combat_attack_window or _state.combat_defend_window)


func _is_p1_main_action_window() -> bool:
	return _state.phase == "action" \
		and _state.turn_player == "p1" \
		and _state.pending_actions.is_empty() \
		and not _state.combat_attack_window \
		and not _state.combat_defend_window \
		and not _state.in_protect_point


func _is_opponent_action_window() -> bool:
	return _state.phase == "action" \
		and _state.turn_player != "p1" \
		and _state.pending_actions.is_empty() \
		and not _state.combat_attack_window \
		and not _state.combat_defend_window \
		and not _state.in_protect_point


func _do_turbo_pass() -> void:
	if not (_turbo_mode or _wrap_up_active) or not _state or not _router:
		return
	if _state.priority_player != "p1" or _p1_type != "human":
		return
	var phase := _state.phase
	# Re-check at fire time — state may have changed since the deferred was scheduled.
	if _is_p1_main_action_window():
		_wrap_up_active = false
		return
	# Hold only when something changed AND you have a legal response. With no
	# legal play, Turbo passes through even on new info (its "auto-pass all
	# 'no legal play'" contract) — matching Layer 3 in _drain_passes.
	if _human_has_new_info("p1") and _router.has_any_legal_play() \
			and phase != "ready" and phase != "draw" \
			and not _player_owns_top_of_chain("p1"):
		_mark_priority_info_seen()
		_wrap_up_active = false
		return
	_mark_priority_info_seen()
	_router.pass_priority_action()
	_refresh_ui()
	_schedule_next_turn()


func _set_status(text: String) -> void:
	if _status:
		_status.text = text


# ── Mock card helper ───────────────────────────────────────────────────────────

static func _make_mock_def(id: String, def_name: String, atk: int, health: int,
		instant: bool, ctype: String) -> CardDef:
	var d := CardDef.new()
	d.card_def_id    = id
	d.card_name      = def_name
	d.printed_atk    = atk
	d.printed_health = health
	d.is_instant     = instant
	d.card_type      = ctype
	return d
