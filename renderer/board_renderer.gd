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

# player_id -> instance_id of that player's hero card. The hero card is pinned to a
# fixed "_hero_card" anchor beside the deck; everything else in "_hero_row" (equipment,
# non-attaching ongoing abilities) uses the normal centre-row spread.
var _hero_card_ids: Dictionary = {}


# card_id -> Tween of an in-flight death overlay fade. card_moved defers the
# move-to-graveyard animation until this finishes, so the card doesn't slide
# away while still covered in red.
var _death_tweens: Dictionary = {}

var _input_router: InputRouter = null
var _status_label: Label = null

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

# ── Wiggle tracking ────────────────────────────────────────────────────────────
# instance_id of the card currently in a continuous targeting wiggle ("" = none).
var _wiggling_id: String = ""

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

# In-play zones need wider spacing so exhausted (rotated 90°) cards don't overlap.
# When exhausted, a card's footprint is CardNode.H wide, so add ~20px margin.
# Hand/chain cards are never rotated, so CardNode.W + ~12px margin is fine there.
const PLAY_SPREAD_GAP := CardNode.H + 20.0

# Hand cards render 1.2x larger than table cards for readability.
const HAND_CARD_SCALE := 1.2
const HAND_SPREAD_GAP := CardNode.W * HAND_CARD_SCALE + 12.0

const PLAY_ZONES := ["p1_ally_row", "p2_ally_row",
	"p1_hero_row", "p2_hero_row",
	"p1_resource_row", "p2_resource_row"]


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
	var mouse := get_viewport().get_mouse_position()
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


func _build_inspector() -> void:
	_inspector = TextureRect.new()
	_inspector.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_inspector.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	_inspector.size         = Vector2(CardNode.W * 4, CardNode.H * 4)   # ~4× the card node
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
	if zone_id.ends_with("_hero_row"):
		_create_row_placeholder(zone_id, anchor)


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
	_apply_zone_scale(instance_id, zone_id)


func set_input_router(router: InputRouter) -> void:
	_input_router = router
	router.highlights_updated.connect(_on_highlights_updated)
	router.conditional_highlights_updated.connect(_on_conditional_highlights_updated)
	router.targeting_started.connect(_on_targeting_started)
	router.targeting_cancelled.connect(_on_targeting_cancelled)


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
		"card_exhausted":
			_animate_exhaust(event.payload["card"])
		"card_readied":
			_animate_ready(event.payload["card"])
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
			_set_status("Quest completed by %s — reward applied!" % event.payload.get("player", "?"))
		"hero_power_used":
			var hero_id: String = event.payload.get("hero_id", "")
			var hcn := card_nodes.get(hero_id) as CardNode
			if hcn:
				if hcn.has_method("set_power_used"):
					hcn.set_power_used(true)
				# If we were wiggling this card (targeted hero power), transition to 2-sec
				# post-resolution wiggle; otherwise start a fresh 2-sec wiggle (AoE / instant).
				if _wiggling_id == hero_id:
					hcn.stop_wiggle(2.0)
					_wiggling_id = ""
				else:
					hcn.wiggle_for(2.0)
			_set_status("%s used their hero power!" % event.payload.get("player", "?"))
		"ally_power_used":
			var ally_id: String = event.payload.get("ally_id", "")
			var acn := card_nodes.get(ally_id) as CardNode
			if acn:
				if _wiggling_id == ally_id:
					_wiggling_id = ""
					# Kill the continuous wiggle immediately so it doesn't fight the
					# exhaust rotation tween (0.2 s). snap to _wiggle_base; the exhaust
					# tween will override it to 90° before our 0.22 s timer fires.
					acn.stop_wiggle(0.0)
				# Delay until after the exhaust rotation tween (0.2 s) so wiggle_for
				# captures the correct exhausted/ready angle as its new base.
				var captured := acn
				get_tree().create_timer(0.22).timeout.connect(
					func() -> void:
						if is_instance_valid(captured):
							captured.wiggle_for(2.0))
		"action_proposed":
			if event.payload.get("action_type") == "place_resource" \
					and not event.payload.get("face_up", true):
				var cn := card_nodes.get(event.payload.get("card_id", "")) as CardNode
				if cn:
					cn.show_card_back()
			# Start a continuous wiggle on the source card when a non-targeted ally
			# power enters the stack (targeted powers start wiggling at targeting_started).
			if event.payload.get("action_type") == "use_ally_power" and _wiggling_id == "":
				var ap_id: String = event.payload.get("card_id", "")
				var apcn := card_nodes.get(ap_id) as CardNode
				if apcn:
					_wiggling_id = ap_id
					apcn.start_wiggle()
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
			var attacker_id: String = event.payload.get("attacker_id", "")
			await _animate_attack(attacker_id, event.payload.get("defender_id", ""))
			# Re-spread the attacker's zone: layout tweens can conflict with the
			# attack tween (they're not tracked in _pos_tweens), leaving cards misaligned.
			for zone_id in _zone_cards:
				if attacker_id in (_zone_cards.get(zone_id, []) as Array):
					_relayout_zone(zone_id)
					break
			var a_dmg: int = event.payload.get("attacker_damage", 0)
			var d_dmg: int = event.payload.get("defender_damage", 0)
			_set_status("⚔ Combat resolved  (dealt %d / received %d)" % [a_dmg, d_dmg])
		"phase_changed":
			pass   # no visual action needed on phase transitions
		"deck_shuffled":
			pass  # no visual needed; card_moved events handle the hand refill
		"game_over":
			_set_status("★ GAME OVER  —  %s wins!" % event.payload.get("winner", "?"))


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
		_relayout_zone(to_zone)
	else:
		var anchor := zone_anchors.get(to_zone) as Node2D
		if anchor:
			_kill_pos_tween(card_id)
			var tween := create_tween()
			tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
			tween.tween_property(card_node, "global_position", anchor.global_position, 0.3)
			_pos_tweens[card_id] = tween

	# RFG is not rendered — the card leaves the board entirely.
	if to_zone.ends_with("_rfg"):
		_remove_from_zone(card_id, to_zone)
		card_nodes.erase(card_id)
		card_node.queue_free()
		return

	# Deck cards have no persistent node — destroy the node after the move tween
	# so it's cleanly gone before the next draw spawns a fresh one.
	if to_zone.ends_with("_deck"):
		await get_tree().create_timer(0.3).timeout
		var still_in_deck: Array = _zone_cards.get(to_zone, [])
		if card_id in still_in_deck:
			_remove_from_zone(card_id, to_zone)
			card_nodes.erase(card_id)
			card_node.queue_free()


