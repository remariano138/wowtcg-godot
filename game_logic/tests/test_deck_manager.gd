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
	_test_rain_of_fire_recipe()
	_test_polymorph_recipe()
	_test_cyclone_recipe()
	_test_ritual_sacrifice_recipe()
	_test_avanthera_recipe()
	_test_unpreventable_holy_recipes()
	_test_resurrection_recipe()
	_test_mute_when_column()
	_test_gift_of_the_elven_magi_recipe()
	_test_graccus_recipe()
	_test_hammer_of_justice_recipe()
	_test_holy_light_recipe()
	_test_healing_wave_recipe()
	_test_priest_heal_recipes()
	_test_clarity_of_thought_recipe()
	_test_hide_of_the_wild_recipe()
	_test_power_word_fortitude_recipe()
	_test_dismantle_recipe()
	_test_shadowmeld_recipe()
	_test_soul_link_count_power()
	_test_wisp_recipe()
	_test_lessons_in_lurking_recipe()
	_test_thorns_recipe()
	_test_eye_of_rend_and_scarlet_kris_recipes()
	_test_point_blank_recipe()
	_test_lokdelar_recipe()
	_test_wing_clip_recipe()
	_test_ghost_wolf_recipe()
	_test_rockbiter_weapon_recipe()
	_test_totemic_call_recipe()
	_test_shaman_ally_recipes()
	_test_edgemasters_handguards_recipe()
	_test_deathdealer_breastplate_recipe()

	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("PASS  %s" % label)
	else:
		_fail += 1
		print("FAIL  %s" % label)


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
			"token_mechanical_yeti", "token_dwarf_warrior"]:
		var def := db.get_def(token_id) as CardDef
		if def == null:
			_check(false, "%s resolves in the database" % token_id)
			continue
		_check(def.is_token, "%s is flagged as a token" % token_id)
		_check(def.card_type == "Ally", "%s is an Ally (got '%s')"
			% [token_id, def.card_type])
		_check(def.printed_atk == 1 and def.printed_health == 1,
			"%s is 1/1 (got %d/%d)" % [token_id, def.printed_atk, def.printed_health])
		# ART. A token has never been in a zone, so no CardNode exists for it
		# until it is MINTED mid-game — a wrong path or an un-imported image
		# therefore shows up as a blank card in play and nowhere else. Both
		# halves are needed: the path must point at a real file, AND Godot must
		# have imported it (load() returns null without a .import sibling, which
		# is the failure mode a plain FileAccess check misses).
		var art := def.image_path.replace("\\", "/")
		_check(art != "", "%s declares an image_path" % token_id)
		if art == "":
			continue
		_check(FileAccess.file_exists("res://" + art),
			"%s art exists on disk (%s)" % [token_id, art])
		_check(ResourceLoader.exists("res://" + art),
			"%s art is imported — load() would return a texture (%s)"
				% [token_id, art])
	# King Magni's token must carry its RACE where the aura can find it — the
	# token CSV puts "Dwarf Warrior" in the SUBTYPE column, not tags, so a
	# tags-only read would silently leave his own tokens without protector.
	var dwarf := db.get_def("token_dwarf_warrior") as CardDef
	_check(dwarf != null and ("Dwarf" in dwarf.card_subtype or "Dwarf" in dwarf.tags),
		"token_dwarf_warrior is findable as a Dwarf by friendly_race_keyword")


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
# matching form_state:<X> flag. This was always load-bearing (a card gating on
# the form by name — Thangal: "Use only while he's in bear form" — silently
# doesn't see a card that forgot it, and Bash and Claw both shipped without
# it); since the grants moved into GameState.FORM_GRANTS the flag is now the
# ENTIRE recipe, so a typo costs the card its protector and its break clause
# too. Pinned against the REAL database rather than trusting hand-edited
# recipes — and the derived properties are pinned with it, since nothing in
# the CSV mentions them any more.
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
		# The grants are no longer segments on the card, so assert what the form
		# NAME resolves to — the reminder text printed on every one of these cards
		# ("Has protector…" / "+1 ATK while attacking…") is the spec being met.
		_check(StackResolver.form_break_tag(def) == "Feral",
			"%s breaks on a non-Feral ability (derived from the form)" % def.card_name)
		var grants: Dictionary = GameState.form_grants(expected[def_id])
		if expected[def_id] == "bear":
			_check("protector" in grants.get("keywords", []),
				"%s: bear form grants protector" % def.card_name)
		else:
			_check(int(grants.get("atk_while_attacking", 0)) == 1,
				"%s: cat form grants +1 ATK while attacking" % def.card_name)
		# ...and that the card does NOT also spell them out by hand. A leftover
		# copy would double the cat ATK bonus and quietly outlive the table.
		for stale in ["hero_has_protector", "form_break:", "hero_atk_while_attacking:"]:
			_check(not (stale in def.effects),
				"%s does not restate `%s` (it comes from the form)" % [def.card_name, stale])


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


# Resurrection (azeroth_86) is PURE CSV, and it is Ancestral Spirit's recipe
# MINUS the trailing damage mode — copy that card's segment wholesale and the
# ally silently comes back at 1 health instead of full, with nothing to fail on.
# So pin the absence of the 7th field as hard as the rest.

# Graccus (azeroth_4) — the flip is the whole card, and a typo in the recipe key
# or in the count would leave a hero whose power silently does nothing (or
# shields the wrong amount) with nothing to fail on. Pinned against the REAL
# database, including the cost, since the power's own cost is also the AI's
# value floor for spending the game's only flip on an ally.

# Hammer of Justice (azeroth_68) is PURE CSV — the whole card is
# `exhaust_target:hero_or_ally|gouge_cant_ready|draw:1`, so a typo in any one of
# the three segments would silently leave a 2-cost do-nothing with nothing to
# fail on. The type matters as much as the effects: at sorcery speed the card
# could never be flashed in on a combat proposal, which is the point of it.
func _test_hammer_of_justice_recipe() -> void:
	var db := _make_db()
	var hoj := db.get_def("azeroth_68") as CardDef
	_check(hoj != null, "azeroth_68 (Hammer of Justice) resolves in the database")
	if hoj == null:
		return
	_check(hoj.card_type == "Ability" and hoj.is_instant,
		"Hammer of Justice is an INSTANT Ability")
	_check(hoj.cost == 2, "Hammer of Justice costs 2")
	_check(not hoj.tags.ends_with(" Talent"),
		"...tagged plain Protection, NOT a Talent — no 100.2c spec restriction")
	var exhaust_kind := ""
	var lock := false
	var draw := 0
	for seg in hoj.effects.split("|"):
		var parts: PackedStringArray = seg.strip_edges().split(":")
		match parts[0].strip_edges():
			"exhaust_target":
				exhaust_kind = parts[1].strip_edges() if parts.size() > 1 else ""
			"gouge_cant_ready":
				lock = true
			"draw":
				draw = int(parts[1]) if parts.size() > 1 else 0
	_check(exhaust_kind == "hero_or_ally", "...exhausts a target hero OR ally")
	_check(lock, "...and locks its controller's next ready step")
	_check(draw == 1, "...and draws a card")



