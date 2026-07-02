class_name DeckManager
extends RefCounted

# Produces Deck objects for GameManager to consume.
#
# Modes:
#   build_random(db)        — picks 1 hero + fills to TARGET_SIZE cards from
#                             the implemented pool, no copy-limit enforced yet.
#   get_named(name, db)     — loads a named premade deck (phase 8+).
#
# Deck composition rules (rule 100):
#   - Exactly 1 hero (separate from the 60-card deck).
#   - Minimum TARGET_SIZE cards (60 for Constructed).
#   - Max 4 copies of any card with the same name (not enforced yet).

const TARGET_SIZE := 60


# ── Random deck ────────────────────────────────────────────────────────────────

static func build_random(db: CardDatabase) -> Deck:
	var heroes: Array  = []
	var allies: Array  = []

	for def in db.get_all_defs():
		var d := def as CardDef
		if d.card_type == "Hero":
			heroes.append(d.card_def_id)
		else:
			allies.append(d.card_def_id)

	if heroes.is_empty():
		push_error("DeckManager: no implemented heroes in database")
		return null

	heroes.shuffle()
	var hero_id: String = heroes[0]

	if allies.is_empty():
		push_error("DeckManager: no implemented non-hero cards in database")
		return null

	# Fill deck: cycle through available allies, adding up to 4 copies each
	# pass until TARGET_SIZE is reached. No legality check yet.
	var card_ids: Array[String] = []
	var pass_num := 0
	while card_ids.size() < TARGET_SIZE:
		var added := 0
		for ally_id in allies:
			if card_ids.size() >= TARGET_SIZE:
				break
			# Count existing copies in this pass cycle (max 4 per name across all passes)
			var def := db.get_def(ally_id) as CardDef
			var name_count := 0
			for id in card_ids:
				var d2 := db.get_def(id) as CardDef
				if d2 and d2.card_name == def.card_name:
					name_count += 1
			if name_count < 4:
				card_ids.append(ally_id)
				added += 1
		pass_num += 1
		if added == 0:
			push_warning("DeckManager: pool exhausted at %d cards (need %d)" % [card_ids.size(), TARGET_SIZE])
			break

	return Deck.make(hero_id, card_ids)
