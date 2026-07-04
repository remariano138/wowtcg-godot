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

const AI_THINK_TIME       := 0.001
const RESOLUTION_DELAY    := 0.2   # pause after combat or AI chain play so human can register it

const DECK_ALLIANCE_MOONSHADOW  := "alliance_moonshadow_test"
const DECK_ALLIANCE_TIMMO       := "alliance_timmo_test"
const DECK_ALLIANCE_DIZDEMONA   := "alliance_dizdemona_test"
const DECK_ALLIANCE_BORIS       := "alliance_boris_test"
const DECK_HORDE_TAZO          := "horde_tazo_test"
const DECK_HORDE_GRENNAN       := "horde_grennan_test"
const DECK_HORDE_OMEDUS        := "horde_omedus_test"
const DECK_HORDE_RADAK         := "horde_radak_test"
const DECK_RANDOM              := "random"

var _state:  GameState
var _db:     CardDatabase
var _gm:     GameManager
var _renderer: BoardRenderer
var _router: InputRouter
var _ai_timer:   Timer
var _draining: bool = false  # true while _drain_passes is running

# Per-player type + AI instance (null = human).
var _p1_type: String = "human"
var _p2_type: String = "fullrandom"
var _p1_ai:   Object = null
var _p2_ai:   Object = null

# ── Menu ───────────────────────────────────────────────────────────────────────
var _menu_layer:  CanvasLayer
var _p1_type_opt: OptionButton
var _p1_deck_opt: OptionButton
var _p2_type_opt: OptionButton
var _p2_deck_opt: OptionButton
var _status:     Label
var _priority_label: Label
var _phase_label:    Label
var _pass_btn:   Button
var _cancel_btn: Button
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
var _end_turn_dialog: ConfirmationDialog
var _p1_played_this_action_phase: bool = false
var _game_over: bool = false
var _last_p1_deck_id: String = ""
var _last_p2_deck_id: String = ""

# ── Game log ───────────────────────────────────────────────────────────────────
var _log: RichTextLabel
var _log_in_mulligan: bool = false
var _pending_exhaust: Dictionary = {}  # player_id -> count of resources exhausted, not yet logged

# ── Control panel ──────────────────────────────────────────────────────────────
var _turbo_mode: bool = true
var _turbo_btn:  Button
var _tactical_btn: Button
var _mode_desc_label: Label

