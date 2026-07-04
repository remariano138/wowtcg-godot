class_name DeckLibraryIndex
extends RefCounted

# Deck ids grouped by on-disk category (spec §9.4). Ids only — full
# DeckDefinitions are loaded on demand by DeckManager.load_deck().

var base: Array[String] = []
var recommended_ai: Array[String] = []
var custom: Array[String] = []


func all() -> Array[String]:
	return base + recommended_ai + custom