# Holy Light (azeroth_69) is PURE CSV — `heal_target:5|draw:1` — so a typo in
# either segment leaves a 3-cost do-nothing with nothing to fail on. The type is
# pinned too, in the opposite direction from Hammer of Justice: this one really
# IS a plain (sorcery-speed) Ability, and quietly "fixing" it to Instant would
# turn a main-phase repair into a combat trick the card is not.
func _test_holy_light_recipe() -> void:
	var db := _make_db()
	var hl := db.get_def("azeroth_69") as CardDef
	_check(hl != null, "azeroth_69 (Holy Light) resolves in the database")
	if hl == null:
		return
	_check(hl.card_type == "Ability" and not hl.is_instant,
		"Holy Light is a plain (sorcery-speed) Ability")
	_check(hl.cost == 3, "Holy Light costs 3")
	_check(not hl.tags.ends_with(" Talent"),
		"...tagged plain Holy, NOT a Talent — no 100.2c spec restriction")
	_check(StackResolver._heal_target_amount(hl) == 5,
		"...heals 5 from a target hero or ally")
	var draw := 0
	for seg in hl.effects.split("|"):
		var parts: PackedStringArray = seg.strip_edges().split(":")
		if parts[0].strip_edges() == "draw":
			draw = int(parts[1]) if parts.size() > 1 else 0
	_check(draw == 1, "...and draws a card")


# Healing Wave is PURE CSV — Healing Touch's heal at 8 instead of 10 — so a typo
# in the segment would leave a silent 3-cost do-nothing with nothing to fail on.
# The sorcery speed is pinned in the same direction as Holy Light's: quietly
# "fixing" it to Instant would turn a main-phase repair into a combat trick the
# card is not.
func _test_healing_wave_recipe() -> void:
	var db := _make_db()
	var hw := db.get_def("azeroth_112") as CardDef
	_check(hw != null, "azeroth_112 (Healing Wave) resolves in the database")
	if hw == null:
		return
	_check(hw.card_type == "Ability" and not hw.is_instant,
		"Healing Wave is a plain (sorcery-speed) Ability")
	_check(hw.cost == 3, "Healing Wave costs 3")
	_check(not hw.tags.ends_with(" Talent"),
		"...tagged plain Restoration, NOT a Talent — no 100.2c spec restriction")
	_check(StackResolver._heal_target_amount(hw) == 8,
		"...heals 8 from a target hero or ally")


# The Priest heal cycle — Flash Heal (azeroth_78), Heal (azeroth_79) and Prayer
# of Healing (azeroth_84). The first two are PURE CSV on Healing Touch's
# `heal_target` key, so a typo would leave a silent do-nothing with nothing to
# fail on. What matters most here is the SPEED cell: Flash Heal's printed type
# line is "Instant Ability", and its CSV cell originally said plain `Ability` —
# quietly "fixing" it back would cost the card its entire point (a 1-cost save
# flashed into a combat window). Prayer of Healing's `heal_party` is pinned as a
# TOP-LEVEL segment, the axis that separates it from Lady Courtney Noel's
# activated power and Stylean Silversteel's enter-play trigger, which carry the
# same word further along their own segment.
func _test_priest_heal_recipes() -> void:
	var db := _make_db()
	var fh := db.get_def("azeroth_78") as CardDef
	var hl := db.get_def("azeroth_79") as CardDef
	var pr := db.get_def("azeroth_84") as CardDef
	_check(fh != null and hl != null and pr != null,
		"azeroth_78/79/84 (Flash Heal, Heal, Prayer of Healing) resolve in the database")
	if fh == null or hl == null or pr == null:
		return
	_check(fh.card_type == "Ability" and fh.is_instant,
		"Flash Heal is an INSTANT Ability — the whole point of the card")
	_check(fh.cost == 1 and StackResolver._heal_target_amount(fh) == 4,
		"...1 resource, heals 4 from a target hero or ally")
	_check(hl.card_type == "Ability" and not hl.is_instant,
		"Heal is a plain (sorcery-speed) Ability")
	_check(hl.cost == 2 and StackResolver._heal_target_amount(hl) == 7,
		"...2 resources, heals 7 from a target hero or ally")
	_check(pr.card_type == "Ability" and not pr.is_instant,
		"Prayer of Healing is a plain (sorcery-speed) Ability")
	_check(pr.cost == 3 and StackResolver._top_level_heal_party_amount(pr) == 3,
		"...3 resources, heals 3 from each hero and ally in your party")
	_check(StackResolver._heal_target_amount(pr) == 0,
		"...and it announces NO target — heal_party is not heal_target")
	for d in [fh, hl, pr]:
		_check(not d.tags.ends_with(" Talent"),
			"%s is tagged plain Holy, NOT a Talent — no 100.2c spec restriction" % d.card_name)


# Clarity of Thought is PURE CSV apart from its one gate, and every part of the
# recipe fails SILENTLY if mistyped: drop `ongoing` and the card resolves to the
# graveyard doing nothing; drop `require_hero_undamaged` and it becomes an
# unconditional card-a-turn engine. The ABSENCE of a `sacrifice_self` extra cost
# is pinned too — that is the whole difference from Mana Agate, which shares the
# ongoing-ability-with-a-draw-power shape but spends itself.
func _test_clarity_of_thought_recipe() -> void:
	var db := _make_db()
	var cl := db.get_def("dark_portal_68") as CardDef
	_check(cl != null, "dark_portal_68 (Clarity of Thought) resolves in the database")
	if cl == null:
		return
	_check(cl.card_type == "Ability" and cl.cost == 4, "Clarity of Thought is a 4-cost Ability")
	_check(StackResolver.is_ongoing_def(cl), "...ongoing — it stays in play")
	_check(StackResolver.requires_hero_undamaged(cl),
		"...gated on the hero having no damage on it")
	var ap := StackResolver._ally_activated_power(cl)
	_check(ap.get("effect", "") == "draw" and int(ap.get("amount", 0)) == 1,
		"...its activated power draws exactly 1")
	_check(int(ap.get("resource_cost", -1)) == 0, "...for no resource cost")
	_check(not StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "sacrifice_self"),
		"...and does NOT spend itself (the difference from Mana Agate)")
	_check(not StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "no_activate"),
		"...keeping the [Activate] tap symbol, so it is once per ready")


# Hide of the Wild is PURE CSV, and the segment fails silently if mistyped —
# the armor is DEF 0, so a broken recipe leaves a 2-cost card that does literally
# nothing, with nothing to fail on. The Back slot is pinned as well: it shares
# that slot with Chromatic Cloak, so a deck cannot run both, which is a real
# deckbuilding constraint rather than a detail.
func _test_hide_of_the_wild_recipe() -> void:
	var db := _make_db()
	var hide := db.get_def("azeroth_294") as CardDef
	_check(hide != null, "azeroth_294 (Hide of the Wild) resolves in the database")
	if hide == null:
		return
	_check(hide.card_type == "Equipment" and hide.cost == 2,
		"Hide of the Wild is a 2-cost Equipment")
	_check(hide.effects.contains("hero_heal_bonus:1"),
		"...carrying hero_heal_bonus:1 — the whole card")
	var spec := StackResolver._equipment_info(hide)
	_check(spec.get("slot", "") == "back",
		"...in the Back slot (shared with Chromatic Cloak — one or the other)")
	_check(int(spec.get("def", -1)) == 0,
		"...at DEF 0: it blocks nothing, the aura is all of it")


