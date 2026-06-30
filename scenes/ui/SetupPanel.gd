extends Control

signal confirmed(p1_is_ai: bool, p2_is_ai: bool)

@onready var p1_option: OptionButton = $Overlay/Panel/VBox/P1Row/P1Option
@onready var p2_option: OptionButton = $Overlay/Panel/VBox/P2Row/P2Option

func _ready() -> void:
	for opt in [p1_option, p2_option]:
		opt.add_item("Human")
		opt.add_item("Basic AI")
	$Overlay/Panel/VBox/ConfirmBtn.pressed.connect(_on_confirm)

func _on_confirm() -> void:
	confirmed.emit(p1_option.selected == 1, p2_option.selected == 1)