func _animate_exhaust(card_id: String) -> void:
	var card_node := card_nodes.get(card_id) as Node2D
	if not card_node:
		return
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "rotation_degrees", 90.0, 0.2)


func _animate_ready(card_id: String) -> void:
	var card_node := card_nodes.get(card_id) as CardNode
	if not card_node:
		return
	# Summoning sickness clears at the ready step — remove the Zzz/Grr badge.
	if card_node.has_method("hide_sick_badge"):
		card_node.hide_sick_badge()
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(card_node, "rotation_degrees", 0.0, 0.2)


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
	tween.tween_property(atk_node, "global_position", punch, 0.12)
	tween.tween_property(atk_node, "global_position", start, 0.10)
	_pos_tweens[attacker_id] = tween  # tracked so _kill_pos_tween can cancel mid-lunge
	await tween.finished
	_pos_tweens.erase(attacker_id)


# ── Zone layout helpers ────────────────────────────────────────────────────────

# Hand cards render bigger than table cards (see HAND_CARD_SCALE) — apply
# the right scale whenever a card enters or leaves a hand zone.
func _apply_zone_scale(card_id: String, zone_id: String) -> void:
	var node := card_nodes.get(card_id) as Node2D
	if not node:
		return
	node.scale = Vector2(HAND_CARD_SCALE, HAND_CARD_SCALE) if zone_id.ends_with("_hand") else Vector2.ONE


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


# "" unless zone_id is a hero_row with a registered hero card, in which case
# returns that hero card's instance_id.
func _hero_card_id_for_zone(zone_id: String) -> String:
	if not zone_id.ends_with("_hero_row"):
		return ""
	var pid := zone_id.substr(0, zone_id.length() - "_hero_row".length())
	return _hero_card_ids.get(pid, "")


# Cards in a hero_row zone, excluding the pinned hero card — used for the spread.
func _spread_cards(zone_id: String) -> Array:
	var zc: Array = _zone_cards.get(zone_id, [])
	var hero_id := _hero_card_id_for_zone(zone_id)
	if hero_id == "":
		return zc
	var out: Array = []
	for cid in zc:
		if cid != hero_id:
			out.append(cid)
	return out


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

	var gap: float = _spread_gap(zone_id)
	var zc: Array  = _spread_cards(zone_id)
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
	var gap: float = _spread_gap(zone_id)
	var count := spread_ids.size()
	var total := gap * (count - 1)
	for i in count:
		var node := card_nodes.get(spread_ids[i]) as Node2D
		if not node:
			continue
		var t: Tween = _pos_tweens.get(spread_ids[i])
		if t and t.is_valid() and t.is_running():
			continue   # in flight — its tween owns the final position
		var target := anchor.global_position + Vector2(-total * 0.5 + i * gap, 0.0)
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
	var gap: float = _spread_gap(zone_id)
	var zc: Array  = _spread_cards(zone_id)
	var count := zc.size()
	for i in count:
		var cid: String = zc[i]
		var node := card_nodes.get(cid) as Node2D
		if not node:
			continue
		var total  := gap * (count - 1)
		var target := anchor.global_position + Vector2(-total * 0.5 + i * gap, 0.0)
		_kill_pos_tween(cid)
		var tween  := create_tween()
		tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tween.tween_property(node, "global_position", target, 0.2)
		_pos_tweens[cid] = tween

	if hero_id != "" and hero_id in (_zone_cards.get(zone_id, []) as Array):
		var hnode := card_nodes.get(hero_id) as Node2D
		if hnode:
			var pid := zone_id.substr(0, zone_id.length() - "_hero_row".length())
			var hero_anchor := zone_anchors.get(pid + "_hero_card") as Node2D
			if hero_anchor:
				_kill_pos_tween(hero_id)
				var htween := create_tween()
				htween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
				htween.tween_property(hnode, "global_position", hero_anchor.global_position, 0.2)
				_pos_tweens[hero_id] = htween


