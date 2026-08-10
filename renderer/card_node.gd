class_name CardNode
extends Node2D

# Visual representation of one card. Handles its own click detection via Area2D.
# Tells listeners what was clicked (instance_id) but makes no game decisions.
# BoardRenderer owns all CardNodes and bridges their signals to InputRouter.

signal card_clicked(instance_id: String)
signal card_right_clicked(instance_id: String)
signal card_hovered(instance_id: String)
signal card_unhovered(instance_id: String)

const W := 75.0
const H := 105.0

const CARD_BACK_PATH := "res://assets/card_backs/wowTCGdefaultback.jpg"

# ATK badge colours — green when the card's ATK is above its printed value,
# red when it's below (Hootie's -1 aura and friends). See update_atk.
const BADGE_BUFF_COLOR   := Color(0.15, 0.75, 0.2)
const BADGE_DEBUFF_COLOR := Color(0.8, 0.18, 0.18)

var instance_id: String = ""
var _bg: ColorRect
var _tex_rect: TextureRect   # shown when a real image is loaded
var _front_texture: Texture2D = null
var _is_face_down: bool = false
# Which way the card faces: 0 = toward P1 (bottom of screen), 180 = toward P2
# (top). Every rotation write (exhaust/ready/settle) composes with this base,
# so P2's cards stay upside-down to the P1 viewer, Tabletop-Simulator style.
var facing_degrees: float = 0.0
# True while this card is attached to a host (rule 400). Attachments peek out
# from behind their host and would otherwise steal clicks meant for it; an
# attachment stays hoverable (Alt+hover inspector still works) but does not
# consume mouse clicks.
var is_attachment: bool = false
var _is_highlighted: bool = false
var _base_color: Color = Color(0.25, 0.45, 0.75)
var _mouse_inside: bool = false
var _damage_badge: Label = null
var _power_used_badge: Label = null
var _sick_badge: Label = null
var _mute_badge: Label = null
var _ready_lock_badge: Label = null
var _outline: ColorRect = null
var _atk_badge_bg: Panel = null
var _atk_badge_lbl: Label = null
var _counter_badge_bg: Panel = null
var _counter_badge_lbl: Label = null
var _hp_badge_bg: Panel = null
var _hp_badge_lbl: Label = null
var _stats_lbl: Label = null

# Set true while a modal overlay (graveyard browser, X-value dialog, …) is open
# so board cards underneath don't intercept clicks/hover meant for the overlay.
# CardNode detects clicks via raw _input() (screen-space bounding box), which
# runs before Control._gui_input — so it fires even when a Control is drawn on
# top, unless callers explicitly gate it with this flag.
static var input_blocked: bool = false

