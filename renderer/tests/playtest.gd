extends Node2D

# Phase 7a — Turn loop: ready → draw → action → end → (opponent's turn …)
#
# HOW TO RUN:
#   Open phase7_test.tscn > Play Scene.
#
# CONTROLS:
#   Click a green card in your hand  → plays it
#   Spacebar / Enter                 → pass priority
#   Escape                           → open/close the Controls panel
#   Right-click (while targeting)    → cancel targeting
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

# ── Hotseat (Duel Table) ───────────────────────────────────────────────────────
# Both players human on one screen. _local_player is the seat the screen currently
# belongs to: only that player's hand is face-up and the InputRouter acts for them.
# At every turn change to the OTHER human, both hands go face-down and a fullscreen
# handoff overlay blocks everything until the incoming player confirms.
# The perspective sentinel "__handoff__" matches neither hand zone, hiding both.
var _hotseat: bool = false
var _local_player: String = "p1"
var _handoff_pending: bool = false
var _handoff_layer: CanvasLayer = null
var _mulligan_queue: Array[String] = []   # human players still to decide (hotseat)
var _mulligan_current: String = "p1"      # player the mulligan panel belongs to
var _mulligan_first: String = ""          # first_player, for the order label

# ── Camera / HUD split (TTS-style rotating view) ──────────────────────────────
# The board (card nodes, zone anchors, deck sprites, side labels) lives in the
# world and is seen through _camera; all UI lives in the _hud CanvasLayer, which
# ignores the camera. The camera rotates 180° about the board centre when the
# screen is handed to P2, so each player sees their own side at the bottom.
# The board used to be drawn in y=0..950 with a 120px UI strip beneath it. With
# that strip gone the board is re-centred in the full 1080 viewport: every anchor
# is written in the old base coordinates and shifted by this offset in
# _make_anchor. 65 puts the board's own centre (y=475 in base coords, the axis
# the two players' decks/graveyards mirror about) on the viewport centre, which
# is what un-crops the top player's deck and hand.
const VIEWPORT_H := 1080.0
const BOARD_Y_OFFSET := VIEWPORT_H * 0.5 - 450.0

# The board's single mirror axis, in BASE board coordinates. Every P2 anchor is
# generated from the matching P1 anchor by reflecting through this point (see
# _mirror), so the two seats are guaranteed to see identical layouts — the p2
# camera rotates 180° about exactly this point.
#
# It used to be three different axes: rows reflected about y=450, hands about
# 465, deck/graveyard columns about 475, and the rows were centred on x=1000
# while the columns reflected about x=960. That made P2's view of their own side
# sit up to 80px off from P1's view of theirs.
const BOARD_MIRROR := Vector2(960, 450)
const BOARD_PIVOT := Vector2(BOARD_MIRROR.x, BOARD_MIRROR.y + BOARD_Y_OFFSET)
var _hud: CanvasLayer
var _camera: Camera2D
var _camera_tween: Tween = null
# One-shot: hold the end-phase (wrap-up) priority window open for the incoming
# hotseat player right after the handoff, so Turbo doesn't auto-pass the window
# they were just handed the screen for (playing instants with leftover resources).
var _stop_for_end_window: bool = false

# ── Combat stance / ambush (off-screen hotseat player reactions) ──────────────
# Per-player stance, set by each player while they hold the screen:
#   "passive" — priority windows during the opponent's turn auto-pass (default).
#   "ambush"  — a window STOPS when this player has a legal instant response:
#     their playable instants highlight YELLOW in their face-down hand (front
#     shown only while hovered), the InputRouter temporarily acts for them so
#     they can play, and the top-right Skip button passes without revealing
#     anything. Windows with no legal response still auto-skip (nothing would
#     be playable, and stopping would only leak "no response" the slow way).
const AMBUSH_HIGHLIGHT := Color(1.0, 0.9, 0.2)
const HOVER_MAGNIFY := 1.2   # local player's own hand cards magnify on hover
# Ambush is the default; a player switches to Passive when they know they won't react.
var _stance: Dictionary = {"p1": "ambush", "p2": "ambush"}
var _in_ambush_mode: bool = false
var _ambush_player: String = ""
# Choice peek: in hotseat, when a mandatory choice is owed by the OFF-SCREEN
# human, the router acts for THEM ambush-style while the renderer perspective
# stays with the seat. PRIVATE choices (a mandatory discard — Mias the Putrid /
# Hypnotic Blade) keep their hand face-down with one-card-at-a-time hover peek;
# PUBLIC ones (The Princess Trapped's reveal — both players are meant to see the
# revealed cards) skip the hiding and only re-point the input. See _route_choice.
var _in_choice_peek: bool = false
var _choice_peek_player: String = ""
var _choice_peek_hides_hand: bool = false
var _skip_btn: Button
var _stance_passive_btn: Button
var _stance_ambush_btn: Button

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
var _chain_panel: Control   # visual chain display (bottom-left, above the control panel)
var _pass_btn:   Button
var _cancel_btn: Button
# Per-player resource readout beside each resource zone (world-space, mirrored):
# "Available X / Total Y" plus the can-place line. pid -> {avail, place} Labels.
var _res_info_labels: Dictionary = {}
# Unrotated (camera-at-p1) top-left of every readout label, keyed by the Label:
# _orient_res_info_labels re-derives the rotated placement from these.
var _res_info_base: Dictionary = {}
var _res_info_size: Vector2 = Vector2.ZERO
# Turn-step strips (Ready · Draw · Action · End), one per pass block: the local
# seat's under the pass button, the opponent's in the mirrored block. The
# current step is bolded on the ACTIVE player's side only.
var _turn_steps_bottom: RichTextLabel
var _turn_steps_top:    RichTextLabel
# The opponent's pass button. Deliberately never clickable: every opponent input
# path already exists (AI resolves itself; a hotseat human takes the seat at the
# handoff, at which point the BOTTOM button is theirs; the ambush stop has its
# own Skip). It is the status light the mirrored design called for — lit while
# they hold priority, greyed otherwise.
var _opp_pass_btn: Button
var _mulligan_panel:       VBoxContainer
var _mulligan_order_label: Label
var _mulligan_ready_btn:   Button
var _mulligan_btn:         Button
var _mulligan_hint_label:  Label
var _p1_has_mulliganed:    bool = false
# True while the panel is showing the "you drew a new hand — Ready to continue"
# acknowledgement, after this player has already committed a mulligan.
var _mulligan_awaiting_ack: bool = false
var _context_menu: PopupMenu
var _context_actions: Array   # Array of {label, action, enabled}
# ── Tool windows (turn info / controls) ───────────────────────────────────────
# The old bottom bar's left and right thirds now live in floating, draggable,
# closable windows opened from two buttons at the bottom-right. Only the centre
# section (pass / cancel / status) stays permanently on the bar.
var _turn_info_window: Panel
var _controls_window:  Panel
# The chain display's window. Draggable but not closable; auto-shown whenever
# the chain is non-empty. Stays centred until the player drags it, after which
# their placement is kept (see _chain_window_moved).
var _chain_window:       Panel
var _chain_window_moved: bool = false
# Combat window: the step readout (proposition / attack window / protect point /
# defend window), who is attacking whom, and the protect point's own buttons.
# Auto-shown for the duration of a combat, like the chain window, and likewise
# draggable but not closable.
var _combat_window:  Panel
var _combat_body:    Control
var _combat_steps_rtl: RichTextLabel   # the full 602 sequence, current step bolded
var _combat_atk_lbl:   Label
var _combat_def_lbl:   Label
var _combat_prompt_lbl: Label
var _combat_btn_row:   Control
# Combatant ids behind the two name labels, for Alt+hover examination.
var _combat_atk_id: String = ""
var _combat_def_id: String = ""
# Which combatant name the pointer is over ("" = none); polled in _process so
# pressing Alt while already hovering works too.
var _combat_name_hover_id: String = ""
# Title bar currently being dragged, and the grab offset within it.
var _dragging_window:  Panel = null
var _drag_offset:      Vector2 = Vector2.ZERO
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
var _gy_body:          VBoxContainer   # holds one (optionally labelled) grid per section
var _gy_confirm_nodes: Array = []      # the "are you sure?" popup, when the search asks for one
var _gy_confirm_heal:  int = 0         # heal per card removed (Cannibalize) — 0 = don't mention healing
var _gy_ask_confirm:   bool = false    # true = Confirm raises an "are you sure?" popup first
var _gy_confirm_btn:   Button
var _gy_cancel_btn:    Button
var _gy_selected:      Array = []       # instance_ids currently picked
var _gy_min:           int = 1
var _gy_max:           int = 1
var _gy_view_only:     bool = false     # true = examine mode (no selection, no router call)
var _gy_peek_active:   bool = false     # true = alt+hover peek (non-modal, no dimmer/buttons)
var _gy_reveal_mode:   bool = false     # true = reveal-and-pick quest (choose_reveal_pick, no cancel)
var _gy_recomb_mode:   bool = false    # true = Operation Recombobulation fetch (choose_recombobulation; Cancel/Esc = decline, the reward is "you may")
var _gy_selectable:    Dictionary = {}  # reveal-pick: instance_id -> true for cards that pass the filter (others shown red, not pickable). See _gy_filter_active.
var _gy_reveal_card_type: String = ""   # reveal-pick: required card type, kept so the choice can be re-opened if a pick is refused
var _gy_filter_active: bool = false   # true = _gy_selectable is authoritative, INCLUDING when empty (reveal-pick with no matching card ⇒ nothing is pickable). Without this an empty dict read as "all selectable" and let the player submit an illegal pick, which the engine refuses — leaving the choice pending forever and hard-locking the turn.
var _end_turn_dialog: ConfirmationDialog
var _played_this_action_phase: Dictionary = {}   # player_id -> bool
var _game_over: bool = false
var _stats: StatTracker = StatTracker.new()   # per-match card draw/play stats
var _last_p1_deck_id: String = ""
var _last_p2_deck_id: String = ""
var _prompt_first_player: bool = true   # false for Quick Start (autopick random)
var _first_player_layer: CanvasLayer

# ── Game log ───────────────────────────────────────────────────────────────────
var _log: RichTextLabel
var _log_bg: ColorRect
# Press L to toggle. Hidden by default: the log is a HUD overlay and now sits
# on top of P2's deck/graveyard column (screen-left since the board went symmetric).
var _log_visible: bool = false
var _log_in_mulligan: bool = false
var _pending_exhaust: Dictionary = {}  # player_id -> count of resources exhausted, not yet logged

# ── Control panel ──────────────────────────────────────────────────────────────
# Tactical is the DEFAULT: a human stops at every priority window that has new
# information (a fresh opponent chain link — a hero power announcement included —
# or a combat window transition), even with no legal response, so nothing the
# opponent announces resolves off-screen. Turbo ([T]) is opt-in and skips those
# "no legal play" windows. AI players are unaffected either way — they always
# respond/pass immediately.
var _turbo_mode: bool = false
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

# Modal spell mode choice (rule 707.1c — Natural Selection) — inline "Choose
# one:" buttons shown when the router opens a modal choice; picking a mode
# enters the normal targeting flow, Esc / any other click cancels.
var _modal_nodes: Array[Node] = []

# Ready-on-attack point (Windseer Tarus) — inline "pay to ready" choice, mirrors
# the strike-point UI.
var _in_ready_mode: bool = false
var _ready_nodes: Array[Node] = []
var _in_strike_ready_mode: bool = false
var _strike_ready_nodes: Array[Node] = []
var _in_whelp_bounce_mode: bool = false
var _whelp_bounce_nodes: Array[Node] = []
var _in_form_return_mode: bool = false   # human deciding a Form pay-return choice
var _form_return_nodes: Array[Node] = []
# Quest reward choice ("Choose one … you may choose both" — Hidden Enemies etc.):
# centered popup, two-step when Both is picked (first "one or both", then order).
var _in_quest_choice_mode: bool = false
var _quest_choice_nodes: Array[Node] = []

# Armor prevention point (rule 717.2c) — inline "exhaust armor / take the
# damage" choice at the moment a packet would hit a hero, mirrors the
# strike-point UI. Board-public (works for the off-screen hotseat player too).
var _in_prevention_mode: bool = false
var _prevention_armor_ids: Array = []
var _prevention_nodes: Array[Node] = []

# Quest "exhaust N allies" completion cost (The Love Potion) — a PRE-submission
# picker, not an engine choice point. Clicking a legal ally only marks it
# (green legal outline → blue selected); nothing is exhausted and no resource is
# spent until Confirm, so Cancel leaves the game state untouched.
var _in_ally_exhaust_mode: bool = false
var _ally_exhaust_quest_id: String = ""
var _ally_exhaust_candidates: Array = []
var _ally_exhaust_selected: Array = []
var _ally_exhaust_count: int = 0
var _ally_exhaust_nodes: Array[Node] = []
const ALLY_EXHAUST_SELECTED_COLOR := Color(0.35, 0.6, 1.0)   # blue — selected
const ALLY_EXHAUST_LEGAL_COLOR    := Color(0.2, 1.0, 0.3)    # green — selectable

# ── Combat window highlight (attacker/defender in red during attack/defend windows) ──
var _combat_highlight_ids: Array = []


func _ready() -> void:
	_build_scene()
	_build_menu()


# ── Scene construction ─────────────────────────────────────────────────────────

func _build_scene() -> void:
	# Scene is 1920×1080: board occupies y=0..950, UI strip y=960..1080.
	# Oversized so it still covers the viewport in the rotated (P2) camera view.
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.13, 0.16)
	bg.position = Vector2(-480, -270)
	bg.size  = Vector2(2880, 1620)
	# Backdrop: must sit behind the zone grid lines, which use negative z_index to
	# stay under the cards. Without this the table swallowed them entirely.
	bg.z_index = -100
	add_child(bg)

	# HUD layer — everything UI goes here so the board camera never rotates it.
	_hud = CanvasLayer.new()
	_hud.layer = 10
	add_child(_hud)

	# Board camera. Default = P1 view (identical to a camera-less scene);
	# _orient_camera flips it 180° about BOARD_PIVOT for the P2 view.
	_camera = Camera2D.new()
	_camera.position = Vector2(960, 540)
	_camera.ignore_rotation = false
	add_child(_camera)
	_camera.make_current()

	# ── Game log panel (left gutter, replaces zone labels) ────────────────────────
	_log_bg = ColorRect.new()
	_log_bg.color    = Color(0.07, 0.09, 0.12, 0.88)
	_log_bg.position = Vector2(5, 5)
	_log_bg.size     = Vector2(248, 950)
	_log_bg.visible  = _log_visible
	_hud.add_child(_log_bg)

	_log = RichTextLabel.new()
	_log.bbcode_enabled  = true
	_log.scroll_active   = true
	_log.position        = Vector2(8, 8)
	_log.size            = Vector2(242, 944)
	_log.add_theme_font_size_override("normal_font_size", 10)
	_log.visible         = _log_visible
	_hud.add_child(_log)

	# ── Side column labels ─────────────────────────────────────────────────────
	# Symmetric board: each player's hero column sits on THEIR right-hand side —
	# P1 (facing up) on screen-right, P2 (facing down) on screen-left.
	# P2's labels are rotated 180° so they read upright from P2's seat (TTS-style).
	# World-space, so they carry BOARD_Y_OFFSET like the anchors they label. P2's
	# are the mirror of P1's (and rotated 180°, so they read upright from P2's
	# seat), same as every zone anchor.
	var lbl_y: float = DECK_ROW_Y - SLOT_HALF_H - 16.0
	var GRAVE_LBL_BASE := Vector2(1592, lbl_y)
	var DECK_LBL_BASE  := Vector2(1774, lbl_y)
	_add_label("P1 grave", _board_pos(GRAVE_LBL_BASE.x, GRAVE_LBL_BASE.y),
		11, Color(0.4, 0.5, 0.4))
	_add_label("P1 deck",  _board_pos(DECK_LBL_BASE.x, DECK_LBL_BASE.y),
		11, Color(0.4, 0.4, 0.5))
	var p2_grave_lbl := _mirror(GRAVE_LBL_BASE)
	var p2_deck_lbl  := _mirror(DECK_LBL_BASE)
	_rotate_label_180(_add_label("P2 grave", _board_pos(p2_grave_lbl.x, p2_grave_lbl.y),
		11, Color(0.5, 0.4, 0.4)))
	_rotate_label_180(_add_label("P2 deck",  _board_pos(p2_deck_lbl.x, p2_deck_lbl.y),
		11, Color(0.4, 0.4, 0.5)))


	# Renderer
	_renderer = BoardRenderer.new()
	add_child(_renderer)

	# Zone anchors, in BASE board coordinates (shifted by BOARD_Y_OFFSET in
	# _make_anchor). ONLY P1's side is declared: every P2 anchor is generated by
	# _register_mirrored_zone reflecting through BOARD_MIRROR, so the two seats
	# cannot drift out of symmetry.
	#
	# Rows (centre x = BOARD_MIRROR.x): hand → resource zone → hero → ally → chain.
	# hero_row sits between ally_row and the resources (rule 415.8a: hero card,
	# equipment, and non-attaching ongoing abilities all live in the hero row).
	# Side columns are mirrored per player (each player's hero/deck/graveyard on
	# their own right-hand side): P1's column at screen-right, P2's at screen-left.
	# Row centres are spaced CardNode.H + 10px apart so full rows never overlap a
	# neighbouring row, regardless of which rows are empty or filled. Every anchor
	# is a fixed constant — no runtime repositioning depends on zone contents.
	_register_mirrored_zone("ally_row",  Vector2(BOARD_MIRROR.x, ALLY_ROW_Y))
	_register_mirrored_zone("hero_row",  Vector2(BOARD_MIRROR.x, HERO_ROW_Y))
	_register_mirrored_zone("hand",      Vector2(BOARD_MIRROR.x, HAND_ROW_Y))
	# The resource ZONE is a 5x2 grid in the player's bottom-left corner rather
	# than a row (see BoardRenderer's resource grid section); the anchor is the
	# grid's CENTRE. Zone id keeps the "_resource_row" name the engine uses.
	_register_mirrored_zone("resource_row", RES_ZONE_CENTRE)
	# Deck/graveyard sit in the outer column, clear of every row. They used to be
	# half off-board, tucked under the old bottom UI strip with only the card top
	# showing; with that strip gone and the board re-centred both pairs are now
	# fully on screen.
	_register_mirrored_zone("graveyard", Vector2(1640, DECK_ROW_Y))
	_register_mirrored_zone("deck",      Vector2(1820, DECK_ROW_Y))
	# Hero card itself stays pinned to the player's side column, above the deck,
	# at its hero_row's height where the hero's size allows (see HERO_CARD_Y).
	_register_mirrored_zone("hero_card", Vector2(1820, HERO_CARD_Y))
	# Shared zone — sits on the mirror axis itself.
	_renderer.register_zone("chain", _make_anchor(BOARD_MIRROR))

	_draw_zone_grids()
	_build_resource_info_labels()

	# ── Deck slot card-back sprites ────────────────────────────────────────────────
	for deck_zone in ["p1_deck", "p2_deck"]:
		var deck_anchor := _renderer.zone_anchors.get(deck_zone) as Node2D
		if deck_anchor:
			# Deck backs face their owner, like every other card on that side.
			_add_deck_back_sprite(deck_anchor.global_position,
					180.0 if deck_zone.begins_with("p2") else 0.0)

	_router = InputRouter.new()
	add_child(_router)
	_renderer.set_input_router(_router)
	_router.targeting_started.connect(_on_targeting_started)
	_router.targeting_cancelled.connect(_on_targeting_cancelled)
	_router.modal_choice_opened.connect(_on_modal_choice_opened)
	_router.modal_choice_cancelled.connect(_on_modal_choice_cancelled)
	_router.trigger_target_resolved.connect(_on_trigger_target_resolved)
	_router.death_target_resolved.connect(_on_death_target_resolved)
	_router.quest_flow_resolved.connect(_on_quest_flow_resolved)
	_router.discard_mode_started.connect(_on_discard_mode_started)
	_router.discard_mode_ended.connect(_on_discard_mode_ended)
	_router.pet_sacrifice_mode_ended.connect(_on_pet_sacrifice_mode_ended)
	_router.control_discard_mode_ended.connect(_on_control_discard_mode_ended)
	_router.equipment_sacrifice_mode_ended.connect(_on_equipment_sacrifice_mode_ended)
	_router.unique_sacrifice_mode_ended.connect(_on_unique_sacrifice_mode_ended)
	_router.form_sacrifice_mode_ended.connect(_on_form_sacrifice_mode_ended)
	_router.x_select_requested.connect(_on_x_select_requested)
	_router.graveyard_select_requested.connect(_on_graveyard_select_requested)
	_router.ally_exhaust_select_requested.connect(_on_ally_exhaust_select_requested)
	_router.graveyard_examine_requested.connect(_on_graveyard_examine_requested)
	_router.graveyard_peek_requested.connect(_on_graveyard_peek_requested)
	_router.graveyard_peek_closed.connect(_on_graveyard_peek_closed)
	_router.card_mute_changed.connect(_on_card_mute_changed)
	_build_x_dialog()
	_build_graveyard_dialog()

	# ── Control panel ────────────────────────────────────────────────────────────
	# Two compact blocks instead of the old full-width strip: the pass block
	# (resource indicator + pass + cancel) centred, and the window-toggle block at
	# the bottom-right. Everything else that used to sit on the strip now lives in
	# the two tool windows, so the board keeps the width that strip was eating.
	# Added before the labels/buttons so they render on top.
	var pass_panel := Panel.new()
	pass_panel.position = PASS_BLOCK_RECT.position
	pass_panel.size     = PASS_BLOCK_RECT.size
	_hud.add_child(pass_panel)

	# ── Visual chain (centred, draggable, shown only while the chain is live) ──
	# One card-sized entry per link, stacked bottom-up (LIFO — the topmost entry
	# is the top of the chain, the one that resolves next). Rebuilt from
	# _state.pending_actions in _update_chain_panel (via _refresh_ui), which also
	# sizes and shows/hides the window.
	# Deliberately centre-screen rather than tucked in a corner: a live chain is
	# the thing the player must react to. It can be dragged aside to peek at what
	# it covers, but not closed.
	_chain_panel = _make_tool_window("Chain  ·  resolves right to left",
		Vector2(CHAIN_PANEL_MIN_W, 100), Vector2(860, 380), false)
	_chain_window = _chain_panel.get_parent() as Panel
	_chain_window.visible = false

	_build_combat_window()

	# ── Skip button (top-right, free since P2's column moved screen-left) ──────
	# The OFF-SCREEN player's pass during an ambush stop: skips the window
	# without revealing their hand. Only visible while an ambush stop is active.
	_skip_btn = Button.new()
	_skip_btn.text     = "Skip window  (opponent)"
	_skip_btn.position = Vector2(1650, 15)
	_skip_btn.size     = Vector2(250, 44)
	_skip_btn.visible  = false
	_skip_btn.pressed.connect(_on_skip_pressed)
	_hud.add_child(_skip_btn)

	# ── Prompt window (the old "Turn info" panel, now prompts only) ────────────
	# Turn/phase/priority all read off the two turn strips now, so the panel lost
	# its reason to be a toggled panel — and with it its button. What is left is
	# the PROMPT-ONLY channel ("select a target", "press Ctrl+Space to…"): every
	# "what just happened" report goes to the game log instead (see _log_event).
	# It shows itself when there is a prompt and hides when there isn't (see
	# _set_status), which is the dedicated prompt popup, away from the pass
	# button, that was always the intent.
	var info_body := _make_tool_window("Prompt", Vector2(400, 60),
		Vector2(1240, BOARD_MID_Y - 262))
	_turn_info_window = info_body.get_parent() as Panel
	_status = _add_label("", Vector2(10, 8), 14, Color(0.5, 0.8, 0.5), true, info_body)
	_status.size = Vector2(380, 50)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD

	# ── Pass bars: one per player, straddling the mirror line ─────────────────
	# Laid out relative to PASS_BLOCK_RECT and BOARD_MID_Y, so moving the whole
	# thing is a one-constant change.
	var pass_x: float = PASS_BLOCK_RECT.position.x
	var btn_x: float  = pass_x + 214.0
	var strip_x: float = pass_x + 16.0

	_cancel_btn = Button.new()
	# Esc now opens the Controls panel, so retracting is this button's job alone.
	_cancel_btn.text     = "Retract last"
	# Just below the block: it only appears while targeting, so giving it a
	# permanent slot inside a bar would leave a hole the rest of the time.
	_cancel_btn.position = Vector2(btn_x, PASS_BLOCK_RECT.end.y + 8.0)
	_cancel_btn.size     = Vector2(160, 40)
	_cancel_btn.visible  = false
	_cancel_btn.pressed.connect(_on_cancel_btn_pressed)
	_hud.add_child(_cancel_btn)

	# Seated player's bar, below the line: pass button then turn strip.
	_pass_btn = Button.new()
	_pass_btn.text     = "Pass Priority  [Space]"
	_pass_btn.position = Vector2(btn_x, BOARD_MID_Y + PASS_BTN_DY)
	_pass_btn.size     = Vector2(230, 40)
	_pass_btn.pressed.connect(_on_pass_btn_pressed)
	_hud.add_child(_pass_btn)
	_turn_steps_bottom = _make_turn_step_strip(
		Vector2(strip_x, BOARD_MID_Y + PASS_STRIP_DY))

	# Opponent's bar, mirrored above the line: their turn strip is outermost, so
	# the two strips end up adjacent around the two buttons. Their pass button is
	# a STATUS light, not a control — see _update_opponent_pass_btn.
	_opp_pass_btn = Button.new()
	_opp_pass_btn.text     = "Pass Priority"
	_opp_pass_btn.position = Vector2(btn_x, BOARD_MID_Y - PASS_BTN_DY - 40.0)
	_opp_pass_btn.size     = Vector2(230, 40)
	_opp_pass_btn.disabled = true
	_hud.add_child(_opp_pass_btn)
	_turn_steps_top = _make_turn_step_strip(
		Vector2(strip_x, BOARD_MID_Y - PASS_STRIP_DY - 26.0))

	# ── Mulligan panel (replaces pass area during mulligan phase) ──────────────
	_mulligan_panel = VBoxContainer.new()
	_mulligan_panel.position = Vector2(760, 420)
	_mulligan_panel.custom_minimum_size = Vector2(400, 110)
	_mulligan_panel.visible  = false
	_hud.add_child(_mulligan_panel)

	_mulligan_order_label = Label.new()
	_mulligan_order_label.add_theme_font_size_override("font_size", 14)
	_mulligan_order_label.add_theme_color_override("font_color", Color(0.9, 0.78, 0.35))
	_mulligan_order_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mulligan_panel.add_child(_mulligan_order_label)

	_mulligan_ready_btn = Button.new()
	_mulligan_ready_btn.text = "Ready  (keep hand)"
	# Doubles as the post-mulligan acknowledgement ("Ready  (continue)"): once the
	# player has already committed a mulligan and seen their new hand, the button
	# only hands the seat over.
	_mulligan_ready_btn.pressed.connect(func() -> void:
		if _mulligan_awaiting_ack:
			_finish_mulligan_decision()
		else:
			_commit_mulligan(false))
	_mulligan_panel.add_child(_mulligan_ready_btn)

	_mulligan_btn = Button.new()
	_mulligan_btn.text = "Mulligan  (shuffle & redraw)"
	_mulligan_btn.pressed.connect(func() -> void: _commit_mulligan(true))
	_mulligan_panel.add_child(_mulligan_btn)

	# ── "Controls" window (was the bar's right third) ──────────────────────────
	# Contents keep their former relative layout; the whole block is simply
	# rebased from screen (1320, 960) to the window body's origin.
	var ctl_body := _make_tool_window("Controls  [Esc]", Vector2(610, 205),
		Vector2(1040, BOARD_MID_Y + 66))
	_controls_window = ctl_body.get_parent() as Panel

	# Turn/phase/priority readouts and the log hint moved here from the old turn
	# info panel — reference material, not something to watch, so behind Esc.
	_phase_label    = _add_label("", Vector2(10, 152), 15, Color(0.9, 0.85, 0.45), true, ctl_body)
	_priority_label = _add_label("", Vector2(10, 172), 13, Color(0.9, 0.85, 0.3), true, ctl_body)
	_add_label("Game log  [L]", Vector2(370, 152), 12, Color(0.55, 0.55, 0.6), true, ctl_body)

	# ── Speed Mode selector ────────────────────────────────────────────────────
	_add_label("SPEED MODE  [T]", Vector2(10, 11), 10, Color(0.55, 0.55, 0.55), true, ctl_body)

	var mode_group := ButtonGroup.new()

	_turbo_btn = Button.new()
	_turbo_btn.text          = "Turbo"
	_turbo_btn.position      = Vector2(10, 27)
	_turbo_btn.size          = Vector2(110, 36)
	_turbo_btn.toggle_mode   = true
	_turbo_btn.button_group  = mode_group
	_turbo_btn.toggled.connect(func(on: bool) -> void: if on: _set_turbo_mode(true))
	ctl_body.add_child(_turbo_btn)

	_tactical_btn = Button.new()
	_tactical_btn.text         = "Tactical"
	_tactical_btn.position     = Vector2(10, 67)
	_tactical_btn.size         = Vector2(110, 36)
	_tactical_btn.toggle_mode  = true
	_tactical_btn.button_group = mode_group
	_tactical_btn.button_pressed = true
	_tactical_btn.toggled.connect(func(on: bool) -> void: if on: _set_turbo_mode(false))
	ctl_body.add_child(_tactical_btn)

	# Matches _set_turbo_mode's Tactical branch — the default (see _turbo_mode).
	_mode_desc_label = _add_label("Manual control — all phases",
		Vector2(10, 107), 10, Color(0.52, 0.42, 0.42), true, ctl_body)

	# ── Combat stance selector (next to Speed Mode) ─────────────────────────────
	# Each player sets THEIR stance while they hold the screen; it governs their
	# priority windows during the opponent's turn (see _stance docs above).
	_add_label("COMBAT STANCE", Vector2(150, 11), 10, Color(0.55, 0.55, 0.55), true, ctl_body)

	var stance_group := ButtonGroup.new()

	_stance_ambush_btn = Button.new()
	_stance_ambush_btn.text           = "Ambush"
	_stance_ambush_btn.position       = Vector2(150, 27)
	_stance_ambush_btn.size           = Vector2(110, 36)
	_stance_ambush_btn.toggle_mode    = true
	_stance_ambush_btn.button_group   = stance_group
	_stance_ambush_btn.button_pressed = true
	_stance_ambush_btn.toggled.connect(func(on: bool) -> void:
		if on: _stance[_local_player] = "ambush")
	ctl_body.add_child(_stance_ambush_btn)

	_stance_passive_btn = Button.new()
	_stance_passive_btn.text         = "Passive"
	_stance_passive_btn.position     = Vector2(150, 67)
	_stance_passive_btn.size         = Vector2(110, 36)
	_stance_passive_btn.toggle_mode  = true
	_stance_passive_btn.button_group = stance_group
	_stance_passive_btn.toggled.connect(func(on: bool) -> void:
		if on: _stance[_local_player] = "passive")
	ctl_body.add_child(_stance_passive_btn)

	# Control indications: docked at the window's far right, past the speed slider.
	_mulligan_hint_label = _add_label(
		"Left-click = play/place\nRight-click = options / cancel targeting\nEsc = this panel\nCtrl+Space/Enter = wrap up / end turn\nF = auto-pass combat windows\nL = game log",
		Vector2(468, 3), 10, Color(0.38, 0.38, 0.38), true, ctl_body)
	_mulligan_hint_label.size = Vector2(128, 128)
	_mulligan_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_mulligan_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_mulligan_hint_label.visible = false

	# ── Far right: Animation speed slider (scales every GameTiming pause AND every
	# renderer tween live — see GameTiming.anim) ──
	# animation_speed: 0 = instant (no pauses/tweens), 1 = base timing,
	# up to 3x slower. Cards already animate at GameTiming.DURATION_SCALE.
	var speed_lbl := _add_label("Speed", Vector2(370, 11), 10, Color(0.55, 0.55, 0.55), true, ctl_body)
	speed_lbl.size = Vector2(90, 16)
	_speed_slider = HSlider.new()
	_speed_slider.position   = Vector2(370, 35)
	_speed_slider.size       = Vector2(90, 24)
	_speed_slider.min_value  = 0.0
	_speed_slider.max_value  = 3.0
	_speed_slider.step       = 0.1
	_speed_slider.value      = GameTiming.animation_speed
	_speed_slider.value_changed.connect(func(v: float) -> void:
		GameTiming.animation_speed = v
		if _speed_value_label:
			_speed_value_label.text = "%.1fx" % v)
	ctl_body.add_child(_speed_slider)
	_speed_value_label = _add_label("%.1fx" % GameTiming.animation_speed,
		Vector2(370, 65), 11, Color(0.6, 0.6, 0.65), true, ctl_body)
	_speed_value_label.size = Vector2(90, 16)
	_speed_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# No toggle buttons any more: the turn info they used to open is on the two
	# turn strips, and the Controls panel is bound to Esc (see _input). That frees
	# the whole band between the ally rows.
	# Both windows start closed; clears any shield left over from a previous game.
	_refresh_card_input_shields()

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
	_p2_ai_types = ["human", "recommended"]
	_p2_ai_types.append_array(ai_ids)
	var p1_labels: Array[String] = ["Human", "Recommended AI"]
	for id in ai_ids:
		p1_labels.append(_ai_profile_label(id))
	var p2_labels: Array[String] = ["Human (hotseat)", "Recommended AI"]
	for id in ai_ids:
		p2_labels.append(_ai_profile_label(id))

	inner.add_child(_player_row("Player 1", p1_labels, 0,
		CAT_ALL,
		func(opt): _p1_type_opt = opt, func(opt): _p1_cat_opt = opt, func(opt): _p1_deck_opt = opt))
	_p1_strategy_label = _make_strategy_label()
	inner.add_child(_p1_strategy_label)
	# Default match-up is human vs human hotseat (Quick Start stays human vs AI).
	inner.add_child(_player_row("Player 2", p2_labels, 0,
		CAT_ALL,
		func(opt): _p2_type_opt = opt, func(opt): _p2_cat_opt = opt, func(opt): _p2_deck_opt = opt))
	_p2_strategy_label = _make_strategy_label()
	inner.add_child(_p2_strategy_label)
	_p1_cat_opt.item_selected.connect(func(idx): _repopulate_deck_opt("p1", idx))
	_p2_cat_opt.item_selected.connect(func(idx): _repopulate_deck_opt("p2", idx))
	_p1_deck_opt.item_selected.connect(func(_idx): _update_strategy_label("p1"))
	_p2_deck_opt.item_selected.connect(func(_idx): _update_strategy_label("p2"))
	_repopulate_deck_opt("p1", CAT_ALL)
	_repopulate_deck_opt("p2", CAT_ALL)

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
	_prompt_first_player = false   # Quick Start autopicks random
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
	_prompt_first_player = true
	_launch_game(_p1_ai_types[_p1_type_opt.selected], resolved[0],
				 _p2_ai_types[_p2_type_opt.selected], resolved[1])