# Power Word: Fortitude is PURE CSV, and every part of it fails silently: a
# mistyped `attached_buff` leaves an attachment that lands and grants nothing,
# and a wrong attach kind would quietly bar the HERO — which is the host the card
# is really for. The ATK half is pinned at 0 too: this is health only.
func _test_power_word_fortitude_recipe() -> void:
	var db := _make_db()
	var pw := db.get_def("azeroth_83") as CardDef
	_check(pw != null, "azeroth_83 (Power Word: Fortitude) resolves in the database")
	if pw == null:
		return
	_check(pw.card_type == "Ability" and pw.cost == 3,
		"Power Word: Fortitude is a 3-cost Ability")
	_check(StackResolver.is_ongoing_def(pw), "...ongoing — the grant lasts while attached")
	_check(pw.effects.contains("attach:hero_or_ally"),
		"...attaches to a hero OR an ally, either party's")
	_check(pw.effects.contains("attached_buff:0:5"),
		"...granting +5 health and no ATK")


# Dismantle is PURE CSV — Shattering Blow's printed effect at half the cost with
# a class restriction instead — so a typo in the segment would leave a silent
# 2-cost do-nothing with nothing to fail on. The pool breadth is pinned too: the
# kind is `equipment` (rule 304 — armor, weapons and Items alike), NOT the
# narrowed `armor` of Sunder Armor, and the sorcery speed is what separates it
# from that card in a deck.
func _test_dismantle_recipe() -> void:
	var db := _make_db()
	var dis := db.get_def("azeroth_96") as CardDef
	_check(dis != null, "azeroth_96 (Dismantle) resolves in the database")
	if dis == null:
		return
	_check(dis.card_type == "Ability" and not dis.is_instant,
		"Dismantle is a plain (sorcery-speed) Ability")
	_check(dis.cost == 2, "Dismantle costs 2")
	_check(not dis.tags.ends_with(" Talent"),
		"...tagged plain Combat, NOT a Talent — no 100.2c spec restriction")
	_check(StackResolver.destroy_target_kind(dis) == "equipment",
		"...destroys target EQUIPMENT (304: armor, weapons and Items), not just armor")
	# Same printed effect as Shattering Blow — if one recipe drifts, say so.
	var blow := db.get_def("azeroth_168") as CardDef
	_check(blow != null and StackResolver.destroy_target_kind(blow) == "equipment",
		"...sharing Shattering Blow's pool exactly")


func _test_shadowmeld_recipe() -> void:
	# Shadowmeld is almost entirely CSV — the aura half is pure data, since
	# _hero_keyword_aura scans every segment. So a typo in either keyword is
	# COMPLETELY silent: the card just quietly grants one thing, or nothing.
	# Pin all four segments against the REAL database.
	var db := _make_db()
	var meld := db.get_def("dark_portal_131") as CardDef
	_check(meld != null, "dark_portal_131 (Shadowmeld) resolves in the database")
	if meld == null:
		return
	_check(meld.card_type == "Ability" and not meld.is_instant,
		"Shadowmeld is a plain (sorcery-speed) Ability")
	_check(meld.cost == 3, "Shadowmeld costs 3")
	var segs := Array(meld.effects.split("|"))
	_check("ongoing" in segs, "...ongoing — it stays in play in the hero row")
	_check("hero_keyword:elusive" in segs, "...granting the hero elusive")
	_check("hero_keyword:untargetable" in segs,
		"...AND untargetable — the first card to carry two hero_keyword segments")
	_check("turn_start_destroy_self" in segs,
		"...and destroying itself at the start of your turn")
	_check("requires_hero_race:Night Elf" in segs,
		"...Night Elf Hero Required (100.2b, deck legality only)")


func _test_mute_when_column() -> void:
	var db := _make_db()
	# The whole point of the column is that a typo does NOTHING observable — the
	# card simply keeps holding priority windows open — so the values are pinned
	# against the REAL database rather than a MockDB.
	var EXPECTED := {
		"dark_portal_178": "end_phase+own_turn",                 # Lynda Steele
		"azeroth_361": "opponent_turn_pre_end_unless_discard",   # Zapped Giants
		"azeroth_355": "opponent_turn_pre_end_unless_discard",   # Kibler's Exotic Pets
		"azeroth_348": "opponent_turn_pre_end_unless_discard",   # Big Game Hunter
		"dark_portal_289": "opponent_turn_pre_end_unless_discard", # Crown of the Earth
		"azeroth_360":     "opponent_turn_pre_end_unless_discard", # Your Fortune Awaits You
		"azeroth_353":     "opponent_turn_pre_end_unless_discard", # Into the Maw of Madness
		"azeroth_354":     "opponent_turn_pre_end_unless_discard", # It's a Secret to Everybody
		"azeroth_352":     "opponent_turn_pre_end_unless_discard", # In Dreams
		"azeroth_351":     "opponent_turn_pre_end_unless_discard", # A Donation of Wool
		"azeroth_347":     "opponent_turn_pre_end_unless_discard", # Battle of Darrowshire
		"azeroth_356":     "opponent_turn_pre_end_unless_discard", # The Love Potion
		"dark_portal_303": "opponent_turn_pre_end_unless_discard", # Lazy Peons
		"dark_portal_302": "opponent_turn_pre_end_unless_discard", # Hidden Enemies
		"dark_portal_305": "opponent_turn_pre_end_unless_discard", # Poison Water
		"azeroth_44":  "outside_combat",                         # Ravenous Bite
		"azeroth_6":   "empty_hand",                             # Moonshadow
		"azeroth_344": "opponent_turn",                          # For the Horde!
		"azeroth_45":  "opponent_turn",                          # Rayder
		"azeroth_214": "opponent_turn",                          # Ryn Dreamstrider
	}
	for id: String in EXPECTED:
		var d := db.get_def(id) as CardDef
		_check(d != null, "%s resolves in the database" % id)
		if d == null:
			continue
		_check(d.mute_when == EXPECTED[id],
			"%s (%s) carries mute_when=%s" % [id, d.card_name, EXPECTED[id]])
	# Every token used anywhere in the database must be one the router knows —
	# an unknown token is silently inert, which is the failure mode this catches.
	# Deliberately NOT muted, and each for a reason a later tidy-up would undo
	# silently: Torek's Assault's gate ("your hero was damaged by an ally this
	# turn") and The Perfect Stout's "can't attack" mode BOTH only do work on
	# the opponent's turn, so muting them hides the one window each works in;
	# A New Plague and Thwarting Kolkar carry require_turn_player and are
	# already illegal off-turn. Defias / Counterattack! are a judgement call:
	# their ally-count gates flicker DURING the opponent's turn, so an
	# auto-pass could carry the player past the moment the gate was true.
	for id: String in ["azeroth_345", "dark_portal_293", "dark_portal_304",
			"dark_portal_309", "azeroth_340", "azeroth_343"]:
		var ud := db.get_def(id) as CardDef
		if ud != null:
			_check(ud.mute_when == "",
				"%s (%s) is deliberately NOT muted" % [id, ud.card_name])
	var KNOWN := ["end_phase", "own_turn", "opponent_turn",
		"opponent_turn_pre_end_unless_discard", "empty_hand", "outside_combat",
		"hero_not_defending", "no_combat_proposal",
		"hero_not_defending_vs_ally"]
	# The regularized three: dropping require_turn_player is the whole point of
	# the swap, so a re-added flag must fail here rather than silently restoring
	# the deviation (the mute would still work, and nobody would notice).
	for id: String in ["azeroth_344", "azeroth_45", "azeroth_214"]:
		var rd := db.get_def(id) as CardDef
		if rd != null:
			_check(not StackResolver.requires_turn_player(rd),
				"%s (%s) is LEGAL off-turn as printed — no require_turn_player" % [id, rd.card_name])
	for d: CardDef in db.get_all_defs():
		if d.mute_when == "":
			continue
		for tok in d.mute_when.split("+", false):
			_check(KNOWN.has(tok.strip_edges()),
				"%s: mute_when token '%s' is a known condition" % [d.card_name, tok.strip_edges()])