# ── Protect point (inline panel UI) ───────────────────────────────────────────
var _in_protect_mode: bool = false
var _protect_protectors: Array = []
var _protect_nodes: Array[Node] = []
var _protect_defender_id: String = ""
var _protect_attacker_id: String = ""


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
	var log_bg := ColorRect.new()
	log_bg.color    = Color(0.07, 0.09, 0.12, 0.88)
	log_bg.position = Vector2(5, 5)
	log_bg.size     = Vector2(248, 950)
	add_child(log_bg)

	_log = RichTextLabel.new()
	_log.bbcode_enabled  = true
	_log.scroll_active   = true
	_log.position        = Vector2(8, 8)
	_log.size            = Vector2(242, 944)
	_log.add_theme_font_size_override("normal_font_size", 10)
	add_child(_log)

	# ── Right column labels (graveyard x=1590, deck/hero x=1750) ─────────────────
	_add_label("P2 grave",  Vector2(1590,  52), 11, Color(0.5, 0.4, 0.4))
	_add_label("P2 deck",   Vector2(1750,  52), 11, Color(0.4, 0.4, 0.5))
	_add_label("P2 hero",   Vector2(1750, 182), 11, Color(0.5, 0.4, 0.5))
	_add_label("P1 grave",  Vector2(1590, 832), 11, Color(0.4, 0.5, 0.4))
	_add_label("P1 hero",   Vector2(1750, 702), 11, Color(0.4, 0.5, 0.45))
	_add_label("P1 deck",   Vector2(1750, 832), 11, Color(0.4, 0.4, 0.5))

	# Status label must exist before renderer.set_status_label is called below.
	_status = _add_label("", Vector2(20, 1040), 18, Color(0.5, 0.8, 0.5))

	# Renderer
	_renderer = BoardRenderer.new()
	add_child(_renderer)

	# Zone anchors.
	# Board rows (centre x=1000): p2_hand → p2_resource → p2_ally → chain → p1_ally → p1_resource → p1_hand
	# Right column (x=1820): p2_deck at top, p2_hero just below; p1_deck at bottom, p1_hero just above.
	# Graveyard at x=1640, same y as the player's hand.
	_renderer.register_zone("p2_hand",         _make_anchor(Vector2(1000,  65)))
	_renderer.register_zone("p2_resource_row", _make_anchor(Vector2(1000, 195)))
	_renderer.register_zone("p2_ally_row",     _make_anchor(Vector2(1000, 325)))
	_renderer.register_zone("chain",           _make_anchor(Vector2(1000, 455)))
	_renderer.register_zone("p1_ally_row",     _make_anchor(Vector2(1000, 585)))
	_renderer.register_zone("p1_resource_row", _make_anchor(Vector2(1000, 715)))
	_renderer.register_zone("p1_hand",         _make_anchor(Vector2(1000, 845)))
	_renderer.register_zone("p2_graveyard",    _make_anchor(Vector2(1640,  65)))
	_renderer.register_zone("p2_deck",         _make_anchor(Vector2(1820,  65)))
	_renderer.register_zone("p2_hero_row",     _make_anchor(Vector2(1820, 195)))
	_renderer.register_zone("p1_graveyard",    _make_anchor(Vector2(1640, 845)))
	_renderer.register_zone("p1_deck",         _make_anchor(Vector2(1820, 845)))
	_renderer.register_zone("p1_hero_row",     _make_anchor(Vector2(1820, 715)))

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
	_router.discard_mode_started.connect(_on_discard_mode_started)
	_router.discard_mode_ended.connect(_on_discard_mode_ended)
	_router.pet_sacrifice_mode_ended.connect(_on_pet_sacrifice_mode_ended)
	_router.x_select_requested.connect(_on_x_select_requested)
	_build_x_dialog()

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
	_priority_label = _add_label("", Vector2(16, 1003), 15, Color(0.9, 0.85, 0.3))
	# _status created earlier (needed by renderer); visually lives in left section.

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

	# ── Mulligan panel (replaces pass area during mulligan phase) ──────────────
	_mulligan_panel = VBoxContainer.new()
	_mulligan_panel.position = Vector2(648, 968)
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

	_mulligan_hint_label = _add_label(
		"Left-click = play/place  ·  Right-click = options  ·  Esc = retract",
		Vector2(648, 1040), 11, Color(0.38, 0.38, 0.38))
	_mulligan_hint_label.visible = false

	# ── VSep 2 ─────────────────────────────────────────────────────────────────
	var vsep2 := ColorRect.new()
	vsep2.color    = Color(0.28, 0.33, 0.38)
	vsep2.position = Vector2(1296, 968)
	vsep2.size     = Vector2(2, 110)
	add_child(vsep2)

	# ── Right section: Speed Mode selector ─────────────────────────────────────
	_add_label("SPEED MODE", Vector2(1330, 971), 10, Color(0.55, 0.55, 0.55))

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
	_tactical_btn.position     = Vector2(1454, 987)
	_tactical_btn.size         = Vector2(110, 36)
	_tactical_btn.toggle_mode  = true
	_tactical_btn.button_group = mode_group
	_tactical_btn.toggled.connect(func(on: bool) -> void: if on: _set_turbo_mode(false))
	add_child(_tactical_btn)

	_mode_desc_label = _add_label("Auto-pass all 'no legal play'",
		Vector2(1330, 1055), 10, Color(0.42, 0.52, 0.42))

	_ai_timer = Timer.new()
	_ai_timer.wait_time = AI_THINK_TIME
	_ai_timer.one_shot  = true
	_ai_timer.timeout.connect(_do_ai_turn)
	add_child(_ai_timer)

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

	var deck_labels := ["Alliance_test (Moonshadow)", "Alliance_test (Timmo)", "Alliance_test (Dizdemona)", "Alliance_test (Boris)", "Horde_test (Ta'zo)", "Horde_test (Grennan)", "Horde_test (Omedus)", "Horde_test (Radak)", "Random"]
	inner.add_child(_player_row("Player 1", ["Human", "BaseAI", "FullRandomAI"], 0,
		deck_labels, 4,
		func(opt): _p1_type_opt = opt, func(opt): _p1_deck_opt = opt))
	inner.add_child(_player_row("Player 2", ["BaseAI", "FullRandomAI"], 1,
		deck_labels, 4,
		func(opt): _p2_type_opt = opt, func(opt): _p2_deck_opt = opt))

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
		deck_items: Array, deck_default: int,
		type_cb: Callable, deck_cb: Callable) -> HBoxContainer:
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

	var dlbl := Label.new()
	dlbl.text = "Deck:"
	row.add_child(dlbl)

	var deck_opt := OptionButton.new()
	deck_opt.custom_minimum_size = Vector2(185, 0)
	for item in deck_items:
		deck_opt.add_item(item)
	deck_opt.selected = deck_default
	row.add_child(deck_opt)
	deck_cb.call(deck_opt)

	return row


