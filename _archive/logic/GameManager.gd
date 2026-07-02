class_name GameManager
extends Node

enum TurnState { BEGINNING, P1, P2 }

@onready var card_database: Node = $CardDatabase
@onready var deck_manager:  Node = $DeckManager

var turn_state: TurnState = TurnState.BEGINNING
var first_player: String  = "player_1"
var player1_is_ai: bool   = false
var player2_is_ai: bool   = false
var player1_wins: int = 0
var player2_wins: int = 0

var hand: Array = []
var board: Array = []
var player1_resources: int = 0
var player2_resources: int = 0
var player1_pet_capacity: int = 1
var player2_pet_capacity: int = 1
var player1_deck: Deck = null
var player2_deck: Deck = null
var player1_draw_pile: Array = []
var player2_draw_pile: Array = []

func play_card(card: Control) -> bool:
	if not hand.has(card):
		return false
	hand.erase(card)
	board.append(card)
	print("Hand: ", hand.map(func(c): return c.card_id))
	print("Board: ", board.map(func(c): return c.card_id))
	return true