# Ghost Wolf (azeroth_110). Pure CSV on the data side: one activated-power
# segment carries the effect, the hero-exhaust cost AND the missing [Activate]
# tap symbol, and the mute token is what keeps it from nagging at every window.
# Each of those fails SILENTLY if mistyped — a wrong effect key leaves a 2-cost
# ongoing that does nothing, a missing no_activate silently makes it once-per-
# ready off a card that never exhausts otherwise. So pin it against the REAL
# database.
# Rockbiter Weapon (azeroth_115). PURE CSV — all four segments are existing
# recipes, so there is no card-specific code to fail. Each fails SILENTLY if
# mistyped: a wrong attach kind leaves it unplayable on weapons, a missing
# attached_buff leaves a 2-cost do-nothing, and a typo'd hero_keyword grants
# nothing at all. The card is also an Instant Ability (it goes down in the
# opponent's attack window, before the protect point), which the CSV type cell
# alone decides. So pin the lot against the REAL database.
func _test_rockbiter_weapon_recipe() -> void:
	var db := _make_db()
	var rb := db.get_def("azeroth_115") as CardDef
	_check(rb != null, "azeroth_115 (Rockbiter Weapon) resolves in the database")
	if rb == null:
		return
	_check(rb.cost == 2 and rb.card_type == "Ability" and rb.is_instant,
		"Rockbiter Weapon is a 2-cost INSTANT Ability")
	var segs := Array(rb.effects.split("|"))
	_check(segs.has("ongoing"), "…ongoing, so it stays in play once attached")
	_check(segs.has("attach:melee_weapon"),
		"…attaches to one of your Melee weapons (Windfury Weapon's kind)")
	_check(segs.has("attached_buff:2:0"),
		"…granting the attached weapon +2 ATK and no health")
	_check(segs.has("hero_keyword:protector"),
		"…and your hero protector, read live out of the attached zone")


# Totemic Call (azeroth_117). The four modes ARE the card, and each one is a
# separate CSV segment whose element gates it — a typo in an element silently
# makes that mode unreachable (no totem will ever match it), and a typo in an
# inner effect makes it resolve into nothing. Instant speed matters too: it is
# flashed in to ready a weapon mid-combat or burn an attacker. Pin the lot
# against the REAL database.
func _test_totemic_call_recipe() -> void:
	var db := _make_db()
	var tc := db.get_def("azeroth_117") as CardDef
	_check(tc != null, "azeroth_117 (Totemic Call) resolves in the database")
	if tc == null:
		return
	_check(tc.cost == 4 and tc.card_type == "Ability" and tc.is_instant,
		"Totemic Call is a 4-cost INSTANT Ability")
	var modes := StackResolver.totem_modes(tc)
	_check(modes.size() == 4, "…with four modes")
	if modes.size() != 4:
		return
	var expected := [
		["air",   "ready_hero_and_melee_weapon"],
		["earth", "party_allies_atk_this_turn:1"],
		["fire",  "deal_damage_to_target:2:fire"],
		["water", "draw:2"],
	]
	for i in expected.size():
		_check(String(modes[i].get("element", "")) == expected[i][0]
			and String(modes[i].get("effect", "")) == expected[i][1],
			"…mode %d is %s -> %s" % [i, expected[i][0], expected[i][1]])
	# Only the fire mode announces a target (the card's errata).
	var targeted := 0
	for m in modes:
		if StackResolver.mode_target_kind(String(m.get("effect", ""))) != "":
			targeted += 1
	_check(targeted == 1, "…and exactly ONE mode (fire) announces a target")


# Rak Skyfury / Warchief Thrall / Masten Everspirit. All three are PURE CSV —
# one effects key each, no card-specific code — so a typo is completely silent:
# a vanilla 1/1, a vanilla 7/8 and a vanilla 4/2 with nothing to fail on.
# Thrall's alignment argument and Unique tag are the easiest to get wrong, and
# both change what the card does, so pin them against the REAL database.
func _test_shaman_ally_recipes() -> void:
	var db := _make_db()

	var rak := db.get_def("azeroth_257") as CardDef
	_check(rak != null, "azeroth_257 (Rak Skyfury) resolves in the database")
	if rak != null:
		_check(rak.cost == 1 and rak.printed_atk == 1 and rak.printed_health == 1,
			"Rak Skyfury is a 1-cost 1/1")
		_check(Array(rak.effects.split("|")).has("on_enter:ready_hero_and_weapon"),
			"…readying your hero and one of your weapons on enter (ANY weapon)")

	var thrall := db.get_def("azeroth_267") as CardDef
	_check(thrall != null, "azeroth_267 (Warchief Thrall) resolves in the database")
	if thrall != null:
		_check(thrall.cost == 9 and thrall.printed_atk == 7 and thrall.printed_health == 8,
			"Warchief Thrall is a 9-cost 7/8")
		_check(Array(thrall.effects.split("|")).has("other_party_allies_buff:Horde:3:3"),
			"…buffing OTHER Horde allies +3/+3 (alignment filter included)")
		_check("unique" in thrall.keywords,
			"…and he is Unique (414.3a)")

	var masten := db.get_def("azeroth_250") as CardDef
	_check(masten != null, "azeroth_250 (Masten Everspirit) resolves in the database")
	if masten != null:
		_check(masten.cost == 5 and masten.printed_atk == 4 and masten.printed_health == 2,
			"Masten Everspirit is a 5-cost 4/2")
		_check(Array(masten.effects.split("|")).has("on_destroyed:return_self_to_hand"),
			"…returning himself from the graveyard to hand when destroyed")


func _test_ghost_wolf_recipe() -> void:
	var db := _make_db()
	var gw := db.get_def("azeroth_110") as CardDef
	_check(gw != null, "azeroth_110 (Ghost Wolf) resolves in the database")
	if gw == null:
		return
	_check(gw.cost == 2 and gw.card_type == "Ability",
		"Ghost Wolf is a 2-cost Ability")
	_check(StackResolver.is_ongoing_def(gw), "…ongoing, so it lives in the hero row")
	var ap := StackResolver._ally_activated_power(gw)
	_check(ap.get("effect", "") == "remove_attacking_allies",
		"…its power removes all attacking allies from combat")
	_check(StackResolver.power_resource_cost(ap, 0) == 0, "…for no resources")
	_check(ap.get("targets", "") == "",
		"…non-targeted, so 706 Untargetable is irrelevant")
	var xc: String = ap.get("extra_cost", "")
	_check(StackResolver.power_has_extra_cost(xc, "exhaust_hero"),
		"…paid by exhausting your hero")
	_check(StackResolver.power_has_extra_cost(xc, "no_activate"),
		"…with NO [Activate] tap symbol: the source itself never exhausts")
	_check(gw.mute_when == "hero_not_defending_vs_ally",
		"…muted unless our hero is defending against an attacking ALLY")


