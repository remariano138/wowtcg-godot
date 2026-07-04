class_name DeckCardEntry
extends RefCounted

# One decklist line: a card definition reference + how many copies.
# Expanded into individual CardInstance objects only at game setup.

var card_def_id: String = ""
var count: int = 0


static func make(def_id: String, n: int) -> DeckCardEntry:
	var e := DeckCardEntry.new()
	e.card_def_id = def_id
	e.count = n
	return e


func to_dict() -> Dictionary:
	return {"card_def_id": card_def_id, "count": count}


static func from_dict(d: Dictionary) -> DeckCardEntry:
	return make(str(d.get("card_def_id", "")), int(d.get("count", 0)))
