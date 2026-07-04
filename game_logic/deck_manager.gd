class_name DeckManager
extends RefCounted

# Single entry point for deck data (spec §9.5). Nothing else reads deck files
# or calls DeckLibrary directly — validation, loading, AI-profile lookup and
# DeckDefinition → runtime Deck conversion all live here.
#
# Modes:
#   get_available_decks()   — categorized index of deck ids on disk.
#   load_deck(id)           — parse + validate one deck file → DeckDefinition.
#   get_runtime_deck(id)    — load_deck + expand to a playable Deck.
#   load_ai_profile(id)     — AIProfile from res://ai_profiles/.
#   make_ai_for_deck(id)    — AI instance from the deck's recommended profile.
#   build_random(db)        — legacy: random deck from the implemented pool.
#
# Deck composition rules (rule 100):
#   - Exactly 1 hero (separate from the 60-card deck).
#   - Minimum TARGET_SIZE cards (60 for Constructed).
#   - Max 4 copies of any card with the same name (not enforced yet — demo
#     decks intentionally exceed it while the implemented pool is small).

const TARGET_SIZE := 60
const AI_PROFILES_ROOT := "res://ai_profiles"
const GENERIC_AI_PROFILE_ID := "ai_fullrandom"

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


# ── DeckDefinition → runtime Deck ──────────────────────────────────────────────

static func get_runtime_deck(deck_id: String) -> Deck:
	var def := load_deck(deck_id)
	if def == null:
		return null
	return Deck.make(def.hero_card_def_id, def.expand_card_ids())


# ── AI profiles ────────────────────────────────────────────────────────────────

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
