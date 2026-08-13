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
#   set_perspective(player_id)         — "" = show all (test/spectator); set = hide opponent hand

# instance_id (String) -> Node2D representing that card visually
var card_nodes: Dictionary = {}

# zone_id (String) -> Node2D whose global_position is the visual centre of that zone
var zone_anchors: Dictionary = {}

# zone_id (String) -> Array[String] instance_ids currently in that zone (renderer's view)
var _zone_cards: Dictionary = {}

# player_id -> instance_id of that player's hero card. The hero card is pinned to a
# fixed "_hero_card" anchor beside the deck; everything else in "_hero_row" (equipment,
# non-attaching ongoing abilities) uses the normal centre-row spread.
var _hero_card_ids: Dictionary = {}

# attachment instance_id -> host instance_id (rule 400.5 — the attachment card
# renders tucked behind its host and follows it around). Maintained from
# card_attached events, self-healed from state in reconcile_from_state.
var _attachment_hosts: Dictionary = {}

# How far an attachment peeks out past its host (toward the opponent side, so
# it reads as tucked underneath from the controller's seat). 1/5 card height.
const ATTACH_PEEK := 21.0
const ATTACH_STACK_GAP := 26.0   # extra peek per additional attachment


# card_id -> Tween of an in-flight death overlay fade. card_moved defers the
# move-to-graveyard animation until this finishes, so the card doesn't slide
# away while still covered in red.
var _death_tweens: Dictionary = {}

var _input_router: InputRouter = null

# Which player is sitting at this screen. "" means spectator/test — show all cards.
# When set, cards in any other player's hand zone are rendered face-down.
var _perspective_player: String = ""

# ── Card inspector (Alt + hover) ───────────────────────────────────────────────
var _inspector: TextureRect = null        # large card image overlay
var _hovered_card_id: String = ""         # instance_id of card under cursor

# ── Graveyard peek (Alt + hover over a graveyard pile) ──────────────────────────
var _gy_peek_open: bool = false
var _gy_peek_zone: String = ""            # zone_id currently driving the peek

# ── Targeting overlay ──────────────────────────────────────────────────────────
var _targeting_line:      Line2D  = null
var _targeting_cursor:    Node2D  = null   # icon + amount label that follows the mouse
var _targeting_active:    bool    = false
var _targeting_source_id: String  = ""
var _highlighted_ids:     Array   = []     # current green-highlighted card ids

# ── Hero HP bars ────────────────────────────────────────────────────────────────
# One bar per player, built lazily on first hp_changed for a hero zone card.
# Dictionary: player_id -> {bg, fill, label} Nodes
var _hero_bars: Dictionary = {}

# ── Deck count labels ──────────────────────────────────────────────────────────
# zone_id -> Label node, created when a deck zone is registered.
var _deck_labels: Dictionary = {}
# zone_id -> int, maintained separately because deck cards have no visual nodes.
var _deck_counts: Dictionary = {}

# ── Pulse tracking ─────────────────────────────────────────────────────────────
# instance_id of the card currently in a continuous targeting pulse ("" = none).
var _pulsing_id: String = ""

# ── Position tween registry ────────────────────────────────────────────────────
# Tracks the active movement/layout tween per card so that a new tween can
# kill the old one before starting.  Prevents stale deck-animation tweens
# from overwriting a layout tween when the same card is returned and redrawn
# during mulligan (hand→deck tween 0.3 s vs layout tween 0.2 s race).
var _pos_tweens: Dictionary = {}   # card_id -> Tween

# Zones where cards are fanned out horizontally. All others stack at the anchor.
const SPREAD_ZONES := ["chain",
	"p1_hand", "p2_hand",
	"p1_ally_row", "p2_ally_row",
	"p1_hero_row", "p2_hero_row",
	"p1_resource_row", "p2_resource_row"]

# Every in-play card slot is one card HEIGHT square: exhausted, a card is rotated
# 90° and its footprint becomes H wide, so that is the smallest slot whose
# contents can never overlap a neighbour in either orientation. It is also what
# makes the drawn zone grids line up exactly with the cards in them (ready cards
# touch the top/bottom lines, exhausted ones the left/right).
# Hand/chain cards are never rotated, so CardNode.W + ~12px margin is fine there.
const CARD_SLOT       := CardNode.H
const PLAY_SPREAD_GAP := CARD_SLOT
# Padding used between rows and against the screen edge. Derived from card size
# so the whole board layout rescales when the cards do.
const CARD_PAD        := CardNode.H / 5.0

# Hand cards render 1.2x larger than table cards for readability.
const HAND_CARD_SCALE := 1.2
const HAND_SPREAD_GAP := CardNode.W * HAND_CARD_SCALE + 12.0

# Hero cards are special (rule 200) and render twice table size, centred on the
# same "_hero_card" anchor as before — CardNode's visual origin is its centre,
# so scaling keeps it height-centred on its hero row (where equipment goes).
# Applied in _apply_zone_scale (the one choke point for card scale) and again in
# register_hero_card, which may run after the card has already been placed.
const HERO_CARD_SCALE := 2.0

const PLAY_ZONES := ["p1_ally_row", "p2_ally_row",
	"p1_hero_row", "p2_hero_row",
	"p1_resource_row", "p2_resource_row"]


# Current view rotation (matches the scene camera: 0 = P1 view, 180 = P2 view).
# Transient world-space overlays (targeting cursor, floating damage/heal numbers)
# counter-compose with it so they stay readable on a rotated board.
var view_rotation_degrees: float = 0.0

# Mouse position in WORLD coordinates, accounting for the board camera (which
# can be rotated 180° for the P2 view). BoardRenderer extends Node (not
# CanvasItem), so it can't use get_global_mouse_position() directly.
func _world_mouse() -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() \
			* get_viewport().get_mouse_position()


func _ready() -> void:
	EventBus.game_event.connect(_on_game_event)
	_build_inspector()
	_build_targeting_line()


func _build_targeting_line() -> void:
	_targeting_line = Line2D.new()
	_targeting_line.width         = 2.5
	_targeting_line.default_color = _LINE_COLOR_DEFAULT
	_targeting_line.z_index       = 60
	_targeting_line.visible       = false
	_targeting_line.add_point(Vector2.ZERO)   # index 0: source card
	_targeting_line.add_point(Vector2.ZERO)   # index 1: cursor
	add_child(_targeting_line)

	# Cursor overlay: icon sprite + damage amount label, hidden until targeting starts.
	_targeting_cursor = Node2D.new()
	_targeting_cursor.z_index = 70
	_targeting_cursor.visible = false

	var icon := Sprite2D.new()
	icon.name  = "Icon"
	icon.scale = Vector2(0.55, 0.55)
	_targeting_cursor.add_child(icon)

	var lbl := Label.new()
	lbl.name = "Amount"
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.size         = Vector2(48, 24)
	lbl.position     = Vector2(-24, 14)   # just below the icon centre
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_targeting_cursor.add_child(lbl)

	add_child(_targeting_cursor)


const _LINE_COLOR_DEFAULT := Color(1.0, 0.85, 0.2, 0.85)   # golden
const _LINE_COLOR_VALID   := Color(0.2, 1.0, 0.3, 0.9)     # green — matches card highlight

