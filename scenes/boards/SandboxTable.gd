extends Control

const CARD_SCENE  = preload("res://scenes/elements/Card.tscn")
const CARD_ASPECT = 5.0 / 7.0
const CARD_FILL   = 0.95
const ZOOM_MIN    = 0.4
const ZOOM_MAX    = 3.0
const ZOOM_SPEED  = 0.1

enum MenuAction { PLAY_BOARD, PLACE_RESOURCE, SEND_GRAVEYARD, RETURN_HAND, EXHAUST, READY, GENERATE_CARD, DEAL_DAMAGE, RANDOMIZE_HERO, RESET_HERO_HEALTH }

@onready var card_inspector:   TextureRect   = $CardInspector
@onready var game_log:         Control       = $GameLog
@onready var turn_label:       Label         = $TurnPanel/TurnLabel
@onready var end_turn_btn:     Button        = $TurnPanel/EndTurnButton
@onready var end_game_dialog:  Control       = $EndGameDialog
@onready var setup_panel:      Control       = $SetupPanel
@onready var mulligan_panel_p1:  Control = $MulliganPanelP1
@onready var mulligan_panel_p2:  Control = $MulliganPanelP2
@onready var camera_container: Control       = $CameraContainer
@onready var game_manager:     Node          = $GameManager
@onready var hand_area:        Control       = $CameraContainer/Board/HandArea
@onready var ally_row_area:    Control       = $CameraContainer/Board/PlayerArea/PlayZones/AllyRow
@onready var hero_equip_area:  Control       = $CameraContainer/Board/PlayerArea/PlayZones/HeroEquipRow
@onready var resource_area:    Control       = $CameraContainer/Board/PlayerArea/PlayZones/ResourceRow
@onready var hand_container:   HBoxContainer = $CameraContainer/Board/HandArea/HandContainer
@onready var ally_row:         HBoxContainer = $CameraContainer/Board/PlayerArea/PlayZones/AllyRow/Cards
@onready var hero_equip_row:   HBoxContainer = $CameraContainer/Board/PlayerArea/PlayZones/HeroEquipRow/Cards
@onready var resource_row:     HBoxContainer = $CameraContainer/Board/PlayerArea/PlayZones/ResourceRow/Cards
@onready var right_column:     Control       = $CameraContainer/Board/PlayerArea/RightColumn
@onready var hero_slot:        ColorRect     = $CameraContainer/Board/PlayerArea/RightColumn/HeroSlot
@onready var deck_slot:        ColorRect     = $CameraContainer/Board/PlayerArea/RightColumn/DeckSlot
@onready var grav_slot:        ColorRect     = $CameraContainer/Board/PlayerArea/RightColumn/GraveyardSlot
@onready var opp_right_column:  Control       = $CameraContainer/Board/OpponentArea/OpponentRightColumn
@onready var opp_hero_slot:     ColorRect     = $CameraContainer/Board/OpponentArea/OpponentRightColumn/OpponentHeroSlot
@onready var opp_deck_slot:     ColorRect     = $CameraContainer/Board/OpponentArea/OpponentRightColumn/OpponentDeckSlot
@onready var opp_grav_slot:     ColorRect     = $CameraContainer/Board/OpponentArea/OpponentRightColumn/OpponentGraveyardSlot
@onready var opp_hand_area:     Control       = $CameraContainer/Board/OpponentHand
@onready var opp_ally_row_area: Control       = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentAllyRow
@onready var opp_hero_area:     Control       = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentHeroEquipRow
@onready var opp_resource_area: Control       = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentResourceRow
@onready var opp_hand_container: HBoxContainer = $CameraContainer/Board/OpponentHand/OpponentHandContainer
@onready var opp_ally_row:      HBoxContainer = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentAllyRow/Cards
@onready var opp_hero_equip_row: HBoxContainer = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentHeroEquipRow/Cards
@onready var opp_resource_row:  HBoxContainer = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentResourceRow/Cards

# Pile slots: cards stacked face-up (graveyard) or face-down (deck)
var _pile_slots: Array = []

# Hero cards currently in play
var _p1_hero: Control = null
var _p2_hero: Control = null

# Mulligan / turn tracking
var _p1_mulliganed: bool = false
var _p2_mulliganed: bool = false
var _p1_ready:      bool = false
var _p2_ready:      bool = false
var _first_turn_skip: String = ""  # whichever player goes first skips turn-1 draw

# Violation resolution
var _violation_cards:    Array    = []
var _violation_overlays: Array    = []  # [[ColorRect, Label], ...]
var _violation_callback: Callable

# Combat targeting
var _attacker: Control = null
var _is_animating: bool = false
var _combat_canvas: CanvasLayer
var _combat_line: Line2D

# HP tooltip
var _hp_tooltip: Control
var _hp_label: RichTextLabel

# Resource counters
var _p1_counter_slot: ColorRect
var _p1_counter_label: Label
var _p2_counter_slot: ColorRect
var _p2_counter_label: Label

# Hero HP bars
const HP_BAR_WIDTH = 28.0
const HP_BAR_GAP   = 6.0
var _p1_hp_bg:    ColorRect
var _p1_hp_fill:  ColorRect
var _p1_hp_label: Label
var _p2_hp_bg:    ColorRect
var _p2_hp_fill:  ColorRect
var _p2_hp_label: Label

# Context menu
var context_menu: PopupMenu
var _context_card: Control = null
var _deck_menu_owner: String = ""
var _warn_dialog: AcceptDialog
var _x_dialog: ConfirmationDialog
var _x_pending_card: Control = null
var _game_over: bool = false

# ── Camera ────────────────────────────────────────────────────────────────────
func _make_counter_slot(parent: Control) -> ColorRect:
	var slot = ColorRect.new()
	slot.layout_mode = 0
	slot.color = Color(0.02, 0.08, 0.02, 1)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(slot)
	var label = Label.new()
	label.layout_mode = 1
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.text = "0"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(label)
	return slot

func _ensure_hero_hp_bar(card_owner: String) -> void:
	var has_bar = _p1_hp_bg if card_owner == "player_1" else _p2_hp_bg
	if has_bar:
		return
	var parent = right_column if card_owner == "player_1" else opp_right_column
	var bg = ColorRect.new()
	bg.layout_mode = 0
	bg.color = Color(0.5, 0.08, 0.08, 1)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)
	var fill = ColorRect.new()
	fill.layout_mode = 0
	fill.color = Color(0.15, 0.75, 0.15, 1)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(fill)
	var label = Label.new()
	label.layout_mode = 1
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(label)
	if card_owner == "player_1":
		_p1_hp_bg = bg
		_p1_hp_fill = fill
		_p1_hp_label = label
	else:
		_p2_hp_bg = bg
		_p2_hp_fill = fill
		_p2_hp_label = label

