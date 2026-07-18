class_name DeckManager
extends RefCounted

# Single entry point for deck data (spec §9.5). Nothing else reads deck files
# or calls DeckLibrary directly — validation, loading, AI-profile lookup and
# DeckDefinition → runtime Deck conversion all live here.
#
# Modes:
#   get_available_decks()   — categorized index of deck ids on disk.
#   load_deck(id)           — parse + validate one deck file → DeckDefinition.
#   authorize_deck(id, db)  — full rule-100 legality check against the card db.
#   get_runtime_deck(id)    — load_deck + expand to a playable Deck.
#   load_ai_profile(id)     — AIProfile from res://ai_profiles/.
#   make_ai_for_deck(id)    — AI instance from the deck's recommended profile.
#   build_random(db)        — legacy: random deck from the implemented pool.
#
# Validation is two-tier:
#   validate_deck (structural, no db)  — hero present, >= TARGET_SIZE cards.
#     Runs inside load_deck; enough for menu listing.
#   authorize_deck (legality, needs db) — every card id resolves in the card
#     database, no heroes among the 60 (100.1), max 4 copies per name (100.4),
#     faction and class icons legal for the hero (100.2a). The scene calls it
#     at game launch so hand-edited custom decks fail with readable messages
#     instead of breaking mid-game.

const TARGET_SIZE := 60
const MAX_COPIES_PER_NAME := 4   # rule 100.4 (Constructed)
const AI_PROFILES_ROOT := "res://ai_profiles"
const GENERIC_AI_PROFILE_ID := "ai_generic"

# WoW TCG two-letter class abbreviations (multi-class cards concatenate them
# in the cards.csv class column, e.g. Mooncloth Robe = "MaPrLo").
const CLASS_ABBREVS := {
	"Dk": "Death Knight", "Dr": "Druid",  "Hu": "Hunter",  "Ma": "Mage",
	"Pa": "Paladin",      "Pr": "Priest", "Ro": "Rogue",   "Sh": "Shaman",
	"Lo": "Warlock",      "Wa": "Warrior",
}

static var _index: DeckLibraryIndex = null


# ── Library index ──────────────────────────────────────────────────────────────

static func get_available_decks(rescan := false) -> DeckLibraryIndex:
	if _index == null or rescan:
		_index = DeckLibrary.scan()
	return _index


# ── Loading + validation ───────────────────────────────────────────────────────

static func load_deck(deck_id: String) -> DeckDefinition:
	var path := _resolve_path(deck_id)
	if path.is_empty():
		push_error("DeckManager: unknown deck id '%s'" % deck_id)
		return null
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not (parsed is Dictionary):
		push_error("DeckManager: cannot parse %s" % path)
		return null
	var deck := DeckDefinition.from_dict(parsed)
	var errors := validate_deck(deck)
	if not errors.is_empty():
		push_error("DeckManager: invalid deck %s: %s" % [deck_id, errors])
		return null
	return deck


static func validate_deck(deck: DeckDefinition) -> Array[String]:
	var errors: Array[String] = []
	if deck.hero_card_def_id.is_empty():
		errors.append("Deck has no hero.")
	var total := deck.total_cards()
	if total < TARGET_SIZE:
		errors.append("Deck has %d cards, minimum is %d." % [total, TARGET_SIZE])
	return errors


# ── Authorization (rule 100 legality against the card database) ────────────────

# Full legality check for a deck id. Returns [] when the deck is legal, else
# human-readable error strings (shown in the game-setup menu). db is the live
# CardDatabase — only implemented cards resolve, so an unknown OR
# not-yet-implemented card id is caught here before it can break a game.
static func authorize_deck(deck_id: String, db) -> Array[String]:
	var deck := load_deck(deck_id)
	if deck == null:
		return ["Deck '%s' failed to load (missing file, bad JSON, or structural errors — see log)." % deck_id]
	return authorize_deck_def(deck, db)


static func authorize_deck_def(deck: DeckDefinition, db) -> Array[String]:
	var errors: Array[String] = validate_deck(deck)
	if not db:
		errors.append("No card database provided.")
		return errors

	# Hero must resolve and actually be a Hero.
	var hero_def: CardDef = null
	if not deck.hero_card_def_id.is_empty():
		hero_def = db.get_def(deck.hero_card_def_id)
		if hero_def == null:
			errors.append("Hero '%s' is unknown or not implemented." % deck.hero_card_def_id)
		elif hero_def.card_type != "Hero":
			errors.append("'%s' (%s) is not a Hero card." % [hero_def.card_name, deck.hero_card_def_id])
			hero_def = null

	var copies_by_name: Dictionary = {}   # card_name -> total count
	# 100.2c: Talent cards ("[Spec] Talent" on the type line, tags column) —
	# our heroes list no talent spec (206.1), so the deck simply may not mix
	# Talents of two different specs. Non-Talent cards are unrestricted no
	# matter their subtype. If heroes ever gain a talent_spec trait, the
	# hero-match branch of 100.2c goes here.
	var deck_talent_spec := ""       # first Talent spec seen
	var deck_talent_card := ""       # its card name (for the error message)
	for entry in deck.card_entries:
		if entry.count < 1:
			errors.append("Card '%s' has a non-positive count (%d)." % [entry.card_def_id, entry.count])
			continue
		var def: CardDef = db.get_def(entry.card_def_id)
		if def == null:
			errors.append("Card '%s' is unknown or not implemented." % entry.card_def_id)
			continue
		# 100.1: decks can't include heroes.
		if def.card_type == "Hero":
			errors.append("'%s' is a Hero — heroes can't be deck cards (rule 100.1)." % def.card_name)
			continue
		copies_by_name[def.card_name] = copies_by_name.get(def.card_name, 0) + entry.count
		var spec := talent_spec(def)
		if spec != "":
			if deck_talent_spec == "":
				deck_talent_spec = spec
				deck_talent_card = def.card_name
			elif spec != deck_talent_spec:
				errors.append("'%s' is a %s Talent but the deck already has the %s Talent '%s' — Talents of different specs can't share a deck (rule 100.2c)."
					% [def.card_name, spec, deck_talent_spec, deck_talent_card])
		if hero_def:
			# 100.2a: faction icons must match the hero's ("" = neutral, always legal).
			if def.alignment != "" and def.alignment != hero_def.alignment:
				errors.append("'%s' is %s — illegal for a %s hero (rule 100.2a)."
					% [def.card_name, def.alignment, hero_def.alignment])
			# 100.2a: class icons must share a class with the hero. Only Abilities
			# and Equipment carry class ICONS — an ally's class column is its
			# flavor subtype (e.g. Boneshanks "Undead Warrior"), never a
			# deckbuilding restriction.
			if def.card_type in ["Ability", "Equipment"]:
				var classes := _parse_class_restriction(def.card_class)
				if classes.size() == 1 and classes[0] == "?":
					errors.append("'%s' has an unrecognized class restriction '%s'."
						% [def.card_name, def.card_class])
				elif not classes.is_empty() and hero_def.card_class not in classes:
					errors.append("'%s' is %s-restricted (%s) — illegal for a %s hero (rule 100.2a)."
						% [def.card_name, "/".join(classes), def.card_class, hero_def.card_class])

	# 100.4: max 4 copies of any card with the same name.
	for card_name in copies_by_name:
		if copies_by_name[card_name] > MAX_COPIES_PER_NAME:
			errors.append("%d copies of '%s' — maximum is %d (rule 100.4)."
				% [copies_by_name[card_name], card_name, MAX_COPIES_PER_NAME])
	return errors


