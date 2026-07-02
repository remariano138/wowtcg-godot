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
#   set_perspective(player_id)         — "" = show all (test/spectator); set = hide opponent hand

# instance_id (String) -> Node2D representing that card visually
var card_nodes: Dictionary = {}

# zone_id (String) -> Node2D whose global_position is the visual centre of that zone
var zone_anchors: Dictionary = {}

# zone_id (String) -> Array[String] instance_ids currently in that zone (renderer's view)
var _zone_cards: Dictionary = {}

var _input_router: InputRouter = null
var _status_label: Label = null

# Which player is sitting at this screen. "" means spectator/test — show all cards.
# When set, cards in any other player's hand zone are rendered face-down.
var _perspective_player: String = ""

# ── Card inspector (Alt + hover) ───────────────────────────────────────────────
var _inspector: TextureRect = null        # large card image overlay
var _hovered_card_id: String = ""         # instance_id of card under cursor

# ── Hero HP bars ────────────────────────────────────────────────────────────────
# One bar per player, built lazily on first hp_changed for a hero zone card.
# Dictionary: player_id -> {bg, fill, label} Nodes
var _hero_bars: Dictionary = {}

# ── Deck count labels ──────────────────────────────────────────────────────────
# zone_id -> Label node, created when a deck zone is registered.
var _deck_labels: Dictionary = {}
# zone_id -> int, maintained separately because deck cards have no visual nodes.
var _deck_counts: Dictionary = {}

# Zones where cards are fanned out horizontally. All others stack at the anchor.
const SPREAD_ZONES := ["chain",
	"p1_hand", "p2_hand",
	"p1_ally_row", "p2_ally_row",
	"p1_hero_row", "p2_hero_row",
	"p1_resource_row", "p2_resource_row"]

# In-play zones need wider spacing so exhausted (rotated 90°) cards don't overlap.
# A card is W=80 H=110; when exhausted its footprint is 110px wide, so 130px gives ~10px margin.
# Hand/chain cards are never rotated, so 92px (6px margin at W=80) is fine there.
const PLAY_SPREAD_GAP := 130.0
const HAND_SPREAD_GAP :=  92.0

const PLAY_ZONES := ["p1_ally_row", "p2_ally_row",
	"p1_hero_row", "p2_hero_row",
	"p1_resource_row", "p2_resource_row"]


func _ready() -> void:
	EventBus.game_event.connect(_on_game_event)
	_build_inspector()


func _build_inspector() -> void:
	_inspector = TextureRect.new()
	_inspector.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_inspector.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	_inspector.size         = Vector2(320, 440)   # ~4× the 80×110 card node
	_inspector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inspector.visible      = false
	_inspector.z_index      = 100
	add_child(_inspector)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_ALT:
			if k.pressed:
				_try_show_inspector()
			else:
				_inspector.visible = false
	elif event is InputEventMouseMotion and Input.is_key_pressed(KEY_ALT):
		_try_show_inspector()


func _try_show_inspector() -> void:
	if _hovered_card_id == "":
		_inspector.visible = false
		return
	var cn := card_nodes.get(_hovered_card_id) as CardNode
	if not cn or not cn._tex_rect or not cn._tex_rect.texture:
		_inspector.visible = false
		return
	_inspector.texture = cn._tex_rect.texture
	var mouse:   Vector2 = get_viewport().get_mouse_position()
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var sz:      Vector2 = _inspector.size
	_inspector.position = Vector2(
		clamp(mouse.x + 24, 0.0, vp_size.x - sz.x),
		clamp(mouse.y - sz.y * 0.5, 0.0, vp_size.y - sz.y))
	_inspector.visible = true


signal card_right_clicked(instance_id: String)


func has_card_node(instance_id: String) -> bool:
	return card_nodes.has(instance_id)


func register_card(instance_id: String, node: Node2D) -> void:
	card_nodes[instance_id] = node
	if node.has_signal("card_clicked"):
		node.card_clicked.connect(_on_card_clicked)
	if node.has_signal("card_right_clicked"):
		node.card_right_clicked.connect(_on_card_right_clicked)
	if node.has_signal("card_hovered"):
		node.card_hovered.connect(_on_card_hovered)
	if node.has_signal("card_unhovered"):
		node.card_unhovered.connect(_on_card_unhovered)