# Exception list for `input_blocked`: instance ids that STAY clickable while the
# board is blocked. Used by choice points where clicking a specific board card IS
# one of the popup's options (armor at the prevention point, weapon at the strike
# point, ally at the protect point) — everything else on the board is inert, so a
# missed click can't be re-read as e.g. an attacker selection. Always cleared by
# whoever set it (see `_set_board_block` in playtest.gd).
static var input_allowlist: Array = []

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
	node._stats_lbl = stats_lbl

	# ATK-buff badge — white number in a green circle, bottom-left corner.
	# Hidden by default; shown (replacing the printed ATK) while a buff is active.
	const BADGE_D := 22.0
	var atk_bg := Panel.new()
	var atk_style := StyleBoxFlat.new()
	atk_style.bg_color = BADGE_BUFF_COLOR
	atk_style.set_corner_radius_all(int(BADGE_D * 0.5))
	atk_bg.add_theme_stylebox_override("panel", atk_style)
	atk_bg.size     = Vector2(BADGE_D, BADGE_D)
	atk_bg.position = Vector2(-W * 0.5 + 2, H * 0.5 - BADGE_D - 2)
	atk_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	atk_bg.visible  = false
	node.add_child(atk_bg)
	node._atk_badge_bg = atk_bg

	var atk_lbl := Label.new()
	atk_lbl.add_theme_font_size_override("font_size", 13)
	atk_lbl.add_theme_color_override("font_color", Color.WHITE)
	atk_lbl.size     = Vector2(BADGE_D, BADGE_D)
	atk_lbl.position = atk_bg.position
	atk_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	atk_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	atk_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	atk_lbl.visible  = false
	node.add_child(atk_lbl)
	node._atk_badge_lbl = atk_lbl

	# Counter badge — white number in an orange circle, bottom-left corner
	# (same treatment as the ATK-buff badge; used by cards that accumulate
	# counters and have no printed ATK of their own, e.g. Berserking's berserk
	# counters). Hidden while the count is 0.
	var ctr_bg := Panel.new()
	var ctr_style := StyleBoxFlat.new()
	ctr_style.bg_color = Color(0.85, 0.4, 0.1)
	ctr_style.set_corner_radius_all(int(BADGE_D * 0.5))
	ctr_bg.add_theme_stylebox_override("panel", ctr_style)
	ctr_bg.size     = Vector2(BADGE_D, BADGE_D)
	ctr_bg.position = Vector2(-W * 0.5 + 2, H * 0.5 - BADGE_D - 2)
	ctr_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ctr_bg.visible  = false
	node.add_child(ctr_bg)
	node._counter_badge_bg = ctr_bg

	var ctr_lbl := Label.new()
	ctr_lbl.add_theme_font_size_override("font_size", 13)
	ctr_lbl.add_theme_color_override("font_color", Color.WHITE)
	ctr_lbl.size     = Vector2(BADGE_D, BADGE_D)
	ctr_lbl.position = ctr_bg.position
	ctr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ctr_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	ctr_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ctr_lbl.visible  = false
	node.add_child(ctr_lbl)
	node._counter_badge_lbl = ctr_lbl

	# HP-buff badge — white number in a blue circle, bottom-right corner.
	# Hidden by default; shown (replacing the printed HP) while a buff is active.
	var hp_bg := Panel.new()
	var hp_style := StyleBoxFlat.new()
	hp_style.bg_color = Color(0.2, 0.45, 0.85)
	hp_style.set_corner_radius_all(int(BADGE_D * 0.5))
	hp_bg.add_theme_stylebox_override("panel", hp_style)
	hp_bg.size     = Vector2(BADGE_D, BADGE_D)
	hp_bg.position = Vector2(W * 0.5 - BADGE_D - 2, H * 0.5 - BADGE_D - 2)
	hp_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_bg.visible  = false
	node.add_child(hp_bg)
	node._hp_badge_bg = hp_bg

	var hp_lbl := Label.new()
	hp_lbl.add_theme_font_size_override("font_size", 13)
	hp_lbl.add_theme_color_override("font_color", Color.WHITE)
	hp_lbl.size     = Vector2(BADGE_D, BADGE_D)
	hp_lbl.position = hp_bg.position
	hp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	hp_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_lbl.visible  = false
	node.add_child(hp_lbl)
	node._hp_badge_lbl = hp_lbl

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

	# Muted badge (🔇, top-left) — the card is silenced for auto-pass purposes
	# (context-menu Mute; see InputRouter.muted_ids).
	var mute_lbl := Label.new()
	mute_lbl.text = "🔇"
	mute_lbl.add_theme_font_size_override("font_size", 22)
	mute_lbl.add_theme_constant_override("outline_size", 4)
	mute_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1.0))
	mute_lbl.size         = Vector2(30, 26)
	mute_lbl.position     = Vector2(-W * 0.5 + 4, -H * 0.5 + 4)
	mute_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mute_lbl.visible      = false
	node.add_child(mute_lbl)
	node._mute_badge = mute_lbl

	# Ready-lock badge (⛓, top-right) — the card won't ready during its
	# controller's next ready step (Entangling Roots, Earthbind Totem).
	var lock_lbl := Label.new()
	lock_lbl.text = "⛓"
	lock_lbl.add_theme_font_size_override("font_size", 22)
	lock_lbl.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0))
	lock_lbl.add_theme_constant_override("outline_size", 4)
	lock_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1.0))
	lock_lbl.size         = Vector2(30, 26)
	lock_lbl.position     = Vector2(W * 0.5 - 30, -H * 0.5 + 4)
	lock_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lock_lbl.visible      = false
	node.add_child(lock_lbl)
	node._ready_lock_badge = lock_lbl

	# Try to load the real card image.
	if image_path != "" and image_path != "No match":
		var res_path := "res://" + image_path.replace("\\", "/")
		var texture: Texture2D = load(res_path)
		if texture:
			node._front_texture = texture
			node._show_texture(texture)

	node._atk_badge_bg.visible  = false
	node._atk_badge_lbl.visible = false
	node._hp_badge_bg.visible   = false
	node._hp_badge_lbl.visible  = false
	node._counter_badge_bg.visible  = false
	node._counter_badge_lbl.visible = false
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


# Show/hide the ATK-buff badge. When the card's current ATK differs from its
# printed value, the badge (white number in a green circle, bottom-left) is
# shown in place of the printed ATK; otherwise it's hidden and the printed
# ATK/HP text (set at creation) is the only thing visible.
#
# atk_if_attacking (optional) is the ATK this card would have if it were the
# combat attacker right now (see GameState.get_atk_if_attacking). "While
# attacking"-only buffs (Rayder, Zorm, For the Horde!) don't apply outside of
# combat, so current_atk == printed_atk even though the card carries a
# conditional buff — in that case we still show the badge with a trailing
# "*" so the player knows the buff exists but only fires on attack.
# Show/hide the counter badge (white number in an orange circle, bottom-left) —
# the same visual treatment as a buffed ATK value. Pass 0 to hide it.
func update_counter(count: int) -> void:
	if not _counter_badge_bg or not _counter_badge_lbl:
		return
	var show_it := count > 0
	_counter_badge_bg.visible  = show_it
	_counter_badge_lbl.visible = show_it
	if show_it:
		_counter_badge_lbl.text = str(count)


