class_name Deck
extends RefCounted

# A resolved deck ready for play: one hero def + ordered list of card def_ids.
# DeckManager produces these; GameManager consumes them.

var hero_def_id: String = ""
var card_def_ids: Array[String] = []   # 60+ cards, order is pre-shuffle


static func make(hero: String, cards: Array[String]) -> Deck:
	var d := Deck.new()
	d.hero_def_id  = hero
	d.card_def_ids = cards
	return d
