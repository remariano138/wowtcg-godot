
var deck_name: String = ""
var hero_id: String = ""
var cards: Array = []  # Array of {id: String, count: int}

# Returns a flat shuffled array of card_ids ready to draw from (hero excluded)
func to_draw_pile() -> Array:
	var pile: Array = []
	for entry in cards:
		for i in entry["count"]:
			pile.append(entry["id"])
	pile.shuffle()
	return pile

func to_dict() -> Dictionary:
	return { "name": deck_name, "hero": hero_id, "cards": cards }

static func from_dict(data: Dictionary) -> Deck:
	var deck = Deck.new()
	deck.deck_name = data.get("name", "Unnamed")
	deck.hero_id   = data.get("hero", "")
	deck.cards     = data.get("cards", [])
	return deck