func _process(_delta: float) -> void:
	if not _targeting_active:
		return
	var mouse := _world_mouse()
	if _targeting_line:
		_targeting_line.set_point_position(1, mouse)
		var cn := card_nodes.get(_targeting_source_id) as Node2D
		if cn:
			_targeting_line.set_point_position(0, cn.global_position)
		# Turn green when hovering a legal target, golden otherwise.
		var over_valid := _hovered_card_id != "" and _hovered_card_id in _highlighted_ids
		_targeting_line.default_color = _LINE_COLOR_VALID if over_valid else _LINE_COLOR_DEFAULT
	if _targeting_cursor:
		_targeting_cursor.global_position = mouse
		_targeting_cursor.rotation_degrees = view_rotation_degrees   # stay upright on screen


# The inspector lives in its own CanvasLayer: it's a screen-space reading aid,
# so it must not rotate with the board camera.
func _build_inspector() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 15
	add_child(layer)
	_inspector = TextureRect.new()
	_inspector.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_inspector.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	_inspector.size         = Vector2(CardNode.W * 4, CardNode.H * 4)   # ~4× the card node
	_inspector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inspector.visible      = false
	_inspector.z_index      = 100
	layer.add_child(_inspector)


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_ALT:
			if k.pressed:
				_try_show_inspector()
			else:
				_inspector.visible = false
				_close_graveyard_peek()
	elif event is InputEventMouseMotion and Input.is_key_pressed(KEY_ALT):
		_try_show_inspector()


# Returns the zone_id currently containing instance_id, or "" if none (matches
# against the renderer's own _zone_cards bookkeeping — no GameState access needed).
func _zone_of_card(instance_id: String) -> String:
	for zone_id in _zone_cards:
		if instance_id in (_zone_cards[zone_id] as Array):
			return zone_id
	return ""


# Show the inspector for a SPECIFIC card, anchored beside the card's node on
# the board rather than the mouse — used by the Combat window's name labels
# (Alt+hover a combatant's written name examines the card it points at, which
# disambiguates same-named allies: the magnified card appears next to the real
# one). Camera-aware: the node position is taken through the canvas transform,
# so the P2 seat's rotated view anchors correctly too.
func show_inspector_for(card_id: String) -> void:
	var cn := card_nodes.get(card_id) as CardNode
	if not cn or not cn._tex_rect or not cn._tex_rect.texture:
		return
	_inspector.texture = cn._tex_rect.texture
	var screen_pos: Vector2 = cn.get_global_transform_with_canvas().origin
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var sz:      Vector2 = _inspector.size
	_inspector.position = Vector2(
		clamp(screen_pos.x + CardNode.W, 0.0, vp_size.x - sz.x),
		clamp(screen_pos.y - sz.y * 0.5, 0.0, vp_size.y - sz.y))
	_inspector.visible = true


func hide_inspector() -> void:
	if _inspector:
		_inspector.visible = false


func _try_show_inspector() -> void:
	if _hovered_card_id == "":
		_inspector.visible = false
		_close_graveyard_peek()
		return
	var zone_id := _zone_of_card(_hovered_card_id)
	if zone_id.ends_with("_graveyard"):
		_inspector.visible = false
		_open_graveyard_peek(zone_id)
		return
	_close_graveyard_peek()
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


# Alt+hover over any card in a graveyard pile opens the (non-modal) examine
# screen for that whole pile. Re-entrant-safe: repeated calls while already
# peeking the same zone are no-ops so the dialog doesn't rebuild every frame.
func _open_graveyard_peek(zone_id: String) -> void:
	if _gy_peek_open and _gy_peek_zone == zone_id:
		return
	_gy_peek_open = true
	_gy_peek_zone = zone_id
	if _input_router:
		var gy_player := "p1" if zone_id.begins_with("p1") else "p2"
		_input_router.request_graveyard_peek(gy_player)


func _close_graveyard_peek() -> void:
	if not _gy_peek_open:
		return
	_gy_peek_open = false
	_gy_peek_zone = ""
	if _input_router:
		_input_router.close_graveyard_peek()


signal card_right_clicked(instance_id: String)
signal card_clicked(instance_id: String)


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


# Which way cards in a zone face: P2's zones point at P2 (180°, upside-down to
# the P1 viewer), everything else (P1's zones, the chain) at P1.
static func _facing_for_zone(zone_id: String) -> float:
	return 180.0 if zone_id.begins_with("p2_") else 0.0


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
		cn.facing_degrees = _facing_for_zone(zone_id)
		cn.rotation_degrees = cn.facing_degrees   # fresh placements are ready; reconcile re-adds exhaust
	_apply_zone_scale(instance_id, zone_id)


func set_input_router(router: InputRouter) -> void:
	_input_router = router
	router.highlights_updated.connect(_on_highlights_updated)
	router.conditional_highlights_updated.connect(_on_conditional_highlights_updated)
	router.targeting_started.connect(_on_targeting_started)
	router.targeting_cancelled.connect(_on_targeting_cancelled)


# Pass the local player's id to hide opponent hand cards. Call before any cards
# are placed. Omit (or pass "") for test/spectator mode — all cards show their front.
func set_perspective(player_id: String) -> void:
	_perspective_player = player_id


