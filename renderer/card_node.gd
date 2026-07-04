class_name CardNode
extends Node2D

# Visual representation of one card. Handles its own click detection via Area2D.
# Tells listeners what was clicked (instance_id) but makes no game decisions.
# BoardRenderer owns all CardNodes and bridges their signals to InputRouter.

signal card_clicked(instance_id: String)
signal card_right_clicked(instance_id: String)
signal card_hovered(instance_id: String)
signal card_unhovered(instance_id: String)

const W := 80.0
const H := 110.0

const CARD_BACK_PATH := "res://assets/card_backs/wowTCGdefaultback.jpg"

var instance_id: String = ""
var _bg: ColorRect
var _tex_rect: TextureRect   # shown when a real image is loaded
var _front_texture: Texture2D = null
var _is_face_down: bool = false
var _base_color: Color = Color(0.25, 0.45, 0.75)
var _mouse_inside: bool = false
var _damage_badge: Label = null
var _power_used_badge: Label = null
var _sick_badge: Label = null
var _outline: ColorRect = null

# ── Wiggle state ───────────────────────────────────────────────────────────────
var _wiggle_tween: Tween = null
var _wiggle_base: float = 0.0


static func create(inst_id: String, card_name: String,
		stats: String, color: Color = Color(0.25, 0.45, 0.75),
		image_path: String = "") -> CardNode:
	var node := CardNode.new()
	node.instance_id = inst_id

	# Outline — drawn first (behind everything), only visible when highlighted.
	const OUTLINE := 3.0
	var outline := ColorRect.new()
	outline.color    = Color(0.2, 1.0, 0.3)
	outline.size     = Vector2(W + OUTLINE * 2, H + OUTLINE * 2)
	outline.position = Vector2(-W * 0.5 - OUTLINE, -H * 0.5 - OUTLINE)
	outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outline.visible  = false
	node.add_child(outline)
	node._outline = outline

	# TextureRect — shown when a real card image or the card back is loaded.
	var tex := TextureRect.new()
	tex.size             = Vector2(W, H)
	tex.position         = Vector2(-W * 0.5, -H * 0.5)
	tex.stretch_mode     = TextureRect.STRETCH_SCALE
	tex.expand_mode      = TextureRect.EXPAND_IGNORE_SIZE
	tex.visible          = false
	node.add_child(tex)
	node._tex_rect = tex

	# Background (fallback when no image).
	var bg := ColorRect.new()
	bg.size     = Vector2(W, H)
	bg.position = Vector2(-W * 0.5, -H * 0.5)
	bg.color    = color
	node.add_child(bg)
	node._bg = bg
	node._base_color = color

	# Border inset (fallback).
	var border := ColorRect.new()
	border.size     = Vector2(W - 4, H - 4)
	border.position = Vector2(-W * 0.5 + 2, -H * 0.5 + 2)
	border.color    = color.darkened(0.3)
	node.add_child(border)

	# Card name (fallback).
	var name_lbl := Label.new()
	name_lbl.text = card_name
	name_lbl.add_theme_font_size_override("font_size", 9)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	name_lbl.position = Vector2(-W * 0.5 + 4, -H * 0.5 + 4)
	name_lbl.size = Vector2(W - 8, 36)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.add_child(name_lbl)

	# ATK / HP stats (fallback).
	var stats_lbl := Label.new()
	stats_lbl.text = stats
	stats_lbl.add_theme_font_size_override("font_size", 13)
	stats_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	stats_lbl.position = Vector2(-18, H * 0.5 - 26)
	node.add_child(stats_lbl)

	# Damage badge — centered on card, shown when damage_taken > 0.
	var badge := Label.new()
	badge.add_theme_font_size_override("font_size", 48)
	badge.add_theme_color_override("font_color", Color(1.0, 0.15, 0.15))
	badge.add_theme_constant_override("outline_size", 6)
	badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1.0))
	badge.size     = Vector2(W, 60)
	badge.position = Vector2(-W * 0.5, -30)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.visible  = false
	node.add_child(badge)
	node._damage_badge = badge

	# "USED" badge — shown on hero cards after they activate their power.
	var used_lbl := Label.new()
	used_lbl.text = "USED"
	used_lbl.add_theme_font_size_override("font_size", 20)
	used_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.0))
	used_lbl.add_theme_constant_override("outline_size", 4)
	used_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1.0))
	used_lbl.size     = Vector2(W, 30)
	used_lbl.position = Vector2(-W * 0.5, H * 0.5 - 34)
	used_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	used_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	used_lbl.visible  = false
	node.add_child(used_lbl)
	node._power_used_badge = used_lbl

	# Summoning-sickness badge (Zzz / Grr) — shown above the card when just_summoned.
	var sick_lbl := Label.new()
	sick_lbl.add_theme_font_size_override("font_size", 15)
	sick_lbl.add_theme_constant_override("outline_size", 3)
	sick_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1.0))
	sick_lbl.size                 = Vector2(W, 22)
	sick_lbl.position             = Vector2(-W * 0.5, -H * 0.5 - 22)
	sick_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sick_lbl.mouse_filter         = Control.MOUSE_FILTER_IGNORE
	sick_lbl.visible              = false
	node.add_child(sick_lbl)
	node._sick_badge = sick_lbl

	# Try to load the real card image.
	if image_path != "" and image_path != "No match":
		var res_path := "res://" + image_path.replace("\\", "/")
		var texture: Texture2D = load(res_path)
		if texture:
			node._front_texture = texture
			node._show_texture(texture)

	return node


