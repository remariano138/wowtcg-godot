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
#   cards_drawn  — starts at STARTING_HAND_SIZE (7) to account for the silent
#                  opening-hand deal (move_card_silent, not itself observed as
#                  an event), then increments for any further card that enters
#                  a player's hand from their deck (turn draws, effect draws,
#                  mulligan redraw). Cards moved from hand back to deck (the
#                  mulligan return) decrement, keeping the count symmetric so
#                  the base-7 opening deal isn't double-counted on a mulligan.
#   cards_played — a card played from hand (ally / instant / ability /
#                  equipment). Placing a resource is NOT a play and is excluded
#                  (it is a separate action; see submit_action). Fed by the
#                  dedicated "card_played" event.
#   damage_prevented — damage points that never landed on a player's characters
#                  because something prevented them (rule 717.2): armor exhausted
#                  at the prevention point, and the automatic shields (Brother
#                  Rhone, Bestial Wrath). Counted for the player who BENEFITED —
#                  the prevented packet's target's controller — so it reads as
#                  "how much did my armor save me". Unpreventable damage
#                  (Lionheart Helm, Annihilator) emits nothing and so counts 0.

# player_id ("p1"/"p2") → count
var cards_drawn:      Dictionary = {"p1": 7, "p2": 7}
var cards_played:     Dictionary = {"p1": 0, "p2": 0}
var damage_prevented: Dictionary = {"p1": 0, "p2": 0}


func reset() -> void:
	cards_drawn      = {"p1": 7, "p2": 7}
	cards_played     = {"p1": 0, "p2": 0}
	damage_prevented = {"p1": 0, "p2": 0}


# Hand this every GameEvent as it is emitted. Cheap and idempotent per event.
func record_event(event: GameEvent) -> void:
	match event.event_type:
		"card_moved":
			var from_zone: String = event.payload.get("from", "")
			var to_zone:   String = event.payload.get("to", "")
			if from_zone.ends_with("_deck") and to_zone.ends_with("_hand"):
				_bump(cards_drawn, _player_of_zone(to_zone))
			# Symmetric un-draw: cards returned from hand to deck (mulligan
			# redraw, rule 103.4) decrement so the base-7 opening deal isn't
			# double-counted when the redrawn 7 come back as card_moved events.
			elif from_zone.ends_with("_hand") and to_zone.ends_with("_deck"):
				_unbump(cards_drawn, _player_of_zone(from_zone))
		"card_played":
			_bump(cards_played, event.payload.get("player", ""))
		"damage_prevented":
			_add(damage_prevented, event.payload.get("controller", ""),
				int(event.payload.get("amount", 0)))


func drawn(player_id: String) -> int:
	return int(cards_drawn.get(player_id, 0))


func played(player_id: String) -> int:
	return int(cards_played.get(player_id, 0))


func prevented(player_id: String) -> int:
	return int(damage_prevented.get(player_id, 0))


func _bump(counter: Dictionary, player_id: String) -> void:
	if player_id == "":
		return
	counter[player_id] = int(counter.get(player_id, 0)) + 1


func _add(counter: Dictionary, player_id: String, amount: int) -> void:
	if player_id == "" or amount <= 0:
		return
	counter[player_id] = int(counter.get(player_id, 0)) + amount


func _unbump(counter: Dictionary, player_id: String) -> void:
	if player_id == "":
		return
	counter[player_id] = int(counter.get(player_id, 0)) - 1


# "p1_hand" → "p1"
static func _player_of_zone(zone_id: String) -> String:
	var idx := zone_id.find("_")
	return zone_id.substr(0, idx) if idx > 0 else ""