func _position_hero_hp_bar(card_owner: String, hero_rect: ColorRect) -> void:
	_ensure_hero_hp_bar(card_owner)
	var bg = _p1_hp_bg if card_owner == "player_1" else _p2_hp_bg
	bg.position = Vector2(hero_rect.position.x + hero_rect.size.x + HP_BAR_GAP, hero_rect.position.y)
	bg.size     = Vector2(HP_BAR_WIDTH, hero_rect.size.y)
	_update_hero_hp_bar(card_owner)

func _update_hero_hp_bar(card_owner: String) -> void:
	var hero = _p1_hero if card_owner == "player_1" else _p2_hero
	var bg    = _p1_hp_bg    if card_owner == "player_1" else _p2_hp_bg
	var fill  = _p1_hp_fill  if card_owner == "player_1" else _p2_hp_fill
	var label = _p1_hp_label if card_owner == "player_1" else _p2_hp_label
	if not bg:
		return
	if not is_instance_valid(hero):
		fill.size = Vector2.ZERO
		label.text = ""
		return
	var ratio = clamp(float(hero.current_health) / float(max(hero.max_health, 1)), 0.0, 1.0)
	var fill_h = bg.size.y * ratio
	fill.size     = Vector2(bg.size.x, fill_h)
	fill.position = Vector2(0, bg.size.y - fill_h)
	label.text = str(hero.current_health)

func _on_card_health_changed(card: Control) -> void:
	if card.card_type == "Hero":
		_update_hero_hp_bar(card.card_owner)

func _count_ready_resources(row: HBoxContainer) -> int:
	var count = 0
	for child in row.get_children():
		if child.has_method("exhaust") and not child.exhausted:
			count += 1
	return count

func _update_resource_counts() -> void:
	var p1 = _count_ready_resources(resource_row)
	var p2 = _count_ready_resources(opp_resource_row)
	game_manager.player1_resources = p1
	game_manager.player2_resources = p2
	if _p1_counter_label:
		_p1_counter_label.text = str(p1)
	if _p2_counter_label:
		_p2_counter_label.text = str(p2)

func _zoom(factor: float, mouse_pos: Vector2) -> void:
	var old_scale = camera_container.scale.x
	var new_scale = clamp(old_scale * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_scale, old_scale):
		return
	camera_container.position = mouse_pos - (mouse_pos - camera_container.position) * (new_scale / old_scale)
	camera_container.scale = Vector2(new_scale, new_scale)

func _reset_camera() -> void:
	camera_container.position = Vector2.ZERO
	camera_container.scale    = Vector2.ONE

# ── Card sizing ───────────────────────────────────────────────────────────────
func card_size_for_zone(zone: Control) -> Vector2:
	var h = zone.size.y * CARD_FILL
	return Vector2(h * CARD_ASPECT, h)

func slot_size_for_zone(zone: Control) -> Vector2:
	var h = zone.size.y * CARD_FILL
	return Vector2(h, h)

func _is_board_ally(card: Control) -> bool:
	return card.card_type == "Ally" and card.get_parent() in [ally_row, opp_ally_row]

func _is_valid_target(card: Control, attacker_owner: String) -> bool:
	var opp = "player_2" if attacker_owner == "player_1" else "player_1"
	var opp_row = opp_ally_row if opp == "player_2" else ally_row
	var opp_hero = _p2_hero if opp == "player_2" else _p1_hero
	if card.get_parent() != opp_row and card != opp_hero:
		return false
	return can_propose_defender(card)

# ── Rule-enforcement hooks ──────────────────────────────────────────────────────
# Sandbox imposes no rules beyond mechanical state (a card must be a board ally
# and not currently exhausted to be proposed as an attacker). DuelTable overrides
# these to add real legality (summoning sickness w/ Ferocity, Elusive, etc.).
func can_propose_attacker(_card: Control) -> bool:
	return true

func can_propose_defender(_card: Control) -> bool:
	return true

const DMG_ICONS = {
	"Arcane": "res://assets/dmg_icons/arcane.png",
	"Fire":   "res://assets/dmg_icons/fire.png",
	"Frost":  "res://assets/dmg_icons/frost.png",
	"Holy":   "res://assets/dmg_icons/holy.png",
	"Melee":  "res://assets/dmg_icons/melee.png",
	"Nature": "res://assets/dmg_icons/nature.png",
	"Ranged": "res://assets/dmg_icons/ranged.png",
	"Shadow": "res://assets/dmg_icons/shadow.png",
}

func _enter_targeting_mode(card: Control) -> void:
	_attacker = card
	var icon_path = DMG_ICONS.get(card.dmg_type, "")
	if icon_path:
		var tex = load(icon_path)
		if tex:
			Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() / 2.0)
	else:
		DisplayServer.cursor_set_shape(DisplayServer.CURSOR_CROSS)
	var atk_lbl = _combat_canvas.get_node("AtkLabel")
	atk_lbl.text = str(card.atk)
	atk_lbl.visible = true
	_combat_line.visible = true

func _exit_targeting_mode() -> void:
	_attacker = null
	Input.set_custom_mouse_cursor(null)
	_combat_line.visible = false
	_combat_canvas.get_node("ArrowHead").visible = false
	_combat_canvas.get_node("AtkLabel").visible = false

func _play_wiggle(attacker: Control, defender: Control) -> void:
	var start      = attacker.global_position
	var atk_center = start + attacker.size / 2.0
	var def_center = defender.global_position + defender.size / 2.0
	var direction  = (def_center - atk_center).normalized()
	var distance   = atk_center.distance_to(def_center)
	var punch_dist = distance * 0.5
	var tween = create_tween()
	tween.tween_property(attacker, "global_position", start + direction * punch_dist, 0.12)
	tween.tween_property(attacker, "global_position", start, 0.10)
	await tween.finished

func _spawn_damage_number(card: Control, amount: int) -> void:
	if amount <= 0:
		return
	var lbl = Label.new()
	lbl.text = "-%d" % amount
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color(1, 0.15, 0.15))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	var origin = card.global_position + card.size / 2.0 - Vector2(20, 14)
	lbl.position = origin
	lbl.size = Vector2(60, 36)
	_combat_canvas.add_child(lbl)
	var tween = create_tween()
	tween.tween_property(lbl, "position", origin + Vector2(0, -70), 1.2)
	tween.parallel().tween_property(lbl, "modulate:a", 0.0, 1.2)
	tween.tween_callback(lbl.queue_free)

