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
	_check(index.recommended_ai.size() == 8, "library finds 8 recommended_ai decks (got %d)" % index.recommended_ai.size())
	_check(index.base.size() == 3, "library finds 3 base decks (got %d)" % index.base.size())
	_check(index.custom.size() == 2, "custom category has 2 decks (Elendril, Thangal)")
	_check(index.custom.has("alliance_elendril_test"), "alliance_elendril_test discovered in custom")
	_check(index.custom.has("horde_thangal_test"), "horde_thangal_test discovered in custom")
	_check(index.all().size() == 13, "all() aggregates categories (8 + 3 + 2)")
	_check(index.recommended_ai.has("alliance_litori_test"), "alliance_litori_test discovered")
	_check(index.recommended_ai.has("horde_tazo_test"), "horde_tazo_test discovered")
	_check(index.base.has("alliance_dizdemona_test"), "dizdemona (Warlock) is in base, not recommended_ai")
	_check(index.base.has("horde_radak_test"), "radak (Warlock) is in base, not recommended_ai")


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
	var source := DeckManager.load_deck("alliance_moonshadow_test")
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
	var horde := DeckManager.load_deck("horde_tazo_test")
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


func _test_runtime_deck_expansion() -> void:
	var runtime := DeckManager.get_runtime_deck("alliance_dizdemona_test")
	_check(runtime != null, "get_runtime_deck returns a Deck")
	if runtime == null:
		return
	_check(runtime.hero_def_id == "azeroth_2", "Dizdemona hero id")
	_check(runtime.card_def_ids.size() == 60, "expanded to 60 def ids")


func _test_roundtrip_serialization() -> void:
	var deck := DeckManager.load_deck("horde_radak_test")
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
	var ai := DeckManager.make_ai_for_deck("horde_tazo_test")
	_check(ai is GenericAI, "make_ai_for_deck uses recommended profile (GenericAI)")
	var fallback := DeckManager.make_ai_for_deck("no_such_deck")
	_check(fallback is GenericAI, "unknown deck falls back to the generic profile (GenericAI)")
	var warlock_ai := DeckManager.make_ai_for_deck("horde_radak_test")
	_check(warlock_ai is GenericAI, "base-category deck still uses its recommended_ai_id (GenericAI)")
