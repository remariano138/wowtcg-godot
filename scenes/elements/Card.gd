extends Control

signal card_clicked(card: Control)
signal card_right_clicked(card: Control)
signal card_hovered(card: Control)
signal card_unhovered
signal card_died(card: Control)
signal health_changed(card: Control)
signal damaged(card: Control, amount: int)  # fired from take_damage() only, never heal()

var CARD_BACK: Texture2D = null

@onready var name_label: Label = $NameLabel
@onready var cost_label: Label = $CostLabel
@onready var color_rect: ColorRect = $ColorRect
@onready var card_image: TextureRect = $CardImage

var card_id: String = ""
var card_name: String = ""
var cost: int = -1       # total cost after X is chosen; -1 = free/unknown
var cost_x: bool = false # true if cost contains X
var cost_base: int = 0   # fixed part (1 in "1+X", 0 in pure "X")
var chosen_x: int = 0    # value chosen by player at play time
var atk: int = 0
var printed_atk: int = 0    # ATK as printed on the card; effects may change atk but not this
var atk_modifier: int = 0  # sum of aura_atk_modifier + berserking_atk_modifier, kept in sync by _recalc_atk()
var aura_atk_modifier: int = 0        # from other cards' continuous auras (e.g. Kailis's party-size buff)
var berserking_atk_modifier: int = 0  # from this card's own "berserking" trigger, scales with its own damage
var current_health: int = 0
var max_health: int = 0
var printed_health: int = 0  # health as printed on the card; effects may change max_health but not this
var health_modifier: int = 0  # sum of active continuous effects' health adjustments (not damage)
var damage_taken: int = 0     # combat/effect damage accumulated; current_health is derived from this
var card_type: String = ""
var alignment: String = ""
var tags: String = ""
var dmg_type: String = ""
var power_text: String = ""
var card_class: String = ""
var card_subtype: String = ""
var keywords: Array = []
var granted_keywords: Array = []  # keywords granted by another card's continuous effect (e.g. Sentry Gwynn -> hero Elusive), recomputed from scratch each time, not printed on this card
var effects: String = ""  # raw effects-column recipe(s); parsed/used by CardEffects
var card_owner: String = "player_1"
var face_down: bool = false
var exhausted: bool = false
var just_summoned: bool = false
var power_used: bool = false       # hero flip powers: true once used, for the rest of the game
var _used_this_turn: bool = false  # generic once-per-turn flag for non-exhaust activated powers
var _front_texture: Texture2D = null
var _zzz_label: Label = null
var _used_label: Label = null

func setup(p_card_id: String, database: Node) -> void:
	var data = database.get_card(p_card_id)
	card_id = p_card_id
	card_name = data.get("name", "")
	var cost_str = data.get("cost", "")
	if "X" in cost_str:
		cost_x    = true
		cost_base = int(cost_str.split("+")[0]) if "+" in cost_str else 0
		cost      = -1
	else:
		cost = int(cost_str) if cost_str != "" else -1
	printed_atk = int(data["atk"]) if data.get("atk", "") != "" else 0
	atk_modifier = 0
	atk = printed_atk
	printed_health = int(data["health"]) if data.get("health", "") != "" else 0
	health_modifier = 0
	damage_taken = 0
	_recalc_health()
	card_type = data.get("type", "")
	alignment = data.get("alignment", "")
	tags = data.get("tags", "")
	dmg_type = data.get("dmg_type", "")
	power_text   = data.get("power_text", "")
	card_class   = data.get("class", "")
	card_subtype = data.get("subtype", "")
	effects      = data.get("effects", "")
	var keywords_str = data.get("keywords", "")
	keywords = []
	if keywords_str != "":
		for k in keywords_str.split(","):
			keywords.append(k.strip_edges().to_lower())

	name_label.text = card_name
	cost_label.text = str(cost) if cost >= 0 else ""

	var image_path = data.get("image_path", "")
	if image_path != "" and image_path != "No match":
		var res_path = "res://" + image_path.replace("\\", "/")
		var texture = load(res_path)
		if texture:
			_front_texture = texture
			card_image.texture = texture
			card_image.visible = true
			color_rect.visible = false
			name_label.visible = false
			cost_label.visible = false

func set_face_down(value: bool) -> void:
	face_down = value
	if value:
		card_image.texture = CARD_BACK
		card_image.visible = true
		color_rect.visible = false
		name_label.visible = false
		cost_label.visible = false
	else:
		if _front_texture:
			card_image.texture = _front_texture
			card_image.visible = true
			color_rect.visible = false
			name_label.visible = false
			cost_label.visible = false
		else:
			card_image.visible = false
			color_rect.visible = true
			name_label.visible = true
			cost_label.visible = true

func has_keyword(keyword: String) -> bool:
	return keyword.to_lower() in keywords or keyword.to_lower() in granted_keywords

func _recalc_health() -> void:
	max_health = max(printed_health + health_modifier, 0)
	current_health = max(max_health - damage_taken, 0)
	health_changed.emit(self)
	if current_health == 0:
		card_died.emit(self)