func _test_gift_of_the_elven_magi_recipe() -> void:
	var db := _make_db()
	var gift := db.get_def("azeroth_322") as CardDef
	_check(gift != null, "azeroth_322 (Gift of the Elven Magi) resolves in the database")
	if gift == null:
		return
	var segs := Array(gift.effects.split("|"))
	_check(gift.card_type == "Equipment", "Gift of the Elven Magi is Equipment (304)")
	_check(gift.cost == 1, "…costing 1")
	_check(gift.printed_atk == 1, "…with 1 printed ATK")
	_check(segs.has("strike_cost:4"), "…and a strike cost of 4, so it IS a weapon (303)")
	# 1 ATK / strike 4 is the worst weapon in the pool: the AI must never strike
	# with it, which is the whole job of the power_weapon flag.
	_check(segs.has("power_weapon"),
		"…flagged power_weapon so the AI uses the power and never the strike")
	# The power is the card, and every field below fails SILENTLY if mistyped —
	# which is why it is pinned against the real CSV rather than against a MockDB.
	var ap := StackResolver._ally_activated_power(gift)
	_check(not ap.is_empty(), "…and it carries an activated power")
	if ap.is_empty():
		return
	_check(ap.get("effect", "") == "look_top_card_to_hand",
		"…whose effect is look_top_card_to_hand")
	_check(int(ap.get("resource_cost", -1)) == 2, "…costing (2)")
	_check(StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "exhaust_hero"),
		"…plus the 'Exhaust your hero' extra cost")
	# Whether the power costs a hero exhaust and whether its printed cost carries
	# the [Activate] tap symbol are INDEPENDENT axes; this card prints both, so
	# no_activate must be absent or the weapon would stop exhausting itself.
	_check(not StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "no_activate"),
		"…and KEEPS its [Activate] tap symbol, so it is once per ready")
	_check(ap.get("targets", "") == "",
		"…announcing no target — which card is looked at is a resolution read (709.2b)")


func _test_graccus_recipe() -> void:
	var db := _make_db()
	var hero := db.get_def("azeroth_4") as CardDef
	_check(hero != null, "azeroth_4 (Graccus) resolves in the database")
	if hero == null:
		return
	_check(hero.card_type == "Hero", "Graccus is a Hero card")
	_check(hero.printed_health == 29, "Graccus has 29 health")
	_check(hero.cost == 3, "…and his flip costs (3)")
	_check(not StackResolver.requires_turn_player(hero),
		"…with no 'use only on your turn' clause — it stays instant-speed (701.3)")
	var shield := -1
	for seg in hero.effects.split("|"):
		var parts: PackedStringArray = seg.strip_edges().split(":")
		if parts[0].strip_edges() == "prevent_next_damage_target" and parts.size() > 1:
			shield = int(parts[1])
	_check(shield == 3, "…and prevents the next 3 damage to its target")


func _test_resurrection_recipe() -> void:
	var db := _make_db()
	var rez := db.get_def("azeroth_86") as CardDef
	_check(rez != null, "azeroth_86 (Resurrection) resolves in the database")
	if rez == null:
		return
	_check(rez.card_type == "Ability" and not rez.is_instant,
		"Resurrection is a plain (sorcery-speed) Ability")
	_check(rez.cost == 4, "Resurrection costs 4")
	var req := StackResolver.get_graveyard_search_requirement(rez)
	_check(req.get("dest", "") == "play", "…it puts the card into PLAY")
	_check(str(req.get("card_type", "")) == "Ally", "…an ally card")
	_check(str(req.get("owner", "")) == "own", "…from YOUR graveyard only")
	_check(bool(req.get("max_cost_dynamic", false)),
		"…capped by your total resource count, not a fixed number")
	_check(str(req.get("damage_mode", "")) == "",
		"…and with NO damage mode: it returns at full health, unlike Ancestral Spirit")


# Chastise (azeroth_76) and Smite (azeroth_89) are PURE CSV — the whole card is
# `deal_damage_to_target:N:holy|damage_unpreventable`, and a typo in that rider
# would silently leave the damage preventable with nothing to fail on. Pinned
# against the REAL database.
func _test_unpreventable_holy_recipes() -> void:
	var db := _make_db()
	for entry in [["azeroth_76", "Chastise", 2, "2"], ["azeroth_89", "Smite", 5, "4"]]:
		var def := db.get_def(entry[0]) as CardDef
		_check(def != null, "%s (%s) resolves in the database" % [entry[0], entry[1]])
		if def == null:
			continue
		_check(def.card_type == "Ability" and not def.is_instant,
			"%s is a plain (sorcery-speed) Ability" % entry[1])
		_check(def.cost == int(entry[2]), "%s costs %d" % [entry[1], int(entry[2])])
		var damage := ""
		var unpreventable := false
		for seg in def.effects.split("|"):
			var parts: PackedStringArray = seg.strip_edges().split(":")
			if parts[0].strip_edges() == "deal_damage_to_target" and parts.size() > 2:
				damage = parts[1].strip_edges()
				_check(parts[2].strip_edges() == "holy",
					"%s deals holy damage" % entry[1])
			if seg.strip_edges() == "damage_unpreventable":
				unpreventable = true
		_check(damage == entry[3],
			"%s deals %s (got '%s')" % [entry[1], entry[3], damage])
		_check(unpreventable,
			"%s carries damage_unpreventable — the damage can't be prevented" % entry[1])


# Rain of Fire is driven entirely by its CSV recipe — no card-specific code — so
# a typo in either segment key would silently turn it into a vanilla 4-cost
# ongoing that charges nothing and burns nothing, with no test to fail. Pin both
# halves against the real database, and pin the two things about them that are
# easy to get wrong in a rewrite: the upkeep key must be one TurnManager
# actually collects, and the burn must be the HERO-sourced key, not Infernal's.
func _test_rain_of_fire_recipe() -> void:
	var db := _make_db()
	var rof := db.get_def("azeroth_129") as CardDef
	_check(rof != null, "azeroth_129 (Rain of Fire) resolves in the database")
	if rof == null:
		return
	_check(rof.card_type == "Ability" and not rof.is_instant,
		"Rain of Fire is a plain (sorcery-speed) Ability")
	_check(rof.cost == 4, "Rain of Fire costs 4")
	var segments: Array = []
	for entry in rof.effects.split("|"):
		segments.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("ongoing" in segments, "…and is ongoing, so it stays in the hero row")
	_check("turn_start_pay_or_destroy" in segments, "…carries the upkeep segment")
	_check("end_of_turn_hero_damage_opposing" in segments,
		"…and the HERO-sourced end-of-turn burn (not Infernal's ally-sourced key)")
	_check(TurnManager.YOUR_TURN_TRIGGERS.has("turn_start_pay_or_destroy"),
		"the upkeep key is one the ready step actually collects")
	_check(not TurnManager.EACH_TURN_TRIGGERS.has("turn_start_pay_or_destroy"),
		"…on YOUR turn only — an each-turn upkeep would charge twice a round")


# Ritual Sacrifice is pure CSV, and three separate things in its recipe would
# each fail SILENTLY if mistyped: `no_activate` (it would start exhausting itself
# and stop being repeatable), the non-friendly_ally TARGETS (which is what makes
# the sacrifice a separate pick), and `hero_deals_damage` (the packet would come
# from the ability instead of the hero, quietly dropping Chromatic Cloak and
# Shadowform). Pin all three against the real database.
func _test_ritual_sacrifice_recipe() -> void:
	var db := _make_db()
	var rs := db.get_def("dark_portal_112") as CardDef
	_check(rs != null, "dark_portal_112 (Ritual Sacrifice) resolves in the database")
	if rs == null:
		return
	_check(rs.card_type == "Ability" and not rs.is_instant,
		"Ritual Sacrifice is a plain (sorcery-speed) Ability")
	_check(rs.cost == 2, "Ritual Sacrifice costs 2")
	var ap := StackResolver._ally_activated_power(rs)
	_check(ap.get("effect", "") == "deal_damage_to_target",
		"…its power deals damage to a target")
	_check(int(ap.get("amount", 0)) == 1 and str(ap.get("dmg_type", "")) == "shadow",
		"…1 shadow damage")
	_check(StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "sacrifice_ally"),
		"…paid by destroying an ally in your party")
	_check(StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "no_activate"),
		"…with NO [Activate] tap symbol, so it is repeatable")
	_check(StackResolver.power_sacrifice_is_separate(ap),
		"…and the sacrifice is a separate pick from the target (two-pick flow)")
	var segs: Array = []
	for entry in rs.effects.split("|"):
		segs.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("ongoing" in segs, "…it is ongoing, so it stays in the hero row")
	_check("hero_deals_damage" in segs,
		"…and YOUR HERO deals the damage, not the ability itself")


