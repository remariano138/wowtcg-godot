extends Node2D

const CARD_SCENE = preload("res://scenes/elements/Card.tscn")
const CARD_WIDTH = 120
const CARD_SPACING = 20

@onready var card_database: Node = $CardDatabase

func _ready() -> void:
	var x = 0
	for card_id in card_database._db.keys():
		var card = CARD_SCENE.instantiate()
		add_child(card)
		card.position = Vector2(x, 0)
		card.setup(card_id, card_database)
		x += CARD_WIDTH + CARD_SPACING
