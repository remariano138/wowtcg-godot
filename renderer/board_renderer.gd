class_name BoardRenderer
extends Node

# Listens to EventBus and drives all visual updates.
# Owns the only lookup table between game instance_ids and Godot nodes.
# Never mutates GameState — read-only access only, and only for initial layout.
#
# Setup (called by whatever scene instantiates this renderer):
#   register_card(instance_id, node)   — tell the renderer which node is which card
#   register_zone(zone_id, anchor)     — tell the renderer where each zone sits on screen
#   set_input_router(router)           — wire card clicks to InputRouter
#   set_status_label(label)            — label updated with priority / phase info

# instance_id (String) -> Node2D representing that card visually
var card_nodes: Dictionary = {}

# zone_id (String) -> Node2D whose global_position is the visual centre of that zone
var zone_anchors: Dictionary = {}

# zone_id (String) -> Array[String] instance_ids currently in that zone (renderer's view)
var _zone_cards: Dictionary = {}

var _input_router: InputRouter = null
var _status_label: Label = null

# Zones where cards are fanned out horizontally. All others stack at the anchor.
const SPREAD_ZONES  := ["chain", "p1_hand", "p2_hand",
						"p1_ally_row", "p2_ally_row",
						"p1_hero_row", "p2_hero_row"]
const SPREAD_GAP    := 90.0   # pixels between card centres


func _ready() -> void:
	EventBus.game_event.connect(_on_game_event)


func register_card(instance_id: String, node: Node2D) -> void:
	card_nodes[instance_id] = node
	if node.has_signal("card_clicked"):
		node.card_clicked.connect(_on_card_clicked)


func register_zone(zone_id: String, anchor: Node2D) -> void:
	zone_anchors[zone_id] = anchor
	if not _zone_cards.has(zone_id):
		_zone_cards[zone_id] = []


# Tell the renderer that a card starts in a zone (call after register_card for
# cards that are already in play at scene start, before any events fire).
func place_card_in_zone(instance_id: String, zone_id: String) -> void:
	if not _zone_cards.has(zone_id):
		_zone_cards[zone_id] = []
	var zc: Array = _zone_cards[zone_id]
	if not zc.has(instance_id):
		zc.append(instance_id)


func set_input_router(router: InputRouter) -> void:
	_input_router = router
	router.highlights_updated.connect(_on_highlights_updated)


func set_status_label(label: Label) -> void:
	_status_label = label


# ── Event dispatch ─────────────────────────────────────────────────────────────

func _on_game_event(event: GameEvent) -> void:
	match event.event_type:
		"card_moved":
			await _animate_move(
				event.payload["card"],
				event.payload["from"],
				event.payload["to"])
		"card_exhausted":
			_animate_exhaust(event.payload["card"])
		"card_readied":
			_animate_ready(event.payload["card"])
		"damage_dealt":
			_show_damage_number(event.payload["target"], event.payload["amount"])
		"hp_changed":
			pass
		"card_destroyed":
			pass  # card_moved to graveyard handles the visual
		"action_proposed":
			_set_status("Chain +1  (%s playing %s)  —  SPACE to pass" % [
				event.payload.get("player", "?"),
				event.payload.get("action_type", "?")])
		"priority_passed":
			_set_status("Priority → %s  —  SPACE to pass" % event.payload.get("player", "?"))
		"priority_window_closed":
			_set_status("Window closed  (phase: %s)" % event.payload.get("phase", "?"))
		"action_fizzled":
			_set_status("Action fizzled: %s" % event.payload.get("reason", "?"))
		"action_retracted":
			_set_status("Retracted: %s" % event.payload.get("action_type", "?"))


# ── Animations ─────────────────────────────────────────────────────────────────

func _animate_move(card_id: String, from_zone: String, to_zone: String) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return

	# Update renderer zone tracking.
	_remove_from_zone(card_id, from_zone)
	_add_to_zone(card_id, to_zone)

	# Animate card to its new spread position.
	var target := _card_position_in_zone(card_id, to_zone)
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "global_position", target, 0.3)

	# Close the gap left behind in the source zone (non-blocking).
	_relayout_zone(from_zone)

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


# ── Zone layout helpers ────────────────────────────────────────────────────────

func _add_to_zone(card_id: String, zone_id: String) -> void:
	if not _zone_cards.has(zone_id):
		_zone_cards[zone_id] = []
	var zc: Array = _zone_cards[zone_id]
	if not zc.has(card_id):
		zc.append(card_id)


func _remove_from_zone(card_id: String, zone_id: String) -> void:
	if _zone_cards.has(zone_id):
		(_zone_cards[zone_id] as Array).erase(card_id)


func _card_position_in_zone(card_id: String, zone_id: String) -> Vector2:
	var anchor := zone_anchors.get(zone_id) as Node2D
	if not anchor:
		return Vector2.ZERO
	if not (zone_id in SPREAD_ZONES):
		return anchor.global_position

	var zc: Array = _zone_cards.get(zone_id, [])
	var count := zc.size()
	var idx   := zc.find(card_id)
	if idx < 0 or count <= 1:
		return anchor.global_position

	var total := SPREAD_GAP * (count - 1)
	return anchor.global_position + Vector2(-total * 0.5 + idx * SPREAD_GAP, 0.0)


# Smoothly slide cards already in a zone to close any gap after a card leaves.
func _relayout_zone(zone_id: String) -> void:
	if not (zone_id in SPREAD_ZONES):
		return
	var anchor := zone_anchors.get(zone_id) as Node2D
	if not anchor:
		return
	var zc: Array = _zone_cards.get(zone_id, [])
	var count := zc.size()
	for i in count:
		var cid: String = zc[i]
		var node := card_nodes.get(cid) as Node2D
		if not node:
			continue
		var total  := SPREAD_GAP * (count - 1)
		var target := anchor.global_position + Vector2(-total * 0.5 + i * SPREAD_GAP, 0.0)
		var tween  := create_tween()
		tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tween.tween_property(node, "global_position", target, 0.2)


# ── Input bridge ───────────────────────────────────────────────────────────────

func _on_card_clicked(instance_id: String) -> void:
	if _input_router:
		_input_router.handle_card_click(instance_id)


func _on_highlights_updated(playable_ids: Array) -> void:
	for inst_id in card_nodes:
		var node := card_nodes[inst_id] as Node2D
		if node and node.has_method("set_highlighted"):
			node.set_highlighted(inst_id in playable_ids)


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text


# ── Damage popup ───────────────────────────────────────────────────────────────

func _show_damage_number(card_id: String, amount: int) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return
	var label := Label.new()
	label.text     = "-%d" % amount
	label.z_index  = 10
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