# Show the card back (face-down resources, hidden hand cards, deck piles).
# Call whenever damage_taken changes. Pass 0 to hide the badge.
func update_damage(damage_taken: int) -> void:
	if not _damage_badge:
		return
	if damage_taken <= 0:
		_damage_badge.visible = false
	else:
		_damage_badge.text    = "-%d" % damage_taken
		_damage_badge.visible = true


func show_card_back() -> void:
	_is_face_down = true
	var back: Texture2D = load(CARD_BACK_PATH)
	if back:
		_show_texture(back)
	else:
		_show_fallback()


func show_card_front() -> void:
	_is_face_down = false
	if _front_texture:
		_show_texture(_front_texture)
	else:
		_show_fallback()


# Briefly show the card's front face, then restore the previous face state.
# Used for "reveal" effects (discard reveal, top-of-deck reveal, etc.).
func reveal(duration: float = 1.5) -> void:
	var was_face_down := _is_face_down
	show_card_front()
	await get_tree().create_timer(duration).timeout
	if was_face_down:
		show_card_back()


func set_power_used(used: bool) -> void:
	if _power_used_badge:
		_power_used_badge.visible = used


func set_highlighted(highlighted: bool, color: Color = Color(0.2, 1.0, 0.3)) -> void:
	if _outline:
		_outline.color   = color
		_outline.visible = highlighted


# ── Helpers ────────────────────────────────────────────────────────────────────

func _show_texture(texture: Texture2D) -> void:
	_tex_rect.texture = texture
	_tex_rect.visible = true
	# Hide all sibling nodes except the tex_rect itself.
	for child in get_children():
		if child != _tex_rect:
			child.visible = false


func _show_fallback() -> void:
	_tex_rect.visible = false
	for child in get_children():
		child.visible = true


# ── Summoning-sickness badge ───────────────────────────────────────────────────

func show_sick_badge(ferocity: bool) -> void:
	if not _sick_badge:
		return
	if ferocity:
		_sick_badge.text = "Grr"
		_sick_badge.add_theme_color_override("font_color", Color(0.95, 0.25, 0.15))
	else:
		_sick_badge.text = "Zzz"
		_sick_badge.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	_sick_badge.visible = true


func hide_sick_badge() -> void:
	if _sick_badge:
		_sick_badge.visible = false


# ── Wiggle ─────────────────────────────────────────────────────────────────────

# Continuous wiggle loop (targeting in progress).
func start_wiggle() -> void:
	if _wiggle_tween:
		_wiggle_tween.kill()
	_wiggle_base = rotation_degrees
	_wiggle_tween = create_tween().set_loops()
	_wiggle_tween.tween_property(self, "rotation_degrees", _wiggle_base + 6.0, 0.09)
	_wiggle_tween.tween_property(self, "rotation_degrees", _wiggle_base - 6.0, 0.09)
	_wiggle_tween.tween_property(self, "rotation_degrees", _wiggle_base,       0.09)


# Wiggle for a fixed duration then snap back (post-resolution effect cue).
func wiggle_for(duration: float) -> void:
	if _wiggle_tween:
		_wiggle_tween.kill()
	_wiggle_base = rotation_degrees
	_wiggle_tween = create_tween()
	var t := 0.0
	while t < duration:
		_wiggle_tween.tween_property(self, "rotation_degrees", _wiggle_base + 6.0, 0.09)
		_wiggle_tween.tween_property(self, "rotation_degrees", _wiggle_base - 6.0, 0.09)
		_wiggle_tween.tween_property(self, "rotation_degrees", _wiggle_base,       0.09)
		t += 0.27
	_wiggle_tween.tween_property(self, "rotation_degrees", _wiggle_base, 0.15)
	_wiggle_tween.tween_callback(func() -> void: _wiggle_tween = null)


# Stop an in-progress continuous wiggle; optionally keep going for `more_seconds`.
func stop_wiggle(more_seconds: float = 0.0) -> void:
	if _wiggle_tween:
		_wiggle_tween.kill()
		_wiggle_tween = null
	rotation_degrees = _wiggle_base
	if more_seconds > 0.0:
		wiggle_for(more_seconds)


func _input(event: InputEvent) -> void:
	var local: Vector2 = to_local(get_viewport().get_mouse_position())
	var inside: bool   = abs(local.x) <= W * 0.5 and abs(local.y) <= H * 0.5

	# Hover tracking — emit once on enter/leave.
	if inside != _mouse_inside:
		_mouse_inside = inside
		if inside:
			card_hovered.emit(instance_id)
		else:
			card_unhovered.emit(instance_id)

	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	if not inside:
		return
	var mb := event as InputEventMouseButton
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			card_clicked.emit(instance_id)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_RIGHT:
			card_right_clicked.emit(instance_id)
			get_viewport().set_input_as_handled()