# The repeat-count UI (ally first, then "how many?") is opened off
# StackResolver.power_repeats_by_count, keyed on the POWER'S EFFECT — so a
# rewritten recipe would silently drop Soul Link back to one click per point
# with nothing to fail on. Pin it against the real database.
func _test_soul_link_count_power() -> void:
	var db := _make_db()
	var link := db.get_def("azeroth_133") as CardDef
	_check(link != null, "azeroth_133 (Soul Link) resolves in the database")
	if link == null:
		return
	_check(StackResolver.power_repeats_by_count(link),
		"Soul Link's power opens the repeat-count dialog")
	var ap := StackResolver._ally_activated_power(link)
	_check(ap.get("targets", "") == "chosen_friendly_ally",
		"…and picks the ally as a CHOICE, not a target (706 n/a)")
	_check(StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "put_damage_ally"),
		"…paying 1 damage put on that ally per use")
	# Every other implemented activated power must NOT open it — the dialog
	# submits N copies of the power, which is only ever right for a free one.
	for def_id in ["azeroth_125", "azeroth_244", "dark_portal_218", "azeroth_211"]:
		var other := db.get_def(def_id) as CardDef
		if other == null:
			continue
		_check(not StackResolver.power_repeats_by_count(other),
			"%s (%s) keeps the single-use power flow"
				% [def_id, other.card_name])


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


func _test_polymorph_recipe() -> void:
	# Polymorph is pure CSV on top of a general mechanism, so a typo in any one
	# of its four ongoing segments would silently leave a 2-cost attachment that
	# does part of its job, with nothing to fail on.
	var db := _make_db()
	var poly := db.get_def("azeroth_58") as CardDef
	_check(poly != null, "azeroth_58 (Polymorph) resolves in the database")
	if poly == null:
		return
	_check(poly.card_type == "Ability" and not poly.is_instant,
		"Polymorph is a plain (sorcery-speed) Ability")
	_check(poly.cost == 2, "Polymorph costs 2")
	var segments: Array = []
	for entry in poly.effects.split("|"):
		segments.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("ongoing" in segments, "…is ongoing (the errata clarifies this)")
	_check("attach" in segments and StackResolver.attach_parts(poly).size() > 1
		and StackResolver.attach_parts(poly)[1] == "ally",
		"…attaches to target ALLY, so a hero is never a legal target")
	_check("attached_cannot_attack" in segments, "…the host can't attack")
	_check("attached_cannot_protect" in segments, "…the host can't protect")
	_check("attached_loses_powers" in segments, "…the host has a blank text box (700.3)")
	_check(StackResolver._effect_flag_arg(poly, "attached_ally_type") == "Sheep",
		"…and gains the Sheep tag (202.3 — additive)")
	# No `attached_buff` and no `attach_heal`: the AI's _attach_actions reads it
	# as a DEBUFF and aims it at the opponent, which is the whole targeting policy.
	_check(not ("attached_buff" in segments) and not ("attach_heal" in segments),
		"…and carries no friendly grant, so the AI aims it at the opponent")


# Avanthera is PURE CSV on the engine side — one effect key, no target, no
# rider. A typo in the key or a stray `[Activate]` (i.e. a missing
# `no_activate`) would leave a silent 2-cost vanilla 3/2 with nothing to fail
# on, so pin the whole recipe against the REAL database.
func _test_avanthera_recipe() -> void:
	var db := _make_db()
	var av := db.get_def("dark_portal_154") as CardDef
	_check(av != null, "dark_portal_154 (Avanthera) resolves in the database")
	if av == null:
		return
	_check(av.cost == 2 and av.printed_atk == 3 and av.printed_health == 2,
		"Avanthera is a 2-cost 3/2")
	var ap := StackResolver._ally_activated_power(av)
	_check(ap.get("effect", "") == "remove_self_from_combat",
		"…her power removes her from combat")
	_check(StackResolver.power_resource_cost(ap, 0) == 1, "…for (1)")
	_check(ap.get("targets", "") == "",
		"…non-targeted, so 706 Untargetable is irrelevant")
	_check(StackResolver.power_has_extra_cost(ap.get("extra_cost", ""), "no_activate"),
		"…with NO [Activate] tap symbol: no exhaust, no summoning sickness, repeatable")


# Wisp (dark_portal_197). The card is PURE CSV on the data side — the whole
# behaviour hangs off one effects key, and the key is what decides which ZONE
# TurnManager scans for the trigger (GRAVEYARD_TURN_TRIGGERS, rule 703.3a). A
# typo there is completely silent: the Wisp becomes a vanilla 0/1 that never
# comes back, with nothing to fail on. So pin it against the REAL database.
func _test_wisp_recipe() -> void:
	var db := _make_db()
	var w := db.get_def("dark_portal_197") as CardDef
	_check(w != null, "dark_portal_197 (Wisp) resolves in the database")
	if w == null:
		return
	_check(w.cost == 1 and w.printed_atk == 0 and w.printed_health == 1,
		"Wisp is a 1-cost 0/1")
	_check(w.card_type == "Ally", "…an Ally card, so it can be reanimated/fetched normally")
	_check(w.effects.find("graveyard_turn_start_pay_to_hand:1") >= 0,
		"…carrying the graveyard return power for (1)")
	_check(TurnManager.GRAVEYARD_TURN_TRIGGERS.has("graveyard_turn_start_pay_to_hand"),
		"…and that key is collected from the GRAVEYARD (703.3a), not the board")
	_check(not TurnManager.YOUR_TURN_TRIGGERS.has("graveyard_turn_start_pay_to_hand") 			and not TurnManager.EACH_TURN_TRIGGERS.has("graveyard_turn_start_pay_to_hand"),
		"…the three trigger-zone lists stay disjoint")

func _test_lessons_in_lurking_recipe() -> void:
	# Lessons in Lurking is pure CSV on top of the general attachment machinery
	# plus one generic keyword key, so a typo in the KEYWORD argument is
	# completely silent: the attachment still lands and simply grants nothing.
	var db := _make_db()
	var lil := db.get_def("dark_portal_146") as CardDef
	_check(lil != null, "dark_portal_146 (Lessons in Lurking) resolves in the database")
	if lil == null:
		return
	_check(lil.card_type == "Ability" and not lil.is_instant,
		"Lessons in Lurking is a plain (sorcery-speed) Ability")
	_check(lil.cost == 2, "Lessons in Lurking costs 2")
	var segments: Array = []
	for entry in lil.effects.split("|"):
		segments.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("ongoing" in segments, "…is ongoing, so it stays in play as an attachment")
	_check("attach" in segments and StackResolver.attach_parts(lil).size() > 1
		and StackResolver.attach_parts(lil)[1] == "ally",
		"…attaches to target ALLY, so a hero is never a legal target")
	_check(StackResolver._effect_flag_arg(lil, "attached_keyword") == "stealth",
		"…and grants STEALTH — the argument a typo would silently blank")