func register_zone(zone_id: String, anchor: Node2D) -> void:
	zone_anchors[zone_id] = anchor
	if not _zone_cards.has(zone_id):
		_zone_cards[zone_id] = []
	if zone_id.ends_with("_deck"):
		_create_deck_label(zone_id, anchor)


# Tell the renderer that a card starts in a zone (call after register_card for
# cards that are already in play at scene start, before any events fire).
func place_card_in_zone(instance_id: String, zone_id: String) -> void:
	if not _zone_cards.has(zone_id):
		_zone_cards[zone_id] = []
	var zc: Array = _zone_cards[zone_id]
	if not zc.has(instance_id):
		zc.append(instance_id)
	var cn := card_nodes.get(instance_id) as CardNode
	if cn:
		if _should_show_front(zone_id):
			cn.show_card_front()
		else:
			cn.show_card_back()


func set_input_router(router: InputRouter) -> void:
	_input_router = router
	router.highlights_updated.connect(_on_highlights_updated)


func set_status_label(label: Label) -> void:
	_status_label = label


# Pass the local player's id to hide opponent hand cards. Call before any cards
# are placed. Omit (or pass "") for test/spectator mode — all cards show their front.
func set_perspective(player_id: String) -> void:
	_perspective_player = player_id


# Returns true if a card in this zone should show its front face from the current
# perspective. Does NOT account for face-down resources — those are flipped by the
# resource_placed event separately.
func _should_show_front(zone_id: String) -> bool:
	if _perspective_player == "":
		return true   # spectator / test — show everything
	# Hand zones: only show fronts for the local player's own hand.
	if zone_id.ends_with("_hand"):
		return zone_id == _perspective_player + "_hand"
	return true


# ── Event dispatch ─────────────────────────────────────────────────────────────

func _on_game_event(event: GameEvent) -> void:
	match event.event_type:
		"card_moved":
			var from_z: String = event.payload["from"]
			var to_z:   String = event.payload["to"]
			await _animate_move(event.payload["card"], from_z, to_z)
			if from_z.ends_with("_deck"):
				_deck_counts[from_z] = max(0, _deck_counts.get(from_z, 0) - 1)
				_refresh_deck_label(from_z)
			if to_z.ends_with("_deck"):
				_deck_counts[to_z] = _deck_counts.get(to_z, 0) + 1
				_refresh_deck_label(to_z)
		"card_exhausted":
			_animate_exhaust(event.payload["card"])
		"card_readied":
			_animate_ready(event.payload["card"])
		"damage_dealt":
			_show_damage_number(event.payload["target"], event.payload["amount"])
		"hp_changed":
			var cid: String  = event.payload.get("card", "")
			var new_hp: int  = event.payload.get("new_hp", 0)
			var max_hp: int  = event.payload.get("max_hp", 0)
			var cn := card_nodes.get(cid) as CardNode
			if not cn:
				return
			# Determine if this card is a hero by checking which zone it occupies.
			var hero_player := _hero_player_for(cid)
			if hero_player != "":
				_update_hero_bar(hero_player, cid, new_hp, max_hp)
			else:
				# Ally: show damage badge. damage = max_hp - new_hp.
				cn.update_damage(max_hp - new_hp)
		"card_destroyed":
			pass  # card_moved to graveyard handles the visual
		"card_revealed":
			var cn := card_nodes.get(event.payload.get("card", "")) as CardNode
			if cn:
				cn.reveal()
		"resource_placed":
			var cn := card_nodes.get(event.payload.get("card_id", "")) as CardNode
			if cn:
				if event.payload.get("face_up", false):
					cn.show_card_front()
				else:
					cn.show_card_back()
		"quest_completed":
			var cn := card_nodes.get(event.payload.get("quest_id", "")) as CardNode
			if cn:
				cn.show_card_back()
		"action_proposed":
			if event.payload.get("action_type") == "place_resource" \
					and not event.payload.get("face_up", true):
				var cn := card_nodes.get(event.payload.get("card_id", "")) as CardNode
				if cn:
					cn.show_card_back()
			var atype: String = event.payload.get("action_type", "?")
			if atype == "propose_combat":
				_set_status("⚔ %s attacks  —  SPACE to let it resolve" % event.payload.get("player", "?"))
			else:
				_set_status("Chain +1  (%s playing %s)  —  SPACE to pass" % [
					event.payload.get("player", "?"), atype])
		"priority_passed":
			_set_status("Priority → %s  —  SPACE to pass" % event.payload.get("player", "?"))
		"priority_window_closed":
			_set_status("Window closed  (phase: %s)" % event.payload.get("phase", "?"))
		"action_fizzled":
			_set_status("Action fizzled: %s" % event.payload.get("reason", "?"))
		"action_retracted":
			_set_status("Retracted: %s" % event.payload.get("action_type", "?"))
		"quest_completed":
			_set_status("Quest completed by %s — reward applied!" % event.payload.get("player", "?"))
		"discard_choice_opened":
			_set_status("Discard %d card(s) from hand  [click a card]" % event.payload.get("count", 1))
		"combat_started":
			_set_status("⚔ Combat begins!")
		"protect_point_opened":
			_set_status("⚔ Protect point — defending player may exhaust a Protector  [or skip]")
		"protect_chosen":
			var pid: String = event.payload.get("protector_id", "")
			if pid == "":
				_set_status("⚔ No protection — combat proceeds")
			else:
				_set_status("⚔ Protector intercepts!")
		"combat_concluded":
			var a_dmg: int = event.payload.get("attacker_damage", 0)
			var d_dmg: int = event.payload.get("defender_damage", 0)
			_set_status("⚔ Combat resolved  (dealt %d / received %d)" % [a_dmg, d_dmg])
		"game_over":
			_set_status("★ GAME OVER  —  %s wins!" % event.payload.get("winner", "?"))