# Re-apply hand face-up/face-down to every card already in a hand zone. Call
# after set_perspective changes mid-game (hotseat handoff). Non-hand zones are
# untouched (face-down resources are driven by resource_placed separately).
func refresh_hand_visibility() -> void:
	for zone_id: String in _zone_cards:
		if not zone_id.ends_with("_hand"):
			continue
		var show_front := _should_show_front(zone_id)
		for cid: String in _zone_cards[zone_id]:
			var cn := card_nodes.get(cid) as CardNode
			if cn:
				if show_front:
					cn.show_card_front()
				else:
					cn.show_card_back()


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
			var moved_card: String = event.payload["card"]
			if to_z.ends_with("_graveyard") and _death_tweens.has(moved_card):
				var death_tw: Tween = _death_tweens[moved_card]
				if is_instance_valid(death_tw):
					await death_tw.finished
				_death_tweens.erase(moved_card)
			await _animate_move(moved_card, from_z, to_z)
			if from_z.ends_with("_deck"):
				_deck_counts[from_z] = max(0, _deck_counts.get(from_z, 0) - 1)
				_refresh_deck_label(from_z)
			if to_z.ends_with("_deck"):
				_deck_counts[to_z] = _deck_counts.get(to_z, 0) + 1
				_refresh_deck_label(to_z)
			if to_z.ends_with("_graveyard"):
				var cn := card_nodes.get(event.payload["card"]) as CardNode
				if cn and cn.has_method("update_damage"):
					cn.update_damage(0)
		"card_attached":
			var att_id:  String = event.payload.get("card", "")
			var host_id: String = event.payload.get("host", "")
			_attachment_hosts[att_id] = host_id
			var att_cn  := card_nodes.get(att_id)  as CardNode
			var host_cn := card_nodes.get(host_id) as CardNode
			if att_cn and host_cn:
				att_cn.facing_degrees = host_cn.facing_degrees
				att_cn.rotation_degrees = att_cn.facing_degrees
				att_cn.is_attachment = true
				_update_host_z(host_id)
				_move_attachments_with_host(host_id, host_cn.global_position)
		"card_exhausted":
			_animate_exhaust(event.payload["card"])
			_res_restack(event.payload["card"])
		"card_readied":
			_animate_ready(event.payload["card"])
			_res_restack(event.payload["card"])
		"damage_dealt":
			_show_damage_number(event.payload["target"], event.payload["amount"])
		"hp_changed":
			var cid: String  = event.payload.get("card", "")
			var new_hp: int  = event.payload.get("new_hp", 0)
			var old_hp: int  = event.payload.get("old_hp", 0)
			var max_hp: int  = event.payload.get("max_hp", 0)
			var cn := card_nodes.get(cid) as CardNode
			if not cn:
				return
			if new_hp > old_hp:
				_show_heal_number(cid, new_hp - old_hp)
				_play_heal_animation(cid)
			var hero_player := _hero_player_for(cid)
			if hero_player != "":
				_update_hero_bar(hero_player, cid, new_hp, max_hp)
			else:
				cn.update_damage(max_hp - new_hp)
		"card_entered_with_damage":
			# Ancestral Spirit: the ally is reanimated with damage set directly on
			# the CardInstance (not dealt), so no hp_changed/damage_dealt fires —
			# refresh the damage overlay explicitly or it reads as full HP.
			var ecd_id: String = event.payload.get("card_id", "")
			var ecd_dmg: int   = event.payload.get("damage", 0)
			var ecd_cn := card_nodes.get(ecd_id) as CardNode
			if ecd_cn and ecd_cn.has_method("update_damage"):
				ecd_cn.update_damage(ecd_dmg)
		"card_destroyed":
			_play_death_animation(event.payload.get("card", ""))
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
		"quest_turned_face_down":
			# Kolkar: same spent face-down resource state as a completed quest,
			# but no reward was applied.
			var fd_cn := card_nodes.get(event.payload.get("quest_id", "")) as CardNode
			if fd_cn:
				fd_cn.show_card_back()
		"hero_power_used":
			var hero_id: String = event.payload.get("hero_id", "")
			var hcn := card_nodes.get(hero_id) as CardNode
			if hcn:
				if hcn.has_method("set_power_used"):
					hcn.set_power_used(true)
				# If we were pulsing this card (targeted hero power), transition to a 2-sec
				# post-resolution pulse; otherwise start a fresh 2-sec one (AoE / instant).
				if _pulsing_id == hero_id:
					hcn.stop_pulse(2.0)
					_pulsing_id = ""
				else:
					hcn.pulse_for(2.0)
		"ally_power_used":
			var ally_id: String = event.payload.get("ally_id", "")
			var acn := card_nodes.get(ally_id) as CardNode
			if acn:
				# The cue animates scale, so it can start immediately — it no longer
				# has to wait out (or fight) the exhaust rotation tween.
				if _pulsing_id == ally_id:
					_pulsing_id = ""
					acn.stop_pulse(2.0)
				else:
					acn.pulse_for(2.0)
		"action_proposed":
			if event.payload.get("action_type") == "place_resource" \
					and not event.payload.get("face_up", true):
				var cn := card_nodes.get(event.payload.get("card_id", "")) as CardNode
				if cn:
					cn.show_card_back()
			# Start a continuous pulse on the source card when a non-targeted ally
			# power enters the stack (targeted powers start pulsing at targeting_started).
			if event.payload.get("action_type") == "use_ally_power" and _pulsing_id == "":
				var ap_id: String = event.payload.get("card_id", "")
				var apcn := card_nodes.get(ap_id) as CardNode
				if apcn:
					_pulsing_id = ap_id
					apcn.start_pulse()
		"combat_concluded":
			var attacker_id: String = event.payload.get("attacker_id", "")
			if event.payload.get("cancelled", false):
				# 603.1b: no damage was dealt and a combatant is gone — no lunge.
				return
			await _animate_attack(attacker_id, event.payload.get("defender_id", ""))
			# Re-spread the attacker's zone: layout tweens can conflict with the
			# attack tween (they're not tracked in _pos_tweens), leaving cards misaligned.
			for zone_id in _zone_cards:
				if attacker_id in (_zone_cards.get(zone_id, []) as Array):
					_relayout_zone(zone_id)
					break
		"phase_changed":
			pass   # no visual action needed on phase transitions
		"deck_shuffled":
			pass  # no visual needed; card_moved events handle the hand refill


# ── Animations ─────────────────────────────────────────────────────────────────

# Covers a card with an opaque rectangle that fades away over `duration` seconds,
# revealing the card underneath. Attached as a child of the CardNode so it travels
# along with any concurrent move tween instead of being left behind.
func _play_color_flash(card_id: String, color: Color, duration: float) -> ColorRect:
	var cn := card_nodes.get(card_id) as CardNode
	if not cn:
		return null
	var overlay := ColorRect.new()
	overlay.color        = color
	overlay.size          = Vector2(CardNode.W, CardNode.H)
	overlay.position      = Vector2(-CardNode.W * 0.5, -CardNode.H * 0.5)
	overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	overlay.z_index       = 50
	cn.add_child(overlay)
	var tw := create_tween()
	tw.tween_property(overlay, "color:a", 0.0, duration)
	tw.finished.connect(func() -> void:
		if is_instance_valid(overlay):
			overlay.queue_free())
	return overlay


# Red flash — matches the emit_events() sim pause in event_bus.gd, which holds
# the simulation still for the same duration (see _death_tweens above, which
# card_moved awaits before animating the move to graveyard).
func _play_death_animation(card_id: String) -> void:
	var cn := card_nodes.get(card_id) as CardNode
	if not cn:
		return
	var overlay := ColorRect.new()
	overlay.color        = Color(0.8, 0.05, 0.05, 1.0)
	overlay.size          = Vector2(CardNode.W, CardNode.H)
	overlay.position      = Vector2(-CardNode.W * 0.5, -CardNode.H * 0.5)
	overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	overlay.z_index       = 50
	cn.add_child(overlay)
	var tw := create_tween()
	_death_tweens[card_id] = tw
	tw.tween_property(overlay, "color:a", 0.0, GameTiming.death_animation())
	tw.finished.connect(func() -> void:
		if is_instance_valid(overlay):
			overlay.queue_free())


# Green flash — no sim pause of its own (the plain damage_pause() already covers
# hp_changed via event_bus.gd), no move to defer, so it's a fire-and-forget flash.
func _play_heal_animation(card_id: String) -> void:
	_play_color_flash(card_id, Color(0.1, 0.75, 0.15, 1.0), GameTiming.heal_animation())


