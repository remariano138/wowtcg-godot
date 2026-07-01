class_name BoardRenderer
extends Node

# Listens to EventBus and drives all visual updates.
# Owns the only lookup table between game instance_ids and Godot nodes.
# Never mutates GameState — read-only access only, and only for initial layout.
#
# Setup (called by whatever scene instantiates this renderer):
#   register_card(instance_id, node)   — tell the renderer which node is which card
#   register_zone(zone_id, anchor)     — tell the renderer where each zone sits on screen

# instance_id (String) -> Node2D representing that card visually
var card_nodes: Dictionary = {}

# zone_id (String) -> Node2D whose global_position is the visual centre of that zone
var zone_anchors: Dictionary = {}


func _ready() -> void:
	EventBus.game_event.connect(_on_game_event)


func register_card(instance_id: String, node: Node2D) -> void:
	card_nodes[instance_id] = node


func register_zone(zone_id: String, anchor: Node2D) -> void:
	zone_anchors[zone_id] = anchor


# ── Event dispatch ─────────────────────────────────────────────────────────────

func _on_game_event(event: GameEvent) -> void:
	match event.event_type:
		"card_moved":
			await _animate_move(event.payload["card"], event.payload["to"])
		"card_exhausted":
			_animate_exhaust(event.payload["card"])
		"card_readied":
			_animate_ready(event.payload["card"])
		"damage_dealt":
			_show_damage_number(event.payload["target"], event.payload["amount"])
		"hp_changed":
			pass  # renderer reacts to damage_dealt for the pop-up; hp_changed is for UI bars (Phase 5+)
		"card_destroyed":
			pass  # move_card will fire card_moved to graveyard — that handles the visual


# ── Animations ─────────────────────────────────────────────────────────────────

func _animate_move(card_id: String, to_zone: String) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	var anchor    := zone_anchors.get(to_zone) as Node2D
	if not card_node or not anchor:
		return
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "global_position", anchor.global_position, 0.3)
	await tween.finished


func _animate_exhaust(card_id: String) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "rotation_degrees", 90.0, 0.2)


func _animate_ready(card_id: String) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "rotation_degrees", 0.0, 0.2)


func _show_damage_number(card_id: String, amount: int) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return
	var label := Label.new()
	label.text       = "-%d" % amount
	label.z_index    = 10
	label.add_theme_font_size_override("font_size", 32)
	label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.global_position = card_node.global_position + Vector2(10, -30)
	get_tree().root.add_child(label)
	var tween := create_tween()
	tween.tween_property(label, "global_position",
		label.global_position + Vector2(0, -60), 0.9)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 0.9)
	await tween.finished
	label.queue_free()
