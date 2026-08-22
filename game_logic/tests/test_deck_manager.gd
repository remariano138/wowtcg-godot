extends Node

# Headless test for Phase 8 (Deck Manager / Deck Library / deck JSON files).
#
# HOW TO RUN:
#   In Godot editor: Scene > New Scene > add this script as the root node > Play Scene.
#   Results appear in the Output panel. All lines should say PASS.

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== WoW TCG Engine — Phase 8 Deck Manager Tests ===\n")

	_test_library_scan()
	_test_load_all_decks()
	_test_validate_rejects_bad_decks()
	_test_authorize_all_shipped_decks()
	_test_authorize_rejects_illegal_decks()
	_test_runtime_deck_expansion()
	_test_roundtrip_serialization()
	_test_ai_profiles()
	_test_make_ai_for_deck()
	_test_tokens_csv_loads()
	_test_form_state_flags()
	_test_cold_snap_pool()

	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("PASS  %s" % label)
	else:
		_fail += 1
		print("FAIL  %s" % label)


func _test_library_scan() -> void:
	var index := DeckManager.get_available_decks(true)
	_check(index.battle_ready.size() == 6, "library finds 6 battle_ready decks (got %d)" % index.battle_ready.size())
	_check(index.ideas.size() == 7, "library finds 7 ideas decks (got %d)" % index.ideas.size())
	_check(index.all().size() == 13, "all() aggregates categories (6 + 7)")
	_check(index.battle_ready.has("alliance_hunter_elendril"), "alliance_hunter_elendril discovered in battle_ready")
	_check(index.battle_ready.has("horde_shaman_grennan_stormspeaker"), "grennan discovered in battle_ready")
	_check(index.battle_ready.has("alliance_druid_moonshadow"), "moonshadow discovered in battle_ready")
	_check(index.ideas.has("horde_mage_tazo"), "tazo is in ideas")
	_check(index.ideas.has("alliance_warlock_dizdemona"), "dizdemona is in ideas")
	_check(index.ideas.has("horde_druid_thangal"), "thangal is in ideas")


func _test_load_all_decks() -> void:
	for deck_id in DeckManager.get_available_decks().all():
		var deck := DeckManager.load_deck(deck_id)
		_check(deck != null, "%s loads" % deck_id)
		if deck == null:
			continue
		_check(deck.deck_id == deck_id, "%s: deck_id matches filename" % deck_id)
		# Rule: a deck needs AT LEAST 60 cards (DeckManager.validate_deck) — some
		# demo decks run a couple over (Grennan/Gorebelly at 62).
		_check(deck.total_cards() >= 60, "%s: >=60 cards (got %d)" % [deck_id, deck.total_cards()])
		_check(not deck.hero_card_def_id.is_empty(), "%s: has hero" % deck_id)
		_check(deck.recommended_ai_id == "ai_generic", "%s: recommends ai_generic" % deck_id)


func _test_validate_rejects_bad_decks() -> void:
	var deck := DeckDefinition.new()
	deck.card_entries.append(DeckCardEntry.make("azeroth_281", 10))
	var errors := DeckManager.validate_deck(deck)
	_check(errors.size() == 2, "no hero + undersized -> 2 errors (got %d)" % errors.size())
	deck.hero_card_def_id = "azeroth_15"
	deck.card_entries.append(DeckCardEntry.make("azeroth_197", 50))
	_check(DeckManager.validate_deck(deck).is_empty(), "hero + 60 cards -> valid")
	_check(DeckManager.load_deck("no_such_deck") == null, "unknown deck id -> null")


# Every token an effect can mint must actually resolve in the real database.
# A malformed tokens.csv row fails the column-count check and is SKIPPED with a
# push_warning, so the token would silently not exist and the effect that creates
# it would no-op — this is the only place that catches that.
func _test_tokens_csv_loads() -> void:
	var db := _make_db()
	for token_id in ["token_mechanical_dragonling", "token_tooga",
			"token_mechanical_yeti"]:
		var def := db.get_def(token_id) as CardDef
		if def == null:
			_check(false, "%s resolves in the database" % token_id)
			continue
		_check(def.is_token, "%s is flagged as a token" % token_id)
		_check(def.card_type == "Ally", "%s is an Ally (got '%s')"
			% [token_id, def.card_type])
		_check(def.printed_atk == 1 and def.printed_health == 1,
			"%s is 1/1 (got %d/%d)" % [token_id, def.printed_atk, def.printed_health])


func _make_db() -> CardDatabase:
	var db := CardDatabase.new()
	db.load_all()
	return db


# Every shipped deck must pass full rule-100 authorization against the real
# card database — this is what catches a deck edit that references an
# unknown/unimplemented card, exceeds 4 copies, or breaks faction/class
# legality, without pinning any specific composition into the tests.
func _test_authorize_all_shipped_decks() -> void:
	var db := _make_db()
	for deck_id in DeckManager.get_available_decks().all():
		var errors := DeckManager.authorize_deck(deck_id, db)
		_check(errors.is_empty(), "%s authorized%s" % [deck_id,
			"" if errors.is_empty() else " — " + "; ".join(errors)])