func _animate_move(card_id: String, from_zone: String, to_zone: String) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return

	_remove_from_zone(card_id, from_zone)
	_add_to_zone(card_id, to_zone)
	_apply_zone_scale(card_id, to_zone)

	# Coming back off the chain (resolved, countered, retracted): the node was
	# hidden while the Chain window stood in for it — show it again so it can fly
	# to its destination.
	if from_zone == "chain":
		card_node.visible = true

	# Leaving an attachment relationship (host died / attachment destroyed):
	# drop the host link and restore the host's z-order if it's now bare.
	if from_zone == "attached" and _attachment_hosts.has(card_id):
		var old_host: String = _attachment_hosts[card_id]
		_attachment_hosts.erase(card_id)
		_update_host_z(old_host)
		if card_node is CardNode:
			(card_node as CardNode).is_attachment = false

	# Flip face based on destination zone and perspective.
	# resource_placed handles face-down resources separately; here we only
	# care about hand visibility (opponent hands hidden in real game).
	var cn := card_nodes.get(card_id) as CardNode
	if cn and to_zone.ends_with("_hand"):
		if _should_show_front(to_zone):
			cn.show_card_front()
		else:
			cn.show_card_back()
	# The graveyard and the "attached" zone are public: cards there are always
	# face up, even when arriving straight from a hand that was face-down (e.g. an
	# opponent's instant going hand → graveyard, or an opponent attaching Mark of
	# the Wild during our turn).
	elif cn and (to_zone.ends_with("_graveyard") or to_zone == "attached"):
		cn.show_card_front()
	# Re-face the card if it changed sides (e.g. control change moves it to the
	# other player's row). Moving cards are ready in practice; the reconcile
	# tick reasserts the exhausted angle if not.
	if cn and cn.facing_degrees != _facing_for_zone(to_zone):
		cn.facing_degrees = _facing_for_zone(to_zone)
		cn.rotation_degrees = cn.facing_degrees

	# Re-centre source zone (closes the gap).
	_relayout_zone(from_zone)

	if to_zone in SPREAD_ZONES:
		_relayout_zone(to_zone)
	else:
		var anchor := zone_anchors.get(to_zone) as Node2D
		if anchor:
			_kill_pos_tween(card_id)
			var tween := create_tween()
			tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
			tween.tween_property(card_node, "global_position", anchor.global_position, GameTiming.anim(0.3))
			_pos_tweens[card_id] = tween

	# The Chain window (playtest's _update_chain_panel) now shows every link, so
	# the card itself no longer sits in the middle of the board on top of the
	# rows. It still FLIES to the chain anchor — that motion, and its sound, are
	# the cue that something was played — and then simply vanishes into the
	# window. The node stays alive (hidden), so resolving/retracting can fly it
	# back out from the same spot.
	if to_zone == "chain":
		await get_tree().create_timer(GameTiming.anim(0.22)).timeout   # the 0.2s layout tween
		if _zone_of_card(card_id) == "chain" and is_instance_valid(card_node):
			card_node.visible = false
		return

	# RFG is not rendered — the card leaves the board entirely.
	if to_zone.ends_with("_rfg"):
		_remove_from_zone(card_id, to_zone)
		card_nodes.erase(card_id)
		card_node.queue_free()
		return

	# Deck cards have no persistent node — destroy the node after the move tween
	# so it's cleanly gone before the next draw spawns a fresh one.
	if to_zone.ends_with("_deck"):
		await get_tree().create_timer(GameTiming.anim(0.3)).timeout
		var still_in_deck: Array = _zone_cards.get(to_zone, [])
		if card_id in still_in_deck:
			_remove_from_zone(card_id, to_zone)
			card_nodes.erase(card_id)
			card_node.queue_free()


func _animate_exhaust(card_id: String) -> void:
	var card_node := card_nodes.get(card_id) as CardNode
	if not card_node:
		return
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "rotation_degrees", card_node.facing_degrees + 90.0, GameTiming.anim(0.2))


func _animate_ready(card_id: String) -> void:
	var card_node := card_nodes.get(card_id) as CardNode
	if not card_node:
		return
	# Summoning sickness clears at the ready step — remove the Zzz/Grr badge.
	if card_node.has_method("hide_sick_badge"):
		card_node.hide_sick_badge()
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "rotation_degrees", card_node.facing_degrees, GameTiming.anim(0.2))


func _animate_attack(attacker_id: String, defender_id: String) -> void:
	var atk_node := card_nodes.get(attacker_id) as Node2D
	var def_node := card_nodes.get(defender_id) as Node2D
	if not atk_node or not def_node:
		return
	# Snap attacker to its zone resting position in case a placement tween is still running
	# (ferocity cards attack immediately, before the 0.2s relayout tween completes).
	_kill_pos_tween(attacker_id)
	for zone_id in _zone_cards:
		if attacker_id in (_zone_cards.get(zone_id, []) as Array):
			atk_node.global_position = _card_position_in_zone(attacker_id, zone_id)
			break
	var start     := atk_node.global_position
	var direction := (def_node.global_position - start).normalized()
	var distance  := atk_node.global_position.distance_to(def_node.global_position)
	var punch     := start + direction * distance * 0.5
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(atk_node, "global_position", punch, GameTiming.anim(0.12))
	tween.tween_property(atk_node, "global_position", start, GameTiming.anim(0.10))
	_pos_tweens[attacker_id] = tween  # tracked so _kill_pos_tween can cancel mid-lunge
	await tween.finished
	_pos_tweens.erase(attacker_id)


# ── Zone layout helpers ────────────────────────────────────────────────────────

# Hand cards render bigger than table cards (see HAND_CARD_SCALE) — apply
# the right scale whenever a card enters or leaves a hand zone. Hands also sit
# in front of the board (rows now overlap the bottom of the hand cards) — give
# them a baseline z_index so they never render behind a board zone.
const HAND_Z_INDEX := 3

func _apply_zone_scale(card_id: String, zone_id: String) -> void:
	var node := card_nodes.get(card_id) as Node2D
	if not node:
		return
	# Leaving a resource zone sheds any pile badge (retract to hand, etc.).
	if not (zone_id in RESOURCE_ZONES) and node is CardNode:
		(node as CardNode).set_stack_count(0)
	var is_hand := zone_id.ends_with("_hand")
	if _is_hero_card(card_id):
		_write_scale(node, Vector2(HERO_CARD_SCALE, HERO_CARD_SCALE))
		node.z_index = 1   # above the row it sits beside, below hand cards
		return
	_write_scale(node, Vector2(HAND_CARD_SCALE, HAND_CARD_SCALE) if is_hand else Vector2.ONE)
	node.z_index = HAND_Z_INDEX if is_hand else 0


# Card scale is also what the pulse cue animates, so a zone change must set the
# card's RESTING scale (set_base_scale) rather than stomp the live value — the
# pulse then keeps beating around the new size.
func _write_scale(node: Node2D, v: Vector2) -> void:
	if node is CardNode:
		(node as CardNode).set_base_scale(v)
	else:
		node.scale = v


func _is_hero_card(card_id: String) -> bool:
	return card_id != "" and _hero_card_ids.values().has(card_id)


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


# Tell the renderer which card is a player's hero, so hero_row layout can pin it
# to the fixed "_hero_card" anchor instead of the centre-row equipment spread.
# Snaps the node there immediately (no tween) so the hero HP bar, which reads
# the node's position synchronously, lines up correctly right away.
func register_hero_card(player_id: String, instance_id: String) -> void:
	_hero_card_ids[player_id] = instance_id
	var node := card_nodes.get(instance_id) as Node2D
	var anchor := zone_anchors.get(player_id + "_hero_card") as Node2D
	if node and anchor:
		node.global_position = anchor.global_position
	# The card was placed (and scaled) before it was known to be a hero.
	var card := card_nodes.get(instance_id) as CardNode
	if card:
		card.set_base_scale(Vector2(HERO_CARD_SCALE, HERO_CARD_SCALE))
		card.z_index = 1


