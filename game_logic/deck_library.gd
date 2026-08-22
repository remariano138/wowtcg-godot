class_name DeckLibrary
extends RefCounted

# Discovers deck files on disk and organizes them into categories (spec §9.4).
# Returns ids only — never parses full deck contents, never validates.
# Only DeckManager should call this.

const DECKS_ROOT := "res://decks"


static func scan() -> DeckLibraryIndex:
	var index := DeckLibraryIndex.new()
	index.battle_ready = _scan_folder(DECKS_ROOT + "/battle_ready")
	index.ideas = _scan_folder(DECKS_ROOT + "/ideas")
	return index


# The deck_id is the filename stem; category folder gives the source.
static func path_for(deck_id: String, category: String) -> String:
	return "%s/%s/%s.json" % [DECKS_ROOT, category, deck_id]


static func _scan_folder(path: String) -> Array[String]:
	var ids: Array[String] = []
	var dir := DirAccess.open(path)
	if dir == null:
		return ids
	for f in dir.get_files():
		# Godot exports rename res:// files to *.json.remap; strip either way.
		if f.ends_with(".json"):
			ids.append(f.trim_suffix(".json"))
		elif f.ends_with(".json.remap"):
			ids.append(f.trim_suffix(".json.remap"))
	ids.sort()
	return ids