func _test_authorize_rejects_illegal_decks() -> void:
	var db := _make_db()
	# Base: a copy of a known-legal shipped deck (Moonshadow — Alliance Druid),
	# mutated per case.
	var source := DeckManager.load_deck("alliance_druid_moonshadow")
	if source == null:
		_check(false, "authorize: source deck loads")
		return

	# Unknown / unimplemented card id.
	var deck := DeckDefinition.from_dict(source.to_dict())
	deck.card_entries.append(DeckCardEntry.make("no_such_card_999", 1))
	_check(DeckManager.authorize_deck_def(deck, db).size() == 1,
		"unknown card id -> 1 error")

	# A hero among the 60 (rule 100.1).
	deck = DeckDefinition.from_dict(source.to_dict())
	deck.card_entries.append(DeckCardEntry.make("azeroth_15", 1))   # Ta'zo (Hero)
	_check(DeckManager.authorize_deck_def(deck, db).size() == 1,
		"hero as a deck card -> 1 error")

	# More than 4 copies of one name (rule 100.4).
	deck = DeckDefinition.from_dict(source.to_dict())
	deck.card_entries.append(DeckCardEntry.make("azeroth_221", 5))  # + shipped 3x Tristan
	var copy_errors := DeckManager.authorize_deck_def(deck, db)
	_check(copy_errors.size() == 1 and "100.4" in copy_errors[0],
		"8 copies of one name -> 1 error citing 100.4")

	# Wrong faction (rule 100.2a): Horde ally in an Alliance deck.
	deck = DeckDefinition.from_dict(source.to_dict())
	deck.card_entries.append(DeckCardEntry.make("dark_portal_201", 1))  # Boneshanks (Horde)
	var faction_errors := DeckManager.authorize_deck_def(deck, db)
	_check(faction_errors.size() == 1 and "Horde" in faction_errors[0],
		"Horde ally in Alliance deck -> 1 faction error")

	# Wrong class (rule 100.2a): Warlock ability in a Druid deck. Class icons
	# only restrict Abilities/Equipment — an ALLY's class column is flavor
	# (Kavai "Warrior" is already legal in this Druid deck's shipped list).
	deck = DeckDefinition.from_dict(source.to_dict())
	deck.card_entries.append(DeckCardEntry.make("azeroth_134", 1))  # Steal Essence (Warlock)
	var class_errors := DeckManager.authorize_deck_def(deck, db)
	_check(class_errors.size() == 1 and "Warlock" in class_errors[0],
		"Warlock ability in Druid deck -> 1 class error")

	# Multi-class equipment (MaPrLo): illegal for Druid, legal for Warlock.
	deck = DeckDefinition.from_dict(source.to_dict())
	deck.card_entries.append(DeckCardEntry.make("azeroth_298", 1))  # Mooncloth Robe
	_check(DeckManager.authorize_deck_def(deck, db).size() == 1,
		"MaPrLo equipment in Druid deck -> 1 error")
	deck.hero_card_def_id = "azeroth_2"   # Dizdemona (Warlock) — Lo matches
	var robe_ok_errors := DeckManager.authorize_deck_def(deck, db)
	var robe_flagged := false
	for e in robe_ok_errors:
		if "Mooncloth" in e:
			robe_flagged = true
	_check(not robe_flagged, "MaPrLo equipment legal for a Warlock hero")

	# "[Race] Hero Required" (rule 100.2b): War Stomp needs a Tauren hero.
	# Ta'zo is a Troll Mage -> illegal; Grennan (Tauren Shaman) -> legal
	# (only the War Stomp error is asserted on the hero swap — Ta'zo's Mage
	# cards going class-illegal for a Shaman is expected noise).
	var horde := DeckManager.load_deck("horde_mage_tazo")
	if horde == null:
		_check(false, "authorize: horde source deck loads")
		return
	deck = DeckDefinition.from_dict(horde.to_dict())
	deck.card_entries.append(DeckCardEntry.make("dark_portal_137", 1))  # War Stomp
	var race_errors := DeckManager.authorize_deck_def(deck, db)
	_check(race_errors.size() == 1 and "100.2b" in race_errors[0],
		"War Stomp with a Troll hero -> 1 error citing 100.2b")
	deck.hero_card_def_id = "azeroth_10"   # Grennan Stormspeaker (Tauren Shaman)
	var stomp_flagged := false
	for e in DeckManager.authorize_deck_def(deck, db):
		if "War Stomp" in e:
			stomp_flagged = true
	_check(not stomp_flagged, "War Stomp legal for a Tauren hero")