func _resolve_combat(attacker: Control, defender: Control) -> void:
	_is_animating = true
	var atk_dmg = attacker.atk
	var def_dmg = defender.atk
	attacker.exhaust()
	_exit_targeting_mode()

	await _play_wiggle(attacker, defender)

	attacker.take_damage(def_dmg)
	defender.take_damage(atk_dmg)
	_spawn_damage_number(defender, atk_dmg)
	_spawn_damage_number(attacker, def_dmg)

	var atk_type = (" " + attacker.dmg_type) if atk_dmg > 0 and attacker.dmg_type else ""
	var def_type = (" " + defender.dmg_type) if def_dmg > 0 and defender.dmg_type else ""
	game_log.add_entry(
		"%s attacked %s — dealt %d%s damage / received %d%s damage" % [
			attacker.card_name, defender.card_name,
			atk_dmg, atk_type, def_dmg, def_type],
		"attack")
	_update_resource_counts()
	_is_animating = false

func _process(_delta: float) -> void:
	if _attacker:
		var mouse  = get_viewport().get_mouse_position()
		var start  = _attacker.global_position + _attacker.size / 2.0
		var dir    = (mouse - start).normalized()
		var head_size = 18.0
		var shaft_end = mouse - dir * head_size
		_combat_line.set_point_position(0, start)
		_combat_line.set_point_position(1, shaft_end)

		var on_target = _hovered_card != null and _is_valid_target(_hovered_card, _attacker.card_owner)
		var arrow_color = Color(0.2, 1.0, 0.2, 0.9) if on_target else Color(1.0, 0.4, 0.0, 0.9)
		_combat_line.default_color = arrow_color

		var perp = Vector2(-dir.y, dir.x) * (head_size * 0.5)
		var head = _combat_canvas.get_node("ArrowHead")
		head.color = arrow_color
		head.polygon = PackedVector2Array([mouse, shaft_end + perp, shaft_end - perp])
		head.visible = true

		# ATK label follows cursor, offset to bottom-right of icon
		var atk_lbl = _combat_canvas.get_node("AtkLabel")
		atk_lbl.position = mouse + Vector2(22, 18)

func _hand_owner_of(card: Control) -> String:
	return "player_1" if card.get_parent() == hand_container else "player_2"

func _available_resources(player: String) -> int:
	return game_manager.player1_resources if player == "player_1" else game_manager.player2_resources

func _can_afford(card: Control) -> bool:
	if card.cost < 0:  # free / X-cost cards
		return true
	return _available_resources(_hand_owner_of(card)) >= card.cost

func _warn_not_enough_resources(card: Control) -> void:
	var available = _available_resources(_hand_owner_of(card))
	_warn_dialog.dialog_text = (
		"Not enough resources to play %s.\nCost: %d  |  Available: %d" \
		% [card.card_name, card.cost, available]
	)
	_warn_dialog.popup_centered()

func _zone_for_container(container: Control) -> Control:
	var map = {
		hand_container:      hand_area,
		ally_row:            ally_row_area,
		hero_equip_row:      hero_equip_area,
		resource_row:        resource_area,
		opp_hand_container:  opp_hand_area,
		opp_ally_row:        opp_ally_row_area,
		opp_hero_equip_row:  opp_hero_area,
		opp_resource_row:    opp_resource_area,
	}
	return map.get(container, ally_row_area)

# Owner-aware zone helpers
func _ally_row_for(card_owner: String) -> HBoxContainer:
	return ally_row if card_owner == "player_1" else opp_ally_row

func _hand_for(card_owner: String) -> HBoxContainer:
	return hand_container if card_owner == "player_1" else opp_hand_container

func _grav_for(card_owner: String) -> ColorRect:
	return grav_slot if card_owner == "player_1" else opp_grav_slot

func _hand_area_for(card_owner: String) -> Control:
	return hand_area if card_owner == "player_1" else opp_hand_area

# ── Slot positioning ──────────────────────────────────────────────────────────
func _row_y_in_col(row: Control, col: Control) -> float:
	return row.global_position.y - col.global_position.y

func _position_slots() -> void:
	var hero_h = hero_equip_area.size.y
	var res_h  = resource_area.size.y

	var hero_card   = card_size_for_zone(hero_equip_area)
	var res_card    = card_size_for_zone(resource_area)
	var hero_slot_w = hero_card.x
	var hero_slot_h = hero_card.y
	var res_slot_w  = res_card.x
	var res_slot_h  = res_card.y

	var col_w = max(hero_slot_w + HP_BAR_GAP + HP_BAR_WIDTH, res_slot_w * 2.0 + 8.0)
	right_column.custom_minimum_size.x     = col_w
	opp_right_column.custom_minimum_size.x = col_w

	var hero_row_y     = _row_y_in_col(hero_equip_area, right_column)
	var res_row_y      = _row_y_in_col(resource_area,   right_column)
	var opp_res_area   = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentResourceRow
	var opp_hero_area  = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentHeroEquipRow
	var opp_res_row_y  = _row_y_in_col(opp_res_area,  opp_right_column)
	var opp_hero_row_y = _row_y_in_col(opp_hero_area, opp_right_column)

	hero_slot.position = Vector2(0,                hero_row_y + (hero_h - hero_slot_h) / 2.0)
	hero_slot.size     = Vector2(hero_slot_w,      hero_slot_h)
	deck_slot.position = Vector2(0,                res_row_y  + (res_h  - res_slot_h)  / 2.0)
	deck_slot.size     = Vector2(res_slot_w,       res_slot_h)
	grav_slot.position = Vector2(res_slot_w + 8.0, res_row_y  + (res_h  - res_slot_h)  / 2.0)
	grav_slot.size     = Vector2(res_slot_w,       res_slot_h)

	opp_deck_slot.position = Vector2(0,                opp_res_row_y  + (res_h  - res_slot_h)  / 2.0)
	opp_deck_slot.size     = Vector2(res_slot_w,       res_slot_h)
	opp_grav_slot.position = Vector2(res_slot_w + 8.0, opp_res_row_y  + (res_h  - res_slot_h)  / 2.0)
	opp_grav_slot.size     = Vector2(res_slot_w,       res_slot_h)
	opp_hero_slot.position = Vector2(0,                opp_hero_row_y + (hero_h - hero_slot_h) / 2.0)
	opp_hero_slot.size     = Vector2(hero_slot_w,      hero_slot_h)

	_position_hero_hp_bar("player_1", hero_slot)
	_position_hero_hp_bar("player_2", opp_hero_slot)

	_pile_slots = [grav_slot, deck_slot, opp_grav_slot, opp_deck_slot]

	deck_slot.gui_input.connect(func(e): _on_deck_gui_input(e, "player_1"))
	opp_deck_slot.gui_input.connect(func(e): _on_deck_gui_input(e, "player_2"))

	# Resource counter slots — same size as deck slot, centered in ally-level empty space
	var slot_w = deck_slot.size.x
	var slot_h = deck_slot.size.y
	var row_h  = ally_row_area.size.y  # all rows are equal height

	_p1_counter_slot = _make_counter_slot(right_column)
	_p1_counter_label = _p1_counter_slot.get_child(0)
	_p1_counter_slot.size = Vector2(slot_w, slot_h)
	_p1_counter_slot.position = Vector2(deck_slot.position.x, (row_h - slot_h) / 2.0)

	_p2_counter_slot = _make_counter_slot(opp_right_column)
	_p2_counter_label = _p2_counter_slot.get_child(0)
	_p2_counter_slot.size = Vector2(slot_w, slot_h)
	var p2_start = opp_hero_slot.position.y + opp_hero_slot.size.y
	_p2_counter_slot.position = Vector2(opp_deck_slot.position.x, p2_start + (row_h - slot_h) / 2.0)