func _kill_pos_tween(card_id: String) -> void:
	if _pos_tweens.has(card_id):
		var t: Tween = _pos_tweens[card_id]
		if t:
			t.kill()
		_pos_tweens.erase(card_id)


# Self-healing pass: snap each card's orientation to authoritative GameState.
# Event-driven animations (wiggle, exhaust/ready swings) can leave a card at a
# crooked resting angle if tweens race; this reasserts truth once motion settles.
# Visual-only, read-only on state, and idempotent (a no-op when already correct).
# Skips cards mid-animation: a live position tween (_pos_tweens) or an active
# wiggle (CardNode.is_wiggling) — so it never fights in-flight motion.
func reconcile_from_state(state) -> void:
	if state == null:
		return
	for card_id in card_nodes:
		if _pos_tweens.has(card_id):
			continue  # positional move / lunge in flight — leave it alone
		var cn := card_nodes.get(card_id) as CardNode
		if not cn or not is_instance_valid(cn):
			continue
		if cn.is_wiggling():
			continue  # effect cue mid-swing — reasserts on next pass
		var card = state.get_card(card_id)
		if card == null:
			continue
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
	# Wiggle the source card while the player is picking a target.
	_wiggling_id = source_id
	var wcn := card_nodes.get(source_id) as CardNode
	if wcn:
		wcn.start_wiggle()
	if _targeting_line:
		var cn := card_nodes.get(source_id) as Node2D
		var src := cn.global_position if cn else get_viewport().get_mouse_position()
		_targeting_line.set_point_position(0, src)
		_targeting_line.set_point_position(1, get_viewport().get_mouse_position())
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
	# Targeting cancelled — stop wiggle immediately.
	if _wiggling_id != "":
		var wcn := card_nodes.get(_wiggling_id) as CardNode
		if wcn:
			wcn.stop_wiggle(0.0)
		_wiggling_id = ""


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
		}
		# Oversized icons need a compensating scale (standard is 0.55).
		var icon_scale_map: Dictionary = {
			"heal":    Vector2(0.055, 0.055),
			"destroy": Vector2(0.55 / 8.0, 0.55 / 8.0),
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

	_targeting_cursor.global_position = get_viewport().get_mouse_position()
	_targeting_cursor.visible         = true


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


func _clear_hero_power_badge(player_id: String) -> void:
	var zone_id: String = player_id + "_hero_row"
	for cid in _zone_cards.get(zone_id, []):
		var cn := card_nodes.get(cid) as CardNode
		if cn and cn.has_method("set_power_used"):
			cn.set_power_used(false)


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


# ── Row placeholders ───────────────────────────────────────────────────────────
# The hero_row (equipment / ongoing abilities) is often empty, which otherwise
# leaves no visual trace of the zone. Draw a faint, always-visible slot so the
# player can see where those cards land.

func _create_row_placeholder(zone_id: String, anchor: Node2D) -> void:
	const PLACEHOLDER_W := CardNode.W * 4.0
	const PLACEHOLDER_H := CardNode.H
	var rect := ColorRect.new()
	rect.color         = Color(1.0, 1.0, 1.0, 0.06)
	rect.size          = Vector2(PLACEHOLDER_W, PLACEHOLDER_H)
	rect.position      = anchor.global_position - Vector2(PLACEHOLDER_W * 0.5, PLACEHOLDER_H * 0.5)
	rect.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	rect.z_index       = -1
	add_child(rect)


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
		lbl.global_position = anchor.global_position + Vector2(
			-CardNode.W * 0.5, CardNode.H * 0.5 + 4)
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
	get_tree().root.add_child(label)
	var tween := create_tween()
	tween.tween_property(label, "global_position", origin + Vector2(0, -60), 0.9)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 0.9)
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
	get_tree().root.add_child(label)
	var tween := create_tween()
	tween.tween_property(label, "global_position", origin + Vector2(0, -60), 0.9)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 0.9)
	await tween.finished
	label.queue_free()