# "[Spec] Talent" tag → the spec ("Marksmanship Talent" → "Marksmanship"),
# or "" for a non-Talent card. The tag lives in the cards.csv tags column
# (CardDef.tags), e.g. Aimed Shot "Marksmanship Talent", Spirit Bond
# "Beast Mastery Talent". Non-Talent subtypes ("Feral", "Feral Combo",
# "Frost"…) never match.
static func talent_spec(def: CardDef) -> String:
	var t := def.tags.strip_edges()
	if t.ends_with(" Talent"):
		return t.trim_suffix(" Talent").strip_edges()
	return ""


# cards.csv class column → full class names: "" = no restriction (legal
# anywhere), a single full name ("Priest"), or concatenated two-letter
# abbreviations for multi-class cards ("MaPrLo"). Returns ["?"] when the
# value parses as neither — authorize_deck_def reports it as a data error.
static func _parse_class_restriction(raw: String) -> Array[String]:
	var s := raw.strip_edges()
	if s.is_empty():
		return []
	if s in CLASS_ABBREVS.values():
		return [s]
	if s.length() % 2 != 0:
		return ["?"]
	var classes: Array[String] = []
	for i in range(0, s.length(), 2):
		var abbrev := s.substr(i, 2)
		if not CLASS_ABBREVS.has(abbrev):
			return ["?"]
		classes.append(CLASS_ABBREVS[abbrev])
	return classes


# ── DeckDefinition → runtime Deck ──────────────────────────────────────────────

static func get_runtime_deck(deck_id: String) -> Deck:
	var def := load_deck(deck_id)
	if def == null:
		return null
	return Deck.make(def.hero_card_def_id, def.expand_card_ids())


# ── AI profiles ────────────────────────────────────────────────────────────────

# Every ai_id found under res://ai_profiles/ (filename stem), sorted.
# Used to populate AI-selection dropdowns without hardcoding profile names.
static func list_ai_profile_ids() -> Array[String]:
	var ids: Array[String] = []
	var dir := DirAccess.open(AI_PROFILES_ROOT)
	if not dir:
		return ids
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			ids.append(fname.get_basename())
		fname = dir.get_next()
	dir.list_dir_end()
	ids.sort()
	return ids


static func load_ai_profile(ai_id: String) -> AIProfile:
	var path := "%s/%s.json" % [AI_PROFILES_ROOT, ai_id]
	if not FileAccess.file_exists(path):
		push_error("DeckManager: missing AI profile '%s'" % ai_id)
		return null
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not (parsed is Dictionary):
		push_error("DeckManager: cannot parse AI profile %s" % path)
		return null
	return AIProfile.from_dict(parsed)


# AI instance from the deck's recommended_ai_id, falling back to the generic
# profile when the deck omits one (e.g. future custom decks).
static func make_ai_for_deck(deck_id: String) -> Object:
	var ai_id := GENERIC_AI_PROFILE_ID
	var def := load_deck(deck_id)
	if def != null and not def.recommended_ai_id.is_empty():
		ai_id = def.recommended_ai_id
	var profile := load_ai_profile(ai_id)
	if profile == null and ai_id != GENERIC_AI_PROFILE_ID:
		profile = load_ai_profile(GENERIC_AI_PROFILE_ID)
	if profile == null:
		return null
	return profile.make_ai()


static func _resolve_path(deck_id: String) -> String:
	var index := get_available_decks()
	if index.base.has(deck_id):
		return DeckLibrary.path_for(deck_id, "base")
	if index.recommended_ai.has(deck_id):
		return DeckLibrary.path_for(deck_id, "recommended_ai")
	if index.custom.has(deck_id):
		return DeckLibrary.path_for(deck_id, "custom")
	return ""


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
		if added == 0:
			push_warning("DeckManager: pool exhausted at %d cards (need %d)" % [card_ids.size(), TARGET_SIZE])
			break

	return Deck.make(hero_id, card_ids)