# "" unless zone_id is a hero_row with a registered hero card, in which case
# returns that hero card's instance_id.
func _hero_card_id_for_zone(zone_id: String) -> String:
	if not zone_id.ends_with("_hero_row"):
		return ""
	var pid := zone_id.substr(0, zone_id.length() - "_hero_row".length())
	return _hero_card_ids.get(pid, "")


# Left-to-right screen order for a zone's cards.
#
# Zone lists are in engine order (index 0 = oldest / first paid), and every
# player must see that order identically FROM THEIR OWN SEAT: first card on
# their left, newly drawn cards on their right, resources exhausting left to
# right. P2's row is viewed from the opposite side (cards face 180°), so its
# world order is the mirror of the list order. True in every mode — the p2
# seat's rotated camera flips it back again.
static func _spread_order(zone_id: String, ids: Array) -> Array:
	if not zone_id.begins_with("p2_"):
		return ids
	var out: Array = ids.duplicate()
	out.reverse()
	return out


# ── Resource zone grid ─────────────────────────────────────────────────────────
# The resource zones lay out as a GRID rather than an ever-widening row: a row
# of resources grew without bound and pushed into its neighbours, while the
# number of resources a player accumulates is quite predictable.
#
# A cell is square and one card HEIGHT on a side, because an exhausted card is
# rotated 90° — that is the smallest cell whose contents can never overlap a
# neighbour in either orientation, and it makes the drawn grid lines touch the
# card edges exactly (ready cards touch top/bottom, exhausted ones left/right).
#
# Cards fill left-to-right then top-to-bottom FROM THEIR OWNER'S SEAT: the list
# is put through _spread_order (which reverses for p2) and the p2 camera's 180°
# rotation flips both axes back, so each player reads their own grid the same way.
const RESOURCE_ZONES  := ["p1_resource_row", "p2_resource_row"]
const RES_GRID_COLS   := 5
const RES_GRID_ROWS   := 3
const RES_CELL        := CARD_SLOT

static func res_grid_size(count: int) -> Vector2:
	# Overflow past COLS*ROWS grows extra rows rather than overlapping cards.
	var rows: int = max(RES_GRID_ROWS, int(ceil(float(count) / float(RES_GRID_COLS))))
	return Vector2(RES_GRID_COLS * RES_CELL, rows * RES_CELL)


# ── Resource stacking (pure rendering) ────────────────────────────────────────
# Identical resources render as ONE pile occupying one slot, with the pile size
# badged on top (CardNode.set_stack_count). Identical means same ready/exhausted
# state AND same name — where all face-down cards count as sharing a name.
# Nothing in the game state or engine changes: every card keeps its own node,
# the pile's members simply share a slot position, and the engine's exhaust
# order (face-down first — see StackResolver._resource_pay_order) is what keeps
# face-down piles together instead of exhausting cards at random.
#
# Set by the scene at game start; without it every card is its own pile.
var _stack_state = null   # GameState — read-only, for pose/name grouping
var _stack_db = null      # CardDatabase — card names for face-up grouping

func set_state_context(state, db) -> void:
	_stack_state = state
	_stack_db = db


# A pose flip regroups the piles immediately: the flipped card slides to its
# new pile (or opens one) the moment the exhaust/ready event lands, and the
# counts on both piles update with it.
func _res_restack(card_id: String) -> void:
	var zone := _zone_of_card(card_id)
	if zone in RESOURCE_ZONES:
		_relayout_zone(zone)


# Grouping key: cards with equal keys share a pile.
func _res_stack_key(card_id: String) -> String:
	if _stack_state == null:
		return card_id
	var card = _stack_state.get_card(card_id)
	if card == null:
		return card_id
	var pose := "E|" if card.is_exhausted else "R|"
	if card.face_down:
		return pose + "#facedown"
	var name_key: String = card.card_def_id
	if _stack_db:
		var def = _stack_db.get_def(card.card_def_id)
		if def:
			name_key = def.card_name
	return pose + name_key


# Slot assignment for a resource zone: one slot per PILE, in order of each
# pile's first appearance in the (seat-ordered) card list.
# Returns {"slots": {card_id: slot_idx}, "slot_count": int,
#          "stack": {card_id: pile size for the pile's representative, else 0}}.
func _res_layout(zone_id: String) -> Dictionary:
	var ids: Array = _spread_cards(zone_id)
	var slots: Dictionary = {}
	var stack: Dictionary = {}
	var key_slot: Dictionary = {}   # stack key -> slot idx
	var key_rep:  Dictionary = {}   # stack key -> representative card_id
	var next_slot := 0
	for cid in ids:
		var key := _res_stack_key(cid)
		if not key_slot.has(key):
			key_slot[key] = next_slot
			key_rep[key]  = cid
			next_slot += 1
		slots[cid] = key_slot[key]
		stack[cid] = 0
	for cid in ids:
		stack[key_rep[_res_stack_key(cid)]] += 1
	return {"slots": slots, "slot_count": next_slot, "stack": stack}


# Position of slot `idx` (of `count`) in `zone_id`, as an offset from the zone
# anchor — the ONE place a zone's card layout is defined, shared by the position
# query, the settled check and the relayout tween.
func _slot_offset(zone_id: String, idx: int, count: int) -> Vector2:
	if zone_id in RESOURCE_ZONES:
		var rows: int = max(RES_GRID_ROWS,
			int(ceil(float(count) / float(RES_GRID_COLS))))
		var col: int = idx % RES_GRID_COLS
		var row: int = idx / RES_GRID_COLS
		# Anchor is the grid's centre, like every other zone anchor.
		return Vector2(
			(col - (RES_GRID_COLS - 1) * 0.5) * RES_CELL,
			(row - (rows - 1) * 0.5) * RES_CELL)
	var gap: float = _spread_gap(zone_id)
	return Vector2(-gap * (count - 1) * 0.5 + idx * gap, 0.0)


# Cards in a hero_row zone, excluding the pinned hero card — used for the spread.
func _spread_cards(zone_id: String) -> Array:
	var zc: Array = _zone_cards.get(zone_id, [])
	var hero_id := _hero_card_id_for_zone(zone_id)
	if hero_id != "":
		var out: Array = []
		for cid in zc:
			if cid != hero_id:
				out.append(cid)
		zc = out
	return _spread_order(zone_id, zc)


func _card_position_in_zone(card_id: String, zone_id: String) -> Vector2:
	var hero_id := _hero_card_id_for_zone(zone_id)
	if hero_id != "" and card_id == hero_id:
		var pid := zone_id.substr(0, zone_id.length() - "_hero_row".length())
		var hero_anchor := zone_anchors.get(pid + "_hero_card") as Node2D
		return hero_anchor.global_position if hero_anchor else Vector2.ZERO

	var anchor := zone_anchors.get(zone_id) as Node2D
	if not anchor:
		return Vector2.ZERO
	if not (zone_id in SPREAD_ZONES):
		return anchor.global_position

	if zone_id in RESOURCE_ZONES:
		var lay := _res_layout(zone_id)
		if not lay["slots"].has(card_id):
			return anchor.global_position
		return anchor.global_position \
			+ _slot_offset(zone_id, lay["slots"][card_id], lay["slot_count"])

	var zc: Array = _spread_cards(zone_id)
	var count := zc.size()
	var idx   := zc.find(card_id)
	if idx < 0 or count <= 1:
		return anchor.global_position

	return anchor.global_position + _slot_offset(zone_id, idx, count)