func _launch_game(p1_type: String, p1_deck_id: String,
		p2_type: String, p2_deck_id: String) -> void:
	# Deck authorization (rule 100 legality against the card database) — the
	# gate that catches hand-edited custom decks (unknown/unimplemented ids,
	# >4 copies, wrong faction/class) with a readable message instead of a
	# broken game. Runs before the menu is torn down so errors land in it.
	var auth_db := CardDatabase.new()
	auth_db.load_all()
	for pick in [["P1", p1_deck_id], ["P2", p2_deck_id]]:
		var auth_errors := DeckManager.authorize_deck(pick[1], auth_db)
		if not auth_errors.is_empty():
			_show_menu_error("%s deck '%s' is not legal:\n%s"
				% [pick[0], pick[1], "\n".join(auth_errors)])
			return
	_log.clear()
	_log_in_mulligan = false
	_pending_exhaust.clear()
	_menu_layer.visible = false
	_p1_type = p1_type
	_p2_type = p2_type
	_hotseat = p1_type == "human" and p2_type == "human"
	_local_player = "p1" if p1_type == "human" else ("p2" if p2_type == "human" else "p1")
	_last_p1_deck_id = p1_deck_id
	_last_p2_deck_id = p2_deck_id
	_p1_ai   = _make_ai(p1_type, p1_deck_id)
	_p2_ai   = _make_ai(p2_type, p2_deck_id)
	_setup_game_state(DeckManager.get_runtime_deck(p1_deck_id),
					  DeckManager.get_runtime_deck(p2_deck_id))


# Player type string for a player id ("human", "recommended", or an ai_id).
func _type_of(pid: String) -> String:
	return _p1_type if pid == "p1" else _p2_type


# type is "" / "human" (no AI), "recommended" (deck's recommended_ai_id), or
# an ai_profiles/*.json id (e.g. "ai_generic") straight from the dropdown.
func _make_ai(type: String, deck_id: String) -> Object:
	match type:
		"", "human":   return null
		"recommended": return DeckManager.make_ai_for_deck(deck_id)
		_:
			var profile := DeckManager.load_ai_profile(type)
			return profile.make_ai() if profile else null


# ── Hotseat handoff ────────────────────────────────────────────────────────────

# Hide both hands, block every driver (passes, AI, card input) and show a
# fullscreen overlay until `next_player` confirms they have the screen.
# `on_confirm` runs after the perspective/router switch to that player.
func _begin_handoff(next_player: String, reason: String, on_confirm: Callable) -> void:
	_handoff_pending = true
	_wrap_up_active = false   # the outgoing player's wrap-up burst ends at the handoff
	_ai_timer.stop()
	_renderer.set_perspective("__handoff__")
	_renderer.refresh_hand_visibility()
	_set_board_block(true)
	# The table turns to the incoming player while the overlay is up.
	_orient_camera(next_player, true)

	_handoff_layer = CanvasLayer.new()
	_handoff_layer.layer = 25
	add_child(_handoff_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.05, 0.07, 0.97)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_handoff_layer.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-260, -90)
	box.custom_minimum_size = Vector2(520, 180)
	box.add_theme_constant_override("separation", 22)
	_handoff_layer.add_child(box)

	var title := Label.new()
	title.text = "%s — %s" % [next_player.to_upper(), reason]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.45))
	box.add_child(title)

	var hint := Label.new()
	hint.text = "Both hands are hidden. Pass the screen over —\nthe other player should look away now."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	box.add_child(hint)

	var btn := Button.new()
	btn.text = "I'm %s — show my hand" % next_player.to_upper()
	btn.custom_minimum_size = Vector2(280, 46)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(func() -> void: _confirm_handoff(next_player, on_confirm))
	box.add_child(btn)


func _confirm_handoff(next_player: String, on_confirm: Callable) -> void:
	if _handoff_layer:
		_handoff_layer.queue_free()
		_handoff_layer = null
	_set_board_block(false)
	_handoff_pending = false
	_set_local_player(next_player)
	on_confirm.call()


# Switch the screen's seat: hand visibility + input routing follow `pid`.
func _set_local_player(pid: String) -> void:
	_local_player = pid
	_router.setup(_state, _db, pid)
	_renderer.set_perspective(pid)
	_renderer.refresh_hand_visibility()
	_orient_camera(pid, false)   # no-op if _begin_handoff already turned it
	# Stance toggle shows the seated player's own stance.
	if _stance_passive_btn and _stance_ambush_btn:
		var ambush: bool = _stance.get(pid, "ambush") == "ambush"
		_stance_ambush_btn.set_pressed_no_signal(ambush)
		_stance_passive_btn.set_pressed_no_signal(not ambush)


# Turn the board camera to `pid`'s side of the table (TTS-style). The camera
# rotates 180° about BOARD_PIVOT, so the board flips within its own region and
# the HUD layer is untouched. Rotated camera position derivation:
# world BOARD_PIVOT must stay at the same screen point → pos' = 2*PIVOT - pos.
func _orient_camera(pid: String, animate: bool) -> void:
	# World-space UI text counter-rotates with the view (see there). Done before
	# the early-out below: the labels may be built after the camera was placed.
	_orient_res_info_labels(pid)
	if not _camera:
		return
	var flipped := pid == "p2"
	var target_rot: float = 180.0 if flipped else 0.0
	var target_pos: Vector2 = (BOARD_PIVOT * 2.0 - Vector2(960, 540)) if flipped \
			else Vector2(960, 540)
	if _camera_tween:
		_camera_tween.kill()
		_camera_tween = null
	if _camera.rotation_degrees == target_rot and _camera.position == target_pos:
		return
	if animate:
		_camera_tween = create_tween().set_parallel()
		_camera_tween.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
		_camera_tween.tween_property(_camera, "rotation_degrees", target_rot, 0.7)
		_camera_tween.tween_property(_camera, "position", target_pos, 0.7)
	else:
		_camera.rotation_degrees = target_rot
		_camera.position = target_pos
	# Transient world overlays (targeting cursor, damage numbers) counter-rotate.
	_renderer.view_rotation_degrees = target_rot


# ── Ambush mode (off-screen player instant responses) ──────────────────────────

# True when the off-screen player `pid` has at least one legal play right now
# (instants / board powers / armor blocks — only instant-speed things are legal
# off-turn anyway). Probes via the router with local_player briefly swapped.
func _offscreen_has_play(pid: String) -> bool:
	var prev := _router.local_player
	_router.local_player = pid
	var has := _router.has_any_legal_play(true)   # muted cards don't stop the window
	_router.local_player = prev
	return has


# Stop the window for the off-screen ambusher: the router acts for them (their
# playable instants highlight yellow; rules make everything else illegal
# off-turn), but the renderer perspective is untouched — their hand stays
# face-down, fronts shown only on hover (_on_card_hover_scene).
func _enter_ambush_mode(pid: String) -> void:
	if _in_ambush_mode:
		return
	_in_ambush_mode = true
	_ambush_player = pid
	_ai_timer.stop()
	_router.setup(_state, _db, pid)
	_router.set_highlight_color(AMBUSH_HIGHLIGHT)
	_router.refresh_highlights()
	_skip_btn.visible = true
	_set_status("⚡ %s may respond — hover a yellow card to peek, Skip to pass"
			% _ambush_player.to_upper())


func _exit_ambush_mode() -> void:
	if not _in_ambush_mode:
		return
	_in_ambush_mode = false
	_ambush_player = ""
	_skip_btn.visible = false
	_router.set_highlight_color(Color(0.2, 1.0, 0.3))
	_router.setup(_state, _db, _local_player)
	_renderer.refresh_hand_visibility()   # re-hide any hover-peeked card
	_router.refresh_highlights()
	_set_status("")


# ── Mandatory-choice routing ───────────────────────────────────────────────────
# THE funnel every mandatory choice goes through. The engine already addresses
# each pending choice to a specific player (pending_*_player / _chooser), so the
# scene's only job is turning "who decides" into "how do I collect it here":
#
#   "ai"     — the decider is an AI: the caller auto-resolves via the AI hook.
#   "local"  — the decider is the human in this seat: render the choice inline.
#   "peek"   — the decider is a human who is NOT in this seat (hotseat): the
#              router is re-pointed at them so their clicks resolve the choice.
#              A `private` choice also hides their hand (hover peek); a `public`
#              one is board-visible and hides nothing.
#
# A network build replaces the "peek" branch alone (serialize the choice, await
# the remote player's answer) — no card-level code changes.
func _route_choice(decider: String, visibility: String = "private") -> String:
	if _type_of(decider) != "human":
		return "ai"
	if decider == _local_player:
		# A chained choice can hand the decision back to the seated player while
		# a peek is still active (A New Plague: completer, then opponent) — the
		# router must follow the decider.
		if _in_choice_peek:
			_exit_choice_peek_mode()
		return "local"
	_enter_choice_peek_mode(decider, visibility == "private")
	return "peek"


func _enter_choice_peek_mode(pid: String, hide_hand: bool) -> void:
	if _in_choice_peek:
		# Decider switched mid-flow (chained choices) — re-point the router.
		if _choice_peek_player != pid:
			_choice_peek_player = pid
			_choice_peek_hides_hand = hide_hand
			_router.setup(_state, _db, pid)
		return
	_in_choice_peek = true
	_choice_peek_player = pid
	_choice_peek_hides_hand = hide_hand
	_ai_timer.stop()
	_router.setup(_state, _db, pid)


func _exit_choice_peek_mode() -> void:
	if not _in_choice_peek:
		return
	_in_choice_peek = false
	_choice_peek_player = ""
	_choice_peek_hides_hand = false
	_router.setup(_state, _db, _local_player)
	_renderer.refresh_hand_visibility()   # re-hide any hover-peeked card
	_router.refresh_highlights()


func _on_skip_pressed() -> void:
	if not _in_ambush_mode or _state.priority_player != _ambush_player:
		return
	_exit_ambush_mode()
	var events := StackResolver.pass_priority(_state, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_drain_passes()
	_schedule_next_turn()
	_maybe_turbo_pass()


# ── Hand hover (magnify + ambush peek) ─────────────────────────────────────────

func _on_card_hover_scene(instance_id: String) -> void:
	if not _state or _handoff_pending:
		return
	var card := _state.get_card(instance_id)
	var cn := _renderer.card_nodes.get(instance_id) as CardNode
	if not card or not cn:
		return
	# Ambush peek: a playable (yellow) instant in the ambusher's hidden hand
	# shows its face only while hovered.
	if _in_ambush_mode and card.zone_id == _ambush_player + "_hand" \
			and instance_id in _router.get_playable_card_ids():
		cn.show_card_front()
	# Discard peek: the off-screen player choosing a mandatory discard peeks
	# their face-down hand one card at a time.
	if _in_choice_peek and _choice_peek_hides_hand and card.zone_id == _choice_peek_player + "_hand":
		cn.show_card_front()
	# The local player's own hand magnifies on hover.
	if card.zone_id == _local_player + "_hand":
		cn.set_base_scale(Vector2.ONE * (BoardRenderer.HAND_CARD_SCALE * HOVER_MAGNIFY))
		cn.z_index = BoardRenderer.HAND_Z_INDEX + 1


func _on_card_unhover_scene(instance_id: String) -> void:
	if not _state:
		return
	var card := _state.get_card(instance_id)
	var cn := _renderer.card_nodes.get(instance_id) as CardNode
	if not card or not cn:
		return
	if _in_ambush_mode and card.zone_id == _ambush_player + "_hand":
		cn.show_card_back()
	if _in_choice_peek and _choice_peek_hides_hand and card.zone_id == _choice_peek_player + "_hand":
		cn.show_card_back()
	if card.zone_id.ends_with("_hand"):
		cn.set_base_scale(Vector2.ONE * BoardRenderer.HAND_CARD_SCALE)
		cn.z_index = BoardRenderer.HAND_Z_INDEX


func _add_deck_back_sprite(pos: Vector2, facing: float = 0.0) -> void:
	var back: Texture2D = load(CardNode.CARD_BACK_PATH)
	if not back:
		return
	var tex := TextureRect.new()
	tex.texture      = back
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tex.size         = Vector2(CardNode.W, CardNode.H)
	tex.position     = pos - Vector2(CardNode.W * 0.5, CardNode.H * 0.5)
	tex.pivot_offset = tex.size * 0.5
	tex.rotation_degrees = facing
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tex)


# Every board anchor is written in BASE board coordinates (the layout as
# documented in _build_scene) and shifted down by BOARD_Y_OFFSET here, the one
# place it is applied — so the whole board can be re-centred in the viewport by
# changing that single constant. BOARD_MID_Y and BOARD_PIVOT are derived from it.
# Base board coordinates → world position (see _make_anchor). For world-space
# decoration that has to travel with the board but isn't a zone anchor.
func _board_pos(x: float, y: float) -> Vector2:
	return Vector2(x, y + BOARD_Y_OFFSET)