# ── Animations ─────────────────────────────────────────────────────────────────

func _animate_move(card_id: String, from_zone: String, to_zone: String) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return

	_remove_from_zone(card_id, from_zone)
	_add_to_zone(card_id, to_zone)

	# Flip face based on destination zone and perspective.
	# resource_placed handles face-down resources separately; here we only
	# care about hand visibility (opponent hands hidden in real game).
	var cn := card_nodes.get(card_id) as CardNode
	if cn and to_zone.ends_with("_hand"):
		if _should_show_front(to_zone):
			cn.show_card_front()
		else:
			cn.show_card_back()

	# Re-centre source zone (closes the gap).
	_relayout_zone(from_zone)

	if to_zone in SPREAD_ZONES:
		# Re-centring the destination handles the arriving card's tween too.
		_relayout_zone(to_zone)
	else:
		# Non-spread zone (graveyard, deck …): tween the card to the anchor directly.
		var anchor := zone_anchors.get(to_zone) as Node2D
		if anchor:
			var tween := create_tween()
			tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
			tween.tween_property(card_node, "global_position", anchor.global_position, 0.3)

	await get_tree().create_timer(0.3).timeout


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
	if not card_nodes.has(card_id):
		return   # no visual node — don't track in zone layout
	if not _zone_cards.has(zone_id):
		_zone_cards[zone_id] = []
	var zc: Array = _zone_cards[zone_id]
	if not zc.has(card_id):
		zc.append(card_id)


func _remove_from_zone(card_id: String, zone_id: String) -> void:
	if _zone_cards.has(zone_id):
		(_zone_cards[zone_id] as Array).erase(card_id)


func _spread_gap(zone_id: String) -> float:
	return PLAY_SPREAD_GAP if zone_id in PLAY_ZONES else HAND_SPREAD_GAP


func _card_position_in_zone(card_id: String, zone_id: String) -> Vector2:
	var anchor := zone_anchors.get(zone_id) as Node2D
	if not anchor:
		return Vector2.ZERO
	if not (zone_id in SPREAD_ZONES):
		return anchor.global_position

	var gap: float = _spread_gap(zone_id)
	var zc: Array  = _zone_cards.get(zone_id, [])
	var count := zc.size()
	var idx   := zc.find(card_id)
	if idx < 0 or count <= 1:
		return anchor.global_position

	var total := gap * (count - 1)
	return anchor.global_position + Vector2(-total * 0.5 + idx * gap, 0.0)


# Smoothly slide all cards in a zone to their centred positions.
# Public so the scene can call it for initial placement before events start.
func relayout_zone(zone_id: String) -> void:
	_relayout_zone(zone_id)


func _relayout_zone(zone_id: String) -> void:
	if not (zone_id in SPREAD_ZONES):
		return
	var anchor := zone_anchors.get(zone_id) as Node2D
	if not anchor:
		return
	var gap: float = _spread_gap(zone_id)
	var zc: Array  = _zone_cards.get(zone_id, [])
	var count := zc.size()
	for i in count:
		var cid: String = zc[i]
		var node := card_nodes.get(cid) as Node2D
		if not node:
			continue
		var total  := gap * (count - 1)
		var target := anchor.global_position + Vector2(-total * 0.5 + i * gap, 0.0)
		var tween  := create_tween()
		tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tween.tween_property(node, "global_position", target, 0.2)