func take_damage(amount: int) -> void:
	damage_taken += amount
	_recalc_health()
	damaged.emit(self, amount)

func heal(amount: int) -> void:
	damage_taken = max(damage_taken - amount, 0)
	_recalc_health()

# Sets this card's continuous-effect health adjustment (e.g. an aura granting
# -1 health). Recomputed from scratch each time by whoever owns the aura —
# callers should pass the full current total, not a delta.
func set_health_modifier(amount: int) -> void:
	if amount == health_modifier:
		return
	health_modifier = amount
	_recalc_health()

func reset_to_printed_hp() -> void:
	health_modifier = 0
	damage_taken = 0
	_recalc_health()
	aura_atk_modifier = 0
	berserking_atk_modifier = 0
	_recalc_atk()

func _recalc_atk() -> void:
	atk_modifier = aura_atk_modifier + berserking_atk_modifier
	atk = printed_atk + atk_modifier

# Sets this card's ATK adjustment from OTHER cards' continuous auras (e.g.
# Kailis's party-size buff). Recomputed from scratch each time by whoever owns
# the aura — callers should pass the full current total, not a delta. Kept
# separate from berserking_atk_modifier so recomputing one never clobbers the
# other — both feed into the same `atk` via _recalc_atk().
func set_aura_atk_modifier(amount: int) -> void:
	if amount == aura_atk_modifier:
		return
	aura_atk_modifier = amount
	_recalc_atk()

# Sets this card's ATK adjustment from its OWN "berserking" trigger (+ATK per
# damage on itself). See set_aura_atk_modifier for why this is a separate field.
func set_berserking_atk_modifier(amount: int) -> void:
	if amount == berserking_atk_modifier:
		return
	berserking_atk_modifier = amount
	_recalc_atk()

func set_just_summoned(value: bool) -> void:
	just_summoned = value
	if value:
		var has_ferocity = has_keyword("ferocity")
		if not _zzz_label:
			_zzz_label = Label.new()
			_zzz_label.add_theme_font_size_override("font_size", 28)
			_zzz_label.add_theme_constant_override("outline_size", 2)
			_zzz_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
			_zzz_label.layout_mode = 0
			_zzz_label.mouse_filter = MOUSE_FILTER_IGNORE
			add_child(_zzz_label)
		if has_ferocity:
			_zzz_label.text = "Grrr..."
			_zzz_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.2, 1.0))
		else:
			_zzz_label.text = "Zzz"
			_zzz_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 1.0))
		_zzz_label.position = Vector2(size.x * 0.55, size.y * 0.08)
		_zzz_label.visible = true
	else:
		if _zzz_label:
			_zzz_label.visible = false

func set_power_used(value: bool) -> void:
	power_used = value
	if value:
		if not _used_label:
			_used_label = Label.new()
			_used_label.text = "USED"
			_used_label.add_theme_font_size_override("font_size", 22)
			_used_label.add_theme_color_override("font_color", Color(0.9, 0.2, 0.2, 1.0))
			_used_label.add_theme_constant_override("outline_size", 2)
			_used_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
			_used_label.layout_mode = 0
			_used_label.mouse_filter = MOUSE_FILTER_IGNORE
			add_child(_used_label)
		_used_label.position = Vector2(size.x * 0.05, size.y * 0.62)
		_used_label.visible = true
	else:
		if _used_label:
			_used_label.visible = false

# Generic once-per-turn gate for activated powers that don't cost exhausting
# themselves (e.g. a resource-only or free power limited to once per turn).
# The caller (CardEffects/DuelTable) decides whether a given power is subject
# to this; reset_turn_flags() is called from this card's controller's turn start.
func can_activate_once_per_turn() -> bool:
	return not _used_this_turn

func mark_activated_this_turn() -> void:
	_used_this_turn = true

func reset_turn_flags() -> void:
	_used_this_turn = false

func exhaust() -> void:
	exhausted = true
	pivot_offset = size / 2.0
	rotation_degrees = 90.0

func ready_card() -> void:
	exhausted = false
	pivot_offset = size / 2.0
	rotation_degrees = 0.0

func set_display_size(new_size: Vector2) -> void:
	custom_minimum_size = new_size
	size = new_size
	size_flags_vertical = SIZE_SHRINK_CENTER

func _notification(what: int) -> void:
	# Re-apply rotation if the container changes this card's size
	if what == NOTIFICATION_RESIZED and exhausted:
		pivot_offset = size / 2.0
		rotation_degrees = 90.0

func _ready() -> void:
	CARD_BACK = load("res://assets/card_backs/wowTCGdefaultback.jpg")
	mouse_entered.connect(func(): card_hovered.emit(self))
	mouse_exited.connect(func(): card_unhovered.emit())

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and not Input.is_key_pressed(KEY_ALT):
			card_clicked.emit(self)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			card_right_clicked.emit(self)