# ── Resource zone grid lines ──────────────────────────────────────────────────
# The resource ROW is now a resource ZONE: a 5x2 grid in the player's own
# bottom-left corner instead of one ever-widening row. The cards themselves are
# placed by BoardRenderer's resource grid (see _slot_offset there); this draws
# the cell lines behind them.
#
# The grid is drawn from the SAME constants the layout uses, so the lines touch
# the card edges exactly — a cell is one card HEIGHT square, the smallest cell a
# card can never overflow in either orientation (an exhausted card is rotated
# 90°, so it is card-height WIDE).
#
# ── P1 row positions, derived from card size ──────────────────────────────────
# Everything below is computed from CardNode's dimensions and BoardRenderer's
# CARD_PAD (= card height / 5), stacked upward from the bottom screen edge, so
# resizing the cards rescales the rows, slots and gaps with no further edits.
# P2's positions are the mirror image of these (see _register_mirrored_zone).
#
# All values are in BASE board coordinates: base = world - BOARD_Y_OFFSET.
# The outermost edge of a player's content, one CARD_PAD off the screen edge:
const P1_EDGE_Y   := VIEWPORT_H - BoardRenderer.CARD_PAD - BOARD_Y_OFFSET
const HAND_HALF_H := CardNode.H * BoardRenderer.HAND_CARD_SCALE * 0.5
const SLOT_HALF_H := BoardRenderer.CARD_SLOT * 0.5
# Hand sits on the edge; each row stacks a CARD_PAD above the one before it.
const HAND_ROW_Y := P1_EDGE_Y - HAND_HALF_H
const HERO_ROW_Y := HAND_ROW_Y - HAND_HALF_H - BoardRenderer.CARD_PAD - SLOT_HALF_H
const ALLY_ROW_Y := HERO_ROW_Y - BoardRenderer.CARD_SLOT - BoardRenderer.CARD_PAD
# Deck / graveyard sit in the outer column, bottom-aligned with everything else.
const DECK_ROW_Y := P1_EDGE_Y - SLOT_HALF_H
# The hero card shares the deck's column and renders at HERO_CARD_SCALE, so at
# 2x it no longer fits between its own row's height and the deck. It is pinned
# to its hero row where possible and otherwise pushed up just enough to clear
# the deck — which is where the current 2x hero size shows: it ends up slightly
# above the equipment sitting in its row. Shrinking HERO_CARD_SCALE (or moving
# the deck column) closes that gap; the clamp only guarantees they never touch.
const HERO_CARD_Y := minf(HERO_ROW_Y,
	DECK_ROW_Y - SLOT_HALF_H - BoardRenderer.CARD_PAD
		- CardNode.H * BoardRenderer.HERO_CARD_SCALE * 0.5)

# Centre of P1's resource grid, in base board coordinates; P2's is its mirror.
# Bottom-aligned with the hand, in the corner beside it.
const RES_ZONE_CENTRE := Vector2(
	BoardRenderer.RES_GRID_COLS * BoardRenderer.RES_CELL * 0.5 + BoardRenderer.CARD_PAD,
	P1_EDGE_Y - BoardRenderer.RES_GRID_ROWS * BoardRenderer.RES_CELL * 0.5)
# Plain white — these lines are scaffolding for judging the layout and will be
# removed once the zone's final look is settled, so they read clearly rather
# than blending into the board.
const RES_ZONE_LINE := Color(1.0, 1.0, 1.0, 0.55)
const HERO_ROW_LINE := Color(0.78, 0.35, 1.0, 0.75)   # abilities / equipment
const ALLY_ROW_LINE := Color(1.0, 0.9, 0.2, 0.75)     # allies

# ── Combat window ─────────────────────────────────────────────────────────────
# Everything about the combat in progress, in one place: which step of rule 602
# we are in, who is attacking whom, and — when it is open — the protect point's
# prompt and buttons. It used to be a bare inline row over the pass button with
# no context beyond "X is attacking Y".
#
# Parked in the free band on the left, between the top player's column and the
# bottom player's resource zone, so it never covers either ally row: the protect
# point stays clickable on the board (a legal protector can be picked by
# clicking the card itself, not just its button).
const COMBAT_WINDOW_AT   := Vector2(30, 380)
const COMBAT_BODY_SIZE   := Vector2(560, 250)
const COMBAT_BTN_H       := 36.0
const COMBAT_BTN_GAP     := 8.0

func _build_combat_window() -> void:
	_combat_body = _make_tool_window("Combat", COMBAT_BODY_SIZE, COMBAT_WINDOW_AT, false)
	_combat_window = _combat_body.get_parent() as Panel
	_combat_window.visible = false

	# The whole 602 sequence, always visible, current step bolded — so the
	# players can see where in the process the combat is, not just its name.
	_combat_steps_rtl = RichTextLabel.new()
	_combat_steps_rtl.bbcode_enabled = true
	_combat_steps_rtl.scroll_active  = false
	_combat_steps_rtl.fit_content    = true
	_combat_steps_rtl.position       = Vector2(12, 10)
	_combat_steps_rtl.size           = Vector2(COMBAT_BODY_SIZE.x - 24, 26)
	_combat_steps_rtl.mouse_filter   = Control.MOUSE_FILTER_IGNORE
	_combat_steps_rtl.add_theme_font_size_override("normal_font_size", 14)
	_combat_steps_rtl.add_theme_font_size_override("bold_font_size", 14)
	_combat_body.add_child(_combat_steps_rtl)

	_combat_atk_lbl  = _add_label("", Vector2(12, 46), 15,
		Color(0.92, 0.92, 0.95), true, _combat_body)
	_combat_def_lbl  = _add_label("", Vector2(12, 70), 15,
		Color(0.92, 0.92, 0.95), true, _combat_body)
	# Alt+hover a combatant's NAME to examine the card it names — the magnified
	# card appears beside the actual board card, which points out WHICH ally is
	# meant when several share a name. Hover state is polled in _process so
	# pressing Alt after the pointer is already on the name works too.
	_wire_combat_name_hover(_combat_atk_lbl, true)
	_wire_combat_name_hover(_combat_def_lbl, false)
	_combat_prompt_lbl = _add_label("", Vector2(12, 104), 15,
		Color(0.9, 0.5, 0.2), true, _combat_body)
	_combat_prompt_lbl.size = Vector2(COMBAT_BODY_SIZE.x - 24, 40)
	_combat_prompt_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD

	# Buttons (protect point) are rebuilt per prompt; this just reserves the row.
	_combat_btn_row = Control.new()
	_combat_btn_row.position     = Vector2(12, 150)
	_combat_btn_row.size         = Vector2(COMBAT_BODY_SIZE.x - 24, COMBAT_BTN_H)
	_combat_btn_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combat_body.add_child(_combat_btn_row)


# The full rule-602 sequence, always displayed; the live step is bolded.
const COMBAT_STEPS := [
	["proposition", "Proposition"], ["attack", "Atk wind."],
	["protect", "Protection"], ["defend", "Def wind."],
	["conclusion", "Conclusion"]]

# Which step of rule 602 the combat is in, or "" when no combat is live.
func _combat_step_key() -> String:
	if not _state:
		return ""
	if _state.in_protect_point:
		return "protect"
	if _state.combat_defend_window:
		return "defend"
	if _state.combat_attack_window:
		return "attack"
	# Attacker committed, no window open and the protect point passed: damage is
	# being dealt / the step is wrapping up.
	if _state.combat_attacker != "":
		return "conclusion"
	for pa in _state.pending_actions:
		if (pa as PendingAction).action_type == "propose_combat":
			return "proposition"
	return ""


func _combat_steps_bbcode(current: String) -> String:
	var parts: Array[String] = []
	for step in COMBAT_STEPS:
		if step[0] == current:
			parts.append("[b][color=#ff9e40]%s[/color][/b]" % step[1])
		else:
			parts.append("[color=#71717e]%s[/color]" % step[1])
	return "  ·  ".join(parts)


# Alt+hover on a combatant NAME examines that card, anchored beside the real
# card on the board. Labels ignore the mouse by default, so opt this one in.
func _wire_combat_name_hover(lbl: Label, is_attacker: bool) -> void:
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	lbl.mouse_entered.connect(func() -> void:
		_combat_name_hover_id = _combat_atk_id if is_attacker else _combat_def_id)
	lbl.mouse_exited.connect(func() -> void:
		_combat_name_hover_id = "")


# The combatants: taken from the live combat once it has started, and from the
# pending proposal while it is still on the chain (nothing is committed yet, so
# GameState.combat_attacker is still empty then).
func _combat_participants() -> Array:
	if _state.combat_attacker != "":
		return [_state.combat_attacker, _state.combat_defender]
	for pa in _state.pending_actions:
		var a := pa as PendingAction
		if a.action_type == "propose_combat":
			return [a.params.get("attacker_id", ""), a.params.get("defender_id", "")]
	return ["", ""]


# Refreshed from _refresh_ui, so the readout tracks every step change without
# each combat event handler having to remember to update it.
func _update_combat_window() -> void:
	if not _combat_window:
		return
	var step := _combat_step_key()
	if step == "":
		_combat_atk_id = ""
		_combat_def_id = ""
		_combat_name_hover_id = ""
		if _combat_window.visible:
			_combat_window.visible = false
			_refresh_card_input_shields()
		return

	var who := _combat_participants()
	_combat_atk_id = who[0]
	_combat_def_id = who[1]
	_combat_steps_rtl.text = _combat_steps_bbcode(step)
	# Nothing is committed until the proposal resolves (601.3 can still fizzle
	# it), so the combatants are "proposed" only during that first step.
	var proposed := step == "proposition"
	_combat_atk_lbl.text = ("Proposed attacker:  %s" if proposed
		else "Attacker:  %s") % _log_card(who[0])
	_combat_def_lbl.text = ("Proposed defender:  %s" if proposed
		else "Defender:  %s") % _log_card(who[1])
	if not _combat_window.visible:
		_combat_window.visible = true
		_refresh_card_input_shields()


func _clear_combat_buttons() -> void:
	if not _combat_btn_row:
		return
	for c in _combat_btn_row.get_children():
		c.queue_free()
	if _combat_prompt_lbl:
		_combat_prompt_lbl.text = ""


const ROW_GRID_COLS := 7   # slots outlined per ally / hero row

func _draw_zone_grids() -> void:
	for spec in [
		{"centre": RES_ZONE_CENTRE, "cols": BoardRenderer.RES_GRID_COLS,
			"rows": BoardRenderer.RES_GRID_ROWS, "color": RES_ZONE_LINE},
		{"centre": Vector2(BOARD_MIRROR.x, HERO_ROW_Y), "cols": ROW_GRID_COLS,
			"rows": 1, "color": HERO_ROW_LINE},
		{"centre": Vector2(BOARD_MIRROR.x, ALLY_ROW_Y), "cols": ROW_GRID_COLS,
			"rows": 1, "color": ALLY_ROW_LINE},
	]:
		# Drawn for P1 and, mirrored, for P2 — same construction as the anchors.
		for base_centre in [spec["centre"], _mirror(spec["centre"])]:
			_draw_zone_grid(base_centre, spec["cols"], spec["rows"], spec["color"])


func _draw_zone_grid(base_centre: Vector2, cols: int, rows: int, color: Color) -> void:
	var cell: float = BoardRenderer.CARD_SLOT
	var size := Vector2(cols * cell, rows * cell)
	var origin := _board_pos(base_centre.x, base_centre.y) - size * 0.5

	var frame := Panel.new()
	frame.position     = origin
	frame.size         = size
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.z_index      = -2
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r, color.g, color.b, 0.05)
	sb.set_border_width_all(2)
	sb.border_color = color
	frame.add_theme_stylebox_override("panel", sb)
	add_child(frame)

	# Interior cell lines only — the frame already draws the outer edges.
	for col in range(1, cols):
		_add_grid_line(origin + Vector2(col * cell, 0), Vector2(1, size.y), color)
	for row in range(1, rows):
		_add_grid_line(origin + Vector2(0, row * cell), Vector2(size.x, 1), color)


func _add_grid_line(pos: Vector2, size: Vector2, color: Color) -> void:
	var line := ColorRect.new()
	line.color        = color
	line.position     = pos
	line.size         = size
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.z_index      = -2
	add_child(line)


# Reflect a base board position through BOARD_MIRROR — P2's side of the table.
func _mirror(base_pos: Vector2) -> Vector2:
	return BOARD_MIRROR * 2.0 - base_pos


# Register "p1_<suffix>" at `p1_base` and "p2_<suffix>" at its mirror image, so
# a layout tweak to one side is automatically applied to the other.
func _register_mirrored_zone(suffix: String, p1_base: Vector2) -> void:
	_renderer.register_zone("p1_" + suffix, _make_anchor(p1_base))
	_renderer.register_zone("p2_" + suffix, _make_anchor(_mirror(p1_base)))


func _make_anchor(pos: Vector2) -> Node2D:
	var a := Node2D.new()
	a.global_position = pos + Vector2(0, BOARD_Y_OFFSET)
	add_child(a)
	return a


# hud=true parents the label to the _hud CanvasLayer (screen-fixed, never
# rotated by the board camera); hud=false leaves it in the world (board labels
# like the deck/graveyard tags, which must travel and turn with the board).
#
# `parent` overrides both: the label is added there instead (used by the tool
# windows, whose contents are positioned relative to the window body).
func _add_label(text: String, pos: Vector2, size: int, color: Color, hud: bool = false,
		parent: Node = null) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.position = pos
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	if parent:
		parent.add_child(lbl)
	elif hud:
		_hud.add_child(lbl)
	else:
		add_child(lbl)
	return lbl


# ── Tool windows ──────────────────────────────────────────────────────────────
# A floating HUD window: draggable by its title bar, closable by the ✕ in the
# corner or the Close button at the foot, reopened from its bottom-right toggle
# button. Contents are added to the returned body Control and positioned
# relative to it, so a window can be dragged anywhere without touching them.
#
# Returns the body Control; the window Panel itself is body.get_parent().
const TOOL_WINDOW_TITLE_H := 30.0
const TOOL_WINDOW_FOOT_H  := 42.0

# The board's mirror line: exactly midway between the two ally rows (base y 369
# and 531), i.e. the line the two players' halves reflect about, shifted with the
# rest of the board. Note the ROWS mirror about base 450 while the outer
# deck/graveyard columns mirror about base 475 — the board has always been 25px
# inconsistent there; this line follows the rows, as asked.
const BOARD_MID_Y := 450.0 + BOARD_Y_OFFSET

# The two blocks the old full-width bottom strip was trimmed down to.
#
# The pass block's TOP edge sits on BOARD_MID_Y, so it reads as belonging to the
# bottom player: this is the anchor for the planned mirrored design, where each
# player gets their own pass bar on their own side of the line, greyed out when
# it isn't theirs to press. It holds only the resource indicator and the pass
# button; Cancel is transient (targeting only) and hangs just below rather than
# reserving a permanently-empty third slot inside the bar.
#
# The window-toggle pair sits immediately to its right in what that empty slot
# used to be, CENTRED on the same line — Turn info above it, Controls below.
# Both blocks are right-aligned to the same margin.
#
# Both are also permanent card-input shields: cards hit-test the raw pointer
# themselves, so anything underneath a block must not answer clicks.
const BLOCK_RIGHT_EDGE  := 1900.0
# Left edge of the TOP player's resource zone: the pass block may not reach any
# closer to the centre than this, so the whole band between the ally rows stays
# free. P1's zone spans CARD_PAD .. CARD_PAD + cols*cell from the left edge, and
# P2's is its mirror image, so its left edge is 1920 minus P1's right edge.
const FREE_BAND_RIGHT := 1920.0 - (BoardRenderer.CARD_PAD
	+ BoardRenderer.RES_GRID_COLS * BoardRenderer.RES_CELL)
# The pass block now holds BOTH players' bars, straddling the mirror line: the
# opponent's turn strip and pass button above it, the seated player's below, each
# half the mirror image of the other. Reading top to bottom:
#   opponent strip · opponent pass button │ pass button · turn strip
# The block is anchored on BOARD_MID_Y and grows symmetrically from it.
const PASS_HALF_H       := 92.0
const PASS_BLOCK_W      := 460.0
const PASS_BLOCK_RECT   := Rect2(BLOCK_RIGHT_EDGE - PASS_BLOCK_W,
	BOARD_MID_Y - PASS_HALF_H, PASS_BLOCK_W, PASS_HALF_H * 2.0)
# Offsets from the mirror line for the seated player's half; the opponent's are
# these negated (button and strip swap order, so their strip ends up outermost).
const PASS_BTN_DY       := 13.0
const PASS_STRIP_DY     := 56.0
# Pass buttons size themselves to their label and re-centre (_centre_in_pass_block).
const PASS_BTN_MIN_W    := 230.0
const PASS_BTN_TEXT_PAD := 28.0

#
# `closable = false` drops both the ✕ and the Close button (the chain window:
# the player may move it out of the way but must not dismiss the one display
# that says what is about to resolve).
func _make_tool_window(title: String, body_size: Vector2, at: Vector2,
		closable: bool = true) -> Control:
	var foot: float = TOOL_WINDOW_FOOT_H if closable else 8.0
	var win := Panel.new()
	win.position = at
	win.size     = Vector2(body_size.x, body_size.y + TOOL_WINDOW_TITLE_H + foot)
	win.visible  = false
	# Above the bar and the chain panel, below the modal dialogs (dimmer z 19+).
	win.z_index  = 12
	_hud.add_child(win)

	var bar := ColorRect.new()
	bar.name  = "TitleBar"   # _resize_tool_window looks it up by name
	bar.color = Color(0.18, 0.22, 0.28)
	bar.size  = Vector2(body_size.x, TOOL_WINDOW_TITLE_H)
	bar.gui_input.connect(func(ev: InputEvent) -> void: _on_window_bar_input(win, ev))
	win.add_child(bar)

	var title_lbl := Label.new()
	title_lbl.text     = title
	title_lbl.position = Vector2(10, 5)
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(title_lbl)

	if closable:
		var x_btn := Button.new()
		x_btn.text     = "✕"
		x_btn.position = Vector2(body_size.x - 28, 3)
		x_btn.size     = Vector2(24, 24)
		x_btn.pressed.connect(func() -> void: _set_window_open(win, false))
		bar.add_child(x_btn)

	var body := Control.new()
	body.position = Vector2(0, TOOL_WINDOW_TITLE_H)
	body.size     = body_size
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	win.add_child(body)

	if closable:
		var close_btn := Button.new()
		close_btn.text     = "Close"
		close_btn.position = Vector2(body_size.x - 100,
			TOOL_WINDOW_TITLE_H + body_size.y + 6)
		close_btn.size     = Vector2(90, 30)
		close_btn.pressed.connect(func() -> void: _set_window_open(win, false))
		win.add_child(close_btn)

	return body


# Re-size a window whose body changes shape at runtime (the chain grows a slot
# per link). The title bar is a plain child sized at build time, so it has to be
# stretched to match or it leaves a gap on a widened window.
func _resize_tool_window(win: Panel, body_size: Vector2, foot: float) -> void:
	if not win:
		return
	win.size = Vector2(body_size.x, body_size.y + TOOL_WINDOW_TITLE_H + foot)
	var bar := win.get_node_or_null("TitleBar") as ColorRect
	if bar:
		bar.size.x = body_size.x


func _set_window_open(win: Panel, open: bool) -> void:
	if not win:
		return
	win.visible = open
	if not open and _dragging_window == win:
		_dragging_window = null
	_update_window_btns()
	_refresh_card_input_shields()


# Board cards hit-test the raw pointer themselves (CardNode._input), so a window
# floating over the board would otherwise let a click pass through to the card
# underneath. Re-register the open windows' rects whenever one opens, closes or
# moves.
func _refresh_card_input_shields() -> void:
	var rects: Array[Rect2] = [PASS_BLOCK_RECT]
	for win in [_turn_info_window, _controls_window, _chain_window]:
		if win and is_instance_valid(win) and win.visible:
			rects.append(Rect2(win.position, win.size))
	CardNode.input_shields = rects


# Drag by the title bar. The press/release arrives on the bar; the motion is
# handled in _process so the window keeps following even when the pointer
# outruns the bar's own rect.
func _on_window_bar_input(win: Panel, ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_dragging_window = win
		_drag_offset     = win.get_global_mouse_position() - win.position
		if win == _chain_window:
			# Player has placed it themselves — stop auto-centring on resize.
			_chain_window_moved = true
		# Dragged window comes to the front of the others.
		for other in [_turn_info_window, _controls_window, _chain_window]:
			if other and is_instance_valid(other):
				other.z_index = 13 if other == win else 12
	else:
		_dragging_window = null


func _drag_tool_window() -> void:
	if not _dragging_window or not is_instance_valid(_dragging_window):
		_dragging_window = null
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging_window = null
		return
	var pos: Vector2 = _dragging_window.get_global_mouse_position() - _drag_offset
	# Keep the title bar reachable — never let a window be dragged fully off.
	var vp := get_viewport().get_visible_rect().size
	pos.x = clamp(pos.x, 40.0 - _dragging_window.size.x, vp.x - 40.0)
	pos.y = clamp(pos.y, 0.0, vp.y - TOOL_WINDOW_TITLE_H)
	_dragging_window.position = pos
	_refresh_card_input_shields()


func _update_window_btns() -> void:
	# The toggle buttons are gone (turn info is on the strips, Controls is on Esc).
	# Kept as a no-op hook so _set_window_open still has one place to notify.
	return


# Rotate a world-space label 180° about its own centre (so P2's side labels
# read upright from P2's seat). Deferred so the Label has auto-sized first.
func _rotate_label_180(lbl: Label) -> void:
	lbl.call_deferred("set", "pivot_offset", lbl.size * 0.5)
	lbl.rotation_degrees = 180
	return


# ── Game state setup ───────────────────────────────────────────────────────────

func _setup_game_state(deck_p1: Deck, deck_p2: Deck) -> void:
	_stats.reset()   # fresh match stats before any card_moved/card_played fires

	# Hotseat: hide BOTH hands from the start — the first handoff overlay (mulligan)
	# reveals the right one. Must run before any card node is placed.
	if _hotseat:
		_renderer.set_perspective("__handoff__")

	# Real database — only engine_status=implemented cards are loaded.
	_db = CardDatabase.new()
	_db.load_all()

	# Mock-only cards (no CSV row yet): instants and quest placeholder.
	_db.add_def(_make_mock_def("mock_quick_shot", "Quick Shot", 0, 0, true, "Ability"))
	_db.add_def(_make_mock_def("mock_dark_bolt",  "Dark Bolt",  0, 0, true, "Ability"))

	# GameManager builds the full state: creates zones, places heroes, shuffles
	# decks, draws 7-card starting hands.
	_gm = GameManager.new()
	_gm.setup(_db)
	_gm.add_player("p1", GameManager.HUMAN if _p1_type == "human" else GameManager.AI, deck_p1)
	_gm.add_player("p2", GameManager.HUMAN if _p2_type == "human" else GameManager.AI, deck_p2)
	_state = _gm.build_state()
	# Resource stacking reads pose/name straight from the state (pure rendering).
	_renderer.set_state_context(_state, _db)

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

	_router.muted_ids.clear()   # mutes are per-game (fresh instance ids each game)
	_router.setup(_state, _db, _local_player)
	_orient_camera(_local_player, false)   # e.g. single human seated at p2 vs AI

	# Who goes first — prompt (normal start / rematch) or autopick random (Quick Start).
	_choose_first_player()


# Display name of a player's hero (for the who-goes-first labels).
func _hero_name(pid: String) -> String:
	var ps := _state.players.get(pid) as PlayerState
	if ps and ps.hero_instance_id != "":
		var card := _state.get_card(ps.hero_instance_id)
		var def: CardDef = _db.get_def(card.card_def_id) if card else null
		if def:
			return def.card_name
	return pid.to_upper()


# After the board is built, decide who goes first. Quick Start skips the prompt
# and picks random; a normal start or rematch shows a selection screen.
func _choose_first_player() -> void:
	if not _prompt_first_player:
		_begin_game("p1" if randi() % 2 == 0 else "p2")
		return

	_first_player_layer = CanvasLayer.new()
	_first_player_layer.layer = 25
	add_child(_first_player_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.05, 0.07, 0.97)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_first_player_layer.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-260, -130)
	box.custom_minimum_size = Vector2(520, 260)
	box.add_theme_constant_override("separation", 18)
	_first_player_layer.add_child(box)

	var title := Label.new()
	title.text = "Who goes first?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.45))
	box.add_child(title)

	var options := [
		["Random", ""],
		["P1 — %s — goes first" % _hero_name("p1"), "p1"],
		["P2 — %s — goes first" % _hero_name("p2"), "p2"],
	]
	for opt in options:
		var label: String = opt[0]
		var choice: String = opt[1]
		var btn := Button.new()
		btn.text = label
		btn.custom_minimum_size = Vector2(360, 46)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.pressed.connect(func() -> void: _on_first_player_chosen(choice))
		box.add_child(btn)


func _on_first_player_chosen(choice: String) -> void:
	if _first_player_layer:
		_first_player_layer.queue_free()
		_first_player_layer = null
	var first_player: String = choice
	if first_player == "":
		first_player = "p1" if randi() % 2 == 0 else "p2"
	_begin_game(first_player)


# Start the game — fires phase_changed (ready) which sets up the first window.
func _begin_game(first_player: String) -> void:
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
	node.card_hovered.connect(_on_card_hover_scene)
	node.card_unhovered.connect(_on_card_unhover_scene)
	add_child(node)
	_renderer.register_card(inst_id, node)
	_renderer.place_card_in_zone(inst_id, card.zone_id)


# ── UI refresh ─────────────────────────────────────────────────────────────────