func update_atk(current_atk: int, printed_atk: int, atk_if_attacking: int = -1,
		raw_atk: int = 0) -> void:
	if not _atk_badge_bg or not _atk_badge_lbl:
		return
	if atk_if_attacking < 0:
		atk_if_attacking = current_atk
	var buffed := current_atk != printed_atk
	var attack_only := not buffed and atk_if_attacking != printed_atk
	# Something is subtracting ATK, but the 0 floor swallowed it (a 0-ATK hero
	# under Hootie's -1 aura). The value the card fights with is unchanged, so
	# show it explicitly rather than leaving the player with a blank card and no
	# sign the aura is live. See GameState.get_atk_raw.
	var suppressed := not buffed and raw_atk < 0
	var show_it := buffed or attack_only or suppressed
	_atk_badge_bg.visible  = show_it
	_atk_badge_lbl.visible = show_it
	if not show_it:
		return
	# The badge colour says which DIRECTION the ATK moved, since the same badge
	# now carries debuffs (Hootie's aura) as well as buffs. A modifier that ends
	# up net-neutral (a -1 aura cancelling a +1 buff) shows nothing at all —
	# there is no number worth reading. The floored case is a debuff regardless:
	# the value only matches the printed one because ATK can't go below 0.
	var shown := current_atk
	if buffed:
		_atk_badge_lbl.text = str(current_atk)
	elif attack_only:
		shown = atk_if_attacking
		_atk_badge_lbl.text = "%d*" % atk_if_attacking
	else:
		_atk_badge_lbl.text = str(current_atk)
	var debuffed := suppressed or shown < printed_atk
	var style := _atk_badge_bg.get_theme_stylebox("panel") as StyleBoxFlat
	if style:
		style.bg_color = BADGE_DEBUFF_COLOR if debuffed else BADGE_BUFF_COLOR


# Show/hide the HP-buff badge, mirroring update_atk but for max health
# (e.g. Nerra Lifeboon's party health aura). Bottom-right corner, blue circle.
func update_hp(current_hp: int, printed_hp: int) -> void:
	if not _hp_badge_bg or not _hp_badge_lbl:
		return
	var buffed := current_hp != printed_hp
	_hp_badge_bg.visible  = buffed
	_hp_badge_lbl.visible = buffed
	if buffed:
		_hp_badge_lbl.text = str(current_hp)


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


func set_muted(muted: bool) -> void:
	if _mute_badge:
		_mute_badge.visible = muted


func set_ready_locked(locked: bool) -> void:
	if _ready_lock_badge:
		_ready_lock_badge.visible = locked


func set_power_used(used: bool) -> void:
	if _power_used_badge:
		_power_used_badge.visible = used


func set_highlighted(highlighted: bool, color: Color = Color(0.2, 1.0, 0.3)) -> void:
	_is_highlighted = highlighted
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


# True while a wiggle tween is animating this card's rotation. Reconcile passes
# skip wiggling cards so they don't fight the effect cue mid-swing.
func is_wiggling() -> bool:
	return _wiggle_tween != null


# Snap rotation to match authoritative state (facing + 90° when exhausted).
# No-op while wiggling. Also re-bases the wiggle so a later stop_wiggle() snaps
# to the correct orientation instead of a stale/crooked angle. Visual-only.
func settle_rotation(exhausted: bool) -> void:
	if _wiggle_tween != null:
		return
	var target := facing_degrees + (90.0 if exhausted else 0.0)
	rotation_degrees = target
	_wiggle_base = target


func _input(event: InputEvent) -> void:
	if input_blocked and not input_allowlist.has(instance_id):
		if _mouse_inside:
			_mouse_inside = false
			card_unhovered.emit(instance_id)
		return
	# get_global_mouse_position is camera-aware (the board camera can be rotated
	# 180° for the P2 view); the raw viewport mouse position is NOT.
	var local: Vector2 = to_local(get_global_mouse_position())
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
	# Attachments are normally click-through so clicks reach the host underneath.
	# Exception: while it's a highlighted legal target (e.g. Kavai's
	# destroy-ability power aimed at Flame Shock attached to a hero), the
	# attachment's exposed peek strip must be clickable to pick it as a target.
	if is_attachment and not _is_highlighted:
		return
	var mb := event as InputEventMouseButton
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			card_clicked.emit(instance_id)
			get_viewport().set_input_as_handled()
		MOUSE_BUTTON_RIGHT:
			card_right_clicked.emit(instance_id)
			get_viewport().set_input_as_handled()