func _on_quick_start() -> void:
	var all_decks := [DECK_ALLIANCE_MOONSHADOW, DECK_ALLIANCE_TIMMO, DECK_ALLIANCE_DIZDEMONA,
					  DECK_ALLIANCE_BORIS, DECK_HORDE_TAZO, DECK_HORDE_GRENNAN, DECK_HORDE_OMEDUS,
					  DECK_HORDE_RADAK]
	all_decks.shuffle()
	_launch_game("human", all_decks[0], "fullrandom", all_decks[1])


func _on_start_game() -> void:
	var p1_types := ["human", "base", "fullrandom"]
	var p2_types := ["base", "fullrandom"]
	var deck_ids := [DECK_ALLIANCE_MOONSHADOW, DECK_ALLIANCE_TIMMO, DECK_ALLIANCE_DIZDEMONA,
					 DECK_ALLIANCE_BORIS, DECK_HORDE_TAZO, DECK_HORDE_GRENNAN, DECK_HORDE_OMEDUS,
					 DECK_HORDE_RADAK, DECK_RANDOM]
	_launch_game(p1_types[_p1_type_opt.selected], deck_ids[_p1_deck_opt.selected],
				 p2_types[_p2_type_opt.selected], deck_ids[_p2_deck_opt.selected])


func _launch_game(p1_type: String, p1_deck_id: String,
		p2_type: String, p2_deck_id: String) -> void:
	_log.clear()
	_log_in_mulligan = false
	_pending_exhaust.clear()
	_menu_layer.visible = false
	_p1_type = p1_type
	_p2_type = p2_type
	_p1_ai   = _make_ai(p1_type)
	_p2_ai   = _make_ai(p2_type)
	var r_p1 := _resolve_deck(p1_deck_id)
	var r_p2 := _resolve_deck(p2_deck_id)
	_last_p1_deck_id = r_p1
	_last_p2_deck_id = r_p2
	_setup_game_state(_build_deck_for(r_p1), _build_deck_for(r_p2))


func _make_ai(type: String) -> Object:
	match type:
		"base":       return BaseAI.new()
		"fullrandom": return FullRandomAI.new()
		_:            return null   # human


func _resolve_deck(deck_id: String) -> String:
	if deck_id == DECK_RANDOM:
		var pool := [DECK_ALLIANCE_MOONSHADOW, DECK_ALLIANCE_TIMMO, DECK_ALLIANCE_DIZDEMONA,
					 DECK_ALLIANCE_BORIS, DECK_HORDE_TAZO, DECK_HORDE_GRENNAN, DECK_HORDE_OMEDUS,
					 DECK_HORDE_RADAK]
		return pool[randi() % pool.size()]
	return deck_id


