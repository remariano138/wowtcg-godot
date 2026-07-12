class_name StatTracker
extends RefCounted

# Per-player match statistics, fed from the game event stream.
#
# This is a passive OBSERVER: it never touches game state or the bus, it only
# reads GameEvents it is handed (see record_event). Wire it up by calling
# record_event() for every event the renderer receives, then read the counters
# when the game ends (Game Over screen). Reset() at the start of each match.
#
# Definitions:
#   cards_drawn  — any card that entered a player's hand from their deck
#                  (turn draws, effect draws, mulligan redraw). The silent
#                  opening-hand deal uses move_card_silent and is NOT counted.
#   cards_played — a card played from hand (ally / instant / ability /
#                  equipment). Placing a resource is NOT a play and is excluded
#                  (it is a separate action; see submit_action). Fed by the
#                  dedicated "card_played" event.

# player_id ("p1"/"p2") → count
var cards_drawn:  Dictionary = {"p1": 0, "p2": 0}
var cards_played: Dictionary = {"p1": 0, "p2": 0}


func reset() -> void:
	cards_drawn  = {"p1": 0, "p2": 0}
	cards_played = {"p1": 0, "p2": 0}


# Hand this every GameEvent as it is emitted. Cheap and idempotent per event.
func record_event(event: GameEvent) -> void:
	match event.event_type:
		"card_moved":
			var from_zone: String = event.payload.get("from", "")
			var to_zone:   String = event.payload.get("to", "")
			if from_zone.ends_with("_deck") and to_zone.ends_with("_hand"):
				_bump(cards_drawn, _player_of_zone(to_zone))
		"card_played":
			_bump(cards_played, event.payload.get("player", ""))


func drawn(player_id: String) -> int:
	return int(cards_drawn.get(player_id, 0))


func played(player_id: String) -> int:
	return int(cards_played.get(player_id, 0))


func _bump(counter: Dictionary, player_id: String) -> void:
	if player_id == "":
		return
	counter[player_id] = int(counter.get(player_id, 0)) + 1


# "p1_hand" → "p1"
static func _player_of_zone(zone_id: String) -> String:
	var idx := zone_id.find("_")
	return zone_id.substr(0, idx) if idx > 0 else ""
