extends Node

const CSV_PATH = "res://data/cards.csv"

var _db: Dictionary = {}

func _ready() -> void:
	var file = FileAccess.open(CSV_PATH, FileAccess.READ)
	var header = file.get_csv_line()
	while not file.eof_reached():
		var row = file.get_csv_line()
		if row.size() < header.size():
			continue
		var entry := {}
		for i in header.size():
			entry[header[i]] = row[i]
		var card_id = entry["expansion"] + "-" + entry["collector_number"]
		_db[card_id] = entry

func get_card(card_id: String) -> Dictionary:
	return _db.get(card_id, {})