# ── Input bridge ───────────────────────────────────────────────────────────────

func _on_card_clicked(instance_id: String) -> void:
	if _input_router:
		_input_router.handle_card_click(instance_id)


func _on_card_right_clicked(instance_id: String) -> void:
	card_right_clicked.emit(instance_id)


func _on_card_hovered(instance_id: String) -> void:
	_hovered_card_id = instance_id
	if Input.is_key_pressed(KEY_ALT):
		_try_show_inspector()


func _on_card_unhovered(instance_id: String) -> void:
	if _hovered_card_id == instance_id:
		_hovered_card_id = ""
		_inspector.visible = false


func _on_highlights_updated(playable_ids: Array) -> void:
	for inst_id in card_nodes:
		var node := card_nodes[inst_id] as Node2D
		if node and node.has_method("set_highlighted"):
			node.set_highlighted(inst_id in playable_ids)


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text


# ── Hero HP bar ────────────────────────────────────────────────────────────────

# Returns the player_id if this card is currently in a hero_row, else "".
func _hero_player_for(card_id: String) -> String:
	for pid in ["p1", "p2"]:
		var zone_id: String = pid + "_hero_row"
		var zc: Array = _zone_cards.get(zone_id, [])
		if card_id in zc:
			return pid
	return ""


func _ensure_hero_bar(player_id: String) -> void:
	if _hero_bars.has(player_id):
		return
	const BAR_W := 24.0
	const BAR_H := CardNode.H

	var bg := ColorRect.new()
	bg.color        = Color(0.35, 0.05, 0.05)
	bg.size         = Vector2(BAR_W, BAR_H)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index      = 10
	add_child(bg)

	var fill := ColorRect.new()
	fill.color        = Color(0.1, 0.45, 0.15)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(fill)

	var lbl := Label.new()
	lbl.layout_mode = 1
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(lbl)

	_hero_bars[player_id] = {"bg": bg, "fill": fill, "label": lbl}


# Call once after the hero node is registered to show the bar at full health.
func init_hero_bar(player_id: String, card_id: String, max_hp: int) -> void:
	_update_hero_bar(player_id, card_id, max_hp, max_hp)


func _update_hero_bar(player_id: String, card_id: String, new_hp: int, max_hp: int) -> void:
	_ensure_hero_bar(player_id)
	var bar: Dictionary = _hero_bars[player_id]
	var bg:   ColorRect = bar["bg"]
	var fill: ColorRect = bar["fill"]
	var lbl:  Label     = bar["label"]

	# Position bar to the right of the hero card node, offset enough to clear
	# the exhausted footprint (card rotates 90°, right edge reaches H/2 from center).
	var cn := card_nodes.get(card_id) as Node2D
	if cn:
		bg.position = cn.global_position + Vector2(CardNode.H * 0.5 + 6, -CardNode.H * 0.5)

	lbl.text = str(new_hp)
	var ratio: float = float(new_hp) / float(max(max_hp, 1))
	var fill_h: float = bg.size.y * ratio
	fill.size     = Vector2(bg.size.x, fill_h)
	fill.position = Vector2(0.0, bg.size.y - fill_h)


# ── Deck count labels ──────────────────────────────────────────────────────────

func _create_deck_label(zone_id: String, anchor: Node2D) -> void:
	_deck_counts[zone_id] = 0
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.size         = Vector2(CardNode.W, 20)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.z_index      = 5
	add_child(lbl)
	_deck_labels[zone_id] = lbl
	_refresh_deck_label(zone_id)


# Call after building GameState to seed the initial count.
func init_deck_count(zone_id: String, count: int) -> void:
	_deck_counts[zone_id] = count
	_refresh_deck_label(zone_id)


func _refresh_deck_label(zone_id: String) -> void:
	var lbl := _deck_labels.get(zone_id) as Label
	if not lbl:
		return
	var anchor := zone_anchors.get(zone_id) as Node2D
	if anchor:
		lbl.global_position = anchor.global_position + Vector2(
			-CardNode.W * 0.5, CardNode.H * 0.5 + 4)
	lbl.text = str(_deck_counts.get(zone_id, 0))


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