# Smoothly slide all cards in a zone to their centred positions.
# Public so the scene can call it for initial placement before events start.
func relayout_zone(zone_id: String) -> void:
	_relayout_zone(zone_id)


# Self-healing layout: reconcile the renderer's private zone bookkeeping with
# the game state's true card list. Event-order edge cases (mulligan redraw
# races, nested event emission) can leave _zone_cards drifted from reality —
# symptoms are overlapping or half-slot-offset fans. Called by the scene on UI
# refresh; cheap no-op when the zone is already correct AND settled.
func sync_zone_with_state(zone_id: String, true_ids: Array) -> void:
	if not (zone_id in SPREAD_ZONES):
		return
	# Only ids with a visual node participate in the fan.
	var filtered: Array = []
	for cid in true_ids:
		if card_nodes.has(cid):
			filtered.append(cid)
	var current: Array = _zone_cards.get(zone_id, [])
	if filtered == current and _zone_settled(zone_id, filtered):
		return
	_zone_cards[zone_id] = filtered
	_relayout_zone(zone_id)


# True when every node in the fan that is NOT mid-tween sits on its slot.
# Catches stale positions left by killed tweens even when the list matches.
func _zone_settled(zone_id: String, ids: Array) -> bool:
	var anchor := zone_anchors.get(zone_id) as Node2D
	if not anchor:
		return true
	var hero_id := _hero_card_id_for_zone(zone_id)
	var spread_ids: Array = ids
	if hero_id != "":
		spread_ids = []
		for cid in ids:
			if cid != hero_id:
				spread_ids.append(cid)
	spread_ids = _spread_order(zone_id, spread_ids)
	var count := spread_ids.size()
	# Resource zones stack identical cards onto shared slots (see _res_layout);
	# a pose change (exhaust/ready) regroups, so it also unsettles the zone.
	var lay: Dictionary = _res_layout(zone_id) if zone_id in RESOURCE_ZONES else {}
	for i in count:
		var node := card_nodes.get(spread_ids[i]) as Node2D
		if not node:
			continue
		var t: Tween = _pos_tweens.get(spread_ids[i])
		if t and t.is_valid() and t.is_running():
			continue   # in flight — its tween owns the final position
		var slot_i: int = lay["slots"].get(spread_ids[i], i) if lay else i
		var slot_n: int = lay["slot_count"] if lay else count
		var target := anchor.global_position + _slot_offset(zone_id, slot_i, slot_n)
		if node.global_position.distance_to(target) > 1.0:
			return false
	if hero_id != "" and hero_id in ids:
		var hnode := card_nodes.get(hero_id) as Node2D
		var t: Tween = _pos_tweens.get(hero_id)
		if hnode and not (t and t.is_valid() and t.is_running()):
			var pid := zone_id.substr(0, zone_id.length() - "_hero_row".length())
			var hero_anchor := zone_anchors.get(pid + "_hero_card") as Node2D
			if hero_anchor and hnode.global_position.distance_to(hero_anchor.global_position) > 1.0:
				return false
	return true


func _relayout_zone(zone_id: String) -> void:
	if not (zone_id in SPREAD_ZONES):
		return
	var anchor := zone_anchors.get(zone_id) as Node2D
	if not anchor:
		return
	var hero_id := _hero_card_id_for_zone(zone_id)
	var zc: Array  = _spread_cards(zone_id)
	var count := zc.size()
	var lay: Dictionary = _res_layout(zone_id) if zone_id in RESOURCE_ZONES else {}
	for i in count:
		var cid: String = zc[i]
		var node := card_nodes.get(cid) as Node2D
		if not node:
			continue
		var slot_i: int = lay["slots"].get(cid, i) if lay else i
		var slot_n: int = lay["slot_count"] if lay else count
		var target := anchor.global_position + _slot_offset(zone_id, slot_i, slot_n)
		# Pile badge + draw order: the pile's representative renders on top and
		# wears the count; everyone else hides theirs beneath it.
		if lay and node is CardNode:
			var stack_n: int = lay["stack"].get(cid, 0)
			(node as CardNode).set_stack_count(stack_n)
			node.z_index = 1 if stack_n > 0 else 0
		_kill_pos_tween(cid)
		var tween  := create_tween()
		tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tween.tween_property(node, "global_position", target, GameTiming.anim(0.2))
		_pos_tweens[cid] = tween
		_move_attachments_with_host(cid, target)

	if hero_id != "" and hero_id in (_zone_cards.get(zone_id, []) as Array):
		var hnode := card_nodes.get(hero_id) as Node2D
		if hnode:
			var pid := zone_id.substr(0, zone_id.length() - "_hero_row".length())
			var hero_anchor := zone_anchors.get(pid + "_hero_card") as Node2D
			if hero_anchor:
				_kill_pos_tween(hero_id)
				var htween := create_tween()
				htween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
				htween.tween_property(hnode, "global_position", hero_anchor.global_position, GameTiming.anim(0.2))
				_pos_tweens[hero_id] = htween


# ── Attachment layout (rule 400.5) ─────────────────────────────────────────────

func _attachments_of(host_id: String) -> Array:
	var out: Array = []
	for att_id in _attachment_hosts:
		if _attachment_hosts[att_id] == host_id:
			out.append(att_id)
	return out


# Where the index-th attachment of a host sits, given the host's (target)
# position. The peek offset composes with the host's facing so it always
# points toward the opponent's side of the board.
func _attachment_target_pos(host_cn: CardNode, host_pos: Vector2, index: int,
		att_cn: CardNode = null) -> Vector2:
	# The visible sliver is measured from the HOST'S EDGE, not from its center —
	# a hero renders at HERO_CARD_SCALE, so a fixed center offset tuned for a
	# normal ally would leave the attachment entirely buried under it.
	var host_half := CardNode.H * 0.5 * host_cn.scale.y
	var att_half  := CardNode.H * 0.5 * (att_cn.scale.y if att_cn else 1.0)
	var peek := (host_half - att_half) + ATTACH_PEEK + index * ATTACH_STACK_GAP
	return host_pos + Vector2(0.0, -peek).rotated(deg_to_rad(host_cn.facing_degrees))


# Tween every attachment of host_id toward its slot behind host_target
# (the position the host itself is heading to).
func _move_attachments_with_host(host_id: String, host_target: Vector2) -> void:
	var host_cn := card_nodes.get(host_id) as CardNode
	if not host_cn:
		return
	var atts := _attachments_of(host_id)
	for i in atts.size():
		var node := card_nodes.get(atts[i]) as CardNode
		if not node:
			continue
		_kill_pos_tween(atts[i])
		var tween := create_tween()
		tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tween.tween_property(node, "global_position",
			_attachment_target_pos(host_cn, host_target, i, node), GameTiming.anim(0.2))
		_pos_tweens[atts[i]] = tween


# A host with attachments draws above them (z 1); a bare card sits at z 0.
func _update_host_z(host_id: String) -> void:
	var host_cn := card_nodes.get(host_id) as CardNode
	if host_cn:
		host_cn.z_index = 1 if not _attachments_of(host_id).is_empty() else 0


