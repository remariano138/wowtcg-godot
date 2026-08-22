class_name DeckLibraryIndex
extends RefCounted

# Deck ids grouped by on-disk category (spec §9.4). Ids only — full
# DeckDefinitions are loaded on demand by DeckManager.load_deck().

var battle_ready: Array[String] = []
var ideas: Array[String] = []


func all() -> Array[String]:
	return battle_ready + ideas
