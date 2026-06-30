extends Node

const BUILTIN_PATH = "res://data/decks/"
const USER_PATH    = "user://decks/"

# Class-section ranges per expansion — allies in these ranges are class-restricted
# (pets, class-specific allies). Faction allies (outside ranges) are unrestricted.
# NOTE: see fill_subtype_column.py for warnings about adding new expansions

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_PATH))

func save(deck: Deck, filename: String) -> void:
	var path = USER_PATH + filename + ".json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(deck.to_dict(), "\t"))

func load_deck(filename: String) -> Deck:
	# User decks take priority over built-in decks
	for base in [USER_PATH, BUILTIN_PATH]:
		var path = base + filename + ".json"
		if FileAccess.file_exists(path):
			var file = FileAccess.open(path, FileAccess.READ)
			var data = JSON.parse_string(file.get_as_text())
			if data:
				return Deck.from_dict(data)
	push_warning("DeckManager: deck not found: " + filename)
	return null

func list_user_decks() -> Array:
	return _list_decks(USER_PATH)

func list_builtin_decks() -> Array:
	return _list_decks(BUILTIN_PATH)

func random_deck_maker(db: Node) -> Deck:
	# 1. Pick a random hero
	var hero_ids = db._db.keys().filter(func(id): return db._db[id]["type"] == "Hero")
	var hero_id    = hero_ids[randi() % hero_ids.size()]
	var hero_data  = db._db[hero_id]
	var hero_alignment = hero_data.get("alignment", "")
	var hero_class     = hero_data.get("class", "")
	var opposite       = "Horde" if hero_alignment == "Alliance" else "Alliance"

	# 2. Build legal card pool — allies only for now (abilities have no effect yet)
	var legal = db._db.keys().filter(func(id):
		var card = db._db[id]
		# Only allies (abilities commented out until card effects are implemented)
		if card["type"] != "Ally":
			return false
		# Alignment: exclude opposite faction (neutrals always allowed)
		var card_alignment = card.get("alignment", "")
		if card_alignment != "" and card_alignment == opposite:
			return false
		# Pets are class-restricted: subtype contains "Pet"
		if "Pet" in card.get("subtype", ""):
			var card_class = card.get("class", "")
			return card_class == "" or card_class == hero_class
		# Regular faction allies: only alignment matters
		return true

		## --- Ability logic (correct but disabled until effects are implemented) ---
		## Abilities: must match hero class or be neutral
		# if card["type"] == "Ability":
		# 	var card_class = card.get("class", "")
		# 	return card_class == "" or card_class == hero_class
	)

	# 3. Build deck: guarantee 12 of each 1/2/3-cost tier, fill rest randomly
	var deck = Deck.new()
	deck.hero_id   = hero_id
	deck.deck_name = "Random — " + hero_data.get("name", "Unknown")

	# Group legal allies by cost
	var by_cost: Dictionary = {}
	for id in legal:
		var c = db._db[id].get("cost", "")
		if not by_cost.has(c):
			by_cost[c] = []
		by_cost[c].append(id)

	var copies: Dictionary = {}  # card_id -> copies already in deck
	var total: int = 0

	# Phase 1: guarantee at least 12 cards per cheap tier (max 4 copies each)
	for tier in ["1", "2", "3"]:
		var pool: Array = by_cost.get(tier, []).duplicate()
		pool.shuffle()
		var tier_added = 0
		for id in pool:
			if tier_added >= 12:
				break
			var already = copies.get(id, 0)
			if already >= 4:
				continue
			var count = min(4 - already, 12 - tier_added)
			deck.cards.append({ "id": id, "count": count })
			copies[id] = already + count
			tier_added += count
			total += count

	# Phase 2: fill remaining slots from full legal pool (4-copy rule enforced via copies dict)
	var phase2_pool: Array = legal.duplicate()
	phase2_pool.shuffle()
	for id in phase2_pool:
		if total >= 60:
			break
		var already = copies.get(id, 0)
		if already >= 4:
			continue
		var count = min(4 - already, 60 - total)
		deck.cards.append({ "id": id, "count": count })
		copies[id] = already + count
		total += count

	return deck

func _list_decks(path: String) -> Array:
	var names: Array = []
	var dir = DirAccess.open(path)
	if not dir:
		return names
	dir.list_dir_begin()
	var entry = dir.get_next()
	while entry != "":
		if entry.ends_with(".json"):
			names.append(entry.trim_suffix(".json"))
		entry = dir.get_next()
	return names