func _build_deck_for(resolved_id: String) -> Deck:
	# ── Horde test deck (60 cards) ────────────────────────────────────────────────
	# Core (22): 12 YFA · 2 Stonetusk · 2 Kagra · 2 Taz'dingo · 2 Arnold · 2 Vanquish
	# Filler (38): 5 remaining horde allies spread evenly (8/8/8/7/7)
	var horde_cards: Array[String] = [
		# 10× Your Fortune Awaits You
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281",
		# 2× A Donation of Wool
		"azeroth_351", "azeroth_351",
		# 2× Ka'tali Stonetusk  (1-cost protector)
		"azeroth_248", "azeroth_248",
		# 2× Kagra of the Crossroads  (1-cost offensive / Ferocity)
		"azeroth_246", "azeroth_246",
		# 2× Taz'dingo  (3-cost alignment staple)
		"azeroth_260", "azeroth_260",
		# 2× Arnold Flem  (on-death AoE)
		"azeroth_225", "azeroth_225",
		# 2× Vanquish
		"azeroth_171", "azeroth_171",
		# Filler — 38 slots across 5 remaining horde allies
		"azeroth_236", "azeroth_236", "azeroth_236", "azeroth_236",  # Fa'tafi        ×8
		"azeroth_236", "azeroth_236", "azeroth_236", "azeroth_236",
		"azeroth_262", "azeroth_262", "azeroth_262", "azeroth_262",  # Vaerik         ×8
		"azeroth_262", "azeroth_262", "azeroth_262", "azeroth_262",
		"azeroth_264", "azeroth_264", "azeroth_264", "azeroth_264",  # Vesh'ral       ×8
		"azeroth_264", "azeroth_264", "azeroth_264", "azeroth_264",
		"azeroth_228", "azeroth_228", "azeroth_228", "azeroth_228",  # Benethor       ×6
		"azeroth_228", "azeroth_228",
		"azeroth_252", "azeroth_252", "azeroth_252", "azeroth_252",  # Moko           ×4
		"azeroth_249", "azeroth_249", "azeroth_249", "azeroth_249",  # Kulan Earthguard ×4
	]

	# ── Alliance test deck (60 cards) ─────────────────────────────────────────────
	# Core (24): 12 YFA · 2 Teep · 2 Tonarin · 2 Parvink · 2 Adept Breton · 2 Vanquish · 2 Freya
	# Filler (36): Crazy Igvand ×8, Kor Cindervein ×8, Latro ×4, Anika ×4, Braxiss ×4, Liba ×4, Gallen ×4
	var alliance_cards: Array[String] = [
		# 10× Your Fortune Awaits You
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281",
		# 2× A Donation of Wool
		"azeroth_351", "azeroth_351",
		# 2× Apprentice Teep  (1-cost protector)
		"azeroth_176", "azeroth_176",
		# 2× Warden Tonarin   (1-cost protector)
		"azeroth_222", "azeroth_222",
		# 2× Parvink          (3-cost alignment staple)
		"azeroth_212", "azeroth_212",
		# 2× Adept Breton     (activated-power AoE)
		"azeroth_174", "azeroth_174",
		# 2× Vanquish
		"azeroth_171", "azeroth_171",
		# 2× Freya Lightsworn (activated heal)
		"azeroth_183", "azeroth_183",
		# Filler — 36 slots across 7 remaining alliance allies
		"azeroth_180", "azeroth_180", "azeroth_180", "azeroth_180",  # Crazy Igvand   ×8
		"azeroth_180", "azeroth_180", "azeroth_180", "azeroth_180",
		"azeroth_192", "azeroth_192", "azeroth_192", "azeroth_192",  # Kor Cindervein ×8
		"azeroth_192", "azeroth_192", "azeroth_192", "azeroth_192",
		"azeroth_197", "azeroth_197", "azeroth_197", "azeroth_197",  # Latro Abiectus ×4
		"azeroth_175", "azeroth_175", "azeroth_175", "azeroth_175",  # Anika Berlyn   ×4
		"azeroth_179", "azeroth_179", "azeroth_179", "azeroth_179",  # Braxiss        ×4
		"azeroth_200", "azeroth_200", "azeroth_200", "azeroth_200",  # Liba Wobblebonk ×4
		"azeroth_219", "azeroth_219", "azeroth_219", "azeroth_219",  # Tracker Gallen ×4
	]

	# ── Dizdemona deck (60 cards) — alliance base + 2× Grimdron (Warlock pet) ──
	# Same as alliance_cards except: 2 Grimdron replace 2 Crazy Igvand (filler trimmed 8→6).
	var dizdemona_cards: Array[String] = [
		# 10× Your Fortune Awaits You
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281",
		# 2× A Donation of Wool
		"azeroth_351", "azeroth_351",
		# 2× Apprentice Teep  (1-cost protector)
		"azeroth_176", "azeroth_176",
		# 2× Warden Tonarin   (1-cost protector)
		"azeroth_222", "azeroth_222",
		# 2× Parvink          (3-cost alignment staple)
		"azeroth_212", "azeroth_212",
		# 2× Adept Breton     (activated-power AoE)
		"azeroth_174", "azeroth_174",
		# 2× Vanquish
		"azeroth_171", "azeroth_171",
		# 2× Freya Lightsworn (activated heal)
		"azeroth_183", "azeroth_183",
		# 2× Grimdron (Warlock pet), 2× Sarmoth (Warlock pet)
		"azeroth_125", "azeroth_125",
		"azeroth_130", "azeroth_130",
		# Filler — Crazy Igvand trimmed 8→4 to make room for pets
		"azeroth_180", "azeroth_180", "azeroth_180", "azeroth_180",  # Crazy Igvand   ×4
		"azeroth_192", "azeroth_192", "azeroth_192", "azeroth_192",  # Kor Cindervein ×8
		"azeroth_192", "azeroth_192", "azeroth_192", "azeroth_192",
		"azeroth_197", "azeroth_197", "azeroth_197", "azeroth_197",  # Latro Abiectus ×8
		"azeroth_197", "azeroth_197", "azeroth_197", "azeroth_197",
		"azeroth_175", "azeroth_175", "azeroth_175", "azeroth_175",  # Anika Berlyn   ×4
		"azeroth_179", "azeroth_179", "azeroth_179", "azeroth_179",  # Braxiss        ×4
		"azeroth_200", "azeroth_200", "azeroth_200", "azeroth_200",  # Liba Wobblebonk ×4
	]

	# ── Boris Brightbeard deck (60 cards) — alliance base, Priest healer hero ──
	var boris_cards: Array[String] = [
		# 10× Your Fortune Awaits You
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281",
		# 2× A Donation of Wool
		"azeroth_351", "azeroth_351",
		# 2× Apprentice Teep  (1-cost protector)
		"azeroth_176", "azeroth_176",
		# 2× Warden Tonarin   (1-cost protector)
		"azeroth_222", "azeroth_222",
		# 2× Parvink          (3-cost alignment staple)
		"azeroth_212", "azeroth_212",
		# 2× Adept Breton     (activated-power AoE)
		"azeroth_174", "azeroth_174",
		# 2× Vanquish
		"azeroth_171", "azeroth_171",
		# 2× Freya Lightsworn (activated heal)
		"azeroth_183", "azeroth_183",
		# Filler
		"azeroth_180", "azeroth_180", "azeroth_180", "azeroth_180",  # Crazy Igvand   ×4
		"azeroth_192", "azeroth_192", "azeroth_192", "azeroth_192",  # Kor Cindervein ×7
		"azeroth_192", "azeroth_192", "azeroth_192",
		"azeroth_352",                                               # In Dreams      ×1
		"azeroth_197", "azeroth_197", "azeroth_197", "azeroth_197",  # Latro Abiectus ×8
		"azeroth_197", "azeroth_197", "azeroth_197", "azeroth_197",
		"azeroth_175", "azeroth_175", "azeroth_175", "azeroth_175",  # Anika Berlyn   ×4
		"azeroth_179", "azeroth_179", "azeroth_179", "azeroth_179",  # Braxiss        ×4
		"azeroth_200", "azeroth_200", "azeroth_200", "azeroth_200",  # Liba Wobblebonk ×4
	]

	# ── Radak Doombringer deck (60 cards) — horde base + 3× Sarmoth + 1× Grimdron as fuel ──
	var radak_cards: Array[String] = [
		# 10× Your Fortune Awaits You
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281",
		# 2× A Donation of Wool
		"azeroth_351", "azeroth_351",
		# 2× Ka'tali Stonetusk
		"azeroth_248", "azeroth_248",
		# 2× Kagra of the Crossroads
		"azeroth_246", "azeroth_246",
		# 2× Taz'dingo
		"azeroth_260", "azeroth_260",
		# 2× Arnold Flem
		"azeroth_225", "azeroth_225",
		# 2× Vanquish
		"azeroth_171", "azeroth_171",
		# 3× Sarmoth (cost 3 Pet — main sacrifice fuel)
		"azeroth_130", "azeroth_130", "azeroth_130",
		# 1× Grimdron (cost 1 Pet — cheap sacrifice for 1 dmg)
		"azeroth_125",
		# Filler
		"azeroth_236", "azeroth_236", "azeroth_236", "azeroth_236",  # Fa'tafi        ×8
		"azeroth_236", "azeroth_236", "azeroth_236", "azeroth_236",
		"azeroth_262", "azeroth_262", "azeroth_262", "azeroth_262",  # Vaerik         ×8
		"azeroth_262", "azeroth_262", "azeroth_262", "azeroth_262",
		"azeroth_264", "azeroth_264", "azeroth_264", "azeroth_264",  # Vesh'ral       ×4
		"azeroth_228", "azeroth_228", "azeroth_228", "azeroth_228",  # Benethor       ×4
		"azeroth_252", "azeroth_252", "azeroth_252", "azeroth_252",  # Moko           ×4
	]

	# ── Omedus deck (60 cards) — horde base with Mias replacing half of Fa'tafi ──
	# Core (26): 12 YFA · 2 Stonetusk · 2 Kagra · 2 Taz'dingo · 2 Arnold · 2 Vanquish · 4 Mias
	# Filler (34): same 5 allies but Fa'tafi trimmed 8→4 to make room
	var omedus_cards: Array[String] = [
		# 10× Your Fortune Awaits You
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281", "azeroth_281", "azeroth_281",
		"azeroth_281", "azeroth_281",
		# 2× A Donation of Wool
		"azeroth_351", "azeroth_351",
		# 2× Ka'tali Stonetusk
		"azeroth_248", "azeroth_248",
		# 2× Kagra of the Crossroads
		"azeroth_246", "azeroth_246",
		# 2× Taz'dingo
		"azeroth_260", "azeroth_260",
		# 2× Arnold Flem
		"azeroth_225", "azeroth_225",
		# 2× Vanquish
		"azeroth_171", "azeroth_171",
		# 4× Mias the Putrid (hand disruption synergy with Omedus)
		"azeroth_251", "azeroth_251", "azeroth_251", "azeroth_251",
		# Filler — Fa'tafi trimmed to 4 (was 8), rest unchanged
		"azeroth_236", "azeroth_236", "azeroth_236", "azeroth_236",  # Fa'tafi        ×4
		"azeroth_262", "azeroth_262", "azeroth_262", "azeroth_262",  # Vaerik         ×7
		"azeroth_262", "azeroth_262", "azeroth_262",
		"azeroth_352",                                               # In Dreams      ×1
		"azeroth_264", "azeroth_264", "azeroth_264", "azeroth_264",  # Vesh'ral       ×8
		"azeroth_264", "azeroth_264", "azeroth_264", "azeroth_264",
		"azeroth_228", "azeroth_228", "azeroth_228", "azeroth_228",  # Benethor       ×7
		"azeroth_228", "azeroth_228", "azeroth_228",
		"azeroth_252", "azeroth_252", "azeroth_252", "azeroth_252",  # Moko           ×7
		"azeroth_252", "azeroth_252", "azeroth_252",
	]

	match resolved_id:
		DECK_HORDE_TAZO:          return Deck.make("azeroth_15", horde_cards)
		DECK_HORDE_GRENNAN:       return Deck.make("azeroth_10", horde_cards)
		DECK_HORDE_OMEDUS:        return Deck.make("azeroth_12", omedus_cards)
		DECK_HORDE_RADAK:         return Deck.make("azeroth_13", radak_cards)
		DECK_ALLIANCE_TIMMO:      return Deck.make("azeroth_7", alliance_cards)
		DECK_ALLIANCE_DIZDEMONA:  return Deck.make("azeroth_2", dizdemona_cards)
		DECK_ALLIANCE_BORIS:      return Deck.make("azeroth_1", boris_cards)
		DECK_ALLIANCE_MOONSHADOW: return Deck.make("azeroth_6", alliance_cards)
		_:                        return Deck.make("azeroth_6", alliance_cards)


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
	if not _in_protect_mode:
		_router.refresh_highlights()
	_update_pass_btn()
	_update_cancel_btn()


