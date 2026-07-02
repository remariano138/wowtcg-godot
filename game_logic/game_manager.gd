class_name GameManager
extends RefCounted

# Bootstraps a complete GameState from player configs and decks.
#
# Usage:
#   var gm := GameManager.new()
#   gm.setup(db)
#   gm.add_player("p1", GameManager.HUMAN, deck_p1)
#   gm.add_player("p2", GameManager.AI,    deck_p2)
#   var state := gm.build_state()   # shuffles decks, draws hands, places heroes
#   # then call TurnManager.start_game(state, first_player, db)

const HUMAN := "human"
const AI    := "ai"

const STARTING_HAND_SIZE := 7

var _db: CardDatabase
var _players: Array = []   # Array of {id, type, deck}


func setup(db: CardDatabase) -> void:
	_db = db


func add_player(player_id: String, player_type: String, deck: Deck) -> void:
	_players.append({"id": player_id, "type": player_type, "deck": deck})


func build_state() -> GameState:
	var player_ids: Array[String] = []
	for p in _players:
		player_ids.append(p["id"])

	var state := GameState.create_new(player_ids)

	for p in _players:
		var pid: String   = p["id"]
		var deck: Deck    = p["deck"]

		# Place hero into hero row.
		_place_hero(state, pid, deck.hero_def_id)

		# Shuffle deck and populate deck zone.
		var shuffled := deck.card_def_ids.duplicate()
		shuffled.shuffle()
		for i in shuffled.size():
			var inst_id := "%s_deck_%d" % [pid, i]
			var card := CardInstance.create(inst_id, shuffled[i], pid, pid + "_deck")
			state.cards[inst_id] = card
			state.zones[pid + "_deck"].card_ids.append(inst_id)

		# Draw starting hand (rule 101.1: 7 cards before first turn).
		_draw_starting_hand(state, pid)

	return state


# ── Helpers ────────────────────────────────────────────────────────────────────

func _place_hero(state: GameState, player_id: String, hero_def_id: String) -> void:
	var inst_id := player_id + "_hero"
	var card := CardInstance.create(inst_id, hero_def_id, player_id, player_id + "_hero_row")
	state.cards[inst_id] = card
	state.zones[player_id + "_hero_row"].card_ids.append(inst_id)

	var ps := state.players.get(player_id) as PlayerState
	if ps:
		ps.hero_instance_id = inst_id


func _draw_starting_hand(state: GameState, player_id: String) -> void:
	var deck_zone := state.zones.get(player_id + "_deck") as Zone
	if not deck_zone:
		return
	for i in STARTING_HAND_SIZE:
		if deck_zone.card_ids.is_empty():
			push_warning("GameManager: deck ran out during starting hand draw for %s" % player_id)
			break
		var top_id: String = deck_zone.card_ids[0]
		# Move directly — no events emitted at setup time.
		GameLogic.move_card_silent(state, top_id, player_id + "_hand")
