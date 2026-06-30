extends Control

signal rematch_requested
signal new_game_requested
signal quit_requested

@onready var title_label:  Label  = $Overlay/Panel/VBox/TitleLabel
@onready var score_label:  Label  = $Overlay/Panel/VBox/ScoreLabel
@onready var rematch_btn:  Button = $Overlay/Panel/VBox/Buttons/RematchButton
@onready var new_game_btn: Button = $Overlay/Panel/VBox/Buttons/NewGameButton
@onready var quit_btn:     Button = $Overlay/Panel/VBox/Buttons/QuitButton

func _ready() -> void:
	rematch_btn.pressed.connect(func(): rematch_requested.emit())
	new_game_btn.pressed.connect(func(): new_game_requested.emit())
	quit_btn.pressed.connect(func(): quit_requested.emit())

func _wins_str(n: int) -> String:
	return "%d win" % n if n <= 1 else "%d wins" % n

func show_result(winner: String, p1_wins: int, p2_wins: int) -> void:
	title_label.text = "%s Wins!" % winner
	score_label.text = "Player 1: %s  |  Player 2: %s" % [_wins_str(p1_wins), _wins_str(p2_wins)]
	visible = true