func _test_thorns_recipe() -> void:
	# Thorns' reflect key is only ever exercised by the scenario suite through a
	# MockDB const, so a typo in the CSV row itself would be completely silent —
	# a 4-cost attachment that lands on a character and then does nothing at all.
	# Both arguments matter: the amount is what it reflects, and the damage type
	# is what a typed replacement effect keys on.
	var db := _make_db()
	var th := db.get_def("dark_portal_28") as CardDef
	_check(th != null, "dark_portal_28 (Thorns) resolves in the database")
	if th == null:
		return
	_check(th.card_type == "Ability" and th.is_instant,
		"Thorns is an INSTANT Ability — it can be flashed in during a combat window")
	_check(th.cost == 4, "Thorns costs 4")
	var segments: Array = []
	for entry in th.effects.split("|"):
		segments.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("ongoing" in segments, "…is ongoing, so it stays in play as an attachment")
	var ap := StackResolver.attach_parts(th)
	_check("attach" in segments and ap.size() > 1 and ap[1] == "hero_or_ally",
		"…attaches to a HERO OR ALLY, either party's")
	var spec := PackedStringArray()
	for entry in th.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "attached_combat_damage_reflect":
			spec = parts
	_check(spec.size() > 2, "…carrying the combat-damage reflect grant")
	if spec.size() > 2:
		_check(int(spec[1]) == 1, "…reflecting 1 — the amount a typo would zero out")
		_check(spec[2].strip_edges() == "nature",
			"…as NATURE damage, the type a typed replacement effect keys on")

func _test_eye_of_rend_and_scarlet_kris_recipes() -> void:
	# Both cards are pure CSV on top of the general equipment machinery, so a
	# typo is completely silent: Eye of Rend becomes a 1-cost DEF 0 helm that
	# boosts nothing, and Scarlet Kris a weapon nobody can afford to strike (or
	# one that is free when it should not be).
	var db := _make_db()
	var eye := db.get_def("azeroth_288") as CardDef
	_check(eye != null, "azeroth_288 (Eye of Rend) resolves in the database")
	if eye != null:
		_check(eye.card_type == "Equipment" and eye.cost == 1,
			"Eye of Rend is a 1-cost Equipment")
		var e_info: Dictionary = StackResolver._equipment_info(eye)
		_check(e_info.get("slot", "") == "head",
			"…in the HEAD slot, so Head (1) uniqueness applies")
		_check(int(e_info.get("def", -1)) == 0,
			"…with DEF 0 — it is not a shielder on its own")
		_check(StackResolver._effect_flag_arg(eye, "weapon_atk_bonus") == "1",
			"…granting +1 ATK — the argument a typo would silently blank")

	var kris := db.get_def("azeroth_333") as CardDef
	_check(kris != null, "azeroth_333 (Scarlet Kris) resolves in the database")
	if kris != null:
		_check(kris.card_type == "Equipment" and kris.cost == 2,
			"Scarlet Kris is a 2-cost Equipment")
		_check(kris.printed_atk == 1, "…a printed 1 ATK")
		_check(kris.dmg_type == "Melee", "…dealing Melee damage")
		_check(StackResolver._effect_flag_arg(kris, "strike_cost") == "0",
			"…and striking for FREE — strike cost 0, not a missing field")

	# Krol Blade's rarity was corrected from Rare: its set symbol is green
	# (Uncommon), matching Chromatic Cloak rather than blue-Rare Brain Freeze.
	var krol := db.get_def("azeroth_331") as CardDef
	if krol != null:
		_check(krol.rarity == "Uncommon", "azeroth_331 (Krol Blade) is Uncommon")

func _test_point_blank_recipe() -> void:
	# Point Blank is two riders on a generic damage effect plus a mute token, so
	# every part of it fails SILENTLY if mistyped: a missing `target_attacker`
	# widens the pool to any hero or ally, a missing `require_hero_defending`
	# makes it an unconditional 3-damage instant, and a missing mute token just
	# means it nags at every window.
	var db := _make_db()
	var pb := db.get_def("dark_portal_37") as CardDef
	_check(pb != null, "dark_portal_37 (Point Blank) resolves in the database")
	if pb == null:
		return
	_check(pb.card_type == "Ability" and pb.is_instant,
		"Point Blank is an INSTANT Ability — it is flashed into the defend window")
	_check(pb.cost == 2, "Point Blank costs 2")
	var segments: Array = []
	for entry in pb.effects.split("|"):
		segments.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("deal_damage_to_target" in segments, "…dealing damage to a target")
	_check(StackResolver._effect_flag_arg(pb, "deal_damage_to_target") == "3",
		"…3 of it — the amount a typo would zero out")
	_check("target_attacker" in segments,
		"…narrowed to the ATTACKER, not any hero or ally")
	_check("require_hero_defending" in segments,
		"…and gated on our hero defending — without this it is unconditional")
	_check(pb.mute_when == "hero_not_defending",
		"…muted while our hero is not defending (legality is unaffected)")
	# The condition is an EFFECT condition, never a use restriction: refusing the
	# announcement would repeat the For the Horde! / Rayder deviation.
	_check(not StackResolver.requires_turn_player(pb),
		"Point Blank carries no turn restriction — it is legal whenever we have priority")

func _test_lokdelar_recipe() -> void:
	# Lok'delar's trigger is data on top of the shared play-trigger framework, so
	# every field fails SILENTLY if mistyped: a wrong CLASS watches a class no
	# card carries, a wrong amount grants nothing, and a missing two_handed makes
	# it a one-handed staff.
	var db := _make_db()
	var lok := db.get_def("dark_portal_279") as CardDef
	_check(lok != null, "dark_portal_279 (Lok'delar) resolves in the database")
	if lok == null:
		return
	_check(lok.card_type == "Equipment" and lok.cost == 2,
		"Lok'delar is a 2-cost Equipment")
	_check(lok.printed_atk == 1 and lok.dmg_type == "Melee",
		"…a 1 ATK MELEE weapon — it never boosts itself")
	_check(StackResolver._effect_flag_arg(lok, "strike_cost") == "2",
		"…with strike cost 2")
	var segments: Array = []
	for entry in lok.effects.split("|"):
		segments.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("two_handed" in segments, "…Two-Handed, so it locks out Off-Hand (414.3c)")
	var spec := PackedStringArray()
	for entry in lok.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "on_play_ability_ranged_atk":
			spec = parts
	_check(spec.size() > 2, "…carrying the play trigger")
	if spec.size() > 2:
		_check(spec[1].strip_edges() == "Hunter",
			"…watching the HUNTER class icon — a typo here watches nothing")
		_check(int(spec[2]) == 1, "…granting +1 ATK")
	# The trigger reads a CLASS, so the parser must accept both storage forms.
	_check(lok.has_class("Hunter"), "Lok'delar itself carries the Hunter icon")
	var krol := db.get_def("azeroth_331") as CardDef
	if krol != null:
		_check(krol.has_class("Hunter") and krol.has_class("Warrior"),
			"multi-class abbrevs parse (Krol Blade HuPaRoWa is Hunter AND Warrior)")
		_check(not krol.has_class("Mage"), "…and exclude classes it doesn't carry")