func _kill_pos_tween(card_id: String) -> void:
	if _pos_tweens.has(card_id):
		var t: Tween = _pos_tweens[card_id]
		if t:
			t.kill()
		_pos_tweens.erase(card_id)


# True only while a tracked position tween is actually still animating. Entries
# in _pos_tweens are never erased when a tween finishes on its own, so a plain
# `_pos_tweens.has(id)` check reads as "in flight" forever after a card's first
# move — which permanently disabled the reconcile self-heal for that card (cards
# left at a crooked angle by a power/attack animation never snapped back).
# Dead entries are dropped here so the dictionary self-cleans.
func _has_live_pos_tween(card_id: String) -> bool:
	if not _pos_tweens.has(card_id):
		return false
	var t: Tween = _pos_tweens[card_id]
	if t != null and is_instance_valid(t) and t.is_running():
		return true
	_pos_tweens.erase(card_id)
	return false


# Self-healing pass: snap each card's orientation to authoritative GameState.
# Event-driven animations (exhaust/ready swings) can leave a card at a crooked
# resting angle if tweens race; this reasserts truth once motion settles.
# Visual-only, read-only on state, and idempotent (a no-op when already correct).
# Skips cards with a live position tween (_pos_tweens) so it never fights motion.
# The pulse cue does NOT block it — that cue animates scale, not rotation, so
# ready/exhaust can be reasserted at any time while a card is pulsing.
func reconcile_from_state(state, force := false) -> void:
	if state == null:
		return
	for card_id in card_nodes:
		if _has_live_pos_tween(card_id):
			continue  # positional move / lunge in flight — leave it alone
		var cn := card_nodes.get(card_id) as CardNode
		if not cn or not is_instance_valid(cn):
			continue
		# A forced pass (turn change) also ends any lingering cue, so no card is
		# left mid-pulse across a turn boundary.
		if force and cn.is_pulsing():
			cn.stop_pulse(0.0)
		var card = state.get_card(card_id)
		if card == null:
			continue
		# Attachments (rule 400.5): self-heal the host map from state, mirror
		# the host's facing, and snap onto the slot behind the host when
		# neither card is mid-tween.
		if card.zone_id == "attached" and card.attached_to != "":
			_attachment_hosts[card_id] = card.attached_to
			cn.is_attachment = true
			var host_cn := card_nodes.get(card.attached_to) as CardNode
			if host_cn:
				_update_host_z(card.attached_to)
				cn.facing_degrees = host_cn.facing_degrees
				cn.settle_rotation(false)
				if not _has_live_pos_tween(card.attached_to):
					var idx := _attachments_of(card.attached_to).find(card_id)
					cn.global_position = _attachment_target_pos(
						host_cn, host_cn.global_position, max(idx, 0), cn)
			continue
		cn.is_attachment = false
		# Self-heal chain visibility: a card on the chain is represented by the
		# Chain window, never on the board. Cards mid-flight are skipped above
		# (live pos tween), so this never cuts an animation short.
		var on_chain: bool = card.zone_id == "chain"
		if cn.visible == on_chain:
			cn.visible = not on_chain
		cn.facing_degrees = _facing_for_zone(card.zone_id)
		cn.settle_rotation(card.is_exhausted)


# ── Input bridge ───────────────────────────────────────────────────────────────

func _on_card_clicked(instance_id: String) -> void:
	card_clicked.emit(instance_id)
	if _input_router:
		_input_router.handle_card_click(instance_id)


func highlight_cards(ids: Array) -> void:
	_on_highlights_updated(ids)


func set_card_outline(id: String, highlighted: bool, color: Color = Color(0.2, 1.0, 0.3)) -> void:
	var cn := card_nodes.get(id) as CardNode
	if cn and cn.has_method("set_highlighted"):
		cn.set_highlighted(highlighted, color)


func _on_card_right_clicked(instance_id: String) -> void:
	card_right_clicked.emit(instance_id)


func _on_card_hovered(instance_id: String) -> void:
	# In stacked (non-spread) zones, only the topmost card (last in list) drives the inspector.
	for zone_id in _zone_cards:
		var zone_list: Array = _zone_cards[zone_id]
		# Attachments each sit behind their own host, not in one shared stack —
		# any of them may drive the inspector.
		if zone_id == "attached":
			continue
		if instance_id in zone_list and zone_id not in SPREAD_ZONES:
			if zone_list[-1] != instance_id:
				return
			break
	_hovered_card_id = instance_id
	if Input.is_key_pressed(KEY_ALT):
		_try_show_inspector()


func _on_card_unhovered(instance_id: String) -> void:
	if _hovered_card_id == instance_id:
		_hovered_card_id = ""
		_inspector.visible = false
		_close_graveyard_peek()


func _on_highlights_updated(playable_ids: Array, color: Color = Color(0.2, 1.0, 0.3)) -> void:
	_highlighted_ids = playable_ids
	for inst_id in card_nodes:
		var node := card_nodes[inst_id] as Node2D
		if node and node.has_method("set_highlighted"):
			node.set_highlighted(inst_id in playable_ids, color)


func _on_conditional_highlights_updated(orange_ids: Array) -> void:
	for inst_id in orange_ids:
		var cn := card_nodes.get(inst_id) as CardNode
		if cn:
			cn.set_highlighted(true, Color(0.95, 0.55, 0.05))


func _on_targeting_started(source_id: String, dmg_type: String, dmg_amount: int) -> void:
	_targeting_active    = true
	_targeting_source_id = source_id
	# Pulse the source card while the player is picking a target.
	_pulsing_id = source_id
	var wcn := card_nodes.get(source_id) as CardNode
	if wcn:
		wcn.start_pulse()
	if _targeting_line:
		var cn := card_nodes.get(source_id) as Node2D
		var src := cn.global_position if cn else _world_mouse()
		_targeting_line.set_point_position(0, src)
		_targeting_line.set_point_position(1, _world_mouse())
		_targeting_line.visible = true
	_update_targeting_cursor(dmg_type, dmg_amount)
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)


func _on_targeting_cancelled() -> void:
	_targeting_active    = false
	_targeting_source_id = ""
	if _targeting_line:
		_targeting_line.visible = false
	if _targeting_cursor:
		_targeting_cursor.visible = false
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	# Targeting cancelled — stop the pulse immediately.
	if _pulsing_id != "":
		var wcn := card_nodes.get(_pulsing_id) as CardNode
		if wcn:
			wcn.stop_pulse(0.0)
		_pulsing_id = ""


