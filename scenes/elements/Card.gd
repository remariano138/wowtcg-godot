extends Control

signal card_clicked(card: Control)
signal card_right_clicked(card: Control)
signal card_hovered(card: Control)
signal card_unhovered
signal card_died(card: Control)
signal health_changed(card: Control)

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
var current_health: int = 0
var max_health: int = 0
var printed_health: int = 0  # health as printed on the card; effects may change max_health but not this
var card_type: String = ""
var alignment: String = ""
var tags: String = ""
var dmg_type: String = ""
var card_text: String = ""
var card_class: String = ""
var card_subtype: String = ""
var card_owner: String = "player_1"
var face_down: bool = false
var exhausted: bool = false
var just_summoned: bool = false
var _front_texture: Texture2D = null
var _zzz_label: Label = null

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
	atk = int(data["atk"]) if data.get("atk", "") != "" else 0
	max_health = int(data["health"]) if data.get("health", "") != "" else 0
	printed_health = max_health
	current_health = max_health
	card_type = data.get("type", "")
	alignment = data.get("alignment", "")
	tags = data.get("tags", "")
	dmg_type = data.get("dmg_type", "")
	card_text    = data.get("card_text", "")
	card_class   = data.get("class", "")
	card_subtype = data.get("subtype", "")

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

func take_damage(amount: int) -> void:
	current_health = max(current_health - amount, 0)
	health_changed.emit(self)
	if current_health == 0:
		card_died.emit(self)

func reset_to_printed_hp() -> void:
	max_health = printed_health
	current_health = printed_health
	health_changed.emit(self)

func set_just_summoned(value: bool) -> void:
	just_summoned = value
	if value:
		if not _zzz_label:
			_zzz_label = Label.new()
			_zzz_label.text = "Zzz"
			_zzz_label.add_theme_font_size_override("font_size", 28)
			_zzz_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 1.0))
			_zzz_label.add_theme_constant_override("outline_size", 2)
			_zzz_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
			_zzz_label.layout_mode = 0
			_zzz_label.mouse_filter = MOUSE_FILTER_IGNORE
			add_child(_zzz_label)
		_zzz_label.position = Vector2(size.x * 0.55, size.y * 0.08)
		_zzz_label.visible = true
	else:
		if _zzz_label:
			_zzz_label.visible = false

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