func _refresh_ui() -> void:
	# Ambush stop is over the moment priority leaves the ambusher (they played
	# and passed, or their link fizzled) — restore router/highlights to the seat.
	if _in_ambush_mode and _state and _state.priority_player != _ambush_player:
		_exit_ambush_mode()
	_update_priority_label()
	_update_chain_panel()
	_update_combat_window()
	_update_phase_label()
	if not _in_protect_mode and not _in_strike_mode and not _in_ready_mode \
			and not _in_strike_ready_mode and not _in_whelp_bounce_mode:
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
	_refresh_ready_lock_badges()


# ⛓ badge on every in-play card that will be skipped by its controller's next
# ready step (Entangling Roots host, ally facing an opposing Earthbind Totem).
# Live probe (TurnManager.is_ready_blocked) — badges self-clear when the aura
# or attachment leaves play.
func _refresh_ready_lock_badges() -> void:
	if not _state or not _db or not _renderer:
		return
	for pid in _state.players:
		for card in _state.cards_in_play(pid):
			var cn := _renderer.card_nodes.get(card.instance_id) as CardNode
			if cn:
				cn.set_ready_locked(TurnManager.is_ready_blocked(_state, card, _db))


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
		Color(0.4, 0.9, 0.4) if who == _local_player else Color(0.9, 0.5, 0.4))


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


# ── Visual chain panel ─────────────────────────────────────────────────────────
# Stack showing every link on the chain, bottom-up (LIFO: the topmost entry
# resolves next). Card-backed links show the card image with a caption
# ("played" / "power" / …); links with no public card face (combat proposals,
# face-down resources) show a card-sized text rectangle instead.
#
# Laid out HORIZONTALLY in play order: oldest link on the left, newest on the
# right. Resolution therefore reads right-to-left — the rightmost link is the
# top of the chain and resolves first, unless another link is added, which
# appears to its right and takes over.
#
# Lives in its own draggable window (_chain_window), which this function sizes
# to the current link count and shows/hides — an empty chain shows nothing.

const CHAIN_CARD_W       := 90.0
const CHAIN_CARD_H       := 126.0
const CHAIN_CAPTION_H    := 18.0
# Second caption line: the targets announced WITH the link (707.1 — targets are
# chosen at announcement, not at resolution), so a responder can see what is
# aimed at what while the window is still open. Reserved only when at least one
# link on the chain actually has targets.
const CHAIN_TARGET_H     := 16.0
const CHAIN_ENTRY_GAP    := 8.0
const CHAIN_PANEL_PAD    := 8.0
# Floor on the body width so the window title always fits; a body narrower than
# this (one or two links) centres its entries instead.
const CHAIN_PANEL_MIN_W  := 250.0

func _update_chain_panel() -> void:
	if not _chain_panel or not _chain_window:
		return
	for child in _chain_panel.get_children():
		child.queue_free()
	if not _state or _state.pending_actions.is_empty():
		if _chain_window.visible:
			_chain_window.visible = false
			_refresh_card_input_shields()
		return

	var count := _state.pending_actions.size()
	var step := CHAIN_CARD_W + CHAIN_ENTRY_GAP
	# Only reserve the target row when some link on the chain has targets to show.
	var target_h := 0.0
	for a in _state.pending_actions:
		if _chain_action_targets(a as PendingAction) != "":
			target_h = CHAIN_TARGET_H
			break
	var body_h: float = CHAIN_CARD_H + CHAIN_CAPTION_H + target_h + CHAIN_PANEL_PAD * 2.0
	var strip_w: float = count * step - CHAIN_ENTRY_GAP
	var body_w: float = maxf(CHAIN_PANEL_MIN_W, strip_w + CHAIN_PANEL_PAD * 2.0)
	# Centre the strip when the title's minimum width is the wider of the two.
	var x0: float = (body_w - strip_w) * 0.5

	for i in count:
		var action := _state.pending_actions[i] as PendingAction
		var is_top := (i == count - 1)
		# Play order, left to right: index 0 (the oldest link, bottom of the
		# chain) sits leftmost, so the LAST index — the one that resolves next —
		# ends up on the right.
		var x: float = x0 + i * step
		_chain_panel.add_child(
			_make_chain_entry(action, Vector2(x, CHAIN_PANEL_PAD), is_top))

	_chain_panel.size = Vector2(body_w, body_h)
	_resize_tool_window(_chain_window, Vector2(body_w, body_h), 8.0)
	# Re-centre only until the player has dragged it — after that their placement
	# is theirs to keep, even as links are added and removed.
	if not _chain_window_moved:
		_chain_window.position = Vector2(960.0 - _chain_window.size.x * 0.5,
			540.0 - _chain_window.size.y * 0.5)
	_chain_window.visible = true
	_refresh_card_input_shields()


func _make_chain_entry(action: PendingAction, pos: Vector2, is_top: bool) -> Control:
	var entry := Control.new()
	entry.position = pos
	entry.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var frame := Panel.new()
	frame.custom_minimum_size = Vector2.ZERO
	frame.size = Vector2(CHAIN_CARD_W, CHAIN_CARD_H)
	frame.clip_contents = true   # belt-and-suspenders: never let a child's own minimum size push the box larger
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = Color(1.0, 0.9, 0.3) if is_top else Color(0.45, 0.48, 0.55)
	frame.add_theme_stylebox_override("panel", sb)
	entry.add_child(frame)

	var caption := ""
	var tex: Texture2D = null
	match action.action_type:
		"propose_combat":
			# No card face — combat proposal rectangle: attacker + proposed defender.
			pass
		"place_resource":
			# Resources enter play face down — never show the card face here.
			caption = "resource"
		"play_ally", "play_instant", "play_ability", "play_equipment":
			caption = "played"
			tex = _chain_action_texture(action)
		"use_ally_power", "activate_power":
			caption = "power"
			tex = _chain_action_texture(action)
		"use_quest":
			caption = "quest"
			tex = _chain_action_texture(action)
		_:
			caption = action.action_type
			tex = _chain_action_texture(action)

	if tex:
		var tr := TextureRect.new()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.custom_minimum_size = Vector2.ZERO
		tr.position = Vector2(2, 2)
		tr.size = Vector2(CHAIN_CARD_W - 4, CHAIN_CARD_H - 4)
		tr.texture = tex   # assign last — texture-driven minimum size is already neutralized above
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(tr)
	else:
		var txt := Label.new()
		txt.text = _describe_pending_action(action)
		txt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE, 4)
		txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		txt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		txt.add_theme_font_size_override("font_size", 12)
		txt.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95))
		txt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(txt)

	if caption != "":
		var cap := Label.new()
		cap.text = caption
		cap.position = Vector2(0, CHAIN_CARD_H + 2)
		cap.size = Vector2(CHAIN_CARD_W, CHAIN_CAPTION_H - 2)
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.add_theme_font_size_override("font_size", 12)
		cap.add_theme_color_override("font_color",
				Color(1.0, 0.9, 0.3) if is_top else Color(0.7, 0.72, 0.78))
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		entry.add_child(cap)

	# Targets are locked in at announcement (707.1), so the opponent must be able
	# to read them off the chain while the response window is open.
	var targets := _chain_action_targets(action)
	if targets != "":
		var tgt := Label.new()
		tgt.text = targets
		tgt.position = Vector2(0, CHAIN_CARD_H + CHAIN_CAPTION_H)
		tgt.size = Vector2(CHAIN_CARD_W, CHAIN_TARGET_H)
		tgt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tgt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tgt.clip_text = true
		tgt.tooltip_text = targets
		tgt.add_theme_font_size_override("font_size", 11)
		tgt.add_theme_color_override("font_color", Color(0.62, 0.86, 1.0))
		tgt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		entry.add_child(tgt)
	return entry


# The targets announced with a pending action, for the chain entry's second
# caption line ("→ Grimdron", "→ Ta'zo, sac: Voss Treebender"). Empty when the
# link announces nothing to point at (combat proposals describe themselves in
# the text rect; resources and untargeted powers have no target at all).
func _chain_action_targets(action: PendingAction) -> String:
	if action == null or action.action_type == "propose_combat":
		return ""
	var ids: Array[String] = []
	for key in ["target_id", "target_id_2", "target_id_3", "heal_target_id"]:
		var tid: String = action.params.get(key, "")
		if tid != "" and not ids.has(tid):
			ids.append(tid)
	# Divided damage (Lightning Storm) announces one id per point, repeats and all.
	var list: Variant = action.params.get("target_ids", [])
	if list is Array:
		for raw in list:
			var tid := str(raw)
			if tid != "" and not ids.has(tid):
				ids.append(tid)
	var parts: Array[String] = []
	for tid in ids:
		var n := 0
		if list is Array:
			for raw in list:
				if str(raw) == tid:
					n += 1
		parts.append("%s x%d" % [_log_card(tid), n] if n > 1 else _log_card(tid))
	var out := ""
	if not parts.is_empty():
		out = "→ " + ", ".join(parts)
	# Additional-cost sacrifice (Sever the Cord, Gertha) — not a target, but the
	# opponent should see which ally is being spent before responding.
	var sac: String = action.params.get("sacrifice_id", "")
	if sac != "":
		out += ("  " if out != "" else "") + "sac: " + _log_card(sac)
	return out


# The public card face for a pending action, or null (falls back to the text rect).
func _chain_action_texture(action: PendingAction) -> Texture2D:
	if not _db or not _state:
		return null
	var card_id: String = action.params.get("card_id", "")
	if card_id == "":
		card_id = action.params.get("quest_id", "")
	if card_id == "":
		card_id = action.params.get("hero_id", "")
	if card_id == "":
		return null
	var card := _state.get_card(card_id)
	if not card:
		return null
	var def := _db.get_def(card.card_def_id) as CardDef
	if not def or def.image_path == "" or def.image_path == "No match":
		return null
	var res_path := "res://" + def.image_path.replace("\\", "/")
	if not ResourceLoader.exists(res_path):
		return null
	return load(res_path) as Texture2D


func _update_cancel_btn() -> void:
	_cancel_btn.visible = StackResolver.can_retract(_state, _local_player)


# ── Resource readouts (beside each resource zone) ────────────────────────────

func _build_resource_info_labels() -> void:
	var zone_size: Vector2 = BoardRenderer.res_grid_size(0)
	# P1's two lines sit just above their zone; P2's are the mirror image, so each
	# readout always hugs its own player's resource grid.
	var line1 := Vector2(RES_ZONE_CENTRE.x - zone_size.x * 0.5,
		RES_ZONE_CENTRE.y - zone_size.y * 0.5 - 48.0)
	var line2 := line1 + Vector2(0, 22)
	var lbl_size := Vector2(zone_size.x, 18)
	_res_info_size = lbl_size
	for pid in ["p1", "p2"]:
		var l1 := _add_label("", Vector2.ZERO, 14, Color(0.85, 0.85, 0.9))
		var l2 := _add_label("", Vector2.ZERO, 14, Color(1.0, 0.3, 0.3))
		for l in [l1, l2]:
			(l as Label).size = lbl_size
			(l as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if pid == "p1":
			_res_info_base[l1] = _board_pos(line1.x, line1.y)
			_res_info_base[l2] = _board_pos(line2.x, line2.y)
		else:
			# Mirrored POSITION (a rect's mirror image has its top-left at the
			# mirror of its bottom-right).
			var m1 := _mirror(line1 + lbl_size)
			var m2 := _mirror(line2 + lbl_size)
			_res_info_base[l1] = _board_pos(m1.x, m1.y)
			_res_info_base[l2] = _board_pos(m2.x, m2.y)
		_res_info_labels[pid] = {"avail": l1, "place": l2}
	_orient_res_info_labels()


# These readouts live in WORLD space (they must travel with the resource grid
# they annotate), so the board camera turns them upside down when the p2 seat is
# the one looking. Text exists for whoever is at the screen, so counter-rotate
# it: a 180° turn about the label's own centre — expressed as rotation about the
# top-left plus a shift by its size — keeps each readout over the same rect while
# reading upright. Positions are re-derived from `_res_info_base` every time, so
# repeated calls never drift. Same idea as `BoardRenderer.view_rotation_degrees`
# for the transient overlays.
func _orient_res_info_labels(pid: String = "") -> void:
	if _res_info_base.is_empty():
		return
	var flipped := (pid if pid != "" else _local_player) == "p2"
	for lbl in _res_info_base:
		var l := lbl as Label
		var base: Vector2 = _res_info_base[lbl]
		l.rotation_degrees = 180.0 if flipped else 0.0
		l.position = (base + _res_info_size) if flipped else base


func _update_resource_info() -> void:
	if _res_info_labels.is_empty() or not _state:
		return
	for pid in _res_info_labels:
		var d: Dictionary = _res_info_labels[pid]
		var avail := _state.get_available_resources(pid)
		var total := _state.get_total_resources(pid)
		(d["avail"] as Label).text = "Available %d  /  Total %d" % [avail, total]
		var ps: PlayerState = _state.players.get(pid)
		var can_place: int = 1 if (_state.turn_player == pid \
			and ps and not ps.resource_placed_this_turn) else 0
		var pl := d["place"] as Label
		pl.text = "%d can be placed" % can_place
		# Red = a placement is still owed this turn; green = done (or not
		# this player's turn, so nothing can be placed anyway).
		pl.add_theme_color_override("font_color",
			Color(1.0, 0.3, 0.3) if can_place > 0 else Color(0.3, 1.0, 0.35))


# ── Turn-step strips (Ready · Draw · Action · End) ────────────────────────────

const TURN_STEPS := [["ready", "Ready"], ["draw", "Draw"],
	["action", "Action Phase"], ["end", "End"]]

func _make_turn_step_strip(at: Vector2) -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.scroll_active  = false
	rtl.fit_content    = true
	rtl.position       = at
	rtl.size           = Vector2(428, 26)
	rtl.mouse_filter   = Control.MOUSE_FILTER_IGNORE
	rtl.add_theme_font_size_override("normal_font_size", 13)
	rtl.add_theme_font_size_override("bold_font_size", 13)
	_hud.add_child(rtl)
	return rtl


# Both strips show all four steps; the current one is bolded ONLY on the strip
# belonging to the turn player, so exactly one step is highlighted at any time
# — on the active player's side. (During mulligan neither side bolds.)
func _update_turn_steps() -> void:
	if not _turn_steps_bottom or not _state:
		return
	var opp := "p2" if _local_player == "p1" else "p1"
	_turn_steps_bottom.text = _turn_step_bbcode(_local_player)
	_turn_steps_top.text    = _turn_step_bbcode(opp)
	_update_opponent_pass_btn(opp)


# "<pid>'s turn · Ready · Draw · Action Phase · End". The owner label is bolded
# for the whole of that player's turn; the step is bolded only on the strip of
# the player whose turn it is — so exactly one step is ever highlighted, on the
# active player's side.
func _turn_step_bbcode(pid: String) -> String:
	var mine := _state.turn_player == pid
	var parts: Array[String] = []
	parts.append(("[b][color=#ffd24a]%s's turn[/color][/b]" if mine
		else "[color=#71717e]%s's turn[/color]") % pid.to_upper())
	for step in TURN_STEPS:
		if mine and _state.phase == step[0]:
			parts.append("[b][color=#ffd24a]%s[/color][/b]" % step[1])
		else:
			parts.append("[color=#71717e]%s[/color]" % step[1])
	return "[center]%s[/center]" % "   ·   ".join(parts)


# Status light: lit while the opponent holds priority (the moment the seated
# player is waiting on them), greyed otherwise. Stays disabled — it is not a
# control the seated player may press.
func _update_opponent_pass_btn(opp: String) -> void:
	if not _opp_pass_btn:
		return
	var theirs := _state.priority_player == opp
	_opp_pass_btn.text     = "Priority" if theirs else "Waiting"
	_opp_pass_btn.modulate = Color(1.0, 0.78, 0.3) if theirs \
		else Color(0.42, 0.42, 0.48)


func _update_pass_btn() -> void:
	_update_resource_info()
	_update_turn_steps()
	var my_turn    := _state.priority_player == _local_player
	var has_plays  := _router.has_any_legal_play()
	var chain_busy := not _state.pending_actions.is_empty()
	var in_action  := _state.phase == "action"
	var in_attack  := _state.combat_attack_window
	var in_defend  := _state.combat_defend_window
	var is_p1_turn := _state.turn_player == _local_player

	_pass_btn.disabled = not my_turn or _state.pending_pet_sacrifice_player == _local_player \
		or _state.pending_equip_sacrifice_player == _local_player \
		or _state.pending_unique_sacrifice_player == _local_player \
		or _state.pending_form_sacrifice_player == _local_player \
		or (_state.pending_control_discard_player != "" \
			and _state.pending_control_discard_player != _local_player)

	if _state.pending_control_discard_player == _local_player:
		# Infernal choice: the pass button is the DECLINE option (give control).
		_pass_btn.disabled = false
		_pass_btn.text     = "Give up control  [Ctrl+Space]"
		_pass_btn.modulate = Color(1.0, 0.6, 0.0)
	elif _state.pending_pet_sacrifice_player == _local_player:
		_pass_btn.text     = "Sacrifice a pet  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif _state.pending_equip_sacrifice_player == _local_player:
		_pass_btn.text     = "Destroy equipment  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif _state.pending_unique_sacrifice_player == _local_player:
		_pass_btn.text     = "Destroy a duplicate  [Space]"
		_pass_btn.modulate = Color(0.5, 0.5, 0.5)
	elif _state.pending_form_sacrifice_player == _local_player:
		_pass_btn.text     = "Destroy a Form  [Space]"
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

	_centre_in_pass_block(_pass_btn)
	_centre_in_pass_block(_opp_pass_btn)
	_centre_in_pass_block(_cancel_btn)


# The pass button's label changes length a lot ("Pass  [Space]" vs
# "Defense window : fight on!  [Space] · auto-pass [F]"), so a fixed-width button
# either clips the long ones or leaves the short ones adrift. Size it to its own
# text and re-centre it on the block instead: the button then always reads as
# centred, whatever it currently says.
func _centre_in_pass_block(btn: Button) -> void:
	if not btn:
		return
	var w: float = maxf(PASS_BTN_MIN_W, btn.get_minimum_size().x + PASS_BTN_TEXT_PAD)
	w = minf(w, PASS_BLOCK_RECT.size.x - 16.0)
	btn.size.x     = w
	btn.position.x = PASS_BLOCK_RECT.position.x + (PASS_BLOCK_RECT.size.x - w) * 0.5


# ── Button handlers ────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _dragging_window:
		_drag_tool_window()
	_update_combat_name_inspect()


# Alt + hovering a combatant's written name in the Combat window examines that
# card. Polled rather than event-driven so that pressing Alt while the pointer
# is ALREADY resting on the name works, same as the board's own Alt+hover.
# Re-asserted every frame because BoardRenderer's Alt handler hides the
# inspector whenever no board card is under the cursor — which is exactly the
# case while the pointer is over this window.
var _combat_inspecting: bool = false

func _update_combat_name_inspect() -> void:
	if not _renderer:
		return
	var want: bool = _combat_name_hover_id != "" and Input.is_key_pressed(KEY_ALT)
	if want:
		_renderer.show_inspector_for(_combat_name_hover_id)
		_combat_inspecting = true
	elif _combat_inspecting:
		_combat_inspecting = false
		_renderer.hide_inspector()


func _input(event: InputEvent) -> void:
	# Handoff overlay owns ALL input except its own confirm button.
	if _handoff_pending:
		if event is InputEventKey and event.pressed:
			get_viewport().set_input_as_handled()
		return
	# Intercept spacebar here (via _input, not _unhandled_input) so we can gate
	# the pass through _try_pass() before InputRouter's _unhandled_input fires.
	# Godot 4 processes _unhandled_input children-first, so InputRouter would
	# consume the event before this scene's _unhandled_input ever ran.
	# Ctrl+Space is the ONLY way to wrap up / end the turn from the keyboard. Plain
	# Space never ends the turn (see the wrap-up guard below), so it can't be pressed
	# by accident. Ctrl+Space is a deliberate two-key combo → skip the confirm dialog.
	# (A modifier makes the physical event stop matching the plain-Space "ui_accept"
	# action, so it needs its own branch by keycode.)
	if event is InputEventKey and event.pressed and event.ctrl_pressed \
			and (event.keycode == KEY_SPACE or event.keycode == KEY_ENTER):
		if (_x_dialog and _x_dialog.visible) \
				or (_gy_dialog and _gy_dialog.visible and not _gy_peek_active):
			get_viewport().set_input_as_handled()
			return
		# Infernal: Ctrl+Space gives up control (declines the discard). Gated behind
		# Ctrl so a stray plain-Space can't hand the card to the opponent by mistake.
		# Handled on its own (NOT via the wrap-up burst) so giving up control doesn't
		# also try to end the turn — it's a start-of-turn choice, the turn continues.
		if _state.pending_control_discard_player == _local_player:
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
		if _state.pending_control_discard_player == _local_player:
			_set_status("Press Ctrl+Space to give up control, or click a card to discard")
			get_viewport().set_input_as_handled()
			return
		# Protect point: Space mirrors the "Don't protect" button (skip protecting),
		# matching the pass button's behavior everywhere else in the window flow.
		if _in_protect_mode:
			_resolve_protection("")
			get_viewport().set_input_as_handled()
			return
		_try_pass()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		# Escape: close the X dialog (cancels the whole power use).
		if _x_dialog and _x_dialog.visible:
			_x_dialog.visible = false
			_set_board_block(false)
			_router.cancel_targeting()
			_set_status("")
			get_viewport().set_input_as_handled()
			return
		# Escape: cancel the quest ally-exhaust cost picker (nothing was paid).
		if _in_ally_exhaust_mode:
			_cancel_ally_exhaust()
			get_viewport().set_input_as_handled()
			return
		# Escape: close/cancel the graveyard browser.
		if _gy_dialog and _gy_dialog.visible and not _gy_peek_active:
			_on_gy_cancel_pressed()
			get_viewport().set_input_as_handled()
			return
		# Otherwise Escape is the Controls panel — one key, one function. It is
		# deliberately swallowed here so InputRouter never sees it: Esc used to
		# also cancel targeting and retract the last chain entry, and those now
		# have exactly one route each (right-click / the Retract button).
		_set_window_open(_controls_window, not _controls_window.visible)
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
	if not _state or _handoff_pending or _type_of(_local_player) != "human":
		return
	# Discard peek: the router temporarily acts for the OFF-SCREEN discarding
	# player — the seated player's Space must not pass (or discard) for them.
	if _in_choice_peek:
		return
	# The quest ally-exhaust picker is modal: answer it (Confirm/Cancel) first.
	if _in_ally_exhaust_mode:
		return
	# Infernal choice pending for the human: Space/pass = decline the discard
	# and give the opponent control of the source.
	if _state.pending_control_discard_player == _local_player:
		_router.decline_control_discard()
		_refresh_ui()
		_schedule_next_turn()
		return
	if _state.priority_player != _local_player:
		return
	var needs_confirm: bool = (
		_state.turn_player == _local_player
		and _state.phase == "action"
		and _state.pending_actions.is_empty()
		and not _played_this_action_phase.get(_local_player, false)
	)
	if needs_confirm and not skip_confirm:
		_end_turn_dialog.popup_centered()
	else:
		_stop_for_end_window = false   # the held wrap-up window is used up by a pass
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


# Human wording for a form_broken payload. The reason is engine-generated:
# "weapon_strike", "non_<tag>_ability" (the Feral forms) or "<tag>_ability"
# (Shadowform's inverted break) — derive the wording rather than hardcoding
# one condition.
func _form_break_reason(reason_raw) -> String:
	var reason := str(reason_raw)
	if reason == "weapon_strike":
		return "a weapon strike"
	var why := reason.trim_suffix("_ability")
	if why.begins_with("non_"):
		why = "non-" + why.trim_prefix("non_").capitalize()
	else:
		why = why.capitalize()
	return "a %s ability" % why


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
		"combat_cancelled":
			var can_att: String = _log_card(event.payload.get("attacker_id", ""))
			var can_def: String = _log_card(event.payload.get("defender_id", ""))
			_log_entry("[color=#a66][b]-- combat cancelled --[/b] (%s ⚔ %s, no damage)[/color]"
				% [can_att, can_def])
		"attacker_removed_from_combat":
			var rem_att: String = _log_card(event.payload.get("attacker_id", ""))
			var rem_src: String = _log_card(event.payload.get("source_id", ""))
			_log_entry("[color=#a66]%s removed from combat by %s[/color]" % [rem_att, rem_src])
		"link_interrupted":
			# Rule 711 (Escape Artist): the link left the chain doing nothing.
			var int_card: String = _log_card(event.payload.get("card_id", ""))
			var int_src:  String = _log_card(event.payload.get("source_id", ""))
			_log_entry("[color=#a66]%s [b]interrupted[/b] by %s — it does nothing[/color]"
				% [int_card, int_src])
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
		"deck_empty":
			_log_entry("[color=#a66]%s's deck is empty[/color]"
				% _log_player(event.payload.get("player", "")))
		"weapon_struck":
			_log_entry("[color=#fc8]%s strikes with [b]%s[/b][/color]"
				% [_log_player(event.payload.get("player", "")),
				   _log_card(event.payload.get("weapon_id", ""))])
		"readied_on_strike":
			_log_entry("[color=#9cf]%s readies %s and their hero[/color]"
				% [_log_player(event.payload.get("player", "")),
				   _log_card(event.payload.get("weapon_id", ""))])
		"readied_on_attack":
			_log_entry("[color=#9cf]%s readies %s[/color]"
				% [_log_player(event.payload.get("player", "")),
				   _log_card(event.payload.get("card_id", ""))])
		"attack_exhaust_resolved":
			_log_entry("[color=#9cf]%s exhausts %s[/color]"
				% [_log_player(event.payload.get("player", "")),
				   _log_card(event.payload.get("target_id", ""))])
		"whelp_bounce_resolved":
			_log_entry("[color=#9cf]%s pays to return %s to hand[/color]"
				% [_log_player(event.payload.get("player", "")),
				   _log_card(event.payload.get("ally_id", ""))])
		"form_return_resolved":
			if event.payload.get("paid", false):
				_log_entry("[color=#9cf]%s pays to return %s to hand[/color]"
					% [_log_player(event.payload.get("player", "")),
					   _log_card(event.payload.get("card_id", ""))])
		"form_broken":
			# card_destroyed logs the destruction itself; this adds the WHY.
			_log_entry("[color=#a66](%s broke %s's Form)[/color]"
				% [_form_break_reason(event.payload.get("reason", "")),
				   _log_player(event.payload.get("player", ""))])
		"ferocity_granted":
			_log_entry("[color=#af8]%s has ferocity this turn[/color]"
				% _log_card(event.payload.get("card_id", "")))
		"quest_turned_face_down":
			_log_entry("[color=#a66]%s's %s is turned face down (no reward)[/color]"
				% [_log_player(event.payload.get("player", "")),
				   _log_card(event.payload.get("quest_id", ""))])
		"hand_returned_to_deck":
			_log_entry("[color=#888]%s puts their hand (%d cards) on the bottom of their deck[/color]"
				% [_log_player(event.payload.get("player", "")),
				   event.payload.get("count", 0)])
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
			# to_top (It's a Secret to Everybody) is a private "look at" - the log
			# is shared, so never name the card that was kept on top.
			if bool(event.payload.get("to_top", false)):
				_log_entry("[color=#af8]%s keeps a card on top of their deck (rest to bottom)[/color]" % rp)
			else:
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
		"player_decked":
			var dp: String = _log_player(event.payload.get("player", ""))
			_log_entry("[color=#f66]%s is decked — drew from an empty deck[/color]" % dp)
		"game_over":
			var head: String = "DRAW" if bool(event.payload.get("draw", false)) \
					else "%s WINS" % _log_player(event.payload.get("winner", ""))
			_log_entry("\n[color=#d4af37][b]═══ %s ═══[/b][/color]\n%s"
					% [head, GameEvent.game_over_explanation(event.payload)])


# ── AI ─────────────────────────────────────────────────────────────────────────

func _do_ai_turn() -> void:
	if _game_over or _handoff_pending:
		return
	if _state.in_protect_point or _in_protect_mode:
		return
	var pid := _state.priority_player
	var ai: Object = _p1_ai if pid == "p1" else _p2_ai
	var events: Array[GameEvent]
	if ai == null:
		# Hotseat: the OFF-SCREEN human's priority windows auto-pass (their hand
		# is hidden; protect/strike points are handled separately and still stop)
		# — unless their stance is Ambush and they have a legal instant response,
		# in which case the window stops for them (yellow highlights + Skip).
		if not (_hotseat and pid != _local_player):
			return   # local human's turn — wait for input
		if _stance.get(pid, "ambush") == "ambush" and _offscreen_has_play(pid):
			_enter_ambush_mode(pid)
			return
		events = StackResolver.pass_priority(_state, _db)
	else:
		var action: PendingAction = ai.decide_action(_state, _db, pid)
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
	_stats.record_event(event)
	match event.event_type:
		"turn_changed":
			# End-of-turn heal: force a reconcile (which also ends any lingering pulse
			# cue) so any card left crooked/un-exhausted after a power or attack
			# animation snaps to its true orientation.
			if _renderer and _state:
				_renderer.reconcile_from_state(_state, true)
			# Hotseat: the turn passed to the OTHER human — hide both hands and
			# block everything until they confirm they have the screen.
			var next_tp: String = event.payload.get("player", "")
			if _hotseat and not _game_over and next_tp != _local_player \
					and _type_of(next_tp) == "human":
				_begin_handoff(next_tp, "your turn", func() -> void:
					_refresh_ui()
					_schedule_next_turn()
					_maybe_turbo_pass())
		"priority_passed":
			if event.payload.get("player", "") != _local_player:
				_blink_pass_btn()
			_refresh_ui()
			var _in_chain := not _state.pending_actions.is_empty()
			if _state.combat_attack_window or _state.combat_defend_window or _in_chain:
				_drain_passes()
			else:
				_schedule_next_turn()
				_maybe_turbo_pass()
		"action_proposed":
			_played_this_action_phase[event.payload.get("player", "")] = true
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
			# A token is minted mid-game and has never been in a zone, so no node
			# exists for it — spawn one as it enters the ally_row (same pattern as
			# the drawn-card branch below).
			if to_zone.ends_with("_ally_row") and not _renderer.has_card_node(moved_id):
				var tok := _state.get_card(moved_id)
				if tok:
					var tok_p1 := tok.controller == "p1"
					var tok_anchor := _renderer.zone_anchors.get(to_zone) as Node2D
					var tok_pos := tok_anchor.global_position if tok_anchor else Vector2.ZERO
					var tok_color := Color(0.25, 0.45, 0.75) if tok_p1 else Color(0.5, 0.25, 0.25)
					_spawn_card_node(moved_id, tok_pos, tok_color)
					_renderer.relayout_zone(to_zone)
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
			if event.payload.get("new") == "action":
				_played_this_action_phase[event.payload.get("player", "")] = false
				# Same self-heal as turn_changed: force a reconcile, ending any
				# lingering pulse cue, so the active player starts their action
				# phase with every card at its true ready/exhausted angle.
				if _renderer and _state:
					_renderer.reconcile_from_state(_state, true)
			if event.payload.get("new", "") != "end":
				_stop_for_end_window = false   # one-shot hold expires with the end phase
			# Hotseat: hand the screen over at the START of the outgoing player's
			# end phase — the incoming player uses the wrap-up window to play
			# instants with leftover resources, then sees their own ready/draw.
			# Skipped when the outgoing player must still discard to hand size
			# (that choice needs THEIR hand); then the turn_changed handoff below
			# covers the switch instead.
			if event.payload.get("new", "") == "end" and _hotseat and not _game_over:
				var outgoing := _state.turn_player
				var incoming := "p2" if outgoing == "p1" else "p1"
				if outgoing == _local_player and _type_of(incoming) == "human":
					var ps_out := _state.players.get(outgoing) as PlayerState
					var max_hand: int = ps_out.max_hand_size if ps_out else 7
					if _state.cards_in_zone(outgoing + "_hand").size() <= max_hand:
						_begin_handoff(incoming, "opponent is wrapping up", func() -> void:
							_stop_for_end_window = true
							_refresh_ui()
							_schedule_next_turn())
			_refresh_ui()
			_maybe_turbo_pass()
		"priority_window_closed":
			# Defer so this event finishes dispatching before TurnManager fires new ones.
			call_deferred("_on_window_closed")
		"combat_cancelled":
			_show_combat_cancelled_notice(event.payload)
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
		"ready_on_attack_opened":
			_window_generation += 1
			_handle_ready_point(event.payload)
		"ready_on_strike_opened":
			_window_generation += 1
			_handle_strike_ready_point(event.payload)
		"readied_on_strike":
			_refresh_ui()   # reported by the game log (_log_event)
		"attack_exhaust_opened":
			_window_generation += 1
			_handle_attack_exhaust(event.payload)
		"attack_exhaust_resolved":
			_refresh_ui()
		"whelp_bounce_opened":
			_window_generation += 1
			_handle_whelp_bounce(event.payload)
		"prevention_opened":
			_window_generation += 1
			_handle_prevention(event.payload)
		"whelp_bounce_resolved":
			_refresh_ui()
		"readied_on_attack":
			_refresh_ui()
		"weapon_struck":
			_refresh_ui()
		"discard_choice_opened":
			_handle_discard_choice(event.payload)
		"pet_sacrifice_required":
			_handle_pet_sacrifice(event.payload)
		"control_discard_choice_opened":
			_handle_control_discard(event.payload)
		"equipment_sacrifice_required":
			_handle_equipment_sacrifice(event.payload)
		"unique_sacrifice_required":
			_handle_unique_sacrifice(event.payload)
		"form_sacrifice_required":
			_handle_form_sacrifice(event.payload)
		"form_return_opened":
			_window_generation += 1
			_handle_form_return(event.payload)
		"form_return_resolved":
			_refresh_ui()
		"form_broken":
			_refresh_ui()
		"reveal_pick_opened":
			_handle_reveal_pick(event.payload)
		"quest_choice_opened":
			_handle_quest_choice(event.payload)
		"quest_ferocity_target_required":
			_handle_quest_ferocity_target(event.payload)
		"plague_destroy_required":
			_handle_plague_destroy(event.payload)
		"quest_facedown_required":
			_handle_quest_facedown(event.payload)
		"ferocity_granted":
			_refresh_ui()
		"quest_turned_face_down":
			_refresh_ui()
		"hand_returned_to_deck":
			_refresh_ui()
		"enter_play_target_required":
			_handle_enter_play_target(event.payload)
		"trigger_target_required":
			_handle_trigger_target(event.payload)
		"death_target_required":
			_handle_death_target(event.payload)
		"recomb_choice_opened":
			_handle_recomb_choice(event.payload)
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
						_state.get_atk_if_attacking(card.instance_id, _db),
						_state.get_atk_raw(card.instance_id, _db))
				cn.update_hp(_state.get_max_hp(card.instance_id, _db), def.printed_health)
				# Berserk counters (Berserking) — same badge treatment as a
				# buffed ATK value, in the ATK badge's corner (the card has
				# no printed ATK of its own).
				cn.update_counter(int(card.counters.get("berserk", 0)))