# Build the cursor overlay: damage-type icon (if any) with the amount below it.
func _update_targeting_cursor(dmg_type: String, dmg_amount: int) -> void:
	if not _targeting_cursor:
		return
	var icon := _targeting_cursor.get_node("Icon") as Sprite2D
	var lbl  := _targeting_cursor.get_node("Amount") as Label

	if dmg_type != "":
		# Non-standard filenames for icons whose filename differs from the type key.
		var icon_file_map: Dictionary = {
			"heal":    "GreenCrossHeal",
			"destroy": "SkullDestroy",
			# Picking the ally a power eats as its cost (Gertha, Besh'iah) — the
			# same skull; the status line says which pick this is.
			"sacrifice": "SkullDestroy",
		}
		# Oversized icons need a compensating scale (standard is 0.55).
		var icon_scale_map: Dictionary = {
			"heal":      Vector2(0.055, 0.055),
			"destroy":   Vector2(0.55 / 8.0, 0.55 / 8.0),
			"sacrifice": Vector2(0.55 / 8.0, 0.55 / 8.0),
		}
		var key    := dmg_type.to_lower()
		var fname  := key if not icon_file_map.has(key) else (icon_file_map[key] as String)
		var path   := "res://assets/type_icons/%s.png" % fname
		var tex: Texture2D = load(path) if ResourceLoader.exists(path) else null
		if icon:
			icon.texture = tex
			icon.scale   = icon_scale_map[key] if icon_scale_map.has(key) else Vector2(0.55, 0.55)
			icon.visible = tex != null
	else:
		if icon:
			icon.visible = false

	if lbl:
		if dmg_amount > 0:
			lbl.text    = str(dmg_amount)
			lbl.visible = true
		else:
			lbl.visible = false

	_targeting_cursor.global_position  = _world_mouse()
	_targeting_cursor.rotation_degrees = view_rotation_degrees
	_targeting_cursor.visible          = true


# ── Hero HP bar ────────────────────────────────────────────────────────────────

# Returns the player_id if this card is currently in a hero_row, else "".
func _hero_player_for(card_id: String) -> String:
	for pid in ["p1", "p2"]:
		var zone_id: String = pid + "_hero_row"
		var zc: Array = _zone_cards.get(zone_id, [])
		if card_id in zc:
			return pid
	return ""


func _clear_hero_power_badge(player_id: String) -> void:
	var zone_id: String = player_id + "_hero_row"
	for cid in _zone_cards.get(zone_id, []):
		var cn := card_nodes.get(cid) as CardNode
		if cn and cn.has_method("set_power_used"):
			cn.set_power_used(false)


func _ensure_hero_bar(player_id: String) -> void:
	if _hero_bars.has(player_id):
		return
	# Bar matches the hero card's rendered height (hero cards draw at
	# HERO_CARD_SCALE), so it reads as part of the card rather than a stub.
	const BAR_W := 24.0 * HERO_CARD_SCALE
	const BAR_H := CardNode.H * HERO_CARD_SCALE

	var bg := ColorRect.new()
	bg.color        = Color(0.35, 0.05, 0.05)
	bg.size         = Vector2(BAR_W, BAR_H)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index      = 10
	# TTS-style facing: P2's bar (label + fill direction) faces P2, like their
	# cards. Rotation is about the bar's center, so positioning stays box-based.
	bg.pivot_offset      = bg.size * 0.5
	bg.rotation_degrees  = _facing_for_zone(player_id + "_hero_row")
	add_child(bg)

	var fill := ColorRect.new()
	fill.color        = Color(0.1, 0.45, 0.15)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(fill)

	var lbl := Label.new()
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

	# Bar sits on the hero card's BOARD-FACING side (P1's column is at screen-right,
	# P2's at screen-left), offset enough to clear the exhausted footprint (the card
	# rotates 90°, so its edge reaches H/2 * scale from centre). Placing it on the
	# outer side would push a full-size hero's bar off the 1920px viewport.
	var cn := card_nodes.get(card_id) as Node2D
	if cn:
		var half := CardNode.H * 0.5 * HERO_CARD_SCALE
		var dx := -(half + 6.0 + bg.size.x) if player_id == "p1" else half + 6.0
		bg.position = cn.global_position + Vector2(dx, -half)

	lbl.text = str(new_hp)
	var ratio: float = float(new_hp) / float(max(max_hp, 1))
	var fill_h: float = bg.size.y * ratio
	fill.size     = Vector2(bg.size.x, fill_h)
	fill.position = Vector2(0.0, bg.size.y - fill_h)


# The hero_row used to get a faint 4-card-wide placeholder rectangle so an empty
# zone still showed where cards land. The drawn zone grids (playtest's
# _draw_zone_grids) do that job properly now, and the placeholder's slightly
# lighter patch showed through them as an unexplained fog over the middle three
# slots — so it is gone.


# ── Deck count labels ──────────────────────────────────────────────────────────

func _create_deck_label(zone_id: String, _anchor: Node2D) -> void:
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
		# The deck sits half off-board (see the anchor comments in playtest.gd), so
		# the count goes on the INNER side of the card — the half that stays visible.
		if zone_id.begins_with("p2"):
			# Rotated 180° so the count reads upright for P2.
			lbl.pivot_offset      = Vector2(CardNode.W * 0.5, 10)
			lbl.rotation_degrees  = 180
			lbl.global_position   = anchor.global_position + Vector2(-CardNode.W * 0.5, CardNode.H * 0.5 + 6)
		else:
			lbl.pivot_offset      = Vector2.ZERO
			lbl.rotation_degrees  = 0
			lbl.global_position   = anchor.global_position + Vector2(-CardNode.W * 0.5, -(CardNode.H * 0.5 + 20))
	lbl.text = str(_deck_counts.get(zone_id, 0))


# ── Damage popup ───────────────────────────────────────────────────────────────

func _show_heal_number(card_id: String, amount: int) -> void:
	var origin := _number_origin(card_id)
	if origin == Vector2.ZERO:
		return
	var label := Label.new()
	label.text    = "+%d" % amount
	label.z_index = 20
	label.add_theme_font_size_override("font_size", 32)
	label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.35))
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.global_position = origin
	label.rotation_degrees = view_rotation_degrees   # upright + up-screen drift in either view
	get_tree().root.add_child(label)
	var tween := create_tween()
	tween.tween_property(label, "global_position",
			origin + Vector2(0, -60).rotated(deg_to_rad(view_rotation_degrees)), GameTiming.anim(0.9))
	tween.parallel().tween_property(label, "modulate:a", 0.0, GameTiming.anim(0.9))
	await tween.finished
	label.queue_free()


func _number_origin(card_id: String) -> Vector2:
	var hero_player := _hero_player_for(card_id)
	if hero_player != "":
		var bar: Dictionary = _hero_bars.get(hero_player, {})
		var bg := bar.get("bg") as ColorRect
		if bg:
			return bg.global_position + Vector2(bg.size.x * 0.5, 0)
		var hero_cn := card_nodes.get(card_id) as Node2D
		return hero_cn.global_position + Vector2(-20, -30) if hero_cn else Vector2.ZERO
	var cn := card_nodes.get(card_id) as Node2D
	return cn.global_position + Vector2(10, -30) if cn else Vector2.ZERO


func _show_damage_number(card_id: String, amount: int) -> void:
	var origin := _number_origin(card_id)
	if origin == Vector2.ZERO:
		return

	var label := Label.new()
	label.text     = "-%d" % amount
	label.z_index  = 20
	label.add_theme_font_size_override("font_size", 32)
	label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.global_position = origin
	label.rotation_degrees = view_rotation_degrees   # upright + up-screen drift in either view
	get_tree().root.add_child(label)
	var tween := create_tween()
	tween.tween_property(label, "global_position",
			origin + Vector2(0, -60).rotated(deg_to_rad(view_rotation_degrees)), GameTiming.anim(0.9))
	tween.parallel().tween_property(label, "modulate:a", 0.0, GameTiming.anim(0.9))
	await tween.finished
	label.queue_free()