func _test_wing_clip_recipe() -> void:
	# Wing Clip is a rider on a generic damage effect plus a mute token, so every
	# part fails SILENTLY if mistyped: a missing `cannot_attack_source` leaves a
	# 1-cost ping, and the wrong rider name would apply a TOTAL attack lock
	# instead of the partial one the card prints.
	var db := _make_db()
	var wc := db.get_def("dark_portal_42") as CardDef
	_check(wc != null, "dark_portal_42 (Wing Clip) resolves in the database")
	if wc == null:
		return
	_check(wc.card_type == "Ability" and wc.is_instant,
		"Wing Clip is an INSTANT Ability — it interrupts a pending proposal")
	_check(wc.cost == 1, "Wing Clip costs 1")
	_check(wc.has_class("Hunter"), "…carrying the Hunter icon")
	var seg := PackedStringArray()
	for entry in wc.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "deal_damage_to_target":
			seg = parts
	_check(seg.size() > 3, "…as a damage effect WITH a rider field")
	if seg.size() > 3:
		_check(int(seg[1]) == 1, "…1 damage")
		_check(seg[2].strip_edges() == "melee",
			"…MELEE, so Aspect of the Hawk does not boost it")
		_check(seg[3].strip_edges() == "cannot_attack_source",
			"…and the PARTIAL lock, not the total `cannot_attack`")
	_check(wc.mute_when == "no_combat_proposal",
		"…muted outside a window with a combat proposal on the chain")

func _test_cyclone_recipe() -> void:
	# Cyclone's two new engine keys are only ever exercised by the scenario
	# suite through a MockDB const, so a typo in the CSV row itself would be
	# completely silent — a 1-cost attachment that locks nothing, or one that
	# never counts down and therefore never lets go.
	var db := _make_db()
	var cyc := db.get_def("dark_portal_21") as CardDef
	_check(cyc != null, "dark_portal_21 (Cyclone) resolves in the database")
	if cyc == null:
		return
	_check(cyc.card_type == "Ability" and cyc.is_instant,
		"Cyclone is an INSTANT Ability — it is flashed in during a combat window")
	_check(cyc.cost == 1, "Cyclone costs 1")
	var segments: Array = []
	for entry in cyc.effects.split("|"):
		segments.append(entry.strip_edges().split(":")[0].strip_edges())
	_check("ongoing" in segments, "…is ongoing")
	var ap := StackResolver.attach_parts(cyc)
	_check("attach" in segments and ap.size() > 1 and ap[1] == "hero_or_ally",
		"…attaches to target hero OR ally, either party's")
	_check("attach_counters:wind:3" in cyc.effects,
		"…and puts THREE wind counters on itself as it attaches")
	_check("attached_cannot_attack" in segments, "…the host can't attack")
	_check("attached_cannot_protect" in segments, "…the host can't protect")
	_check(not ("attached_loses_powers" in segments),
		"…but the host does NOT lose its powers — that is Polymorph, not Cyclone")
	_check("turn_start_remove_counter_destroy:wind" in cyc.effects,
		"…and it removes one wind counter at its controller's ready step")
	_check(TurnManager.YOUR_TURN_TRIGGERS.has("turn_start_remove_counter_destroy"),
		"…the countdown is a YOUR-turn trigger, so it ticks once a round")


func _test_edgemasters_handguards_recipe() -> void:
	# Edgemaster's Handguards is PURE CSV on top of Margaret Fowl's strike-cost
	# aura, so every part of it fails SILENTLY if mistyped: a wrong slot makes it
	# fight for Head or Chest, a missing DEF makes it a non-shielder, and a wrong
	# sign or a stray OPPOSING value would tax the wielder instead of discounting.
	var db := _make_db()
	var ed := db.get_def("azeroth_286") as CardDef
	_check(ed != null, "azeroth_286 (Edgemaster's Handguards) resolves in the database")
	if ed == null:
		return
	_check(ed.card_type == "Equipment" and ed.cost == 3,
		"Edgemaster's Handguards is a 3-cost Equipment")
	var info: Dictionary = StackResolver._equipment_info(ed)
	_check(info.get("slot", "") == "hands",
		"…in the HANDS slot — its own slot, shared with nothing shipped")
	_check(int(info.get("def", -1)) == 1, "…with DEF 1")
	_check(int(info.get("capacity", 0)) == 1, "…Hands (1), the default capacity")
	# Despite the slot's NAME it is armor, not an Off-Hand or a weapon, so it
	# costs ZERO hands in the rule 406 wielding model and never conflicts with a
	# Two-Handed weapon.
	_check(StackResolver.equipment_hand_cost(ed) == 0,
		"…costing 0 hands, so a Two-Handed weapon still fits")
	var seg := ""
	for s2 in ed.effects.split("|"):
		if s2.begins_with("strike_cost_mod:"):
			seg = s2
	_check(seg == "strike_cost_mod:-1:0",
		"…and carrying strike_cost_mod:-1:0 — a discount for US, no tax on THEM (got '%s')" % seg)
	_check(ed.card_subtype == "Mail", "…printed Armor - Mail")
	_check(ed.rarity == "Uncommon", "…Uncommon")
	for cls in ["Hunter", "Paladin", "Shaman", "Warrior"]:
		_check(ed.has_class(cls), "…legal for %s" % cls)
	for cls in ["Druid", "Mage", "Priest", "Rogue", "Warlock"]:
		_check(not ed.has_class(cls), "…NOT legal for %s" % cls)


func _test_deathdealer_breastplate_recipe() -> void:
	# Pure CSV on Eye of Rend's aura, so the AMOUNT is what fails silently: a
	# mistyped bonus leaves a 5-cost DEF 1 chestpiece that boosts nothing, and a
	# wrong slot would fight for Head instead of Chest.
	var db := _make_db()
	var dd := db.get_def("azeroth_283") as CardDef
	_check(dd != null, "azeroth_283 (Deathdealer Breastplate) resolves in the database")
	if dd == null:
		return
	_check(dd.card_type == "Equipment" and dd.cost == 5,
		"Deathdealer Breastplate is a 5-cost Equipment")
	var info: Dictionary = StackResolver._equipment_info(dd)
	_check(info.get("slot", "") == "chest",
		"…in the CHEST slot, which it shares with Truesilver Breastplate")
	_check(int(info.get("def", -1)) == 1, "…with DEF 1")
	_check(int(info.get("capacity", 0)) == 1, "…Chest (1), the default capacity")
	# It is armor, not an Off-Hand or a weapon, so it costs no hands (406).
	_check(StackResolver.equipment_hand_cost(dd) == 0, "…costing 0 hands")
	_check(StackResolver._effect_flag_arg(dd, "weapon_atk_bonus") == "2",
		"…granting +2 ATK — the argument a typo would silently blank")
	_check(dd.card_subtype == "Mail", "…printed Armor - Mail")
	_check(dd.rarity == "Rare", "…Rare (blue set symbol, unlike the green Handguards)")
	for cls in ["Hunter", "Paladin", "Shaman", "Warrior"]:
		_check(dd.has_class(cls), "…legal for %s" % cls)
	for cls in ["Druid", "Mage", "Priest", "Rogue", "Warlock"]:
		_check(not dd.has_class(cls), "…NOT legal for %s" % cls)

	# Head vs Chest: Eye of Rend and the Breastplate are DIFFERENT slots, so a
	# board may run both and the two grants add. Pinned here because "the other
	# +ATK armor" is exactly the card someone would assume conflicts.
	var eye := db.get_def("azeroth_288") as CardDef
	if eye != null:
		var e_info: Dictionary = StackResolver._equipment_info(eye)
		_check(e_info.get("slot", "") != info.get("slot", ""),
			"…and Eye of Rend sits in a DIFFERENT slot, so the two coexist")
