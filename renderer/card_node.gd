class_name CardNode
extends Node2D

# Visual representation of one card. Handles its own click detection via Area2D.
# Tells listeners what was clicked (instance_id) but makes no game decisions.
# BoardRenderer owns all CardNodes and bridges their signals to InputRouter.

signal card_clicked(instance_id: String)

const W := 80.0
const H := 110.0

var instance_id: String = ""
var _bg: ColorRect


static func create(inst_id: String, card_name: String,
		stats: String, color: Color = Color(0.25, 0.45, 0.75)) -> CardNode:
	var node := CardNode.new()
	node.instance_id = inst_id

	# Background
	var bg := ColorRect.new()
	bg.size     = Vector2(W, H)
	bg.position = Vector2(-W * 0.5, -H * 0.5)
	bg.color    = color
	node.add_child(bg)
	node._bg = bg

	# Border inset
	var border := ColorRect.new()
	border.size     = Vector2(W - 4, H - 4)
	border.position = Vector2(-W * 0.5 + 2, -H * 0.5 + 2)
	border.color    = color.darkened(0.3)
	node.add_child(border)

	# Card name
	var name_lbl := Label.new()
	name_lbl.text = card_name
	name_lbl.add_theme_font_size_override("font_size", 9)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	name_lbl.position = Vector2(-W * 0.5 + 4, -H * 0.5 + 4)
	name_lbl.size = Vector2(W - 8, 36)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.add_child(name_lbl)

	# ATK / HP stats
	var stats_lbl := Label.new()
	stats_lbl.text = stats
	stats_lbl.add_theme_font_size_override("font_size", 13)
	stats_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	stats_lbl.position = Vector2(-18, H * 0.5 - 26)
	node.add_child(stats_lbl)

	return node


func set_highlighted(highlighted: bool) -> void:
	if not _bg:
		return
	_bg.color = Color(0.25, 0.60, 0.15) if highlighted else Color(0.25, 0.45, 0.75)


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	var local := to_local(get_viewport().get_mouse_position())
	if abs(local.x) <= W * 0.5 and abs(local.y) <= H * 0.5:
		card_clicked.emit(instance_id)
		get_viewport().set_input_as_handled()
