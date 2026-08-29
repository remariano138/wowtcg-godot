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
	_test_ritual_sacrifice_recipe()
	_test_unpreventable_holy_recipes()
	_test_resurrection_recipe()
	_test_graccus_recipe()
	_test_hammer_of_justice_recipe()
	_test_holy_light_recipe()
	_test_healing_wave_recipe()
	_test_dismantle_recipe()
	_test_soul_link_count_power()

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