# ── Ready ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	setup_panel.confirmed.connect(_on_setup_confirmed)

	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	mulligan_panel_p1.get_node("VBox/MulliganBtn").pressed.connect(func(): _mulligan("player_1"))
	mulligan_panel_p1.get_node("VBox/ReadyBtn").pressed.connect(func(): _set_ready("player_1"))
	mulligan_panel_p2.get_node("VBox/MulliganBtn").pressed.connect(func(): _mulligan("player_2"))
	mulligan_panel_p2.get_node("VBox/ReadyBtn").pressed.connect(func(): _set_ready("player_2"))
	end_game_dialog.rematch_requested.connect(_on_rematch)
	end_game_dialog.new_game_requested.connect(_on_new_game)
	end_game_dialog.quit_requested.connect(func(): get_tree().quit())

	context_menu = PopupMenu.new()
	add_child(context_menu)
	context_menu.id_pressed.connect(_on_context_menu_id_pressed)

	_warn_dialog = AcceptDialog.new()
	_warn_dialog.title = "Cannot play card"
	add_child(_warn_dialog)

	_x_dialog = ConfirmationDialog.new()
	_x_dialog.title = "Choose X"
	var vbox = VBoxContainer.new()
	_x_dialog.add_child(vbox)
	var lbl = Label.new()
	lbl.name = "Desc"
	vbox.add_child(lbl)
	var spin = SpinBox.new()
	spin.name = "Spin"
	spin.min_value = 0
	spin.max_value = 99
	spin.step = 1
	vbox.add_child(spin)
	_x_dialog.confirmed.connect(_on_x_confirmed)
	add_child(_x_dialog)

	_combat_canvas = CanvasLayer.new()
	_combat_canvas.layer = 10
	add_child(_combat_canvas)
	_combat_line = Line2D.new()
	_combat_line.width = 3.0
	_combat_line.default_color = Color(1.0, 0.4, 0.0, 0.9)
	_combat_line.add_point(Vector2.ZERO)
	_combat_line.add_point(Vector2.ZERO)
	_combat_line.visible = false
	_combat_canvas.add_child(_combat_line)
	var head = Polygon2D.new()
	head.color = Color(1.0, 0.4, 0.0, 0.9)
	head.name = "ArrowHead"
	_combat_canvas.add_child(head)

	var atk_lbl = Label.new()
	atk_lbl.name = "AtkLabel"
	atk_lbl.add_theme_font_size_override("font_size", 26)
	atk_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.3))
	atk_lbl.add_theme_constant_override("outline_size", 4)
	atk_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	atk_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	atk_lbl.visible = false
	_combat_canvas.add_child(atk_lbl)

	_hp_tooltip = ColorRect.new()
	_hp_tooltip.color = Color(0.05, 0.05, 0.05, 0.9)
	_hp_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_tooltip.visible = false
	_hp_tooltip.z_index = 101
	add_child(_hp_tooltip)
	var rtl = RichTextLabel.new()
	rtl.layout_mode = 1
	rtl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rtl.bbcode_enabled = true
	rtl.fit_content = false
	rtl.scroll_active = false
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rtl.add_theme_font_size_override("normal_font_size", 18)
	_hp_tooltip.add_child(rtl)
	_hp_label = rtl

	# Layout must settle before _init_game can measure zones
	camera_container.size = get_viewport_rect().size
	await get_tree().process_frame
	await get_tree().process_frame
	_position_slots()

func _place_card_in_zone(card_id: String, container: HBoxContainer, card_owner: String, face_down: bool = false) -> Control:
	var db   = game_manager.card_database
	var zone = _zone_for_container(container)
	var card = CARD_SCENE.instantiate()
	card.set_display_size(slot_size_for_zone(zone))
	container.add_child(card)
	card.setup(card_id, db)
	card.card_owner = card_owner
	if face_down:
		card.set_face_down(true)
	card.card_right_clicked.connect(_on_card_right_clicked)
	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)
	card.card_died.connect(_on_card_died)
	card.card_clicked.connect(_on_card_clicked)
	game_manager.board.append(card)
	return card

func _init_board() -> void:
	pass  # Board starts clean — cards enter play through normal game actions

func _hero_slot_for(card_owner: String) -> ColorRect:
	return hero_slot if card_owner == "player_1" else opp_hero_slot

func _randomize_deck_for_player(card_owner: String) -> void:
	var deck = game_manager.deck_manager.random_deck_maker(game_manager.card_database)
	if card_owner == "player_1":
		game_manager.player1_deck = deck
		game_manager.player1_draw_pile = deck.to_draw_pile()
	else:
		game_manager.player2_deck = deck
		game_manager.player2_draw_pile = deck.to_draw_pile()
	_place_hero(card_owner, deck.hero_id)

