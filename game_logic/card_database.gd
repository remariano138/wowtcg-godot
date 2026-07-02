class_name CardDatabase
extends RefCounted

# Loads card definitions from data/cards.csv.
# Only cards whose engine_status column equals "implemented" are surfaced to
# the engine. Every other card is silently skipped — this is the manual gate
# that prevents half-finished cards from reaching game logic.
#
# Usage:
#   var db := CardDatabase.new()
#   db.load_csv("res://data/cards.csv")
#   var def: CardDef = db.get_def("swift_wolf")

const ENGINE_READY_TAG := "implemented"

var _defs: Dictionary = {}   # card_def_id (String) -> CardDef


func load_csv(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("CardDatabase: cannot open %s" % path)
		return

	var raw := file.get_as_text()
	file.close()

	# Strip UTF-8 BOM if present (PowerShell Export-Csv adds one).
	if raw.begins_with("﻿"):
		raw = raw.substr(1)

	var lines := raw.split("\n")
	if lines.is_empty():
		push_error("CardDatabase: empty file %s" % path)
		return

	# Parse header — strip surrounding quotes added by PowerShell.
	var headers: Array[String] = []
	for h in lines[0].split(","):
		headers.append(_unquote(h.strip_edges()))

	var loaded := 0
	var skipped := 0

	for i in range(1, lines.size()):
		var line := lines[i].strip_edges()
		if line == "":
			continue

		var cols := _split_csv_line(line)
		if cols.size() != headers.size():
			push_warning("CardDatabase: column count mismatch on line %d" % (i + 1))
			continue

		var row: Dictionary = {}
		for j in headers.size():
			row[headers[j]] = _unquote(cols[j])

		# Gate: skip anything not explicitly marked as implemented.
		if row.get("engine_status", "").strip_edges() != ENGINE_READY_TAG:
			skipped += 1
			continue

		# Use expansion + collector_number as a stable unique ID.
		var def_id := "%s_%s" % [row.get("expansion", ""), row.get("collector_number", "")]
		var def := CardDef.from_csv_row(def_id, row)
		_defs[def_id] = def
		loaded += 1

	print("CardDatabase: loaded %d cards (%d skipped — not implemented)" % [loaded, skipped])


# Inject a CardDef directly — used by test scenes for mock cards that have no
# CSV row (e.g. placeholder instants, quests) without polluting the real data.
func add_def(def: CardDef) -> void:
	_defs[def.card_def_id] = def


func get_def(id: String) -> CardDef:
	return _defs.get(id)


func get_all_defs() -> Array:
	return _defs.values()


func size() -> int:
	return _defs.size()


# ── CSV parsing helpers ────────────────────────────────────────────────────────

# Strip one layer of surrounding double-quotes, and unescape "" → ".
func _unquote(s: String) -> String:
	if s.begins_with("\"") and s.ends_with("\""):
		s = s.substr(1, s.length() - 2)
		s = s.replace("\"\"", "\"")
	return s


# Splits one CSV line respecting quoted fields (which may contain commas).
func _split_csv_line(line: String) -> Array[String]:
	var result: Array[String] = []
	var current := ""
	var in_quotes := false
	var i := 0
	while i < line.length():
		var c := line[i]
		if c == "\"":
			if in_quotes and i + 1 < line.length() and line[i + 1] == "\"":
				current += "\""
				i += 2
				continue
			in_quotes = !in_quotes
		elif c == "," and not in_quotes:
			result.append(current)
			current = ""
			i += 1
			continue
		else:
			current += c
		i += 1
	result.append(current)
	return result