func _update_phase_label() -> void:
	var names := {
		"mulligan": "Mulligan",
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
	var in_attack  := _state.combat_attack_window
	var in_defend  := _state.combat_defend_window

	_pass_btn.disabled = not my_turn or _state.pending_pet_sacrifice_player == "p1"

	if _state.pending_pet_sacrifice_player == "p1":
		_pass_btn.text     = "Sacrifice a pet  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif not my_turn:
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif not has_plays:
		var _no_play_label := "Wrap Up" if in_action \
				else ("End Turn" if _state.phase == "end" else "Pass")
		_pass_btn.text     = "No legal play — %s  [Space]" % _no_play_label
		_pass_btn.modulate = Color(1.0, 0.35, 0.35)
	elif chain_busy:
		_pass_btn.text     = "Pass Priority  [Space]"
		_pass_btn.modulate = Color(1.0, 1.0, 1.0)
	elif in_attack:
		_pass_btn.text     = "Attack window — Pass  [Space]"
		_pass_btn.modulate = Color(0.65, 0.65, 0.65)
	elif in_defend:
		_pass_btn.text     = "Defend window — Pass  [Space]"
		_pass_btn.modulate = Color(0.65, 0.65, 0.65)
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
		# If the X dialog is open, Enter confirms it (the LineEdit grabs Enter via text_submitted,
		# but we also handle it here for the case where focus has drifted to the OK button).
		if _x_dialog and _x_dialog.visible:
			_confirm_x_value(_x_input.text)
			get_viewport().set_input_as_handled()
			return
		_try_pass()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		# Escape: close the X dialog (cancels the whole power use).
		if _x_dialog and _x_dialog.visible:
			_x_dialog.visible = false
			_router.cancel_targeting()
			_set_status("")
			get_viewport().set_input_as_handled()
			return
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
func _try_pass() -> void:
	if not _state or _state.priority_player != "p1" or _p1_type != "human":
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
			_log_entry("\n[color=#d4af37][b]── Turn %d · %s ──[/b][/color]" % [n, p])
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
			elif from_z.ends_with("_hand") and to_z.ends_with("_ally_row"):
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
		"combat_started":
			var att: String = _log_card(event.payload.get("attacker_id", ""))
			var def: String = _log_card(event.payload.get("defender_id", ""))
			_log_entry("[color=#fc8][b]%s ⚔ %s[/b][/color]" % [att, def])
		"attack_window_opened":
			_set_status("⚔ Attack window — you may respond before protect")
			_refresh_ui()
		"defend_window_opened":
			_set_status("⚔ Defend window — you may respond before damage")
			_refresh_ui()
			_drain_passes()  # human chose protector; drain the defend window
		"damage_dealt":
			var src:    String = _log_card(event.payload.get("source", ""))
			var tgt:    String = _log_card(event.payload.get("target", ""))
			var amt:    int    = event.payload.get("amount", 0)
			_log_entry("[color=#f66]%s receives %d dmg from %s[/color]" % [tgt, amt, src])
		"card_destroyed":
			var card_name: String = _log_card(event.payload.get("card",   ""))
			var source: String = event.payload.get("source", "")
			if source != "":
				var src_name: String = _log_card(source)
				_log_entry("[color=#f44][b]%s destroyed by %s[/b][/color]" % [card_name, src_name])
			else:
				_log_entry("[color=#f44][b]%s destroyed[/b][/color]" % card_name)
		"hero_power_used":
			var p: String = _log_player(event.payload.get("player", ""))
			_log_entry("[color=#aef]%s hero power[/color]" % p)
		"ally_power_used":
			var p: String   = _log_player(event.payload.get("player", ""))
			var cid: String = event.payload.get("ally_id", "")
			_log_entry("[color=#aef]%s activates [b]%s[/b][/color]" % [p, _log_card(cid)])
		"quest_completed":
			var p:  String = _log_player(event.payload.get("player", ""))
			var cid: String = event.payload.get("quest_id", "")
			_log_entry("[color=#af8]%s completes %s[/color]" % [p, _log_card(cid)])
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
	EventBus.emit_events(events)
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
			_refresh_ui()
			_drain_passes()
		"card_moved":
			# A card drawn from deck needs a fresh CardNode spawned at the hand anchor.
			var to_zone: String   = event.payload.get("to", "")
			var from_zone: String = event.payload.get("from", "")
			var moved_id: String  = event.payload.get("card", "")
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
					var spawn_pos := hand_anchor.global_position if hand_anchor else (Vector2(1000, 845) if is_p1 else Vector2(1000, 65))
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
		"action_fizzled":
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
			_set_status("")
			_refresh_ui()
			_schedule_next_turn()
		"protect_point_opened":
			_handle_protect_point(event.payload)
		"discard_choice_opened":
			_handle_discard_choice(event.payload)
		"pet_sacrifice_required":
			_handle_pet_sacrifice(event.payload)
		"enter_play_target_required":
			_handle_enter_play_target(event.payload)
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


func _on_pet_sacrifice_mode_ended() -> void:
	_set_status("")
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


func _handle_discard_choice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var count: int     = payload.get("count", 1)
	_discard_reason    = payload.get("reason", "card_effect")
	if player == "p2":
		# AI: discard using smart heuristic (lowest-cost non-quest/location first).
		for _i in count:
			var pick := _pick_ai_discard("p2")
			if pick == null:
				break
			var events := StackResolver.choose_discard(_state, pick.instance_id, _db)
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
			var target_id: String = targets[randi() % targets.size()]
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
	_set_status("")
	_router.confirm_x_value(x)


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
	_drain_passes()


func _on_card_clicked_scene(instance_id: String) -> void:
	if _in_protect_mode and instance_id in _protect_protectors:
		_resolve_protection(instance_id)


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
	_p1_has_mulliganed            = false
	_p1_ai = _make_ai(_p1_type)
	_p2_ai = _make_ai(_p2_type)
	_build_scene()
	_setup_game_state(_build_deck_for(_last_p1_deck_id), _build_deck_for(_last_p2_deck_id))


func _schedule_next_turn() -> void:
	if _draining or _game_over:
		return
	if _state.pending_discard_count > 0:
		return  # wait for discard resolution before advancing
	if _state.pending_pet_sacrifice_player != "":
		return  # wait for pet sacrifice before advancing
	var pid := _state.priority_player
	var pid_type := _p1_type if pid == "p1" else _p2_type
	if pid_type != "human" \
			and not _ai_timer.time_left > 0 \
			and not _state.in_protect_point \
			and not _in_protect_mode:
		_ai_timer.start()


# ── Speed mode ─────────────────────────────────────────────────────────────────

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
		if _game_over or _state.in_protect_point or _in_protect_mode:
			break
		if _state.pending_discard_count > 0 or _state.pending_pet_sacrifice_player != "":
			break
		var in_combat     := _state.combat_attack_window or _state.combat_defend_window
		var chain_pending := not _state.pending_actions.is_empty()
		if not in_combat and not chain_pending:
			break
		var pid := _state.priority_player
		var pid_type := _p1_type if pid == "p1" else _p2_type
		var events: Array[GameEvent] = []
		if pid_type == "human":
			if not _turbo_mode or _router.has_any_legal_play():
				break
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
		EventBus.emit_events(events)
		_refresh_ui()
		# Track whether a resolution delay is warranted after the drain.
		for e: GameEvent in events:
			if e.event_type == "combat_concluded":
				had_combat_conclusion = true
			elif e.event_type == "card_moved" and e.payload.get("from", "") == "chain":
				var cid: String = e.payload.get("card", "")
				var moved_card := _state.get_card(cid)
				if moved_card:
					var owner_type := _p1_type if moved_card.controller == "p1" else _p2_type
					if owner_type != "human":
						had_ai_chain_play = true
	_draining = false
	var delay := RESOLUTION_DELAY if (had_combat_conclusion or had_ai_chain_play) else 0.0
	if delay > 0.0:
		get_tree().create_timer(delay).timeout.connect(
			func() -> void: _schedule_next_turn(); _maybe_turbo_pass())
	else:
		_schedule_next_turn()
		_maybe_turbo_pass()


func _maybe_turbo_pass() -> void:
	if _draining or not _turbo_mode or not _state or not _router:
		return
	if _in_protect_mode:
		return
	if _state.pending_discard_count > 0:
		return
	if _state.pending_pet_sacrifice_player != "":
		return
	if _state.priority_player != "p1" or _p1_type != "human":
		return
	var phase := _state.phase
	# Never auto-pass the human's own main action window (chain empty, no combat):
	# that pass ends the turn and requires an explicit Wrap Up, even with no legal play.
	if _is_p1_main_action_window():
		return
	# Auto-pass when there's nothing to play, or during ready/draw (instants are
	# so rare there that Turbo skips them — switch to Tactical to play powers early).
	if not _router.has_any_legal_play() or phase == "ready" or phase == "draw":
		call_deferred("_do_turbo_pass")


func _is_p1_main_action_window() -> bool:
	return _state.phase == "action" \
		and _state.turn_player == "p1" \
		and _state.pending_actions.is_empty() \
		and not _state.combat_attack_window \
		and not _state.combat_defend_window \
		and not _state.in_protect_point


func _do_turbo_pass() -> void:
	if not _turbo_mode or not _state or not _router:
		return
	if _state.priority_player != "p1" or _p1_type != "human":
		return
	var phase := _state.phase
	# Re-check at fire time — state may have changed since the deferred was scheduled.
	if _is_p1_main_action_window():
		return
	if _router.has_any_legal_play() and phase != "ready" and phase != "draw":
		return
	_router.pass_priority_action()
	_refresh_ui()
	_schedule_next_turn()


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