func _place_hero(card_owner: String, hero_id: String = "") -> void:
	var db = game_manager.card_database
	if hero_id == "":
		var heroes = db._db.keys().filter(func(id): return db._db[id]["type"] == "Hero")
		if heroes.is_empty():
			return
		hero_id = heroes[randi() % heroes.size()]
	var slot = _hero_slot_for(card_owner)
	var existing = _p1_hero if card_owner == "player_1" else _p2_hero
	if is_instance_valid(existing):
		existing.queue_free()
	var card_id = hero_id
	var card = CARD_SCENE.instantiate()
	card.layout_mode = 0
	card.position = Vector2.ZERO
	slot.add_child(card)
	card.setup(card_id, db)
	card.card_owner = card_owner
	card.set_display_size(slot.size)
	card.card_clicked.connect(_on_card_clicked)
	card.card_right_clicked.connect(_on_card_right_clicked)
	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)
	card.card_died.connect(_on_card_died)
	card.health_changed.connect(_on_card_health_changed)
	if card_owner == "player_1":
		_p1_hero = card
	else:
		_p2_hero = card
	_update_hero_hp_bar(card_owner)

func _spawn_card(card_id: String, db: Node, card_owner: String,
		container: Control, zone_area: Control) -> Control:
	var card = CARD_SCENE.instantiate()
	card.set_display_size(card_size_for_zone(zone_area))
	container.add_child(card)
	card.setup(card_id, db)
	card.card_owner = card_owner
	card.card_clicked.connect(_on_card_clicked)
	card.card_right_clicked.connect(_on_card_right_clicked)
	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)
	card.card_died.connect(_on_card_died)
	return card

func _on_card_died(card: Control) -> void:
	if card.card_type == "Hero":
		var winner = "player_2" if card.card_owner == "player_1" else "player_1"
		_end_game(winner)
		return
	card.ready_card()
	game_log.add_entry("%s died and was sent to the graveyard" % card.card_name, "death")
	move_card(card, _grav_for(card.card_owner))

# ── End game ──────────────────────────────────────────────────────────────────

func _end_game(winner: String) -> void:
	_game_over = true
	if winner == "player_1":
		game_manager.player1_wins += 1
	else:
		game_manager.player2_wins += 1
	game_log.add_entry("%s wins the game!" % _player_name(winner), "death")
	end_game_dialog.show_result(
		_player_name(winner),
		game_manager.player1_wins,
		game_manager.player2_wins)

func _clear_all_cards() -> void:
	var containers = [
		hand_container, opp_hand_container,
		ally_row, opp_ally_row,
		hero_equip_row, opp_hero_equip_row,
		resource_row, opp_resource_row,
		grav_slot, opp_grav_slot,
		deck_slot, opp_deck_slot,
	]
	for c in containers:
		for child in c.get_children():
			if child.get("card_id") != null:  # only free Card instances, not tscn Labels
				child.queue_free()
	if is_instance_valid(_p1_hero): _p1_hero.queue_free()
	if is_instance_valid(_p2_hero): _p2_hero.queue_free()
	_p1_hero = null
	_p2_hero = null
	_update_hero_hp_bar("player_1")
	_update_hero_hp_bar("player_2")
	game_manager.hand.clear()
	game_manager.board.clear()

func _on_rematch() -> void:
	# Same player settings, new random decks — skip setup panel
	end_game_dialog.visible = false
	_init_game()

func _on_new_game() -> void:
	# Back to setup to change Human/AI settings
	end_game_dialog.visible = false
	setup_panel.visible = true
	mulligan_panel_p2.get_node("VBox/ReadyBtn").disabled = false
	_randomize_first_player()
	_update_turn_ui()
	game_log.add_entry("--- Rematch ---", "default")

# ── Input ─────────────────────────────────────────────────────────────────────
var _hovered_card: Control = null

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if _attacker:
			_exit_targeting_mode()