func _on_window_closed() -> void:
	var events := TurnManager.advance_phase(_state, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()


func _handle_mulligan_started(payload: Dictionary) -> void:
	var first: String = payload.get("first_player", "")
	_p1_has_mulliganed = false
	_mulligan_first    = first

	var player_order: Array = payload.get("player_order", [])
	if player_order.is_empty():
		for pid in _state.players:
			player_order.append(pid)

	# Queue every undecided human (turn order); AI players commit immediately.
	_mulligan_queue.clear()
	for pid in player_order:
		if _state.mulligan_decided.get(pid, false):
			continue   # already committed (e.g. chain reaction)
		if _type_of(pid) == "human":
			_mulligan_queue.append(pid)
		else:
			var pid_ai: Object = _p1_ai if pid == "p1" else _p2_ai
			var wants: bool = pid_ai.wants_mulligan(_state, _db, pid) if pid_ai else false
			var events := TurnManager.commit_mulligan(_state, pid, wants, _db)
			_emit_mulligan_events(events)

	if _mulligan_queue.is_empty():
		# All-AI table: nobody left to decide, start the game.
		var start_events := TurnManager.finish_mulligan_if_ready(_state, _db)
		if not start_events.is_empty():
			EventBus.emit_events(start_events)
			_refresh_ui()
			_schedule_next_turn()
			_maybe_turbo_pass()
	elif _hotseat:
		_advance_mulligan_queue()
	else:
		# Single human: show the panel directly, no handoff needed.
		_mulligan_current = _mulligan_queue.pop_front()
		_show_mulligan_panel()


# Hotseat: hand the screen to the next undecided human, then show their panel.
func _advance_mulligan_queue() -> void:
	if _mulligan_queue.is_empty():
		return
	_mulligan_current = _mulligan_queue.pop_front()
	_begin_handoff(_mulligan_current, "mulligan decision", _show_mulligan_panel)


func _show_mulligan_panel() -> void:
	_pass_btn.visible          = false
	_mulligan_panel.visible    = true
	_mulligan_awaiting_ack     = false
	_mulligan_btn.visible      = true
	_mulligan_btn.disabled     = false
	_mulligan_ready_btn.text   = "Ready  (keep hand)"
	_mulligan_order_label.text = \
		"You go first!" if _mulligan_first == _mulligan_current else "Opponent goes first."
	_refresh_ui()


func _commit_mulligan(wants: bool) -> void:
	var events := TurnManager.commit_mulligan(_state, _mulligan_current, wants, _db)
	_emit_mulligan_events(events)
	_refresh_ui()
	if wants:
		# The redraw is already on its way (the deck→hand half fires after a short
		# delay). Keep the panel up with a single "Ready" so this player actually
		# sees — and hears — their new hand before the seat changes hands.
		_p1_has_mulliganed       = true
		_mulligan_awaiting_ack   = true
		_mulligan_btn.visible    = false
		_mulligan_ready_btn.text = "Ready  (continue)"
		return
	_finish_mulligan_decision()


# This player is done: hand over to the next undecided human, or — if everyone
# has decided — end the mulligan phase and start turn 1.
func _finish_mulligan_decision() -> void:
	_mulligan_awaiting_ack  = false
	_mulligan_panel.visible = false
	if _hotseat and not _mulligan_queue.is_empty():
		# The next human's decision needs its own handoff. The panel is already
		# hidden so it isn't visible behind the overlay.
		_advance_mulligan_queue()
		return
	if not _mulligan_queue.is_empty():
		_mulligan_current = _mulligan_queue.pop_front()
		_show_mulligan_panel()
		return
	var events := TurnManager.finish_mulligan_if_ready(_state, _db)
	if events.is_empty():
		_mulligan_panel.visible = true   # still waiting on someone else
		return
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


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
	# Turn 1 is started separately (finish_mulligan_if_ready), so this only has to
	# land the redrawn hand.
	get_tree().create_timer(0.45).timeout.connect(func() -> void:
		EventBus.emit_events(phase2)
		_refresh_ui())


func _on_card_right_clicked(instance_id: String) -> void:
	# Right-click during targeting always cancels — no context menu mid-targeting.
	if _router and _router._targeting_source != "":
		_router.cancel_targeting()
		return
	# Allowlisted cards during a choice point (armor / weapon / protector) are
	# clickable ONLY as that choice — no context menu on them either.
	if CardNode.input_blocked:
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


func _on_card_mute_changed(instance_id: String, muted: bool) -> void:
	var cn := _renderer.card_nodes.get(instance_id) as CardNode
	if cn:
		cn.set_muted(muted)


# ── Targeting ──────────────────────────────────────────────────────────────────

func _on_discard_mode_started(count: int) -> void:
	if _in_choice_peek:
		_set_status("🃏 %s must discard %d card(s) — hover a red card to peek, click to discard"
				% [_choice_peek_player.to_upper(), count])
	else:
		_set_status("Choose %d card(s) to discard — click a highlighted hand card" % count)
	_refresh_ui()


func _on_discard_mode_ended() -> void:
	_exit_choice_peek_mode()
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


func _on_unique_sacrifice_mode_ended() -> void:
	_set_status("")
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


func _on_form_sacrifice_mode_ended() -> void:
	_set_status("")
	_refresh_ui()
	_schedule_next_turn()
	_maybe_turbo_pass()


# Form (1) tag-count uniqueness (rule 414.3b): destroy Forms until one remains.
func _handle_form_sacrifice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var candidates: Array = payload.get("candidates", [])
	var new_id: String = payload.get("new_card_id", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	if player_type != "human":
		# AI: playing a new Form IS the shapeshift — keep the newly played one,
		# destroy the older Form(s).
		var keep_id: String = new_id if new_id != "" else \
				(candidates[0] if not candidates.is_empty() else "")
		for cid: String in candidates:
			if cid == keep_id:
				continue
			var events := StackResolver.choose_form_sacrifice(_state, cid, _db)
			if not events.is_empty():
				EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: highlight the in-play Forms; click one to destroy it.
		_router.start_form_sacrifice_mode(candidates)
		_set_status("Form (1) — click a highlighted Form to destroy it")
		_refresh_ui()


func _handle_unique_sacrifice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var candidates: Array = payload.get("candidates", [])
	var player_type := _p1_type if player == "p1" else _p2_type
	if player_type != "human":
		# AI: the duplicates are the same card by name — keep the first, destroy
		# the rest until only one same-named Unique copy remains.
		var keep_id: String = candidates[0] if not candidates.is_empty() else ""
		for cid: String in candidates:
			if cid == keep_id:
				continue
			var events := StackResolver.choose_unique_sacrifice(_state, cid, _db)
			if not events.is_empty():
				EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: highlight the same-named Unique duplicates; click one to destroy it.
		_router.start_unique_sacrifice_mode(candidates)
		_set_status("Unique — click a highlighted duplicate to destroy it")
		_refresh_ui()


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
	# A discard is PRIVATE — an off-screen human's hand must stay hidden while
	# they pick (the "peek" branch of _route_choice does that re-pointing).
	if _route_choice(player, "private") == "ai":
		# AI: the AI instance picks each discard (BaseAI: lowest-cost non-quest;
		# GenericAI: least valuable via sort_valuable_cards).
		var ai: Object = _p1_ai if player == "p1" else _p2_ai
		for _i in count:
			var pick_id := ""
			if ai is BaseAI:
				pick_id = (ai as BaseAI).choose_discard_card(_state, _db, player)
			else:
				var pick := _pick_ai_discard(player)
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
		# Human (seated, or off-screen with the router already re-pointed at them
		# by _route_choice): discard mode — red highlights + click to resolve.
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
# Giants; The Princess Trapped). The top cards were revealed; the card kept goes
# to `player`'s hand, the rest to the bottom of `player`'s deck. The DECIDER is
# `chooser` — normally `player`, but the opponent for The Princess Trapped, which
# also flips the pick quality (they choose the card you'd least want).
func _handle_reveal_pick(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var chooser: String = payload.get("chooser", player)
	var selectable: Array = payload.get("selectable", [])
	var revealed: Array = payload.get("revealed", [])
	var card_type: String = payload.get("card_type", "")
	var hostile := chooser != player
	# The picked card goes back on TOP of the deck instead of into hand.
	var to_top: bool = payload.get("to_top", false)
	# A public "reveal" is shown to BOTH players; a private "look at" (It's a
	# Secret to Everybody) is the chooser's alone. In hotseat both players share
	# a screen so the difference is nominal, but it is what a two-device build
	# keys off to send the opponent nothing.
	var visibility := "private" if bool(payload.get("private", false)) else "public"
	if _route_choice(chooser, visibility) == "ai":
		# AI keeps the most valuable revealed card of the required type — or, when
		# choosing for the opponent, hands them the LEAST valuable one.
		var pick_id := _pick_ai_reveal(selectable, hostile)
		var events := StackResolver.choose_reveal_pick(_state, pick_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: reuse the browser modal. Show ALL revealed cards (like a graveyard
		# pick); non-matching cards render red and can't be selected. A matching
		# card MUST be chosen before OK (min 1); if none match, OK sends every
		# revealed card to the bottom of the deck (min 0, no card to pick).
		_gy_selectable.clear()
		for cid: String in selectable:
			_gy_selectable[cid] = true
		_gy_filter_active = true
		_gy_reveal_card_type = card_type
		var has_pick := not selectable.is_empty()
		var type_label := "" if card_type == "Any" else card_type + " "
		var title := "Revealed top %d — choose a %scard to keep (rest go to bottom of deck)" \
				% [revealed.size(), type_label]
		if to_top:
			title = "Looked at top %d — choose one to put back on top (rest go to bottom)" \
					% revealed.size()
		elif hostile:
			title = "%s revealed top %d — %s chooses which card %s keeps (rest to bottom of deck)" \
					% [player.to_upper(), revealed.size(), chooser.to_upper(), player.to_upper()]
		elif not has_pick:
			title = "Revealed top %d — no %scard to keep (all go to bottom of deck)" \
					% [revealed.size(), type_label]
		_open_gy_dialog(revealed, false, title, 1 if has_pick else 0, 1)
		_gy_reveal_mode = true
		_gy_cancel_btn.visible = false
		_gy_confirm_btn.text = "OK (C)"
		if hostile:
			_set_status("🎯 %s: choose a card to put into %s's hand"
					% [chooser.to_upper(), player.to_upper()])
		elif to_top:
			_set_status("Choose a card to put back on top of your deck")
		elif has_pick:
			_set_status("Choose a %scard to put into your hand" % type_label)
		else:
			_set_status("No %scard revealed — click OK" % type_label)
		_refresh_ui()


# AI reveal-pick: keep the highest-cost card, tie-broken by total stats. When
# `hostile` (the AI is choosing which card the OPPONENT keeps — The Princess
# Trapped), the ranking inverts: hand them the worst card revealed.
func _pick_ai_reveal(candidates: Array, hostile: bool = false) -> String:
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
		if hostile:
			score = -score
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
	# Ghank's optional destroy trigger ("you may destroy target exhausted ally
	# with damage on it") — separate path: AI only destroys OPPOSING allies
	# (declines otherwise), humans may Esc to decline.
	if _state.pending_enter_play_effect.get("effect", "") == "destroy_exhausted_damaged_ally":
		if ctrl_type != "human":
			var opp := "p2" if ctrl == "p1" else "p1"
			var best_id := ""
			var best_cost := -1
			for tid in StackResolver.get_enter_play_destroy_targets(_state, _db):
				var t := _state.get_card(tid)
				if not t or t.controller != opp:
					continue
				var tdef := _db.get_def(t.card_def_id) as CardDef
				var tcost: int = tdef.cost if tdef else 0
				if tcost > best_cost:
					best_cost = tcost
					best_id = tid
			if best_id == "":
				EventBus.emit_events(StackResolver.decline_enter_play_effect(_state))
			else:
				var dact := PendingAction.make("choose_enter_play_target", ctrl,
					{"source_card_id": card_id, "target_id": best_id})
				EventBus.emit_events(StackResolver.submit_action(_state, dact, _db))
				EventBus.emit_events(StackResolver.pass_priority(_state, _db))
			_refresh_ui()
			_schedule_next_turn()
		else:
			_router.start_enter_play_targeting(card_id, dmg_type, amount)
			_refresh_ui()
		return
	# Hur Shieldsmasher / Zygore Bladebreaker: optional destroy-equipment
	# trigger. AI only destroys OPPOSING equipment (declines otherwise);
	# humans may Esc to decline.
	var enter_eff: String = _state.pending_enter_play_effect.get("effect", "")
	# Karkas Deathhowl's optional bounce ("you may put target ally into its
	# owner's hand") — AI only bounces OPPOSING allies (declines otherwise; the
	# printed text lets a human bounce their own, Karkas included), preferring
	# the most expensive one. Humans may Esc to decline.
	if enter_eff == "return_to_hand_ally":
		if ctrl_type != "human":
			var opp3 := "p2" if ctrl == "p1" else "p1"
			var best_id3 := ""
			var best_cost3 := -1
			for tid in StackResolver.get_death_target_targets(_state, _db):
				var t3 := _state.get_card(tid)
				if not t3 or t3.controller != opp3:
					continue
				var tdef3 := _db.get_def(t3.card_def_id) as CardDef
				var tcost3: int = tdef3.cost if tdef3 else 0
				if tcost3 > best_cost3:
					best_cost3 = tcost3
					best_id3 = tid
			if best_id3 == "":
				EventBus.emit_events(StackResolver.decline_enter_play_effect(_state))
			else:
				var dact3 := PendingAction.make("choose_enter_play_target", ctrl,
					{"source_card_id": card_id, "target_id": best_id3})
				EventBus.emit_events(StackResolver.submit_action(_state, dact3, _db))
				EventBus.emit_events(StackResolver.pass_priority(_state, _db))
			_refresh_ui()
			_schedule_next_turn()
		else:
			_router.start_enter_play_targeting(card_id, dmg_type, amount)
			_refresh_ui()
		return
	# Bhenn Checks-the-Sky's optional exhaust ("you may exhaust target ally").
	# AI: the attacking ally of a combat proposal still on the chain first (that
	# interrupt is why she was flashed in — exhausting it fizzles the proposal
	# at the 601.3 recheck), otherwise the opponent's most expensive READY ally.
	# Never our own side; declines when nothing is worth exhausting. Humans may
	# Esc to decline (the printed text lets them exhaust their own, Bhenn included).
	if enter_eff == "exhaust_ally":
		if ctrl_type != "human":
			var opp4 := "p2" if ctrl == "p1" else "p1"
			var cands4: Array[String] = StackResolver.get_death_target_targets(_state, _db)
			var best_id4 := ""
			var best_cost4 := -1
			var attacker4 := ""
			for a in _state.pending_actions:
				var pa := a as PendingAction
				if pa.action_type == "propose_combat" and pa.source_player == opp4:
					attacker4 = pa.params.get("attacker_id", "")
			if attacker4 != "" and attacker4 in cands4:
				best_id4 = attacker4
			else:
				for tid in cands4:
					var t4 := _state.get_card(tid)
					if not t4 or t4.controller != opp4 or t4.is_exhausted:
						continue
					var tdef4 := _db.get_def(t4.card_def_id) as CardDef
					var tcost4: int = tdef4.cost if tdef4 else 0
					if tcost4 > best_cost4:
						best_cost4 = tcost4
						best_id4 = tid
			if best_id4 == "":
				EventBus.emit_events(StackResolver.decline_enter_play_effect(_state))
			else:
				var dact4 := PendingAction.make("choose_enter_play_target", ctrl,
					{"source_card_id": card_id, "target_id": best_id4})
				EventBus.emit_events(StackResolver.submit_action(_state, dact4, _db))
				EventBus.emit_events(StackResolver.pass_priority(_state, _db))
			_refresh_ui()
			_schedule_next_turn()
		else:
			_router.start_enter_play_targeting(card_id, dmg_type, amount)
			_refresh_ui()
		return
	# Sister Rot rides the same branch with the ability pool instead.
	if enter_eff == "destroy_armor" or enter_eff == "destroy_armor_or_weapon" \
			or enter_eff == "destroy_ability":
		if ctrl_type != "human":
			var opp2 := "p2" if ctrl == "p1" else "p1"
			var best_id2 := ""
			var best_cost2 := -1
			var include_weapons := enter_eff == "destroy_armor_or_weapon"
			var cands2: Array[String] = \
				StackResolver.get_enter_play_ability_targets(_state, _db) \
				if enter_eff == "destroy_ability" \
				else StackResolver.get_enter_play_equipment_targets(_state, _db, include_weapons)
			for tid in cands2:
				var t2 := _state.get_card(tid)
				if not t2 or t2.controller != opp2:
					continue
				var tdef2 := _db.get_def(t2.card_def_id) as CardDef
				var tcost2: int = tdef2.cost if tdef2 else 0
				if tcost2 > best_cost2:
					best_cost2 = tcost2
					best_id2 = tid
			if best_id2 == "":
				EventBus.emit_events(StackResolver.decline_enter_play_effect(_state))
			else:
				var dact2 := PendingAction.make("choose_enter_play_target", ctrl,
					{"source_card_id": card_id, "target_id": best_id2})
				EventBus.emit_events(StackResolver.submit_action(_state, dact2, _db))
				EventBus.emit_events(StackResolver.pass_priority(_state, _db))
			_refresh_ui()
			_schedule_next_turn()
		else:
			_router.start_enter_play_targeting(card_id, dmg_type, amount)
			_refresh_ui()
		return
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
func _handle_trigger_target(payload: Dictionary) -> void:
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
		var legal := StackResolver.get_turn_start_trigger_targets(_state, _db)
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
		var events := StackResolver.choose_trigger_target(_state, target_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: enter targeting mode to pick the target hero or ally.
		_router.start_trigger_targeting(card_id, dmg_type, amount)
		_refresh_ui()


# A human finished picking a Totem trigger's target (or the queue advanced). Resume
# driving the turn; if another totem trigger is now pending, its handler already
# restarted targeting and _schedule_next_turn no-ops on the pending guard.
func _on_trigger_target_resolved() -> void:
	_refresh_ui()
	_schedule_next_turn()


# Boneshanks: "When [this] is destroyed, destroy target ally." Mandatory targeted
# death trigger resolved by the destroyed card's controller. AI auto-picks; a
# HUMAN controller (either seat) is always PROMPTED to choose — even in hotseat,
# since the choice is board-public (no hidden information). The choice is
# resolved on the shared screen with the router acting for the controller.
# Operation Recombobulation: an opposing non-token ally died while the quest
# reward is active, so the completer MAY put an ally card from his own graveyard
# into his hand. Optional and board-public (a graveyard is open information), so
# the off-seat hotseat player is routed with "public" — no hand hiding, no
# handoff, just the browser and their click.
func _handle_recomb_choice(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var card_ids: Array = payload.get("card_ids", [])
	if _route_choice(player, "public") == "ai":
		var pick := ""
		var ai_obj: Object = _p1_ai if player == "p1" else _p2_ai
		if ai_obj is BaseAI:
			pick = (ai_obj as BaseAI).choose_recombobulation(_state, _db, player)
		var events := StackResolver.choose_recombobulation(_state, pick, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
		return
	_open_gy_dialog(card_ids, false,
			"Operation Recombobulation — put an ally card from your graveyard into your hand",
			0, 1)
	_gy_recomb_mode = true
	_gy_confirm_btn.text = "Take it (C)"
	_gy_cancel_btn.text = "Decline (Esc)"
	_set_status("An opposing ally was destroyed — take an ally card back, or decline")
	_refresh_ui()


func _handle_death_target(payload: Dictionary) -> void:
	var card_id: String = payload.get("card_id", "")
	var ctrl: String    = payload.get("player", "")
	var ctrl_type := _p1_type if ctrl == "p1" else _p2_type
	if ctrl_type != "human":
		var ai_obj: Object = _p1_ai if ctrl == "p1" else _p2_ai
		var target_id := ""
		if ai_obj is BaseAI:
			target_id = (ai_obj as BaseAI).choose_death_target(_state, _db, ctrl)
		else:
			# Non-BaseAI fallback: destroy the first legal ally.
			var legal := StackResolver.get_death_target_targets(_state, _db)
			target_id = legal[0] if not legal.is_empty() else ""
		var events := StackResolver.choose_death_target(_state, target_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: enter targeting mode to pick the ally to destroy. In hotseat, point
		# the router at the controller so their pick resolves even off-seat (the
		# board is public, so no hand-hiding handoff is needed).
		if _hotseat and ctrl != _local_player:
			_router.setup(_state, _db, ctrl)
		_router.start_death_target_targeting(card_id)
		_refresh_ui()


# A human finished picking a Boneshanks death-trigger target (or the queue
# advanced). Restore the router to the seated player, then resume driving; if
# another death trigger is now pending, its handler restarts targeting.
func _on_death_target_resolved() -> void:
	if _hotseat and _router.local_player != _local_player:
		_router.setup(_state, _db, _local_player)
	_refresh_ui()
	_schedule_next_turn()


# ── Quest reward choice ("Choose one … you may choose both") ───────────────────
# Hidden Enemies / A New Plague / Thwarting Kolkar Aggression / Crown of the
# Earth. The completer picks one reward mode — or both, in an order of their
# choosing, when the hero-race condition is met. Two-step popup for humans:
# first "one or both", then (if Both) which resolves first.

func _quest_mode_label(mode: String) -> String:
	match mode.split(":")[0]:
		"draw":
			var parts := mode.split(":")
			var n := int(parts[1]) if parts.size() > 1 else 1
			return "Draw a card" if n == 1 else "Draw %d cards" % n
		"ally_ferocity_this_turn":
			return "Target ally has ferocity this turn"
		"each_player_destroys_ally":
			return "Each player destroys an ally in his party"
		"opponent_quest_face_down":
			return "Opponent turns one of his quests face down"
		"hand_to_deck_draw":
			return "Put your hand on the bottom of your deck, draw that many"
	return mode


func _handle_quest_choice(payload: Dictionary) -> void:
	var player: String   = payload.get("player", "")
	var quest_id: String = payload.get("quest_id", "")
	var modes: Array     = payload.get("modes", [])
	var can_both: bool   = payload.get("can_both", false)
	# Board-public choice — in hotseat only the input is re-pointed ("peek").
	if _route_choice(player, "public") == "ai":
		var ai_obj: Object = _p1_ai if player == "p1" else _p2_ai
		var chosen: Array = []
		if ai_obj is BaseAI:
			chosen = (ai_obj as BaseAI).choose_quest_modes(_state, _db, player)
		else:
			# Non-BaseAI fallback: first available mode.
			for entry in modes:
				if entry.get("available", false):
					chosen = [entry.get("mode", "")]
					break
		var events := StackResolver.choose_quest_modes(_state, chosen, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_show_quest_choice_popup(quest_id, modes, can_both)


func _show_quest_choice_popup(quest_id: String, modes: Array, can_both: bool) -> void:
	_clear_quest_choice_nodes()
	_in_quest_choice_mode = true
	_ai_timer.stop()
	var card := _state.get_card(quest_id)
	var def: CardDef = _db.get_def(card.card_def_id) if card and _db else null
	var qname := def.card_name if def else "Quest reward"
	var avail: Array = []
	for entry in modes:
		if entry.get("available", false):
			avail.append(entry.get("mode", ""))
	var header := "%s — choose one%s:" % [qname, " (or both)" if can_both else ""]
	var buttons: Array = []
	for m in avail:
		var captured_m: String = m
		buttons.append({
			"text": _quest_mode_label(captured_m),
			"callback": func() -> void: _pick_quest_modes([captured_m]),
		})
	if can_both:
		var pair := avail.duplicate()
		buttons.append({
			"text": "Both (choose order)",
			"callback": func() -> void: _show_quest_order_popup(qname, pair),
		})
	_quest_choice_nodes.append(
		_build_choice_popup(header, Color(0.95, 0.8, 0.3), buttons, true))


# Second step after "Both": which mode resolves first (the other follows).
func _show_quest_order_popup(qname: String, pair: Array) -> void:
	_clear_quest_choice_nodes()
	_in_quest_choice_mode = true
	var buttons: Array = []
	for i in pair.size():
		var first: String = pair[i]
		var second: String = pair[1 - i]
		buttons.append({
			"text": "%s — first" % _quest_mode_label(first),
			"callback": func() -> void: _pick_quest_modes([first, second]),
		})
	_quest_choice_nodes.append(_build_choice_popup(
		"%s — both: which resolves first?" % qname,
		Color(0.95, 0.8, 0.3), buttons, true))


func _pick_quest_modes(chosen: Array) -> void:
	_clear_quest_choice_nodes()
	_in_quest_choice_mode = false
	var events := StackResolver.choose_quest_modes(_state, chosen, _db)
	EventBus.emit_events(events)   # may open a sub-choice (its handler takes over)
	_on_quest_flow_resolved()


func _clear_quest_choice_nodes() -> void:
	for node in _quest_choice_nodes:
		if is_instance_valid(node):
			node.queue_free()
	if not _quest_choice_nodes.is_empty():
		_set_board_block(false)
	_quest_choice_nodes.clear()


# Hidden Enemies: the completer picks the ally that gains ferocity this turn.
func _handle_quest_ferocity_target(payload: Dictionary) -> void:
	var player: String   = payload.get("player", "")
	var quest_id: String = payload.get("quest_id", "")
	if _route_choice(player, "public") == "ai":
		var ai_obj: Object = _p1_ai if player == "p1" else _p2_ai
		var target_id := ""
		if ai_obj is BaseAI:
			target_id = (ai_obj as BaseAI).choose_quest_ferocity_target(_state, _db, player)
		else:
			var legal := StackResolver.get_quest_ferocity_targets(_state, _db)
			target_id = legal[0] if not legal.is_empty() else ""
		var events := StackResolver.choose_quest_ferocity_target(_state, target_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_router.start_quest_ferocity_targeting(quest_id)
		_set_status("🐺 Select the ally that gains ferocity this turn")
		_refresh_ui()


# A New Plague: the pending player destroys an ally in their own party.
func _handle_plague_destroy(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	if _route_choice(player, "public") == "ai":
		var ai_obj: Object = _p1_ai if player == "p1" else _p2_ai
		var pick_id := ""
		if ai_obj is BaseAI:
			pick_id = (ai_obj as BaseAI).choose_plague_destroy(_state, _db, player)
		else:
			var own := _state.cards_in_zone(player + "_ally_row")
			pick_id = own[0].instance_id if not own.is_empty() else ""
		var events := StackResolver.choose_plague_destroy(_state, pick_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		var candidates: Array = []
		for c in _state.cards_in_zone(player + "_ally_row"):
			candidates.append(c.instance_id)
		_router.start_plague_destroy_mode(candidates)
		_set_status("☠ %s: choose an ally in your party to destroy" % player.to_upper())
		_refresh_ui()


# Kolkar: the TARGET player turns one of their face-up quests face down.
func _handle_quest_facedown(payload: Dictionary) -> void:
	var player: String  = payload.get("player", "")
	var quest_ids: Array = payload.get("quest_ids", [])
	if _route_choice(player, "public") == "ai":
		var ai_obj: Object = _p1_ai if player == "p1" else _p2_ai
		var pick_id := ""
		if ai_obj is BaseAI:
			pick_id = (ai_obj as BaseAI).choose_quest_facedown(_state, _db, player)
		else:
			pick_id = quest_ids[0] if not quest_ids.is_empty() else ""
		var events := StackResolver.choose_quest_facedown(_state, pick_id, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_router.start_quest_facedown_mode(quest_ids)
		_set_status("🔻 %s: choose one of your quests to turn face down" % player.to_upper())
		_refresh_ui()


# A human resolved a quest-reward sub-pick (or the mode pick itself). Exit the
# hotseat peek if the flow is over, then resume driving the turn — any further
# pending sub-choice already restarted its own mode via its handler.
func _on_quest_flow_resolved() -> void:
	if not StackResolver._quest_choice_pending(_state):
		if _in_choice_peek:
			_exit_choice_peek_mode()
		elif _hotseat and _router.local_player != _local_player:
			_router.setup(_state, _db, _local_player)
	_refresh_ui()
	_drain_passes()
	_schedule_next_turn()


func _on_targeting_started(source_id: String, dmg_type: String, _dmg_amount: int) -> void:
	var card := _state.get_card(source_id) as CardInstance
	var def: CardDef = _db.get_def(card.card_def_id) if card else null
	var name_str := def.card_name if def else source_id
	# Mandatory picks (Taz'dingo's enter-play damage, totem triggers, Boneshanks,
	# Hidden Enemies' ferocity) can't be backed out of — a cancel just restarts the
	# same pick — so the hint must not advertise one.
	var cancel_hint := "  [mandatory]" if _router.targeting_is_mandatory() \
		else "  [right-click to cancel]"
	if dmg_type == "heal":
		_set_status("✚ %s — select a target to heal%s" % [name_str, cancel_hint])
	# Phase 1 of a two-pick sacrifice power (Gertha, Besh'iah): the cost, not the
	# effect's target — say so, or the player can't tell the two picks apart.
	elif dmg_type == "sacrifice":
		_set_status("☠ %s — select an ally to sacrifice%s" % [name_str, cancel_hint])
	# Ravenous Bite's two sequential ally picks (see InputRouter._is_atk_swing).
	elif dmg_type in ["atk_up", "atk_down"]:
		var swing: Array = StackResolver.atk_swing_amounts(def)
		var idx := 0 if dmg_type == "atk_up" else 1
		var amt: int = swing[idx] if idx < swing.size() else 0
		if dmg_type == "atk_up":
			_set_status("▲ %s — select the ally that gets %+d ATK this turn%s"
				% [name_str, amt, cancel_hint])
		else:
			_set_status("▼ %s — select the ally that gets %+d ATK this turn  [click the spell to go back]"
				% [name_str, amt])
	else:
		# Lightning Storm: X clicks, one per point of damage — the prompt counts
		# "N / X target" (the same ally may be clicked more than once).
		var div: Array = _router.divided_progress()
		if int(div[1]) > 0:
			_set_status("⚡ %s — %d / %d target — click an ally for each point of damage%s"
				% [name_str, int(div[0]) + 1, int(div[1]), cancel_hint])
		else:
			_set_status("⚔ %s — select a target%s" % [name_str, cancel_hint])
	_refresh_ui()


func _on_targeting_cancelled() -> void:
	_set_status("")
	# Attack-exhaust trigger (Chops / Voss Treebender) is optional ("you may") —
	# Esc while picking resolves it as a decline, opening the held attack window.
	if _state and _state.pending_attack_exhaust_player != "":
		var ex_events := StackResolver.choose_attack_exhaust(_state, "", _db)
		EventBus.emit_events(ex_events)
		_refresh_ui()
		return
	# A totem trigger's damage is mandatory ("deals", not "may") — the player can't
	# bow out of picking. If one is still pending after a cancel, restart targeting
	# from the front queued trigger so the human is asked again instead of locked.
	if _state and _state.pending_trigger_target_player != "" \
			and not _state.pending_turn_start_triggers.is_empty():
		var trig: Dictionary = _state.pending_turn_start_triggers[0]
		# The queue carries the raw effects args (see GameState.pending_turn_start_triggers);
		# for the targeted trigger they are AMOUNT:DMG_TYPE.
		var trig_args: Array = trig.get("args", [])
		_router.start_trigger_targeting(
			trig.get("card_id", ""),
			String(trig_args[1]) if trig_args.size() > 1 else "",
			int(trig_args[0]) if trig_args.size() > 0 else 0)
		return
	# Hidden Enemies' ferocity pick is mandatory once the mode was chosen — if a
	# cancel somehow fired while it is pending, restart targeting.
	if _state and _state.pending_quest_ferocity_player != "":
		_router.start_quest_ferocity_targeting(_state.pending_quest_ferocity_source)
		return
	# A Boneshanks death trigger is mandatory ("destroy target ally") whenever a
	# legal ally exists — the player can't bow out. Restart targeting if still pending.
	if _state and _state.pending_death_target_player != "" \
			and not _state.pending_death_triggers.is_empty():
		var dtrig: Dictionary = _state.pending_death_triggers[0]
		_router.start_death_target_targeting(dtrig.get("card_id", ""))
		return
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
			# Optional effect (Ghank "you may ...") — Esc means decline.
			if eff.get("optional", false):
				EventBus.emit_events(StackResolver.decline_enter_play_effect(_state))
				_refresh_ui()
				_drain_passes()
				return
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

	_hud.add_child(_x_dialog)


func _on_x_select_requested(hero_id: String, max_x: int) -> void:
	_x_hero_id = hero_id
	_x_max = max_x
	_x_label.text = "Choose X (1 – %d):" % max_x
	_x_input.text = ""
	# Centre the dialog in the viewport.
	var vp := get_viewport().get_visible_rect().size
	_x_dialog.position = (vp - _x_dialog.custom_minimum_size) * 0.5
	_x_dialog.visible = true
	_set_board_block(true)
	_x_input.grab_focus()
	var hero_card := _router.state.get_card(hero_id) if _router.state else null
	var hero_def: CardDef = _router.db.get_def(hero_card.card_def_id) if hero_card and _router.db else null
	if hero_def and hero_def.cost_x:
		# X-cost hand card (Aimed Shot): X is both the extra cost and the amount.
		_set_status("Enter X — %s costs %d+X" % [hero_def.card_name, hero_def.cost_base])
	elif hero_def and StackResolver._power_effect_is(hero_def, "heal_x_from_target"):
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
	_set_board_block(false)
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
	_hud.add_child(_gy_dimmer)

	_gy_dialog = Panel.new()
	_gy_dialog.visible = false
	_gy_dialog.z_index = 20
	_hud.add_child(_gy_dialog)

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

	# Sections stack vertically: a search that spans BOTH graveyards (owner:both)
	# renders one labelled grid per graveyard so the player can tell whose cards
	# they are picking; every other search renders a single unlabelled grid.
	_gy_body = VBoxContainer.new()
	_gy_body.add_theme_constant_override("separation", 10)
	_gy_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gy_scroll.add_child(_gy_body)

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
	# Title reflects where the candidates come from: "your deck", "your
	# graveyard", or "any graveyard" (owner:both, e.g. Ophelia Barrows).
	var source := "your graveyard"
	var both := false
	var gy_req := StackResolver.get_graveyard_search_requirement(quest_def) if quest_def else {}
	if quest_def:
		if gy_req.get("source", "graveyard") == "deck":
			source = "your deck"
		elif gy_req.get("owner", "own") == "both":
			source = "any graveyard"
			both = true
		elif gy_req.get("owner", "own") == "opponent":
			source = "the opponent's graveyard"
	# "Any number" (max_count above the candidate pool) reads better as a range
	# the player can't miscount than as a literal "0 – 99".
	var any_number := min_count == 0 and max_count >= candidate_ids.size()
	if any_number:
		count_str = "any number of"
	# A search spanning BOTH graveyards is split into a labelled section per
	# graveyard — a flat grid gives the player no way to tell whose card is
	# whose, which matters when exiling from the opponent's pile is the point.
	var sections: Array = []
	if both:
		var mine: Array = []
		var theirs: Array = []
		var opp := "p2" if _local_player == "p1" else "p1"
		for cid in candidate_ids:
			var c := _state.get_card(cid as String)
			if c and c.zone_id == opp + "_graveyard":
				theirs.append(cid)
			else:
				mine.append(cid)
		sections = [
			{"label": "Your graveyard", "ids": mine},
			{"label": "Opponent's graveyard", "ids": theirs},
		]
	# Cannibalize's "heals 2 damage for each card removed" rider drives the
	# confirmation wording; 0 means the confirm just names the removal.
	_gy_confirm_heal = StackResolver.rfg_heal_per_card(quest_def) if quest_def else 0
	# Both-graveyard searches remove/relocate cards the player can't get back —
	# they confirm before the action is submitted (see _on_gy_confirm_pressed).
	_gy_ask_confirm = both
	var noun := "cards" if any_number else "card(s)"
	_open_gy_dialog(candidate_ids, false,
			"%s — choose %s %s from %s" % [quest_name, count_str, noun, source],
			min_count, max_count, true, sections)


func _on_graveyard_examine_requested(graveyard_player: String, card_ids: Array) -> void:
	var who := "Your" if graveyard_player == _local_player else "Opponent's"
	_open_gy_dialog(card_ids, true,
			"%s graveyard — %d card(s)" % [who, card_ids.size()], 0, 0)


# Alt+hover peek: same visual as examine, but non-modal (no dimmer, no buttons)
# so it can't steal hover away from the graveyard card driving it, and closes
# the instant Alt is released or the cursor leaves the pile.
func _on_graveyard_peek_requested(graveyard_player: String, card_ids: Array) -> void:
	var who := "Your" if graveyard_player == _local_player else "Opponent's"
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
		min_count: int, max_count: int, modal: bool = true,
		sections: Array = []) -> void:
	_gy_selected.clear()
	_gy_view_only = view_only
	_gy_peek_active = not modal
	_gy_min = min_count
	_gy_max = max_count
	_gy_title.text = title

	for child in _gy_body.get_children():
		child.queue_free()
	# One unlabelled section by default; `sections` ([{label, ids}]) splits the
	# pool per graveyard for owner:both searches. An EMPTY section is still
	# rendered with its label ("— empty —") so "no ally cards over there" is
	# information the player can see rather than infer from a missing heading.
	var groups: Array = sections
	if groups.is_empty():
		groups = [{"label": "", "ids": card_ids}]
	var count: int = max(card_ids.size(), 1)
	var cols: int = clamp(count, 1, GY_MAX_COLS)
	var card_rows := 0
	var head_lines := 0
	for g in groups:
		var ids: Array = g.get("ids", [])
		var label: String = str(g.get("label", ""))
		if label != "":
			var head := Label.new()
			head.text = label
			head.add_theme_font_size_override("font_size", 15)
			head.add_theme_color_override("font_color", Color(0.75, 0.8, 0.95))
			_gy_body.add_child(head)
			head_lines += 1
		if ids.is_empty():
			var empty := Label.new()
			empty.text = "— empty —"
			empty.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
			_gy_body.add_child(empty)
			head_lines += 1
			continue
		var grid := GridContainer.new()
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 14)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.columns = cols
		for cid in ids:
			grid.add_child(_make_gy_card_button(cid as String))
		_gy_body.add_child(grid)
		card_rows += ceili(float(ids.size()) / cols)

	_gy_confirm_btn.visible = not view_only and modal
	_gy_confirm_btn.text = "Confirm (C)"
	_gy_cancel_btn.visible = modal
	_gy_cancel_btn.text = "Close (Esc)" if view_only else "Cancel (Esc)"
	# Peek mode must never block board input — no dimmer, and the panel itself
	# lets clicks/hover pass through to the cards underneath.
	_gy_dialog.mouse_filter = Control.MOUSE_FILTER_STOP if modal else Control.MOUSE_FILTER_IGNORE

	# Size to content: width from columns, height from the card rows plus the
	# section headings/empty markers (capped → scrolls).
	var content_w: int = cols * int(GY_CARD_SIZE.x + 14) + 60
	var content_h: int = card_rows * int(GY_CARD_SIZE.y + 14) + head_lines * 34 + 140
	_gy_dialog.size = Vector2(max(content_w, 480), min(content_h, GY_MAX_DIALOG_H))
	_gy_dialog.position = (Vector2(1920, 1080) - _gy_dialog.size) * 0.5
	_gy_dimmer.visible = modal
	_gy_dialog.visible = true
	_set_board_block(modal)
	_update_gy_confirm()


func _make_gy_card_button(instance_id: String) -> Button:
	var card := _state.get_card(instance_id)
	var def: CardDef = _db.get_def(card.card_def_id) if card else null
	# Reveal-pick: cards that fail the filter are shown (important context) but
	# tinted red and non-selectable. Empty _gy_selectable ⇒ every card selectable.
	var pickable := (not _gy_filter_active) or _gy_selectable.has(instance_id)
	var btn := Button.new()
	btn.custom_minimum_size = GY_CARD_SIZE
	btn.toggle_mode = not _gy_view_only and pickable
	btn.clip_text = true
	var tex_path := "res://" + def.image_path.replace("\\", "/") if def and def.image_path != "" else ""
	if tex_path != "" and ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		btn.icon = tex
		btn.expand_icon = true
	else:
		btn.text = "%s\n(%d) %s" % [def.card_name if def else instance_id,
				def.cost if def else 0, def.card_type if def else ""]
	if not pickable:
		# Red overlay + no interaction — visible but not choosable.
		btn.disabled = true
		btn.modulate = Color(1.0, 0.45, 0.45)
		return btn
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
	if _gy_recomb_mode:
		_resolve_recomb_choice(_gy_selected[0] if not _gy_selected.is_empty() else "")
		return
	if _gy_reveal_mode:
		var pick: String = _gy_selected[0] if not _gy_selected.is_empty() else ""
		var payload := {
			"player": _state.pending_reveal_pick_player,
			"chooser": _state.pending_reveal_pick_chooser,
			"selectable": _state.pending_reveal_pick_ids.duplicate(),
			"revealed": _state.pending_reveal_pick_all.duplicate(),
			"card_type": _gy_reveal_card_type,
			"to_top": _state.pending_reveal_pick_to_top,
			"private": _state.pending_reveal_pick_private,
		}
		_close_gy_dialog()
		var events := StackResolver.choose_reveal_pick(_state, pick, _db)
		# Safety net: the engine refuses an illegal pick and leaves the choice
		# pending — nothing else can resolve it, so re-open rather than stall
		# the game with a hidden pending choice (see _gy_filter_active).
		if _state.pending_reveal_pick_player != "":
			_handle_reveal_pick(payload)
			return
		# Choice resolved — if an off-screen human made it, hand input back to
		# the seated player.
		_exit_choice_peek_mode()
		EventBus.emit_events(events)
		_set_status("")
		_refresh_ui()
		_schedule_next_turn()
		return
	# Both-graveyard searches (Cannibalize, Ophelia Barrows) exile cards for
	# good, so the pick is re-stated once before it is submitted. Cancelling
	# leaves the browser open with the selection intact — nothing has been sent
	# to the engine yet, so backing out costs nothing.
	if _gy_ask_confirm and _gy_confirm_nodes.is_empty():
		_show_gy_confirm_popup()
		return
	_dismiss_gy_confirm_popup()
	_close_gy_dialog()
	_router.confirm_graveyard_selection(_gy_selected.duplicate())
	_refresh_ui()


# "Remove 3 ally cards and heal 6 damage?" — the last stop before the selection
# is announced. Sits above the browser (which stays open behind it) so Cancel
# returns the player to their picks rather than to the board.
func _show_gy_confirm_popup() -> void:
	var n := _gy_selected.size()
	var noun := "ally card" if n == 1 else "ally cards"
	var text := "Remove %d %s from the game" % [n, noun]
	if _gy_confirm_heal > 0:
		text += " and heal %d damage" % (_gy_confirm_heal * n)
	text += "?"
	var popup := _build_choice_popup(text, Color(0.85, 0.85, 0.95), [
		{"text": "Confirm", "callback": Callable(self, "_on_gy_confirm_pressed")},
		{"text": "Cancel",  "callback": Callable(self, "_dismiss_gy_confirm_popup")},
	])
	# The browser's dimmer/panel sit at z 19/20 — the popup must clear both.
	popup.z_index = 25
	_gy_confirm_nodes.append(popup)


func _dismiss_gy_confirm_popup() -> void:
	for n in _gy_confirm_nodes:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_gy_confirm_nodes.clear()


func _on_gy_cancel_pressed() -> void:
	# The "are you sure?" popup is the innermost layer: Esc/Cancel dismisses it
	# and returns to the selection instead of abandoning the whole search.
	if not _gy_confirm_nodes.is_empty():
		_dismiss_gy_confirm_popup()
		return
	if _gy_reveal_mode:
		return  # mandatory reveal-pick — no cancel
	if _gy_recomb_mode:
		_resolve_recomb_choice("")   # "you may" — Esc/Cancel declines the fetch
		return
	var was_view_only := _gy_view_only
	_close_gy_dialog()
	if not was_view_only:
		_router.cancel_graveyard_selection()
	_refresh_ui()


# Shared exit for the Recombobulation browser: "" declines. Another queued
# death re-opens the browser through recomb_choice_opened, so this only has to
# hand input back to the seated player and resume driving.
func _resolve_recomb_choice(pick: String) -> void:
	_close_gy_dialog()
	var events := StackResolver.choose_recombobulation(_state, pick, _db)
	_exit_choice_peek_mode()
	EventBus.emit_events(events)
	_set_status("")
	_refresh_ui()
	_schedule_next_turn()


func _close_gy_dialog() -> void:
	_dismiss_gy_confirm_popup()
	_gy_ask_confirm = false
	_gy_confirm_heal = 0
	_gy_reveal_mode = false
	_gy_recomb_mode = false
	_gy_selectable.clear()
	_gy_filter_active = false
	_gy_dialog.visible = false
	_gy_dimmer.visible = false
	_set_board_block(false)
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
	# Modal except the legal protectors — clicking one is the same as its button
	# (see _build_choice_popup; the protect point renders inline, not as a popup).
	_set_board_block(true, protectors)
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

	# Prompt + buttons live in the Combat window (see _build_combat_window), which
	# already shows the step and the combatants — this only adds the question and
	# the choices. The window is off to the side, so the board stays visible and
	# a protector can still be picked by clicking the card itself.
	_update_combat_window()
	_clear_combat_buttons()
	_combat_prompt_lbl.text = "%s is attacking %s — protect?" % [atk_name, def_name]

	# One button per legal protector, then Skip; laid out left to right and
	# wrapped to the row width so a wide party can't overflow the window.
	var row_w: float = _combat_btn_row.size.x
	var n := protectors.size()
	var btn_w: float = min(170.0, (row_w - 100.0 - COMBAT_BTN_GAP * (n + 1)) / max(n, 1))
	var bx := 0.0
	for cid in protectors:
		var card := _state.get_card(cid)
		var btn_label: String = cid
		if card and _db:
			var def: CardDef = _db.get_def(card.card_def_id)
			if def:
				btn_label = def.card_name
		var btn := Button.new()
		btn.text          = btn_label
		btn.clip_text     = true
		btn.position      = Vector2(bx, 0)
		btn.size          = Vector2(btn_w, COMBAT_BTN_H)
		var captured_id: String = cid
		btn.pressed.connect(func() -> void: _resolve_protection(captured_id))
		_combat_btn_row.add_child(btn)
		bx += btn_w + COMBAT_BTN_GAP

	var skip := Button.new()
	skip.text     = "Skip"
	skip.position = Vector2(bx + COMBAT_BTN_GAP, 0)
	skip.size     = Vector2(90, COMBAT_BTN_H)
	skip.pressed.connect(func() -> void: _resolve_protection(""))
	_combat_btn_row.add_child(skip)

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
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	for n in _protect_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_protect_nodes.clear()
	_clear_combat_buttons()
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
	elif _in_prevention_mode and instance_id in _prevention_armor_ids:
		_resolve_prevention(instance_id)
	elif _in_ally_exhaust_mode and instance_id in _ally_exhaust_candidates:
		_toggle_ally_exhaust_pick(instance_id)


# ── Central choice popup (every non-Protect player choice) ─────────────────────
# Protecting stays inline over the pass bar (it's the common combat decision and
# players expect it there). Every OTHER board-public player choice — modal mode
# (Natural Selection), weapon strike, ready-on-attack (Windseer Tarus), Green
# Whelp bounce — renders in this centered popup panel instead of crowding the
# pass button. `buttons` is an Array of { "text": String, "callback": Callable }.
# Returns the root Panel; freeing it (queue_free) tears down the whole popup, so
# callers append just the panel to their existing `_*_nodes` array.
const CHOICE_POPUP_CENTER := Vector2(960, 470)


# Single entry point for the modal board block. `allowed_ids` (only meaningful
# while blocking) is the set of board cards that remain clickable because clicking
# them IS one of the open choice's options. Releasing always clears the allowlist.
func _set_board_block(blocked: bool, allowed_ids: Array = []) -> void:
	CardNode.input_blocked   = blocked
	CardNode.input_allowlist = allowed_ids.duplicate() if blocked else []


# `block_board` makes the choice modal: while the popup is up, board cards can't be
# clicked (CardNode.input_blocked) so a card sitting under a button can't steal the
# click, and the player must answer the popup before doing anything else.
# `allowed_ids` are the exceptions — cards that ARE one of the popup's options and
# stay clickable (armor at the prevention point, weapon at the strike point). The
# general rule: while a choice point is open, nothing that isn't one of its options
# responds to a click, so a missed click can never start e.g. attacker targeting.
# Callers that opt in MUST release the block (`_set_board_block(false)`) when they
# tear the popup down.
func _build_choice_popup(header_text: String, header_color: Color, buttons: Array,
		block_board: bool = false, allowed_ids: Array = []) -> Panel:
	if block_board:
		_set_board_block(true, allowed_ids)
	const PAD        := 26
	const BTN_H      := 40
	const BTN_GAP    := 12
	const HEADER_H   := 30
	const HEADER_GAP := 20
	# Button sizing: width grows with the label up to MAX_BTN_W, then the label
	# WRAPS onto extra lines instead of overflowing into the next button (long
	# quest reward modes: "Put your hand on the bottom of your deck, …").
	const MIN_BTN_W  := 150
	const MAX_BTN_W  := 360
	const BTN_CHAR_W := 10   # approx px per character at the button's font size
	const BTN_LINE_H := 22
	const BTN_TEXT_PAD := 36

	# Per-button width from label length (clamped); total row width from those.
	# The tallest wrapped label sets one shared row height, so the buttons stay
	# aligned however many lines any one of them needs.
	var btn_widths: Array[int] = []
	var row_w := 0
	var max_lines := 1
	for b in buttons:
		var text_len: int = str(b.get("text", "")).length()
		var w: int = clampi(text_len * BTN_CHAR_W + BTN_TEXT_PAD, MIN_BTN_W, MAX_BTN_W)
		var chars_per_line: int = maxi(int(float(w - BTN_TEXT_PAD) / float(BTN_CHAR_W)), 1)
		max_lines = maxi(max_lines, ceili(float(text_len) / float(chars_per_line)))
		btn_widths.append(w)
		row_w += w
	row_w += max(buttons.size() - 1, 0) * BTN_GAP
	var row_h: int = maxi(BTN_H, max_lines * BTN_LINE_H + 16)

	var header_w: int = header_text.length() * 8 + 40
	var content_w: int = max(row_w, header_w)
	var panel_w: int = content_w + PAD * 2
	var panel_h: int = PAD * 2 + HEADER_H + HEADER_GAP + row_h

	var panel := Panel.new()
	panel.size     = Vector2(panel_w, panel_h)
	panel.position = CHOICE_POPUP_CENTER - Vector2(panel_w, panel_h) * 0.5
	panel.add_theme_stylebox_override("panel", _make_stylebox(Color(0.10, 0.11, 0.16, 0.97)))
	_hud.add_child(panel)

	var header := Label.new()
	header.text = header_text
	header.add_theme_font_size_override("font_size", 15)
	header.add_theme_color_override("font_color", header_color)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.size     = Vector2(panel_w - PAD * 2, HEADER_H)
	header.position = Vector2(PAD, PAD)
	panel.add_child(header)

	@warning_ignore("integer_division")
	var btn_x := (panel_w - row_w) / 2
	var btn_y := PAD + HEADER_H + HEADER_GAP
	for i in buttons.size():
		var btn := Button.new()
		btn.text = str(buttons[i].get("text", ""))
		# Wrap rather than bleed over the neighbouring button. Order matters:
		# a Control can never be sized below its combined MINIMUM size, and a
		# Button's minimum includes its full single-line text width — so a long
		# label silently ignored the width set here and painted over the next
		# button. clip_text takes the text out of that minimum, and
		# custom_minimum_size then pins the box we actually laid out.
		btn.autowrap_mode      = TextServer.AUTOWRAP_WORD_SMART
		btn.clip_text          = true
		btn.custom_minimum_size = Vector2(btn_widths[i], row_h)
		btn.position = Vector2(btn_x, btn_y)
		btn.size     = Vector2(btn_widths[i], row_h)
		btn.pressed.connect(buttons[i].get("callback") as Callable)
		panel.add_child(btn)
		btn_x += btn_widths[i] + BTN_GAP

	return panel


# ── Transient notice (no choice — just tells the player what happened) ────────
# Non-blocking: shows a centered banner in the HUD that fades itself out, so it
# never stalls the AI or an auto-passing hotseat seat.
func _show_transient_notice(text: String, color: Color, hold: float = 1.6) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER

	var panel_w: int = clampi(text.length() * 12 + 60, 260, 900)
	var panel_h := 68
	var panel := Panel.new()
	panel.size     = Vector2(panel_w, panel_h)
	panel.position = CHOICE_POPUP_CENTER - Vector2(panel_w, panel_h) * 0.5
	panel.add_theme_stylebox_override("panel", _make_stylebox(Color(0.10, 0.11, 0.16, 0.97)))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(panel)

	label.size     = Vector2(panel_w, panel_h)
	label.position = Vector2.ZERO
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)

	var tw := create_tween()
	tw.tween_interval(hold)
	tw.tween_property(panel, "modulate:a", 0.0, 0.35)
	tw.tween_callback(panel.queue_free)


# Rule 603.1b — a combatant was bounced / destroyed / removed from combat before
# the conclusion. The engine emits combat_cancelled; the renderer skips the
# attack animation (cancelled flag on combat_concluded) and we say so here.
func _show_combat_cancelled_notice(payload: Dictionary) -> void:
	var reason: String = payload.get("reason", "")
	var att: String = _log_card(payload.get("attacker_id", ""))
	var def: String = _log_card(payload.get("defender_id", ""))
	var detail := ""
	match reason:
		"attacker_removed":
			detail = "the attacker was removed from combat"
		"attacker_gone":
			detail = "%s left play" % (att if att != "" else "the attacker")
		_:
			detail = "%s left play" % (def if def != "" else "the defender")
	_show_transient_notice("⚔ Combat cancelled — %s. No damage dealt." % detail,
		Color(0.95, 0.55, 0.45))


# ── Modal spell mode choice (rule 707.1c — "Choose one:", Natural Selection) ───

func _on_modal_choice_opened(card_id: String, mode_labels: Array) -> void:
	_clear_modal_buttons()

	var card := _state.get_card(card_id)
	var def: CardDef = _db.get_def(card.card_def_id) if card and _db else null
	var header_text := "%s — choose one:" % (def.card_name if def else "Choose one:")

	var buttons: Array = []
	for i in mode_labels.size():
		var captured_i: int = i
		# choose_modal_mode fires modal_choice_cancelled first (clearing this popup
		# via _on_modal_choice_cancelled), then starts targeting.
		buttons.append({
			"text": str(mode_labels[i]),
			"callback": func() -> void: _router.choose_modal_mode(captured_i),
		})
	buttons.append({
		"text": "Cancel",
		"callback": func() -> void: _router.cancel_modal_choice(),
	})

	_modal_nodes.append(_build_choice_popup(header_text, Color(0.9, 0.5, 0.2), buttons, true))


func _on_modal_choice_cancelled() -> void:
	_clear_modal_buttons()


func _clear_modal_buttons() -> void:
	for node in _modal_nodes:
		if is_instance_valid(node):
			node.queue_free()
	if not _modal_nodes.is_empty():
		_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	_modal_nodes.clear()


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

	var header_text := "Strike with a weapon? (%s)" % \
		("attacking" if side == "attack" else "defending")

	var buttons: Array = []
	for cid in weapon_ids:
		var btn_label: String = cid
		var card := _state.get_card(cid)
		if card and _db:
			var def: CardDef = _db.get_def(card.card_def_id)
			if def:
				var cost := StackResolver.get_strike_cost(_state, _state.pending_strike_player, def, _db)
				btn_label = "%s  (+%d ATK, %d)" % [def.card_name, _state.get_atk(cid, _db), cost]
		var captured_id: String = cid
		buttons.append({
			"text": btn_label,
			"callback": func() -> void: _resolve_strike(captured_id),
		})
	buttons.append({
		"text": "Don't strike",
		"callback": func() -> void: _resolve_strike(""),
	})

	# Modal except the weapons themselves — clicking one is the same as its button.
	_strike_nodes.append(_build_choice_popup(
		header_text, Color(0.9, 0.5, 0.2), buttons, true, weapon_ids))

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
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	for n in _strike_nodes:
		if is_instance_valid(n):
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


# ── Quest "exhaust N allies" cost picker (The Love Potion) ────────────────────
# Same shape as the armor-prevention popup — a centered panel plus clickable
# board cards — but it runs BEFORE anything is submitted to the engine. Clicking
# a candidate toggles selection (green → blue) and rebuilds the panel; Confirm
# only lights up at exactly N picks and hands the ids to the router, which
# submits the completion (that is where the allies actually exhaust and the
# resource is paid). Cancel throws the picks away with the game state unchanged.

func _on_ally_exhaust_select_requested(quest_id: String, candidate_ids: Array,
		count: int) -> void:
	_in_ally_exhaust_mode    = true
	_ally_exhaust_quest_id   = quest_id
	_ally_exhaust_candidates = candidate_ids.duplicate()
	_ally_exhaust_selected   = []
	_ally_exhaust_count      = count
	_ai_timer.stop()   # no AI actions while the human is deciding
	_pass_btn.visible   = false
	_cancel_btn.visible = false
	_show_ally_exhaust_popup()


func _show_ally_exhaust_popup() -> void:
	_clear_ally_exhaust_nodes()

	var quest_name := "this quest"
	var q_card := _state.get_card(_ally_exhaust_quest_id)
	if q_card and _db:
		var q_def: CardDef = _db.get_def(q_card.card_def_id)
		if q_def:
			quest_name = q_def.card_name
	var header_text := "%s — select %d allies to exhaust  (%d/%d)" % [
		quest_name, _ally_exhaust_count,
		_ally_exhaust_selected.size(), _ally_exhaust_count]

	var buttons: Array = []
	if _ally_exhaust_selected.size() == _ally_exhaust_count:
		buttons.append({
			"text": "Complete quest",
			"callback": func() -> void: _confirm_ally_exhaust(),
		})
	buttons.append({
		"text": "Cancel",
		"callback": func() -> void: _cancel_ally_exhaust(),
	})

	# Modal except the candidate allies — clicking one toggles its selection.
	_ally_exhaust_nodes.append(_build_choice_popup(
		header_text, ALLY_EXHAUST_SELECTED_COLOR, buttons, true, _ally_exhaust_candidates))

	# Deferred for the same reason as the prevention/protect outlines.
	call_deferred("_apply_ally_exhaust_highlights")


func _apply_ally_exhaust_highlights() -> void:
	if not _in_ally_exhaust_mode:
		return   # already resolved before this frame fired
	for cid in _ally_exhaust_candidates:
		_renderer.set_card_outline(cid, true,
			ALLY_EXHAUST_SELECTED_COLOR if cid in _ally_exhaust_selected
			else ALLY_EXHAUST_LEGAL_COLOR)


func _toggle_ally_exhaust_pick(instance_id: String) -> void:
	if instance_id in _ally_exhaust_selected:
		_ally_exhaust_selected.erase(instance_id)
	elif _ally_exhaust_selected.size() < _ally_exhaust_count:
		_ally_exhaust_selected.append(instance_id)
	else:
		return   # already at N picks — deselect one first
	_show_ally_exhaust_popup()


func _clear_ally_exhaust_nodes() -> void:
	for n in _ally_exhaust_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_ally_exhaust_nodes.clear()


# Tear the picker down. Clears the blue/green outlines that _apply_* painted
# directly (they are not part of the router's highlight set).
func _end_ally_exhaust_mode() -> void:
	for cid in _ally_exhaust_candidates:
		_renderer.set_card_outline(cid, false)
	_in_ally_exhaust_mode    = false
	_ally_exhaust_quest_id   = ""
	_ally_exhaust_candidates = []
	_ally_exhaust_selected   = []
	_ally_exhaust_count      = 0
	_clear_ally_exhaust_nodes()
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	_pass_btn.visible = true


func _confirm_ally_exhaust() -> void:
	var picks := _ally_exhaust_selected.duplicate()
	_end_ally_exhaust_mode()
	_router.confirm_ally_exhaust_selection(picks)
	_refresh_ui()
	_drain_passes()
	_schedule_next_turn()


func _cancel_ally_exhaust() -> void:
	_end_ally_exhaust_mode()
	_router.cancel_ally_exhaust_selection()
	_refresh_ui()


# ── Armor prevention point (rule 717.2c) ───────────────────────────────────────
# Opened by the engine at the moment a damage packet would hit a hero whose
# controller has ready DEF armor — combat conclusion or a hero-damaging chain
# link about to resolve. The player exhausts armors one at a time (the engine
# re-opens the point while damage remains and armor is available) or takes the
# damage. Board-public, so the off-screen hotseat player is prompted inline too.

func _handle_prevention(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	var ai: Object = _p1_ai if player == "p1" else _p2_ai
	if player_type != "human":
		# AI decides one armor per call; choose_prevention re-emits
		# prevention_opened (re-entering this handler) while the point stays open.
		var armor_id: String = ai.choose_prevention(_state, _db, player)
		var events := StackResolver.choose_prevention(_state, armor_id, _db)
		EventBus.emit_events(events)
		if _state.pending_prevention_player == "":
			_refresh_ui()
			_drain_passes()
			_schedule_next_turn()
	else:
		_show_prevention_inline(payload)


func _show_prevention_inline(payload: Dictionary) -> void:
	# A previous popup may still be up when the point re-opens (second armor).
	_clear_prevention_nodes()
	_in_prevention_mode   = true
	_prevention_armor_ids = StackResolver.get_ready_def_armor(
		_state, payload.get("player", ""), _db)
	_ai_timer.stop()   # no AI actions while the human is deciding
	_pass_btn.visible   = false
	_cancel_btn.visible = false

	var amount: int = payload.get("amount", 0)
	var src_card := _state.get_card(payload.get("source", ""))
	var src_def: CardDef = _db.get_def(src_card.card_def_id) if src_card else null
	var header_text := "%d damage incoming%s — exhaust armor to prevent?" % [
		amount, (" from %s" % src_def.card_name) if src_def else ""]

	var buttons: Array = []
	for cid in _prevention_armor_ids:
		var btn_label: String = cid
		var card := _state.get_card(cid)
		if card and _db:
			var def: CardDef = _db.get_def(card.card_def_id)
			if def:
				btn_label = "%s  (DEF %d)" % [def.card_name,
					int(StackResolver._equipment_info(def).get("def", 0))]
		var captured_id: String = cid
		buttons.append({
			"text": btn_label,
			"callback": func() -> void: _resolve_prevention(captured_id),
		})
	buttons.append({
		"text": "Take the damage",
		"callback": func() -> void: _resolve_prevention(""),
	})

	# Modal except the armors themselves — clicking one is the same as its button.
	_prevention_nodes.append(_build_choice_popup(
		header_text, Color(0.55, 0.75, 1.0), buttons, true, _prevention_armor_ids))

	# Highlight the exhaustable armors (deferred, same reason as protect outlines).
	var captured_ids: Array = _prevention_armor_ids.duplicate()
	call_deferred("_apply_prevention_highlights", captured_ids)


func _apply_prevention_highlights(armor_ids: Array) -> void:
	if not _in_prevention_mode:
		return   # already resolved before this frame fired
	_renderer.highlight_cards(armor_ids)


func _clear_prevention_nodes() -> void:
	for n in _prevention_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_prevention_nodes.clear()


func _resolve_prevention(armor_id: String) -> void:
	_in_prevention_mode   = false
	_prevention_armor_ids = []
	_clear_prevention_nodes()
	# Released here, not in _clear_prevention_nodes — that also runs when the point
	# re-opens for a second armor, which immediately re-blocks with the new list.
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	_pass_btn.visible = true
	_router.refresh_highlights()

	var events := StackResolver.choose_prevention(_state, armor_id, _db)
	EventBus.emit_events(events)
	# Point still open (another armor / the other hero's packet)? The nested
	# prevention_opened handler already rebuilt the UI inside emit_events.
	if _state.pending_prevention_player != "":
		return
	_refresh_ui()
	_drain_passes()
	_schedule_next_turn()


# ── Ready-on-attack point (Windseer Tarus) ─────────────────────────────────────

func _handle_ready_point(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	var ai: Object = _p1_ai if player == "p1" else _p2_ai
	if player_type != "human":
		# AI decides immediately (BaseAI.choose_ready_on_attack).
		var pay: bool = ai.choose_ready_on_attack(_state, _db, player)
		var events := StackResolver.choose_ready_on_attack(_state, pay, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_show_ready_inline(payload)


func _show_ready_inline(payload: Dictionary) -> void:
	_in_ready_mode = true
	_ai_timer.stop()   # no AI actions while the human is deciding
	_pass_btn.visible   = false
	_cancel_btn.visible = false

	var card_id: String = payload.get("card_id", "")
	var cost: int       = payload.get("cost", 0)
	var card := _state.get_card(card_id)
	var card_name := "the attacker"
	if card and _db:
		var def: CardDef = _db.get_def(card.card_def_id)
		if def:
			card_name = def.card_name

	var header_text := "%s attacks — pay %d to ready it?" % [card_name, cost]
	var buttons: Array = [
		{
			"text": "Pay %d: ready %s" % [cost, card_name],
			"callback": func() -> void: _resolve_ready(true),
		},
		{
			"text": "Decline",
			"callback": func() -> void: _resolve_ready(false),
		},
	]

	# Yes/no choice — nothing on the board is an option, so block all of it.
	_ready_nodes.append(_build_choice_popup(header_text, Color(0.5, 0.8, 0.9), buttons, true))


func _resolve_ready(pay: bool) -> void:
	_in_ready_mode = false
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	for n in _ready_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_ready_nodes.clear()
	_pass_btn.visible = true
	_router.refresh_highlights()

	var events := StackResolver.choose_ready_on_attack(_state, pay, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	# NOTE: no _drain_passes() here — same reasoning as _resolve_strike.
	# choose_ready_on_attack opens the held attack window, whose handler drains
	# synchronously inside emit_events above.


# ── Ready-on-strike point (Windfury Weapon) ───────────────────────────────────

func _handle_strike_ready_point(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	var ai: Object = _p1_ai if player == "p1" else _p2_ai
	if player_type != "human":
		# AI decides immediately (BaseAI.choose_ready_on_strike).
		var pay: bool = ai.choose_ready_on_strike(_state, _db, player)
		var events := StackResolver.choose_ready_on_strike(_state, pay, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_show_strike_ready_inline(payload)


func _show_strike_ready_inline(payload: Dictionary) -> void:
	_in_strike_ready_mode = true
	_ai_timer.stop()
	_pass_btn.visible   = false
	_cancel_btn.visible = false

	var weapon_id: String = payload.get("weapon_id", "")
	var cost: int         = payload.get("cost", 0)
	var card := _state.get_card(weapon_id)
	var card_name := "the weapon"
	if card and _db:
		var def: CardDef = _db.get_def(card.card_def_id)
		if def:
			card_name = def.card_name

	var header_text := "Windfury — pay %d to ready %s and your hero?" % [cost, card_name]
	var buttons: Array = [
		{
			"text": "Pay %d: ready %s + hero" % [cost, card_name],
			"callback": func() -> void: _resolve_strike_ready(true),
		},
		{
			"text": "Decline",
			"callback": func() -> void: _resolve_strike_ready(false),
		},
	]

	# Yes/no choice — nothing on the board is an option, so block all of it.
	_strike_ready_nodes.append(_build_choice_popup(
		header_text, Color(0.5, 0.8, 0.9), buttons, true))


func _resolve_strike_ready(pay: bool) -> void:
	_in_strike_ready_mode = false
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	for n in _strike_ready_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_strike_ready_nodes.clear()
	_pass_btn.visible = true
	_router.refresh_highlights()

	var events := StackResolver.choose_ready_on_strike(_state, pay, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	# NOTE: no _drain_passes() here — choose_ready_on_strike opens the held combat
	# window, whose handler drains synchronously inside emit_events above.


# ── Attack-exhaust point (Chops / Voss Treebender) ─────────────────────────────

func _handle_attack_exhaust(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	var ai: Object = _p1_ai if player == "p1" else _p2_ai
	if player_type != "human":
		# AI decides immediately (BaseAI.choose_attack_exhaust; "" = decline).
		var target: String = ai.choose_attack_exhaust(_state, _db, player) if ai else ""
		var events := StackResolver.choose_attack_exhaust(_state, target, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		# Human: enter targeting mode to pick the hero or ally to exhaust.
		# Esc = decline (see _on_targeting_cancelled) — the trigger is optional.
		_router.start_attack_exhaust_targeting(payload.get("source_id", ""))
		_refresh_ui()


# ── Green Whelp Armor bounce point ─────────────────────────────────────────────

func _handle_whelp_bounce(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	var ai: Object = _p1_ai if player == "p1" else _p2_ai
	# The bounce choice is board-public (pay 2 or decline — nothing hidden), so
	# like the protect/strike points any human decides inline, including the
	# off-screen hotseat player. Only AI seats auto-resolve; a null AI declines.
	if player_type != "human":
		var pay: bool = ai.choose_whelp_bounce(_state, _db, player) if ai else false
		var events := StackResolver.choose_whelp_bounce(_state, pay, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_show_whelp_bounce_inline(payload)


func _show_whelp_bounce_inline(payload: Dictionary) -> void:
	_in_whelp_bounce_mode = true
	_ai_timer.stop()   # no AI actions while the human is deciding
	_pass_btn.visible   = false
	_cancel_btn.visible = false

	var ally_id: String = payload.get("ally_id", "")
	var cost: int       = payload.get("cost", 0)
	var card := _state.get_card(ally_id)
	var card_name := "the attacker"
	if card and _db:
		var def: CardDef = _db.get_def(card.card_def_id)
		if def:
			card_name = def.card_name

	var who: String = payload.get("player", "")
	var prefix := "%s: " % who.to_upper() if _hotseat and who != "" else ""
	var header_text := "%sGreen Whelp Armor — pay %d to return %s to hand?" % [prefix, cost, card_name]
	var buttons: Array = [
		{
			"text": "Pay %d: bounce %s" % [cost, card_name],
			"callback": func() -> void: _resolve_whelp_bounce(true),
		},
		{
			"text": "Decline",
			"callback": func() -> void: _resolve_whelp_bounce(false),
		},
	]

	_whelp_bounce_nodes.append(_build_choice_popup(header_text, Color(0.5, 0.9, 0.6), buttons, true))


# Form pay-return choice (Bear/Cat Form death trigger). Board-public like the
# whelp bounce: AI seats auto-resolve (always pay — see BaseAI.choose_form_return),
# any human gets the inline pay/decline popup.
func _handle_form_return(payload: Dictionary) -> void:
	var player: String = payload.get("player", "")
	var player_type := _p1_type if player == "p1" else _p2_type
	var ai: Object = _p1_ai if player == "p1" else _p2_ai
	if player_type != "human":
		var pay: bool = ai.choose_form_return(_state, _db, player) if ai else false
		var events := StackResolver.choose_form_return(_state, pay, _db)
		EventBus.emit_events(events)
		_refresh_ui()
		_schedule_next_turn()
	else:
		_show_form_return_inline(payload)


func _show_form_return_inline(payload: Dictionary) -> void:
	_in_form_return_mode = true
	_ai_timer.stop()
	_pass_btn.visible   = false
	_cancel_btn.visible = false

	var card_id: String = payload.get("card_id", "")
	var cost: int       = payload.get("cost", 0)
	var card := _state.get_card(card_id)
	var card_name := "the Form"
	if card and _db:
		var def: CardDef = _db.get_def(card.card_def_id)
		if def:
			card_name = def.card_name

	var who: String = payload.get("player", "")
	var prefix := "%s: " % who.to_upper() if _hotseat and who != "" else ""
	var header_text := "%s%s destroyed — pay %d to return it to hand?" % [prefix, card_name, cost]
	var buttons: Array = [
		{
			"text": "Pay %d: return %s" % [cost, card_name],
			"callback": func() -> void: _resolve_form_return(true),
		},
		{
			"text": "Decline",
			"callback": func() -> void: _resolve_form_return(false),
		},
	]
	_form_return_nodes.append(_build_choice_popup(header_text, Color(0.7, 0.55, 0.35), buttons, true))


func _resolve_form_return(pay: bool) -> void:
	_in_form_return_mode = false
	for n in _form_return_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_form_return_nodes.clear()
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	_pass_btn.visible = true
	_router.refresh_highlights()

	var events := StackResolver.choose_form_return(_state, pay, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	_schedule_next_turn()
	_drain_passes()


func _resolve_whelp_bounce(pay: bool) -> void:
	_in_whelp_bounce_mode = false
	for n in _whelp_bounce_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_whelp_bounce_nodes.clear()
	_set_board_block(false)   # release the modal board-block (see _build_choice_popup)
	_pass_btn.visible = true
	_router.refresh_highlights()

	var events := StackResolver.choose_whelp_bounce(_state, pay, _db)
	EventBus.emit_events(events)
	_refresh_ui()
	# Combat already concluded; nothing reopens a window. Resume the normal flow.
	_schedule_next_turn()
	_drain_passes()


# ── Game over ──────────────────────────────────────────────────────────────────

func _handle_game_over(payload: Dictionary) -> void:
	if _game_over:
		return   # already handled — game_over can fire twice if both heroes die simultaneously
	_game_over = true
	_ai_timer.stop()
	var is_draw: bool  = bool(payload.get("draw", false))
	var winner: String = str(payload.get("winner", ""))
	# Headline = who won; the line under it is the win condition explanation
	# (GameEvent.game_over_explanation — one place for every reason).
	var headline: String = "☯  DRAW" if is_draw \
			else "★  %s  wins!" % _log_player(winner)
	var dialog := ConfirmationDialog.new()
	dialog.title            = "Game Over"
	dialog.dialog_text      = "%s\n\n%s\n\n%s" % [
		headline, GameEvent.game_over_explanation(payload), _stats_summary()]
	dialog.get_ok_button().text     = "Rematch"
	dialog.get_cancel_button().text = "Leave Game"
	dialog.confirmed.connect(_on_rematch)
	dialog.canceled.connect(func() -> void: get_tree().quit())
	add_child(dialog)
	dialog.popup_centered()


# Compact per-player stat block for the Game Over dialog.
func _stats_summary() -> String:
	var lines := PackedStringArray()
	lines.append("            Drawn   Played")
	for pid in ["p1", "p2"]:
		lines.append("%-8s  %5d   %6d" % [
			pid.to_upper(), _stats.drawn(pid), _stats.played(pid)])
	return "\n".join(lines)


func _on_rematch() -> void:
	for child in get_children():
		child.queue_free()
	await get_tree().process_frame
	_game_over                    = false
	_played_this_action_phase     = {}
	_stop_for_end_window          = false
	_camera_tween                 = null   # camera is rebuilt by _build_scene
	_in_ambush_mode               = false  # _stance survives the rematch (player pref)
	_ambush_player                = ""
	_in_choice_peek              = false
	_choice_peek_player          = ""
	_choice_peek_hides_hand      = false
	_handoff_pending              = false
	_handoff_layer                = null   # freed with the other children above
	_mulligan_queue               = []
	_mulligan_awaiting_ack        = false
	_local_player                 = "p1" if _p1_type == "human" \
			else ("p2" if _p2_type == "human" else "p1")
	_mulligan_current             = _local_player
	_set_board_block(false)
	_in_protect_mode              = false
	_protect_nodes                = []
	_in_strike_mode               = false
	_strike_nodes                 = []
	_in_ready_mode                = false
	_ready_nodes                  = []
	_in_strike_ready_mode         = false
	_strike_ready_nodes           = []
	_in_prevention_mode           = false
	_prevention_armor_ids         = []
	_prevention_nodes             = []
	_in_ally_exhaust_mode         = false
	_ally_exhaust_quest_id        = ""
	_ally_exhaust_candidates      = []
	_ally_exhaust_selected        = []
	_ally_exhaust_count           = 0
	_ally_exhaust_nodes           = []
	_in_form_return_mode          = false
	_form_return_nodes            = []
	_p1_has_mulliganed            = false
	_prompt_first_player          = true   # Rematch returns to the who-goes-first screen
	_first_player_layer           = null   # freed with the other children above
	_p1_ai = _make_ai(_p1_type, _last_p1_deck_id)
	_p2_ai = _make_ai(_p2_type, _last_p2_deck_id)
	_build_scene()
	_setup_game_state(DeckManager.get_runtime_deck(_last_p1_deck_id),
					  DeckManager.get_runtime_deck(_last_p2_deck_id))


func _schedule_next_turn() -> void:
	if _draining or _game_over or _handoff_pending or _in_ambush_mode:
		return
	if _state.pending_discard_count > 0:
		return  # wait for discard resolution before advancing
	if _state.pending_pet_sacrifice_player != "":
		return  # wait for pet sacrifice before advancing
	if _state.pending_equip_sacrifice_player != "":
		return  # wait for equipment sacrifice before advancing
	if _state.pending_unique_sacrifice_player != "":
		return  # wait for the Unique-duplicate sacrifice before advancing
	if _state.pending_form_sacrifice_player != "":
		return  # wait for the Form (1) sacrifice choice before advancing
	if _state.pending_form_return_player != "" or _in_form_return_mode:
		return  # wait for the Form pay-return choice before advancing
	if _state.pending_control_discard_player != "":
		return  # wait for the discard-or-give-control choice before advancing
	if _state.pending_reveal_pick_player != "":
		return  # wait for the reveal-and-pick quest choice before advancing
	if _state.pending_trigger_target_player != "":
		return  # wait for the Totem start-of-turn target choice before advancing
	if _state.pending_death_target_player != "":
		return  # wait for the Boneshanks death-trigger target choice before advancing
	if StackResolver._quest_choice_pending(_state) or _in_quest_choice_mode:
		return  # wait for the quest reward choice / its sub-picks before advancing
	if _state.pending_ready_player != "":
		return  # wait for the ready-on-attack choice (Windseer Tarus) before advancing
	if _state.pending_strike_ready_player != "" or _in_strike_ready_mode:
		return  # wait for the ready-on-strike choice (Windfury Weapon) before advancing
	if _state.pending_attack_exhaust_player != "":
		return  # wait for the attack-exhaust choice (Chops / Voss) before advancing
	if _state.pending_whelp_bounce_player != "":
		return  # wait for the Green Whelp Armor bounce choice before advancing
	if _state.pending_prevention_player != "" or _in_prevention_mode:
		return  # wait for the armor-prevention choice (717.2c) before advancing
	if _in_ally_exhaust_mode:
		return  # wait for the quest ally-exhaust cost picker (The Love Potion)
	var pid := _state.priority_player
	var pid_type := _p1_type if pid == "p1" else _p2_type
	# Auto-drive AI players AND, in hotseat, the off-screen human (auto-pass).
	var auto_driven := pid_type != "human" or (_hotseat and pid != _local_player)
	if auto_driven \
			and not _ai_timer.time_left > 0 \
			and not _state.in_protect_point \
			and not _in_protect_mode \
			and _state.pending_strike_player == "" \
			and not _in_strike_mode \
			and _state.pending_ready_player == "" \
			and not _in_ready_mode \
			and _state.pending_strike_ready_player == "" \
			and not _in_strike_ready_mode:
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


# SUSPENDED (2026-08-13): Layer 2, the mode-independent "nothing changed"
# auto-pass in _drain_passes — it skipped the human's priority window whenever
# the chain top wasn't a new opponent link and no combat-window transition had
# happened. That was convenient while few instants existed; now that responses
# matter, every window is held so the player can act. The code is deliberately
# kept (not deleted) so Turbo mode can switch it back on later — flip this to
# true, or make it read a Turbo flag. Layers 3/`_maybe_turbo_pass`/`_do_turbo_pass`
# already only fire under Turbo or a wrap-up burst, so they are untouched.
const LAYER2_NOTHING_CHANGED_AUTOPASS := false

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
		if _handoff_pending or _in_ambush_mode:
			break
		if _game_over or _state.in_protect_point or _in_protect_mode \
				or _state.pending_strike_player != "" or _in_strike_mode \
				or _state.pending_ready_player != "" or _in_ready_mode \
				or _state.pending_strike_ready_player != "" or _in_strike_ready_mode \
				or _state.pending_attack_exhaust_player != "" \
				or _state.pending_prevention_player != "" or _in_prevention_mode \
				or _in_ally_exhaust_mode:
			break
		if _state.pending_discard_count > 0 or _state.pending_pet_sacrifice_player != "" \
				or _state.pending_equip_sacrifice_player != "" \
				or _state.pending_unique_sacrifice_player != "" \
				or _state.pending_form_sacrifice_player != "" \
				or _state.pending_form_return_player != "" or _in_form_return_mode \
				or _state.pending_control_discard_player != "" \
				or _state.pending_reveal_pick_player != "" \
				or _state.pending_trigger_target_player != "" \
				or _state.pending_death_target_player != "" \
				or StackResolver._quest_choice_pending(_state) \
				or _in_quest_choice_mode \
				or _state.pending_whelp_bounce_player != "":
			_wrap_up_active = false
			break
		var in_combat     := _state.combat_attack_window or _state.combat_defend_window
		var chain_pending := not _state.pending_actions.is_empty()
		if not in_combat and not chain_pending:
			break
		var pid := _state.priority_player
		var pid_type := _p1_type if pid == "p1" else _p2_type
		var events: Array[GameEvent] = []
		if pid_type == "human" and _hotseat and pid != _local_player:
			# Hotseat off-screen human: auto-pass (hand hidden), unless Ambush
			# stance + a legal instant response — then stop the window for them.
			if _stance.get(pid, "ambush") == "ambush" and _offscreen_has_play(pid):
				_enter_ambush_mode(pid)
				break
			events = StackResolver.pass_priority(_state, _db)
		elif pid_type == "human":
			# Turbo auto-passes the human's own just-added top chain link even when they
			# hold a legal instant (LIFO — they'll regain priority if the opponent reacts).
			var owns_top := _player_owns_top_of_chain(pid)
			# C one-shot: auto-pass this player's combat windows until the opponent
			# responds. An opponent link on the chain (not owned by us) means they
			# played something → stop, clear the flag, and hand control back.
			if _auto_pass_combat and pid == _local_player:
				if chain_pending and not owns_top:
					_auto_pass_combat = false
					break
				if not (in_combat or owns_top):
					_auto_pass_combat = false
					break
				_mark_priority_info_seen()
				events = StackResolver.pass_priority(_state, _db)
			elif LAYER2_NOTHING_CHANGED_AUTOPASS and not owns_top \
					and not _human_has_new_info(pid):
				# Layer 2 (mode-independent "nothing changed" auto-pass): the chain
				# top isn't a new opponent link and no combat window transition
				# happened since we last looked. The engine still requires the
				# pass, there's just nothing new to prompt the human about —
				# so auto-pass regardless of Turbo/Tactical.
				_mark_priority_info_seen()
				events = StackResolver.pass_priority(_state, _db)
			elif not owns_top and (_turbo_mode or _wrap_up_active) \
					and not _router.has_any_legal_play(true):
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
	if _draining or _handoff_pending or not (_turbo_mode or _wrap_up_active) \
			or not _state or not _router:
		return
	if _in_protect_mode:
		return
	if _state.pending_discard_count > 0:
		_wrap_up_active = false
		return
	if _state.pending_pet_sacrifice_player != "":
		_wrap_up_active = false
		return
	if _state.pending_unique_sacrifice_player != "":
		_wrap_up_active = false
		return
	if _state.pending_control_discard_player != "":
		_wrap_up_active = false
		return
	if _state.priority_player != _local_player or _type_of(_local_player) != "human":
		return
	# Post-handoff hold: the incoming hotseat player was handed the screen FOR
	# this end-phase window (play instants with leftover resources) — never
	# auto-pass it. Cleared when they pass or the phase moves on.
	if _stop_for_end_window and _state.phase == "end" \
			and _state.pending_actions.is_empty():
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
	if not _human_has_new_info(_local_player) or phase == "ready" or phase == "draw" \
			or _player_owns_top_of_chain(_local_player):
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
		if top != null and top.source_player != _local_player \
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
	# With the layer-2 "nothing changed" auto-pass suspended, a window is also
	# held when nothing new happened — name the window rather than "unknown".
	if _state.combat_defend_window:
		return "defend window"
	if _state.combat_attack_window:
		return "attack window"
	if not _state.pending_actions.is_empty():
		return "chain response window"
	return "priority window"


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
	if not _state or _state.priority_player != _local_player \
			or _state.turn_player != _local_player:
		return false
	if _state.pending_control_discard_player == _local_player \
			or _state.pending_pet_sacrifice_player == _local_player \
			or _state.pending_equip_sacrifice_player == _local_player \
			or _state.pending_unique_sacrifice_player == _local_player:
		return false
	if not _state.pending_actions.is_empty():
		return false
	if _state.combat_attack_window or _state.combat_defend_window or _state.in_protect_point:
		return false
	return _state.phase == "action" or _state.phase == "end"


# True when the human currently holds priority in one of their own combat
# windows — the moment pressing C to auto-pass the rest of combat makes sense.
func _can_auto_pass_combat() -> bool:
	return _state != null and _type_of(_local_player) == "human" \
		and _state.priority_player == _local_player \
		and (_state.combat_attack_window or _state.combat_defend_window)


# The LOCAL human's own main action window (chain empty, no combat).
func _is_p1_main_action_window() -> bool:
	return _state.phase == "action" \
		and _state.turn_player == _local_player \
		and _state.pending_actions.is_empty() \
		and not _state.combat_attack_window \
		and not _state.combat_defend_window \
		and not _state.in_protect_point


func _is_opponent_action_window() -> bool:
	return _state.phase == "action" \
		and _state.turn_player != _local_player \
		and _state.pending_actions.is_empty() \
		and not _state.combat_attack_window \
		and not _state.combat_defend_window \
		and not _state.in_protect_point


func _do_turbo_pass() -> void:
	if not (_turbo_mode or _wrap_up_active) or not _state or not _router or _handoff_pending:
		return
	if _state.priority_player != _local_player or _type_of(_local_player) != "human":
		return
	var phase := _state.phase
	# Re-check at fire time — state may have changed since the deferred was scheduled.
	if _stop_for_end_window and phase == "end" and _state.pending_actions.is_empty():
		return   # held wrap-up window for the just-seated hotseat player
	if _is_p1_main_action_window():
		_wrap_up_active = false
		return
	# Hold only when something changed AND you have a legal response. With no
	# legal play, Turbo passes through even on new info (its "auto-pass all
	# 'no legal play'" contract) — matching Layer 3 in _drain_passes.
	if _human_has_new_info(_local_player) and _router.has_any_legal_play() \
			and phase != "ready" and phase != "draw" \
			and not _player_owns_top_of_chain(_local_player):
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
	# The prompt window has no toggle button — a prompt IS the reason to show it,
	# and an empty one is just a panel over the board.
	if _turn_info_window and is_instance_valid(_turn_info_window):
		_set_window_open(_turn_info_window, text != "")


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
