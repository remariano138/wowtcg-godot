class_name DeckDefinition
extends RefCounted

# Static definition of one deck (spec §9.2): hero + card entries + metadata.
# Loaded from a JSON file by DeckManager. Knows nothing about zones,
# CardInstances, or the live game.

var deck_id: String = ""            # unique, filename-safe; equals the JSON filename stem
var display_name: String = ""
var hero_card_def_id: String = ""
var card_entries: Array[DeckCardEntry] = []
var recommended_ai_id: String = ""  # AIProfile id, empty = use generic fallback
var source: String = ""             # "base" | "recommended_ai" | "custom"
var metadata: Dictionary = {}


func total_cards() -> int:
	var n := 0
	for entry in card_entries:
		n += entry.count
	return n


# Flatten entries into the pre-shuffle def_id list the runtime Deck expects.
func expand_card_ids() -> Array[String]:
	var ids: Array[String] = []
	for entry in card_entries:
		for i in range(entry.count):
			ids.append(entry.card_def_id)
	return ids


func to_dict() -> Dictionary:
	var entries := []
	for entry in card_entries:
		entries.append(entry.to_dict())
	return {
		"deck_id": deck_id,
		"display_name": display_name,
		"hero_card_def_id": hero_card_def_id,
		"card_entries": entries,
		"recommended_ai_id": recommended_ai_id,
		"source": source,
		"metadata": metadata,
	}


static func from_dict(d: Dictionary) -> DeckDefinition:
	var deck := DeckDefinition.new()
	deck.deck_id = str(d.get("deck_id", ""))
	deck.display_name = str(d.get("display_name", ""))
	deck.hero_card_def_id = str(d.get("hero_card_def_id", ""))
	for entry_dict in d.get("card_entries", []):
		deck.card_entries.append(DeckCardEntry.from_dict(entry_dict))
	deck.recommended_ai_id = str(d.get("recommended_ai_id", ""))
	deck.source = str(d.get("source", ""))
	deck.metadata = d.get("metadata", {})
	return deck