func _input(event: InputEvent) -> void:
	# Ctrl+Space ends the current human turn (TTS-style shortcut)
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE and event.ctrl_pressed:
		if end_turn_btn.visible and not end_turn_btn.disabled:
			var current_is_ai = game_manager.player1_is_ai if game_manager.turn_state == GameManager.TurnState.P1 \
				else game_manager.player2_is_ai
			if not current_is_ai:
				_on_end_turn_pressed()
				get_viewport().set_input_as_handled()
		return

	# Violation mode: number keys select candidate
	if _violation_cards.size() > 0 and event is InputEventKey and event.pressed:
		var idx = event.keycode - KEY_1
		if idx >= 0 and idx < _violation_cards.size():
			_resolve_violation(_violation_cards[idx])
			get_viewport().set_input_as_handled()
			return

	if _attacker and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_exit_targeting_mode()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(1.0 + ZOOM_SPEED, event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(1.0 - ZOOM_SPEED, event.position)

	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		camera_container.position += event.relative

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_R:
				_reset_camera()
			KEY_ALT:
				if _hovered_card:
					_show_inspector(_hovered_card)
			KEY_CTRL:
				if _hovered_card:
					_show_hp_tooltip(_hovered_card)
	if event is InputEventKey and not event.pressed:
		match event.keycode:
			KEY_ALT:  card_inspector.visible = false
			KEY_CTRL: _hp_tooltip.visible = false

# ── Inspector ─────────────────────────────────────────────────────────────────
func _show_inspector(card: Control) -> void:
	if not card.card_image.texture:
		return
	card_inspector.texture = card.card_image.texture
	var mouse      = get_global_mouse_position()
	var panel_size = card_inspector.size
	var vp_size    = get_viewport_rect().size
	card_inspector.position = Vector2(
		clamp(mouse.x + 20, 0, vp_size.x - panel_size.x),
		clamp(mouse.y - panel_size.y / 2.0, 0, vp_size.y - panel_size.y)
	)
	card_inspector.visible = true

func _race_of(card: Control) -> String:
	# tags holds "Race Class" (e.g. "Human Mage") or just "Race" for class-less beasts
	if card.card_class != "" and card.tags.ends_with(card.card_class):
		return card.tags.substr(0, card.tags.length() - card.card_class.length()).strip_edges()
	return card.tags.strip_edges()

func _show_hp_tooltip(card: Control) -> void:
	if card.card_type not in ["Ally", "Hero"]:
		return
	var full_hp = card.current_health >= card.max_health
	var hp_color = "white" if full_hp else "#ff3333"

	var keywords: Array = []
	var race = _race_of(card)
	if race != "":
		keywords.append(race)
	if card.card_class != "":
		keywords.append(card.card_class)
	var keywords_text = ", ".join(keywords) if not keywords.is_empty() else "-"

	_hp_label.text = "[center]Atk: %d\nHP: [color=%s]%d[/color] / %d\n%s[/center]" % \
		[card.atk, hp_color, card.current_health, card.max_health, keywords_text]
	var mouse = get_global_mouse_position()
	_hp_tooltip.size = Vector2(220, 90)
	var vp = get_viewport_rect().size
	_hp_tooltip.position = Vector2(
		clamp(mouse.x - 110, 0, vp.x - 220),
		clamp(mouse.y - 100, 0, vp.y - 90))
	_hp_tooltip.visible = true

func _on_card_hovered(card: Control) -> void:
	_hovered_card = card
	if Input.is_key_pressed(KEY_ALT):
		_show_inspector(card)
	if Input.is_key_pressed(KEY_CTRL):
		_show_hp_tooltip(card)

func _on_card_unhovered() -> void:
	_hovered_card = null
	card_inspector.visible = false
	_hp_tooltip.visible = false

# ── Card movement ─────────────────────────────────────────────────────────────

# Move a card to target_container.
# Legality checks happen before this call — this function always executes the move.
func move_card(card: Control, target: Control) -> void:
	var is_hand = target in [hand_container, opp_hand_container]
	var is_pile = target in _pile_slots
	var is_graveyard = target in [grav_slot, opp_grav_slot]

	# Allies reset to their printed HP when leaving play to hand/graveyard (clears any
	# in-play max_health buffs/debuffs too). Does NOT apply to a future "removed from
	# game" zone, where allies should keep their current HP — add that zone to a
	# separate check, not to this one, if/when it's implemented.
	if card.card_type == "Ally" and (is_hand or is_graveyard):
		card.reset_to_printed_hp()

	game_manager.hand.erase(card)
	game_manager.board.erase(card)
	if is_hand:
		game_manager.hand.append(card)
		card.set_face_down(false)  # always face-up in hand
	else:
		game_manager.board.append(card)

	# TODO: play movement animation here before reparenting

	card.reparent(target)

	# After a card enters a row container, re-apply rotation on any exhausted siblings
	# (the container re-sorts positions which can visually reset rotation without NOTIFICATION_RESIZED)
	if target is HBoxContainer:
		for sibling in target.get_children():
			if sibling != card and sibling.get("exhausted") == true:
				sibling.pivot_offset = sibling.size / 2.0
				sibling.rotation_degrees = 90.0

	# Summoning sickness: only applies to allies played as allies (not as face-down resources)
	var ally_zones = [ally_row, opp_ally_row]
	if target in ally_zones and card.card_type == "Ally" and not card.face_down:
		card.set_just_summoned(true)
	_update_resource_counts()

	if is_pile:
		# Pile layout: manually position, size to fill slot
		card.layout_mode = 0
		card.position = Vector2.ZERO
		card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		card.set_display_size(target.size)
	elif is_hand:
		card.set_display_size(card_size_for_zone(_hand_area_for(card.card_owner)))
	else:
		card.set_display_size(slot_size_for_zone(_zone_for_container(target)))

# ── Context menu ──────────────────────────────────────────────────────────────
func _get_card_location(card: Control) -> String:
	var p = card.get_parent()
	if p in [hand_container, opp_hand_container]:
		return "hand"
	if p in [ally_row, hero_equip_row, resource_row, opp_ally_row, opp_hero_equip_row, opp_resource_row]:
		return "board"
	if p in _pile_slots:
		return "pile"
	return "unknown"

func _on_card_right_clicked(card: Control) -> void:
	_context_card = card
	context_menu.clear()

	if _attacker:
		_exit_targeting_mode()
		return

	if card.card_type == "Hero":
		context_menu.add_item("Deal 1 damage", MenuAction.DEAL_DAMAGE)
		context_menu.add_item("Randomize Hero", MenuAction.RANDOMIZE_HERO)
		context_menu.add_item("Reset Hero Health", MenuAction.RESET_HERO_HEALTH)
		if context_menu.item_count > 0:
			context_menu.position = Vector2i(get_viewport().get_mouse_position())
			context_menu.reset_size()
			context_menu.popup()
		return

	match _get_card_location(card):
		"hand":
			context_menu.add_item("Play", MenuAction.PLAY_BOARD)
			context_menu.add_item("Place as resource (face down)", MenuAction.PLACE_RESOURCE)
			context_menu.add_item("Send to graveyard", MenuAction.SEND_GRAVEYARD)
		"board":
			if not card.exhausted:
				context_menu.add_item("Exhaust", MenuAction.EXHAUST)
			else:
				context_menu.add_item("Ready", MenuAction.READY)
			if card.card_type == "Ally":
				context_menu.add_item("Deal 1 damage", MenuAction.DEAL_DAMAGE)
			context_menu.add_item("Send to graveyard", MenuAction.SEND_GRAVEYARD)
			context_menu.add_item("Return to hand", MenuAction.RETURN_HAND)
		"pile":
			context_menu.add_item("Return to hand", MenuAction.RETURN_HAND)

	if context_menu.item_count == 0:
		return
	context_menu.position = Vector2i(get_viewport().get_mouse_position())
	context_menu.reset_size()
	context_menu.popup()

func _on_deck_gui_input(event: InputEvent, card_owner: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_deck_menu_owner = card_owner
		_context_card = null
		context_menu.clear()
		context_menu.add_item("Draw a card", MenuAction.GENERATE_CARD)
		context_menu.position = Vector2i(get_viewport().get_mouse_position())
		context_menu.reset_size()
		context_menu.popup()

func _draw_card(card_owner: String) -> void:
	var pile = game_manager.player1_draw_pile if card_owner == "player_1" else game_manager.player2_draw_pile
	if pile.is_empty():
		game_log.add_entry("%s has no cards left to draw!" % _player_name(card_owner), "death")
		return
	var card_id = pile.pop_back()
	var db = game_manager.card_database
	var card = _spawn_card(card_id, db, card_owner, _hand_for(card_owner), _hand_area_for(card_owner))
	game_manager.hand.append(card)
	_update_deck_labels()
	game_log.add_entry("%s drew %s" % [_player_name(card_owner), db._db[card_id].get("name", card_id)], "play")

func _update_deck_labels() -> void:
	var p1 = game_manager.player1_draw_pile.size()
	var p2 = game_manager.player2_draw_pile.size()
	var p1_lbl = deck_slot.get_child(0) as Label
	var p2_lbl = opp_deck_slot.get_child(0) as Label
	if p1_lbl: p1_lbl.text = "Deck\n%d" % p1
	if p2_lbl: p2_lbl.text = "Deck\n%d" % p2

func _on_context_menu_id_pressed(id: int) -> void:
	if id == MenuAction.GENERATE_CARD:
		_draw_card(_deck_menu_owner)
		_deck_menu_owner = ""
		return
	if not _context_card:
		return
	var o = _context_card.card_owner
	match id:
		MenuAction.PLAY_BOARD:
			_play_card(_context_card)
		MenuAction.PLACE_RESOURCE:
			_context_card.set_face_down(true)
			move_card(_context_card, opp_resource_row if o == "player_2" else resource_row)
		MenuAction.EXHAUST:
			_context_card.exhaust()
			_update_resource_counts()
		MenuAction.READY:
			_context_card.ready_card()
			_update_resource_counts()
		MenuAction.DEAL_DAMAGE:
			_context_card.take_damage(1)
		MenuAction.RANDOMIZE_HERO:
			_randomize_deck_for_player(_context_card.card_owner)
		MenuAction.RESET_HERO_HEALTH:
			_context_card.reset_to_printed_hp()
		MenuAction.SEND_GRAVEYARD:
			_context_card.ready_card()
			move_card(_context_card, _grav_for(o))
		MenuAction.RETURN_HAND:
			_context_card.ready_card()
			move_card(_context_card, _hand_for(o))
		MenuAction.GENERATE_CARD:
			_draw_card(_deck_menu_owner)
	_context_card = null
	_deck_menu_owner = ""

# ── Card actions ──────────────────────────────────────────────────────────────
func _player_name(owner: String) -> String:
	return "Player 1" if owner == "player_1" else "Player 2"

func _current_turn_player() -> String:
	if game_manager.turn_state == GameManager.TurnState.P1:
		return "player_1"
	elif game_manager.turn_state == GameManager.TurnState.P2:
		return "player_2"
	return ""

# ── Turn logic ────────────────────────────────────────────────────────────────

func _update_turn_ui() -> void:
	var is_beginning = game_manager.turn_state == GameManager.TurnState.BEGINNING
	end_turn_btn.visible = not is_beginning
	match game_manager.turn_state:
		GameManager.TurnState.BEGINNING:
			turn_label.text = "Beginning"
		GameManager.TurnState.P1:
			turn_label.text = "Player 1's Turn"
			end_turn_btn.text = "End P1 Turn"
		GameManager.TurnState.P2:
			turn_label.text = "Player 2's Turn"
			end_turn_btn.text = "End P2 Turn"

func _mulligan_panel(player: String) -> Control:
	return mulligan_panel_p1 if player == "player_1" else mulligan_panel_p2

func _mulligan(player: String) -> void:
	var already = _p1_mulliganed if player == "player_1" else _p2_mulliganed
	if already or game_manager.turn_state != GameManager.TurnState.BEGINNING:
		return
	var hand_cards = game_manager.hand.filter(func(c): return c.card_owner == player)
	var count = hand_cards.size()
	var pile = game_manager.player1_draw_pile if player == "player_1" else game_manager.player2_draw_pile
	for card in hand_cards:
		pile.append(card.card_id)
		card.queue_free()
		game_manager.hand.erase(card)
	pile.shuffle()
	for _i in count:
		_draw_card(player)
	if player == "player_1":
		_p1_mulliganed = true
	else:
		_p2_mulliganed = true
	_mulligan_panel(player).get_node("VBox/MulliganBtn").disabled = true
	game_log.add_entry("%s mulliganed (%d cards)" % [_player_name(player), count], "default")

func _set_ready(player: String) -> void:
	if game_manager.turn_state != GameManager.TurnState.BEGINNING:
		return
	if player == "player_1":
		_p1_ready = true
	else:
		_p2_ready = true
	_mulligan_panel(player).get_node("VBox/ReadyBtn").disabled = true
	game_log.add_entry("%s is ready" % _player_name(player), "default")
	if _p1_ready and _p2_ready:
		_start_game()

func _start_game() -> void:
	mulligan_panel_p1.visible = false
	mulligan_panel_p2.visible = false
	_first_turn_skip = game_manager.first_player
	game_manager.turn_state = GameManager.TurnState.P1 \
		if game_manager.first_player == "player_1" else GameManager.TurnState.P2
	_start_turn(game_manager.first_player)

func _on_setup_confirmed(p1_is_ai: bool, p2_is_ai: bool) -> void:
	game_manager.player1_is_ai = p1_is_ai
	game_manager.player2_is_ai = p2_is_ai
	setup_panel.visible = false
	_init_game()

func _init_game() -> void:
	_game_over = false
	_clear_all_cards()
	_randomize_deck_for_player("player_1")
	_randomize_deck_for_player("player_2")
	_init_board()
	for _i in 7: _draw_card("player_1")
	for _i in 7: _draw_card("player_2")

	_p1_ready = false
	_p2_ready = false
	_p1_mulliganed = false
	_p2_mulliganed = false
	_first_turn_skip = ""
	mulligan_panel_p1.get_node("VBox/MulliganBtn").disabled = false
	mulligan_panel_p1.get_node("VBox/ReadyBtn").disabled = false
	mulligan_panel_p2.get_node("VBox/MulliganBtn").disabled = false
	mulligan_panel_p2.get_node("VBox/ReadyBtn").disabled = false
	game_manager.turn_state            = GameManager.TurnState.BEGINNING
	game_manager.player1_resources     = 0
	game_manager.player2_resources     = 0
	game_manager.player1_pet_capacity  = 1
	game_manager.player2_pet_capacity  = 1
	_update_deck_labels()
	_update_resource_counts()
	_randomize_first_player()
	_update_turn_ui()

	# AI players skip mulligan
	if game_manager.player1_is_ai:
		mulligan_panel_p1.visible = false
		_p1_ready = true
	if game_manager.player2_is_ai:
		mulligan_panel_p2.visible = false
		_p2_ready = true
	if _p1_ready and _p2_ready:
		_start_game()

func _randomize_first_player() -> void:
	game_manager.first_player = "player_1" if randi() % 2 == 0 else "player_2"
	var p1_goes_first = game_manager.first_player == "player_1"
	mulligan_panel_p1.get_node("VBox/OrderLabel").text = \
		"You go First" if p1_goes_first else "You go Second"
	mulligan_panel_p2.get_node("VBox/OrderLabel").text = \
		"You go Second" if p1_goes_first else "You go First"

func _start_turn(player: String) -> void:
	if _game_over:
		return
	# Start Phase 1: ready all of this player's in-play cards + clear summoning sickness
	for card in game_manager.board:
		if card.card_owner == player:
			if card.exhausted:
				card.ready_card()
			if card.just_summoned:
				card.set_just_summoned(false)
	_update_resource_counts()
	# Start Phase 2: draw 1 — first player skips on their very first turn
	if player == _first_turn_skip:
		_first_turn_skip = ""  # only skips once
	else:
		_draw_card(player)
	game_log.add_entry("%s's turn begins" % _player_name(player), "default")
	_update_turn_ui()

	# Hand off to AI if this player is an AI
	var is_ai = game_manager.player1_is_ai if player == "player_1" else game_manager.player2_is_ai
	if is_ai:
		var ai = BasicAI.new()
		ai.sandbox = self
		await ai.run_turn(player)

func _on_end_turn_pressed() -> void:
	match game_manager.turn_state:
		GameManager.TurnState.P1:
			game_manager.turn_state = GameManager.TurnState.P2
			call_deferred("_start_turn", "player_2")
		GameManager.TurnState.P2:
			game_manager.turn_state = GameManager.TurnState.P1
			call_deferred("_start_turn", "player_1")

func _exhaust_resources(player: String, amount: int) -> void:
	var row = resource_row if player == "player_1" else opp_resource_row
	var exhausted = 0
	for child in row.get_children():
		if exhausted >= amount:
			break
		if child.has_method("exhaust") and not child.exhausted:
			child.exhaust()
			exhausted += 1
	_update_resource_counts()

func _prompt_x_value(card: Control) -> void:
	_x_pending_card = card
	var payer     = _hand_owner_of(card)
	var available = _available_resources(payer)
	var max_x     = available - card.cost_base
	var spin      = _x_dialog.get_child(0).get_node("Spin") as SpinBox
	var lbl       = _x_dialog.get_child(0).get_node("Desc") as Label
	spin.max_value = max_x
	spin.value     = 0
	lbl.text = "%s\nBase cost: %d  |  Available: %d\nChoose X (0 – %d):" % [
		card.card_name, card.cost_base, available, max_x]
	_x_dialog.popup_centered()

func _on_x_confirmed() -> void:
	if not _x_pending_card:
		return
	var spin = _x_dialog.get_child(0).get_node("Spin") as SpinBox
	var x    = int(spin.value)
	_x_pending_card.chosen_x = x
	_x_pending_card.cost     = _x_pending_card.cost_base + x
	_do_play_card(_x_pending_card)
	_x_pending_card = null

func _play_card(card: Control) -> void:
	if card.cost_x:
		# Check at least the base cost is affordable before prompting
		var payer = _hand_owner_of(card)
		if _available_resources(payer) < card.cost_base:
			_warn_dialog.dialog_text = (
				"Not enough resources to play %s.\nMinimum cost: %d  |  Available: %d" % [
					card.card_name, card.cost_base, _available_resources(payer)])
			_warn_dialog.popup_centered()
			return
		_prompt_x_value(card)
		return
	_do_play_card(card)

# ── Violation resolution ──────────────────────────────────────────────────────

func _enter_violation_mode(candidates: Array, prompt: String, callback: Callable) -> void:
	_violation_cards    = candidates
	_violation_callback = callback
	game_log.add_entry("VIOLATION — %s (click or press 1–%d)" % [prompt, candidates.size()], "death")
	for i in candidates.size():
		var card = candidates[i]
		var overlay = ColorRect.new()
		overlay.color        = Color(1.0, 0.2, 0.2, 0.45)
		overlay.layout_mode  = 1
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(overlay)
		var lbl = Label.new()
		lbl.text = str(i + 1)
		lbl.add_theme_font_size_override("font_size", 36)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		lbl.add_theme_constant_override("outline_size", 5)
		lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		lbl.layout_mode = 1
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(lbl)
		_violation_overlays.append([overlay, lbl])

func _exit_violation_mode() -> void:
	for pair in _violation_overlays:
		for node in pair:
			node.queue_free()
	_violation_overlays.clear()
	_violation_cards.clear()

func _resolve_violation(card: Control) -> void:
	_exit_violation_mode()
	_violation_callback.call(card)

func _check_violations_for(card: Control) -> void:
	# Pet uniqueness (also covers Warlock demons — both have subtype "Pet")
	if card.card_type == "Ally" and "Pet" in card.card_subtype:
		var pets = game_manager.board.filter(func(c):
			return c.card_owner == card.card_owner and "Pet" in c.card_subtype)
		if pets.size() > _pet_capacity(card.card_owner):
			_enter_violation_mode(
				pets,
				"Too many Pets — choose one to destroy",
				func(chosen): _destroy_to_graveyard(chosen))
			return
	# TODO: equipment uniqueness, unique card violations

func _destroy_to_graveyard(card: Control) -> void:
	card.ready_card()
	game_log.add_entry("%s was destroyed (uniqueness violation)" % card.card_name, "death")
	move_card(card, _grav_for(card.card_owner))

func _count_pets(card_owner: String) -> int:
	return game_manager.board.filter(func(c):
		return c.card_owner == card_owner and "Pet" in c.card_subtype).size()

func _pet_capacity(card_owner: String) -> int:
	return game_manager.player1_pet_capacity if card_owner == "player_1" \
		else game_manager.player2_pet_capacity

func _do_play_card(card: Control) -> void:
	if not _can_afford(card):
		_warn_not_enough_resources(card)
		return
	var payer = _hand_owner_of(card)
	if card.cost > 0:
		_exhaust_resources(payer, card.cost)
		var cost_str = "%d+%d" % [card.cost_base, card.chosen_x] if card.cost_x else str(card.cost)
		game_log.add_entry(
			"%s exhausted %s resource%s to play %s" % [
				_player_name(payer), cost_str,
				"s" if card.cost > 1 else "", card.card_name],
			"resource")
	var o = card.card_owner
	match card.card_type:
		"Ally":    move_card(card, _ally_row_for(o))
		"Ability": move_card(card, _grav_for(o))
		_:         move_card(card, _ally_row_for(o))
	_check_violations_for(card)

func _on_card_clicked(card: Control) -> void:
	if _is_animating:
		return
	# Violation mode takes priority — click selects which card to destroy
	if _violation_cards.size() > 0:
		if card in _violation_cards:
			_resolve_violation(card)
		return  # block all other actions until violation is resolved

	# In targeting mode
	if _attacker:
		if _is_valid_target(card, _attacker.card_owner):
			_resolve_combat(_attacker, card)
		else:
			_exit_targeting_mode()
		return

	# Normal mode
	if game_manager.hand.has(card):
		_play_card(card)
	elif _is_board_ally(card) and not card.exhausted and can_propose_attacker(card):
		_enter_targeting_mode(card)
