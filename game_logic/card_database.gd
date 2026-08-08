class_name CardDatabase
extends RefCounted

# Loads card definitions from data/cards.csv and data/tokens.csv.
# Only cards whose engine_status column equals "implemented" are surfaced to
# the engine. Every other card is silently skipped — this is the manual gate
# that prevents half-finished cards from reaching game logic.
#
# Usage:
#   var db := CardDatabase.new()
#   db.load_all()
#   var def: CardDef = db.get_def("swift_wolf")

const ENGINE_READY_TAG := "implemented"

const CARDS_PATH  := "res://data/cards.csv"
const TOKENS_PATH := "res://data/tokens.csv"

var _defs: Dictionary = {}   # card_def_id (String) -> CardDef


# Load every data file into this one database. Card defs are resolved by id
# everywhere in the engine (GameState, renderer, AI), so tokens have to live in
# the SAME database as normal cards — they're only kept in a separate file
# because they are not deckable (see CardDef.is_token). Prefer this over
# calling load_csv per file: a new data file gets picked up by every call site
# at once.
func load_all() -> void:
	load_csv(CARDS_PATH)
	load_csv(TOKENS_PATH, true)


# `as_tokens` marks every def from this file as a token (CardDef.is_token).
func load_csv(path: String, as_tokens: bool = false) -> void:
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
			push_warning("CardDatabase: column count mismatch on line %d (got %d cols, expected %d) — card skipped: %s" % [i + 1, cols.size(), headers.size(), line.substr(0, 60)])
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
		def.is_token = as_tokens
		_defs[def_id] = def
		loaded += 1

	print("CardDatabase: loaded %d %s (%d skipped — not implemented)"
		% [loaded, "tokens" if as_tokens else "cards", skipped])


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
	s = s.strip_edges()
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