# Every card whose printed text says "your hero is in <X> form" must carry the
# matching form_state:<X> flag, or a card that gates on the form by name
# (Thangal: "Use only while he's in bear form") silently doesn't see it. The
# flag is easy to forget on the cards that pair a form with an on-play effect —
# Bash and Claw both shipped without it — so this pins the whole set against the
# REAL database rather than trusting each recipe to be edited by hand.
func _test_form_state_flags() -> void:
	var db := _make_db()
	var expected := {
		"azeroth_17":      "bear",   # Bash
		"azeroth_18":      "bear",   # Bear Form
		"azeroth_25":      "bear",   # Maul
		"dark_portal_19":  "cat",    # Cat Form
		"dark_portal_20":  "cat",    # Claw
	}
	for def_id in expected:
		var def := db.get_def(def_id) as CardDef
		if def == null:
			_check(false, "%s resolves in the database" % def_id)
			continue
		var got := StackResolver.form_state_of(def)
		_check(got == expected[def_id], "%s (%s) declares form_state:%s (got '%s')"
			% [def_id, def.card_name, expected[def_id], got])
		# The printed text and the flag must agree — a card claiming one form in
		# its text and another in its recipe would pass the check above.
		_check(("in %s form" % expected[def_id]) in def.power_text.to_lower(),
			"%s power_text says \"in %s form\"" % [def.card_name, expected[def_id]])


# Cold Snap's pool is defined by a TAG substring against the real cards.csv, so
# the recipe is only as good as the tags column: a Frost ability whose tags cell
# is blank or misspelled silently drops out of the pool with nothing to fail on.
# Pin the whole set here, and the X/self-exile riders with it.
func _test_cold_snap_pool() -> void:
	var db := _make_db()
	var cold := db.get_def("azeroth_50") as CardDef
	_check(cold != null, "azeroth_50 (Cold Snap) resolves in the database")
	if cold == null:
		return
	_check(cold.card_type == "Ability" and cold.is_instant,
		"Cold Snap is an Instant Ability")
	_check(cold.cost_x and cold.cost_base == 2, "Cold Snap costs 2+X")
	var req := StackResolver.get_graveyard_search_requirement(cold)
	_check(req.get("dest", "") == "hand", "Cold Snap fetches to hand")
	_check(req.get("max_count_x", false), "Cold Snap's count is the announced X")
	_check(String(req.get("tag_filter", "")) == "Frost", "Cold Snap filters on the Frost tag")
	_check(req.get("distinct_names", false), "Cold Snap requires different names")
	_check(StackResolver.ability_rfg_self_on_resolve(cold), "Cold Snap exiles itself")
	# Every implemented Frost ability must be reachable by it. Cold Snap itself
	# never can be — it exiles itself rather than reaching a graveyard.
	for def_id in ["azeroth_56"]:                      # Frostbolt
		var d := db.get_def(def_id) as CardDef
		_check(d != null and d.card_type == "Ability" and "Frost" in d.tags,
			"%s is a Frost ability card (tags: '%s')"
				% [def_id, d.tags if d else "<missing>"])


func _test_runtime_deck_expansion() -> void:
	var runtime := DeckManager.get_runtime_deck("alliance_warlock_dizdemona")
	_check(runtime != null, "get_runtime_deck returns a Deck")
	if runtime == null:
		return
	_check(runtime.hero_def_id == "azeroth_2", "Dizdemona hero id")
	_check(runtime.card_def_ids.size() == 60, "expanded to 60 def ids")


func _test_roundtrip_serialization() -> void:
	var deck := DeckManager.load_deck("horde_warlock_radak_doombringer")
	if deck == null:
		_check(false, "roundtrip: source deck loads")
		return
	var copy := DeckDefinition.from_dict(deck.to_dict())
	_check(copy.to_dict() == deck.to_dict(), "to_dict/from_dict roundtrip stable")
	_check(copy.total_cards() == 60, "roundtrip preserves card count")


func _test_ai_profiles() -> void:
	var fullrandom := DeckManager.load_ai_profile("ai_fullrandom")
	_check(fullrandom != null and fullrandom.ai_class == "fullrandom", "ai_fullrandom profile loads")
	var base := DeckManager.load_ai_profile("ai_base")
	_check(base != null and base.ai_class == "base", "ai_base profile loads")
	if fullrandom != null:
		_check(fullrandom.make_ai() is FullRandomAI, "ai_fullrandom -> FullRandomAI instance")
	if base != null:
		_check(base.make_ai() is BaseAI, "ai_base -> BaseAI instance")
	var generic := DeckManager.load_ai_profile("ai_generic")
	_check(generic != null and generic.ai_class == "generic", "ai_generic profile loads")
	if generic != null:
		_check(generic.make_ai() is GenericAI, "ai_generic -> GenericAI instance")


func _test_make_ai_for_deck() -> void:
	var ai := DeckManager.make_ai_for_deck("horde_mage_tazo")
	_check(ai is GenericAI, "make_ai_for_deck uses recommended profile (GenericAI)")
	var fallback := DeckManager.make_ai_for_deck("no_such_deck")
	_check(fallback is GenericAI, "unknown deck falls back to the generic profile (GenericAI)")
	var warlock_ai := DeckManager.make_ai_for_deck("horde_warlock_radak_doombringer")
	_check(warlock_ai is GenericAI, "base-category deck still uses its recommended_ai_id (GenericAI)")
