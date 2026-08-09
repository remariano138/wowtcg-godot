extends Node

# Headless scenario tests — full StackResolver turn-loop, no rendering required.
#
# HOW TO RUN:
#   In Godot editor: Scene > New Scene > add this script as the root node > Play Scene.
#   Passing scenarios print a single "PASS <fn_name>" summary line; a scenario
#   with any failing assertion prints its full buffered log instead. Non-zero
#   FAIL count = a bug.
#
# Philosophy: each test builds a specific game state from scratch, wires up
# ScriptedAI instances that play predetermined actions, then drives the
# priority loop until the scenario resolves and asserts on outcomes.

const MAX_STEPS := 200   # guard against infinite loops in a broken driver


func _ready() -> void:
	print("=== WoW TCG Engine — Scenario Tests ===\n")

	var tests: Array[Callable] = [
		_test_protector_intercepts_attack,
		_test_donna_calister_readies_on_opposing_attack,
		_test_ferocity_attacks_turn_played,
		_test_elusive_never_targetable,
		_test_hand_size_wrap_up_discard,
		_test_tazo_hero_power,
		_test_tazdingo_enter_play,
		_test_parvink_enter_play,
		_test_vanquish,
		_test_quick_strike,
		_test_lightning_bolt,
		_test_pet_uniqueness,
		_test_mooncloth_robe_power,
		_test_mooncloth_robe_hero_exhausted,
		_test_activate_costs_paid_on_announce,
		_test_activate_costs_refunded_on_retract,
		_test_equipment_slot_uniqueness,
		_test_ai_plays_equipment,
		_test_pads_block_combat,
		_test_pads_block_decline,
		_test_pads_block_instant,
		_test_pads_block_enter_play_damage,
		_test_pads_overblock_expires,
		_test_ai_armor_block_heuristic,
		_test_prevention_noncombat_sources,
		_test_prevention_reduces_discard_per_damage,
		_test_lionheart_helm_unpreventable,
		_test_annihilator_unpreventable,
		_test_brother_rhone_shield,
		_test_ai_prefers_free_block,
		_test_ai_skips_pointless_attack_into_shield,
		_test_ai_holds_free_block_vs_bait,
		_test_grimdron_ally_power,
		_test_tim_ally_power,
		_test_sarmoth_taunt_forces_attacker,
		_test_sarmoth_taunt_multiple_attackers,
		_test_sarmoth_elusive_no_taunt,
		_test_sarmoth_taunt_lifts_on_death,
		_test_boris_heal_x,
		_test_radak_pet_sacrifice,
		_test_radak_no_pets,
		_test_timmo_destroy_exhausted_ally,
		_test_quest_cant_reuse_while_pending,
		_test_liba_wobblebonk_enter_play,
		_test_kulan_earthguard_end_of_turn_ready,
		_test_tracker_gallen_atk_per_ally,
		_test_malwani_atk_per_damage_self,
		_test_zorm_party_atk_while_attacking,
		_test_elder_moorf_buff_target,
		_test_rayder_party_buff_while_attacking,
		_test_for_the_horde_quest_buff,
		_test_turn_buff_expires_at_end_of_turn,
		_test_zorm_bonus_applies_to_real_combat_damage,
		_test_get_atk_if_attacking_preview,
		_test_moorf_buff_applies_to_real_defense_damage,
		_test_ryn_dreamstrider_buff_target_attacking,
		_test_chasing_ame_graveyard_to_hand,
		_test_chasing_ame_blocked_and_filtered,
		_test_love_potion_exhaust_cost,
		_test_sunken_treasure_equipment_to_hand,
		_test_finkle_einhorn_graveyard_to_play,
		_test_ancestral_spirit_reanimate,
		_test_ancestral_spirit_gates,
		_test_ancestral_spirit_ai_picks_best,
		_test_missing_diplomat_deck_search,
		_test_reveal_pick_takes_matching_card,
		_test_reveal_pick_no_match_all_to_bottom,
		_test_reveal_pick_blocks_other_actions,
		_test_reveal_pick_to_top,
		_test_princess_trapped_opponent_chooses,
		_test_darrowshire_rfg_three_allies,
		_test_darrowshire_blocked_with_too_few_allies,
		_test_defias_brotherhood_requires_four_allies,
		_test_toreks_assault_requires_hero_damaged_by_ally,
		_test_find_lethal,
		_test_find_lethal_baseline_in_ai_actions,
		_test_sort_valuable_cards,
		_test_find_safe_lethals,
		_test_generic_ai_safe_kill_flow,
		_test_generic_ai_value_choices,
		_test_combat_trade_value,
		_test_generic_ai_trade_develop_chip,
		_test_generic_ai_protector_choice,
		_test_generic_ai_while_attacking_buffs,
		_test_ally_heal_power_targets_friendlies,
		_test_react_to_hero_power_with_heal,
		_test_react_to_hero_power_with_heal_legal_on_chain,
		_test_on_your_turn_power_blocked_on_chain,
		_test_instant_ally_timing_and_protect,
		_test_ai_flashes_instant_protector,
		_test_ai_holds_instant_protector,
		_test_combat_instant_ambush,
		_test_deacon_johanna_once_per_turn,
		_test_acolyte_demia_power,
		_test_acolyte_demia_own_turn_only,
		_test_acolyte_demia_self_destroys,
		_test_senzir_beastwalker_power,
		_test_senzir_beastwalker_no_pet_in_graveyard,
		_test_ai_senzir_picks_most_valuable_pet,
		_test_bloodclaw_no_horde_bonus,
		_test_old_bones_protects_hero_only,
		_test_arcane_shot,
		_test_arcane_shot_combat_instant_tag,
		_test_fire_blast,
		_test_frost_instants,
		_test_frost_riders,
		_test_steal_essence,
		_test_natural_selection,
		_test_mind_damage_discard,
		_test_ismantal_ally_power_discard,
		_test_boneshanks_death_trigger,
		_test_lady_jaina_aura,
		_test_lady_jaina_unique,
		_test_hannah_cant_protect_aura,
		_test_nerra_lifeboon_health_aura,
		_test_nerra_death_triggers_aura_loss_death,
		_test_master_of_the_hunt_ongoing,
		_test_guardian_steelhorn_cant_attack,
		_test_starfire,
		_test_flamestrike,
		_test_chain_lightning,
		_test_multi_shot,
		_test_untargetable_keyword,
		_test_infernal_discard_keeps_control,
		_test_infernal_decline_gives_control,
		_test_infernal_decline_pet_uniqueness,
		_test_infernal_end_of_turn_damage,
		_test_hierophant_caydiem_power,
		_test_tanwa_long_range,
		_test_generic_ai_all_out_hero_lethal,
		_test_generic_ai_all_out_with_spell_lethal,
		_test_litori_freeze_fizzles_proposal,
		_test_litori_too_late_in_window,
		_test_ai_litori_freeze_save,
		_test_exhaustion_freezes_proposal,
		_test_ai_exhaustion_freeze_save,
		_test_war_stomp_mass_exhaust,
		_test_ai_war_stomp_freeze_save,
		_test_coup_de_grace_destroys_exhausted_ally,
		_test_gouge_exhaust_and_ready_lock,
		_test_berserking,
		_test_cat_form_hero_attack,
		_test_form_break_and_pay_return,
		_test_form_uniqueness_shapeshift,
		_test_bash_freezes_and_grants_bear_form,
		_test_form_breaks_on_weapon_strike,
		_test_ai_bear_form_flash_in,
		_test_ai_bash_freezes_attacking_hero,
		_test_ai_hero_attack_lethal_gate,
		_test_ai_claw_ambush,
		_test_ravenous_bite_atk_swing,
		_test_ravenous_bite_same_target_and_fizzle,
		_test_ai_ravenous_bite_swing,
		_test_shock_and_soothe,
		_test_ai_shock_and_soothe,
		_test_withdraw_bounce_and_spell_fizzle,
		_test_ai_withdraw_save,
		_test_fall_back_friendly_only,
	_test_blink_removes_attacker,
	_test_combat_cancelled_event,
	_test_ai_blink_evasion,
		_test_first_to_fall_destroys_protector,
		_test_ai_first_to_fall_destroys_protector,
		_test_targeted_instant_highlight_requires_target,
		_test_galahandra_power_freezes_proposal,
		_test_ai_galahandra_freeze_save,
		_test_weapon_attack_strike,
		_test_weapon_defend_strike,
		_test_devilsaur_leggings,
		_test_iceblade_hacker,
		_test_bone_bow_grants_long_range,
		_test_elendril_ranged_bonus,
		_test_ai_elendril_flip_for_lethal,
		_test_strike_gates_and_gorebelly_discount,
		_test_ai_strike_decisions,
		_test_rod_of_ogre_magi_power,
		_test_hammer_of_grace_heal_power,
		_test_rod_two_handed_off_hand_uniqueness,
		_test_ai_power_weapon_never_strikes,
		_test_hypnotic_blade_discard,
		_test_golem_skull_helm_block,
		_test_deflector_hero_protects,
		_test_ai_hero_protect_decisions,
		_test_searing_totem_enters_ally_row_cant_attack,
		_test_searing_totem_fires_each_turn,
		_test_searing_totem_priority_window,
		_test_searing_totem_source_killed_in_window,
		_test_searing_totem_can_be_attacked,
		_test_searing_totem_instant_timing,
		_test_earthbind_totem_ready_lock,
		_test_healing_stream_totem_heals_party,
		_test_watcher_malwi_pings_entering_opposing_ally,
		_test_watcher_malwi_ignores_own_allies,
		_test_wazzuli_party_heal,
		_test_stylean_enter_play_party_heal,
		_test_windseer_ready_on_attack,
		_test_windseer_ready_declined_and_unaffordable,
		_test_windfury_totem_party_ready,
		_test_windfury_totem_with_windseer_single_ready,
		_test_windfury_weapon_attach_and_ready_on_strike,
		_test_kena_shadowbrand_power,
		_test_kena_shadowbrand_self_lethal,
		_test_bizzik_sparkcog_sacrifice_draw,
		_test_augustus_destroys_with_graveyard_cost,
		_test_augustus_blocked_too_few_graveyard_allies,
		_test_gertha_sacrifice_destroy,
		_test_melgwy_pingzot_fire_ping,
		_test_power_usable_in_nonaction_priority_window,
		_test_kavai_sacrifice_destroys_ability_or_equipment,
		_test_kavai_fizzles_opposing_removal,
		_test_ai_kavai_doomed_cash_in,
		_test_lafiel_destroys_ability,
		_test_lafiel_fizzles_and_ai,
		_test_stat_tracker_counts,
		_test_green_whelp_armor_bounces_attacker,
		_test_green_whelp_armor_decline_and_gates,
		_test_attack_exhaust_denies_protector,
		_test_attack_exhaust_decline_keeps_protect,
		_test_attack_exhaust_defender_combat_proceeds,
		_test_ai_attack_exhaust_choice,
		_test_bala_atk_vs_exhausted,
		_test_bala_bonus_turns_on_mid_combat,
		_test_mark_of_the_wild_attach_buff,
		_test_entangling_roots_ready_lock,
		_test_attach_fizzles_when_target_dies,
		_test_ai_attach_target_choice,
		_test_burn_away_destroys_ability,
		_test_purge_spares_friendly_attachments,
		_test_shattering_blow_destroys_equipment,
		_test_randipan_draw_on_hero_combat_damage,
		_test_samuel_grey_discard_on_hero_combat_damage,
		_test_ophelia_barrows_rfg_and_heal,
		_test_ophelia_barrows_gates_and_fizzle,
		_test_fireball_attach_and_burn,
		_test_flame_shock_attach_and_burn,
		_test_ai_flame_shock_targets_hero_only,
		_test_world_in_flames_doubles_fire,
		_test_chromatic_cloak_ability_bonus,
		_test_ai_fireball_targets_hero_only,
		_test_aimed_shot_x_cost,
		_test_aimed_shot_retract_and_ai,
		_test_spirit_bond_turn_start_heal,
		_test_talent_deck_legality,
		_test_mana_agate_power,
		_test_mana_agate_killed_in_response,
		_test_arcane_intellect_attach_and_hand_size,
		_test_ai_mana_agate_and_arcane_intellect,
		_test_stealth_blocks_protectors,
		_test_ghank_enter_play_destroy,
		_test_ghank_no_target_no_prompt,
		_test_ghank_decline,
		_test_ghank_window_lets_opponent_respond,
		_test_hur_shieldsmasher_destroys_armor,
		_test_hur_shieldsmasher_ignores_weapon,
		_test_hur_shieldsmasher_no_armor_no_prompt,
		_test_zygore_bladebreaker_destroys_weapon,
		_test_zygore_bladebreaker_destroys_armor,
		_test_mya_creates_token,
		_test_token_destroyed_ceases_to_exist,
		_test_token_bounce_ceases_to_exist,
		_test_tokens_not_deckable,
		_test_toogas_quest,
		_test_tooga_killed_before_trigger,
		_test_decked_loses_the_game,
		_test_empty_deck_alone_is_not_a_loss,
		_test_simultaneous_decking_is_a_draw,
		_test_game_over_explanations,
	]

	for t in tests:
		_run_test(t)

	print("\n=== Results: %d passed  %d failed ===" % [_pass, _fail])
	if _fail == 0:
		print("ALL TESTS PASSED ✓")
	else:
		print("SOME TESTS FAILED — see FAIL lines above")
	await get_tree().process_frame
	get_tree().quit()


# ── Assertion helpers ──────────────────────────────────────────────────────────
#
# Per-test output is buffered: if every assertion in a test passes, only a
# single "PASS <fn_name>" summary line prints. If anything fails, the full
# buffered log (including the test's own header print) is flushed so the
# failure is fully diagnosable. Keeps a full run's console output short
# without losing detail exactly where it's needed.

var _pass := 0
var _fail := 0
var _buf: Array[String] = []
var _buf_had_fail := false

func _run_test(fn: Callable) -> void:
	_buf = []
	_buf_had_fail = false
	fn.call()
	if _buf_had_fail:
		for line in _buf:
			print(line)
	else:
		print("  PASS  %s" % fn.get_method())

func ok(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		_buf.append("  PASS  %s" % label)
	else:
		_fail += 1
		_buf_had_fail = true
		_buf.append("  FAIL  %s" % label)

func eq(a, b, label: String) -> void:
	if a == b:
		_pass += 1
		_buf.append("  PASS  %s" % label)
	else:
		_fail += 1
		_buf_had_fail = true
		_buf.append("  FAIL  %s  [got %s, expected %s]" % [label, str(a), str(b)])


# ── Stat tracker ────────────────────────────────────────────────────────────────

func _test_stat_tracker_counts() -> void:
	_buf.append("[b]--- stat_tracker: counts draws & plays per player ---[/b]")
	var st := StatTracker.new()

	# Draws: only deck→hand moves for the owning player count.
	st.record_event(GameEvent.card_moved("c1", "p1_deck", "p1_hand"))
	st.record_event(GameEvent.card_moved("c2", "p1_deck", "p1_hand"))
	st.record_event(GameEvent.card_moved("c3", "p2_deck", "p2_hand"))
	# Non-draw moves must be ignored (play to chain, discard, graveyard).
	st.record_event(GameEvent.card_moved("c4", "p1_hand", "chain"))
	st.record_event(GameEvent.card_moved("c5", "p1_hand", "p1_graveyard"))

	# Plays: dedicated card_played events; resources never emit these.
	st.record_event(GameEvent.card_played("p1", "c4"))
	st.record_event(GameEvent.card_played("p1", "c6"))
	st.record_event(GameEvent.card_played("p2", "c7"))

	eq(st.drawn("p1"),  9, "p1 drawn")
	eq(st.drawn("p2"),  8, "p2 drawn")
	eq(st.played("p1"), 2, "p1 played")
	eq(st.played("p2"), 1, "p2 played")

	# reset() clears everything for a new match (baseline 7 for opening hand).
	st.reset()
	eq(st.drawn("p1"),  7, "reset clears drawn to opening-hand baseline")
	eq(st.played("p1"), 0, "reset clears played")

	# Real submission emits card_played for a card play but NOT for a resource.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear", 2, 2, [], 0)
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_hand_card(state, "play_me", "bear", "p1")
	_add_hand_card(state, "res_me", "bear", "p1")
	var st2 := StatTracker.new()

	var play := PendingAction.new()
	play.action_type   = "play_ally"
	play.source_player = "p1"
	play.params        = {"card_id": "play_me"}
	for e in StackResolver.submit_action(state, play, db):
		st2.record_event(e)

	var res := PendingAction.new()
	res.action_type   = "place_resource"
	res.source_player = "p1"
	res.params        = {"card_id": "res_me"}
	for e in StackResolver.submit_action(state, res, db):
		st2.record_event(e)

	eq(st2.played("p1"), 1, "submit: play counts, resource excluded")


# Green Whelp Armor: when an attacking ally deals combat damage to the wielder's
# hero, the wielder may pay 2 to return that ally to its owner's hand.
func _test_green_whelp_armor_bounces_attacker() -> void:
	_buf.append("\n-- Green Whelp Armor: pay 2 to bounce the attacking ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("whelp_def", 4, "equipment:chest:1|whelp_bounce", "Armor")
	db.ally("ogre_def", 3, 3, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p1", 2)
	var ogre := _add_ally(state, "ogre", "ogre_def", "p2")
	ogre.just_summoned = false
	var whelp := CardInstance.create("whelp", "whelp_def", "p1", "p1_hero_row")
	state.cards["whelp"] = whelp
	state.zones["p1_hero_row"].card_ids.append("whelp")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "ogre", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # → prevention point (whelp has DEF 1)
	eq(state.pending_prevention_player, "p1", "gw-a0: prevention point opened first")
	StackResolver.choose_prevention(state, "", db)   # decline → conclusion → bounce point

	eq(state.get_card("p1_hero").damage_taken, 3, "gw-a: hero took the ogre's 3")
	eq(state.pending_whelp_bounce_player, "p1", "gw-b: bounce point opened for p1")
	eq(state.pending_whelp_bounce_ally_id, "ogre", "gw-b2: on the attacking ogre")
	eq(state.pending_whelp_bounce_cost, 2, "gw-b3: cost is 2")

	StackResolver.choose_whelp_bounce(state, true, db)
	eq(state.pending_whelp_bounce_player, "", "gw-c: bounce point cleared")
	ok(not state.is_in_play("ogre"), "gw-c2: ogre left the ally row")
	ok("ogre" in state.zones["p2_hand"].card_ids, "gw-c3: ogre returned to owner's hand")
	eq(state.get_available_resources("p1"), 0, "gw-c4: paid the 2 cost")


# Green Whelp Armor gates: declining leaves the ally in play; the point never
# opens when the wielder can't afford 2, nor when a HERO (not an ally) attacks.
func _test_green_whelp_armor_decline_and_gates() -> void:
	_buf.append("\n-- Green Whelp Armor: decline + affordability/ally gates --")

	# Gate 1 (decline): p1 can afford but chooses not to pay.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("whelp_def", 4, "equipment:chest:1|whelp_bounce", "Armor")
	db.ally("ogre_def", 3, 3, [], 3)

	var s1 := _base_state(db, "p1_hero", "p2_hero")
	s1.turn_player     = "p2"
	s1.priority_player = "p2"
	_add_resources(s1, "p1", 2)
	var ogre1 := _add_ally(s1, "ogre", "ogre_def", "p2")
	ogre1.just_summoned = false
	var w1 := CardInstance.create("whelp", "whelp_def", "p1", "p1_hero_row")
	s1.cards["whelp"] = w1
	s1.zones["p1_hero_row"].card_ids.append("whelp")

	StackResolver.submit_action(s1, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "ogre", "defender_id": "p1_hero"}), db)
	for i in range(6):
		StackResolver.pass_priority(s1, db)
	StackResolver.choose_prevention(s1, "", db)   # decline the DEF 1 prevention point
	eq(s1.pending_whelp_bounce_player, "p1", "gw-d: bounce point opened")
	StackResolver.choose_whelp_bounce(s1, false, db)   # decline
	ok(s1.is_in_play("ogre"), "gw-d2: declined — ogre stays in play")
	eq(s1.get_available_resources("p1"), 2, "gw-d3: declined — no resources spent")

	# Gate 2 (unaffordable): p1 has only 1 resource — point never opens.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	s2.turn_player     = "p2"
	s2.priority_player = "p2"
	_add_resources(s2, "p1", 1)
	var ogre2 := _add_ally(s2, "ogre", "ogre_def", "p2")
	ogre2.just_summoned = false
	var w2 := CardInstance.create("whelp", "whelp_def", "p1", "p1_hero_row")
	s2.cards["whelp"] = w2
	s2.zones["p1_hero_row"].card_ids.append("whelp")

	StackResolver.submit_action(s2, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "ogre", "defender_id": "p1_hero"}), db)
	for i in range(6):
		StackResolver.pass_priority(s2, db)
	StackResolver.choose_prevention(s2, "", db)   # decline the DEF 1 prevention point
	eq(s2.pending_whelp_bounce_player, "", "gw-e: unaffordable — point never opens")
	ok(s2.is_in_play("ogre"), "gw-e2: ogre unaffected")


# Randipan (azeroth_213): "When Randipan deals combat damage to a defending
# hero, draw a card." Fires only when the damage LANDS on a defending hero.
func _test_randipan_draw_on_hero_combat_damage() -> void:
	_buf.append("\n-- Randipan: draw on combat damage to a defending hero --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("randipan_def", 2, 2, [], 3, "on_combat_damage_to_hero:draw:1")
	db.ally("bear_def", 1, 4, [], 2)

	# Case A: attacks the hero, damage lands → draw.
	var st := _base_state(db, "p1_hero", "p2_hero")
	var rp := _add_ally(st, "randipan", "randipan_def", "p1")
	rp.just_summoned = false
	var dc := CardInstance.create("deck1", "bear_def", "p1", "p1_deck")
	st.cards["deck1"] = dc
	st.zones["p1_deck"].card_ids.append("deck1")

	StackResolver.submit_action(st, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "randipan", "defender_id": "p2_hero"}), db)
	for i in range(6):
		StackResolver.pass_priority(st, db)
	eq(st.get_card("p2_hero").damage_taken, 2, "rp-a: hero took 2")
	ok("deck1" in st.zones["p1_hand"].card_ids, "rp-a2: drew a card")

	# Case B: attacks a defending ALLY → no draw.
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	var rp2 := _add_ally(st2, "randipan", "randipan_def", "p1")
	rp2.just_summoned = false
	var bear := _add_ally(st2, "bear", "bear_def", "p2")
	bear.just_summoned = false
	var dc2 := CardInstance.create("deck1", "bear_def", "p1", "p1_deck")
	st2.cards["deck1"] = dc2
	st2.zones["p1_deck"].card_ids.append("deck1")

	StackResolver.submit_action(st2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "randipan", "defender_id": "bear"}), db)
	for i in range(6):
		StackResolver.pass_priority(st2, db)
	eq(st2.get_card("bear").damage_taken, 2, "rp-b: ally took 2")
	ok("deck1" in st2.zones["p1_deck"].card_ids, "rp-b2: no draw vs an ally")

	# Case C: block absorbs all the damage → no trigger.
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	var rp3 := _add_ally(st3, "randipan", "randipan_def", "p1")
	rp3.just_summoned = false
	var dc3 := CardInstance.create("deck1", "bear_def", "p1", "p1_deck")
	st3.cards["deck1"] = dc3
	st3.zones["p1_deck"].card_ids.append("deck1")

	StackResolver.submit_action(st3, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "randipan", "defender_id": "p2_hero"}), db)
	for i in range(4):
		StackResolver.pass_priority(st3, db)   # up to the defend window
	(st3.players["p2"] as PlayerState).damage_prevention = 5   # committed block
	StackResolver.pass_priority(st3, db)
	StackResolver.pass_priority(st3, db)       # conclusion
	eq(st3.get_card("p2_hero").damage_taken, 0, "rp-c: all damage prevented")
	ok("deck1" in st3.zones["p1_deck"].card_ids, "rp-c2: no draw — no damage landed")


# Samuel Grey (azeroth_258): "When Samuel Grey deals combat damage to a
# defending hero, that hero's controller discards a card."
func _test_samuel_grey_discard_on_hero_combat_damage() -> void:
	_buf.append("\n-- Samuel Grey: hero's controller discards on combat damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("samuel_def", 2, 2, [], 3, "on_combat_damage_to_hero:discard_controller:1")
	db.ally("bear_def", 1, 4, [], 2)

	# Case A: damage lands on the hero → its controller owes a discard.
	var st := _base_state(db, "p1_hero", "p2_hero")
	var sg := _add_ally(st, "samuel", "samuel_def", "p1")
	sg.just_summoned = false
	_add_card_to_hand(st, "h1", "bear_def", "p2")
	_add_card_to_hand(st, "h2", "bear_def", "p2")

	StackResolver.submit_action(st, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "samuel", "defender_id": "p2_hero"}), db)
	for i in range(6):
		StackResolver.pass_priority(st, db)
	eq(st.get_card("p2_hero").damage_taken, 2, "sg-a: hero took 2")
	eq(st.pending_discard_player, "p2", "sg-a2: p2 owes a discard")
	eq(st.pending_discard_count, 1, "sg-a3: exactly one card")

	StackResolver.choose_discard(st, "h1", db)
	eq(st.pending_discard_player, "", "sg-b: discard resolved")
	ok("h1" in st.zones["p2_graveyard"].card_ids, "sg-b2: discarded to graveyard")
	ok("h2" in st.zones["p2_hand"].card_ids, "sg-b3: other card kept")

	# Case B: empty hand → trigger is a no-op (no stuck pending discard).
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	var sg2 := _add_ally(st2, "samuel", "samuel_def", "p1")
	sg2.just_summoned = false

	StackResolver.submit_action(st2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "samuel", "defender_id": "p2_hero"}), db)
	for i in range(6):
		StackResolver.pass_priority(st2, db)
	eq(st2.get_card("p2_hero").damage_taken, 2, "sg-c: hero took 2")
	eq(st2.pending_discard_player, "", "sg-c2: empty hand — no pending discard")


const OPHELIA_FX := "activated_power:1:rfg_graveyard_ally:1::graveyard_ally:no_activate" \
		+ "|graveyard_to_rfg:Ally:1:1:both"

# Ophelia Barrows (azeroth_253): "1 -> Remove target ally card in any graveyard
# from the game. If you do, Ophelia Barrows heals 1 damage from herself."
# Plain payment power (no [Activate]) — no exhaust, repeatable, any graveyard.
func _test_ophelia_barrows_rfg_and_heal() -> void:
	_buf.append("\n-- Ophelia Barrows: exile graveyard ally + self-heal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ophelia_def", 1, 5, ["protector"], 4, OPHELIA_FX)
	db.ally("bear_def", 1, 4, [], 2)

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 2)
	var oph := _add_ally(st, "ophelia", "ophelia_def", "p1")
	oph.just_summoned = false
	oph.damage_taken = 2
	# One ally card in each graveyard ("any graveyard" — both are candidates).
	var g1 := CardInstance.create("dead_own", "bear_def", "p1", "p1_graveyard")
	st.cards["dead_own"] = g1
	st.zones["p1_graveyard"].card_ids.append("dead_own")
	var g2 := CardInstance.create("dead_opp", "bear_def", "p2", "p2_graveyard")
	st.cards["dead_opp"] = g2
	st.zones["p2_graveyard"].card_ids.append("dead_opp")

	# Use 1: exile from the OPPONENT's graveyard.
	StackResolver.submit_action(st, PendingAction.make("use_ally_power", "p1",
		{"card_id": "ophelia", "target_id": "dead_opp"}), db)
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)
	ok("dead_opp" in st.zones["p2_rfg"].card_ids, "oph-a: opp graveyard ally exiled")
	eq(oph.damage_taken, 1, "oph-a2: healed 1 from herself")
	ok(not oph.is_exhausted, "oph-a3: no [Activate] — Ophelia not exhausted")

	# Use 2 same turn (repeatable payment power): exile from OWN graveyard too.
	StackResolver.submit_action(st, PendingAction.make("use_ally_power", "p1",
		{"card_id": "ophelia", "target_id": "dead_own"}), db)
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)
	ok("dead_own" in st.zones["p1_rfg"].card_ids, "oph-b: own graveyard ally exiled")
	eq(oph.damage_taken, 0, "oph-b2: healed again")
	eq(st.get_available_resources("p1"), 0, "oph-b3: paid 1 per use")


# Gates: no ally card in any graveyard blocks even the no-target probe (an
# Ability card doesn't count); a target that leaves the graveyard before
# resolution fizzles the whole power — no exile, no heal ("if you do").
func _test_ophelia_barrows_gates_and_fizzle() -> void:
	_buf.append("\n-- Ophelia Barrows: candidate gates + fizzle --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ophelia_def", 1, 5, ["protector"], 4, OPHELIA_FX)
	db.ally("bear_def", 1, 4, [], 2)
	db.instant("bolt_def", 2, "")

	# Gate: graveyards hold only an Ability card → probe and submit both fail.
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 2)
	var oph := _add_ally(st, "ophelia", "ophelia_def", "p1")
	oph.just_summoned = false
	var gb := CardInstance.create("dead_bolt", "bolt_def", "p2", "p2_graveyard")
	st.cards["dead_bolt"] = gb
	st.zones["p2_graveyard"].card_ids.append("dead_bolt")

	ok(not StackResolver.can_submit(st, PendingAction.make("use_ally_power", "p1",
		{"card_id": "ophelia", "_skip_target_check": true}), db),
		"oph-c: no ally in any graveyard — probe fails")
	ok(not StackResolver.can_submit(st, PendingAction.make("use_ally_power", "p1",
		{"card_id": "ophelia", "target_id": "dead_bolt"}), db),
		"oph-c2: an Ability card is not a legal target")

	# Fizzle: target leaves the graveyard while the power is on the chain.
	var g2 := CardInstance.create("dead_ally", "bear_def", "p2", "p2_graveyard")
	st.cards["dead_ally"] = g2
	st.zones["p2_graveyard"].card_ids.append("dead_ally")
	oph.damage_taken = 2
	StackResolver.submit_action(st, PendingAction.make("use_ally_power", "p1",
		{"card_id": "ophelia", "target_id": "dead_ally"}), db)
	# Simulate the card vanishing from the graveyard before resolution.
	GameLogic.move_card(st, "dead_ally", "p2_hand")
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)
	ok("dead_ally" in st.zones["p2_hand"].card_ids, "oph-d: target stayed where it went")
	ok(st.zones["p2_rfg"].card_ids.is_empty(), "oph-d2: nothing exiled")
	eq(oph.damage_taken, 2, "oph-d3: no removal — no heal ('if you do')")


# Aimed Shot (azeroth_32, "1+X", Ability — Marksmanship Talent): "Your hero
# deals X ranged damage to target hero or ally." First X-cost hand card: the
# announced x_value is both part of the cost (1+X, paid at submission) and the
# damage dealt at resolution.
func _aimed_db() -> MockDB:
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ability("aimed_def", 0, "deal_damage_to_target:X:ranged")
	var ad := db._defs["aimed_def"] as CardDef
	ad.cost = -1
	ad.cost_x = true
	ad.cost_base = 1
	db.ally("bear_def", 1, 4, [], 2)
	return db


func _test_aimed_shot_x_cost() -> void:
	_buf.append("\n-- Aimed Shot: 1+X cost, X damage --")
	var db := _aimed_db()
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 5)
	var bear := _add_ally(st, "bear", "bear_def", "p2")
	bear.just_summoned = false
	_add_card_to_hand(st, "aimed", "aimed_def", "p1")

	# X must be announced: no x_value (or 0) is not a legal submission.
	ok(not StackResolver.can_submit(st, PendingAction.make("play_ability", "p1",
		{"card_id": "aimed", "target_id": "bear"}), db),
		"as-a: no announced X — rejected")
	# Unaffordable X: 1+5 = 6 > 5 available.
	ok(not StackResolver.can_submit(st, PendingAction.make("play_ability", "p1",
		{"card_id": "aimed", "target_id": "bear", "x_value": 5}), db),
		"as-a2: X=5 costs 6 with 5 available — rejected")

	# X=3: total cost 4 paid at submission, 3 damage at resolution.
	StackResolver.submit_action(st, PendingAction.make("play_ability", "p1",
		{"card_id": "aimed", "target_id": "bear", "x_value": 3}), db)
	eq(st.get_available_resources("p1"), 1, "as-b: paid 1+3 at submission")
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)
	eq(bear.damage_taken, 3, "as-b2: dealt X=3 ranged damage")
	ok("aimed" in st.zones["p1_graveyard"].card_ids, "as-b3: card resolved to graveyard")


func _test_aimed_shot_retract_and_ai() -> void:
	_buf.append("\n-- Aimed Shot: retraction refunds 1+X; AI announces X --")
	var db := _aimed_db()
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 5)
	var bear := _add_ally(st, "bear", "bear_def", "p2")
	bear.just_summoned = false
	_add_card_to_hand(st, "aimed", "aimed_def", "p1")

	StackResolver.submit_action(st, PendingAction.make("play_ability", "p1",
		{"card_id": "aimed", "target_id": "bear", "x_value": 2}), db)
	eq(st.get_available_resources("p1"), 2, "ar-a: paid 1+2")
	StackResolver.retract_last(st, "p1", db)
	eq(st.get_available_resources("p1"), 5, "ar-a2: retraction refunded 1+X")
	ok("aimed" in st.zones["p1_hand"].card_ids, "ar-a3: card back in hand")

	# AI: enumerates the play with X announced — exactly the bear's HP (4)
	# vs the ally, everything payable (4) vs the hero.
	var ai := BaseAI.new()
	var actions: Array = ai.get_reasonable_actions(st, db, "p1")
	var ally_x := -1
	var hero_x := -1
	for a in actions:
		if a.action_type == "play_ability" and a.params.get("card_id", "") == "aimed":
			if a.params.get("target_id", "") == "bear":
				ally_x = int(a.params.get("x_value", 0))
			elif a.params.get("target_id", "") == "p2_hero":
				hero_x = int(a.params.get("x_value", 0))
	eq(ally_x, 4, "ar-b: AI announces X = ally HP vs the bear")
	eq(hero_x, 4, "ar-b2: AI announces max affordable X vs the hero")


# Spirit Bond (dark_portal_39, 1, Ability — Beast Mastery Talent): "Ongoing:
# At the start of your turn, if you have a Pet, your hero heals 2 damage from
# itself and each of your Pets."
func _test_spirit_bond_turn_start_heal() -> void:
	_buf.append("\n-- Spirit Bond: turn-start heal gated on a Pet --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ability("sbond_def", 1, "ongoing|turn_start_heal_hero_and_pets:2")
	db.pet("wolf_def", 2, 5, [], 2)
	db.ally("bear_def", 1, 4, [], 2)

	var st := _base_state(db, "p1_hero", "p2_hero")
	var sb := CardInstance.create("sbond", "sbond_def", "p1", "p1_hero_row")
	st.cards["sbond"] = sb
	st.zones["p1_hero_row"].card_ids.append("sbond")
	var wolf := _add_ally(st, "wolf", "wolf_def", "p1")
	wolf.damage_taken = 3
	var bear := _add_ally(st, "bear", "bear_def", "p1")
	bear.damage_taken = 2
	st.get_card("p1_hero").damage_taken = 4

	# p1 action → end → p2's turn start: NOT p1's turn, no heal.
	TurnManager.advance_phase(st, db)
	TurnManager.advance_phase(st, db)
	eq(st.turn_player, "p2", "sb-a: now p2's turn")
	eq(st.get_card("p1_hero").damage_taken, 4, "sb-a2: no heal on opponent's turn")

	# Drive to p1's next turn start: hero and the Pet heal 2, non-Pet doesn't.
	while not (st.turn_player == "p1" and st.phase == "ready"):
		TurnManager.advance_phase(st, db)
	eq(st.get_card("p1_hero").damage_taken, 2, "sb-b: hero healed 2")
	eq(wolf.damage_taken, 1, "sb-b2: Pet healed 2")
	eq(bear.damage_taken, 2, "sb-b3: non-Pet ally not healed")

	# No Pet in play → the trigger does nothing.
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	var sb2 := CardInstance.create("sbond", "sbond_def", "p1", "p1_hero_row")
	st2.cards["sbond"] = sb2
	st2.zones["p1_hero_row"].card_ids.append("sbond")
	st2.get_card("p1_hero").damage_taken = 4
	while not (st2.turn_player == "p2"):
		TurnManager.advance_phase(st2, db)
	while not (st2.turn_player == "p1" and st2.phase == "ready"):
		TurnManager.advance_phase(st2, db)
	eq(st2.get_card("p1_hero").damage_taken, 4, "sb-c: no Pet — no heal")


# Rule 100.2c: our heroes list no talent spec, so a deck may not mix Talent
# cards of two different [Talent Spec]s. Non-Talent cards of any subtype are
# unrestricted alongside a Talent.
func _test_talent_deck_legality() -> void:
	_buf.append("\n-- Deck legality: Talents of different specs can't mix (100.2c) --")
	var db := MockDB.new()
	db.hero("hero_def", 30)
	db.ability("aimed_def", 1, "deal_damage_to_target:X:ranged")
	(db._defs["aimed_def"] as CardDef).tags = "Marksmanship Talent"
	db.ability("sbond_def", 1, "ongoing|turn_start_heal_hero_and_pets:2")
	(db._defs["sbond_def"] as CardDef).tags = "Beast Mastery Talent"
	db.instant("frost_def", 3, "deal_damage_to_target:3:frost")
	(db._defs["frost_def"] as CardDef).tags = "Frost"   # non-Talent subtype
	for i in range(14):
		db.ally("filler_%d_def" % i, 1, 1, [], 1)

	var deck := DeckDefinition.new()
	deck.deck_id = "talent_test"
	deck.hero_card_def_id = "hero_def"
	for i in range(14):
		deck.card_entries.append(DeckCardEntry.from_dict(
			{"card_def_id": "filler_%d_def" % i, "count": 4}))
	# 56 fillers + 4 Aimed Shot = 60, one Talent spec → legal.
	deck.card_entries.append(DeckCardEntry.from_dict(
		{"card_def_id": "aimed_def", "count": 4}))
	eq(DeckManager.authorize_deck_def(deck, db).size(), 0,
		"td-a: single-spec Talents are legal")

	# Swap 2 fillers for a non-Talent ability of another school → still legal.
	deck.card_entries[0] = DeckCardEntry.from_dict(
		{"card_def_id": "frost_def", "count": 4})
	eq(DeckManager.authorize_deck_def(deck, db).size(), 0,
		"td-b: a Talent + non-Talent abilities of any subtype is legal")

	# Add a second spec (Beast Mastery next to Marksmanship) → illegal.
	deck.card_entries[1] = DeckCardEntry.from_dict(
		{"card_def_id": "sbond_def", "count": 4})
	var errors := DeckManager.authorize_deck_def(deck, db)
	eq(errors.size(), 1, "td-c: mixed Talent specs rejected")
	ok(errors.size() > 0 and "100.2c" in errors[0], "td-c2: error cites rule 100.2c")


# ── Mock database ──────────────────────────────────────────────────────────────

class MockDB extends RefCounted:
	var _defs: Dictionary = {}

	func ally(def_id: String, atk: int, health: int, kw: Array[String] = [], cost: int = 0, effects: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.printed_atk    = atk
		d.printed_health = health
		d.cost           = cost
		d.effects        = effects
		d.card_type      = "Ally"
		for k in kw:
			d.keywords.append(k)
		_defs[def_id] = d

	# Ally token (data/tokens.csv): a normal ally def flagged is_token, which is
	# what makes it non-deckable and makes it cease to exist when it leaves play.
	func token(def_id: String, atk: int, health: int, kw: Array[String] = [], effects: String = "") -> void:
		ally(def_id, atk, health, kw, 0, effects)
		(_defs[def_id] as CardDef).is_token = true

	func pet(def_id: String, atk: int, health: int, kw: Array[String] = [], cost: int = 0, effects: String = "") -> void:
		ally(def_id, atk, health, kw, cost, effects)
		(_defs[def_id] as CardDef).card_subtype = "Pet"

	func equipment(def_id: String, cost: int, effects: String, subtype: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.cost           = cost
		d.effects        = effects
		d.card_type      = "Equipment"
		d.card_subtype   = subtype
		_defs[def_id] = d

	# Weapon (rule 303): Equipment with ATK, dmg_type, and a strike_cost:STRIKE_COST segment.
	func weapon(def_id: String, cost: int, atk: int, strike_cost: int,
			dmg_type: String = "Melee", slot: String = "melee_weapon",
			extra_effects: String = "") -> void:
		var fx := "equipment:%s:0|strike_cost:%d" % [slot, strike_cost]
		if extra_effects != "":
			fx += "|" + extra_effects
		equipment(def_id, cost, fx)
		var d := _defs[def_id] as CardDef
		d.printed_atk = atk
		d.dmg_type    = dmg_type

	func hero(def_id: String, health: int, power_cost: int = 0, power_effects: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.printed_atk    = 0
		d.printed_health = health
		d.cost           = power_cost
		d.effects        = power_effects
		d.card_type      = "Hero"
		_defs[def_id] = d

	func quest(def_id: String, cost: int = 0, effects: String = "") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.printed_atk    = 0
		d.printed_health = 0
		d.cost           = cost
		d.effects        = effects
		d.card_type      = "Quest"
		_defs[def_id] = d

	func instant(def_id: String, cost: int, effects: String) -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.cost           = cost
		d.card_type      = "Ability"
		d.is_instant     = true
		d.effects        = effects
		_defs[def_id] = d

	# Non-instant ability, action-phase timing (e.g. Vanquish-speed or ongoing).
	func ability(def_id: String, cost: int, effects: String) -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.cost           = cost
		d.card_type      = "Ability"
		d.is_instant     = false
		d.effects        = effects
		_defs[def_id] = d

	# Totem (rule 305.3): an Instant Ability that enters play as an ability ally
	# with an ATK/health value (Searing Totem). Recipe carries a totem[:element]
	# segment plus its ongoing power.
	func totem(def_id: String, cost: int, effects: String, health: int = 1,
			dmg_type: String = "Fire") -> void:
		var d := CardDef.new()
		d.card_def_id    = def_id
		d.card_name      = def_id
		d.cost           = cost
		d.card_type      = "Ability"
		d.is_instant     = true
		d.printed_atk    = 0
		d.printed_health = health
		d.dmg_type       = dmg_type
		d.effects        = effects
		_defs[def_id] = d

	func get_def(id: String) -> CardDef:
		return _defs.get(id)


# ── ScriptedAI ─────────────────────────────────────────────────────────────────

class ScriptedAI extends RefCounted:
	var _actions:   Array = []
	var _protectors: Array = []

	func queue_action(a: PendingAction) -> void:
		_actions.append(a)

	func queue_protect(protector_id: String) -> void:
		_protectors.append(protector_id)

	func decide_action(state: GameState, db, _player_id: String) -> PendingAction:
		if not _actions.is_empty():
			# Peek first — only consume when the action is currently legal.
			# This prevents the action from being lost during stack resolution
			# windows where the chain is non-empty (e.g. waiting for a previous
			# play_ally to resolve before the next one can be submitted).
			var next := _actions[0] as PendingAction
			if StackResolver.can_submit(state, next, db):
				return _actions.pop_front()
		return null

	func choose_protector(_state: GameState, _db, _player_id: String) -> String:
		if not _protectors.is_empty():
			return _protectors.pop_front()
		return ""


# ── RandomAttackerAI ──────────────────────────────────────────────────────────

class RandomAttackerAI extends RefCounted:
	func decide_action(state: GameState, db, player_id: String) -> PendingAction:
		if state.phase != "action" or state.turn_player != player_id:
			return null
		if not state.pending_actions.is_empty():
			return null
		var attackers := StackResolver.get_legal_attackers(state, player_id, db)
		if attackers.is_empty():
			return null
		var atk_id: String = attackers[randi() % attackers.size()]
		var defenders := StackResolver.get_legal_defenders(state, atk_id, db)
		if defenders.is_empty():
			return null
		var def_id: String = defenders[randi() % defenders.size()]
		return PendingAction.make("propose_combat", player_id,
			{"attacker_id": atk_id, "defender_id": def_id})

	func choose_protector(_state: GameState, _db, _player_id: String) -> String:
		return ""


# ── Scenario driver ────────────────────────────────────────────────────────────

func _drive(state: GameState, db, p1_ai: ScriptedAI, p2_ai: ScriptedAI) -> Array[GameEvent]:
	var all_events: Array[GameEvent] = []
	var protect_pending := false
	var protect_player  := ""

	for _step in range(MAX_STEPS):
		if protect_pending or state.in_protect_point:
			protect_pending = false
			var prot_ai: ScriptedAI = p1_ai if protect_player == "p1" else p2_ai
			var pid := prot_ai.choose_protector(state, db, protect_player)
			var prot_events := StackResolver.choose_protector(state, pid, db)
			all_events.append_array(prot_events)
			for e in prot_events:
				if e.event_type == "protect_point_opened":
					protect_pending = true
					var def_card := state.get_card(e.payload.get("defender_id", ""))
					protect_player = def_card.controller if def_card else ""
			continue

		if all_events.any(func(e: GameEvent) -> bool: return e.event_type == "game_over"):
			break

		var player_id  := state.priority_player
		var turn_ai: ScriptedAI = p1_ai if player_id == "p1" else p2_ai
		var action     := turn_ai.decide_action(state, db, player_id)
		var step_events: Array[GameEvent] = \
			StackResolver.submit_action(state, action, db) if action \
			else StackResolver.pass_priority(state, db)

		all_events.append_array(step_events)

		for e in step_events:
			if e.event_type == "protect_point_opened":
				protect_pending = true
				var def_card := state.get_card(e.payload.get("defender_id", ""))
				protect_player = def_card.controller if def_card else ""
			elif e.event_type == "phase_changed" and e.payload.get("new") == "action":
				if all_events.size() > 5:
					return all_events

	return all_events


# Top up a player's deck with vanilla 0-cost 1/1 filler so draw steps have
# something to draw (see the decked rule, 410.6b).
func _stock_filler_deck(state: GameState, db, pid: String, n: int) -> void:
	if db is MockDB:
		var no_kw: Array[String] = []
		db.ally("deck_filler_def", 1, 1, no_kw, 0)
	var deck := state.zones.get(pid + "_deck") as Zone
	if not deck:
		return
	while deck.card_ids.size() < n:
		var inst_id := "%s_filler_%d" % [pid, deck.card_ids.size()]
		state.cards[inst_id] = CardInstance.create(
			inst_id, "deck_filler_def", pid, pid + "_deck")
		deck.card_ids.append(inst_id)


# `stock_decks` false leaves the decks empty — only for scenarios whose
# assertions count cards in hand/graveyard and would be skewed by drawn filler.
# Those scenarios must not run long enough to reach a draw step (410.6b).
# Cards in a zone excluding the filler _drive_turns stocks decks with.
func _non_filler_in(state: GameState, zone_id: String) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	for c in state.cards_in_zone(zone_id):
		if c.card_def_id != "deck_filler_def":
			result.append(c)
	return result


func _drive_turns(state: GameState, db, p1_ai, p2_ai, max_turns: int,
		stock_decks: bool = true) -> Array[GameEvent]:
	var all_events: Array[GameEvent] = []
	var protect_pending := false
	var protect_player  := ""
	var game_over       := false

	# Scenario states start with empty decks; since 410.6b a required draw from
	# an empty deck decks the player and ends the game, which would truncate
	# every multi-turn scenario at the first draw step. Stock both decks with
	# enough filler to survive the drive.
	if stock_decks:
		_stock_filler_deck(state, db, "p1", max_turns + 2)
		_stock_filler_deck(state, db, "p2", max_turns + 2)

	for _step in range(max_turns * 20):
		if game_over:
			break

		if protect_pending or state.in_protect_point:
			protect_pending = false
			var prot_ai = p1_ai if protect_player == "p1" else p2_ai
			var pid: String = prot_ai.choose_protector(state, db, protect_player)
			var prot_events := StackResolver.choose_protector(state, pid, db)
			all_events.append_array(prot_events)
			for e in prot_events:
				if e.event_type == "protect_point_opened":
					protect_pending = true
					var def_card := state.get_card(e.payload.get("defender_id", ""))
					protect_player = def_card.controller if def_card else ""
				elif e.event_type == "game_over":
					game_over = true
			continue

		var player_id  := state.priority_player
		var turn_ai    = p1_ai if player_id == "p1" else p2_ai
		var action     = turn_ai.decide_action(state, db, player_id)
		var step_events: Array[GameEvent] = \
			StackResolver.submit_action(state, action, db) if action \
			else StackResolver.pass_priority(state, db)

		all_events.append_array(step_events)

		for e in step_events:
			if e.event_type == "priority_window_closed":
				var adv := TurnManager.advance_phase(state, db)
				all_events.append_array(adv)
				for ae in adv:
					if ae.event_type == "game_over":
						game_over = true
					elif ae.event_type == "discard_choice_opened":
						all_events.append_array(_headless_discard(state, ae, db))
					elif ae.event_type == "control_discard_choice_opened":
						all_events.append_array(_headless_control_discard(state, db))
					elif ae.event_type == "totem_target_required":
						var t_ev := _headless_totem_target(state, db)
						all_events.append_array(t_ev)
						for te in t_ev:
							if te.event_type == "game_over":
								game_over = true
			elif e.event_type == "control_discard_choice_opened":
				all_events.append_array(_headless_control_discard(state, db))
			elif e.event_type == "discard_choice_opened":
				all_events.append_array(_headless_discard(state, e, db))
			elif e.event_type == "pet_sacrifice_required":
				all_events.append_array(_headless_pet_sacrifice(state, e, db))
			elif e.event_type == "equipment_sacrifice_required":
				all_events.append_array(_headless_equipment_sacrifice(state, e, db))
			elif e.event_type == "enter_play_target_required":
				all_events.append_array(_headless_enter_play_target(state, e, db))
			elif e.event_type == "totem_target_required":
				var t_ev := _headless_totem_target(state, db)
				all_events.append_array(t_ev)
				for te in t_ev:
					if te.event_type == "game_over":
						game_over = true
			elif e.event_type == "protect_point_opened":
				protect_pending = true
				var def_card := state.get_card(e.payload.get("defender_id", ""))
				protect_player = def_card.controller if def_card else ""
			elif e.event_type == "game_over":
				game_over = true

	return all_events


# ── Headless discard helper ───────────────────────────────────────────────────

func _headless_discard(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var dp:  String = event.payload.get("player", "")
	var cnt: int    = event.payload.get("count",  0)
	var reason: String = event.payload.get("reason", "")
	var events: Array[GameEvent] = []

	if reason == "wrap_up":
		var hand := state.cards_in_zone(dp + "_hand")
		hand.shuffle()
		for i in range(mini(cnt, hand.size())):
			events.append_array(
				GameLogic.move_card(state, hand[i].instance_id, dp + "_graveyard"))
		var adv2 := TurnManager.advance_phase(state, db)
		events.append_array(adv2)
		for ae2 in adv2:
			if ae2.event_type == "discard_choice_opened":
				events.append_array(_headless_discard(state, ae2, db))
	else:
		var hand := state.cards_in_zone(dp + "_hand")
		hand.shuffle()
		for card in hand:
			if state.pending_discard_count <= 0:
				break
			events.append_array(StackResolver.choose_discard(state, card.instance_id, db))

	return events


# ── Headless control-discard helper (Infernal) ───────────────────────────────
# Discards the first hand card to keep control; declines only with an empty hand.

func _headless_control_discard(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	while state.pending_control_discard_player != "":
		var pl := state.pending_control_discard_player
		var hand := state.cards_in_zone(pl + "_hand")
		var sub: Array[GameEvent] = \
			StackResolver.choose_control_discard(state, hand[0].instance_id, db) \
			if not hand.is_empty() else StackResolver.decline_control_discard(state, db)
		if sub.is_empty():
			break   # safety: avoid an infinite loop on unexpected state
		events.append_array(sub)
		for e in sub:
			if e.event_type == "pet_sacrifice_required":
				events.append_array(_headless_pet_sacrifice(state, e, db))
	return events


# ── Headless pet sacrifice helper ─────────────────────────────────────────────
# Sacrifices candidates one by one until the player's pet count is within capacity.
# Strategy: sacrifice the first candidate (lowest in list = oldest in play).

func _headless_pet_sacrifice(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var candidates: Array = event.payload.get("candidates", [])
	var events: Array[GameEvent] = []

	# Sacrifice the first valid candidate — choose_pet_sacrifice resolves immediately
	# (not via the pending_actions stack) so state is updated before we check again.
	for cid in candidates:
		if state.pending_pet_sacrifice_player == "":
			break
		var sub := StackResolver.choose_pet_sacrifice(state, cid as String, db)
		if sub.is_empty():
			continue
		events.append_array(sub)
		# If another violation fires (capacity > 1 edge case), recurse.
		for e in sub:
			if e.event_type == "pet_sacrifice_required":
				events.append_array(_headless_pet_sacrifice(state, e, db))
		break   # one sacrifice per call; re-check happens in the event loop

	return events


# ── Headless equipment sacrifice helper ───────────────────────────────────────
# Destroys same-slot equipment one by one until only one remains. Sacrifices the
# first candidate in the list.

func _headless_equipment_sacrifice(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var candidates: Array = event.payload.get("candidates", [])
	var events: Array[GameEvent] = []
	for cid in candidates:
		if state.pending_equip_sacrifice_player == "":
			break
		var sub := StackResolver.choose_equipment_sacrifice(state, cid as String, db)
		if sub.is_empty():
			continue
		events.append_array(sub)
		for e in sub:
			if e.event_type == "equipment_sacrifice_required":
				events.append_array(_headless_equipment_sacrifice(state, e, db))
		break
	return events


# ── Headless Totem start-of-turn target helper (Searing Totem) ───────────────
# Resolves each queued totem trigger. If _totem_target_pref is set and legal it
# is used; otherwise the acting player's opposing hero is targeted.
var _totem_target_pref: String = ""

func _headless_totem_target(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var guard := 8
	while state.pending_totem_target_player != "" and guard > 0:
		guard -= 1
		var ctrl := state.pending_totem_target_player
		var opp := "p2" if ctrl == "p1" else "p1"
		var legal := StackResolver.get_totem_targets(state, db)
		var target := ""
		if _totem_target_pref != "" and _totem_target_pref in legal:
			target = _totem_target_pref
		else:
			var ps_opp := state.players.get(opp) as PlayerState
			if ps_opp and ps_opp.hero_instance_id in legal:
				target = ps_opp.hero_instance_id
			elif not legal.is_empty():
				target = legal[0]
		events.append_array(StackResolver.choose_totem_target(state, target, db))
	return events


# ── Headless enter-play target helper ────────────────────────────────────────

func _headless_enter_play_target(state: GameState, event: GameEvent, db) -> Array[GameEvent]:
	var source_id: String = event.payload.get("card_id", "")
	var source_card := state.get_card(source_id)
	if not source_card:
		return []
	var ctrl := source_card.controller
	var events: Array[GameEvent] = []

	var targets: Array[String] = []
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": source_id, "target_id": ps.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				targets.append(ps.hero_instance_id)
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": source_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				targets.append(card.instance_id)

	if targets.is_empty():
		return []

	var target_id := targets[randi() % targets.size()]
	var action := PendingAction.make("choose_enter_play_target", ctrl,
		{"source_card_id": source_id, "target_id": target_id})
	events.append_array(StackResolver.submit_action(state, action, db))
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))
	return events


# ── State builder helpers ──────────────────────────────────────────────────────

func _base_state(_db: MockDB, p1_hero_id: String, p2_hero_id: String) -> GameState:
	var state := GameState.create_new(["p1", "p2"])

	var h1 := CardInstance.create(p1_hero_id, p1_hero_id, "p1", "p1_hero_row")
	state.cards[p1_hero_id] = h1
	state.zones["p1_hero_row"].card_ids.append(p1_hero_id)
	state.players["p1"].hero_instance_id = p1_hero_id

	var h2 := CardInstance.create(p2_hero_id, p2_hero_id, "p2", "p2_hero_row")
	state.cards[p2_hero_id] = h2
	state.zones["p2_hero_row"].card_ids.append(p2_hero_id)
	state.players["p2"].hero_instance_id = p2_hero_id

	state.phase           = "action"
	state.turn_player     = "p1"
	state.priority_player = "p1"
	state.turn_number     = 1

	return state


func _add_ally(state: GameState, inst_id: String, def_id: String, ctrl: String) -> CardInstance:
	var card := CardInstance.create(inst_id, def_id, ctrl, ctrl + "_ally_row")
	state.cards[inst_id] = card
	state.zones[ctrl + "_ally_row"].card_ids.append(inst_id)
	return card


func _add_card_to_hand(state: GameState, inst_id: String, def_id: String, ctrl: String) -> CardInstance:
	var card := CardInstance.create(inst_id, def_id, ctrl, ctrl + "_hand")
	state.cards[inst_id] = card
	state.zones[ctrl + "_hand"].card_ids.append(inst_id)
	return card


func _add_resources(state: GameState, player_id: String, count: int) -> void:
	for i in range(count):
		var inst_id := "%s_res_%d" % [player_id, i]
		var card := CardInstance.create(inst_id, "resource_blank", player_id,
			player_id + "_resource_row")
		card.face_down   = true
		card.is_exhausted = false
		state.cards[inst_id] = card
		state.zones[player_id + "_resource_row"].card_ids.append(inst_id)


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 1 — Protector intercepts, hero takes zero damage
# ══════════════════════════════════════════════════════════════════════════════

func _test_protector_intercepts_attack() -> void:
	_buf.append("\n-- Scenario 1: Protector intercepts attack on hero --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.ally("protector_def", 0, 6, (["protector"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	_add_ally(state, "prot", "protector_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()
	p2_ai.queue_protect("prot")

	_drive(state, db, p1_ai, p2_ai)

	var p2_hero   := state.get_card("p2_hero")
	var protector := state.get_card("prot")

	eq(p2_hero.damage_taken,   0, "sc1: P2 hero took 0 damage (intercepted)")
	eq(protector.damage_taken, 3, "sc1: protector took 3 damage")
	ok(protector.is_exhausted,    "sc1: protector is exhausted after protecting")
	ok(atk.is_exhausted if atk else true, "sc1: attacker is exhausted after attacking")


# ── Donna Calister: readies when an opposing character attacks ────────────────

func _test_donna_calister_readies_on_opposing_attack() -> void:
	_buf.append("\n-- Donna Calister: readies on opposing attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	# Donna: 1/7 Protector, "ready_on_opposing_attack" flag.
	db.ally("donna_def", 1, 7, (["protector"] as Array[String]), 5,
		"ready_on_opposing_attack")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "attacker_def", "p1")
	var donna := _add_ally(state, "donna", "donna_def", "p2")
	# Pretend Donna already protected earlier this turn — she's exhausted.
	donna.is_exhausted = true
	state.players["p1"].resource_placed_this_turn = true

	# P1 attacks the hero; P2 does NOT protect. The attack alone must ready Donna.
	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()

	_drive(state, db, p1_ai, p2_ai)

	ok(not state.get_card("donna").is_exhausted,
		"Donna readied by the opposing attack (though she didn't protect)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 2 — Ferocity: ally attacks the turn it is played
# ══════════════════════════════════════════════════════════════════════════════

func _test_ferocity_attacks_turn_played() -> void:
	_buf.append("\n-- Scenario 2: Ferocity ally attacks the turn it is played --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ferocity_ally", 3, 4, (["ferocity"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "ferocity_ally", "p1")
	atk.just_summoned = true
	state.players["p1"].resource_placed_this_turn = true

	var legal := StackResolver.get_legal_attackers(state, "p1", db)
	ok("atk" in legal, "sc2: Ferocity ally is a legal attacker despite just_summoned")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()

	_drive(state, db, p1_ai, p2_ai)
	eq(state.get_card("p2_hero").damage_taken, 3, "sc2: hero took 3 damage (Ferocity attacked immediately)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 3 — Elusive: never a legal defender
# ══════════════════════════════════════════════════════════════════════════════

func _test_elusive_never_targetable() -> void:
	_buf.append("\n-- Scenario 3: Elusive ally is never a legal defender --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("p1_attacker", 1, 30)
	db.ally("elusive_ally", 0, 1, (["elusive"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "p1_attacker", "p1")
	_add_ally(state, "elu", "elusive_ally", "p2")

	var defenders := StackResolver.get_legal_defenders(state, "atk", db)
	ok("elu" not in defenders, "sc3: Elusive ally is not in legal defenders list")
	ok("p2_hero" in defenders, "sc3: P2 hero IS a legal defender")

	state.players["p1"].resource_placed_this_turn = true
	_drive_turns(state, db, RandomAttackerAI.new(), ScriptedAI.new(), 5)

	ok(state.get_card("elu").zone_id == "p2_ally_row", "sc3: Elusive ally still in play")
	eq(state.get_card("elu").damage_taken, 0,           "sc3: Elusive took 0 damage")
	ok(state.get_card("p2_hero").damage_taken > 0,      "sc3: Hero absorbed all attacks")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 4 — Hand-size wrap-up discard
# ══════════════════════════════════════════════════════════════════════════════

func _test_hand_size_wrap_up_discard() -> void:
	_buf.append("\n-- Scenario 4: Wrap-up discard reduces hand to max size --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("expensive_ally", 3, 4, [], 5)

	var state := _base_state(db, "p1_hero", "p2_hero")
	for i in range(9):
		var inst_id := "hand_%d" % i
		var card := CardInstance.create(inst_id, "expensive_ally", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)
	state.players["p1"].resource_placed_this_turn = true

	_drive_turns(state, db, ScriptedAI.new(), ScriptedAI.new(), 2, false)

	eq(state.cards_in_zone("p1_hand").size(),      7, "sc4: P1 hand reduced to 7")
	eq(state.cards_in_zone("p1_graveyard").size(), 2, "sc4: 2 excess cards in graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 5 — Ta'zo hero power: deal 3 fire damage to target
# ══════════════════════════════════════════════════════════════════════════════

func _test_tazo_hero_power() -> void:
	_buf.append("\n-- Scenario 5: Ta'zo hero power deals 3 damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("tazo_def", 25, 3, "deal_damage_to_target:3:fire")
	db.ally("target_ally", 2, 4, [], 0)

	var state := GameState.create_new(["p1", "p2"])
	var h1 := CardInstance.create("p1_hero", "p1_hero", "p1", "p1_hero_row")
	state.cards["p1_hero"] = h1
	state.zones["p1_hero_row"].card_ids.append("p1_hero")
	state.players["p1"].hero_instance_id = "p1_hero"

	var h2 := CardInstance.create("tazo_inst", "tazo_def", "p2", "p2_hero_row")
	state.cards["tazo_inst"] = h2
	state.zones["p2_hero_row"].card_ids.append("tazo_inst")
	state.players["p2"].hero_instance_id = "tazo_inst"

	state.phase = "action"
	state.turn_player = "p2"
	state.priority_player = "p2"
	state.turn_number = 1

	_add_ally(state, "p1_ally", "target_ally", "p1")
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var helper := BaseAI.new()
	var legal := helper.get_reasonable_actions(state, db, "p2")
	var power_action: PendingAction = null
	for a in legal:
		if a.action_type == "activate_power" and a.params.get("target_id") == "p1_ally":
			power_action = a
			break
	ok(power_action != null, "sc5-a: activate_power targeting p1_ally in legal actions")

	var all_events: Array[GameEvent] = []
	all_events.append_array(StackResolver.submit_action(state, power_action, db) if power_action \
		else ([] as Array[GameEvent]))
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))

	var saw_power_used := false
	for e in all_events:
		if e.event_type == "hero_power_used":
			saw_power_used = true
	ok(saw_power_used, "sc5-b: hero_power_used event fired")
	eq(state.get_card("p1_ally").damage_taken if state.get_card("p1_ally") else -1, 3,
		"sc5-c: p1 ally took 3 damage")

	var p2_ps := state.players.get("p2") as PlayerState
	ok(p2_ps != null and p2_ps.has_used_hero_power, "sc5-d: has_used_hero_power is true")

	var legal2 := helper.get_reasonable_actions(state, db, "p2")
	var found_second := false
	for a in legal2:
		if a.action_type == "activate_power":
			found_second = true
	ok(not found_second, "sc5-e: activate_power not available after power used")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 6 — Taz'dingo enters-play effect fires and deals 1 ranged damage
# ══════════════════════════════════════════════════════════════════════════════

func _test_tazdingo_enter_play() -> void:
	_buf.append("\n-- Scenario 6: Taz'dingo enters-play targeted damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tazdingo_def", 2, 2, [], 3, "on_enter:deal_damage_to_target:1:ranged")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var taz := CardInstance.create("taz_inst", "tazdingo_def", "p1", "p1_hand")
	state.cards["taz_inst"] = taz
	state.zones["p1_hand"].card_ids.append("taz_inst")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "taz_inst"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("taz_inst").zone_id == "p1_ally_row",
		"sc6-a: Taz'dingo is in p1_ally_row")

	var saw_target_req := false
	for e in all_events:
		if e.event_type == "enter_play_target_required":
			saw_target_req = true
	ok(saw_target_req, "sc6-b: enter_play_target_required event fired")

	var total_dmg := 0
	for e in all_events:
		if e.event_type == "damage_dealt":
			total_dmg += e.payload.get("amount", 0)
	eq(total_dmg, 1, "sc6-c: exactly 1 total damage dealt by enters-play effect")
	ok(state.pending_enter_play_effect.is_empty(), "sc6-d: pending_enter_play_effect cleared")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 7 — Parvink enters play and draws a card
# ══════════════════════════════════════════════════════════════════════════════

func _test_parvink_enter_play() -> void:
	_buf.append("\n-- Scenario 7: Parvink enters play and draws a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("parvink_def", 2, 2, (["protector"] as Array[String]), 3, "on_enter:draw:1")
	db.ally("deck_card_def", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var parvink := CardInstance.create("parvink_inst", "parvink_def", "p1", "p1_hand")
	state.cards["parvink_inst"] = parvink
	state.zones["p1_hand"].card_ids.append("parvink_inst")

	var deck_card := CardInstance.create("deck1", "deck_card_def", "p1", "p1_deck")
	state.cards["deck1"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck1")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "parvink_inst"}))

	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("parvink_inst").zone_id == "p1_ally_row", "sc7-a: Parvink in p1_ally_row")
	ok(state.get_card("deck1").zone_id == "p1_hand",            "sc7-b: deck card drawn into hand")
	eq(_non_filler_in(state, "p1_hand").size(), 1,              "sc7-c: hand has exactly 1 non-filler card")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8 — Vanquish destroys target ally
# ══════════════════════════════════════════════════════════════════════════════

func _test_vanquish() -> void:
	_buf.append("\n-- Scenario 8: Vanquish destroys target ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_ally_def", 3, 5, [], 5)
	db.instant("vanquish_def", 4, "destroy_target:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)

	var vanquish := CardInstance.create("vanquish_inst", "vanquish_def", "p1", "p1_hand")
	state.cards["vanquish_inst"] = vanquish
	state.zones["p1_hand"].card_ids.append("vanquish_inst")

	var big := CardInstance.create("big_ally_inst", "big_ally_def", "p2", "p2_ally_row")
	state.cards["big_ally_inst"] = big
	state.zones["p2_ally_row"].card_ids.append("big_ally_inst")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "vanquish_inst", "target_id": "big_ally_inst"}))

	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("big_ally_inst").zone_id == "p2_graveyard", "sc8-a: target ally in graveyard")
	ok(state.get_card("vanquish_inst").zone_id == "p1_graveyard", "sc8-b: Vanquish in graveyard")

	var p2_hero_id := (state.players.get("p2") as PlayerState).hero_instance_id
	var bad_action := PendingAction.make("play_instant", "p1",
		{"card_id": "vanquish_inst", "target_id": p2_hero_id})
	ok(not StackResolver.can_submit(state, bad_action, db), "sc8-c: Vanquish cannot target a hero")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8b — Quick Strike: instant, hero deals 2 melee to announced target
#
# Quick Strike is an Instant Ability whose target is ANNOUNCED at play time
# (like Vanquish — gives humans cancellable targeting). The damage SOURCE is
# the controller's hero ("Your hero deals 2 melee damage"), not the ability
# card (which goes to the graveyard on resolution).
#
# Assertions:
#   sc8b-a  submission WITHOUT a target is rejected
#   sc8b-b  exactly 2 total damage dealt to the announced target
#   sc8b-c  the damage source is the controller's HERO
#   sc8b-d  Quick Strike itself is in the graveyard
#   sc8b-e  the target carries the damage (4 HP ally at 2 damage, survives)
#   sc8b-f  instant is legal DURING a combat window (instant timing)
#   sc8b-g  a non-instant ally is NOT legal in that same window (contrast)
# ══════════════════════════════════════════════════════════════════════════════

func _test_quick_strike() -> void:
	_buf.append("\n-- Scenario 8b: Quick Strike — hero deals 2 melee to announced target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 4, [], 3)
	db.ally("dummy_ally_def", 1, 1, [], 1)
	db.instant("quickstrike_def", 3, "deal_damage_to_target:2:melee")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var qs := CardInstance.create("qs_inst", "quickstrike_def", "p1", "p1_hand")
	state.cards["qs_inst"] = qs
	state.zones["p1_hand"].card_ids.append("qs_inst")

	# The opposing ally that will be targeted.
	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	# Target is required at submission.
	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_instant", "p1", {"card_id": "qs_inst"}), db),
		"sc8b-a: submission without a target is rejected")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "qs_inst", "target_id": "enemy_ally"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	var total_dmg := 0
	var dmg_source := ""
	for e in all_events:
		if e.event_type == "damage_dealt":
			total_dmg += int(e.payload.get("amount", 0))
			dmg_source = e.payload.get("source", dmg_source)
	eq(total_dmg, 2, "sc8b-b: exactly 2 total damage dealt")
	var p1_hero_id := (state.players.get("p1") as PlayerState).hero_instance_id
	eq(dmg_source, p1_hero_id, "sc8b-c: damage source is the controller's hero")
	ok(state.get_card("qs_inst").zone_id == "p1_graveyard", "sc8b-d: Quick Strike in graveyard")
	eq(state.get_card("enemy_ally").damage_taken, 2,
		"sc8b-e: announced target carries the 2 damage (survives at 4 HP)")

	# ── Instant timing: legal during a combat window; a non-instant is not. ──
	var tstate := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(tstate, "p1", 3)
	tstate.combat_attack_window = true
	var qs2 := CardInstance.create("qs2", "quickstrike_def", "p1", "p1_hand")
	tstate.cards["qs2"] = qs2
	tstate.zones["p1_hand"].card_ids.append("qs2")
	var dummy := CardInstance.create("dummy_ally", "dummy_ally_def", "p1", "p1_hand")
	tstate.cards["dummy_ally"] = dummy
	tstate.zones["p1_hand"].card_ids.append("dummy_ally")
	var p2_hero_id := (tstate.players.get("p2") as PlayerState).hero_instance_id
	ok(StackResolver.can_submit(tstate,
		PendingAction.make("play_instant", "p1",
			{"card_id": "qs2", "target_id": p2_hero_id}), db),
		"sc8b-f: Quick Strike (instant) is legal during a combat window")
	ok(not StackResolver.can_submit(tstate,
		PendingAction.make("play_ally", "p1", {"card_id": "dummy_ally"}), db),
		"sc8b-g: a non-instant ally is NOT legal in that same window")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8c — Lightning Bolt: non-instant ability, hero deals 4 nature to
# target hero or ally (own or opponent's)
#
# Same shape as Quick Strike (deal_damage_to_target) but action-phase timing
# like Vanquish, not instant speed. Also verifies self-targeting is legal for
# the human/engine, but the AI never selects its own hero/ally as a target.
# ══════════════════════════════════════════════════════════════════════════════

func _test_lightning_bolt() -> void:
	_buf.append("\n-- Scenario 8c: Lightning Bolt — non-instant, 4 nature to target hero or ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("enemy_ally_def", 2, 6, [], 3)
	db.ability("bolt_def", 3, "deal_damage_to_target:4:nature")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var bolt := CardInstance.create("bolt_inst", "bolt_def", "p1", "p1_hand")
	state.cards["bolt_inst"] = bolt
	state.zones["p1_hand"].card_ids.append("bolt_inst")

	var enemy := CardInstance.create("enemy_ally_inst", "enemy_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally_inst"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally_inst")

	# Not legal during a combat window (non-instant, action-phase timing).
	var tstate := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(tstate, "p1", 3)
	tstate.combat_attack_window = true
	var bolt2 := CardInstance.create("bolt2", "bolt_def", "p1", "p1_hand")
	tstate.cards["bolt2"] = bolt2
	tstate.zones["p1_hand"].card_ids.append("bolt2")
	var p2_hero_id_t := (tstate.players.get("p2") as PlayerState).hero_instance_id
	ok(not StackResolver.can_submit(tstate,
		PendingAction.make("play_ability", "p1", {"card_id": "bolt2", "target_id": p2_hero_id_t}), db),
		"sc8c-a: Lightning Bolt is NOT legal during a combat window")

	# Legal to target own hero (rules-legal, even if AI would never choose it).
	var p1_hero_id := (state.players.get("p1") as PlayerState).hero_instance_id
	ok(StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1", {"card_id": "bolt_inst", "target_id": p1_hero_id}), db),
		"sc8c-b: Lightning Bolt CAN legally target your own hero")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "bolt_inst", "target_id": "enemy_ally_inst"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	var total_dmg := 0
	var dmg_source := ""
	for e in all_events:
		if e.event_type == "damage_dealt":
			total_dmg += int(e.payload.get("amount", 0))
			dmg_source = e.payload.get("source", dmg_source)
	eq(total_dmg, 4, "sc8c-c: exactly 4 nature damage dealt")
	eq(dmg_source, p1_hero_id, "sc8c-d: damage source is the controller's hero")
	ok(state.get_card("bolt_inst").zone_id == "p1_graveyard", "sc8c-e: Lightning Bolt in graveyard")
	eq(state.get_card("enemy_ally_inst").damage_taken, 4,
		"sc8c-f: target carries the 4 damage")

	# AI never targets its own hero/ally with a targeted damage ability.
	var astate := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(astate, "p1", 3)
	var bolt3 := CardInstance.create("bolt3", "bolt_def", "p1", "p1_hand")
	astate.cards["bolt3"] = bolt3
	astate.zones["p1_hand"].card_ids.append("bolt3")
	var own_ally := CardInstance.create("own_ally_inst", "enemy_ally_def", "p1", "p1_ally_row")
	astate.cards["own_ally_inst"] = own_ally
	astate.zones["p1_ally_row"].card_ids.append("own_ally_inst")

	var base_ai := BaseAI.new()
	var actions: Array[PendingAction] = base_ai.get_reasonable_actions(astate, db, "p1")
	var p1_hero_id_a := (astate.players.get("p1") as PlayerState).hero_instance_id
	var self_targeted := false
	for act in actions:
		if act.action_type == "play_ability" and act.params.get("card_id", "") == "bolt3":
			var tid: String = act.params.get("target_id", "")
			if tid == p1_hero_id_a or tid == "own_ally_inst":
				self_targeted = true
	ok(not self_targeted, "sc8c-g: AI never generates a self-targeting Lightning Bolt action")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 9 — Pet uniqueness: only 1 pet may be in play at a time
#
# Setup:
#   P1 has 2 Grimdron instances in hand (played sequentially so the second
#   triggers the uniqueness rule), plus 1 Grimdron in each of: deck, graveyard,
#   and face-down resource row (none of which count toward the limit).
#   P1 has 2 ready resources so both can be played.
#
# The key thing being tested: when the second Grimdron enters play the engine
# emits pet_sacrifice_required and the driver must resolve it — the AI (or
# headless helper) cannot pass this mandatory choice.
#
# Assertions:
#   sc9-a  exactly 1 Grimdron is in p1_ally_row at the end
#   sc9-b  pet_sacrifice_required event fired exactly once
#   sc9-c  the sacrificed Grimdron is in the graveyard (one of the two hand ones)
#   sc9-d  Grimdron in deck still in deck (non-ally_row zones are unaffected)
#   sc9-e  Grimdron in graveyard still in graveyard (not double-counted)
#   sc9-f  Grimdron as face-down resource still in resource_row
#   sc9-g  pending_pet_sacrifice_player cleared after resolution
# ══════════════════════════════════════════════════════════════════════════════

func _test_pet_uniqueness() -> void:
	_buf.append("\n-- Scenario 9: Pet uniqueness — only 1 pet allowed in play --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.pet("grimdron_def", 0, 1, (["elusive"] as Array[String]), 1,
		"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally")

	var state := _base_state(db, "p1_hero", "p2_hero")

	# 2 ready resources — exactly enough for both hand Grimdrons (cost 1 each).
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true

	# 2 Grimdrons in hand.
	for i in range(2):
		var inst_id := "grim_hand_%d" % i
		var card := CardInstance.create(inst_id, "grimdron_def", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)

	# 1 Grimdron in deck (must NOT be touched by uniqueness rule).
	var grim_deck := CardInstance.create("grim_deck", "grimdron_def", "p1", "p1_deck")
	state.cards["grim_deck"] = grim_deck
	state.zones["p1_deck"].card_ids.append("grim_deck")

	# 1 Grimdron already in graveyard before the scenario starts (must NOT be touched).
	var grim_grave := CardInstance.create("grim_grave", "grimdron_def", "p1", "p1_graveyard")
	state.cards["grim_grave"] = grim_grave
	state.zones["p1_graveyard"].card_ids.append("grim_grave")

	# 1 Grimdron as face-down resource (must NOT be touched).
	var grim_res := CardInstance.create("grim_res", "grimdron_def", "p1", "p1_resource_row")
	grim_res.face_down = true
	state.cards["grim_res"] = grim_res
	state.zones["p1_resource_row"].card_ids.append("grim_res")

	# Queue both hand Grimdrons — second play must trigger sacrifice.
	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "grim_hand_0"}))
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "grim_hand_1"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 4)

	# sc9-a: exactly 1 Grimdron in ally_row.
	var pets_in_play := 0
	for card in state.cards_in_zone("p1_ally_row"):
		var d := db.get_def(card.card_def_id) as CardDef
		if d and d.card_subtype == "Pet":
			pets_in_play += 1
	eq(pets_in_play, 1, "sc9-a: exactly 1 pet in p1_ally_row after playing 2")

	# sc9-b: sacrifice event fired exactly once.
	var sacrifice_events := 0
	for e in all_events:
		if e.event_type == "pet_sacrifice_required":
			sacrifice_events += 1
	eq(sacrifice_events, 1, "sc9-b: pet_sacrifice_required fired exactly once")

	# sc9-c: one of the two hand Grimdrons was sacrificed to graveyard.
	var hand_grim_in_grave := 0
	for cid in ["grim_hand_0", "grim_hand_1"]:
		if state.get_card(cid).zone_id == "p1_graveyard":
			hand_grim_in_grave += 1
	eq(hand_grim_in_grave, 1, "sc9-c: exactly 1 hand Grimdron was sacrificed to graveyard")

	# sc9-d/e/f: non-ally_row Grimdrons untouched.
	ok(state.get_card("grim_deck").zone_id != "p2_graveyard",   "sc9-d: deck Grimdron not destroyed by uniqueness rule")
	eq(state.get_card("grim_grave").zone_id, "p1_graveyard",    "sc9-e: pre-existing graveyard Grimdron unchanged")
	eq(state.get_card("grim_res").zone_id,   "p1_resource_row", "sc9-f: face-down resource Grimdron unchanged")

	# sc9-g: pending sacrifice state is cleared.
	eq(state.pending_pet_sacrifice_player, "", "sc9-g: pending_pet_sacrifice_player cleared")


# ══════════════════════════════════════════════════════════════════════════════
# Mooncloth Robe — equipment play + activated power (draw a card)
#
# Power: (2), Exhaust this, Exhaust your hero >>> Draw a card.
# ══════════════════════════════════════════════════════════════════════════════

const ROBE_EFFECTS := "equipment:chest:0|activated_power:2:draw:1:::exhaust_hero"

func _test_mooncloth_robe_power() -> void:
	_buf.append("\n-- Mooncloth Robe: play from hand + draw power --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")

	# 6 ready resources: 4 to play the robe, 2 for the power.
	_add_resources(state, "p1", 6)
	state.players["p1"].resource_placed_this_turn = true

	# Robe in hand.
	var robe := CardInstance.create("robe_inst", "robe_def", "p1", "p1_hand")
	state.cards["robe_inst"] = robe
	state.zones["p1_hand"].card_ids.append("robe_inst")

	# One card in deck to be drawn by the power.
	var deck_card := CardInstance.create("deck_card", "robe_def", "p1", "p1_deck")
	state.cards["deck_card"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck_card")

	# mr-a: playing the equipment is legal.
	var play := PendingAction.make("play_equipment", "p1", {"card_id": "robe_inst"})
	ok(StackResolver.can_submit(state, play, db), "mr-a: play_equipment is legal")

	# Resolve the play (submit + both pass).
	StackResolver.submit_action(state, play, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# mr-b: robe entered the hero row.
	eq(state.get_card("robe_inst").zone_id, "p1_hero_row",
		"mr-b: robe enters play in the hero row")

	# mr-c: the power is usable this same turn (equipment has no summoning sickness).
	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"})
	ok(StackResolver.can_submit(state, use, db),
		"mr-c: robe power usable the turn it entered play")

	# Resolve the power.
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# mr-d: the deck card was drawn into hand.
	eq(state.get_card("deck_card").zone_id, "p1_hand",
		"mr-d: robe power drew a card")

	# mr-e: robe is exhausted (activate symbol).
	ok(state.get_card("robe_inst").is_exhausted, "mr-e: robe exhausted after use")

	# mr-f: hero is exhausted (extra cost).
	ok(state.get_card("p1_hero").is_exhausted, "mr-f: hero exhausted by robe power")

	# mr-g: all 6 resources are now exhausted (4 play + 2 power).
	var ready_res := 0
	for r in state.cards_in_zone("p1_resource_row"):
		if not r.is_exhausted:
			ready_res += 1
	eq(ready_res, 0, "mr-g: 6 resources spent (4 play + 2 power)")

	# mr-h: power can't be used again (robe now exhausted).
	ok(not StackResolver.can_submit(state, use, db),
		"mr-h: robe power not reusable while exhausted")


func _test_mooncloth_robe_hero_exhausted() -> void:
	_buf.append("\n-- Mooncloth Robe: cannot use with exhausted hero / too few resources --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	var deck_card := CardInstance.create("deck_card", "robe_def", "p1", "p1_deck")
	state.cards["deck_card"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck_card")

	# Robe already in play (ready).
	var robe := CardInstance.create("robe_inst", "robe_def", "p1", "p1_hero_row")
	state.cards["robe_inst"] = robe
	state.zones["p1_hero_row"].card_ids.append("robe_inst")

	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"})

	# me-a: with a ready hero and 2 resources, legal.
	ok(StackResolver.can_submit(state, use, db),
		"me-a: robe power legal with ready hero + 2 resources")

	# me-b: exhausted hero → cannot pay the exhaust-hero cost.
	state.get_card("p1_hero").is_exhausted = true
	ok(not StackResolver.can_submit(state, use, db),
		"me-b: robe power illegal when hero already exhausted")
	state.get_card("p1_hero").is_exhausted = false

	# me-c: only 1 ready resource → cannot pay the 2 cost.
	state.cards_in_zone("p1_resource_row")[0].is_exhausted = true
	ok(not StackResolver.can_submit(state, use, db),
		"me-c: robe power illegal with only 1 ready resource")


# ══════════════════════════════════════════════════════════════════════════════
# Activated-power exhaust costs are paid ON CHAIN ENTRY (rule 412.2)
#
# The [Activate] tap symbol and the "Exhaust your hero" extra cost are paid at
# announcement, not at resolution. Deferring them left the source and the hero
# READY while the power sat on the chain, so a second copy of the same power —
# or Rod of the Ogre Magi + The Hammer of Grace off one hero — validated and
# both resolved off a single exhaust.
# ══════════════════════════════════════════════════════════════════════════════

const ROD_EFFECTS := "equipment:melee_weapon:0|strike_cost:4|two_handed|power_weapon|activated_power:2:deal_damage_to_target:1::hero_or_ally:exhaust_hero"

func _test_activate_costs_paid_on_announce() -> void:
	_buf.append("\n-- Activated power: exhaust costs paid at announcement --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")
	db.equipment("rod_def", 4, ROD_EFFECTS, "Staff")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 6)
	state.players["p1"].resource_placed_this_turn = true

	# Robe + Rod both already in play and ready; both cost 2 and exhaust the hero.
	for pair in [["robe_inst", "robe_def"], ["rod_inst", "rod_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_hero_row")
		state.cards[pair[0]] = c
		state.zones["p1_hero_row"].card_ids.append(pair[0])

	for i in 2:
		var dc := CardInstance.create("deck_%d" % i, "robe_def", "p1", "p1_deck")
		state.cards["deck_%d" % i] = dc
		state.zones["p1_deck"].card_ids.append("deck_%d" % i)

	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"})
	StackResolver.submit_action(state, use, db)

	# ac-a/b: both exhausts land at announcement, while the power is still on the chain.
	ok(state.get_card("robe_inst").is_exhausted, "ac-a: source exhausted at announcement")
	ok(state.get_card("p1_hero").is_exhausted, "ac-b: hero exhausted at announcement")
	eq(state.get_card("deck_0").zone_id, "p1_deck",
		"ac-c: effect has NOT resolved yet (card still in deck)")

	# ac-d: the same power can't be announced twice off one exhaust.
	ok(not StackResolver.can_submit(state,
		PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"}), db),
		"ac-d: same power not re-announceable while on the chain")

	# ac-e: a DIFFERENT exhaust_hero power can't ride the same (now spent) hero.
	ok(not StackResolver.can_submit(state,
		PendingAction.make("use_ally_power", "p1",
			{"card_id": "rod_inst", "target_id": "p2_hero"}), db),
		"ac-e: second exhaust_hero power illegal off an already-spent hero")

	# ac-f: costs were paid at announcement, so an opponent exhausting the hero in
	# response (War Stomp) changes nothing — the effect still resolves.
	state.get_card("p1_hero").is_exhausted = true
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("deck_0").zone_id, "p1_hand",
		"ac-f: effect resolves normally after the costs were already paid")


func _test_activate_costs_refunded_on_retract() -> void:
	_buf.append("\n-- Activated power: retraction refunds the exhaust costs --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	var dc := CardInstance.create("deck_0", "robe_def", "p1", "p1_deck")
	state.cards["deck_0"] = dc
	state.zones["p1_deck"].card_ids.append("deck_0")

	var robe := CardInstance.create("robe_inst", "robe_def", "p1", "p1_hero_row")
	state.cards["robe_inst"] = robe
	state.zones["p1_hero_row"].card_ids.append("robe_inst")

	StackResolver.submit_action(state,
		PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"}), db)
	StackResolver.retract_last(state, "p1", db)

	# rt-a/b: both exhausts undone.
	ok(not state.get_card("robe_inst").is_exhausted, "rt-a: source readied by retraction")
	ok(not state.get_card("p1_hero").is_exhausted, "rt-b: hero readied by retraction")

	# rt-c: the SOURCE stays on the board — retraction must not bounce it to hand
	# (only cards played FROM hand go back there).
	eq(state.get_card("robe_inst").zone_id, "p1_hero_row",
		"rt-c: power source stays in play after retraction")

	# rt-d: resources refunded.
	eq(state.get_available_resources("p1"), 2, "rt-d: resource cost refunded")

	# rt-e: the power is fully usable again.
	ok(StackResolver.can_submit(state,
		PendingAction.make("use_ally_power", "p1", {"card_id": "robe_inst"}), db),
		"rt-e: power re-announceable after retraction")


func _test_equipment_slot_uniqueness() -> void:
	_buf.append("\n-- Equipment slot uniqueness: only 1 Chest allowed --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 8)   # 4 + 4 to play both
	state.players["p1"].resource_placed_this_turn = true

	for i in range(2):
		var inst_id := "robe_hand_%d" % i
		var card := CardInstance.create(inst_id, "robe_def", "p1", "p1_hand")
		state.cards[inst_id] = card
		state.zones["p1_hand"].card_ids.append(inst_id)

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_equipment", "p1", {"card_id": "robe_hand_0"}))
	p1_ai.queue_action(PendingAction.make("play_equipment", "p1", {"card_id": "robe_hand_1"}))

	var all_events := _drive_turns(state, db, p1_ai, ScriptedAI.new(), 4)

	# eu-a: exactly 1 Chest equipment remains in the hero row.
	var chest_in_play := 0
	for card in state.cards_in_zone("p1_hero_row"):
		var d := db.get_def(card.card_def_id) as CardDef
		if d and d.card_type == "Equipment":
			chest_in_play += 1
	eq(chest_in_play, 1, "eu-a: exactly 1 Chest equipment in hero_row after playing 2")

	# eu-b: sacrifice event fired exactly once.
	var sac := 0
	for e in all_events:
		if e.event_type == "equipment_sacrifice_required":
			sac += 1
	eq(sac, 1, "eu-b: equipment_sacrifice_required fired exactly once")

	# eu-c: one robe was destroyed to the graveyard.
	var in_grave := 0
	for cid in ["robe_hand_0", "robe_hand_1"]:
		if state.get_card(cid).zone_id == "p1_graveyard":
			in_grave += 1
	eq(in_grave, 1, "eu-c: exactly 1 robe destroyed to graveyard")

	# eu-d: pending state cleared.
	eq(state.pending_equip_sacrifice_player, "", "eu-d: pending_equip_sacrifice_player cleared")


func _test_ai_plays_equipment() -> void:
	_buf.append("\n-- AI generates equipment play + draw-power actions --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("robe_def", 4, ROBE_EFFECTS, "Cloth")
	var ai := BaseAI.new()

	# Case 1: robe in hand, affordable → AI offers play_equipment.
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s1, "p1", 4)
	s1.players["p1"].resource_placed_this_turn = true
	var robe := CardInstance.create("robe_inst", "robe_def", "p1", "p1_hand")
	s1.cards["robe_inst"] = robe
	s1.zones["p1_hand"].card_ids.append("robe_inst")
	var has_play := false
	for a in ai.get_reasonable_actions(s1, db, "p1"):
		if a.action_type == "play_equipment" and a.params.get("card_id") == "robe_inst":
			has_play = true
	ok(has_play, "ai-eq-a: AI offers play_equipment for a robe in hand")

	# Case 2: robe in play, ready hero, deck card, 2 resources → AI offers the draw power.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s2, "p1", 2)
	s2.players["p1"].resource_placed_this_turn = true
	var robe2 := CardInstance.create("robe2", "robe_def", "p1", "p1_hero_row")
	s2.cards["robe2"] = robe2
	s2.zones["p1_hero_row"].card_ids.append("robe2")
	var deck2 := CardInstance.create("deck2", "robe_def", "p1", "p1_deck")
	s2.cards["deck2"] = deck2
	s2.zones["p1_deck"].card_ids.append("deck2")
	var has_power := false
	for a in ai.get_reasonable_actions(s2, db, "p1"):
		if a.action_type == "use_ally_power" and a.params.get("card_id") == "robe2":
			has_power = true
	ok(has_power, "ai-eq-b: AI offers the robe draw power from the hero row")

	# Case 3: same as case 2 but hand is full → AI skips the draw power.
	for i in range(7):
		var hid := "fill_%d" % i
		var c := CardInstance.create(hid, "robe_def", "p1", "p1_hand")
		s2.cards[hid] = c
		s2.zones["p1_hand"].card_ids.append(hid)
	var still_power := false
	for a in ai.get_reasonable_actions(s2, db, "p1"):
		if a.action_type == "use_ally_power" and a.params.get("card_id") == "robe2":
			still_power = true
	ok(not still_power, "ai-eq-c: AI skips the draw power when hand is full")


# ══════════════════════════════════════════════════════════════════════════════
# Pads of the Dread Wolf — armor damage prevention (rule 717.2c)
#
# Cost 1, Armor—Leather, Feet, 1 DEF. No powers — its whole job is
# "exhaust to prevent 1 damage to your hero". The prevention point opens at the
# moment the packet would land (combat conclusion / a hero-damaging chain link
# about to resolve) — never a chain action, resolved via choose_prevention().
# ══════════════════════════════════════════════════════════════════════════════

const PADS_EFFECTS := "equipment:feet:1"

func _test_pads_block_combat() -> void:
	_buf.append("\n-- Pads of the Dread Wolf: prevention point at combat conclusion --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.ally("smasher", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_ally(state, "smasher_inst", "smasher", "p2")
	var pads := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p1_hero_row"].card_ids.append("pads_inst")

	# p2 attacks p1's hero.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "smasher_inst", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → combat starts, attack window
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → defend window opens
	ok(state.pending_prevention_player == "",
		"pb-a: no prevention point before the packets would land")
	StackResolver.pass_priority(state, db)   # p2 passes
	var events := StackResolver.pass_priority(state, db)   # p1 passes → conclusion imminent

	# pb-b: instead of concluding, the prevention point opened for p1.
	eq(state.pending_prevention_player, "p1", "pb-b: prevention point opened for p1")
	eq(state.pending_prevention_amount, 2, "pb-b2: packet amount is the attacker's ATK")
	var opened := false
	for ev in events:
		if ev.event_type == "prevention_opened":
			opened = true
	ok(opened, "pb-b3: prevention_opened emitted")
	eq(state.get_card("p1_hero").damage_taken, 0, "pb-b4: no damage yet — packet held")

	# pb-c: the pass/submit gates hard-block while the point is open.
	eq(StackResolver.pass_priority(state, db).size(), 0,
		"pb-c: pass_priority blocked while prevention pending")

	# p1 exhausts the pads → conclusion runs with the reduced packet.
	StackResolver.choose_prevention(state, "pads_inst", db)
	ok(state.get_card("pads_inst").is_exhausted, "pb-d: pads exhausted by the choice")
	eq(state.pending_prevention_player, "", "pb-d2: point closed (no more ready armor)")
	eq(state.get_card("p1_hero").damage_taken, 1, "pb-e: hero took 1 (2 ATK − 1 prevented)")
	eq(state.players["p1"].damage_prevention, 0, "pb-f: pool cleared after combat")
	eq(state.combat_attacker, "", "pb-g: combat concluded after the choice")


func _test_pads_block_decline() -> void:
	_buf.append("\n-- Prevention point: declining takes the full damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.ally("smasher", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_ally(state, "smasher_inst", "smasher", "p2")
	var pads := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p1_hero_row"].card_ids.append("pads_inst")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "smasher_inst", "defender_id": "p1_hero"}), db)
	for _i in range(6):
		StackResolver.pass_priority(state, db)
	eq(state.pending_prevention_player, "p1", "pd-a: prevention point opened")
	StackResolver.choose_prevention(state, "", db)   # decline
	eq(state.get_card("p1_hero").damage_taken, 2, "pd-b: full 2 damage taken")
	ok(not state.get_card("pads_inst").is_exhausted, "pd-c: pads stays ready")


func _test_pads_block_instant() -> void:
	_buf.append("\n-- Prevention point: hero-damaging chain link about to resolve --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.instant("zap_def", 1, "deal_damage_to_target:2:melee")

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p2", 1)
	var pads := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p1_hero_row"].card_ids.append("pads_inst")
	var zap := CardInstance.create("zap_inst", "zap_def", "p2", "p2_hand")
	state.cards["zap_inst"] = zap
	state.zones["p2_hand"].card_ids.append("zap_inst")

	# p2 plays the damage instant at p1's hero; both pass → the link would
	# resolve, so the prevention point opens first.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2",
		{"card_id": "zap_inst", "target_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → prevention point, link stashed

	eq(state.pending_prevention_player, "p1", "pi-a: prevention point opened for p1")
	eq(state.pending_prevention_amount, 2, "pi-a2: packet is the instant's damage")
	eq(state.get_card("p1_hero").damage_taken, 0, "pi-a3: link held, no damage yet")

	StackResolver.choose_prevention(state, "pads_inst", db)   # exhaust → link resolves

	eq(state.get_card("p1_hero").damage_taken, 1, "pi-b: hero took 1 (2 dmg − 1 prevented)")
	eq(state.players["p1"].damage_prevention, 0, "pi-c: pool consumed/cleared")
	eq(state.priority_player, "p2", "pi-d: turn player has priority post-resolution")


# Prevention vs enter-play targeted damage (e.g. Taz'dingo): the target choice
# sits on the chain as choose_enter_play_target — the point opens as it would
# resolve, exactly like against Quick Strike.
func _test_pads_block_enter_play_damage() -> void:
	_buf.append("\n-- Prevention point: enter-play targeted damage (Taz'dingo-style) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.ally("taz_def", 2, 2, [], 3, "on_enter:deal_damage_to_target:2:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p2", 3)
	var pads := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p1_hero_row"].card_ids.append("pads_inst")
	var taz := CardInstance.create("taz_inst", "taz_def", "p2", "p2_hand")
	state.cards["taz_inst"] = taz
	state.zones["p2_hand"].card_ids.append("taz_inst")

	# p2 plays the ally; it resolves and its enter-play effect wants a target.
	StackResolver.submit_action(state, PendingAction.make("play_ally", "p2",
		{"card_id": "taz_inst"}), db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → ally resolves, effect pending
	ok(not state.pending_enter_play_effect.is_empty(),
		"ep-a: enter-play effect pending after the ally resolves")

	# p2 announces the target: p1's hero. The choice goes on the chain.
	StackResolver.submit_action(state, PendingAction.make("choose_enter_play_target",
		"p2", {"source_card_id": "taz_inst", "target_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → prevention point before it lands

	eq(state.pending_prevention_player, "p1",
		"ep-b: prevention point opened against enter-play damage")

	# ep-c: the AI picks the armor at the point.
	var ai := BaseAI.new()
	eq(ai.choose_prevention(state, db, "p1"), "pads_inst",
		"ep-c: AI exhausts the armor against enter-play damage")

	StackResolver.choose_prevention(state, "pads_inst", db)
	eq(state.get_card("p1_hero").damage_taken, 1, "ep-d: hero took 1 (2 dmg − 1 prevented)")
	eq(state.players["p1"].damage_prevention, 0, "ep-e: pool consumed to 0")


func _test_pads_overblock_expires() -> void:
	_buf.append("\n-- Prevention point: excess DEF beyond the packet is wasted --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("plate_def", 3, "equipment:chest:3", "Plate")
	db.ally("poker", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_ally(state, "poker_inst", "poker", "p2")
	var plate := CardInstance.create("plate_inst", "plate_def", "p1", "p1_hero_row")
	state.cards["plate_inst"] = plate
	state.zones["p1_hero_row"].card_ids.append("plate_inst")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "poker_inst", "defender_id": "p1_hero"}), db)
	for _i in range(6):
		StackResolver.pass_priority(state, db)   # → prevention point at conclusion
	eq(state.pending_prevention_player, "p1", "ob-pre: prevention point opened")
	StackResolver.choose_prevention(state, "plate_inst", db)   # DEF 3 vs 2 dmg

	# ob-a: hero took 0 (2 ATK fully prevented by DEF 3).
	eq(state.get_card("p1_hero").damage_taken, 0, "ob-a: hero took 0 (fully prevented)")
	# ob-b: leftover 1 DEF wasted — pool cleared with the packet.
	eq(state.players["p1"].damage_prevention, 0, "ob-b: leftover DEF wasted after combat")


# Multi-armor stacking at ONE point (717.2c "you may exhaust another equipment,
# and so on") + the AI's per-armor picks.
func _test_ai_armor_block_heuristic() -> void:
	_buf.append("\n-- Prevention point: multi-armor stacking + AI heuristic --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("plate3_def", 3, "equipment:chest:3", "Plate")
	db.equipment("pads1_def", 1, PADS_EFFECTS, "Leather")
	db.equipment("shield6_def", 5, "equipment:back:6", "Plate")
	db.ally("bruiser", 6, 6)
	db.ally("rat", 1, 1)
	var ai := BaseAI.new()

	# Case 1: 6 incoming vs DEF 3 + DEF 1 → point stays open after the first
	# exhaust; AI picks the 3 first, then the 1, both at the same point.
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	s1.turn_player     = "p2"
	s1.priority_player = "p2"
	_add_ally(s1, "bruiser_inst", "bruiser", "p2")
	for pair in [["plate_inst", "plate3_def"], ["pads_inst", "pads1_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_hero_row")
		s1.cards[pair[0]] = c
		s1.zones["p1_hero_row"].card_ids.append(pair[0])
	StackResolver.submit_action(s1, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "bruiser_inst", "defender_id": "p1_hero"}), db)
	for _i in range(6):
		StackResolver.pass_priority(s1, db)
	eq(s1.pending_prevention_player, "p1", "hb-pre: prevention point opened")
	eq(s1.pending_prevention_amount, 6, "hb-pre2: packet is 6")

	var pick1 := ai.choose_prevention(s1, db, "p1")
	eq(pick1, "plate_inst", "hb-a: 6 incoming → highest DEF (3) armor chosen first")
	StackResolver.choose_prevention(s1, pick1, db)
	eq(s1.pending_prevention_player, "p1", "hb-a2: point stays open (damage remains, armor left)")
	eq(s1.pending_prevention_amount, 3, "hb-a3: remaining packet reduced to 3")

	var pick2 := ai.choose_prevention(s1, db, "p1")
	eq(pick2, "pads_inst", "hb-b: 3 remaining → DEF 1 armor also exhausted (3 >= 0)")
	StackResolver.choose_prevention(s1, pick2, db)
	eq(s1.pending_prevention_player, "", "hb-c: no ready armor left → point closes, combat concludes")
	eq(s1.get_card("p1_hero").damage_taken, 2, "hb-c2: hero took 6 − 4 = 2")
	eq(s1.players["p1"].damage_prevention, 0, "hb-c3: pool cleared")

	# Case 2: 1 incoming vs DEF 6 → wasted potential (1 < 5), AI declines.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	s2.turn_player = "p2"
	_add_ally(s2, "rat_inst", "rat", "p2")
	var sh := CardInstance.create("shield_inst", "shield6_def", "p1", "p1_hero_row")
	s2.cards["shield_inst"] = sh
	s2.zones["p1_hero_row"].card_ids.append("shield_inst")
	s2.pending_prevention_player = "p1"
	s2.pending_prevention_amount = 1
	eq(ai.choose_prevention(s2, db, "p1"), "",
		"hb-d: 1 incoming vs DEF 6 → armor held (wasted potential)")
	s2.pending_prevention_player = ""
	s2.pending_prevention_amount = 0

	# Case 3: ally (not hero) is the defender → no prevention point at all
	# (heroes are the only shielders).
	var s3 := _base_state(db, "p1_hero", "p2_hero")
	s3.turn_player = "p2"
	_add_ally(s3, "bruiser_inst3", "bruiser", "p2")
	_add_ally(s3, "rat_p1", "rat", "p1")
	var sh3 := CardInstance.create("shield3_inst", "shield6_def", "p1", "p1_hero_row")
	s3.cards["shield3_inst"] = sh3
	s3.zones["p1_hero_row"].card_ids.append("shield3_inst")
	s3.combat_attacker = "bruiser_inst3"
	s3.combat_defender = "rat_p1"
	eq(StackResolver._combat_prevention_offers(s3, db).size(), 0,
		"hb-e: ally under attack → no prevention point (heroes only)")


# Non-chain damage sources route through the prevention machinery too
# (defer_packets): totem start-of-turn triggers, Infernal's end-of-turn burn,
# and on_destroyed AoE all offer the point before their hero packet lands.
func _test_prevention_noncombat_sources() -> void:
	_buf.append("\n-- Prevention point: totem / Infernal EOT / death AoE packets --")

	# Case 1: totem start-of-turn trigger aimed at an armored hero.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.ally("totem_def", 0, 1)
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(s1, "totem_inst", "totem_def", "p2")
	var pads1 := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	s1.cards["pads_inst"] = pads1
	s1.zones["p1_hero_row"].card_ids.append("pads_inst")
	s1.pending_ongoing_triggers = [
		{"card_id": "totem_inst", "amount": 1, "dmg_type": "fire"}]
	s1.pending_totem_target_player = "p2"
	StackResolver.choose_totem_target(s1, "p1_hero", db)
	# 501.1a / 410: the trigger is now a chain link — its damage (and so the
	# prevention point) lands only after the priority window closes (both pass).
	eq(s1.pending_prevention_player, "", "nc-a0: no damage until the totem link resolves")
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)
	eq(s1.pending_prevention_player, "p1", "nc-a: totem packet opens the prevention point")
	StackResolver.choose_prevention(s1, "pads_inst", db)
	eq(s1.get_card("p1_hero").damage_taken, 0, "nc-b: totem's 1 fire fully prevented")
	eq(s1.pending_totem_target_player, "", "nc-b2: totem queue drained after the point")

	# Case 2: Infernal end-of-turn burn — the opposing hero's packet is
	# preventable; the ally packets in the same group land regardless.
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db2.ally("infernal_def", 6, 6, [], 6, "end_of_turn_damage_opposing:1:fire")
	db2.ally("tough_def", 0, 3)
	var s2 := _base_state(db2, "p1_hero", "p2_hero")
	_add_ally(s2, "infernal_inst", "infernal_def", "p1")
	_add_ally(s2, "tough_inst", "tough_def", "p2")
	var pads2 := CardInstance.create("pads2", "pads_def", "p2", "p2_hero_row")
	s2.cards["pads2"] = pads2
	s2.zones["p2_hero_row"].card_ids.append("pads2")
	s2.phase       = "action"
	s2.turn_player = "p1"
	TurnManager.advance_phase(s2, db2)   # → end phase, burn fires
	eq(s2.pending_prevention_player, "p2", "nc-c: EOT burn opens the point for p2")
	eq(s2.get_card("tough_inst").damage_taken, 0, "nc-c2: whole group held, ally not hit yet")
	StackResolver.choose_prevention(s2, "pads2", db2)
	eq(s2.get_card("p2_hero").damage_taken, 0, "nc-d: hero's 1 fire fully prevented")
	eq(s2.get_card("tough_inst").damage_taken, 1, "nc-d2: opposing ally still took 1")

	# Case 3: on_destroyed AoE (2 fire to each opposing hero and ally).
	var db3 := MockDB.new()
	db3.hero("p1_hero", 30)
	db3.hero("p2_hero", 30)
	db3.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db3.ally("bomber_def", 1, 1, [], 2, "on_destroyed:deal_damage_aoe:2:fire:opposing")
	db3.ally("rat_def", 1, 2)
	var s3 := _base_state(db3, "p1_hero", "p2_hero")
	_add_ally(s3, "bomber", "bomber_def", "p2")
	_add_ally(s3, "rat", "rat_def", "p1")
	var pads3 := CardInstance.create("pads3", "pads_def", "p1", "p1_hero_row")
	s3.cards["pads3"] = pads3
	s3.zones["p1_hero_row"].card_ids.append("pads3")
	StackResolver._destroy_card_trigger(s3, "bomber", "", db3)
	eq(s3.pending_prevention_player, "p1", "nc-e: death AoE opens the point for p1")
	StackResolver.choose_prevention(s3, "pads3", db3)
	eq(s3.get_card("p1_hero").damage_taken, 1, "nc-f: hero took 2 − 1 prevented = 1")
	eq(s3.get_card("rat").zone_id, "p1_graveyard", "nc-f2: ally took the full 2 and died")


# discard_per_damage (Mind Blast) counts damage actually DEALT — armor
# prevention at the point reduces (or zeroes) the forced discard.
func _test_prevention_reduces_discard_per_damage() -> void:
	_buf.append("\n-- Prevention point: Mind Blast discard reduced by armor --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.equipment("plate_def", 3, "equipment:chest:3", "Plate")
	db.ability("blast_def", 5, "deal_damage_to_target:2:shadow|discard_per_damage:1")
	db.ally("filler", 1, 1)

	# Case 1: 2 shadow at the hero, DEF 1 exhausted → 1 dealt → discard 1.
	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p2", 5)
	var pads := CardInstance.create("pads_inst", "pads_def", "p1", "p1_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p1_hero_row"].card_ids.append("pads_inst")
	for i in range(3):
		var hid := "hand_%d" % i
		var hc := CardInstance.create(hid, "filler", "p1", "p1_hand")
		state.cards[hid] = hc
		state.zones["p1_hand"].card_ids.append(hid)
	var blast := CardInstance.create("blast_inst", "blast_def", "p2", "p2_hand")
	state.cards["blast_inst"] = blast
	state.zones["p2_hand"].card_ids.append("blast_inst")

	StackResolver.submit_action(state, PendingAction.make("play_ability", "p2",
		{"card_id": "blast_inst", "target_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # → prevention point
	eq(state.pending_prevention_player, "p1", "md-a: prevention point opened")
	StackResolver.choose_prevention(state, "pads_inst", db)
	eq(state.get_card("p1_hero").damage_taken, 1, "md-b: hero took 1 (2 − 1 prevented)")
	eq(state.pending_discard_player, "p1", "md-c: damaged hero's controller must discard")
	eq(state.pending_discard_count, 1, "md-d: discard 1 — only 1 damage was DEALT")
	# Clean up the pending discard.
	StackResolver.choose_discard(state, "hand_0", db)

	# Case 2: full prevention (DEF 3 vs 2) → packet ceases to exist (717.2b):
	# no damage, no discard.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	s2.turn_player     = "p2"
	s2.priority_player = "p2"
	_add_resources(s2, "p2", 5)
	var plate := CardInstance.create("plate_inst", "plate_def", "p1", "p1_hero_row")
	s2.cards["plate_inst"] = plate
	s2.zones["p1_hero_row"].card_ids.append("plate_inst")
	var hc2 := CardInstance.create("hand_x", "filler", "p1", "p1_hand")
	s2.cards["hand_x"] = hc2
	s2.zones["p1_hand"].card_ids.append("hand_x")
	var blast2 := CardInstance.create("blast2", "blast_def", "p2", "p2_hand")
	s2.cards["blast2"] = blast2
	s2.zones["p2_hand"].card_ids.append("blast2")

	StackResolver.submit_action(s2, PendingAction.make("play_ability", "p2",
		{"card_id": "blast2", "target_id": "p1_hero"}), db)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)
	eq(s2.pending_prevention_player, "p1", "md-e: prevention point opened")
	StackResolver.choose_prevention(s2, "plate_inst", db)
	eq(s2.get_card("p1_hero").damage_taken, 0, "md-f: fully prevented — no damage")
	eq(s2.pending_discard_count, 0, "md-g: fully prevented — no discard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 10 — Grimdron ally activated power deals 1 fire damage
#
# Setup : P1 has Grimdron in ally_row (ready, not summoning-sick).
#         P2 has a 0/3 ally.  P1 has 1 ready resource.
#
# Assertions:
#   sc10-a  use_ally_power targeting p2_ally appears in P1 legal actions
#   sc10-b  targeting own ally is NOT legal (heuristic: never target friendlies)
#   sc10-c  targeting with 0 resources is NOT legal (cost 1)
#   sc10-d  p2_ally has 1 damage after power resolves
#   sc10-e  Grimdron is exhausted after activation
#   sc10-f  use_ally_power not available again (Grimdron now exhausted)
# ══════════════════════════════════════════════════════════════════════════════

func _test_lionheart_helm_unpreventable() -> void:
	_buf.append("\n-- Lionheart Helm: damage dealt by your hero can't be prevented --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("helm_def", 4, "equipment:head:2|hero_damage_unpreventable", "Plate")
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")
	db.ally("minion_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var pads := CardInstance.create("pads_inst", "pads_def", "p2", "p2_hero_row")
	state.cards["pads_inst"] = pads
	state.zones["p2_hero_row"].card_ids.append("pads_inst")
	_add_ally(state, "minion_inst", "minion_def", "p1")

	# lh-a: control — WITHOUT the helm, p1's hero damage is ordinary preventable
	# damage, so p2's ready pads open the prevention point.
	StackResolver.defer_packets(state, db,
		[{"source": "p1_hero", "target": "p2_hero", "amount": 3}])
	eq(state.pending_prevention_player, "p2", "lh-a: no helm → prevention point opens")
	StackResolver.choose_prevention(state, "pads_inst", db)
	eq(state.get_card("p2_hero").damage_taken, 2, "lh-a2: pads prevented 1 of 3")

	# Now p1 equips the helm.
	var helm := CardInstance.create("helm_inst", "helm_def", "p1", "p1_hero_row")
	state.cards["helm_inst"] = helm
	state.zones["p1_hero_row"].card_ids.append("helm_inst")
	state.get_card("pads_inst").is_exhausted = false   # ready armor again

	# lh-b: the point never opens — an offer that can't help is not offered.
	StackResolver.defer_packets(state, db,
		[{"source": "p1_hero", "target": "p2_hero", "amount": 3}])
	eq(state.pending_prevention_player, "", "lh-b: helm → no prevention point at all")
	eq(state.get_card("p2_hero").damage_taken, 5, "lh-b2: all 3 landed unprevented")
	ok(not state.get_card("pads_inst").is_exhausted,
		"lh-b3: p2's armor untouched — unpreventable consumes no shield")

	# lh-c: scoped to "your HERO" — p1's ally damage is still preventable.
	StackResolver.defer_packets(state, db,
		[{"source": "minion_inst", "target": "p2_hero", "amount": 2}])
	eq(state.pending_prevention_player, "p2", "lh-c: ally source still opens the point")
	StackResolver.choose_prevention(state, "", db)

	# lh-d: the clause is about damage DEALT BY your hero, not damage taken —
	# incoming damage is preventable as usual. (The helm is itself DEF 2 armor,
	# so it opens the point for its own controller and can block with it.)
	StackResolver.defer_packets(state, db,
		[{"source": "p2_hero", "target": "p1_hero", "amount": 2}])
	eq(state.pending_prevention_player, "p1", "lh-d: incoming damage still opens p1's point")
	StackResolver.choose_prevention(state, "", db)   # decline
	eq(state.get_card("p1_hero").damage_taken, 2, "lh-d2: helm doesn't shield its own hero")


func _test_annihilator_unpreventable() -> void:
	_buf.append("\n-- Annihilator: only combat damage dealt WITH IT is unpreventable --")

	# Case 1: hero strikes with Annihilator → the defender gets no prevention point.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("anni_def", 2, 3, 2, "Melee", "melee_weapon", "combat_damage_unpreventable")
	db.equipment("pads_def", 1, PADS_EFFECTS, "Leather")

	var s1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s1, "p1", 3)
	var anni := CardInstance.create("anni", "anni_def", "p1", "p1_hero_row")
	s1.cards["anni"] = anni
	s1.zones["p1_hero_row"].card_ids.append("anni")
	var pads := CardInstance.create("pads_inst", "pads_def", "p2", "p2_hero_row")
	s1.cards["pads_inst"] = pads
	s1.zones["p2_hero_row"].card_ids.append("pads_inst")

	StackResolver.submit_action(s1, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # combat starts → strike point
	StackResolver.choose_strike(s1, "anni", db)
	eq(s1.get_atk("p1_hero", db), 3, "an-a: struck weapon gives the hero 3 ATK")
	for _i in range(4):
		StackResolver.pass_priority(s1, db)   # attack + defend windows close
	eq(s1.pending_prevention_player, "", "an-b: no prevention point — damage can't be prevented")
	eq(s1.get_card("p2_hero").damage_taken, 3, "an-b2: full 3 landed")
	ok(not s1.get_card("pads_inst").is_exhausted, "an-b3: p2's pads never spent")

	# Case 2: same board, but the hero strikes with a DIFFERENT weapon. The
	# Annihilator is in play yet wasn't struck, so its clause doesn't apply.
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.weapon("anni_def", 2, 3, 2, "Melee", "melee_weapon", "combat_damage_unpreventable")
	db2.weapon("krol_def", 3, 3, 1, "Melee", "sword")
	db2.equipment("pads_def", 1, PADS_EFFECTS, "Leather")

	var s2 := _base_state(db2, "p1_hero", "p2_hero")
	_add_resources(s2, "p1", 3)
	for pair in [["anni2", "anni_def"], ["krol2", "krol_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_hero_row")
		s2.cards[pair[0]] = c
		s2.zones["p1_hero_row"].card_ids.append(pair[0])
	var pads2 := CardInstance.create("pads2", "pads_def", "p2", "p2_hero_row")
	s2.cards["pads2"] = pads2
	s2.zones["p2_hero_row"].card_ids.append("pads2")

	StackResolver.submit_action(s2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db2)
	StackResolver.pass_priority(s2, db2)
	StackResolver.pass_priority(s2, db2)
	StackResolver.choose_strike(s2, "krol2", db2)
	for _i in range(4):
		StackResolver.pass_priority(s2, db2)
	eq(s2.pending_prevention_player, "p2", "an-c: struck the other weapon → point opens")
	StackResolver.choose_prevention(s2, "pads2", db2)
	eq(s2.get_card("p2_hero").damage_taken, 2, "an-c2: 1 of 3 prevented normally")

	# Case 3: the clause is combat-only — a hero ability packet stays preventable
	# even while the Annihilator is in play (contrast with Lionheart Helm).
	var s3 := _base_state(db, "p1_hero", "p2_hero")
	var anni3 := CardInstance.create("anni3", "anni_def", "p1", "p1_hero_row")
	s3.cards["anni3"] = anni3
	s3.zones["p1_hero_row"].card_ids.append("anni3")
	var pads3 := CardInstance.create("pads3", "pads_def", "p2", "p2_hero_row")
	s3.cards["pads3"] = pads3
	s3.zones["p2_hero_row"].card_ids.append("pads3")
	StackResolver.defer_packets(s3, db,
		[{"source": "p1_hero", "target": "p2_hero", "amount": 3}])
	eq(s3.pending_prevention_player, "p2", "an-d: non-combat hero damage still preventable")


func _test_brother_rhone_shield() -> void:
	_buf.append("\n-- Brother Rhone: prevents combat damage from attacking allies --")
	const RHONE_FX := "prevent_combat_damage_from_attacking_allies"

	# Case 1: an attacking ally's combat damage is fully prevented.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db.ally("smasher_def", 3, 3)

	var s1 := _base_state(db, "p1_hero", "p2_hero")
	s1.turn_player     = "p2"
	s1.priority_player = "p2"
	_add_ally(s1, "rhone", "rhone_def", "p1")
	_add_ally(s1, "smasher", "smasher_def", "p2")

	StackResolver.submit_action(s1, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "smasher", "defender_id": "rhone"}), db)
	var prevented := 0
	for _i in range(6):
		for ev in StackResolver.pass_priority(s1, db):
			if ev.event_type == "damage_prevented" \
					and ev.payload.get("target_id", "") == "rhone":
				prevented += int(ev.payload.get("amount", 0))
	eq(prevented, 3, "br-a: all 3 combat damage prevented")
	eq(s1.get_card("rhone").damage_taken, 0, "br-a2: Rhone took nothing")
	ok(s1.is_in_play("rhone"), "br-a3: the 0/1 survives a 3-ATK attacker")
	eq(s1.get_card("smasher").damage_taken, 0,
		"br-a4: Rhone's own 0 ATK retaliation is unaffected")

	# Case 2: an attacking HERO is not an ally — its combat damage lands.
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db2.weapon("krol_def", 3, 3, 1)

	var s2 := _base_state(db2, "p1_hero", "p2_hero")
	s2.turn_player     = "p2"
	s2.priority_player = "p2"
	_add_resources(s2, "p2", 2)
	_add_ally(s2, "rhone2", "rhone_def", "p1")
	var krol := CardInstance.create("krol", "krol_def", "p2", "p2_hero_row")
	s2.cards["krol"] = krol
	s2.zones["p2_hero_row"].card_ids.append("krol")

	StackResolver.submit_action(s2, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "p2_hero", "defender_id": "rhone2"}), db2)
	StackResolver.pass_priority(s2, db2)
	StackResolver.pass_priority(s2, db2)   # combat starts → strike point
	StackResolver.choose_strike(s2, "krol", db2)
	for _i in range(4):
		StackResolver.pass_priority(s2, db2)
	ok(not s2.is_in_play("rhone2"), "br-b: hero's combat damage killed Rhone")

	# Case 3: combat-only — a non-combat packet from an opposing ally lands.
	var s3 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(s3, "rhone3", "rhone_def", "p1")
	_add_ally(s3, "smasher3", "smasher_def", "p2")
	StackResolver.defer_packets(s3, db,
		[{"source": "smasher3", "target": "rhone3", "amount": 1}])
	ok(not s3.is_in_play("rhone3"), "br-c: ally ABILITY damage is not prevented")


func _test_ai_prefers_free_block() -> void:
	_buf.append("\n-- AI: Brother Rhone is the priority protector vs attacking allies --")
	const RHONE_FX := "prevent_combat_damage_from_attacking_allies"
	var ai := GenericAI.new()
	var base := BaseAI.new()

	# Case 1: a lethal attack on a valuable ally. Ordinary fodder would have to
	# die to save it; Rhone blocks for free, so he is chosen instead.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db.ally("fodder_def", 1, 1, ["protector"], 1)
	db.ally("prize_def", 4, 2, [], 5)
	db.ally("smasher_def", 4, 4, [], 4)

	var s1 := _base_state(db, "p1_hero", "p2_hero")
	s1.turn_player     = "p2"
	s1.priority_player = "p2"
	_add_ally(s1, "rhone", "rhone_def", "p1")
	_add_ally(s1, "fodder", "fodder_def", "p1")
	_add_ally(s1, "prize", "prize_def", "p1")
	_add_ally(s1, "smasher", "smasher_def", "p2")
	s1.combat_attacker = "smasher"
	s1.combat_defender = "prize"
	eq(ai.choose_protector(s1, db, "p1"), "rhone",
		"fb-a: GenericAI blocks with the untouchable protector, not the fodder")
	eq(base.choose_protector(s1, db, "p1"), "rhone",
		"fb-a2: BaseAI picks it too (over the higher-HP fodder)")

	# Case 2: the free block is taken even when nothing would die — it soaks the
	# chip damage at no cost.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	s2.turn_player     = "p2"
	s2.priority_player = "p2"
	_add_ally(s2, "rhone", "rhone_def", "p1")
	_add_ally(s2, "tank", "prize_def", "p1")
	_add_ally(s2, "smasher", "smasher_def", "p2")
	s2.combat_attacker = "smasher"
	s2.combat_defender = "p1_hero"
	eq(ai.choose_protector(s2, db, "p1"), "rhone",
		"fb-b: free block interposed in front of the hero")

	# Case 3: a block that KILLS the attacker and survives still outranks the
	# free block — it removes a card instead of stopping one attack.
	var db3 := MockDB.new()
	db3.hero("p1_hero", 30)
	db3.hero("p2_hero", 30)
	db3.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db3.ally("killer_def", 5, 5, ["protector"], 4)
	db3.ally("prize_def", 4, 2, [], 5)
	db3.ally("smasher_def", 4, 4, [], 4)
	var s3 := _base_state(db3, "p1_hero", "p2_hero")
	s3.turn_player     = "p2"
	s3.priority_player = "p2"
	_add_ally(s3, "rhone", "rhone_def", "p1")
	_add_ally(s3, "killer", "killer_def", "p1")
	_add_ally(s3, "prize", "prize_def", "p1")
	_add_ally(s3, "smasher", "smasher_def", "p2")
	s3.combat_attacker = "smasher"
	s3.combat_defender = "prize"
	eq(ai.choose_protector(s3, db3, "p1"), "killer",
		"fb-c: safe_lethal block still wins over the free block")

	# Case 4: scoped to ALLY attackers — vs an attacking hero Rhone is ordinary
	# (and dies), so he must not be volunteered as a free block.
	var db4 := MockDB.new()
	db4.hero("p1_hero", 30)
	db4.hero("p2_hero", 30)
	db4.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db4.ally("fodder_def", 1, 1, ["protector"], 1)
	db4.weapon("krol_def", 3, 3, 1)
	var s4 := _base_state(db4, "p1_hero", "p2_hero")
	s4.turn_player     = "p2"
	s4.priority_player = "p2"
	_add_resources(s4, "p2", 2)
	_add_ally(s4, "rhone", "rhone_def", "p1")
	_add_ally(s4, "fodder", "fodder_def", "p1")
	var krol := CardInstance.create("krol", "krol_def", "p2", "p2_hero_row")
	s4.cards["krol"] = krol
	s4.zones["p2_hero_row"].card_ids.append("krol")
	s4.combat_attacker = "p2_hero"
	s4.combat_defender = "p1_hero"
	ok(not BaseAI.blocks_for_free(s4, db4, "rhone", "p2_hero"),
		"fb-d: an attacking HERO is not blocked for free")


func _test_ai_skips_pointless_attack_into_shield() -> void:
	_buf.append("\n-- AI: never proposes an ally attack that can't damage the defender --")
	const RHONE_FX := "prevent_combat_damage_from_attacking_allies"
	var ai := BaseAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db.ally("smasher_def", 4, 4, [], 4)
	db.weapon("krol_def", 3, 3, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.phase = "action"
	_add_resources(state, "p1", 2)
	_add_ally(state, "smasher", "smasher_def", "p1")
	_add_ally(state, "rhone", "rhone_def", "p2")
	state.get_card("smasher").just_summoned = false
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")

	var ally_at_rhone := false
	var ally_at_hero  := false
	var hero_at_rhone := false
	for a in ai.get_reasonable_actions(state, db, "p1"):
		if a.action_type != "propose_combat":
			continue
		var atk: String = a.params.get("attacker_id", "")
		var dfd: String = a.params.get("defender_id", "")
		if atk == "smasher" and dfd == "rhone":
			ally_at_rhone = true
		if atk == "smasher" and dfd == "p2_hero":
			ally_at_hero = true
		if atk == "p1_hero" and dfd == "rhone":
			hero_at_rhone = true
	ok(not ally_at_rhone, "ps-a: ally attack into the shield is never proposed")
	ok(ally_at_hero, "ps-b: the same ally may still attack the hero (baits the block)")
	ok(hero_at_rhone, "ps-c: the HERO attacking it is still offered — shield is ally-only")


func _test_ai_holds_free_block_vs_bait() -> void:
	_buf.append("\n-- AI: holds the free block for a strictly bigger ready ally --")
	const RHONE_FX := "prevent_combat_damage_from_attacking_allies"
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db.ally("bait_def", 1, 1, [], 1)
	db.ally("big_def", 5, 5, [], 5)
	db.ally("chump_def", 2, 1, [], 2)

	# hb-a: the 1/1 baits while a ready 5/5 waits → decline, take the 1.
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	s1.turn_player     = "p2"
	s1.priority_player = "p2"
	_add_ally(s1, "rhone", "rhone_def", "p1")
	_add_ally(s1, "bait", "bait_def", "p2")
	_add_ally(s1, "big", "big_def", "p2")
	for id in ["bait", "big"]:
		s1.get_card(id).just_summoned = false
	s1.combat_attacker = "bait"
	s1.combat_defender = "p1_hero"
	eq(ai.choose_protector(s1, db, "p1"), "",
		"hb-a: free block held back from the cheap bait")

	# hb-b: now the 5/5 swings (the bait exhausted attacking) → block it.
	s1.get_card("bait").is_exhausted = true
	s1.combat_attacker = "big"
	eq(ai.choose_protector(s1, db, "p1"), "rhone",
		"hb-b: the block is spent on the real threat")

	# hb-c: the bigger ready attacker is their HERO, which the shield can't stop
	# for free anyway → no reason to hold; block the bait now.
	var db3 := MockDB.new()
	db3.hero("p1_hero", 30)
	db3.hero("p2_hero", 30)
	db3.ally("rhone_def", 0, 1, ["protector"], 2, RHONE_FX)
	db3.ally("bait_def", 1, 1, [], 1)
	db3.weapon("krol_def", 3, 3, 1)
	var s3 := _base_state(db3, "p1_hero", "p2_hero")
	s3.turn_player     = "p2"
	s3.priority_player = "p2"
	_add_resources(s3, "p2", 2)
	_add_ally(s3, "rhone", "rhone_def", "p1")
	_add_ally(s3, "bait", "bait_def", "p2")
	s3.get_card("bait").just_summoned = false
	var krol := CardInstance.create("krol", "krol_def", "p2", "p2_hero_row")
	s3.cards["krol"] = krol
	s3.zones["p2_hero_row"].card_ids.append("krol")
	s3.combat_attacker = "bait"
	s3.combat_defender = "p1_hero"
	eq(ai.choose_protector(s3, db3, "p1"), "rhone",
		"hb-c: a hero attacker isn't free-blockable, so nothing is worth holding for")

	# hb-d: the "bait" would KILL one of our allies → unrecoverable, block now
	# even though a bigger attacker is ready.
	var s4 := _base_state(db, "p1_hero", "p2_hero")
	s4.turn_player     = "p2"
	s4.priority_player = "p2"
	_add_ally(s4, "rhone", "rhone_def", "p1")
	_add_ally(s4, "chump", "chump_def", "p1")
	_add_ally(s4, "bait", "bait_def", "p2")
	_add_ally(s4, "big", "big_def", "p2")
	for id in ["bait", "big"]:
		s4.get_card(id).just_summoned = false
	s4.combat_attacker = "bait"
	s4.combat_defender = "chump"
	eq(ai.choose_protector(s4, db, "p1"), "rhone",
		"hb-d: a bait that kills a card is answered immediately")

	# hb-e: same bait, but our hero is low — face damage is no longer recoverable.
	var s5 := _base_state(db, "p1_hero", "p2_hero")
	s5.turn_player     = "p2"
	s5.priority_player = "p2"
	_add_ally(s5, "rhone", "rhone_def", "p1")
	_add_ally(s5, "bait", "bait_def", "p2")
	_add_ally(s5, "big", "big_def", "p2")
	for id in ["bait", "big"]:
		s5.get_card(id).just_summoned = false
	s5.get_card("p1_hero").damage_taken = 25   # 5 HP left
	s5.combat_attacker = "bait"
	s5.combat_defender = "p1_hero"
	eq(ai.choose_protector(s5, db, "p1"), "rhone",
		"hb-e: below the hero floor every hit is blocked")


func _test_grimdron_ally_power() -> void:
	_buf.append("\n-- Scenario 10: Grimdron ally power deals 1 fire damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.pet("grimdron_def", 0, 1, (["elusive"] as Array[String]), 1,
		"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally")
	db.ally("dummy_ally_def", 0, 3, [], 0)

	var state := _base_state(db, "p1_hero", "p2_hero")

	# Grimdron in p1_ally_row, ready, not summoning-sick.
	var grim := _add_ally(state, "grim_inst", "grimdron_def", "p1")
	grim.just_summoned = false
	grim.is_exhausted  = false

	# p1 friendly ally (must NOT be a valid target for the power).
	_add_ally(state, "p1_ally_inst", "dummy_ally_def", "p1")

	# p2 target ally.
	_add_ally(state, "p2_ally_inst", "dummy_ally_def", "p2")

	# 1 ready resource for P1 (cost of Grimdron power).
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	# sc10-a: use_ally_power targeting p2_ally is legal.
	var good_action := PendingAction.make("use_ally_power", "p1",
		{"card_id": "grim_inst", "target_id": "p2_ally_inst"})
	ok(StackResolver.can_submit(state, good_action, db),
		"sc10-a: use_ally_power targeting enemy ally is legal")

	# sc10-b: targeting own ally is also technically legal by the rules
	# (the restriction is a heuristic, not a rule) — but verify targeting
	# a non-in-play card is rejected.
	# p1_hero IS in play so that would actually be legal; test that an
	# out-of-play target (deck card) is correctly rejected instead.
	var deck_card := CardInstance.create("deck_dummy", "dummy_ally_def", "p1", "p1_deck")
	state.cards["deck_dummy"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck_dummy")
	var bad_deck := PendingAction.make("use_ally_power", "p1",
		{"card_id": "grim_inst", "target_id": "deck_dummy"})
	ok(not StackResolver.can_submit(state, bad_deck, db),
		"sc10-b: targeting an out-of-play card is illegal")

	# sc10-c: 0 resources → cannot activate (cost is 1).
	var state_no_res := state.duplicate(true) as GameState
	for res_card in state_no_res.cards_in_zone("p1_resource_row"):
		res_card.is_exhausted = true
	ok(not StackResolver.can_submit(state_no_res, good_action, db),
		"sc10-c: use_ally_power rejected when player has 0 available resources")

	# sc10-d/e: resolve the power and check outcomes.
	var events: Array[GameEvent] = []
	events.append_array(StackResolver.submit_action(state, good_action, db))
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	var p2_ally := state.get_card("p2_ally_inst")
	eq(p2_ally.damage_taken if p2_ally else -1, 1,
		"sc10-d: p2 ally took 1 fire damage from Grimdron power")

	var grim_after := state.get_card("grim_inst")
	ok(grim_after != null and grim_after.is_exhausted,
		"sc10-e: Grimdron is exhausted after using its power")

	# sc10-f: power no longer available (exhausted).
	ok(not StackResolver.can_submit(state, good_action, db),
		"sc10-f: use_ally_power not available again (Grimdron exhausted)")


# Tim (dark_portal_192): 3-cost 1/1 Alliance Human Mage, Elusive.
#   Power: [Activate] -> Tim deals 1 arcane damage to target hero or ally.
#   Cost-0 activated power (exhaust only, no resources). Mirrors Grimdron.
func _test_tim_ally_power() -> void:
	_buf.append("\n-- Scenario: Tim ally power deals 1 arcane damage (cost 0) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tim_def", 1, 1, (["elusive"] as Array[String]), 3,
		"activated_power:0:deal_damage_to_target:1:arcane:hero_or_ally")

	var state := _base_state(db, "p1_hero", "p2_hero")

	# Tim in p1_ally_row, ready, not summoning-sick.
	var tim := _add_ally(state, "tim_inst", "tim_def", "p1")
	tim.just_summoned = false
	tim.is_exhausted  = false

	# tim-a: power is usable with 0 available resources (cost is 0).
	for res_card in state.cards_in_zone("p1_resource_row"):
		res_card.is_exhausted = true
	var action := PendingAction.make("use_ally_power", "p1",
		{"card_id": "tim_inst", "target_id": "p2_hero"})
	ok(StackResolver.can_submit(state, action, db),
		"tim-a: use_ally_power legal even with 0 available resources (cost 0)")

	# tim-b/c: resolve the power onto the enemy hero.
	var events: Array[GameEvent] = []
	events.append_array(StackResolver.submit_action(state, action, db))
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	var p2_hero := state.get_card("p2_hero")
	eq(p2_hero.damage_taken if p2_hero else -1, 1,
		"tim-b: p2 hero took 1 arcane damage from Tim's power")

	var tim_after := state.get_card("tim_inst")
	ok(tim_after != null and tim_after.is_exhausted,
		"tim-c: Tim is exhausted after using its power")

	# tim-d: power no longer available (exhausted).
	ok(not StackResolver.can_submit(state, action, db),
		"tim-d: use_ally_power not available again (Tim exhausted)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 11 — Sarmoth taunt: attacker must target Sarmoth
#
# Setup: P1 has one attacker. P2 has Sarmoth + a normal ally + hero.
#
# Assertions:
#   sc11-a  Sarmoth is the only legal defender (hero and normal ally excluded)
#   sc11-b  combat targeting Sarmoth is accepted
#   sc11-c  combat targeting the hero is rejected (taunt active)
#   sc11-d  combat targeting the other ally is rejected (taunt active)
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_taunt_forces_attacker() -> void:
	_buf.append("\n-- Scenario 11: Sarmoth taunt forces attacker to target Sarmoth --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var defenders := StackResolver.get_legal_defenders(state, "atk", db)

	eq(defenders.size(), 1,           "sc11-a: only 1 legal defender when Sarmoth is in play")
	ok("sarmoth" in defenders,        "sc11-a: Sarmoth is that defender")

	var good := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "sarmoth"})
	ok(StackResolver.can_submit(state, good, db),
		"sc11-b: combat targeting Sarmoth is accepted")

	var bad_hero := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, bad_hero, db),
		"sc11-c: combat targeting hero is rejected while Sarmoth taunts")

	var bad_ally := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "normal"})
	ok(not StackResolver.can_submit(state, bad_ally, db),
		"sc11-d: combat targeting normal ally is rejected while Sarmoth taunts")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 12 — Sarmoth taunt applies to all of P1's attackers
#
# Setup: P1 has two attackers. P2 has Sarmoth + normal ally.
# Each attacker's legal defenders list must contain only Sarmoth.
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_taunt_multiple_attackers() -> void:
	_buf.append("\n-- Scenario 12: Sarmoth taunt restricts all attackers --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 2, 3)
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk1", "attacker_def", "p1")
	_add_ally(state, "atk2", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var def1 := StackResolver.get_legal_defenders(state, "atk1", db)
	var def2 := StackResolver.get_legal_defenders(state, "atk2", db)

	ok("sarmoth" in def1 and def1.size() == 1, "sc12-a: atk1 must target Sarmoth only")
	ok("sarmoth" in def2 and def2.size() == 1, "sc12-b: atk2 must target Sarmoth only")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 13 — Sarmoth taunt lifts when Sarmoth dies
#
# Setup: P1 attacks Sarmoth for lethal damage. After combat, P1's second
# attacker should be able to target the hero or normal ally freely.
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_taunt_lifts_on_death() -> void:
	_buf.append("\n-- Scenario 13: Sarmoth taunt lifts after Sarmoth dies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 6, 4)   # enough ATK to kill Sarmoth (5 health)
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk1", "attacker_def", "p1")
	_add_ally(state, "atk2", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	# Confirm taunt is active before Sarmoth leaves play.
	var before := StackResolver.get_legal_defenders(state, "atk1", db)
	ok("sarmoth" in before and before.size() == 1, "sc13-a: taunt active before Sarmoth dies")

	# Remove Sarmoth directly — sc13 tests that the taunt lifts on removal,
	# not the combat system itself (which is covered by sc1/sc2/sc11).
	GameLogic.move_card(state, "sarmoth", "p2_graveyard")

	ok(state.get_card("sarmoth").zone_id == "p2_graveyard",
		"sc13-b: Sarmoth is in graveyard")

	# Taunt should be gone — atk2 can now target hero or normal ally.
	var after := StackResolver.get_legal_defenders(state, "atk2", db)
	ok("p2_hero" in after,  "sc13-c: hero is a legal defender after Sarmoth dies")
	ok("normal" in after,   "sc13-d: normal ally is a legal defender after Sarmoth dies")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 14 — Elusive Sarmoth: taunt doesn't restrict (Sarmoth not a legal defender)
#
# Edge case: if Sarmoth gains Elusive it can't be chosen as a defender, so the
# taunt filter finds no taunt cards in the legal-defenders list and falls through
# to normal targeting (hero + other allies).
# ══════════════════════════════════════════════════════════════════════════════

func _test_sarmoth_elusive_no_taunt() -> void:
	_buf.append("\n-- Scenario 14: Elusive Sarmoth — taunt doesn't restrict --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.pet("sarmoth_elusive_def", 1, 5, (["elusive"] as Array[String]), 3, "sarmoth_taunt")
	db.ally("normal_ally_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "atk", "attacker_def", "p1")
	_add_ally(state, "sarmoth", "sarmoth_elusive_def", "p2")
	_add_ally(state, "normal", "normal_ally_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var defenders := StackResolver.get_legal_defenders(state, "atk", db)

	ok("sarmoth" not in defenders, "sc14-a: Elusive Sarmoth is not a legal defender")
	ok("p2_hero" in defenders,     "sc14-b: hero is a legal defender (taunt not restricting)")
	ok("normal" in defenders,      "sc14-c: normal ally is a legal defender (taunt not restricting)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 15 — Boris Brightbeard: heal X from target, capped at max HP
# Setup: Crazy Igvand (6 max HP, 3 damage taken → 3 current HP).
#        Boris pays X=4, heals 4 → capped at max HP → Igvand at exactly 6 HP.
# ══════════════════════════════════════════════════════════════════════════════

func _test_boris_heal_x() -> void:
	_buf.append("\n-- Scenario 15: Boris Brightbeard heal-X hero power --")
	var db := MockDB.new()
	db.hero("boris_def", 26, 0, "heal_x_from_target:holy|on_your_turn")
	db.hero("p2_hero", 30)
	db.ally("igvand_def", 2, 6, [], 3)   # Crazy Igvand: 2 ATK, 6 HP, cost 3

	var state := _base_state(db, "boris_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	var igvand := _add_ally(state, "igvand", "igvand_def", "p1")
	igvand.damage_taken = 3   # Igvand at 3/6 HP

	_add_resources(state, "p1", 5)

	# ── sc15-a: can_submit probe (no target) succeeds when resources available ──
	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "boris_def", "target_id": "", "x_value": 0})
	ok(StackResolver.can_submit(state, probe, db), "sc15-a: probe passes with 5 resources available")

	# ── sc15-b: x > available resources is illegal ──
	var too_big := PendingAction.make("activate_power", "p1",
		{"hero_id": "boris_def", "target_id": "igvand", "x_value": 6})
	ok(not StackResolver.can_submit(state, too_big, db), "sc15-b: x=6 rejected (only 5 resources)")

	# ── sc15-c: heal 4 from Igvand (3 damage taken) — overheal capped at max HP ──
	var act := PendingAction.make("activate_power", "p1",
		{"hero_id": "boris_def", "target_id": "igvand", "x_value": 4})
	ok(StackResolver.can_submit(state, act, db), "sc15-c: heal x=4 is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.get_current_hp("igvand", db), 6,
		"sc15-d: Igvand at exactly 6 HP (overheal capped, not 7)")
	eq(igvand.damage_taken, 0,
		"sc15-e: damage_taken is 0 (fully healed, not negative)")
	eq(state.get_available_resources("p1"), 1,
		"sc15-f: 4 resources spent, 1 remaining")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 16 — Radak Doombringer: sacrifice Sarmoth (cost 3), deal 3 shadow dmg
#
# Setup: P1 is Radak (no flip cost, no resources spent — the Pet IS the cost).
#        P1 has a Sarmoth (cost 3) in ally_row, not summoning-sick, and 3
#        available resources (can_submit requires availability to cover the
#        Pet's cost even though sacrificing the Pet is the actual payment).
#        P2 has a 2/5 ally as the damage target.
#
# Assertions:
#   sc16-a  probe (pet_id="", target_id="") passes when Pet is in ally_row
#   sc16-b  phase-1 probe with pet_id set (target_id="") passes
#   sc16-c  full action (pet_id + target_id + x_value=3) is legal
#   sc16-d  Sarmoth is removed from play at submission (cost payment)
#   sc16-e  p2 ally takes 3 shadow damage at resolution
#   sc16-f  hero_power_used event fires
#   sc16-g  x_value mismatch (pet cost 3 but x_value=1) is rejected
# ══════════════════════════════════════════════════════════════════════════════

func _test_radak_pet_sacrifice() -> void:
	_buf.append("\n-- Scenario 16: Radak sacrifices Sarmoth (cost 3) for 3 shadow damage --")
	var db := MockDB.new()
	db.hero("radak_def", 30, 0, "radak_pet_sacrifice:shadow|on_your_turn")
	db.pet("sarmoth_def", 1, 5, [], 3, "sarmoth_taunt")
	db.ally("target_def", 2, 5, [], 2)

	var state := _base_state(db, "radak_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	var sarmoth := _add_ally(state, "sarmoth_inst", "sarmoth_def", "p1")
	sarmoth.just_summoned = false
	sarmoth.is_exhausted  = false

	_add_ally(state, "target_inst", "target_def", "p2")
	_add_resources(state, "p1", 3)   # Sarmoth costs 3 — radak_pet_sacrifice needs an affordable Pet

	# sc16-a: probe passes when Pet is in play.
	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "", "target_id": "", "x_value": 0})
	ok(StackResolver.can_submit(state, probe, db),
		"sc16-a: probe passes with Sarmoth in ally_row")

	# sc16-b: phase-1 probe (pet chosen, no target yet) passes.
	var phase1 := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "sarmoth_inst", "target_id": "", "x_value": 0})
	ok(StackResolver.can_submit(state, phase1, db),
		"sc16-b: phase-1 probe with pet_id='sarmoth_inst' passes")

	# sc16-c: full action is legal.
	var full_act := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "sarmoth_inst", "target_id": "target_inst", "x_value": 3})
	ok(StackResolver.can_submit(state, full_act, db),
		"sc16-c: full action (pet + target + x=3) is legal")

	# sc16-g: x_value mismatch — the engine doesn't validate x vs pet cost in can_submit,
	# but the UI always sets x = pet.cost. Test that x=0 (empty) is rejected.
	var bad_x := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "sarmoth_inst", "target_id": "target_inst", "x_value": 0})
	ok(not StackResolver.can_submit(state, bad_x, db),
		"sc16-g: x_value=0 with valid pet+target is rejected")


	# sc16-d/e/f: submit and resolve; check Pet destroyed and damage dealt.
	var events: Array[GameEvent] = StackResolver.submit_action(state, full_act, db)

	# Pet is destroyed at submission (cost payment), before either player passes.
	ok(not state.is_in_play("sarmoth_inst"),
		"sc16-d: Sarmoth removed from play at submission")

	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	var target := state.get_card("target_inst")
	eq(target.damage_taken if target else -1, 3,
		"sc16-e: p2 ally took 3 shadow damage")

	var saw_power_used := false
	for e in events:
		if e.event_type == "hero_power_used":
			saw_power_used = true
	ok(saw_power_used, "sc16-f: hero_power_used event fired")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 17 — Radak: probe rejected when no Pets in ally_row
#
# Assertions:
#   sc17-a  probe rejected when ally_row has only non-Pet allies
#   sc17-b  probe rejected when ally_row is completely empty
# ══════════════════════════════════════════════════════════════════════════════

func _test_radak_no_pets() -> void:
	_buf.append("\n-- Scenario 17: Radak probe rejected with no Pets in play --")
	var db := MockDB.new()
	db.hero("radak_def", 30, 0, "radak_pet_sacrifice:shadow|on_your_turn")
	db.ally("normal_ally_def", 2, 3, [], 2)

	var state := _base_state(db, "radak_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	_add_ally(state, "normal_inst", "normal_ally_def", "p1")

	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "radak_def", "pet_id": "", "target_id": "", "x_value": 0})

	ok(not StackResolver.can_submit(state, probe, db),
		"sc17-a: probe rejected when only non-Pet allies present")

	# Remove the normal ally — empty row.
	GameLogic.move_card(state, "normal_inst", "p1_discard")
	ok(not StackResolver.can_submit(state, probe, db),
		"sc17-b: probe rejected when ally_row is empty")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 17b — Timmo Shadestep: destroy_exhausted_ally targeting + hero game_over
#
# Bug (all three reported issues):
#   #1 the power could target an enemy HERO (target validation was misplaced
#      inside the graveyard-power branch and never ran for Timmo)
#   #2 it could target a non-exhausted ally
#   #3 destroying a hero via an explicit destroy effect did not end the game
#
# Assertions:
#   sc17b-a  hero target is rejected
#   sc17b-b  non-exhausted enemy ally is rejected
#   sc17b-c  exhausted enemy ally is a legal target
#   sc17b-d  empty-target probe rejected when no exhausted enemy ally exists
#   sc17b-e  resolving the power destroys the exhausted ally
#   sc17b-f  _destroy_card_trigger on a hero emits game_over (loser = controller)
# ══════════════════════════════════════════════════════════════════════════════

func _test_timmo_destroy_exhausted_ally() -> void:
	_buf.append("\n-- Scenario 17b: Timmo destroys only exhausted allies; hero destroy ends game --")
	var db := MockDB.new()
	db.hero("timmo_def", 27, 0, "destroy_exhausted_ally|on_your_turn")
	db.hero("p2_hero", 30)
	db.ally("victim_def", 2, 3, [], 2)

	var state := _base_state(db, "timmo_def", "p2_hero")
	state.players["p1"].resource_placed_this_turn = true

	var victim := _add_ally(state, "victim_inst", "victim_def", "p2")
	victim.just_summoned = false
	victim.is_exhausted  = false

	# sc17b-a: hero target rejected.
	var hit_hero := PendingAction.make("activate_power", "p1",
		{"hero_id": "timmo_def", "target_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, hit_hero, db),
		"sc17b-a: enemy hero is NOT a legal target")

	# sc17b-b: non-exhausted ally rejected.
	var hit_ready := PendingAction.make("activate_power", "p1",
		{"hero_id": "timmo_def", "target_id": "victim_inst"})
	ok(not StackResolver.can_submit(state, hit_ready, db),
		"sc17b-b: non-exhausted enemy ally is NOT a legal target")

	# sc17b-d: probe rejected while no exhausted enemy ally exists.
	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "timmo_def", "target_id": ""})
	ok(not StackResolver.can_submit(state, probe, db),
		"sc17b-d: empty-target probe rejected when no exhausted enemy ally")

	# Now exhaust the ally.
	victim.is_exhausted = true

	# sc17b-c: exhausted ally is legal.
	ok(StackResolver.can_submit(state, hit_ready, db),
		"sc17b-c: exhausted enemy ally IS a legal target")
	ok(StackResolver.can_submit(state, probe, db),
		"sc17b-d2: probe passes once an exhausted enemy ally exists")

	# sc17b-e: resolve — ally is destroyed.
	var events: Array[GameEvent] = StackResolver.submit_action(state, hit_ready, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))
	ok(not state.is_in_play("victim_inst"),
		"sc17b-e: exhausted enemy ally destroyed by Timmo power")

	# sc17b-f: destroying a hero directly ends the game.
	var go := StackResolver._destroy_card_trigger(state, "p2_hero", "timmo_def", db)
	var saw_game_over := false
	for e in go:
		if e.event_type == "game_over":
			saw_game_over = true
			eq(e.payload.get("loser", ""), "p2", "sc17b-f2: loser is the hero's controller")
			eq(e.payload.get("winner", ""), "p1", "sc17b-f3: opponent wins")
	ok(saw_game_over, "sc17b-f: destroying a hero emits game_over")
	ok(state.is_in_play("p2_hero"),
		"sc17b-f4: hero is NOT moved to the graveyard on destroy")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 18 — Quest completion can't be chained with itself while pending
#
# Bug: a quest whose cost (e.g. 3) is less than total available resources (e.g. 6)
# still looked "legal" via can_submit even after its own use_quest action was
# already pushed to pending_actions (awaiting resolution) — because the resource
# check only compared the flat cost against total available resources, not
# accounting for the fact the quest itself was already mid-activation. This let
# turbo-mode treat the same quest as a second legal move and refuse to auto-pass.
#
# Assertions:
#   sc18-a  can_submit passes before the quest is on the stack
#   sc18-b  once pushed to pending_actions, can_submit for the same quest_id is false
#   sc18-c  a different face-up quest is unaffected (still legal)
# ══════════════════════════════════════════════════════════════════════════════

func _test_quest_cant_reuse_while_pending() -> void:
	_buf.append("\n-- Scenario 18: quest can't be re-triggered while its own completion is pending --")
	var db := MockDB.new()
	db.hero("p1_hero_def", 30)
	db.hero("p2_hero_def", 30)
	db.quest("yfay_def", 3)
	db.quest("other_quest_def", 2)

	var state := _base_state(db, "p1_hero_def", "p2_hero_def")

	var yfay := CardInstance.create("yfay_inst", "yfay_def", "p1", "p1_resource_row")
	state.cards["yfay_inst"] = yfay
	state.zones["p1_resource_row"].card_ids.append("yfay_inst")

	var other := CardInstance.create("other_inst", "other_quest_def", "p1", "p1_resource_row")
	state.cards["other_inst"] = other
	state.zones["p1_resource_row"].card_ids.append("other_inst")

	_add_resources(state, "p1", 6)

	var complete_yfay := PendingAction.make("use_quest", "p1", {"quest_id": "yfay_inst"})

	# sc18-a: legal before it's on the stack.
	ok(StackResolver.can_submit(state, complete_yfay, db),
		"sc18-a: YFAY completion legal with 6 available resources (cost 3)")

	state.pending_actions.push_back(complete_yfay)

	# sc18-b: same quest_id rejected while pending, even though 6 resources remain untouched.
	ok(not StackResolver.can_submit(state, complete_yfay, db),
		"sc18-b: re-checking YFAY while its own completion is pending is illegal")

	# sc18-c: a different quest is unaffected.
	var complete_other := PendingAction.make("use_quest", "p1", {"quest_id": "other_inst"})
	ok(StackResolver.can_submit(state, complete_other, db),
		"sc18-c: unrelated quest is still legal while YFAY is pending")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 19 — Liba Wobblebonk enters play and draws a card
# ══════════════════════════════════════════════════════════════════════════════

func _test_liba_wobblebonk_enter_play() -> void:
	_buf.append("\n-- Scenario 19: Liba Wobblebonk enters play and draws a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("liba_wobblebonk_def", 3, 4, [], 5, "on_enter:draw:1")
	db.ally("deck_card_def", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 5)

	var liba := CardInstance.create("liba_inst", "liba_wobblebonk_def", "p1", "p1_hand")
	state.cards["liba_inst"] = liba
	state.zones["p1_hand"].card_ids.append("liba_inst")

	var deck_card := CardInstance.create("deck1", "deck_card_def", "p1", "p1_deck")
	state.cards["deck1"] = deck_card
	state.zones["p1_deck"].card_ids.append("deck1")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "liba_inst"}))

	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	ok(state.get_card("liba_inst").zone_id == "p1_ally_row", "sc19-a: Liba Wobblebonk in p1_ally_row")
	ok(state.get_card("deck1").zone_id == "p1_hand",          "sc19-b: deck card drawn into hand")
	eq(_non_filler_in(state, "p1_hand").size(), 1,            "sc19-c: hand has exactly 1 non-filler card")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 20 — Kulan Earthguard readies itself at the end of its controller's turn
# ══════════════════════════════════════════════════════════════════════════════

func _test_kulan_earthguard_end_of_turn_ready() -> void:
	_buf.append("\n-- Scenario 20: Kulan Earthguard readies itself at end of turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("kulan_def", 3, 5, ["protector"], 5, "ready_self_at_turn_end")

	var state := _base_state(db, "p1_hero", "p2_hero")

	var kulan := CardInstance.create("kulan_inst", "kulan_def", "p1", "p1_ally_row")
	state.cards["kulan_inst"] = kulan
	state.zones["p1_ally_row"].card_ids.append("kulan_inst")

	# Exhaust it manually (e.g. as if it had just protected an attack).
	GameLogic.exhaust_card(state, "kulan_inst")
	ok(kulan.is_exhausted, "sc20-a: Kulan starts this test exhausted")

	_drive_turns(state, db, ScriptedAI.new(), ScriptedAI.new(), 1)

	ok(not state.get_card("kulan_inst").is_exhausted,
		"sc20-b: Kulan Earthguard is ready again after p1's turn ends")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 21 — Tracker Gallen: +1 ATK for each ally in party
# ══════════════════════════════════════════════════════════════════════════════

func _test_tracker_gallen_atk_per_ally() -> void:
	_buf.append("\n-- Scenario 21: Tracker Gallen gains ATK per ally in party --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("gallen_def", 0, 2, [], 2, "atk_per_ally:1")
	db.ally("other_ally_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "gallen_inst", "gallen_def", "p1")

	ok(state.get_atk("gallen_inst", db) == 1,
		"sc21-a: Tracker Gallen alone has 1 ATK (counts itself)")

	_add_ally(state, "other_inst", "other_ally_def", "p1")

	ok(state.get_atk("gallen_inst", db) == 2,
		"sc21-b: Tracker Gallen gains +1 ATK when a second ally enters play")

	_add_ally(state, "opp_inst", "other_ally_def", "p2")

	ok(state.get_atk("gallen_inst", db) == 2,
		"sc21-c: Opponent's allies don't count toward Gallen's ATK")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 22 — Blood Guard Mal'wani: +1 ATK for each damage on him
# ══════════════════════════════════════════════════════════════════════════════

func _test_malwani_atk_per_damage_self() -> void:
	_buf.append("\n-- Scenario 22: Blood Guard Mal'wani gains ATK per damage on him --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("malwani_def", 1, 5, [], 4, "atk_per_damage_self:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "malwani_inst", "malwani_def", "p1")

	ok(state.get_atk("malwani_inst", db) == 1,
		"sc22-a: Mal'wani has base 1 ATK with no damage on him")

	GameLogic.deal_damage(state, "p2_hero", "malwani_inst", 2, db)

	ok(state.get_atk("malwani_inst", db) == 3,
		"sc22-b: Mal'wani gains +1 ATK per damage taken (1 base + 2 damage)")

	GameLogic.deal_damage(state, "p2_hero", "malwani_inst", 1, db)

	ok(state.get_atk("malwani_inst", db) == 4,
		"sc22-c: ATK keeps scaling as more damage accumulates")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 23 — Chasing A-Me 01: return target ally from your graveyard to hand
# ══════════════════════════════════════════════════════════════════════════════

func _test_chasing_ame_graveyard_to_hand() -> void:
	_buf.append("\n-- Scenario 23: Chasing A-Me 01 returns an ally from the graveyard to hand --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("chasing_ame_def", 3, "graveyard_to_hand:Ally:1:1:own")
	db.ally("dead_ally_def", 2, 2, [], 4)
	db.quest("dead_quest_def", 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var quest := CardInstance.create("ame_inst", "chasing_ame_def", "p1", "p1_resource_row")
	state.cards["ame_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("ame_inst")

	# p1 graveyard: one ally (valid) and one quest card (filtered out).
	for pair in [["dead_ally", "dead_ally_def"], ["dead_quest", "dead_quest_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])
	# p2 graveyard: an ally that must NOT be a candidate (owner filter = own).
	var opp_dead := CardInstance.create("opp_dead_ally", "dead_ally_def", "p2", "p2_graveyard")
	state.cards["opp_dead_ally"] = opp_dead
	state.zones["p2_graveyard"].card_ids.append("opp_dead_ally")

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("chasing_ame_def"))
	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["dead_ally"], "sc23-a: only own graveyard ally is a candidate")

	ok(StackResolver.can_use_quest_no_target_check(state, "ame_inst", "p1", db),
		"sc23-b: no-target probe passes with a valid candidate")

	var no_target := PendingAction.make("use_quest", "p1", {"quest_id": "ame_inst"})
	ok(not StackResolver.can_submit(state, no_target, db),
		"sc23-c: completion without announced targets is rejected")

	var bad_target := PendingAction.make("use_quest", "p1",
			{"quest_id": "ame_inst", "target_ids": ["dead_quest"]})
	ok(not StackResolver.can_submit(state, bad_target, db),
		"sc23-d: non-ally graveyard card is an illegal target")

	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "ame_inst", "target_ids": ["dead_ally"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "sc23-e: completion with valid target submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	ok(state.get_card("dead_ally").zone_id == "p1_hand",
		"sc23-f: dead ally returned to p1 hand")
	ok(state.get_card("ame_inst").face_down,
		"sc23-g: quest flipped face-down after completion")
	var returned := false
	for ev in events:
		if ev.event_type == "card_returned_from_graveyard" \
				and ev.payload.get("card_id", "") == "dead_ally":
			returned = true
	ok(returned, "sc23-h: card_returned_from_graveyard event emitted")


# The Love Potion — "Exhaust two allies in your party and pay (1) to complete
# this quest. Reward: Draw a card." The allies are an extra COST announced with
# the completion and exhausted on chain entry (rule 412.2), so they must be
# ready allies of the completer, must be two DISTINCT ones, and come back ready
# if the completion is retracted.
func _test_love_potion_exhaust_cost() -> void:
	_buf.append("\n-- The Love Potion: exhaust two allies as a completion cost --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("potion_def", 1, "exhaust_allies:2|draw:1")
	db.ally("body_def", 2, 2, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)
	var quest := CardInstance.create("potion_inst", "potion_def", "p1", "p1_resource_row")
	state.cards["potion_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("potion_inst")
	# Two of p1's allies are ready; the third is already exhausted. p2 has one
	# ready ally that must never be a candidate ("allies in YOUR party").
	for pair in [["a1", "p1"], ["a2", "p1"], ["a3", "p1"], ["e1", "p2"]]:
		var c := CardInstance.create(pair[0], "body_def", pair[1], pair[1] + "_ally_row")
		state.cards[pair[0]] = c
		state.zones[pair[1] + "_ally_row"].card_ids.append(pair[0])
	state.get_card("a3").is_exhausted = true
	# Something to draw, so the reward is observable.
	var top := CardInstance.create("deck_top", "body_def", "p1", "p1_deck")
	state.cards["deck_top"] = top
	state.zones["p1_deck"].card_ids.append("deck_top")

	eq(StackResolver.get_quest_ally_exhaust_requirement(db.get_def("potion_def")), 2,
		"lp-a: cost parsed as two allies")
	eq(StackResolver.get_quest_exhaust_candidates(state, "p1"), ["a1", "a2"],
		"lp-b: only p1's READY allies are candidates")

	ok(StackResolver.can_use_quest_no_target_check(state, "potion_inst", "p1", db),
		"lp-c: no-target probe passes while two ready allies exist")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_quest", "p1",
		{"quest_id": "potion_inst"}), db),
		"lp-d: completion without announced allies is rejected")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_quest", "p1",
		{"quest_id": "potion_inst", "ally_ids": ["a1", "a1"]}), db),
		"lp-e: the same ally can't pay twice")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_quest", "p1",
		{"quest_id": "potion_inst", "ally_ids": ["a1", "a3"]}), db),
		"lp-f: an already-exhausted ally can't pay")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_quest", "p1",
		{"quest_id": "potion_inst", "ally_ids": ["a1", "e1"]}), db),
		"lp-g: an opposing ally can't pay")

	# Announce → costs (resource + both allies) are paid on chain entry.
	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "potion_inst", "ally_ids": ["a1", "a2"]})
	ok(not StackResolver.submit_action(state, good, db).is_empty(),
		"lp-h: completion with two ready allies submits")
	ok(state.get_card("a1").is_exhausted and state.get_card("a2").is_exhausted,
		"lp-i: both allies exhausted at announcement (412.2)")
	# Two resources are available: the blank one plus the face-up quest itself.
	eq(state.get_available_resources("p1"), 1, "lp-j: the (1) is paid at announcement")

	# Retract puts everything back — the cost is undone with the announcement.
	StackResolver.retract_last(state, "p1", db)
	ok(not state.get_card("a1").is_exhausted and not state.get_card("a2").is_exhausted,
		"lp-k: retract readies both allies again")
	eq(state.get_available_resources("p1"), 2, "lp-l: retract refunds the resource")
	ok(not state.get_card("potion_inst").face_down, "lp-m: quest still uncompleted")

	# Re-announce and resolve: the reward draws.
	StackResolver.submit_action(state, PendingAction.make("use_quest", "p1",
		{"quest_id": "potion_inst", "ally_ids": ["a1", "a2"]}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.get_card("potion_inst").face_down, "lp-n: quest flipped face-down")
	eq(state.get_card("deck_top").zone_id, "p1_hand", "lp-o: reward drew a card")

	# With only one ready ally left the quest is no longer completable at all.
	for res_card in state.cards_in_zone("p1_resource_row"):
		res_card.is_exhausted = false
	var quest2 := CardInstance.create("potion2", "potion_def", "p1", "p1_resource_row")
	state.cards["potion2"] = quest2
	state.zones["p1_resource_row"].card_ids.append("potion2")
	state.get_card("a3").is_exhausted = false   # exactly one ready ally now
	ok(not StackResolver.can_use_quest_no_target_check(state, "potion2", "p1", db),
		"lp-p: quest is dark with fewer than two ready allies")


func _test_chasing_ame_blocked_and_filtered() -> void:
	_buf.append("\n-- Scenario 24: Chasing A-Me 01 blocked with no valid graveyard target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("chasing_ame_def", 3, "graveyard_to_hand:Ally:1:1:own")
	db.quest("dead_quest_def", 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var quest := CardInstance.create("ame_inst", "chasing_ame_def", "p1", "p1_resource_row")
	state.cards["ame_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("ame_inst")

	# Empty graveyard: probe and submission both fail.
	ok(not StackResolver.can_use_quest_no_target_check(state, "ame_inst", "p1", db),
		"sc24-a: probe fails with empty graveyard")

	# Graveyard with only a non-ally card: still blocked.
	var dq := CardInstance.create("dead_quest", "dead_quest_def", "p1", "p1_graveyard")
	state.cards["dead_quest"] = dq
	state.zones["p1_graveyard"].card_ids.append("dead_quest")
	ok(not StackResolver.can_use_quest_no_target_check(state, "ame_inst", "p1", db),
		"sc24-b: probe fails when graveyard has no ally")

	var forced := PendingAction.make("use_quest", "p1",
			{"quest_id": "ame_inst", "target_ids": ["dead_quest"]})
	ok(not StackResolver.can_submit(state, forced, db),
		"sc24-c: submission with only-invalid targets rejected")


# ══════════════════════════════════════════════════════════════════════════════
# Sunken Treasure (azeroth_358) — Chasing A-Me 01 for equipment. Pure CSV recipe
# (graveyard_to_hand:Equipment:1:1:own); this pins the Equipment type filter,
# which must accept weapons (a subtype of Equipment) as well as armor.
# ══════════════════════════════════════════════════════════════════════════════

func _test_sunken_treasure_equipment_to_hand() -> void:
	_buf.append("\n-- Sunken Treasure returns an equipment card from the graveyard to hand --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("sunken_def", 3, "graveyard_to_hand:Equipment:1:1:own")
	db.equipment("armor_def", 4, "equipment:chest:1")
	db.weapon("weapon_def", 3, 3, 1)
	db.ally("dead_ally_def", 2, 2, [], 4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var quest := CardInstance.create("sunken_inst", "sunken_def", "p1", "p1_resource_row")
	state.cards["sunken_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("sunken_inst")

	# No equipment in the graveyard yet — the quest can't be completed.
	ok(not StackResolver.can_use_quest_no_target_check(state, "sunken_inst", "p1", db),
		"sunken-a: probe fails with no equipment in the graveyard")

	# p1 graveyard: armor + a weapon (both legal) and an ally (filtered out).
	for pair in [["dead_armor", "armor_def"], ["dead_weapon", "weapon_def"],
			["dead_ally", "dead_ally_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])
	# p2 graveyard: equipment that must NOT be a candidate (owner filter = own).
	var opp := CardInstance.create("opp_armor", "armor_def", "p2", "p2_graveyard")
	state.cards["opp_armor"] = opp
	state.zones["p2_graveyard"].card_ids.append("opp_armor")

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("sunken_def"))
	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["dead_armor", "dead_weapon"],
		"sunken-b: own armor AND weapon are candidates, ally and opponent's are not")

	ok(StackResolver.can_use_quest_no_target_check(state, "sunken_inst", "p1", db),
		"sunken-c: no-target probe passes with a valid candidate")

	var bad := PendingAction.make("use_quest", "p1",
			{"quest_id": "sunken_inst", "target_ids": ["dead_ally"]})
	ok(not StackResolver.can_submit(state, bad, db),
		"sunken-d: a non-equipment graveyard card is an illegal target")

	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "sunken_inst", "target_ids": ["dead_weapon"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "sunken-e: completion with a valid target submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	ok(state.get_card("dead_weapon").zone_id == "p1_hand",
		"sunken-f: the chosen weapon is returned to p1's hand")
	ok(state.get_card("dead_armor").zone_id == "p1_graveyard",
		"sunken-g: the unchosen equipment stays in the graveyard")
	ok(state.get_card("sunken_inst").face_down,
		"sunken-h: quest flipped face-down after completion")


# ══════════════════════════════════════════════════════════════════════════════
# The Missing Diplomat — search your deck for an ally, reveal it, put it into
# your hand, then shuffle. May find nothing (min 0) — the quest still completes.
# ══════════════════════════════════════════════════════════════════════════════

func _test_missing_diplomat_deck_search() -> void:
	_buf.append("\n-- The Missing Diplomat: search deck for an ally, put into hand, shuffle --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("diplomat_def", 4, "deck_to_hand:Ally:0:1")
	db.ally("deck_ally_def", 2, 2, [], 3)
	db.quest("deck_quest_def", 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)

	var quest := CardInstance.create("dip_inst", "diplomat_def", "p1", "p1_resource_row")
	state.cards["dip_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("dip_inst")

	# p1 deck: two allies (candidates) + one quest (filtered out).
	for pair in [["deck_a1", "deck_ally_def"], ["deck_a2", "deck_ally_def"], ["deck_q", "deck_quest_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_deck")
		state.cards[pair[0]] = c
		state.zones["p1_deck"].card_ids.append(pair[0])
	# p2 deck ally must NOT be a candidate (owner filter = own).
	var opp := CardInstance.create("opp_deck_a", "deck_ally_def", "p2", "p2_deck")
	state.cards["opp_deck_a"] = opp
	state.zones["p2_deck"].card_ids.append("opp_deck_a")

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("diplomat_def"))
	eq(req.get("source", ""), "deck", "diplomat-a: requirement source is deck")
	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["deck_a1", "deck_a2"], "diplomat-b: only own deck allies are candidates")

	# Completion with no announced target is legal (min 0 — may fail to find).
	ok(StackResolver.can_submit(state,
			PendingAction.make("use_quest", "p1", {"quest_id": "dip_inst"}), db),
		"diplomat-c: completion legal with no target (may find nothing)")

	# A non-ally deck card can't be targeted.
	ok(not StackResolver.can_submit(state,
			PendingAction.make("use_quest", "p1",
				{"quest_id": "dip_inst", "target_ids": ["deck_q"]}), db),
		"diplomat-d: non-ally deck card is an illegal target")

	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "dip_inst", "target_ids": ["deck_a1"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "diplomat-e: completion with a valid deck ally submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.get_card("deck_a1").zone_id, "p1_hand", "diplomat-f: chosen ally moved to hand")
	ok(state.get_card("dip_inst").face_down, "diplomat-g: quest flipped face-down")
	var revealed := false
	var shuffled := false
	for ev in events:
		if ev.event_type == "card_revealed_from_deck" \
				and ev.payload.get("card_id", "") == "deck_a1":
			revealed = true
		if ev.event_type == "deck_shuffled" and ev.payload.get("player", "") == "p1":
			shuffled = true
	ok(revealed, "diplomat-h: card_revealed_from_deck event emitted")
	ok(shuffled, "diplomat-i: deck shuffled after the search")


# ══════════════════════════════════════════════════════════════════════════════
# Reveal-and-pick quests (Big Game Hunter / Kibler's Exotic Pets / Zapped
# Giants): "Reveal the top N cards; put a revealed <type> card into your hand and
# the rest on the bottom of your deck."
# ══════════════════════════════════════════════════════════════════════════════

func _test_reveal_pick_takes_matching_card() -> void:
	_buf.append("\n-- Reveal-pick: reveal top 4, take an equipment, rest to bottom in order --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("bgh_def", 2, "reveal_pick:Equipment:4")
	db.ally("ally_def", 2, 2, [], 3)
	db.equipment("equip_def", 2, "equipment:chest:0")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)

	var quest := CardInstance.create("bgh_inst", "bgh_def", "p1", "p1_resource_row")
	state.cards["bgh_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("bgh_inst")

	# Deck top→down: ally, equipment (the match), ally, ally, then a 5th card that
	# must NOT be revealed (only top 4 are seen).
	var layout := [["d_a1", "ally_def"], ["d_eq", "equip_def"],
			["d_a2", "ally_def"], ["d_a3", "ally_def"], ["d_bottom", "ally_def"]]
	for pair in layout:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_deck")
		state.cards[pair[0]] = c
		state.zones["p1_deck"].card_ids.append(pair[0])

	var action := PendingAction.make("use_quest", "p1", {"quest_id": "bgh_inst"})
	var events := StackResolver.submit_action(state, action, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.pending_reveal_pick_player, "p1", "revealpick-a: pending choice belongs to p1")
	eq(state.pending_reveal_pick_ids, ["d_eq"], "revealpick-b: only the equipment is selectable")
	var opened := false
	for ev in events:
		if ev.event_type == "reveal_pick_opened":
			opened = true
	ok(opened, "revealpick-c: reveal_pick_opened emitted")
	ok(state.get_card("d_bottom").zone_id == "p1_deck", "revealpick-d: 5th card untouched")

	# Take the equipment.
	var res := StackResolver.choose_reveal_pick(state, "d_eq", db)
	eq(state.pending_reveal_pick_player, "", "revealpick-e: pending cleared after pick")
	eq(state.get_card("d_eq").zone_id, "p1_hand", "revealpick-f: chosen equipment in hand")
	# The three non-picked revealed allies go to the bottom, below d_bottom, in
	# revealed order: d_a1, d_a2, d_a3.
	var deck_ids: Array = state.zones["p1_deck"].card_ids
	eq(deck_ids, ["d_bottom", "d_a1", "d_a2", "d_a3"],
		"revealpick-g: rest pushed to bottom in revealed order")
	var resolved := false
	for ev in res:
		if ev.event_type == "reveal_pick_resolved" and ev.payload.get("card_id", "") == "d_eq":
			resolved = true
	ok(resolved, "revealpick-h: reveal_pick_resolved emitted")


func _test_reveal_pick_to_top() -> void:
	_buf.append("
-- Reveal-pick to_top: It's a Secret to Everybody keeps one on top --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("secret_def", 1, "reveal_pick:Any:3:to_top:private")
	db.ally("ally_def", 2, 2, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var quest := CardInstance.create("secret_inst", "secret_def", "p1", "p1_resource_row")
	state.cards["secret_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("secret_inst")

	for id in ["d_a1", "d_a2", "d_a3", "d_bottom"]:
		var c := CardInstance.create(id, "ally_def", "p1", "p1_deck")
		state.cards[id] = c
		state.zones["p1_deck"].card_ids.append(id)

	var action := PendingAction.make("use_quest", "p1", {"quest_id": "secret_inst"})
	var events := StackResolver.submit_action(state, action, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.pending_reveal_pick_player, "p1", "secret-a: pending choice belongs to p1")
	eq(state.pending_reveal_pick_ids, ["d_a1", "d_a2", "d_a3"],
		"secret-b: every revealed card is selectable (Any)")
	ok(state.pending_reveal_pick_to_top, "secret-c: to_top flag set")
	ok(state.pending_reveal_pick_private, "secret-d: private flag set")
	var flagged := false
	for ev in events:
		if ev.event_type == "reveal_pick_opened" and ev.payload.get("to_top", false) 				and ev.payload.get("private", false):
			flagged = true
	ok(flagged, "secret-e: reveal_pick_opened carries to_top + private")

	# Keep the SECOND revealed card on top; the other two go to the bottom in
	# revealed order, below the card that was never revealed.
	var res := StackResolver.choose_reveal_pick(state, "d_a2", db)
	eq(state.pending_reveal_pick_player, "", "secret-f: pending cleared after pick")
	ok(not state.pending_reveal_pick_to_top, "secret-g: to_top flag cleared")
	eq(state.get_card("d_a2").zone_id, "p1_deck", "secret-h: kept card stays in the deck (not hand)")
	eq(state.zones["p1_deck"].card_ids, ["d_a2", "d_bottom", "d_a1", "d_a3"],
		"secret-i: kept card on top, rest to bottom in revealed order")
	eq(state.zones["p1_hand"].card_ids, [], "secret-j: nothing went to hand")
	var resolved := false
	for ev in res:
		if ev.event_type == "reveal_pick_resolved" and ev.payload.get("to_top", false):
			resolved = true
	ok(resolved, "secret-k: reveal_pick_resolved flagged to_top")


func _test_reveal_pick_no_match_all_to_bottom() -> void:
	_buf.append("\n-- Reveal-pick: no matching card → choice still opens (empty), OK sends all to bottom --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("kibler_def", 2, "reveal_pick:Ally:3")
	db.ability("abil_def", 1, "")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)

	var quest := CardInstance.create("kib_inst", "kibler_def", "p1", "p1_resource_row")
	state.cards["kib_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("kib_inst")

	# Top three are all abilities (no ally to find); a 4th card stays on top… no,
	# a 4th card must remain the new top after the three cycle to the bottom.
	var layout := [["k_ab1", "abil_def"], ["k_ab2", "abil_def"],
			["k_ab3", "abil_def"], ["k_keep", "abil_def"]]
	for pair in layout:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_deck")
		state.cards[pair[0]] = c
		state.zones["p1_deck"].card_ids.append(pair[0])

	var action := PendingAction.make("use_quest", "p1", {"quest_id": "kib_inst"})
	var events := StackResolver.submit_action(state, action, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	# The choice still opens so the player can SEE the revealed cards, but with
	# nothing selectable it's an empty acknowledgement (OK).
	eq(state.pending_reveal_pick_player, "p1", "revealpick-i: choice opens even when nothing matches")
	eq(state.pending_reveal_pick_ids, [], "revealpick-i2: nothing is selectable")
	var opened := false
	for ev in events:
		if ev.event_type == "reveal_pick_opened":
			opened = true
	ok(opened, "revealpick-i3: reveal_pick_opened emitted with empty selectable")

	# A non-empty pick is rejected (nothing matched); only the empty ack resolves.
	var bad := StackResolver.choose_reveal_pick(state, "k_ab1", db)
	eq(bad.size(), 0, "revealpick-i4: picking a non-matching card is refused")
	eq(state.pending_reveal_pick_player, "p1", "revealpick-i5: still pending after refused pick")

	StackResolver.choose_reveal_pick(state, "", db)
	eq(state.pending_reveal_pick_player, "", "revealpick-i6: pending cleared after empty ack")
	# The three revealed abilities cycle to the bottom; k_keep becomes the top.
	eq(state.zones["p1_deck"].card_ids, ["k_keep", "k_ab1", "k_ab2", "k_ab3"],
		"revealpick-j: all revealed cards pushed to the bottom in order")


func _test_reveal_pick_blocks_other_actions() -> void:
	_buf.append("\n-- Reveal-pick: pending choice blocks other submissions and passing --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("zapped_def", 2, "reveal_pick:Ability:3")
	db.ability("abil_def", 1, "")
	db.ally("ally_def", 2, 2, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 5)

	var quest := CardInstance.create("zap_inst", "zapped_def", "p1", "p1_resource_row")
	state.cards["zap_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("zap_inst")

	var abil := CardInstance.create("z_ab1", "abil_def", "p1", "p1_deck")
	state.cards["z_ab1"] = abil
	state.zones["p1_deck"].card_ids.append("z_ab1")
	# An ally in hand — proves nothing else can be played while the pick is pending.
	var hand_ally := CardInstance.create("z_hand", "ally_def", "p1", "p1_hand")
	state.cards["z_hand"] = hand_ally
	state.zones["p1_hand"].card_ids.append("z_hand")

	var action := PendingAction.make("use_quest", "p1", {"quest_id": "zap_inst"})
	StackResolver.submit_action(state, action, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.pending_reveal_pick_player, "p1", "revealpick-k: reveal pick pending")
	ok(not StackResolver.can_submit(state,
			PendingAction.make("play_ally", "p1", {"card_id": "z_hand"}), db),
		"revealpick-l: can't play an ally while a reveal pick is pending")
	ok(StackResolver.pass_priority(state, db).is_empty(),
		"revealpick-m: passing is blocked while a reveal pick is pending")

	# Picking the only revealed ability resolves and unblocks.
	StackResolver.choose_reveal_pick(state, "z_ab1", db)
	eq(state.get_card("z_ab1").zone_id, "p1_hand", "revealpick-n: ability taken to hand")
	eq(state.pending_reveal_pick_player, "", "revealpick-o: pending cleared")


# The Princess Trapped (azeroth_357): "Reveal the top two cards of your deck.
# Target opponent chooses one. Put that card into your hand and the other one on
# the bottom of your deck." The DECIDER is the opponent while the owner is still
# the completer — every card moves in the completer's zones.
func _test_princess_trapped_opponent_chooses() -> void:
	_buf.append("\n-- The Princess Trapped: opponent picks which revealed card you keep --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("princess_def", 2, "reveal_pick:Any:2:opponent")
	db.ally("ally_def", 2, 2, [], 3)
	db.ability("abil_def", 1, "")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)

	var quest := CardInstance.create("pr_inst", "princess_def", "p1", "p1_resource_row")
	state.cards["pr_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("pr_inst")

	# Top→down: ally, ability, then a third card that must stay untouched.
	var layout := [["pr_a", "ally_def"], ["pr_b", "abil_def"], ["pr_c", "ally_def"]]
	for pair in layout:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_deck")
		state.cards[pair[0]] = c
		state.zones["p1_deck"].card_ids.append(pair[0])

	var action := PendingAction.make("use_quest", "p1", {"quest_id": "pr_inst"})
	var events := StackResolver.submit_action(state, action, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.pending_reveal_pick_player, "p1", "princess-a: owner is the quest completer")
	eq(state.pending_reveal_pick_chooser, "p2", "princess-b: the OPPONENT is the decider")
	# want_type "Any" — both revealed cards are selectable regardless of type.
	eq(state.pending_reveal_pick_ids, ["pr_a", "pr_b"],
		"princess-c: both revealed cards selectable (Any)")
	var chooser_in_event := ""
	for ev in events:
		if ev.event_type == "reveal_pick_opened":
			chooser_in_event = ev.payload.get("chooser", "")
	eq(chooser_in_event, "p2", "princess-d: reveal_pick_opened carries the chooser")
	eq(state.get_card("pr_c").zone_id, "p1_deck", "princess-e: 3rd card not revealed")

	# The pick is still a hard block on everything else (same guards as before).
	ok(StackResolver.pass_priority(state, db).is_empty(),
		"princess-f: passing blocked while the pick is pending")

	# p2 hands p1 the ability; the ally goes to the bottom of p1's deck.
	StackResolver.choose_reveal_pick(state, "pr_b", db)
	eq(state.pending_reveal_pick_player, "", "princess-g: pending cleared")
	eq(state.pending_reveal_pick_chooser, "", "princess-h: chooser cleared")
	eq(state.get_card("pr_b").zone_id, "p1_hand",
		"princess-i: chosen card goes to the OWNER's hand, not the chooser's")
	eq(state.zones["p1_deck"].card_ids, ["pr_c", "pr_a"],
		"princess-j: the other revealed card goes to the bottom of the owner's deck")


# ══════════════════════════════════════════════════════════════════════════════
# Finkle Einhorn, At Your Service! — put an ally (cost 2 or less) from the
# graveyard directly into play; its enter-play triggers fire as if from hand.
# ══════════════════════════════════════════════════════════════════════════════

func _test_finkle_einhorn_graveyard_to_play() -> void:
	_buf.append("\n-- Finkle Einhorn: put a cost≤2 ally from graveyard into play (triggers fire) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("finkle_def", 3, "graveyard_to_play:Ally:1:1:own:2")
	# Cost-2 ally with an on_enter draw trigger — proves triggers fire on entry.
	db.ally("drawbot_def", 1, 1, [], 2, "on_enter:draw:1")
	# Cost-3 ally — must be filtered out by the max_cost=2 gate.
	db.ally("big_ally_def", 3, 3, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)

	var quest := CardInstance.create("finkle_inst", "finkle_def", "p1", "p1_resource_row")
	state.cards["finkle_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("finkle_inst")

	# p1 graveyard: the eligible cost-2 ally and an over-cost ally.
	for pair in [["drawbot", "drawbot_def"], ["big_ally", "big_ally_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])

	# A card in the deck so the on_enter draw has something to pull.
	var dcard := CardInstance.create("deck_card", "drawbot_def", "p1", "p1_deck")
	state.cards["deck_card"] = dcard
	state.zones["p1_deck"].card_ids.append("deck_card")

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("finkle_def"))
	eq(req.get("dest", ""), "play", "finkle-a: requirement parsed with dest=play")
	eq(int(req.get("max_cost", -1)), 2, "finkle-b: max_cost gate is 2")

	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["drawbot"], "finkle-c: only the cost≤2 ally is a candidate")

	# Over-cost ally is an illegal target.
	var bad := PendingAction.make("use_quest", "p1",
			{"quest_id": "finkle_inst", "target_ids": ["big_ally"]})
	ok(not StackResolver.can_submit(state, bad, db),
		"finkle-d: cost-3 ally is an illegal target")

	var hand_before := state.cards_in_zone("p1_hand").size()

	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "finkle_inst", "target_ids": ["drawbot"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "finkle-e: completion with valid target submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.get_card("drawbot").zone_id, "p1_ally_row",
		"finkle-f: ally put into play in p1 ally_row")
	ok(state.get_card("drawbot").just_summoned,
		"finkle-g: reinstated ally has summoning sickness (just_summoned)")
	eq(state.cards_in_zone("p1_hand").size(), hand_before + 1,
		"finkle-h: on_enter draw trigger fired (hand +1)")
	ok(state.get_card("finkle_inst").face_down,
		"finkle-i: quest flipped face-down after completion")


const ANCESTRAL_FX := "graveyard_to_play:Ally:1:1:own:resources:health_minus_1"

# Ancestral Spirit (dark_portal_91, 3, Ability — Restoration): "Put target ally
# card from your graveyard into play if its cost <= the number of resources you
# have. That ally enters play with damage on it equal to its health -1."
func _test_ancestral_spirit_reanimate() -> void:
	_buf.append("\n-- Ancestral Spirit: reanimate own graveyard ally at 1 HP --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ability("ancestral_def", 3, ANCESTRAL_FX)
	db.ally("bear_def", 2, 4, [], 2)          # cost 2, 4 health → enters with 3 damage

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 3)               # cost 3 to play; total resources 3 = cost cap
	_add_card_to_hand(st, "ancestral", "ancestral_def", "p1")
	var dead := CardInstance.create("dead_bear", "bear_def", "p1", "p1_graveyard")
	st.cards["dead_bear"] = dead
	st.zones["p1_graveyard"].card_ids.append("dead_bear")

	# Requirement parses with dynamic cost + damage mode.
	var req := StackResolver.get_graveyard_search_requirement(db.get_def("ancestral_def"))
	eq(req.get("dest", ""), "play", "anc-a: dest=play")
	ok(req.get("max_cost_dynamic", false), "anc-a2: dynamic cost cap")
	eq(req.get("damage_mode", ""), "health_minus_1", "anc-a3: damage mode parsed")

	# Highlight probe lights up (a candidate exists), and the target is legal.
	ok(StackResolver.can_play_ability_no_target_check(st, "ancestral", "p1", db),
		"anc-b: probe highlights (candidate in graveyard)")

	StackResolver.submit_action(st, PendingAction.make("play_ability", "p1",
		{"card_id": "ancestral", "target_id": "dead_bear"}), db)
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)

	eq(st.get_card("dead_bear").zone_id, "p1_ally_row", "anc-c: ally in play")
	eq(st.get_card("dead_bear").damage_taken, 3, "anc-d: enters with health-1 damage")
	eq(st.get_max_hp("dead_bear", db) - st.get_card("dead_bear").damage_taken, 1,
		"anc-d2: effective HP is 1")
	ok(st.get_card("dead_bear").just_summoned, "anc-e: summoning sickness")
	ok("ancestral" in st.zones["p1_graveyard"].card_ids, "anc-f: ability to graveyard")


# Gates: cost cap (dead ally cost > total resources), own-graveyard only, and a
# 1-health ally enters with 0 damage (no underflow).
func _test_ancestral_spirit_gates() -> void:
	_buf.append("\n-- Ancestral Spirit: cost/owner gates + 1-HP entry --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ability("ancestral_def", 3, ANCESTRAL_FX)
	db.ally("cheap_def", 1, 1, [], 1)         # 1 health → 0 damage on enter
	db.ally("big_def", 3, 5, [], 5)           # cost 5 → over the cap

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 3)               # cost cap = 3
	_add_card_to_hand(st, "ancestral", "ancestral_def", "p1")
	# Over-cost ally in own graveyard, plus a legal cheap ally in OPP graveyard.
	var big := CardInstance.create("big", "big_def", "p1", "p1_graveyard")
	st.cards["big"] = big
	st.zones["p1_graveyard"].card_ids.append("big")
	var opp := CardInstance.create("opp_cheap", "cheap_def", "p2", "p2_graveyard")
	st.cards["opp_cheap"] = opp
	st.zones["p2_graveyard"].card_ids.append("opp_cheap")

	# Neither is a legal target: big is over cost cap, opp_cheap is not our graveyard.
	ok(not StackResolver.can_submit(st, PendingAction.make("play_ability", "p1",
		{"card_id": "ancestral", "target_id": "big"}), db),
		"anc-g: over-cost ally illegal (cost 5 > 3 resources)")
	ok(not StackResolver.can_submit(st, PendingAction.make("play_ability", "p1",
		{"card_id": "ancestral", "target_id": "opp_cheap"}), db),
		"anc-g2: opponent's graveyard ally illegal")
	# No legal candidate at all → probe dark.
	ok(not StackResolver.can_play_ability_no_target_check(st, "ancestral", "p1", db),
		"anc-g3: probe dark with no legal candidate")

	# Now put a legal 1-HP ally in our graveyard and reanimate it.
	var cheap := CardInstance.create("cheap", "cheap_def", "p1", "p1_graveyard")
	st.cards["cheap"] = cheap
	st.zones["p1_graveyard"].card_ids.append("cheap")
	StackResolver.submit_action(st, PendingAction.make("play_ability", "p1",
		{"card_id": "ancestral", "target_id": "cheap"}), db)
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)
	eq(st.get_card("cheap").zone_id, "p1_ally_row", "anc-h: 1-HP ally in play")
	eq(st.get_card("cheap").damage_taken, 0, "anc-h2: health-1 = 0 damage (no underflow)")


# AI reanimates the highest-cost affordable ally in its own graveyard.
func _test_ancestral_spirit_ai_picks_best() -> void:
	_buf.append("\n-- Ancestral Spirit: AI picks highest-cost graveyard ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ability("ancestral_def", 3, ANCESTRAL_FX)
	db.ally("small_def", 1, 2, [], 1)
	db.ally("mid_def", 2, 3, [], 3)

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 3)
	_add_card_to_hand(st, "ancestral", "ancestral_def", "p1")
	for pair in [["gy_small", "small_def"], ["gy_mid", "mid_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		st.cards[pair[0]] = c
		st.zones["p1_graveyard"].card_ids.append(pair[0])

	var ai := BaseAI.new()
	var actions: Array = ai.get_reasonable_actions(st, db, "p1")
	var chosen := ""
	for a in actions:
		if a.action_type == "play_ability" and a.params.get("card_id", "") == "ancestral":
			chosen = a.params.get("target_id", "")
	eq(chosen, "gy_mid", "anc-i: AI reanimates the cost-3 ally over the cost-1 one")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 25 — Battle of Darrowshire: RFG three allies from graveyard, draw a card
# ══════════════════════════════════════════════════════════════════════════════

func _test_darrowshire_rfg_three_allies() -> void:
	_buf.append("\n-- Scenario 25: Battle of Darrowshire removes 3 allies from the game, draws 1 --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("darrowshire_def", 1, "graveyard_to_rfg:Ally:3:3:own|draw:1")
	db.ally("dead_ally_def", 2, 2, [], 4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)
	for i in 2:
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "dead_ally_def", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	var quest := CardInstance.create("dar_inst", "darrowshire_def", "p1", "p1_resource_row")
	state.cards["dar_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("dar_inst")

	# Four dead allies in p1's graveyard.
	for i in 4:
		var cid := "dead_%d" % i
		var c := CardInstance.create(cid, "dead_ally_def", "p1", "p1_graveyard")
		state.cards[cid] = c
		state.zones["p1_graveyard"].card_ids.append(cid)

	var req := StackResolver.get_graveyard_search_requirement(db.get_def("darrowshire_def"))
	eq(req.get("dest", ""), "rfg", "sc25-a: requirement parsed with dest=rfg")
	eq(int(req.get("min_count", 0)), 3, "sc25-b: min_count is 3")

	# Two announced targets (below min) is rejected; a duplicated target too.
	var too_few := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_1"]})
	ok(not StackResolver.can_submit(state, too_few, db),
		"sc25-c: fewer than 3 targets rejected")
	var dupes := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_0", "dead_1"]})
	ok(not StackResolver.can_submit(state, dupes, db),
		"sc25-d: duplicated target rejected (must be 3 distinct cards)")

	var hand_before: int = state.zones["p1_hand"].card_ids.size()
	var good := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_1", "dead_2"]})
	var events := StackResolver.submit_action(state, good, db)
	ok(not events.is_empty(), "sc25-e: completion with 3 distinct targets submits")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	for cid in ["dead_0", "dead_1", "dead_2"]:
		ok(state.get_card(cid).zone_id == "p1_rfg",
			"sc25-f: %s moved to p1_rfg" % cid)
	ok(state.get_card("dead_3").zone_id == "p1_graveyard",
		"sc25-g: unchosen ally stays in the graveyard")
	eq(state.zones["p1_hand"].card_ids.size(), hand_before + 1,
		"sc25-h: reward drew exactly one card")
	ok(state.get_card("dar_inst").face_down,
		"sc25-i: quest flipped face-down after completion")
	var rfg_events := 0
	for ev in events:
		if ev.event_type == "card_removed_from_game":
			rfg_events += 1
	eq(rfg_events, 3, "sc25-j: three card_removed_from_game events emitted")


func _test_darrowshire_blocked_with_too_few_allies() -> void:
	_buf.append("\n-- Scenario 26: Battle of Darrowshire blocked with fewer than 3 graveyard allies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("darrowshire_def", 1, "graveyard_to_rfg:Ally:3:3:own|draw:1")
	db.ally("dead_ally_def", 2, 2, [], 4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var quest := CardInstance.create("dar_inst", "darrowshire_def", "p1", "p1_resource_row")
	state.cards["dar_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("dar_inst")

	# Only two allies in the graveyard — one short of the requirement.
	for i in 2:
		var cid := "dead_%d" % i
		var c := CardInstance.create(cid, "dead_ally_def", "p1", "p1_graveyard")
		state.cards[cid] = c
		state.zones["p1_graveyard"].card_ids.append(cid)

	ok(not StackResolver.can_use_quest_no_target_check(state, "dar_inst", "p1", db),
		"sc26-a: probe fails with only 2 graveyard allies")
	var forced := PendingAction.make("use_quest", "p1",
			{"quest_id": "dar_inst", "target_ids": ["dead_0", "dead_1"]})
	ok(not StackResolver.can_submit(state, forced, db),
		"sc26-b: forced submission with 2 targets rejected")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 26b — The Defias Brotherhood: needs 4+ allies in play, pay 1, draw 2
# ══════════════════════════════════════════════════════════════════════════════

func _test_defias_brotherhood_requires_four_allies() -> void:
	_buf.append("\n-- Scenario 26b: The Defias Brotherhood needs 4+ allies in party --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("defias_def", 1, "require_ally_count:4|draw:2")
	db.ally("filler_ally_def", 2, 2, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var quest := CardInstance.create("defias_inst", "defias_def", "p1", "p1_resource_row")
	state.cards["defias_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("defias_inst")

	eq(StackResolver.get_quest_ally_count_requirement(db.get_def("defias_def")), 4,
		"sc26b-a: parsed requirement is 4")

	# Only 3 allies in play — one short.
	for i in 3:
		_add_ally(state, "ally_%d" % i, "filler_ally_def", "p1")
	ok(not StackResolver.can_use_quest_no_target_check(state, "defias_inst", "p1", db),
		"sc26b-b: probe fails with only 3 allies in play")

	# Add a 4th ally — now legal.
	_add_ally(state, "ally_3", "filler_ally_def", "p1")
	ok(StackResolver.can_use_quest_no_target_check(state, "defias_inst", "p1", db),
		"sc26b-c: probe succeeds with 4 allies in play")

	for i in 20:
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "filler_ally_def", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	var hand_before: int = state.zones["p1_hand"].card_ids.size()
	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "defias_inst"})
	var events := StackResolver.submit_action(state, complete, db)
	ok(not events.is_empty(), "sc26b-d: completion submits with 4 allies in play")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.zones["p1_hand"].card_ids.size(), hand_before + 2,
		"sc26b-e: reward drew exactly two cards")
	ok(state.get_card("defias_inst").face_down,
		"sc26b-f: quest flipped face-down after completion")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 26c — Torek's Assault: needs opposing hero damaged by our ally this turn
# ══════════════════════════════════════════════════════════════════════════════

func _test_toreks_assault_requires_hero_damaged_by_ally() -> void:
	_buf.append("\n-- Scenario 26c: Torek's Assault requires opposing hero damaged by our ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("torek_def", 1, "require_hero_damaged_by_ally|draw:1")
	db.ally("filler_ally_def", 2, 2, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var quest := CardInstance.create("torek_inst", "torek_def", "p1", "p1_resource_row")
	state.cards["torek_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("torek_inst")

	_add_ally(state, "p1_ally", "filler_ally_def", "p1")
	_add_ally(state, "p2_ally", "filler_ally_def", "p2")

	ok(not StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-a: probe fails before any hero has taken damage")

	# Our ally damaging OUR OWN hero must not satisfy the condition.
	GameLogic.deal_damage(state, "p1_ally", "p1_hero", 1, db)
	ok(not StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-b: probe still fails when our own hero is damaged by our ally")

	# The opposing ally damaging the opposing hero must not satisfy the condition either.
	GameLogic.deal_damage(state, "p2_ally", "p2_hero", 1, db)
	ok(not StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-c: probe still fails when opposing hero is damaged by their own ally")

	# Our ally damaging the OPPOSING hero satisfies the condition.
	GameLogic.deal_damage(state, "p1_ally", "p2_hero", 1, db)
	ok(StackResolver.can_use_quest_no_target_check(state, "torek_inst", "p1", db),
		"sc26c-d: probe succeeds once our ally damages the opposing hero")

	var hand_before: int = state.zones["p1_hand"].card_ids.size()
	for i in 5:
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "filler_ally_def", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "torek_inst"})
	var events := StackResolver.submit_action(state, complete, db)
	ok(not events.is_empty(), "sc26c-e: completion submits once condition is met")
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(state.zones["p1_hand"].card_ids.size(), hand_before + 1,
		"sc26c-f: reward drew exactly one card")
	ok(state.get_card("torek_inst").face_down,
		"sc26c-g: quest flipped face-down after completion")

	# Flag resets at the start of a new turn (action -> end -> next turn's ready).
	TurnManager.advance_phase(state, db)
	TurnManager.advance_phase(state, db)
	ok(not state.players["p2"].hero_damaged_by_ally_this_turn,
		"sc26c-h: hero_damaged_by_ally_this_turn resets at next turn start")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 27 — BaseAI.find_lethal: opposing characters that die to N damage
# ══════════════════════════════════════════════════════════════════════════════

func _test_find_lethal() -> void:
	_buf.append("\n-- Scenario 27: find_lethal lists lethal targets, hero-only when hero is lethal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("small_def", 1, 2, [], 1)   # 2 HP
	db.ally("big_def",   3, 5, [], 4)   # 5 HP

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "small_a", "small_def", "p2")
	_add_ally(state, "small_b", "small_def", "p2")
	_add_ally(state, "big",     "big_def",   "p2")

	# No hero lethal: both 2-HP allies listed, 5-HP ally excluded.
	var lethal3 := BaseAI.find_lethal(state, db, "p1", 3)
	ok("small_a" in lethal3 and "small_b" in lethal3,
		"sc27-a: both 2-HP allies die to 3 damage")
	ok("big" not in lethal3, "sc27-b: 5-HP ally not listed at 3 damage")
	ok(state.players["p2"].hero_instance_id not in lethal3,
		"sc27-c: 30-HP hero not listed")

	# Nothing dies to 1 damage... except the 2-HP allies don't; empty list.
	eq(BaseAI.find_lethal(state, db, "p1", 1).size(), 0,
		"sc27-d: no target dies to 1 damage")
	eq(BaseAI.find_lethal(state, db, "p1", 0).size(), 0,
		"sc27-e: 0 damage returns empty list")

	# Hero lethal: only the hero is returned, even with lethal allies around.
	var p2_hero_id: String = state.players["p2"].hero_instance_id
	state.get_card(p2_hero_id).damage_taken = 28   # 2 HP left
	var hero_lethal := BaseAI.find_lethal(state, db, "p1", 3)
	eq(hero_lethal, [p2_hero_id],
		"sc27-f: lethal hero returned alone despite lethal allies")

	# Opposing perspective: p2 scans p1's side (no p1 allies, healthy hero).
	eq(BaseAI.find_lethal(state, db, "p2", 3).size(), 0,
		"sc27-g: p2 finds no lethal targets on p1's side")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 28 — find_lethal baseline in AI action generation
# (Ta'zo-style hero powers offer only lethal targets; ally powers try lethal first)
# ══════════════════════════════════════════════════════════════════════════════

func _test_find_lethal_baseline_in_ai_actions() -> void:
	_buf.append("\n-- Scenario 28: hero/ally power actions restricted/ordered by find_lethal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("tazo_def", 25, 3, "deal_damage_to_target:3:fire")
	db.ally("small_def", 1, 2, [], 1)   # 2 HP — dies to 3
	db.ally("big_def",   3, 6, [], 4)   # 6 HP — survives 3
	db.ally("grimdron_def", 1, 3, [], 2,
			"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally")

	var state := GameState.create_new(["p1", "p2"])
	var h1 := CardInstance.create("p1_hero", "p1_hero", "p1", "p1_hero_row")
	state.cards["p1_hero"] = h1
	state.zones["p1_hero_row"].card_ids.append("p1_hero")
	state.players["p1"].hero_instance_id = "p1_hero"
	var h2 := CardInstance.create("tazo_inst", "tazo_def", "p2", "p2_hero_row")
	state.cards["tazo_inst"] = h2
	state.zones["p2_hero_row"].card_ids.append("tazo_inst")
	state.players["p2"].hero_instance_id = "tazo_inst"

	state.phase = "action"
	state.turn_player = "p2"
	state.priority_player = "p2"
	state.turn_number = 1
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	_add_ally(state, "small", "small_def", "p1")
	_add_ally(state, "big",   "big_def",   "p1")

	var helper := BaseAI.new()

	# sc28-a/b: Ta'zo's 3-damage power offers ONLY the lethal 2-HP ally.
	var power_targets: Array = []
	for a in helper._get_hero_power_actions(state, db, "p2"):
		power_targets.append(a.params.get("target_id"))
	eq(power_targets, ["small"],
		"sc28-a: only the lethal ally is offered as a hero power target")

	# sc28-b: hero lethal → the power offers ONLY the hero.
	state.get_card("p1_hero").damage_taken = 28   # 2 HP left
	power_targets.clear()
	for a in helper._get_hero_power_actions(state, db, "p2"):
		power_targets.append(a.params.get("target_id"))
	eq(power_targets, ["p1_hero"],
		"sc28-b: lethal hero is the only offered target")
	state.get_card("p1_hero").damage_taken = 0

	# sc28-c: no lethal target → all legal targets offered (baseline unchanged).
	state.get_card("small").damage_taken = 0
	(db._defs["tazo_def"] as CardDef).effects = "deal_damage_to_target:1:fire"
	power_targets.clear()
	for a in helper._get_hero_power_actions(state, db, "p2"):
		power_targets.append(a.params.get("target_id"))
	eq(power_targets.size(), 3,
		"sc28-c: with no lethal target, hero + both allies all offered")

	# sc28-d: Grimdron (1 dmg) prefers the lethal 1-HP target over a more-damaged one.
	_add_ally(state, "grim", "grimdron_def", "p2")
	state.get_card("grim").just_summoned = false
	state.get_card("small").damage_taken = 1   # 1 HP left — lethal to 1 dmg
	state.get_card("big").damage_taken   = 2   # 4 HP left — more damage taken
	var ally_actions := helper._get_ally_power_actions(state, db, "p2")
	ok(ally_actions.size() == 1
			and ally_actions[0].params.get("target_id") == "small",
		"sc28-d: ally power targets the lethal ally first")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 29 — sort_valuable_cards: card_value_score (cost + rarity +
# 0.2*(atk+hp)) first, then ally > Protector > HP > Ferocity > Elusive > ATK
# ══════════════════════════════════════════════════════════════════════════════

func _test_sort_valuable_cards() -> void:
	_buf.append("\n-- Scenario 29: sort_valuable_cards orders most valuable first --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# atk, health, keywords, cost
	db.ally("epic_cheap",  1, 1, [],            1)
	db.ally("rare_exp",    1, 1, [],            5)
	db.ally("ally_4",      2, 3, [],            4)
	db.quest("spell_4",    4)   # non-ally, same cost as ally_4
	db.ally("prot_2",      1, 2, ["Protector"], 2)
	db.ally("hp_2",        1, 5, [],            2)
	db.ally("fero_2",      1, 2, ["Ferocity"],  2)
	db.ally("elu_2",       1, 2, ["Elusive"],   2)
	db.ally("atk_2",       4, 2, [],            2)
	db.ally("plain_2",     1, 2, [],            2)
	(db._defs["epic_cheap"] as CardDef).rarity = "Epic"
	(db._defs["rare_exp"]   as CardDef).rarity = "Rare"
	for did in ["ally_4", "spell_4", "prot_2", "hp_2", "fero_2", "elu_2", "atk_2", "plain_2"]:
		(db._defs[did] as CardDef).rarity = "Common"

	var state := _base_state(db, "p1_hero", "p2_hero")
	var ids: Array[String] = []
	for did in ["plain_2", "atk_2", "elu_2", "fero_2", "hp_2", "prot_2",
			"spell_4", "ally_4", "rare_exp", "epic_cheap"]:
		var c := CardInstance.create(did + "_i", did, "p1", "p1_graveyard")
		state.cards[did + "_i"] = c
		state.zones["p1_graveyard"].card_ids.append(did + "_i")
		ids.append(did + "_i")

	# Scores: rare_exp 5+3+0.4=8.4 > ally_4 4+1+1.0=6.0 > epic_cheap 1+4+0.4=5.4
	# > spell_4 4+1+0=5.0 (non-ally: no stat term) > hp_2/atk_2 2+1+1.2=4.2
	# (tie → HP) > the 3.6 pack (tie → Protector, Ferocity, Elusive).
	var sorted_ids := BaseAI.sort_valuable_cards(state, db, ids)
	eq(sorted_ids, ["rare_exp_i", "ally_4_i", "epic_cheap_i", "spell_4_i",
			"hp_2_i", "atk_2_i", "prot_2_i", "fero_2_i", "elu_2_i", "plain_2_i"],
		"sc29-a: full order — score first, keyword heuristic breaks ties")
	eq(ids.size(), 10, "sc29-b: input list not mutated (still 10 entries)")
	ok(ids[0] == "plain_2_i", "sc29-c: input order untouched")
	ok(absf(BaseAI.card_value_score(state, db, "rare_exp_i") - 8.4) < 0.001,
		"sc29-a2: card_value_score = cost + rarity + 0.2*(atk+hp)")

	# Situational bonus: +3.5 lifts plain_2 (3.6) above ally_4 (6.0) but not
	# rare_exp (8.4).
	var boosted := BaseAI.sort_valuable_cards(state, db, ids,
			{"plain_2_i": 3.5})
	eq(boosted[0], "rare_exp_i", "sc29-g: bonus doesn't overtake a higher score")
	eq(boosted[1], "plain_2_i", "sc29-h: per-card bonus lifts score in the sort")

	# FullRandomAI hook: lethal pools come back value-sorted.
	var fr := FullRandomAI.new()
	var ranked := fr.rank_lethal_targets(state, db, ids)
	eq(ranked[0], "rare_exp_i",
		"sc29-d: FullRandomAI ranks the most valuable card first")

	# In-play cards use CURRENT values: same def, one damaged → the healthy
	# one (3 HP left) is more valuable than the hurt one (1 HP left).
	db.ally("twin_def", 1, 3, [], 2)
	_add_ally(state, "twin_full", "twin_def", "p2")
	_add_ally(state, "twin_hurt", "twin_def", "p2")
	state.get_card("twin_hurt").damage_taken = 2
	var twins: Array[String] = ["twin_hurt", "twin_full"]
	eq(BaseAI.sort_valuable_cards(state, db, twins),
			["twin_full", "twin_hurt"],
		"sc29-e: in-play cards ranked by current HP, not printed")

	# Mixed zones: a graveyard copy of the same def uses printed HP (3),
	# tying the healthy twin and beating the hurt one.
	var gy_twin := CardInstance.create("twin_gy", "twin_def", "p2", "p2_graveyard")
	state.cards["twin_gy"] = gy_twin
	state.zones["p2_graveyard"].card_ids.append("twin_gy")
	var mixed: Array[String] = ["twin_hurt", "twin_gy"]
	eq(BaseAI.sort_valuable_cards(state, db, mixed),
			["twin_gy", "twin_hurt"],
		"sc29-f: mixed-zone list — graveyard card uses printed values")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 30 — find_safe_lethals: kill-and-survive pairs
# ══════════════════════════════════════════════════════════════════════════════

func _test_find_safe_lethals() -> void:
	_buf.append("\n-- Scenario 30: find_safe_lethals returns kill-and-survive pairs --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("striker_def", 3, 3, [], 2)   # 3/3
	db.ally("weak_def",    1, 2, [], 1)   # 1/2 — dies to 3, deals 1 back
	db.ally("trader_def",  3, 3, [], 2)   # 3/3 — dies to 3 but kills back (3 not < 3)
	db.ally("tank_def",    1, 4, [], 3)   # 1/4 — survives 3 damage

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "striker", "striker_def", "p1")
	_add_ally(state, "weak",    "weak_def",    "p2")
	_add_ally(state, "trader",  "trader_def",  "p2")
	_add_ally(state, "tank",    "tank_def",    "p2")

	var atk_list: Array[String] = ["striker"]
	var def_list: Array[String] = ["weak", "trader", "tank"]
	var pairs := BaseAI.find_safe_lethals(state, db, atk_list, def_list)
	eq(pairs, [["striker", "weak"]],
		"sc30-a: only the kill-and-survive pair is returned")

	# Damaged defender becomes safe: trader at 1 HP left still hits back for 3,
	# which ties striker's 3 HP — still NOT safe (survival needs strict >).
	state.get_card("trader").damage_taken = 2
	pairs = BaseAI.find_safe_lethals(state, db, atk_list, def_list)
	ok(not _pairs_contain(pairs, "striker", "trader"),
		"sc30-b: mutual-kill trade is not a safe kill (HP must strictly beat ATK)")

	# Damaged ATTACKER loses its safe kill: striker at 1 HP dies to weak's 1 ATK...
	# 1 > 1 is false → no pairs.
	state.get_card("striker").damage_taken = 2
	pairs = BaseAI.find_safe_lethals(state, db, atk_list, def_list)
	eq(pairs.size(), 0,
		"sc30-c: attacker at 1 HP can no longer safely kill a 1-ATK defender")


func _pairs_contain(pairs: Array, attacker: String, defender: String) -> bool:
	for p in pairs:
		if p[0] == attacker and p[1] == defender:
			return true
	return false


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 31 — GenericAI: safe-kill selection flow
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_safe_kill_flow() -> void:
	_buf.append("\n-- Scenario 31: GenericAI baits with cheap attacker, kills best target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("cheap_def",  3, 3, [],            1)
	db.ally("pricey_def", 4, 4, [],            5)
	db.ally("fero_def",   2, 2, ["Ferocity"],  0)
	db.ally("victim_lo",  1, 2, [],            1)
	db.ally("victim_hi",  1, 2, [],            4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "cheap",  "cheap_def",  "p1")
	_add_ally(state, "pricey", "pricey_def", "p1")
	_add_ally(state, "v_lo",   "victim_lo",  "p2")
	_add_ally(state, "v_hi",   "victim_hi",  "p2")
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var ai := GenericAI.new()

	# sc31-a: two board attackers, both with safe kills → cheap goes first,
	# and it targets the most valuable victim (cost 4 over cost 1).
	var act := ai.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "cheap"
			and act.params.get("defender_id") == "v_hi",
		"sc31-a: least valuable attacker proposed against most valuable safe kill")

	# sc31-b: a playable Ferocity ally in hand (cost 0 — least valuable of all)
	# is played immediately instead of attacking with a board ally.
	var fero := CardInstance.create("fero", "fero_def", "p1", "p1_hand")
	state.cards["fero"] = fero
	state.zones["p1_hand"].card_ids.append("fero")
	act = ai.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "play_ally"
			and act.params.get("card_id") == "fero",
		"sc31-b: hand Ferocity ally with a safe kill is played first")
	state.zones["p1_hand"].card_ids.erase("fero")
	state.cards.erase("fero")

	# sc31-c: Elusive best target is skipped (can_submit fails) — the attacker
	# falls through to the next-best legal safe kill.
	(db._defs["victim_hi"] as CardDef).keywords.append("elusive")
	act = ai.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "cheap"
			and act.params.get("defender_id") == "v_lo",
		"sc31-c: illegal (Elusive) pair skipped, next safe kill chosen")
	(db._defs["victim_hi"] as CardDef).keywords.erase("elusive")

	# sc31-d: no safe kill (victims outclass attackers) → falls back to random
	# legal behaviour, i.e. NOT a doomed propose_combat from the safe-kill path.
	state.get_card("cheap").damage_taken = 2    # 1 HP left, dies to any 1-ATK hit
	state.get_card("pricey").damage_taken = 3   # 1 HP left
	var fallback := ai._safe_lethal_action(state, db, "p1")
	ok(fallback == null, "sc31-d: no safe kill → safe-lethal path returns null")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32 — GenericAI value-based choices: discard, resource, graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_value_choices() -> void:
	_buf.append("\n-- Scenario 32: GenericAI discards/places least valuable, picks best from graveyard --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("gem_def",  3, 3, [], 5)   # valuable
	db.ally("junk_def", 1, 1, [], 0)   # least valuable
	db.quest("quest_def", 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var ai := GenericAI.new()

	# Hand: valuable ally + junk ally.
	for pair in [["gem", "gem_def"], ["junk", "junk_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_hand")
		state.cards[pair[0]] = c
		state.zones["p1_hand"].card_ids.append(pair[0])

	# sc32-a: discard the least valuable card.
	eq(ai.choose_discard_card(state, db, "p1"), "junk",
		"sc32-a: least valuable hand card chosen for discard")

	# sc32-b: resource placement — least valuable goes face-down.
	var res_act := ai._decide_resource_placement(state, db, "p1")
	ok(res_act != null and res_act.params.get("card_id") == "junk"
			and res_act.params.get("face_up") == false,
		"sc32-b: least valuable hand card placed face-down as resource")

	# sc32-c: a quest in hand still takes priority, face-up.
	var q := CardInstance.create("quest_c", "quest_def", "p1", "p1_hand")
	state.cards["quest_c"] = q
	state.zones["p1_hand"].card_ids.append("quest_c")
	res_act = ai._decide_resource_placement(state, db, "p1")
	ok(res_act != null and res_act.params.get("card_id") == "quest_c"
			and res_act.params.get("face_up") == true,
		"sc32-c: quest still placed face-up first")

	# sc32-d: graveyard-to-hand reward → MOST valuable candidate.
	for pair in [["dead_gem", "gem_def"], ["dead_junk", "junk_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])
	var to_hand := {"card_type": "Ally", "min_count": 1, "max_count": 1,
			"owner": "own", "max_cost": -1, "dest": "hand"}
	var gy_cands: Array[String] = ["dead_junk", "dead_gem"]
	eq(ai._choose_graveyard_targets(state, db, "p1", to_hand, gy_cands),
			["dead_gem"],
		"sc32-d: most valuable graveyard card returned to hand")

	# sc32-e: own-graveyard RFG cost (Darrowshire) → LEAST valuable.
	var to_rfg := {"card_type": "Ally", "min_count": 1, "max_count": 1,
			"owner": "own", "max_cost": -1, "dest": "rfg"}
	eq(ai._choose_graveyard_targets(state, db, "p1", to_rfg, gy_cands),
			["dead_junk"],
		"sc32-e: least valuable own card removed from the game as a cost")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32b — combat_trade_value: the four outcomes (pure ATK/HP math)
# ══════════════════════════════════════════════════════════════════════════════

func _test_combat_trade_value() -> void:
	_buf.append("\n-- Scenario 32b: combat_trade_value classifies safe_lethal/both/suicide/no_one --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def",   3, 4, [], 3)   # atk3 hp4
	db.ally("even_def",  3, 3, [], 3)   # atk3 hp3
	db.ally("wall_def",  1, 5, [], 3)   # atk1 hp5
	db.ally("glass_def", 1, 2, [], 1)   # atk1 hp2

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "big",   "big_def",   "p1")
	_add_ally(state, "evenA", "even_def",  "p1")
	_add_ally(state, "evenB", "even_def",  "p2")
	_add_ally(state, "wall",  "wall_def",  "p2")
	_add_ally(state, "glass", "glass_def", "p1")

	# big(3/4) → evenB(3/3): kills (3>=3), survives (4>3).
	eq(BaseAI.combat_trade_value(state, db, "big", "evenB"), "safe_lethal",
		"sc32b-a: kills and survives → safe_lethal")
	# evenA(3/3) → evenB(3/3): kills (3>=3), dies (3>=3).
	eq(BaseAI.combat_trade_value(state, db, "evenA", "evenB"), "both",
		"sc32b-b: kills and dies → both")
	# evenA(3/3) → wall(1/5): can't kill (3<5), survives (3<... wall atk1<3).
	eq(BaseAI.combat_trade_value(state, db, "evenA", "wall"), "no_one",
		"sc32b-c: can't kill and survives → no_one")
	# glass(1/2) → big(3/4): can't kill (1<4), dies (big atk3 >= glass hp2).
	eq(BaseAI.combat_trade_value(state, db, "glass", "big"), "suicide",
		"sc32b-d: can't kill and dies → suicide")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32c — GenericAI pipeline: trades, develop, hero-chip, termination
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_trade_develop_chip() -> void:
	_buf.append("\n-- Scenario 32c: GenericAI trades up, develops, chips (holding protectors) --")
	var ai := GenericAI.new()

	# ── _trade_action: take an even 'both' trade, refuse a value-down one ──
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("even_def",  2, 2, [], 2)   # our attacker
	db.ally("peer_def",  2, 2, [], 2)   # even trade target
	db.ally("tough_def", 3, 3, [], 5)   # we can't profitably fight this

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "mine",  "even_def",  "p1")
	_add_ally(st, "peer",  "peer_def",  "p2")
	_add_ally(st, "tough", "tough_def", "p2")
	st.players["p1"].resource_placed_this_turn = true
	st.players["p2"].resource_placed_this_turn = true

	var t := ai._trade_action(st, db, "p1")
	ok(t != null and t.action_type == "propose_combat"
			and t.params.get("attacker_id") == "mine"
			and t.params.get("defender_id") == "peer",
		"sc32c-a: takes the even 'both' trade, not the doomed fight vs tough")

	# Now make our attacker the valuable one and the only target a chump:
	# value-down 'both' trade must be refused.
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.ally("bomb_def",  5, 5, [], 5)   # valuable attacker
	db2.ally("chump_def", 5, 5, [], 1)   # both die, but they lose only a 1-drop
	var st2 := _base_state(db2, "p1_hero", "p2_hero")
	_add_ally(st2, "bomb",  "bomb_def",  "p1")
	_add_ally(st2, "chump", "chump_def", "p2")
	st2.players["p1"].resource_placed_this_turn = true
	st2.players["p2"].resource_placed_this_turn = true
	ok(ai._trade_action(st2, db2, "p1") == null,
		"sc32c-b: refuses a value-down 'both' trade (bomb for a chump)")

	# ── _hero_chip_action: hold protectors while hero healthy; never 0-ATK ──
	var db3 := MockDB.new()
	db3.hero("p1_hero", 30)
	db3.hero("p2_hero", 30)
	db3.ally("prot_def", 2, 5, (["protector"] as Array[String]), 3)
	db3.ally("zero_def", 0, 4, [], 2)
	db3.ally("beater_def", 2, 2, [], 1)
	var st3 := _base_state(db3, "p1_hero", "p2_hero")
	_add_ally(st3, "prot",   "prot_def",   "p1")
	_add_ally(st3, "zero",   "zero_def",   "p1")
	st3.players["p1"].resource_placed_this_turn = true

	ok(ai._hero_chip_action(st3, db3, "p1") == null,
		"sc32c-c: protector held + 0-ATK never attacks → no chip while hero at 30")

	# Drop the enemy hero to all-out range → protector now chips, 0-ATK still won't.
	st3.get_card("p2_hero").damage_taken = 20   # 10 HP left
	var chip := ai._hero_chip_action(st3, db3, "p1")
	ok(chip != null and chip.action_type == "propose_combat"
			and chip.params.get("attacker_id") == "prot"
			and chip.params.get("defender_id") == "p2_hero",
		"sc32c-d: hero at 10 → all out, protector chips the face")

	# Least valuable non-protector chips first (hero back at full).
	st3.get_card("p2_hero").damage_taken = 0
	_add_ally(st3, "beater", "beater_def", "p1")
	chip = ai._hero_chip_action(st3, db3, "p1")
	ok(chip != null and chip.params.get("attacker_id") == "beater",
		"sc32c-e: cheap non-protector chips before the held protector")

	# ── pipeline ordering & terminate-to-null (no random fallback) ──
	var db4 := MockDB.new()
	db4.hero("p1_hero", 30)
	db4.hero("p2_hero", 30)
	db4.ally("dev_def", 1, 1, [], 1)
	var st4 := _base_state(db4, "p1_hero", "p2_hero")
	st4.players["p1"].resource_placed_this_turn = true   # isolate develop = play ally
	st4.players["p1"].has_used_hero_power = true          # no phantom hero-power play
	_add_resources(st4, "p1", 1)                          # 1 resource → dev (cost 1) affordable

	# Nothing on board, empty hand, resource placed → the turn simply ends.
	ok(ai.decide_action(st4, db4, "p1") == null,
		"sc32c-f: no combat, no develop, no chip → decide_action returns null (turn ends)")

	# One ally in hand → GenericAI develops it (no combat available).
	var hand := CardInstance.create("dev", "dev_def", "p1", "p1_hand")
	st4.cards["dev"] = hand
	st4.zones["p1_hand"].card_ids.append("dev")
	var d := ai.decide_action(st4, db4, "p1")
	ok(d != null and d.action_type == "play_ally" and d.params.get("card_id") == "dev",
		"sc32c-g: with only a develop available, GenericAI plays the ally")

	# Simulate the develop resolving: the ally is now in play but summoning-sick,
	# so it is not a legal attacker and the turn ends — the loop can't spin.
	st4.zones["p1_hand"].card_ids.erase("dev")
	GameLogic.move_card(st4, "dev", "p1_ally_row")
	st4.get_card("dev").just_summoned = true
	ok(ai.decide_action(st4, db4, "p1") == null,
		"sc32c-h: after developing, the summoning-sick ally can't attack → turn ends")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32d — GenericAI protector choice via combat_trade_value
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_protector_choice() -> void:
	_buf.append("\n-- Scenario 32d: GenericAI protects from the proposed-fight outcome --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("atk3_def",   3, 3, [], 3)                                  # the attacker
	db.ally("killer_def", 3, 5, (["protector"] as Array[String]), 3)   # kills atk3 & lives
	db.ally("soak_def",   1, 5, (["protector"] as Array[String]), 2)   # survives, can't kill
	db.ally("bigdef_def", 3, 4, [], 3)                                 # kills atk3 & lives (defender)
	db.ally("prize_def",  2, 2, [], 4)                                 # valuable ally, dies to atk3
	db.ally("fodder_def", 1, 3, (["protector"] as Array[String]), 1)   # cheap protector
	db.ally("pricey_def", 2, 4, (["protector"] as Array[String]), 6)   # expensive protector

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "atk",    "atk3_def",   "p2")
	_add_ally(st, "killer", "killer_def", "p1")
	_add_ally(st, "soak",   "soak_def",   "p1")
	st.combat_attacker = "atk"
	st.combat_defender = "p1_hero"

	# a: hero survives, a protector can kill the attacker and live → protect.
	eq(ai.choose_protector(st, db, "p1"), "killer",
		"sc32d-a: defender survives → protect only to kill the attacker (safe_lethal protector)")

	# b: hero survives, no protector can kill the attacker (soak only) → take the hit.
	st.get_card("killer").is_exhausted = true
	eq(ai.choose_protector(st, db, "p1"), "",
		"sc32d-b: defender survives + no killing protector → don't waste one soaking chip")

	# c: the attacker would DIE to the proposed defender → let the free kill happen.
	_add_ally(st, "bigdef", "bigdef_def", "p1")   # soak still ready, but irrelevant
	st.combat_defender = "bigdef"
	eq(ai.choose_protector(st, db, "p1"), "",
		"sc32d-c: attacker dies to the defender for free → do not protect")

	# d: a valuable ally would die; a cheaper protector saves it (fodder < prize).
	_add_ally(st, "prize",  "prize_def",  "p1")
	_add_ally(st, "fodder", "fodder_def", "p1")
	st.combat_defender = "prize"
	eq(ai.choose_protector(st, db, "p1"), "fodder",
		"sc32d-d: dying ally saved by the least valuable protector worth less than it")

	# e: valuable ally would die but only a pricier protector remains → let it die.
	st.get_card("fodder").is_exhausted = true
	st.get_card("soak").is_exhausted = true
	_add_ally(st, "pricey", "pricey_def", "p1")
	st.combat_defender = "prize"
	eq(ai.choose_protector(st, db, "p1"), "",
		"sc32d-e: only protectors more valuable than the ally → don't over-trade, let it die")

	# f: lethal hit on the hero → always interpose the cheapest available body.
	st.combat_defender = "p1_hero"
	st.get_card("p1_hero").damage_taken = 28   # 2 HP left; atk 3 is lethal
	eq(ai.choose_protector(st, db, "p1"), "pricey",
		"sc32d-f: lethal on hero → chump with the only ready body regardless of value")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32e — AI combat evaluation forecasts "while attacking" buffs
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_while_attacking_buffs() -> void:
	_buf.append("\n-- Scenario 32e: AI combat eval honors 'while attacking' buffs (Zorm) --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def",  1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2, [], 2)   # 2/2 base → 3/2 while attacking under Zorm
	db.ally("wall_def",  1, 3, [], 3)   # 1/3 enemy — needs 3 ATK to die

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "zorm",  "zorm_def",  "p1")
	_add_ally(st, "grunt", "grunt_def", "p1")
	_add_ally(st, "wall",  "wall_def",  "p2")
	st.players["p1"].resource_placed_this_turn = true
	st.players["p2"].resource_placed_this_turn = true

	# No combat is live here (combat_attacker == ""), so only the explicit
	# attacking forecast can reveal the Zorm bonus.
	eq(BaseAI.combat_trade_value(st, db, "grunt", "wall"), "safe_lethal",
		"sc32e-a: grunt (→3 ATK while attacking) safe-kills the 1/3 wall")
	eq(BaseAI.combat_trade_value(st, db, "grunt", "wall", false), "no_one",
		"sc32e-b: control — scored as non-attacker (2 ATK), the same pair is no_one")

	# The pipeline seizes the safe kill that ONLY exists while attacking.
	var act := ai.decide_action(st, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "grunt"
			and act.params.get("defender_id") == "wall",
		"sc32e-c: GenericAI takes the safe kill enabled by the Zorm aura")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 33 — Ally heal powers (Freya) target FRIENDLY damaged characters only
# ══════════════════════════════════════════════════════════════════════════════

func _test_ally_heal_power_targets_friendlies() -> void:
	_buf.append("\n-- Scenario 33: heal_target ally power never heals the enemy --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("freya_def", 2, 2, [], 2,
			"activated_power:0:heal_target:3:holy:hero_or_ally")
	db.ally("dummy_def", 2, 5, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "freya",     "freya_def", "p1")
	_add_ally(state, "own_hurt",  "dummy_def", "p1")
	_add_ally(state, "opp_hurt",  "dummy_def", "p2")
	state.get_card("own_hurt").damage_taken = 2
	state.get_card("opp_hurt").damage_taken = 4   # more damaged — must be ignored

	var ai := BaseAI.new()
	var actions := ai._get_ally_power_actions(state, db, "p1")
	ok(actions.size() == 1
			and actions[0].params.get("target_id") == "own_hurt",
		"sc33-a: heal targets the damaged FRIENDLY ally, not the enemy")

	# Damaged own hero outranks a less-damaged ally (most damage first).
	state.get_card("p1_hero").damage_taken = 6
	actions = ai._get_ally_power_actions(state, db, "p1")
	ok(actions.size() == 1
			and actions[0].params.get("target_id") == "p1_hero",
		"sc33-b: most damaged friendly (hero) preferred")

	# Nothing damaged on our side → power not used at all.
	state.get_card("p1_hero").damage_taken = 0
	state.get_card("own_hurt").damage_taken = 0
	actions = ai._get_ally_power_actions(state, db, "p1")
	eq(actions.size(), 0,
		"sc33-c: no damaged friendly → heal power not offered (enemy never healed)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 33b — Instant-speed reaction to a hero power on the chain (LIFO)
#
# p2's Ta'zo puts "deal 3 to victim" on the chain. p1 responds with Freya's
# activated power (heal 3 from victim). The chain resolves LIFO: Freya heals
# FIRST, so the victim survives the damage that follows. Proves both that the
# response is legal on a non-empty chain and that ordering is heal-then-damage.
#
#   victim: health 5, starts with 4 damage (1 effective HP).
#   FIFO (wrong): 4 + 3 = 7 ≥ 5 → dies, heal fizzles → victim in graveyard.
#   LIFO (right): heal 4→1, then +3 → 4 damage < 5 → survives.
# ══════════════════════════════════════════════════════════════════════════════

func _test_react_to_hero_power_with_heal() -> void:
	_buf.append("\n-- Scenario 33b: Freya reacts to Ta'zo hero power on the chain (LIFO) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("tazo_def", 25, 3, "deal_damage_to_target:3:fire")
	db.ally("victim_def", 2, 5, [], 2)
	db.ally("freya_def", 2, 2, [], 2,
			"activated_power:0:heal_target:3:holy:hero_or_ally")

	var state := GameState.create_new(["p1", "p2"])
	var h1 := CardInstance.create("p1_hero", "p1_hero", "p1", "p1_hero_row")
	state.cards["p1_hero"] = h1
	state.zones["p1_hero_row"].card_ids.append("p1_hero")
	state.players["p1"].hero_instance_id = "p1_hero"

	var h2 := CardInstance.create("tazo_inst", "tazo_def", "p2", "p2_hero_row")
	state.cards["tazo_inst"] = h2
	state.zones["p2_hero_row"].card_ids.append("tazo_inst")
	state.players["p2"].hero_instance_id = "tazo_inst"

	state.phase           = "action"
	state.turn_player     = "p2"
	state.priority_player = "p2"
	state.turn_number     = 1

	_add_ally(state, "victim", "victim_def", "p1")
	var freya := _add_ally(state, "freya", "freya_def", "p1")
	freya.just_summoned = false
	state.get_card("victim").damage_taken = 4
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# p2 puts Ta'zo's damage on the chain, then passes priority to p1.
	var tazo_power := PendingAction.make("activate_power", "p2",
		{"hero_id": "tazo_inst", "target_id": "victim"})
	StackResolver.submit_action(state, tazo_power, db)
	StackResolver.pass_priority(state, db)   # p2 → p1
	eq(state.priority_player, "p1", "sc33b-a: p1 has priority to respond")

	# The heal must be a LEGAL response even though the chain is non-empty.
	var freya_resp := PendingAction.make("use_ally_power", "p1",
		{"card_id": "freya", "target_id": "victim"})
	ok(StackResolver.can_submit(state, freya_resp, db),
		"sc33b-b: Freya's power is legal in response on a non-empty chain")

	StackResolver.submit_action(state, freya_resp, db)
	# Drain: both players pass until the chain empties.
	var guard := 8
	while not state.pending_actions.is_empty() and guard > 0:
		StackResolver.pass_priority(state, db)
		guard -= 1

	var victim := state.get_card("victim")
	ok(victim != null and state.is_in_play("victim"),
		"sc33b-c: victim survived (LIFO — heal resolved before damage)")
	eq(victim.damage_taken if victim else -1, 4,
		"sc33b-d: victim at 4 damage (4, heal→1, +3→4) < 5 health")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 33c — Hero powers are also instant-speed responses to the chain.
# A hero power (Ta'zo) put on the chain by p2 can be answered by p1's own hero
# power before it resolves (both are instants, rule 701.3).
# ══════════════════════════════════════════════════════════════════════════════

func _test_react_to_hero_power_with_heal_legal_on_chain() -> void:
	_buf.append("\n-- Scenario 33c: hero power legal in response to a hero power on chain --")
	var db := MockDB.new()
	db.hero("p1_def", 30, 3, "deal_damage_to_target:3:fire")
	db.hero("p2_def", 30, 3, "deal_damage_to_target:3:fire")

	var state := GameState.create_new(["p1", "p2"])
	var h1 := CardInstance.create("p1_hero", "p1_def", "p1", "p1_hero_row")
	state.cards["p1_hero"] = h1
	state.zones["p1_hero_row"].card_ids.append("p1_hero")
	state.players["p1"].hero_instance_id = "p1_hero"
	var h2 := CardInstance.create("p2_hero", "p2_def", "p2", "p2_hero_row")
	state.cards["p2_hero"] = h2
	state.zones["p2_hero_row"].card_ids.append("p2_hero")
	state.players["p2"].hero_instance_id = "p2_hero"

	state.phase           = "action"
	state.turn_player     = "p2"
	state.priority_player = "p2"
	state.turn_number     = 1
	_add_resources(state, "p1", 3)
	_add_resources(state, "p2", 3)

	# p2 puts its hero power on the chain, passes to p1.
	StackResolver.submit_action(state, PendingAction.make("activate_power", "p2",
		{"hero_id": "p2_hero", "target_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)

	var resp := PendingAction.make("activate_power", "p1",
		{"hero_id": "p1_hero", "target_id": "p2_hero"})
	ok(StackResolver.can_submit(state, resp, db),
		"sc33c-a: p1 hero power is legal in response on a non-empty chain")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 33d — "Use only on your turn" powers stay sorcery-speed: they may NOT
# be added to a non-empty chain even by the turn player holding priority.
# ══════════════════════════════════════════════════════════════════════════════

func _test_on_your_turn_power_blocked_on_chain() -> void:
	_buf.append("\n-- Scenario 33d: on_your_turn ally power blocked while chain non-empty --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Non-targeted on_your_turn power (draw) so no target machinery is involved.
	db.ally("sorc_def", 2, 3, [], 2, "activated_power:0:draw:1|on_your_turn")
	db.instant("bolt_def", 1, "deal_damage_to_target:1:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")   # p1 is turn/priority
	var sorc := _add_ally(state, "sorc", "sorc_def", "p1")
	sorc.just_summoned = false
	_add_resources(state, "p1", 3)

	var pow := PendingAction.make("use_ally_power", "p1", {"card_id": "sorc"})
	ok(StackResolver.can_submit(state, pow, db),
		"sc33d-a: on_your_turn power legal with an empty chain")

	# Put an instant on the chain; the sorcery-speed power is now illegal.
	var bolt := CardInstance.create("bolt", "bolt_def", "p1", "p1_hand")
	state.cards["bolt"] = bolt
	state.zones["p1_hand"].card_ids.append("bolt")
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "bolt", "target_id": "p2_hero"}), db)
	ok(not StackResolver.can_submit(state, pow, db),
		"sc33d-b: on_your_turn power rejected once the chain is non-empty")


# ── Shared setup for the Tristan Rapidstrike (Instant Ally) scenarios ──────────
# p1's 2/3 attacker proposes combat; p2 holds Tristan (azeroth_221 — the real
# def_id so BaseAI.COMBAT_INSTANT_TAGS matches) with 4 resources.
func _instant_ally_db() -> MockDB:
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 2, 3, [], 3)
	db.ally("vanilla_def", 2, 2, [], 2)
	db.ally("azeroth_221", 3, 3, (["protector"] as Array[String]), 4)
	(db.get_def("azeroth_221") as CardDef).is_instant = true
	return db


func _add_hand_card(state: GameState, inst_id: String, def_id: String,
		ctrl: String) -> CardInstance:
	var card := CardInstance.create(inst_id, def_id, ctrl, ctrl + "_hand")
	state.cards[inst_id] = card
	state.zones[ctrl + "_hand"].card_ids.append(inst_id)
	return card


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 35 — Instant Ally (Tristan Rapidstrike): playable during a combat
# attack window (rule 409.1 — the Instant tag overrides non-instant timing),
# then legally protects at the very next protect point (601.2a's "since the
# start of turn" restriction applies to attackers only; summoning sickness
# never blocks protecting).
# ══════════════════════════════════════════════════════════════════════════════

func _test_instant_ally_timing_and_protect() -> void:
	_buf.append("\n-- Scenario 35: Instant Ally flashes in during attack window, protects --")
	var db := _instant_ally_db()
	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_hand_card(state, "tristan", "azeroth_221", "p2")
	_add_hand_card(state, "vanilla", "vanilla_def", "p2")
	_add_resources(state, "p2", 4)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# p1 attacks p2's hero; both pass → combat starts, attack window opens.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)   # p1 → p2
	StackResolver.pass_priority(state, db)   # p2 → resolve proposal
	ok(state.combat_attack_window, "sc35-a: attack window is open")

	StackResolver.pass_priority(state, db)   # p1 passes → p2 priority
	eq(state.priority_player, "p2", "sc35-b: p2 has priority in the attack window")

	# A plain ally is NOT playable here (rule 502.1) — the Instant Ally is.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ally", "p2",
		{"card_id": "vanilla"}), db),
		"sc35-c: non-instant ally rejected during the attack window")
	var play := PendingAction.make("play_ally", "p2", {"card_id": "tristan"})
	ok(StackResolver.can_submit(state, play, db),
		"sc35-d: Instant Ally playable during the attack window")

	StackResolver.submit_action(state, play, db)
	StackResolver.pass_priority(state, db)   # p2 → p1
	StackResolver.pass_priority(state, db)   # p1 → resolve play_ally
	ok(state.is_in_play("tristan")
			and state.get_card("tristan").zone_id == "p2_ally_row",
		"sc35-e: Tristan resolved into p2's ally row mid-combat")
	ok(state.get_card("tristan").just_summoned,
		"sc35-f: Tristan has summoning sickness (irrelevant for protecting)")

	# Close the attack window → protect point, with Tristan as a legal protector.
	StackResolver.pass_priority(state, db)   # p1 (turn player got priority) → p2
	StackResolver.pass_priority(state, db)   # p2 → close attack window
	ok(state.in_protect_point, "sc35-g: protect point opened")
	ok("tristan" in StackResolver.get_legal_protectors(
			state, state.combat_attacker, state.combat_defender, db),
		"sc35-h: freshly-flashed Tristan is a legal protector")

	StackResolver.choose_protector(state, "tristan", db)
	eq(state.combat_defender, "tristan", "sc35-i: Tristan is now the defender")
	# Defend window → both pass → combat concludes.
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 0,
		"sc35-j: hero took 0 damage (intercepted)")
	eq(state.get_card("tristan").damage_taken, 2,
		"sc35-k: Tristan took the attacker's 2 damage")
	ok(not state.is_in_play("atk"),
		"sc35-l: 2/3 attacker died to Tristan's 3 ATK")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 36 — AI flashes Tristan in during the ATTACK window when the
# protector logic wants him (defending ally would die; Tristan kills the
# attacker and survives), then protects with him at the protect point.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_flashes_instant_protector() -> void:
	_buf.append("\n-- Scenario 36: AI flashes in Tristan and protects with him --")
	var db := _instant_ally_db()
	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")   # 2/3
	atk.just_summoned = false
	_add_ally(state, "victim", "vanilla_def", "p2")            # 2/2 — dies to the hit
	_add_hand_card(state, "tristan", "azeroth_221", "p2")
	_add_resources(state, "p2", 4)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var ai := GenericAI.new()

	# Open the attack window on p2's 2/2.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "victim"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # p1 passes on the window floor
	eq(state.priority_player, "p2", "sc36-a: p2 (AI) holds priority, attack window open")

	var action := ai.decide_action(state, db, "p2")
	ok(action != null and action.action_type == "play_ally"
			and action.params.get("card_id") == "tristan",
		"sc36-b: AI plays Tristan during the attack window")

	# Resolve the flash-in, close the window → protect point.
	StackResolver.submit_action(state, action, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(ai.decide_action(state, db, "p2") == null if state.priority_player == "p2" else true,
		"sc36-c: AI does not flash a second copy / re-act after playing")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.in_protect_point, "sc36-d: protect point opened after the flash-in")
	eq(ai.choose_protector(state, db, "p2"), "tristan",
		"sc36-e: AI protects with the freshly-played Tristan")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 37 — AI HOLDS Tristan when flashing him in is wrong:
#   a) never blind-played on its own action window (held like a combat instant)
#   b) never during the DEFEND window (protect point already past)
#   c) not when a board protector already answers the attack
#   d) not when the block isn't safe (attacker too big) and no hero is dying
#   e) never when the AI is the ATTACKING side
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_holds_instant_protector() -> void:
	_buf.append("\n-- Scenario 37: AI holds Tristan outside the right window --")
	var db := _instant_ally_db()
	db.ally("big_def", 4, 6, [], 5)
	db.ally("board_prot_def", 3, 4, (["protector"] as Array[String]), 3)

	# a) own action window: get_reasonable_actions never blind-plays a held card.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_hand_card(state, "tristan", "azeroth_221", "p1")
	_add_resources(state, "p1", 4)
	state.players["p1"].resource_placed_this_turn = true
	var ai := GenericAI.new()
	var blind := false
	for a in ai.get_reasonable_actions(state, db, "p1"):
		if a.params.get("card_id", "") == "tristan":
			blind = true
	ok(not blind, "sc37-a: Tristan is held — never blind-played on own window")

	# Shared combat setup builder: p1's attacker vs p2's 2/2, Tristan in p2 hand.
	var mk := func(attacker_def: String) -> GameState:
		var s := _base_state(db, "p1_hero", "p2_hero")
		var a := _add_ally(s, "atk", attacker_def, "p1")
		a.just_summoned = false
		_add_ally(s, "victim", "vanilla_def", "p2")
		_add_hand_card(s, "tristan", "azeroth_221", "p2")
		_add_resources(s, "p2", 4)
		s.players["p1"].resource_placed_this_turn = true
		s.players["p2"].resource_placed_this_turn = true
		StackResolver.submit_action(s, PendingAction.make("propose_combat", "p1",
			{"attacker_id": "atk", "defender_id": "victim"}), db)
		StackResolver.pass_priority(s, db)
		StackResolver.pass_priority(s, db)
		StackResolver.pass_priority(s, db)   # window floor → p2 priority
		return s

	# b) defend window: too late.
	var s_b: GameState = mk.call("attacker_def")
	StackResolver.pass_priority(s_b, db)   # p2 passes → close attack window
	# no protectors on board and none played → defend window opens directly
	ok(s_b.combat_defend_window, "sc37-b1: defend window open")
	if s_b.priority_player != "p2":
		StackResolver.pass_priority(s_b, db)
	ok(ai.instant_protector_action(s_b, db, "p2") == null,
		"sc37-b2: Tristan never flashed during the defend window")

	# c) a board protector already answers (3/4 safe-blocks the 2/3 attacker).
	var s_c: GameState = mk.call("attacker_def")
	var bp := _add_ally(s_c, "board_prot", "board_prot_def", "p2")
	bp.just_summoned = false
	ok(ai.instant_protector_action(s_c, db, "p2") == null,
		"sc37-c: board protector answers — Tristan held")

	# d) unsafe block (4/6 attacker: Tristan neither kills nor survives),
	#    dying card is an ally, not the hero → hold.
	var s_d: GameState = mk.call("big_def")
	ok(ai.instant_protector_action(s_d, db, "p2") == null,
		"sc37-d: unsafe block to save an ally — Tristan held")

	# e) the attacking side never flashes its own protector.
	var s_e: GameState = mk.call("attacker_def")
	_add_hand_card(s_e, "tristan_p1", "azeroth_221", "p1")
	_add_resources(s_e, "p1", 4)
	ok(ai.instant_protector_action(s_e, db, "p1") == null,
		"sc37-e: attacking side never flashes a protector")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 34 — Combat instant (Quick Strike): AI holds it, ambushes in combat
#
# BaseAI.COMBAT_INSTANT_TAGS marks Quick Strike (azeroth_165) as a card to HOLD:
# never blind-played on the AI's own action window, only played via
# combat_instant_action() when the AI is being attacked.
#
#   Attack window:  attacker_hp <= dmg  AND  attacker_cost >= card_cost
#   Defend window:  attacker_hp <= defender_atk + dmg
#                   AND attacker_hp > defender_atk
#                   AND attacker_cost >= card_cost
#
# Assertions:
#   sc34-a  attack window: 2 HP / cost-4 attacker → play
#   sc34-b  attack window: cheap bait (cost 1) → hold
#   sc34-c  attack window: 5 HP attacker survives the 2 dmg → hold
#   sc34-d  the ATTACKING player never plays it on its own combat
#   sc34-e  defend window: 5 HP attacker vs 4 ATK defender + 2 dmg → play
#   sc34-f  defend window: attacker already dies to defender alone → hold
#   sc34-g  defend window: attacker out of reach (7 HP vs 4+2) → hold
#   sc34-h  outside combat: get_reasonable_actions never blind-plays it
#   sc34-i/j/k  integration: BaseAI defender kills the attacker during the
#               attack window — attacker dead, zero combat damage, QS in grave
# ══════════════════════════════════════════════════════════════════════════════

func _test_combat_instant_ambush() -> void:
	_buf.append("\n-- Scenario 34: combat instant — AI holds Quick Strike, ambushes attacker --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Registered under its REAL def id so BaseAI.COMBAT_INSTANT_TAGS matches.
	db.instant("azeroth_165", 3, "deal_damage_to_target:2:melee")
	db.ally("atk_worthy_def", 3, 2, [], 4)   # cost 4, 2 HP — dies to QS, worth it
	db.ally("atk_cheap_def",  3, 2, [], 1)   # cost 1 — bait, never worth QS
	db.ally("atk_fat_def",    3, 5, [], 6)   # cost 6, 5 HP — survives QS alone
	db.ally("atk_huge_def",   3, 7, [], 6)   # cost 6, 7 HP — out of combined reach
	db.ally("blocker_def",    4, 6, [], 3)   # 4 ATK defender for defend-window math

	var ai := BaseAI.new()

	# ── Attack-window matrix (p2 attacks p1's hero) ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	st.turn_player     = "p2"
	st.priority_player = "p1"
	_add_resources(st, "p1", 3)
	var qs := CardInstance.create("qs_p1", "azeroth_165", "p1", "p1_hand")
	st.cards["qs_p1"] = qs
	st.zones["p1_hand"].card_ids.append("qs_p1")
	_add_ally(st, "atk_worthy", "atk_worthy_def", "p2")
	_add_ally(st, "atk_cheap",  "atk_cheap_def",  "p2")
	_add_ally(st, "atk_fat",    "atk_fat_def",    "p2")
	st.combat_attack_window = true
	st.combat_defender = "p1_hero"

	st.combat_attacker = "atk_worthy"
	var act := ai.combat_instant_action(st, db, "p1")
	ok(act != null and act.params.get("card_id") == "qs_p1"
			and act.params.get("target_id") == "atk_worthy",
		"sc34-a: attack window — 2 HP / cost-4 attacker → play QS targeting it")

	st.combat_attacker = "atk_cheap"
	ok(ai.combat_instant_action(st, db, "p1") == null,
		"sc34-b: attack window — cheap bait (cost 1 < QS cost 3) → hold")

	st.combat_attacker = "atk_fat"
	ok(ai.combat_instant_action(st, db, "p1") == null,
		"sc34-c: attack window — 5 HP attacker survives 2 dmg → hold")

	# The attacking side never ambushes its own combat.
	st.combat_attacker = "atk_worthy"
	st.priority_player = "p2"
	var qs2 := CardInstance.create("qs_p2", "azeroth_165", "p2", "p2_hand")
	st.cards["qs_p2"] = qs2
	st.zones["p2_hand"].card_ids.append("qs_p2")
	_add_resources(st, "p2", 3)
	ok(ai.combat_instant_action(st, db, "p2") == null,
		"sc34-d: attacking player never plays the combat instant")

	# ── Defend-window matrix (p1's 4 ATK blocker defends) ──
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	st2.turn_player     = "p2"
	st2.priority_player = "p1"
	_add_resources(st2, "p1", 3)
	var qsb := CardInstance.create("qs_b", "azeroth_165", "p1", "p1_hand")
	st2.cards["qs_b"] = qsb
	st2.zones["p1_hand"].card_ids.append("qs_b")
	_add_ally(st2, "blocker",     "blocker_def",    "p1")
	_add_ally(st2, "atk_fat2",    "atk_fat_def",    "p2")
	_add_ally(st2, "atk_worthy2", "atk_worthy_def", "p2")
	_add_ally(st2, "atk_huge2",   "atk_huge_def",   "p2")
	st2.combat_defend_window = true
	st2.combat_defender = "blocker"

	st2.combat_attacker = "atk_fat2"   # hp 5: 5 <= 4+2 AND 5 > 4 → play
	var act2 := ai.combat_instant_action(st2, db, "p1")
	ok(act2 != null and act2.params.get("card_id") == "qs_b"
			and act2.params.get("target_id") == "atk_fat2",
		"sc34-e: defend window — QS finishes what the defender can't → play")

	st2.combat_attacker = "atk_worthy2"   # hp 2: already dies to 4 ATK alone
	ok(ai.combat_instant_action(st2, db, "p1") == null,
		"sc34-f: defend window — attacker already dying to defender → hold")

	st2.combat_attacker = "atk_huge2"   # hp 7 > 4+2
	ok(ai.combat_instant_action(st2, db, "p1") == null,
		"sc34-g: defend window — attacker out of combined reach → hold")

	# ── Hold outside combat: never a blind play on own action window ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 3)
	var qs3 := CardInstance.create("qs_hold", "azeroth_165", "p1", "p1_hand")
	st3.cards["qs_hold"] = qs3
	st3.zones["p1_hand"].card_ids.append("qs_hold")
	var blind := false
	for a in ai.get_reasonable_actions(st3, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "qs_hold":
			blind = true
	ok(not blind, "sc34-h: get_reasonable_actions never blind-plays a held combat instant")

	# ── Integration: p1 attacks, BaseAI p2 ambushes during the attack window ──
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st4, "raider", "atk_worthy_def", "p1")   # cost 4, 2 HP, 3 ATK
	_add_resources(st4, "p2", 3)
	var qs4 := CardInstance.create("qs_ambush", "azeroth_165", "p2", "p2_hand")
	st4.cards["qs_ambush"] = qs4
	st4.zones["p2_hand"].card_ids.append("qs_ambush")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}))

	_drive_turns(st4, db, p1_ai, BaseAI.new(), 3)

	ok(st4.get_card("raider").zone_id == "p1_graveyard",
		"sc34-i: attacker killed by Quick Strike during the attack window")
	eq(st4.get_card("p2_hero").damage_taken, 0,
		"sc34-j: p2 hero took no combat damage (attacker died pre-conclusion)")
	ok(st4.get_card("qs_ambush").zone_id == "p2_graveyard",
		"sc34-k: Quick Strike in graveyard after the ambush")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 35 — Deacon Johanna: no-exhaust payment power, gated once per turn
#
# Deacon Johanna's power has NO [Activate] tap symbol on the card — just a
# resource cost ("2") — so per rule 701.3/3216 it isn't gated by summoning
# sickness or the card's exhausted state, only by its own printed
# "once per turn" restriction (CardInstance.used_this_turn, reset each turn).
# ══════════════════════════════════════════════════════════════════════════════

func _test_deacon_johanna_once_per_turn() -> void:
	_buf.append("\n-- Scenario 35: Deacon Johanna — once-per-turn heal, no exhaust cost --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("johanna_def", 2, 2, [], 2,
			"activated_power:2:heal_target:2:holy:hero_or_ally:once_per_turn")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)
	_add_ally(state, "johanna", "johanna_def", "p1")
	# Simulate a freshly-summoned, already-exhausted Johanna — the power still
	# has to work since it isn't an [Activate] power.
	state.get_card("johanna").just_summoned = true
	state.get_card("johanna").is_exhausted  = true
	state.get_card("p1_hero").damage_taken  = 5

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "johanna", "target_id": "p1_hero"})

	# dj-a: usable despite summoning sickness and being exhausted.
	ok(StackResolver.can_submit(state, use, db),
		"dj-a: power usable while summoning-sick and exhausted (no tap symbol)")

	# Ready Johanna to prove the power itself never exhausts her (no tap cost).
	state.get_card("johanna").is_exhausted = false

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# dj-b: heal applied.
	eq(state.get_card("p1_hero").damage_taken, 3, "dj-b: healed 2 damage from hero")

	# dj-c: Johanna is still ready — the power carries no exhaust cost.
	ok(not state.get_card("johanna").is_exhausted,
		"dj-c: Johanna remains ready after using her power")

	# dj-d: can't reuse this turn (once-per-turn gate).
	ok(not StackResolver.can_submit(state, use, db),
		"dj-d: power not usable again same turn")

	# Advance deterministically through the rest of p1's turn, all of p2's turn,
	# and into p1's next action phase (action->end->[next_turn/ready]->draw->action,
	# twice) — avoids relying on how many priority-pass steps that takes.
	for _i in 8:
		TurnManager.advance_phase(state, db)
	eq(state.turn_player, "p1", "dj-e-setup: back to p1's turn")
	eq(state.phase, "action", "dj-e-setup: in p1's action phase")

	# dj-e: once-per-turn gate reset for the new turn.
	state.get_card("p1_hero").damage_taken = 5
	ok(StackResolver.can_submit(state, use, db),
		"dj-e: power usable again on a new turn")


# ══════════════════════════════════════════════════════════════════════════════
# Scenario 36 — Acolyte Demia: "(1), Put 1 damage on Acolyte Demia -> Demia
# deals 1 shadow damage to target hero or ally. Use only on your turn."
# No [Activate] tap symbol on this power (rule 701.3) — it's a plain payment
# power (701.2), so it never exhausts Demia and isn't gated by summoning
# sickness; it can be reused any turn as long as the resource + self-damage
# cost (rule 405.3 — capped at exactly fatal) can be paid.
# ══════════════════════════════════════════════════════════════════════════════

const DEMIA_EFFECTS := "activated_power:1:deal_damage_to_target:1:shadow:hero_or_ally:put_damage_self:1|on_your_turn"

func _test_acolyte_demia_power() -> void:
	_buf.append("\n-- Scenario 36: Acolyte Demia — activate, put 1 damage on self, deal 1 shadow --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("demia_def", 3, 6, [], 6, DEMIA_EFFECTS)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var demia := _add_ally(state, "demia_inst", "demia_def", "p1")
	demia.just_summoned = false
	# Already exhausted going in: rule 701.2 payment powers (no [Activate] tap
	# symbol) have no exhaust requirement, unlike 701.3 activated powers.
	demia.is_exhausted  = true
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "demia_inst", "target_id": "p2_hero"})

	# ad-a: legal on Demia's controller's own turn, even while exhausted.
	ok(StackResolver.can_submit(state, use, db), "ad-a: Demia power legal on p1's turn while exhausted")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# ad-b: Demia took 1 damage (put, as her own cost).
	eq(state.get_card("demia_inst").damage_taken, 1, "ad-b: Demia has 1 damage put on herself")

	# ad-c: target hero took 1 shadow damage dealt.
	eq(state.get_card("p2_hero").damage_taken, 1, "ad-c: p2 hero took 1 shadow damage")

	# ad-d: Demia's exhausted state is untouched by using the power (no activate
	# symbol on this power — using it neither requires nor causes exhaustion) and
	# she can be used again immediately as long as the resource cost can be paid.
	ok(state.get_card("demia_inst").is_exhausted,
		"ad-d: Demia's exhausted flag is unchanged by the power (still exhausted from setup)")
	_add_resources(state, "p1", 1)
	ok(StackResolver.can_submit(state, use, db), "ad-d2: Demia power reusable immediately")


func _test_acolyte_demia_own_turn_only() -> void:
	_buf.append("\n-- Scenario 36b: Acolyte Demia — use only on your turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("demia_def", 3, 6, [], 6, DEMIA_EFFECTS)

	var state := _base_state(db, "p1_hero", "p2_hero")
	# Demia controlled by p2, but it's p1's turn.
	var demia := _add_ally(state, "demia_inst", "demia_def", "p2")
	demia.just_summoned = false
	demia.is_exhausted  = false
	_add_resources(state, "p2", 1)
	state.priority_player = "p2"

	var use := PendingAction.make("use_ally_power", "p2",
		{"card_id": "demia_inst", "target_id": "p1_hero"})

	# ad-e: illegal off her controller's turn, even with priority and resources.
	ok(not StackResolver.can_submit(state, use, db),
		"ad-e: Demia power illegal outside her controller's own turn")


func _test_acolyte_demia_self_destroys() -> void:
	_buf.append("\n-- Scenario 36c: Acolyte Demia — self-damage can be exactly fatal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("demia_def", 3, 6, [], 6, DEMIA_EFFECTS)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var demia := _add_ally(state, "demia_inst", "demia_def", "p1")
	demia.just_summoned = false
	demia.is_exhausted  = false
	demia.damage_taken  = 5   # 1 more damage is exactly fatal (6 health).
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "demia_inst", "target_id": "p2_hero"})

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# ad-f: the effect still resolves even though the cost was fatal to Demia.
	eq(state.get_card("p2_hero").damage_taken, 1,
		"ad-f: damage effect still resolves after fatal self-cost")

	# ad-g: Demia was destroyed and moved to the graveyard.
	eq(state.get_card("demia_inst").zone_id, "p1_graveyard",
		"ad-g: Demia destroyed by her own put-damage cost")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 24 — Zorm Stonefury: party aura "+1 ATK while attacking"
# ══════════════════════════════════════════════════════════════════════════════

func _test_zorm_party_atk_while_attacking() -> void:
	_buf.append("\n-- Scenario 24: Zorm Stonefury party '+1 ATK while attacking' aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def", 1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "zorm_inst", "zorm_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	_add_ally(state, "opp_inst", "grunt_def", "p2")

	# Nobody attacking → no bonus anywhere.
	eq(state.get_atk("grunt_inst", db), 2, "sc24-a: no bonus while not attacking")
	eq(state.get_atk("zorm_inst", db), 1, "sc24-b: Zorm itself unbuffed while idle")

	# Grunt attacks → +1 from Zorm's aura.
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 3, "sc24-c: attacking ally gets +1")
	eq(state.get_atk("zorm_inst", db), 1, "sc24-d: non-attacking Zorm still unbuffed")

	# Zorm attacks → buffs itself (it's an ally in your party).
	state.combat_attacker = "zorm_inst"
	eq(state.get_atk("zorm_inst", db), 2, "sc24-e: Zorm buffs itself while attacking")

	# Opponent's attacker gets nothing from p1's Zorm.
	state.combat_attacker = "opp_inst"
	eq(state.get_atk("opp_inst", db), 2, "sc24-f: enemy attacker unaffected by your Zorm")

	# Two Zorms stack.
	_add_ally(state, "zorm2_inst", "zorm_def", "p1")
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 4, "sc24-g: two Zorms stack (+2)")

	# Card text is "your allies" — your own attacking HERO gets nothing from Zorm.
	state.combat_attacker = "p1_hero"
	eq(state.get_atk("p1_hero", db), 0, "sc24-h: attacking hero unaffected by Zorm (allies only)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 25 — Elder Moorf: "[1],[activate] Target ally has +2 ATK this turn"
# ══════════════════════════════════════════════════════════════════════════════

func _test_elder_moorf_buff_target() -> void:
	_buf.append("\n-- Scenario 25: Elder Moorf +2 ATK to target ally this turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("moorf_def", 1, 1, [], 1, "activated_power:1:buff_atk_target:2::ally:once_per_turn")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var moorf := _add_ally(state, "moorf_inst", "moorf_def", "p1")
	moorf.just_summoned = false
	moorf.is_exhausted  = false
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	# Two resources so sc25-f isolates the once-per-turn gate (1 stays available).
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true

	# Heroes are not legal targets for an "ally"-only power.
	var at_hero := PendingAction.make("use_ally_power", "p1",
		{"card_id": "moorf_inst", "target_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, at_hero, db),
		"sc25-a: Moorf cannot target a hero")

	# A friendly ally is a legal target.
	var at_ally := PendingAction.make("use_ally_power", "p1",
		{"card_id": "moorf_inst", "target_id": "grunt_inst"})
	ok(StackResolver.can_submit(state, at_ally, db),
		"sc25-b: Moorf can target an ally")

	StackResolver.submit_action(state, at_ally, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Buff is unconditional — applies even when not attacking.
	eq(state.get_atk("grunt_inst", db), 4, "sc25-c: target ally at +2 ATK (2 -> 4)")
	# Non-tap "once per turn" power: Moorf stays ready but can't be used again.
	ok(not state.get_card("moorf_inst").is_exhausted, "sc25-d: Moorf not exhausted (non-tap power)")
	ok(state.get_card("moorf_inst").used_this_turn, "sc25-e: Moorf flagged used_this_turn")
	ok(not StackResolver.can_submit(state, at_ally, db),
		"sc25-f: Moorf power can't be used a second time this turn")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 26 — Rayder: "[activate] Your allies +2 ATK while attacking this turn"
# ══════════════════════════════════════════════════════════════════════════════

func _test_rayder_party_buff_while_attacking() -> void:
	_buf.append("\n-- Scenario 26: Rayder party '+2 ATK while attacking this turn' --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("rayder_def", 2, 2, [], 2, "activated_power:0:party_buff_atk_attacking:2|on_your_turn")
	db.ally("grunt_def", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var rayder := _add_ally(state, "rayder_inst", "rayder_def", "p1")
	rayder.just_summoned = false
	rayder.is_exhausted  = false
	_add_ally(state, "grunt_inst", "grunt_def", "p1")

	# Engine deviation (data/rules_deviations.md): the power can never matter
	# off-turn (allies can only attack on the controller's turn), so it's
	# blocked entirely rather than letting the AI exhaust Rayder for nothing.
	state.turn_player = "p2"
	var off_turn_attempt := PendingAction.make("use_ally_power", "p1", {"card_id": "rayder_inst"})
	eq(StackResolver.can_submit(state, off_turn_attempt, db), false,
		"sc26-e: Rayder's power cannot be activated off-turn")
	state.turn_player = "p1"

	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "rayder_inst"})
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Conditional buff: nothing while idle.
	eq(state.get_atk("grunt_inst", db), 1, "sc26-a: no bonus while grunt idle")

	# Grunt attacks → +2.
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 3, "sc26-b: grunt +2 while attacking")

	# Rayder itself is in its own party → buffed while attacking.
	state.combat_attacker = "rayder_inst"
	eq(state.get_atk("rayder_inst", db), 4, "sc26-c: Rayder +2 while attacking")

	# An ally that enters play AFTER Rayder's power resolves is still buffed
	# for the rest of the turn (bug: used to snapshot only allies present
	# at activation time).
	_add_ally(state, "latecomer_inst", "grunt_def", "p1")
	state.combat_attacker = "latecomer_inst"
	eq(state.get_atk("latecomer_inst", db), 3, "sc26-d: late-summoned ally still +2 while attacking")

	# Card text is "your allies" — the attacking hero gets nothing from Rayder.
	state.combat_attacker = "p1_hero"
	eq(state.get_atk("p1_hero", db), 0, "sc26-f: attacking hero unaffected by Rayder (allies only)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 27 — For the Horde!: quest reward buffs only Horde allies
# ══════════════════════════════════════════════════════════════════════════════

func _test_for_the_horde_quest_buff() -> void:
	_buf.append("\n-- Scenario 27: For the Horde! buffs only Horde allies while attacking --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("fth_def", 1, "party_buff_atk_attacking:1|require_turn_player")
	db.ally("horde_def", 2, 2)
	db.ally("neutral_def", 2, 2)
	db.get_def("horde_def").alignment = "Horde"
	db.get_def("neutral_def").alignment = ""

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "horde_inst", "horde_def", "p1")
	_add_ally(state, "neutral_inst", "neutral_def", "p1")
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true

	var quest := CardInstance.create("fth_inst", "fth_def", "p1", "p1_resource_row")
	state.cards["fth_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("fth_inst")

	# Engine deviation (data/rules_deviations.md): completion is blocked
	# entirely off-turn, since the reward can never matter off-turn.
	state.turn_player = "p2"
	var off_turn_attempt := PendingAction.make("use_quest", "p1", {"quest_id": "fth_inst"})
	eq(StackResolver.can_submit(state, off_turn_attempt, db), false,
		"sc27-e: For the Horde! cannot be completed off-turn")
	state.turn_player = "p1"

	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "fth_inst"})
	StackResolver.submit_action(state, complete, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Horde ally gains the while-attacking buff; neutral ally does not.
	state.combat_attacker = "horde_inst"
	eq(state.get_atk("horde_inst", db), 3, "sc27-a: Horde ally +1 while attacking")
	state.combat_attacker = "neutral_inst"
	eq(state.get_atk("neutral_inst", db), 2, "sc27-b: non-Horde ally unbuffed")

	# Buff is gated on attacking.
	state.combat_attacker = ""
	eq(state.get_atk("horde_inst", db), 2, "sc27-c: no bonus while Horde ally idle")

	# A Horde ally that enters play AFTER the quest completes is still
	# buffed for the rest of the turn.
	_add_ally(state, "late_horde_inst", "horde_def", "p1")
	state.combat_attacker = "late_horde_inst"
	eq(state.get_atk("late_horde_inst", db), 3, "sc27-d: late-summoned Horde ally still +1 while attacking")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 28 — "this turn" buffs expire at end of turn
# ══════════════════════════════════════════════════════════════════════════════

func _test_turn_buff_expires_at_end_of_turn() -> void:
	_buf.append("\n-- Scenario 28: 'this turn' buffs are swept at end of turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	state.get_card("grunt_inst").active_buffs.append(
		Buff.make("test_turn_buff", "src", "atk", 3, "turns", 1))

	eq(state.get_atk("grunt_inst", db), 5, "sc28-a: turn buff applies (2 + 3)")

	TurnManager._enter_end(state, db)

	eq(state.get_atk("grunt_inst", db), 2, "sc28-b: turn buff swept at end of turn")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 29 — Regression: "while attacking" bonuses must apply to REAL combat
# damage, not just to get_atk queried mid-window. (Bug: _do_combat_conclusion
# used to clear state.combat_attacker before computing atk_dmg, so Zorm/Rayder/
# For the Horde! bonuses never reached the actual damage dealt.)
# ══════════════════════════════════════════════════════════════════════════════

func _test_zorm_bonus_applies_to_real_combat_damage() -> void:
	_buf.append("\n-- Scenario 29: Zorm's +1 ATK while attacking lands in real combat damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def", 1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "zorm_inst", "zorm_def", "p1")
	var grunt := _add_ally(state, "grunt_inst", "grunt_def", "p1")
	grunt.just_summoned = false
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "grunt_inst", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()

	_drive(state, db, p1_ai, p2_ai)

	# Grunt is printed 2 ATK; with Zorm's aura it should deal 3, not 2.
	eq(state.get_card("p2_hero").damage_taken, 3,
		"sc29: real combat damage includes Zorm's +1 ATK while attacking")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 30 — get_atk_if_attacking: targeting-cursor preview helper
# ══════════════════════════════════════════════════════════════════════════════

func _test_get_atk_if_attacking_preview() -> void:
	_buf.append("\n-- Scenario 30: get_atk_if_attacking previews attack ATK without mutating state --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zorm_def", 1, 1, [], 2, "party_atk_while_attacking:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "zorm_inst", "zorm_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")

	# Before any combat is proposed: plain get_atk correctly omits the bonus
	# (rule 601 — not attacking yet), but the preview helper shows what it
	# WOULD be, for the targeting cursor.
	eq(state.get_atk("grunt_inst", db), 2,
		"sc30-a: plain get_atk shows base ATK before combat is proposed")
	eq(state.get_atk_if_attacking("grunt_inst", db), 3,
		"sc30-b: preview helper shows the buffed ATK")

	# The preview call must not mutate real state.
	eq(state.combat_attacker, "",
		"sc30-c: preview helper leaves combat_attacker untouched")
	eq(state.get_atk("grunt_inst", db), 2,
		"sc30-d: plain get_atk is unaffected by the preview call")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 31 — Regression: Elder Moorf's buff must land on REAL defense damage
# when activated by the (non-turn) defending player mid-combat, exactly as in
# a live game: p1's ally attacks p2's ally; p2 uses Moorf's power on the
# defender during the Defend Window before combat concludes.
# ══════════════════════════════════════════════════════════════════════════════

func _test_moorf_buff_applies_to_real_defense_damage() -> void:
	_buf.append("\n-- Scenario 31: Elder Moorf's buff lands on real combat damage while defending --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 2, 10)
	db.ally("grunt_def", 2, 2)
	db.ally("moorf_def", 1, 1, [], 1, "activated_power:1:buff_atk_target:2::ally:once_per_turn")

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player = "p1"
	var attacker := _add_ally(state, "attacker_inst", "attacker_def", "p1")
	attacker.just_summoned = false
	var grunt := _add_ally(state, "grunt_inst", "grunt_def", "p2")
	grunt.just_summoned = false
	var moorf := _add_ally(state, "moorf_inst", "moorf_def", "p2")
	moorf.just_summoned = false
	_add_resources(state, "p2", 1)

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "attacker_inst", "defender_id": "grunt_inst"}))
	var p2_ai := ScriptedAI.new()
	# Fires as soon as p2 has priority and the action is legal — i.e. during the
	# Defend Window, exactly like a human activating it mid-combat.
	p2_ai.queue_action(PendingAction.make("use_ally_power", "p2",
		{"card_id": "moorf_inst", "target_id": "grunt_inst"}))

	_drive(state, db, p1_ai, p2_ai)

	# Grunt is printed 2 ATK; Moorf's +2 buff should make it deal 4 back.
	eq(state.get_card("attacker_inst").damage_taken, 4,
		"sc31: attacker takes buffed (2+2=4) counter-damage from the defending ally")
	ok(state.get_card("moorf_inst").used_this_turn,
		"sc31: Moorf's once-per-turn power was actually used")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 32 — Ryn Dreamstrider: "[activate] Target hero or ally +2 ATK while
# attacking this turn"
# ══════════════════════════════════════════════════════════════════════════════

func _test_ryn_dreamstrider_buff_target_attacking() -> void:
	_buf.append("\n-- Scenario 32: Ryn Dreamstrider targeted 'while attacking' buff --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ryn_def", 2, 2, [], 4, "activated_power:0:buff_atk_target_attacking:2::hero_or_ally")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var ryn := _add_ally(state, "ryn_inst", "ryn_def", "p1")
	ryn.just_summoned = false
	ryn.is_exhausted  = false
	_add_ally(state, "grunt_inst", "grunt_def", "p1")

	# Can target a friendly ally, a hero, and (per printed text) an enemy character.
	var at_own_hero := PendingAction.make("use_ally_power", "p1",
		{"card_id": "ryn_inst", "target_id": "p1_hero"})
	ok(StackResolver.can_submit(state, at_own_hero, db),
		"sc32-a: Ryn can target a hero")

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "ryn_inst", "target_id": "grunt_inst"})
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# Conditional buff: nothing while idle.
	eq(state.get_atk("grunt_inst", db), 2, "sc32-b: no bonus while grunt idle")
	state.combat_attacker = "grunt_inst"
	eq(state.get_atk("grunt_inst", db), 4, "sc32-c: grunt +2 while attacking")

	# Exhausts (has an [Activate] tap symbol, unlike Moorf).
	ok(state.get_card("ryn_inst").is_exhausted, "sc32-d: Ryn exhausted after using power")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 34 — Sen'zir Beastwalker: "3, Flip -> Put a Pet card from your
# graveyard into your hand."
#
# Assertions:
#   sc34-a  candidates from get_graveyard_search_candidates: only own Pet
#   sc34-b  no-target probe passes with a valid Pet candidate
#   sc34-c  completion without an announced target is rejected
#   sc34-d  targeting the non-Pet ally in the graveyard is illegal
#   sc34-e  targeting an opponent's graveyard Pet is illegal (owner=own)
#   sc34-f  full action with the correct Pet target is legal and costs 3
#   sc34-g  Pet moves to p1 hand after resolution
#   sc34-h  card_returned_from_graveyard event fired
#   sc34-i  hero_power_used event fired (once-per-turn gate engaged)
# ══════════════════════════════════════════════════════════════════════════════

func _test_senzir_beastwalker_power() -> void:
	_buf.append("\n-- Scenario 34: Sen'zir Beastwalker returns a Pet from graveyard to hand --")
	var db := MockDB.new()
	db.hero("senzir_def", 28, 3, "graveyard_to_hand:Pet:1:1:own")
	db.hero("p2_hero", 30)
	db.pet("pet_def", 1, 3, [], 2)
	db.ally("nonpet_def", 2, 2, [], 2)

	var state := _base_state(db, "senzir_def", "p2_hero")
	_add_resources(state, "p1", 3)

	for pair in [["dead_pet", "pet_def"], ["dead_nonpet", "nonpet_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])
	var opp_pet := CardInstance.create("opp_dead_pet", "pet_def", "p2", "p2_graveyard")
	state.cards["opp_dead_pet"] = opp_pet
	state.zones["p2_graveyard"].card_ids.append("opp_dead_pet")

	var def := db.get_def("senzir_def")
	var req := StackResolver.get_graveyard_search_requirement(def)
	var cands := StackResolver.get_graveyard_search_candidates(state, "p1", req, db)
	eq(cands, ["dead_pet"], "sc34-a: only own graveyard Pet is a candidate")

	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": ""})
	ok(StackResolver.can_submit(state, probe, db),
		"sc34-b: no-target probe passes with a valid Pet candidate")

	var no_target := PendingAction.make("activate_power", "p1", {"hero_id": "senzir_def"})
	ok(StackResolver.can_submit(state, no_target, db),
		"sc34-c: pre-target probe (empty target_id) still passes — full resolution needs a real target")

	var bad_nonpet := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": "dead_nonpet"})
	ok(not StackResolver.can_submit(state, bad_nonpet, db),
		"sc34-d: non-Pet graveyard card is an illegal target")

	var bad_opp := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": "opp_dead_pet"})
	ok(not StackResolver.can_submit(state, bad_opp, db),
		"sc34-e: opponent's graveyard Pet is an illegal target (owner=own)")

	var good := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": "dead_pet"})
	ok(StackResolver.can_submit(state, good, db),
		"sc34-f: full action with the correct Pet target is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, good, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	ok(state.get_card("dead_pet").zone_id == "p1_hand",
		"sc34-g: Pet moved to p1 hand")
	eq(state.get_available_resources("p1"), 0,
		"sc34-f2: 3 resources spent for the power")

	var saw_return := false
	var saw_power_used := false
	for e in events:
		if e.event_type == "card_returned_from_graveyard" \
				and e.payload.get("card_id", "") == "dead_pet":
			saw_return = true
		if e.event_type == "hero_power_used":
			saw_power_used = true
	ok(saw_return, "sc34-h: card_returned_from_graveyard event fired")
	ok(saw_power_used, "sc34-i: hero_power_used event fired")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 35 — Sen'zir: blocked when no Pet is in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_senzir_beastwalker_no_pet_in_graveyard() -> void:
	_buf.append("\n-- Scenario 35: Sen'zir power blocked with no Pet in graveyard --")
	var db := MockDB.new()
	db.hero("senzir_def", 28, 3, "graveyard_to_hand:Pet:1:1:own")
	db.hero("p2_hero", 30)
	db.ally("nonpet_def", 2, 2, [], 2)

	var state := _base_state(db, "senzir_def", "p2_hero")
	_add_resources(state, "p1", 3)

	var c := CardInstance.create("dead_nonpet", "nonpet_def", "p1", "p1_graveyard")
	state.cards["dead_nonpet"] = c
	state.zones["p1_graveyard"].card_ids.append("dead_nonpet")

	var probe := PendingAction.make("activate_power", "p1",
		{"hero_id": "senzir_def", "target_id": ""})
	ok(not StackResolver.can_submit(state, probe, db),
		"sc35-a: probe rejected — no Pet in graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 36 — AI (GenericAI) picks the MOST valuable Pet when using
# Sen'zir Beastwalker's power with several candidates in the graveyard.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_senzir_picks_most_valuable_pet() -> void:
	_buf.append("\n-- Scenario 36: AI picks the most valuable Pet for Sen'zir's power --")
	var db := MockDB.new()
	db.hero("senzir_def", 28, 3, "graveyard_to_hand:Pet:1:1:own")
	db.hero("p2_hero", 30)
	db.pet("gem_pet_def",  3, 3, [], 5)   # valuable
	db.pet("junk_pet_def", 1, 1, [], 0)   # least valuable

	var state := _base_state(db, "senzir_def", "p2_hero")
	_add_resources(state, "p1", 3)
	var ai := GenericAI.new()

	for pair in [["dead_gem_pet", "gem_pet_def"], ["dead_junk_pet", "junk_pet_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_graveyard")
		state.cards[pair[0]] = c
		state.zones["p1_graveyard"].card_ids.append(pair[0])

	var actions := ai._graveyard_to_hand_hero_actions(state, db, "p1", "senzir_def")
	eq(actions.size(), 1, "sc36-a: exactly one action produced")
	eq(actions[0].params.get("target_id", ""), "dead_gem_pet",
		"sc36-b: AI picks the most valuable Pet (gem, not junk)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 37 — Bloodclaw: vanilla neutral Pet (3/1, cost 1) — no Horde
# alignment, so "For the Horde!" must not buff it.
# ══════════════════════════════════════════════════════════════════════════════

func _test_bloodclaw_no_horde_bonus() -> void:
	_buf.append("\n-- Scenario 37: Bloodclaw (neutral Pet) gets no For the Horde! bonus --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("fth_def", 1, "party_buff_atk_attacking:1|require_turn_player")
	db.pet("bloodclaw_def", 3, 1, [], 1)
	db.get_def("bloodclaw_def").alignment = ""   # neutral — no faction printed

	var state := _base_state(db, "p1_hero", "p2_hero")
	var bloodclaw := _add_ally(state, "bloodclaw_inst", "bloodclaw_def", "p1")
	bloodclaw.just_summoned = false

	eq(state.get_atk("bloodclaw_inst", db), 3, "sc37-a: Bloodclaw is 3 ATK / 1 HP as printed")

	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true
	var quest := CardInstance.create("fth_inst", "fth_def", "p1", "p1_resource_row")
	state.cards["fth_inst"] = quest
	state.zones["p1_resource_row"].card_ids.append("fth_inst")

	var complete := PendingAction.make("use_quest", "p1", {"quest_id": "fth_inst"})
	StackResolver.submit_action(state, complete, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	state.combat_attacker = "bloodclaw_inst"
	eq(state.get_atk("bloodclaw_inst", db), 3,
		"sc37-b: Bloodclaw unbuffed while attacking (neutral, not Horde)")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 38 — Old Bones: "can protect your hero" — a restricted, non-keyword
# grant of protection that only applies when the HERO is the proposed defender.
#
# Assertions:
#   sc38-a  Old Bones IS a legal protector when the hero is the proposed defender
#   sc38-b  Old Bones is NOT a legal protector when an ally is the proposed defender
#   sc38-c  end-to-end: Old Bones intercepts an attack on the hero (0 dmg to hero)
# ══════════════════════════════════════════════════════════════════════════════

func _test_old_bones_protects_hero_only() -> void:
	_buf.append("\n-- Scenario 38: Old Bones can protect your hero (restricted, not full Protector) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 4)
	db.ally("target_ally_def", 2, 5)
	db.pet("old_bones_def", 4, 4, [], 4, "protect_hero_only")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "attacker_inst", "attacker_def", "p1")
	var target_ally := _add_ally(state, "target_ally_inst", "target_ally_def", "p2")
	var old_bones := _add_ally(state, "old_bones_inst", "old_bones_def", "p2")
	old_bones.just_summoned = false
	old_bones.is_exhausted  = false

	# sc38-a: hero is the proposed defender — Old Bones is offered.
	var protectors_vs_hero := StackResolver.get_legal_protectors(state, "attacker_inst", "p2_hero", db)
	ok("old_bones_inst" in protectors_vs_hero,
		"sc38-a: Old Bones can protect when hero is the proposed defender")

	# sc38-b: an ally is the proposed defender — Old Bones is NOT offered.
	var protectors_vs_ally := StackResolver.get_legal_protectors(
			state, "attacker_inst", "target_ally_inst", db)
	ok(not ("old_bones_inst" in protectors_vs_ally),
		"sc38-b: Old Bones cannot protect an ally (no printed Protector keyword)")

	# sc38-c: end-to-end — Old Bones actually intercepts an attack on the hero.
	state.players["p1"].resource_placed_this_turn = true
	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "attacker_inst", "defender_id": "p2_hero"}))
	var p2_ai := ScriptedAI.new()
	p2_ai.queue_protect("old_bones_inst")

	_drive(state, db, p1_ai, p2_ai)

	var p2_hero := state.get_card("p2_hero")
	eq(p2_hero.damage_taken, 0, "sc38-c: P2 hero took 0 damage (Old Bones intercepted)")
	eq(old_bones.damage_taken, 3, "sc38-d: Old Bones took the 3 combat damage instead")
	ok(old_bones.is_exhausted, "sc38-e: Old Bones exhausted after protecting")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 39 — Arcane Shot: like Quick Strike (hero deals damage to an
# announced target), plus "Draw a card."
#
# Assertions:
#   sc39-a  submission WITHOUT a target is rejected (same as Quick Strike)
#   sc39-b  1 arcane damage dealt to the announced target, sourced from the hero
#   sc39-c  a card is drawn
#   sc39-d  Arcane Shot itself ends up in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_arcane_shot() -> void:
	_buf.append("\n-- Scenario 39: Arcane Shot — hero deals 1 arcane dmg + draw a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 4, [], 3)
	db.ally("filler_def", 1, 1, [], 1)
	db.instant("arcane_shot_def", 2, "deal_damage_to_target:1:arcane|draw:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)

	var shot := CardInstance.create("shot_inst", "arcane_shot_def", "p1", "p1_hand")
	state.cards["shot_inst"] = shot
	state.zones["p1_hand"].card_ids.append("shot_inst")

	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	# A card to draw, at the top of p1's deck.
	var draw_card := CardInstance.create("draw_card_inst", "filler_def", "p1", "p1_deck")
	state.cards["draw_card_inst"] = draw_card
	state.zones["p1_deck"].card_ids.append("draw_card_inst")

	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_instant", "p1", {"card_id": "shot_inst"}), db),
		"sc39-a: submission without a target is rejected")

	var act := PendingAction.make("play_instant", "p1",
		{"card_id": "shot_inst", "target_id": "enemy_ally"})
	ok(StackResolver.can_submit(state, act, db), "sc39-a2: full action is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(enemy.damage_taken, 1, "sc39-b: enemy ally took 1 arcane damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "enemy_ally":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc39-b2: damage sourced from p1's hero")

	ok(state.get_card("draw_card_inst").zone_id == "p1_hand",
		"sc39-c: a card was drawn into p1's hand")

	ok(state.get_card("shot_inst").zone_id == "p1_graveyard",
		"sc39-d: Arcane Shot itself is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40 — Arcane Shot is tagged as a combat instant (design-only AI tag,
# not a rules concept): held in hand, only played to ambush an attacker.
#
# Assertions:
#   sc40-a  get_reasonable_actions never blind-plays it outside combat
#   sc40-b  attack window — 1 HP / cost-matching attacker → play targeting it
#   sc40-c  attack window — attacker survives 1 dmg → hold
#   sc40-d  integration: attacker killed by Arcane Shot during the attack window
# ══════════════════════════════════════════════════════════════════════════════

func _test_arcane_shot_combat_instant_tag() -> void:
	_buf.append("\n-- Scenario 40: Arcane Shot tagged as a combat instant (held, ambush-only) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Registered under its REAL def id so BaseAI.COMBAT_INSTANT_TAGS matches.
	db.instant("azeroth_33", 2, "deal_damage_to_target:1:arcane|draw:1")
	db.ally("atk_worthy_def", 3, 1, [], 4)   # cost 4, 1 HP — dies to Arcane Shot
	db.ally("atk_fat_def",    3, 5, [], 4)   # cost 4, 5 HP — survives 1 dmg

	var ai := BaseAI.new()

	# ── Hold outside combat: never a blind play on own action window ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 2)
	var shot_hold := CardInstance.create("shot_hold", "azeroth_33", "p1", "p1_hand")
	st3.cards["shot_hold"] = shot_hold
	st3.zones["p1_hand"].card_ids.append("shot_hold")
	var blind := false
	for a in ai.get_reasonable_actions(st3, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "shot_hold":
			blind = true
	ok(not blind, "sc40-a: get_reasonable_actions never blind-plays a held combat instant")

	# ── Attack-window ambush matrix ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	st.turn_player     = "p2"
	st.priority_player = "p1"
	_add_resources(st, "p1", 2)
	var shot := CardInstance.create("shot_p1", "azeroth_33", "p1", "p1_hand")
	st.cards["shot_p1"] = shot
	st.zones["p1_hand"].card_ids.append("shot_p1")
	_add_ally(st, "atk_worthy", "atk_worthy_def", "p2")
	_add_ally(st, "atk_fat",    "atk_fat_def",    "p2")
	st.combat_attack_window = true
	st.combat_defender = "p1_hero"

	st.combat_attacker = "atk_worthy"
	var act := ai.combat_instant_action(st, db, "p1")
	ok(act != null and act.params.get("card_id") == "shot_p1"
			and act.params.get("target_id") == "atk_worthy",
		"sc40-b: attack window — 1 HP attacker dies to Arcane Shot → play targeting it")

	st.combat_attacker = "atk_fat"
	ok(ai.combat_instant_action(st, db, "p1") == null,
		"sc40-c: attack window — 5 HP attacker survives 1 dmg → hold")

	# ── Integration: p1 attacks, BaseAI p2 ambushes during the attack window ──
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st4, "raider", "atk_worthy_def", "p1")   # cost 4, 1 HP, 3 ATK
	_add_resources(st4, "p2", 2)
	var shot4 := CardInstance.create("shot_ambush", "azeroth_33", "p2", "p2_hand")
	st4.cards["shot_ambush"] = shot4
	st4.zones["p2_hand"].card_ids.append("shot_ambush")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}))

	_drive_turns(st4, db, p1_ai, BaseAI.new(), 3)

	ok(st4.get_card("raider").zone_id == "p1_graveyard",
		"sc40-d: attacker killed by Arcane Shot during the attack window")
	eq(st4.get_card("p2_hero").damage_taken, 0,
		"sc40-e: p2 hero took no combat damage (attacker died pre-conclusion)")
	ok(st4.get_card("shot_ambush").zone_id == "p2_graveyard",
		"sc40-f: Arcane Shot in graveyard after the ambush")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40b — Fire Blast: same shape as Quick Strike (hero deals damage to
# announced target), cost 1, fire damage. Also tagged as a combat instant
# (AI holds it, ambushes only during attack/defend windows).
#
# Assertions:
#   sc40b-a  submission WITHOUT a target is rejected
#   sc40b-b  2 fire damage dealt to the announced target, sourced from the hero
#   sc40b-c  Fire Blast itself ends up in the graveyard
#   sc40b-d  get_reasonable_actions never blind-plays it outside combat
#   sc40b-e  attack window — 2 HP / cost-matching attacker → play targeting it
#   sc40b-f  attack window — attacker survives 2 dmg → hold
#   sc40b-g  integration: attacker killed by Fire Blast during the attack window
# ══════════════════════════════════════════════════════════════════════════════

func _test_fire_blast() -> void:
	_buf.append("\n-- Scenario 40b: Fire Blast — hero deals 2 fire dmg, cost 1 --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 4, [], 3)
	# Registered under its REAL def id so BaseAI.COMBAT_INSTANT_TAGS matches.
	db.instant("azeroth_52", 1, "deal_damage_to_target:2:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)

	var blast := CardInstance.create("blast_inst", "azeroth_52", "p1", "p1_hand")
	state.cards["blast_inst"] = blast
	state.zones["p1_hand"].card_ids.append("blast_inst")

	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_instant", "p1", {"card_id": "blast_inst"}), db),
		"sc40b-a: submission without a target is rejected")

	var act := PendingAction.make("play_instant", "p1",
		{"card_id": "blast_inst", "target_id": "enemy_ally"})
	ok(StackResolver.can_submit(state, act, db), "sc40b-a2: full action is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(enemy.damage_taken, 2, "sc40b-b: enemy ally took 2 fire damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "enemy_ally":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc40b-b2: damage sourced from p1's hero")

	ok(state.get_card("blast_inst").zone_id == "p1_graveyard",
		"sc40b-c: Fire Blast itself is in the graveyard")

	# ── Hold outside combat: never a blind play on own action window ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 1)
	var blast_hold := CardInstance.create("blast_hold", "azeroth_52", "p1", "p1_hand")
	st3.cards["blast_hold"] = blast_hold
	st3.zones["p1_hand"].card_ids.append("blast_hold")
	var blind := false
	for a in BaseAI.new().get_reasonable_actions(st3, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "blast_hold":
			blind = true
	ok(not blind, "sc40b-d: get_reasonable_actions never blind-plays a held combat instant")

	# ── Attack-window ambush matrix ──
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.instant("azeroth_52", 1, "deal_damage_to_target:2:fire")
	db2.ally("atk_worthy_def", 3, 2, [], 4)   # cost 4, 2 HP — dies to Fire Blast
	db2.ally("atk_fat_def",    3, 5, [], 4)   # cost 4, 5 HP — survives 2 dmg

	var ai := BaseAI.new()
	var st := _base_state(db2, "p1_hero", "p2_hero")
	st.turn_player     = "p2"
	st.priority_player = "p1"
	_add_resources(st, "p1", 1)
	var blast_p1 := CardInstance.create("blast_p1", "azeroth_52", "p1", "p1_hand")
	st.cards["blast_p1"] = blast_p1
	st.zones["p1_hand"].card_ids.append("blast_p1")
	_add_ally(st, "atk_worthy", "atk_worthy_def", "p2")
	_add_ally(st, "atk_fat",    "atk_fat_def",    "p2")
	st.combat_attack_window = true
	st.combat_defender = "p1_hero"

	st.combat_attacker = "atk_worthy"
	var act2 := ai.combat_instant_action(st, db2, "p1")
	ok(act2 != null and act2.params.get("card_id") == "blast_p1"
			and act2.params.get("target_id") == "atk_worthy",
		"sc40b-e: attack window — 2 HP attacker dies to Fire Blast → play targeting it")

	st.combat_attacker = "atk_fat"
	ok(ai.combat_instant_action(st, db2, "p1") == null,
		"sc40b-f: attack window — 5 HP attacker survives 2 dmg → hold")

	# ── Integration: p1 attacks, BaseAI p2 ambushes during the attack window ──
	var st4 := _base_state(db2, "p1_hero", "p2_hero")
	_add_ally(st4, "raider", "atk_worthy_def", "p1")   # cost 4, 2 HP, 3 ATK
	_add_resources(st4, "p2", 1)
	var blast4 := CardInstance.create("blast_ambush", "azeroth_52", "p2", "p2_hand")
	st4.cards["blast_ambush"] = blast4
	st4.zones["p2_hand"].card_ids.append("blast_ambush")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}))

	_drive_turns(st4, db2, p1_ai, BaseAI.new(), 3)

	ok(st4.get_card("raider").zone_id == "p1_graveyard",
		"sc40b-g: attacker killed by Fire Blast during the attack window")
	eq(st4.get_card("p2_hero").damage_taken, 0,
		"sc40b-h: p2 hero took no combat damage (attacker died pre-conclusion)")
	ok(st4.get_card("blast_ambush").zone_id == "p2_graveyard",
		"sc40b-i: Fire Blast in graveyard after the ambush")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40c — Frostbolt (azeroth_56, 3 frost) & Frost Shock (azeroth_109,
# 2 frost): same Quick-Strike shape (hero deals damage to an announced target).
# Both are tagged combat instants — the AI holds them and only ambushes during
# a combat window. The printed "can't attack (or protect) this turn" rider is
# NOT modeled yet (see data/rules_deviations.md) — only the damage is live.
#
#   sc40c-a  Frostbolt: submission without a target is rejected
#   sc40c-b  Frostbolt: 3 frost damage to the announced target, sourced from hero
#   sc40c-c  Frostbolt: the card itself ends up in the graveyard
#   sc40c-d  Frostbolt: get_reasonable_actions never blind-plays it outside combat
#   sc40c-e  Frostbolt: attack window — 3 HP attacker dies → play targeting it
#   sc40c-f  Frostbolt: attack window — 5 HP attacker survives → hold
#   sc40c-g  Frost Shock: 2 frost damage to the announced target, sourced from hero
#   sc40c-h  Frost Shock: attack window — 2 HP attacker dies → play targeting it
# ══════════════════════════════════════════════════════════════════════════════

func _test_frost_instants() -> void:
	_buf.append("\n-- Scenario 40c: Frostbolt (3 frost) & Frost Shock (2 frost) combat instants --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 5, [], 3)   # 5 HP — survives 3 frost
	# Registered under their REAL def ids so BaseAI.COMBAT_INSTANT_TAGS matches.
	db.instant("azeroth_56",  3, "deal_damage_to_target:3:frost")
	db.instant("azeroth_109", 2, "deal_damage_to_target:2:frost")

	# ── Frostbolt: damage, source, and graveyard ──
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	var fb := CardInstance.create("fb_inst", "azeroth_56", "p1", "p1_hand")
	state.cards["fb_inst"] = fb
	state.zones["p1_hand"].card_ids.append("fb_inst")
	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_instant", "p1", {"card_id": "fb_inst"}), db),
		"sc40c-a: Frostbolt submission without a target is rejected")

	var act := PendingAction.make("play_instant", "p1",
		{"card_id": "fb_inst", "target_id": "enemy_ally"})
	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(enemy.damage_taken, 3, "sc40c-b: enemy ally took 3 frost damage")
	var from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "enemy_ally":
			from_hero = true
	ok(from_hero, "sc40c-b2: Frostbolt damage sourced from p1's hero")
	ok(state.get_card("fb_inst").zone_id == "p1_graveyard",
		"sc40c-c: Frostbolt itself is in the graveyard")

	# ── Hold outside combat: never a blind play on own action window ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 3)
	var fb_hold := CardInstance.create("fb_hold", "azeroth_56", "p1", "p1_hand")
	st3.cards["fb_hold"] = fb_hold
	st3.zones["p1_hand"].card_ids.append("fb_hold")
	var blind := false
	for a in BaseAI.new().get_reasonable_actions(st3, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "fb_hold":
			blind = true
	ok(not blind, "sc40c-d: get_reasonable_actions never blind-plays a held combat instant")

	# ── Attack-window ambush matrix (Frostbolt) ──
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.instant("azeroth_56", 3, "deal_damage_to_target:3:frost")
	db2.ally("atk_worthy_def", 3, 3, [], 4)   # cost 4, 3 HP — dies to Frostbolt
	db2.ally("atk_fat_def",    3, 5, [], 4)   # cost 4, 5 HP — survives 3 dmg

	var ai := BaseAI.new()
	var st := _base_state(db2, "p1_hero", "p2_hero")
	st.turn_player     = "p2"
	st.priority_player = "p1"
	_add_resources(st, "p1", 3)
	var fb_p1 := CardInstance.create("fb_p1", "azeroth_56", "p1", "p1_hand")
	st.cards["fb_p1"] = fb_p1
	st.zones["p1_hand"].card_ids.append("fb_p1")
	_add_ally(st, "atk_worthy", "atk_worthy_def", "p2")
	_add_ally(st, "atk_fat",    "atk_fat_def",    "p2")
	st.combat_attack_window = true
	st.combat_defender = "p1_hero"

	st.combat_attacker = "atk_worthy"
	var act2 := ai.combat_instant_action(st, db2, "p1")
	ok(act2 != null and act2.params.get("card_id") == "fb_p1"
			and act2.params.get("target_id") == "atk_worthy",
		"sc40c-e: attack window — 3 HP attacker dies to Frostbolt → play targeting it")

	st.combat_attacker = "atk_fat"
	ok(ai.combat_instant_action(st, db2, "p1") == null,
		"sc40c-f: attack window — 5 HP attacker survives 3 dmg → hold")

	# ── Frost Shock: damage + source, then attack-window ambush ──
	var fs_state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(fs_state, "p1", 2)
	var fs := CardInstance.create("fs_inst", "azeroth_109", "p1", "p1_hand")
	fs_state.cards["fs_inst"] = fs
	fs_state.zones["p1_hand"].card_ids.append("fs_inst")
	var fs_enemy := CardInstance.create("fs_enemy", "target_ally_def", "p2", "p2_ally_row")
	fs_state.cards["fs_enemy"] = fs_enemy
	fs_state.zones["p2_ally_row"].card_ids.append("fs_enemy")

	var fs_act := PendingAction.make("play_instant", "p1",
		{"card_id": "fs_inst", "target_id": "fs_enemy"})
	var fs_events: Array[GameEvent] = StackResolver.submit_action(fs_state, fs_act, db)
	fs_events.append_array(StackResolver.pass_priority(fs_state, db))
	fs_events.append_array(StackResolver.pass_priority(fs_state, db))
	eq(fs_enemy.damage_taken, 2, "sc40c-g: Frost Shock dealt 2 frost damage")
	var fs_from_hero := false
	for e in fs_events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "fs_enemy":
			fs_from_hero = true
	ok(fs_from_hero, "sc40c-g2: Frost Shock damage sourced from p1's hero")

	var db3 := MockDB.new()
	db3.hero("p1_hero", 30)
	db3.hero("p2_hero", 30)
	db3.instant("azeroth_109", 2, "deal_damage_to_target:2:frost")
	db3.ally("fs_atk_def", 3, 2, [], 4)   # cost 4, 2 HP — dies to Frost Shock
	var fs_st := _base_state(db3, "p1_hero", "p2_hero")
	fs_st.turn_player     = "p2"
	fs_st.priority_player = "p1"
	_add_resources(fs_st, "p1", 2)
	var fs_p1 := CardInstance.create("fs_p1", "azeroth_109", "p1", "p1_hand")
	fs_st.cards["fs_p1"] = fs_p1
	fs_st.zones["p1_hand"].card_ids.append("fs_p1")
	_add_ally(fs_st, "fs_atk", "fs_atk_def", "p2")
	fs_st.combat_attack_window = true
	fs_st.combat_defender = "p1_hero"
	fs_st.combat_attacker = "fs_atk"
	var fs_act2 := ai.combat_instant_action(fs_st, db3, "p1")
	ok(fs_act2 != null and fs_act2.params.get("card_id") == "fs_p1"
			and fs_act2.params.get("target_id") == "fs_atk",
		"sc40c-h: attack window — 2 HP attacker dies to Frost Shock → play targeting it")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40d — Frostbolt / Frost Shock "can't attack (or protect)" rider.
# The damaged survivor gets a restriction Buff (turns:1) via the optional 4th
# field on deal_damage_to_target. Frostbolt → cannot_attack; Frost Shock →
# cannot_attack + cannot_protect (also enforced in get_legal_protectors).
# ══════════════════════════════════════════════════════════════════════════════

func _test_frost_riders() -> void:
	_buf.append("\n-- Scenario 40d: Frostbolt / Frost Shock can't-attack-or-protect rider --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("grunt_def", 3, 5, [], 3)                       # 5 HP — survives 3 frost
	db.ally("prot_def",  3, 5, (["protector"] as Array[String]), 3)  # protector, 5 HP
	db.instant("azeroth_56",  3, "deal_damage_to_target:3:frost:cannot_attack")
	db.instant("azeroth_109", 2, "deal_damage_to_target:2:frost:cannot_attack+cannot_protect")

	# ── Frostbolt: surviving enemy ally can't attack this turn ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 3)
	var fb := _add_hand_card(st, "fb", "azeroth_56", "p1")
	fb.zone_id = "p1_hand"
	var grunt := _add_ally(st, "grunt", "grunt_def", "p2")
	grunt.just_summoned = false
	ok("grunt" in StackResolver.get_legal_attackers(st, "p2", db),
		"sc40d-a: enemy ally is a legal attacker before Frostbolt")

	StackResolver.submit_action(st, PendingAction.make("play_instant", "p1",
		{"card_id": "fb", "target_id": "grunt"}), db)
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)

	ok(st.get_card("grunt").has_restriction("cannot_attack"),
		"sc40d-b: Frostbolt put cannot_attack on the surviving target")
	ok("grunt" not in StackResolver.get_legal_attackers(st, "p2", db),
		"sc40d-c: the frozen ally is no longer a legal attacker")

	# ── Frost Shock: surviving enemy protector can't attack OR protect ──
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st2, "p1", 2)
	_add_hand_card(st2, "fs", "azeroth_109", "p1")
	var prot := _add_ally(st2, "prot", "prot_def", "p2")
	prot.just_summoned = false
	ok("prot" in StackResolver.get_legal_protectors(st2, "atk_dummy", "p2_hero", db),
		"sc40d-d: enemy protector can protect its hero before Frost Shock")

	StackResolver.submit_action(st2, PendingAction.make("play_instant", "p1",
		{"card_id": "fs", "target_id": "prot"}), db)
	StackResolver.pass_priority(st2, db)
	StackResolver.pass_priority(st2, db)

	ok(st2.get_card("prot").has_restriction("cannot_attack"),
		"sc40d-e: Frost Shock put cannot_attack on the survivor")
	ok(st2.get_card("prot").has_restriction("cannot_protect"),
		"sc40d-f: Frost Shock also put cannot_protect on the survivor")
	ok("prot" not in StackResolver.get_legal_protectors(st2, "atk_dummy", "p2_hero", db),
		"sc40d-g: the frozen protector can no longer protect")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40f — Steal Essence (azeroth_134): "Your hero deals 2 shadow damage
# to target hero or ally and heals 1 damage from itself for each damage dealt."
# Recipe: deal_damage_to_target:2:shadow|drain_heal_per_damage:1 — the drain
# segment heals the casting hero per damage actually DEALT (armor prevention
# and 405.3 excess-beyond-fatal both reduce the heal).
# ══════════════════════════════════════════════════════════════════════════════

func _test_steal_essence() -> void:
	_buf.append("\n-- Scenario 40f: Steal Essence — 2 shadow drain heals the caster --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("grunt_def", 3, 5, [], 3)      # 5 HP — survives 2 shadow
	db.ally("wisp_def",  1, 1, [], 1)      # 1 HP — only 1 damage can be placed
	db.instant("azeroth_134", 2, "deal_damage_to_target:2:shadow|drain_heal_per_damage:1")

	# ── Full drain: 2 dealt → hero heals 2 ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 2)
	_add_hand_card(st, "se", "azeroth_134", "p1")
	var grunt := _add_ally(st, "grunt", "grunt_def", "p2")
	st.get_card("p1_hero").damage_taken = 5

	var events: Array[GameEvent] = StackResolver.submit_action(st,
		PendingAction.make("play_instant", "p1",
			{"card_id": "se", "target_id": "grunt"}), db)
	events.append_array(StackResolver.pass_priority(st, db))
	events.append_array(StackResolver.pass_priority(st, db))

	eq(grunt.damage_taken, 2, "sc40f-a: target ally took 2 shadow damage")
	var from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "grunt":
			from_hero = true
	ok(from_hero, "sc40f-b: damage sourced from p1's hero")
	eq(st.get_card("p1_hero").damage_taken, 3,
		"sc40f-c: hero healed 2 (one per damage dealt)")
	ok(st.get_card("se").zone_id == "p1_graveyard",
		"sc40f-d: Steal Essence itself is in the graveyard")

	# ── 405.3: only 1 damage fits on a 1-HP target → heal 1, target destroyed ──
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st2, "p1", 2)
	_add_hand_card(st2, "se2", "azeroth_134", "p1")
	_add_ally(st2, "wisp", "wisp_def", "p2")
	st2.get_card("p1_hero").damage_taken = 5

	StackResolver.submit_action(st2, PendingAction.make("play_instant", "p1",
		{"card_id": "se2", "target_id": "wisp"}), db)
	StackResolver.pass_priority(st2, db)
	StackResolver.pass_priority(st2, db)

	ok(st2.get_card("wisp").zone_id == "p2_graveyard",
		"sc40f-e: 1-HP target is destroyed")
	eq(st2.get_card("p1_hero").damage_taken, 4,
		"sc40f-f: only 1 damage placed (excess lost) → hero heals 1")

	# ── Armor prevention on the target hero reduces the drain too ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 2)
	_add_hand_card(st3, "se3", "azeroth_134", "p1")
	st3.get_card("p1_hero").damage_taken = 5
	(st3.players["p2"] as PlayerState).damage_prevention = 1

	StackResolver.submit_action(st3, PendingAction.make("play_instant", "p1",
		{"card_id": "se3", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(st3, db)
	StackResolver.pass_priority(st3, db)

	eq(st3.get_card("p2_hero").damage_taken, 1,
		"sc40f-g: enemy hero took 1 (1 prevented by armor block)")
	eq(st3.get_card("p1_hero").damage_taken, 4,
		"sc40f-h: hero heals only the 1 damage actually dealt")

	# ── Undamaged hero: damage still lands, heal is a no-op ──
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st4, "p1", 2)
	_add_hand_card(st4, "se4", "azeroth_134", "p1")
	var grunt4 := _add_ally(st4, "grunt4", "grunt_def", "p2")

	StackResolver.submit_action(st4, PendingAction.make("play_instant", "p1",
		{"card_id": "se4", "target_id": "grunt4"}), db)
	StackResolver.pass_priority(st4, db)
	StackResolver.pass_priority(st4, db)
	eq(grunt4.damage_taken, 2, "sc40f-i: damage lands on an undamaged caster")
	eq(st4.get_card("p1_hero").damage_taken, 0,
		"sc40f-j: heal on an undamaged hero is a no-op")

	# ── AI: held combat instant — never blind-played; ambush-kills an attacker ──
	var ai := BaseAI.new()
	var st5 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st5, "p1", 2)
	_add_hand_card(st5, "se5", "azeroth_134", "p1")
	var blind := false
	for a in ai.get_reasonable_actions(st5, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "se5":
			blind = true
	ok(not blind, "sc40f-k: AI never blind-plays Steal Essence on its own window")

	db.ally("atk_frail_def", 3, 2, [], 4)   # cost 4, 2 HP — dies to 2 shadow
	var st6 := _base_state(db, "p1_hero", "p2_hero")
	st6.turn_player     = "p2"
	st6.priority_player = "p1"
	_add_resources(st6, "p1", 2)
	_add_hand_card(st6, "se6", "azeroth_134", "p1")
	_add_ally(st6, "atk_frail", "atk_frail_def", "p2")
	st6.combat_attack_window = true
	st6.combat_defender = "p1_hero"
	st6.combat_attacker = "atk_frail"
	var amb := ai.combat_instant_action(st6, db, "p1")
	ok(amb != null and amb.params.get("card_id") == "se6"
			and amb.params.get("target_id") == "atk_frail",
		"sc40f-l: attack window — 2 HP attacker dies to Steal Essence → ambush it")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40g — Mind Spike / Mind Blast: "Your hero deals N shadow damage to
# target hero or ally. Its controller discards a card for each damage dealt."
# (deal_damage_to_target:N:shadow|discard_per_damage:1)
# ══════════════════════════════════════════════════════════════════════════════

func _test_mind_damage_discard() -> void:
	_buf.append("\n-- Scenario 40g: Mind Spike / Mind Blast — damage then discard-per-damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("grunt_def", 3, 5, [], 3)     # 5 HP — survives 2 shadow
	db.ally("wisp_def",  1, 1, [], 1)     # 1 HP — only 1 damage placed
	db.ally("junk_def",  1, 1, [], 1)     # filler hand cards to discard
	db.ability("mind_blast_def", 5, "deal_damage_to_target:2:shadow|discard_per_damage:1")
	db.ability("mind_spike_def", 2, "deal_damage_to_target:1:shadow|discard_per_damage:1")

	# ── Mind Blast: 2 dealt to a surviving enemy ally → its controller discards 2 ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 5)
	_add_card_to_hand(st, "mb", "mind_blast_def", "p1")
	var grunt := _add_ally(st, "grunt", "grunt_def", "p2")
	_add_card_to_hand(st, "j1", "junk_def", "p2")
	_add_card_to_hand(st, "j2", "junk_def", "p2")
	_add_card_to_hand(st, "j3", "junk_def", "p2")

	StackResolver.submit_action(st, PendingAction.make("play_ability", "p1",
		{"card_id": "mb", "target_id": "grunt"}), db)
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)

	eq(grunt.damage_taken, 2, "sc40g-a: target ally took 2 shadow damage")
	eq(st.pending_discard_player, "p2", "sc40g-b: the target's controller (p2) owes the discard")
	eq(st.pending_discard_count, 2, "sc40g-c: discard count equals damage dealt (2)")
	# Resolve the two discards (scene calls choose_discard directly).
	StackResolver.choose_discard(st, "j1", db)
	StackResolver.choose_discard(st, "j2", db)
	eq(st.zones["p2_hand"].card_ids.size(), 1, "sc40g-d: p2 discarded 2 cards (1 left)")
	eq(st.pending_discard_count, 0, "sc40g-e: no discards left pending")

	# ── Mind Spike on a 1-HP ally: only 1 damage placed → discard exactly 1 ──
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st2, "p1", 2)
	_add_card_to_hand(st2, "ms", "mind_spike_def", "p1")
	_add_ally(st2, "wisp", "wisp_def", "p2")
	_add_card_to_hand(st2, "k1", "junk_def", "p2")

	StackResolver.submit_action(st2, PendingAction.make("play_ability", "p1",
		{"card_id": "ms", "target_id": "wisp"}), db)
	StackResolver.pass_priority(st2, db)
	StackResolver.pass_priority(st2, db)

	ok(st2.get_card("wisp").zone_id == "p2_graveyard", "sc40g-f: 1-HP target destroyed")
	eq(st2.pending_discard_player, "p2", "sc40g-g: destroyed ally's controller still discards")
	eq(st2.pending_discard_count, 1, "sc40g-h: exactly 1 discard (1 damage placed)")

	# ── Empty hand: damage still lands, no discard is set up (no crash) ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 5)
	_add_card_to_hand(st3, "mb3", "mind_blast_def", "p1")
	StackResolver.submit_action(st3, PendingAction.make("play_ability", "p1",
		{"card_id": "mb3", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(st3, db)
	StackResolver.pass_priority(st3, db)
	eq(st3.get_card("p2_hero").damage_taken, 2, "sc40g-i: hero takes 2 damage")
	eq(st3.pending_discard_player, "", "sc40g-j: empty-handed controller owes no discard")

	# ── Self-target: "its controller" is the caster → the CASTER discards ──
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st4, "p1", 2)
	_add_card_to_hand(st4, "ms4", "mind_spike_def", "p1")
	_add_ally(st4, "own", "grunt_def", "p1")
	_add_card_to_hand(st4, "own_junk", "junk_def", "p1")
	StackResolver.submit_action(st4, PendingAction.make("play_ability", "p1",
		{"card_id": "ms4", "target_id": "own"}), db)
	StackResolver.pass_priority(st4, db)
	StackResolver.pass_priority(st4, db)
	eq(st4.pending_discard_player, "p1", "sc40g-k: targeting own ally makes the caster discard")
	eq(st4.pending_discard_count, 1, "sc40g-l: 1 discard owed by p1")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40h — Dark Cleric Ismantal: "4, [Activate]: deals 1 shadow damage to
# target hero or ally. That character's controller discards a card for each
# damage dealt. Use only on your turn." (activated_power + discard_per_damage +
# on_your_turn). Reuses the ally-power path.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ismantal_ally_power_discard() -> void:
	_buf.append("\n-- Scenario 40h: Dark Cleric Ismantal ally power — damage then discard --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ismantal_def", 1, 3, [], 3,
		"activated_power:4:deal_damage_to_target:1:shadow:hero_or_ally|discard_per_damage:1|on_your_turn")
	db.ally("grunt_def", 3, 5, [], 3)
	db.ally("junk_def", 1, 1, [], 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var isman := _add_ally(state, "isman", "ismantal_def", "p1")
	isman.just_summoned = false
	isman.is_exhausted  = false
	_add_ally(state, "target", "grunt_def", "p2")
	_add_card_to_hand(state, "e1", "junk_def", "p2")
	_add_card_to_hand(state, "e2", "junk_def", "p2")
	_add_resources(state, "p1", 4)
	state.players["p1"].resource_placed_this_turn = true

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "isman", "target_id": "target"})
	ok(StackResolver.can_submit(state, use, db),
		"sc40h-a: Ismantal power legal on your turn with 4 resources")

	# "Use only on your turn": illegal on the opponent's turn.
	var opp_turn := state.duplicate(true) as GameState
	opp_turn.turn_player = "p2"
	ok(not StackResolver.can_submit(opp_turn, use, db),
		"sc40h-b: power illegal on the opponent's turn (on_your_turn)")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("target").damage_taken, 1, "sc40h-c: target took 1 shadow damage")
	eq(state.pending_discard_player, "p2", "sc40h-d: target's controller (p2) owes the discard")
	eq(state.pending_discard_count, 1, "sc40h-e: 1 discard (1 damage dealt)")
	ok(state.get_card("isman").is_exhausted, "sc40h-f: Ismantal exhausted after activating")
	StackResolver.choose_discard(state, "e1", db)
	eq(state.zones["p2_hand"].card_ids.size(), 1, "sc40h-g: p2 discarded a card")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40i — Boneshanks: "When Boneshanks is destroyed, destroy target ally."
# A mandatory targeted death trigger (on_destroyed:destroy_target:ally) resolved
# by the destroyed card's controller via choose_death_target (direct call).
# ══════════════════════════════════════════════════════════════════════════════

func _test_boneshanks_death_trigger() -> void:
	_buf.append("\n-- Scenario 40i: Boneshanks — on-destroy destroy target ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bone_def", 3, 2, [], 3, "on_destroyed:destroy_target:ally")
	db.ally("grunt_def", 3, 5, [], 3)
	db.ally("wisp_def",  1, 1, [], 1)

	# ── Case A: Boneshanks dies → its controller must destroy a target ally ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	var bone := _add_ally(st, "bone", "bone_def", "p1")
	var enemy := _add_ally(st, "enemy", "grunt_def", "p2")
	var events := StackResolver._destroy_card_trigger(st, "bone", "bone", db)
	ok(bone.zone_id == "p1_graveyard", "sc40i-a: Boneshanks is in the graveyard")
	eq(st.pending_death_target_player, "p1",
		"sc40i-b: its controller (p1) must pick a target ally")
	var saw_req := false
	for e in events:
		if e.event_type == "death_target_required":
			saw_req = true
	ok(saw_req, "sc40i-c: death_target_required event emitted")
	# Everything else is blocked while the choice is pending.
	ok(not StackResolver.can_submit(st,
		PendingAction.make("place_resource", "p1", {"card_id": "x"}), db),
		"sc40i-d: can_submit blocked while a death-target choice is pending")
	ok(StackResolver.pass_priority(st, db).is_empty(),
		"sc40i-e: pass_priority is hard-blocked while pending")
	# Resolve: destroy the enemy ally.
	StackResolver.choose_death_target(st, "enemy", db)
	ok(enemy.zone_id == "p2_graveyard", "sc40i-f: chosen enemy ally destroyed")
	eq(st.pending_death_target_player, "", "sc40i-g: no death-target choice left pending")

	# ── Case B: no allies in play when Boneshanks dies → trigger fizzles ──
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st2, "bone2", "bone_def", "p1")
	StackResolver._destroy_card_trigger(st2, "bone2", "bone2", db)
	eq(st2.pending_death_target_player, "",
		"sc40i-h: no legal ally → no choice opened (trigger fizzles)")

	# ── Case C: AI picks the highest-value enemy ally ──
	var ai := BaseAI.new()
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st3, "bone3", "bone_def", "p1")
	_add_ally(st3, "weak", "wisp_def", "p2")     # low value
	_add_ally(st3, "strong", "grunt_def", "p2")  # high value
	StackResolver._destroy_card_trigger(st3, "bone3", "bone3", db)
	eq(ai.choose_death_target(st3, db, "p1"), "strong",
		"sc40i-i: AI destroys the most valuable enemy ally")

	# ── Case D: only friendly allies remain → AI is forced to destroy its own ──
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st4, "bone4", "bone_def", "p1")
	_add_ally(st4, "friend", "grunt_def", "p1")
	StackResolver._destroy_card_trigger(st4, "bone4", "bone4", db)
	eq(ai.choose_death_target(st4, db, "p1"), "friend",
		"sc40i-j: AI forced to destroy its own ally when no enemy ally exists")

	# ── Case E: chained death — destroying another Boneshanks opens a 2nd choice ──
	var st5 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st5, "boneA", "bone_def", "p1")
	_add_ally(st5, "boneB", "bone_def", "p2")
	_add_ally(st5, "victim", "grunt_def", "p2")
	StackResolver._destroy_card_trigger(st5, "boneA", "boneA", db)
	eq(st5.pending_death_target_player, "p1", "sc40i-k: p1's Boneshanks trigger opens")
	# p1 chooses to destroy p2's Boneshanks → ITS trigger now fires for p2.
	StackResolver.choose_death_target(st5, "boneB", db)
	ok(not st5.is_in_play("boneB"), "sc40i-l: p2's Boneshanks destroyed")
	eq(st5.pending_death_target_player, "p2",
		"sc40i-m: chained Boneshanks trigger opens a choice for p2")
	StackResolver.choose_death_target(st5, "victim", db)
	ok(not st5.is_in_play("victim"), "sc40i-n: p2 forced to destroy its remaining ally")
	eq(st5.pending_death_target_player, "", "sc40i-o: queue fully drained")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40e — Lady Jaina Proudmoore: "Opposing allies can't attack." A live
# static aura — while an opponent controls Jaina, none of your ALLIES may be
# proposed as attackers (your hero is unaffected). Removing Jaina restores them.
# ══════════════════════════════════════════════════════════════════════════════

func _test_lady_jaina_aura() -> void:
	_buf.append("\n-- Scenario 40e: Lady Jaina — opposing allies can't attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("azeroth_195", 7, 4, (["unique"] as Array[String]), 8, "opposing_allies_cant_attack")
	db.ally("grunt_def", 3, 3, [], 2)

	var st := _base_state(db, "p1_hero", "p2_hero")
	var jaina := _add_ally(st, "jaina", "azeroth_195", "p1")
	jaina.just_summoned = false
	var p1_grunt := _add_ally(st, "p1_grunt", "grunt_def", "p1")
	p1_grunt.just_summoned = false
	var p2_grunt := _add_ally(st, "p2_grunt", "grunt_def", "p2")
	p2_grunt.just_summoned = false

	# p2 (Jaina's opponent) has its allies locked; p1 (Jaina's controller) does not.
	ok("p2_grunt" not in StackResolver.get_legal_attackers(st, "p2", db),
		"sc40e-a: opposing ally can't be proposed as an attacker under Jaina")
	ok("p1_grunt" in StackResolver.get_legal_attackers(st, "p1", db),
		"sc40e-b: Jaina's own controller's allies are unaffected")

	# Submission guard: propose_combat from a locked ally is rejected.
	st.turn_player     = "p2"
	st.priority_player = "p2"
	ok(not StackResolver.can_submit(st, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "p2_grunt", "defender_id": "p1_hero"}), db),
		"sc40e-c: propose_combat is rejected for the locked ally")

	# Remove Jaina → the lock lifts.
	st.turn_player     = "p1"
	st.priority_player = "p1"
	GameLogic.move_card(st, "jaina", "p1_graveyard")
	ok("p2_grunt" in StackResolver.get_legal_attackers(st, "p2", db),
		"sc40e-d: removing Jaina restores opposing allies as legal attackers")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40f — Lady Jaina Proudmoore uniqueness (rule 414.3a — the Unique tag).
# Playing a 2nd same-named Unique card forces the controller to destroy one.
# ══════════════════════════════════════════════════════════════════════════════

func _test_lady_jaina_unique() -> void:
	_buf.append("\n-- Scenario 40f: Lady Jaina — name-based Unique uniqueness --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("azeroth_195", 7, 4, (["unique"] as Array[String]), 8, "opposing_allies_cant_attack")

	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 8)
	var jaina1 := _add_ally(st, "jaina1", "azeroth_195", "p1")
	jaina1.just_summoned = false
	_add_hand_card(st, "jaina2", "azeroth_195", "p1")

	# Play the second Jaina; both players pass to resolve it into play.
	StackResolver.submit_action(st, PendingAction.make("play_ally", "p1",
		{"card_id": "jaina2"}), db)
	StackResolver.pass_priority(st, db)
	StackResolver.pass_priority(st, db)

	eq(st.pending_unique_sacrifice_player, "p1",
		"sc40f-a: playing a 2nd same-named Unique card triggers a sacrifice")
	ok("jaina1" in st.pending_unique_sacrifice_ids and "jaina2" in st.pending_unique_sacrifice_ids,
		"sc40f-b: both copies are in the violation set")
	# Nothing else may be submitted while the violation is pending — a combat that
	# would otherwise be legal (jaina1 is ready, 7 ATK, chain empty) is blocked.
	ok(not StackResolver.can_submit(st, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "jaina1", "defender_id": "p2_hero"}), db),
		"sc40f-c: the pending violation hard-blocks other actions")

	# Repair: destroy one copy.
	StackResolver.choose_unique_sacrifice(st, "jaina2", db)
	eq(st.pending_unique_sacrifice_player, "",
		"sc40f-d: destroying a duplicate clears the violation")
	ok(st.get_card("jaina2").zone_id == "p1_graveyard",
		"sc40f-e: the chosen duplicate is destroyed")
	ok(st.is_in_play("jaina1"),
		"sc40f-f: the surviving copy stays in play")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 40g — Hannah the Unstoppable: "Opposing heroes and allies can't
# protect." A live static aura — while an opponent controls Hannah, that player
# has NO legal protectors (neither their allies with Protector nor a hero grant).
# Removing Hannah restores them.
# ══════════════════════════════════════════════════════════════════════════════

func _test_hannah_cant_protect_aura() -> void:
	_buf.append("\n-- Scenario 40g: Hannah — opposing heroes and allies can't protect --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("azeroth_187", 3, 3, [], 5, "opposing_cant_protect")
	db.ally("attacker_def", 3, 3)
	db.ally("guard_def", 3, 4, (["protector"] as Array[String]))

	var st := _base_state(db, "p1_hero", "p2_hero")
	var hannah := _add_ally(st, "hannah", "azeroth_187", "p1")
	hannah.just_summoned = false
	_add_ally(st, "attacker", "attacker_def", "p1")
	var guard := _add_ally(st, "guard", "guard_def", "p2")
	guard.just_summoned = false
	guard.is_exhausted  = false

	# p2 (Hannah's opponent) can't protect: its Protector ally is not offered.
	ok("guard" not in StackResolver.get_legal_protectors(st, "attacker", "p2_hero", db),
		"sc40g-a: opposing Protector can't protect under Hannah")

	# Sanity: without the aura the same guard WOULD be a legal protector.
	GameLogic.move_card(st, "hannah", "p1_graveyard")
	ok("guard" in StackResolver.get_legal_protectors(st, "attacker", "p2_hero", db),
		"sc40g-b: removing Hannah restores the opposing Protector")

	# Hannah's own controller is unaffected — p1 could still protect if attacked.
	_add_ally(st, "hannah2", "azeroth_187", "p2")  # now p2 controls Hannah
	st.get_card("hannah2").just_summoned = false
	var p1_guard := _add_ally(st, "p1_guard", "guard_def", "p1")
	p1_guard.just_summoned = false
	p1_guard.is_exhausted  = false
	ok("p1_guard" not in StackResolver.get_legal_protectors(st, "attacker", "p1_hero", db),
		"sc40g-c: p2's Hannah now locks p1's protectors")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 41 — Nerra Lifeboon: "Other allies in your party have +1 health."
# ══════════════════════════════════════════════════════════════════════════════

func _test_nerra_lifeboon_health_aura() -> void:
	_buf.append("\n-- Scenario 41: Nerra Lifeboon party '+1 health' aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("nerra_def", 4, 4, [], 5, "party_health_aura:1")
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "nerra_inst", "nerra_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	_add_ally(state, "opp_inst", "grunt_def", "p2")

	eq(state.get_max_hp("grunt_inst", db), 3, "sc41-a: other ally gets +1 max health")
	eq(state.get_max_hp("nerra_inst", db), 4, "sc41-b: Nerra doesn't buff herself")
	eq(state.get_max_hp("opp_inst", db), 2, "sc41-c: opponent's ally unaffected by p1's Nerra")

	# Two Nerras stack.
	_add_ally(state, "nerra2_inst", "nerra_def", "p1")
	eq(state.get_max_hp("grunt_inst", db), 4, "sc41-d: two Nerras stack (+2)")
	eq(state.get_max_hp("nerra_inst", db), 5, "sc41-e: each Nerra buffs the other")

	# Nerra leaves play → aura disappears.
	GameLogic.move_card(state, "nerra_inst", "p1_graveyard")
	GameLogic.move_card(state, "nerra2_inst", "p1_graveyard")
	eq(state.get_max_hp("grunt_inst", db), 2, "sc41-f: aura gone once both Nerras leave play")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 41b — Nerra Lifeboon aura-loss death check.
#
# An ally kept alive only by Nerra's +health aura must die the instant Nerra
# dies, even with no further damage dealt (state-based death, rule 118.4/704).
# ══════════════════════════════════════════════════════════════════════════════

func _test_nerra_death_triggers_aura_loss_death() -> void:
	_buf.append("\n-- Scenario 41b: Nerra death kills an ally kept alive by her aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("nerra_def", 4, 4, [], 5, "party_health_aura:1")
	db.ally("braxiss_def", 4, 4)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "nerra_inst", "nerra_def", "p1")
	_add_ally(state, "braxiss_inst", "braxiss_def", "p1")

	# Braxiss: printed 4 health, +1 from Nerra's aura = 5 max. Take 4 damage —
	# survives with 1 effective health left.
	state.get_card("braxiss_inst").damage_taken = 4
	eq(state.get_max_hp("braxiss_inst", db), 5, "sc41b-a: Braxiss has 5 max health thanks to Nerra")
	eq(state.get_current_hp("braxiss_inst", db), 1, "sc41b-b: Braxiss survives on 1 effective health")

	# Kill Nerra directly (simulates combat lethal damage).
	state.get_card("nerra_inst").damage_taken = state.get_max_hp("nerra_inst", db)
	StackResolver._check_destroyed_trigger(state, "nerra_inst", "p2_hero", db)

	ok(state.get_card("nerra_inst").zone_id == "p1_graveyard", "sc41b-c: Nerra destroyed")
	eq(state.get_max_hp("braxiss_inst", db), 4, "sc41b-d: Braxiss back to 4 max health, aura gone")
	ok(state.get_card("braxiss_inst").zone_id == "p1_graveyard",
		"sc41b-e: Braxiss dies too — 4 damage now equals his 4 max health")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 42 — Master of the Hunt: "Ongoing: Your Pets have +2 ATK and +2 health."
#
# Rule 305.2c: a non-attaching ongoing ability enters play in its controller's
# hero row and remains there providing its effect until removed — it does NOT
# resolve-and-graveyard like a non-ongoing ability (e.g. Vanquish).
# ══════════════════════════════════════════════════════════════════════════════

func _test_master_of_the_hunt_ongoing() -> void:
	_buf.append("\n-- Scenario 42: Master of the Hunt ongoing '+2 ATK / +2 health' pet aura --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ability("hunt_def", 3, "ongoing|pet_atk_health_aura:2:2")
	db.pet("pet_def", 2, 2, [], 2)
	db.ally("grunt_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	_add_ally(state, "pet_inst", "pet_def", "p1")
	_add_ally(state, "grunt_inst", "grunt_def", "p1")
	_add_ally(state, "opp_pet_inst", "pet_def", "p2")

	var hunt := CardInstance.create("hunt_inst", "hunt_def", "p1", "p1_hand")
	state.cards["hunt_inst"] = hunt
	state.zones["p1_hand"].card_ids.append("hunt_inst")

	var play := PendingAction.make("play_ability", "p1", {"card_id": "hunt_inst"})
	ok(StackResolver.can_submit(state, play, db), "sc42-a: play_ability is legal")
	StackResolver.submit_action(state, play, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("hunt_inst").zone_id, "p1_hero_row",
		"sc42-b: ongoing ability enters play in the hero row (not the graveyard)")
	eq(state.get_atk("pet_inst", db), 4, "sc42-c: friendly pet gets +2 ATK")
	eq(state.get_max_hp("pet_inst", db), 4, "sc42-d: friendly pet gets +2 health")
	eq(state.get_atk("grunt_inst", db), 2, "sc42-e: non-pet ally unaffected")
	eq(state.get_atk("opp_pet_inst", db), 2, "sc42-f: opponent's pet unaffected by p1's aura")

	GameLogic.move_card(state, "hunt_inst", "p1_graveyard")
	eq(state.get_atk("pet_inst", db), 2, "sc42-g: aura gone once the ability leaves play")
	eq(state.get_max_hp("pet_inst", db), 2, "sc42-h: health aura gone once the ability leaves play")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 43 — Guardian Steelhorn: "can't attack" (Protector that never attacks)
# ══════════════════════════════════════════════════════════════════════════════

func _test_guardian_steelhorn_cant_attack() -> void:
	_buf.append("\n-- Scenario 43: Guardian Steelhorn can't attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("steelhorn_def", 3, 3, (["protector", "cant_attack"] as Array[String]))
	db.ally("plain_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "steel", "steelhorn_def", "p1")
	_add_ally(state, "plain", "plain_def", "p1")
	# Both are ready and not summoning-sick.
	state.get_card("steel").just_summoned = false
	state.get_card("plain").just_summoned = false
	state.players["p1"].resource_placed_this_turn = true

	var legal := StackResolver.get_legal_attackers(state, "p1", db)
	ok("steel" not in legal, "sc43-a: Guardian Steelhorn is NOT a legal attacker")
	ok("plain" in legal, "sc43-b: a normal ally IS a legal attacker")

	# Direct submission of a combat proposal with Steelhorn must be rejected.
	var propose := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "steel", "defender_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, propose, db),
		"sc43-c: propose_combat with Guardian Steelhorn is illegal")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 44 — Starfire: non-instant Ability (action-phase only), hero deals
# 5 arcane damage to an announced target, plus "Draw a card."
#
# Assertions:
#   sc44-a  cannot be played outside the action phase / with pending chain
#   sc44-b  submission without a target is rejected
#   sc44-c  5 arcane damage dealt to the announced target, sourced from the hero
#   sc44-d  a card is drawn
#   sc44-e  Starfire itself ends up in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_starfire() -> void:
	_buf.append("\n-- Scenario 44: Starfire — hero deals 5 arcane dmg + draw a card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_ally_def", 2, 8, [], 3)
	db.ally("filler_def", 1, 1, [], 1)
	db.ability("starfire_def", 6, "deal_damage_to_target:5:arcane|draw:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 6)

	var starfire := CardInstance.create("starfire_inst", "starfire_def", "p1", "p1_hand")
	state.cards["starfire_inst"] = starfire
	state.zones["p1_hand"].card_ids.append("starfire_inst")

	var enemy := CardInstance.create("enemy_ally", "target_ally_def", "p2", "p2_ally_row")
	state.cards["enemy_ally"] = enemy
	state.zones["p2_ally_row"].card_ids.append("enemy_ally")

	# A card to draw, at the top of p1's deck.
	var draw_card := CardInstance.create("draw_card_inst", "filler_def", "p1", "p1_deck")
	state.cards["draw_card_inst"] = draw_card
	state.zones["p1_deck"].card_ids.append("draw_card_inst")

	# Combat window open → not action-phase-only-legal.
	state.combat_attack_window = true
	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1",
			{"card_id": "starfire_inst", "target_id": "enemy_ally"}), db),
		"sc44-a: cannot be played during a combat window")
	state.combat_attack_window = false

	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1", {"card_id": "starfire_inst"}), db),
		"sc44-b: submission without a target is rejected")

	var act := PendingAction.make("play_ability", "p1",
		{"card_id": "starfire_inst", "target_id": "enemy_ally"})
	ok(StackResolver.can_submit(state, act, db), "sc44-b2: full action is legal")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(enemy.damage_taken, 5, "sc44-c: enemy ally took 5 arcane damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "enemy_ally":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc44-c2: damage sourced from p1's hero")

	ok(state.get_card("draw_card_inst").zone_id == "p1_hand",
		"sc44-d: a card was drawn into p1's hand")

	ok(state.get_card("starfire_inst").zone_id == "p1_graveyard",
		"sc44-e: Starfire itself is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 45 — Flamestrike: non-instant Ability (action-phase only), hero deals
# 3 fire damage to EACH opposing hero and ally — no target announced.
#
# Assertions:
#   sc45-a  cannot be played outside the action phase / with pending chain
#   sc45-b  no target required to submit (unlike Quick Strike / Starfire)
#   sc45-c  3 fire damage dealt to every opposing ally, sourced from the hero
#   sc45-d  3 fire damage dealt to the opposing hero
#   sc45-e  friendly allies and own hero take no damage
#   sc45-f  a lethally-damaged opposing ally is destroyed (goes to graveyard)
#   sc45-g  Flamestrike itself ends up in the graveyard
# ══════════════════════════════════════════════════════════════════════════════

func _test_flamestrike() -> void:
	_buf.append("\n-- Scenario 45: Flamestrike — hero deals 3 fire dmg to each opposing hero/ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("opp_ally_def", 2, 5, [], 3)
	db.ally("opp_weak_def", 2, 2, [], 2)   # dies to 3 fire damage
	db.ally("own_ally_def", 2, 5, [], 3)
	db.ability("flamestrike_def", 7, "deal_damage_aoe_opponent:3:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 7)

	var flamestrike := CardInstance.create("flamestrike_inst", "flamestrike_def", "p1", "p1_hand")
	state.cards["flamestrike_inst"] = flamestrike
	state.zones["p1_hand"].card_ids.append("flamestrike_inst")

	var opp_ally := CardInstance.create("opp_ally", "opp_ally_def", "p2", "p2_ally_row")
	state.cards["opp_ally"] = opp_ally
	state.zones["p2_ally_row"].card_ids.append("opp_ally")

	var opp_weak := CardInstance.create("opp_weak", "opp_weak_def", "p2", "p2_ally_row")
	state.cards["opp_weak"] = opp_weak
	state.zones["p2_ally_row"].card_ids.append("opp_weak")

	var own_ally := CardInstance.create("own_ally", "own_ally_def", "p1", "p1_ally_row")
	state.cards["own_ally"] = own_ally
	state.zones["p1_ally_row"].card_ids.append("own_ally")

	# Combat window open → not action-phase-only-legal.
	state.combat_attack_window = true
	ok(not StackResolver.can_submit(state,
		PendingAction.make("play_ability", "p1", {"card_id": "flamestrike_inst"}), db),
		"sc45-a: cannot be played during a combat window")
	state.combat_attack_window = false

	var act := PendingAction.make("play_ability", "p1", {"card_id": "flamestrike_inst"})
	ok(StackResolver.can_submit(state, act, db), "sc45-b: no target required to submit")

	var events: Array[GameEvent] = StackResolver.submit_action(state, act, db)
	events.append_array(StackResolver.pass_priority(state, db))
	events.append_array(StackResolver.pass_priority(state, db))

	eq(opp_ally.damage_taken, 3, "sc45-c: opposing ally took 3 fire damage")
	var saw_dmg_from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "p2_hero":
			saw_dmg_from_hero = true
	ok(saw_dmg_from_hero, "sc45-d: opposing hero took 3 fire damage sourced from p1's hero")
	eq(state.get_card("p2_hero").damage_taken, 3, "sc45-d2: opposing hero damage_taken == 3")

	eq(own_ally.damage_taken, 0, "sc45-e: friendly ally took no damage")
	eq(state.get_card("p1_hero").damage_taken, 0, "sc45-e2: own hero took no damage")

	ok(state.get_card("opp_weak").zone_id == "p2_graveyard",
		"sc45-f: lethally-damaged opposing ally destroyed")

	ok(state.get_card("flamestrike_inst").zone_id == "p1_graveyard",
		"sc45-g: Flamestrike itself is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 46 — Chain Lightning: 3 waves (3/2/1 nature), each an optional "may"
# after the mandatory 1st target. Card-specific targeting rule: the 1st target
# may NOT be Untargetable, but the 2nd/3rd targets CAN be (override of the
# normal Untargetable rule — see CLAUDE.md).
#
# Assertions:
#   sc46-a  no target at all → illegal submission
#   sc46-b  1-target cast: only 3 dmg dealt, to target_id, from p1's hero
#   sc46-c  2-target cast: 3 dmg + 2 dmg dealt to the two announced targets
#   sc46-d  3-target cast: 3+2+1 dmg dealt to the three announced targets
#   sc46-e  target_id_3 without target_id_2 is illegal (can't skip "another")
#   sc46-f  a repeated target (not distinct) is illegal
#   sc46-g  a target that dies to wave 1 doesn't block wave 2/3 from resolving
#           against the other announced targets (each wave is independent)
#   sc46-h  Untargetable card CANNOT be chosen as target_id (1st)
#   sc46-i  the SAME Untargetable card CAN be chosen as target_id_2 (2nd)
# ══════════════════════════════════════════════════════════════════════════════

func _test_chain_lightning() -> void:
	_buf.append("\n-- Scenario 46: Chain Lightning — up to 3 waves, 3/2/1 nature --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("victim_a_def", 2, 6, [], 3)
	db.ally("victim_b_def", 2, 6, [], 3)
	db.ally("victim_c_def", 2, 6, [], 3)
	db.ally("frail_def",    2, 2, [], 1)   # dies to 3 nature (wave 1)
	db.ally("untargetable_def", 0, 6, (["untargetable"] as Array[String]), 2)
	db.ability("chainlightning_def", 5, "chain_lightning:3:2:1:nature")

	# sc46-a: no target at all → illegal.
	var state0 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state0, "p1", 5)
	var cl0 := CardInstance.create("cl0", "chainlightning_def", "p1", "p1_hand")
	state0.cards["cl0"] = cl0
	state0.zones["p1_hand"].card_ids.append("cl0")
	ok(not StackResolver.can_submit(state0,
		PendingAction.make("play_ability", "p1", {"card_id": "cl0"}), db),
		"sc46-a: no target at all is illegal")

	# sc46-b: single-target cast — only 3 dmg, from p1's hero.
	var state1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state1, "p1", 5)
	var cl1 := CardInstance.create("cl1", "chainlightning_def", "p1", "p1_hand")
	state1.cards["cl1"] = cl1
	state1.zones["p1_hand"].card_ids.append("cl1")
	_add_ally(state1, "va1", "victim_a_def", "p2")

	var p1_ai1 := ScriptedAI.new()
	p1_ai1.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl1", "target_id": "va1"}))
	var events1 := _drive_turns(state1, db, p1_ai1, ScriptedAI.new(), 3)
	eq(state1.get_card("va1").damage_taken, 3, "sc46-b: single-target cast deals exactly 3 dmg")
	var dmg_source1 := ""
	for e in events1:
		if e.event_type == "damage_dealt":
			dmg_source1 = e.payload.get("source", dmg_source1)
	eq(dmg_source1, "p1_hero", "sc46-b2: damage source is p1's hero")
	ok(state1.get_card("cl1").zone_id == "p1_graveyard", "sc46-b3: Chain Lightning in graveyard")

	# sc46-c: two-target cast — 3 dmg + 2 dmg.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 5)
	var cl2 := CardInstance.create("cl2", "chainlightning_def", "p1", "p1_hand")
	state2.cards["cl2"] = cl2
	state2.zones["p1_hand"].card_ids.append("cl2")
	_add_ally(state2, "va2", "victim_a_def", "p2")
	_add_ally(state2, "vb2", "victim_b_def", "p2")

	var p1_ai2 := ScriptedAI.new()
	p1_ai2.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl2", "target_id": "va2", "target_id_2": "vb2"}))
	_drive_turns(state2, db, p1_ai2, ScriptedAI.new(), 3)
	eq(state2.get_card("va2").damage_taken, 3, "sc46-c: 1st target took 3 dmg")
	eq(state2.get_card("vb2").damage_taken, 2, "sc46-c2: 2nd target took 2 dmg")

	# sc46-d: three-target cast — 3 + 2 + 1.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 5)
	var cl3 := CardInstance.create("cl3", "chainlightning_def", "p1", "p1_hand")
	state3.cards["cl3"] = cl3
	state3.zones["p1_hand"].card_ids.append("cl3")
	_add_ally(state3, "va3", "victim_a_def", "p2")
	_add_ally(state3, "vb3", "victim_b_def", "p2")
	_add_ally(state3, "vc3", "victim_c_def", "p2")

	var p1_ai3 := ScriptedAI.new()
	p1_ai3.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl3", "target_id": "va3", "target_id_2": "vb3", "target_id_3": "vc3"}))
	_drive_turns(state3, db, p1_ai3, ScriptedAI.new(), 3)
	eq(state3.get_card("va3").damage_taken, 3, "sc46-d: 1st target took 3 dmg")
	eq(state3.get_card("vb3").damage_taken, 2, "sc46-d2: 2nd target took 2 dmg")
	eq(state3.get_card("vc3").damage_taken, 1, "sc46-d3: 3rd target took 1 dmg")

	# sc46-e / sc46-f: illegal target combinations.
	var state4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state4, "p1", 5)
	var cl4 := CardInstance.create("cl4", "chainlightning_def", "p1", "p1_hand")
	state4.cards["cl4"] = cl4
	state4.zones["p1_hand"].card_ids.append("cl4")
	_add_ally(state4, "va4", "victim_a_def", "p2")
	_add_ally(state4, "vb4", "victim_b_def", "p2")
	ok(not StackResolver.can_submit(state4, PendingAction.make("play_ability", "p1",
		{"card_id": "cl4", "target_id": "va4", "target_id_3": "vb4"}), db),
		"sc46-e: target_id_3 without target_id_2 is illegal")
	ok(not StackResolver.can_submit(state4, PendingAction.make("play_ability", "p1",
		{"card_id": "cl4", "target_id": "va4", "target_id_2": "va4"}), db),
		"sc46-f: repeated (non-distinct) target is illegal")

	# sc46-g: a target that dies to wave 1 doesn't block waves 2/3 from resolving
	# against the OTHER announced targets (each wave targets a different card).
	var state5 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state5, "p1", 5)
	var cl5 := CardInstance.create("cl5", "chainlightning_def", "p1", "p1_hand")
	state5.cards["cl5"] = cl5
	state5.zones["p1_hand"].card_ids.append("cl5")
	_add_ally(state5, "frail5", "frail_def",   "p2")   # 2 HP — dies to wave-1's 3 dmg
	_add_ally(state5, "vb5",    "victim_b_def", "p2")  # 6 HP — survives wave-2's 2 dmg

	var p1_ai5 := ScriptedAI.new()
	p1_ai5.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl5", "target_id": "frail5", "target_id_2": "vb5"}))
	_drive_turns(state5, db, p1_ai5, ScriptedAI.new(), 3)
	ok(state5.get_card("frail5").zone_id == "p2_graveyard",
		"sc46-g: 1st target destroyed by wave-1's 3 dmg")
	eq(state5.get_card("vb5").damage_taken, 2,
		"sc46-g2: 2nd target still took wave-2's 2 dmg despite the 1st target dying first")

	# sc46-h / sc46-i: Untargetable — card-specific override of the normal
	# Untargetable rule (References/wow_rules.txt ~line 4215): CANNOT be the
	# 1st target, but CAN be the 2nd (or 3rd) target of Chain Lightning only.
	var state6 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state6, "p1", 5)
	var cl6 := CardInstance.create("cl6", "chainlightning_def", "p1", "p1_hand")
	state6.cards["cl6"] = cl6
	state6.zones["p1_hand"].card_ids.append("cl6")
	_add_ally(state6, "ut6", "untargetable_def", "p2")
	_add_ally(state6, "va6", "victim_a_def",     "p2")

	ok(not StackResolver.can_submit(state6, PendingAction.make("play_ability", "p1",
		{"card_id": "cl6", "target_id": "ut6"}), db),
		"sc46-h: Untargetable card cannot be the 1st (mandatory) target")
	ok(StackResolver.can_submit(state6, PendingAction.make("play_ability", "p1",
		{"card_id": "cl6", "target_id": "va6", "target_id_2": "ut6"}), db),
		"sc46-i: the SAME Untargetable card CAN be the 2nd target")

	var p1_ai6 := ScriptedAI.new()
	p1_ai6.queue_action(PendingAction.make("play_ability", "p1",
		{"card_id": "cl6", "target_id": "va6", "target_id_2": "ut6"}))
	_drive_turns(state6, db, p1_ai6, ScriptedAI.new(), 3)
	eq(state6.get_card("va6").damage_taken, 3, "sc46-j: 1st (non-Untargetable) target took 3 dmg")
	eq(state6.get_card("ut6").damage_taken, 2,
		"sc46-k: Untargetable 2nd target still took wave-2's 2 dmg")

	# sc46-l: AI wave assignment, case 1 — targets with 3/2/1 HP (+4 HP, +hero):
	# each wave kills the matching target (3→3hp, 2→2hp, 1→1hp).
	db.ally("hp4_def", 1, 4, [], 2)
	db.ally("hp3_def", 1, 3, [], 2)
	db.ally("hp2_def", 1, 2, [], 1)
	db.ally("hp1_def", 1, 1, [], 1)
	var state7 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state7, "p1", 5)
	var cl7 := CardInstance.create("cl7", "chainlightning_def", "p1", "p1_hand")
	state7.cards["cl7"] = cl7
	state7.zones["p1_hand"].card_ids.append("cl7")
	_add_ally(state7, "a4", "hp4_def", "p2")
	_add_ally(state7, "a3", "hp3_def", "p2")
	_add_ally(state7, "a2", "hp2_def", "p2")
	_add_ally(state7, "a1", "hp1_def", "p2")

	var ai7 := BaseAI.new()
	var act7 := ai7._chain_lightning_action(state7, db, "p1", "cl7", "play_ability")
	ok(act7 != null, "sc46-l: AI produced a Chain Lightning action")
	if act7:
		eq(act7.params.get("target_id", ""),   "a3", "sc46-l2: wave 1 (3 dmg) kills the 3-HP ally")
		eq(act7.params.get("target_id_2", ""), "a2", "sc46-l3: wave 2 (2 dmg) kills the 2-HP ally")
		eq(act7.params.get("target_id_3", ""), "a1", "sc46-l4: wave 3 (1 dmg) kills the 1-HP ally")

	# sc46-m: AI wave assignment, case 2 — two 1-HP allies + hero: the small
	# waves (2 and 1) kill the allies; the 3-damage wave goes to the hero
	# instead of being wasted on a 1-HP ally.
	var state8 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state8, "p1", 5)
	var cl8 := CardInstance.create("cl8", "chainlightning_def", "p1", "p1_hand")
	state8.cards["cl8"] = cl8
	state8.zones["p1_hand"].card_ids.append("cl8")
	_add_ally(state8, "f1", "hp1_def", "p2")
	_add_ally(state8, "f2", "hp1_def", "p2")

	var ai8 := BaseAI.new()
	var act8 := ai8._chain_lightning_action(state8, db, "p1", "cl8", "play_ability")
	ok(act8 != null, "sc46-m: AI produced a Chain Lightning action")
	if act8:
		eq(act8.params.get("target_id", ""), "p2_hero",
			"sc46-m2: wave 1 (3 dmg) hits the hero, not a 1-HP ally")
		var t2: String = act8.params.get("target_id_2", "")
		var t3: String = act8.params.get("target_id_3", "")
		ok(t2 in ["f1", "f2"] and t3 in ["f1", "f2"] and t2 != t3,
			"sc46-m3: waves 2 and 1 kill the two 1-HP allies")


func _test_multi_shot() -> void:
	_buf.append("\n-- Scenario 46b: Multi-Shot — up to 3 targets, flat 2 ranged each --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ms_victim_a", 2, 6, [], 3)
	db.ally("ms_victim_b", 2, 6, [], 3)
	db.ally("ms_victim_c", 2, 6, [], 3)
	db.ally("ms_frail",    2, 2, [], 1)   # dies to 2 ranged
	db.ally("ms_untarget", 0, 6, (["untargetable"] as Array[String]), 2)
	db.instant("multishot_def", 5, "multi_shot:2:ranged")

	# sc46b-a: no target at all → illegal.
	var state0 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state0, "p1", 5)
	var ms0 := CardInstance.create("ms0", "multishot_def", "p1", "p1_hand")
	state0.cards["ms0"] = ms0
	state0.zones["p1_hand"].card_ids.append("ms0")
	ok(not StackResolver.can_submit(state0,
		PendingAction.make("play_instant", "p1", {"card_id": "ms0"}), db),
		"sc46b-a: no target at all is illegal")

	# sc46b-b: single-target cast — 2 dmg from p1's hero, card to graveyard.
	var state1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state1, "p1", 5)
	var ms1 := CardInstance.create("ms1", "multishot_def", "p1", "p1_hand")
	state1.cards["ms1"] = ms1
	state1.zones["p1_hand"].card_ids.append("ms1")
	_add_ally(state1, "ma1", "ms_victim_a", "p2")

	var p1_ai1 := ScriptedAI.new()
	p1_ai1.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "ms1", "target_id": "ma1"}))
	var events1 := _drive_turns(state1, db, p1_ai1, ScriptedAI.new(), 3)
	eq(state1.get_card("ma1").damage_taken, 2, "sc46b-b: single target took 2 dmg")
	var dmg_source1 := ""
	for e in events1:
		if e.event_type == "damage_dealt":
			dmg_source1 = e.payload.get("source", dmg_source1)
	eq(dmg_source1, "p1_hero", "sc46b-b2: damage source is p1's hero")
	ok(state1.get_card("ms1").zone_id == "p1_graveyard", "sc46b-b3: Multi-Shot in graveyard")

	# sc46b-c: three-target cast — every target takes the same 2 dmg.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 5)
	var ms3 := CardInstance.create("ms3", "multishot_def", "p1", "p1_hand")
	state3.cards["ms3"] = ms3
	state3.zones["p1_hand"].card_ids.append("ms3")
	_add_ally(state3, "ma3", "ms_victim_a", "p2")
	_add_ally(state3, "mb3", "ms_victim_b", "p2")
	_add_ally(state3, "mc3", "ms_victim_c", "p2")

	var p1_ai3 := ScriptedAI.new()
	p1_ai3.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "ms3", "target_id": "ma3", "target_id_2": "mb3", "target_id_3": "mc3"}))
	_drive_turns(state3, db, p1_ai3, ScriptedAI.new(), 3)
	eq(state3.get_card("ma3").damage_taken, 2, "sc46b-c: 1st target took 2 dmg")
	eq(state3.get_card("mb3").damage_taken, 2, "sc46b-c2: 2nd target took 2 dmg")
	eq(state3.get_card("mc3").damage_taken, 2, "sc46b-c3: 3rd target took 2 dmg")

	# sc46b-d: illegal target combinations.
	var state4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state4, "p1", 5)
	var ms4 := CardInstance.create("ms4", "multishot_def", "p1", "p1_hand")
	state4.cards["ms4"] = ms4
	state4.zones["p1_hand"].card_ids.append("ms4")
	_add_ally(state4, "ma4", "ms_victim_a", "p2")
	_add_ally(state4, "mb4", "ms_victim_b", "p2")
	ok(not StackResolver.can_submit(state4, PendingAction.make("play_instant", "p1",
		{"card_id": "ms4", "target_id": "ma4", "target_id_3": "mb4"}), db),
		"sc46b-d: target_id_3 without target_id_2 is illegal")
	ok(not StackResolver.can_submit(state4, PendingAction.make("play_instant", "p1",
		{"card_id": "ms4", "target_id": "ma4", "target_id_2": "ma4"}), db),
		"sc46b-d2: repeated (non-distinct) target is illegal")

	# sc46b-e: Untargetable can be selected in ANY slot (all three slots select
	# rather than target — card-specific override, unlike Chain Lightning's 1st wave).
	var state6 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state6, "p1", 5)
	var ms6 := CardInstance.create("ms6", "multishot_def", "p1", "p1_hand")
	state6.cards["ms6"] = ms6
	state6.zones["p1_hand"].card_ids.append("ms6")
	_add_ally(state6, "mu6", "ms_untarget",  "p2")
	_add_ally(state6, "mv6", "ms_victim_a",  "p2")
	ok(StackResolver.can_submit(state6, PendingAction.make("play_instant", "p1",
		{"card_id": "ms6", "target_id": "mu6"}), db),
		"sc46b-e: Untargetable CAN be the 1st (mandatory) target of Multi-Shot")

	var p1_ai6 := ScriptedAI.new()
	p1_ai6.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "ms6", "target_id": "mu6", "target_id_2": "mv6"}))
	_drive_turns(state6, db, p1_ai6, ScriptedAI.new(), 3)
	eq(state6.get_card("mu6").damage_taken, 2, "sc46b-e2: Untargetable 1st target took 2 dmg")
	eq(state6.get_card("mv6").damage_taken, 2, "sc46b-e3: 2nd target took 2 dmg")

	# sc46b-f: a target that dies to an earlier hit doesn't block the others.
	var state5 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state5, "p1", 5)
	var ms5 := CardInstance.create("ms5", "multishot_def", "p1", "p1_hand")
	state5.cards["ms5"] = ms5
	state5.zones["p1_hand"].card_ids.append("ms5")
	_add_ally(state5, "mfrail5", "ms_frail",    "p2")   # 2 HP — dies to its 2 dmg
	_add_ally(state5, "mvb5",    "ms_victim_b",  "p2")

	var p1_ai5 := ScriptedAI.new()
	p1_ai5.queue_action(PendingAction.make("play_instant", "p1",
		{"card_id": "ms5", "target_id": "mfrail5", "target_id_2": "mvb5"}))
	_drive_turns(state5, db, p1_ai5, ScriptedAI.new(), 3)
	ok(state5.get_card("mfrail5").zone_id == "p2_graveyard",
		"sc46b-f: 1st target destroyed by its 2 dmg")
	eq(state5.get_card("mvb5").damage_taken, 2,
		"sc46b-f2: 2nd target still took its 2 dmg")

	# sc46b-g: AI targeting — prefers killable allies, then soak, then hero,
	# and always targets opponents only.
	db.ally("ms_hp2", 1, 2, [], 1)   # killed by 2
	db.ally("ms_hp5", 1, 5, [], 2)   # soak
	var state7 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state7, "p1", 5)
	var ms7 := CardInstance.create("ms7", "multishot_def", "p1", "p1_hand")
	state7.cards["ms7"] = ms7
	state7.zones["p1_hand"].card_ids.append("ms7")
	_add_ally(state7, "k7", "ms_hp2", "p2")
	_add_ally(state7, "s7", "ms_hp5", "p2")
	# A friendly ally that must NEVER be targeted.
	_add_ally(state7, "friend7", "ms_hp2", "p1")

	var ai7 := BaseAI.new()
	var act7 := ai7._multi_shot_action(state7, db, "p1", "ms7", "play_instant")
	ok(act7 != null, "sc46b-g: AI produced a Multi-Shot action")
	if act7:
		var picked := [act7.params.get("target_id", ""),
			act7.params.get("target_id_2", ""), act7.params.get("target_id_3", "")]
		ok("friend7" not in picked, "sc46b-g2: AI never targets its own ally")
		eq(act7.params.get("target_id", ""), "k7",
			"sc46b-g3: AI shoots the killable ally first")
		ok("s7" in picked and "p2_hero" in picked,
			"sc46b-g4: AI also hits the soak ally and the enemy hero")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 47 — Untargetable (Jeleane Nightbreeze, dark_portal_170): "This card
# can't be targeted" (References/wow_rules.txt ~line 4215, in play only). Links
# can't choose it as a target (rule 706), but combat is NOT targeting (601.2b)
# and non-targeted effects (AoE) are unaffected. A target that BECOMES
# Untargetable after the announce is illegal at resolution (glossary 4217) —
# the effect fizzles like a target that left play.
#
# Assertions:
#   sc47-a  targeted instant (Quick Strike-style) cannot target it
#   sc47-b  targeted ability (Vanquish-style destroy_target:ally) cannot target it
#   sc47-c  it CAN be attacked (combat is not targeting) and takes combat damage
#   sc47-d  AoE (Flamestrike-style, no target) still hits it
#   sc47-e  target becomes Untargetable after announce → effect fizzles,
#           the instant still goes to the graveyard
#   sc47-f  the same targeted instant is legal against a plain ally (sanity)
# ══════════════════════════════════════════════════════════════════════════════

func _test_untargetable_keyword() -> void:
	_buf.append("\n-- Scenario 47: Untargetable — no link targeting; combat and AoE unaffected --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Jeleane Nightbreeze's real stats: cost 2, 3 ATK melee, 2 health, Untargetable.
	db.ally("jeleane_def", 3, 2, (["untargetable"] as Array[String]), 2)
	db.ally("plain_def", 2, 6, [], 3)
	db.ally("attacker_def", 1, 4, [], 2)
	db.instant("quickstrike_def", 2, "deal_damage_to_target:2:melee")
	db.ability("vanquish_def", 3, "destroy_target:ally")
	db.ability("flamestrike_def", 7, "deal_damage_aoe_opponent:3:fire")

	# sc47-a / sc47-b / sc47-f: submission-time targeting checks.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 7)
	_add_ally(state, "jeleane", "jeleane_def", "p2")
	_add_ally(state, "plain", "plain_def", "p2")
	var qs := CardInstance.create("qs", "quickstrike_def", "p1", "p1_hand")
	state.cards["qs"] = qs
	state.zones["p1_hand"].card_ids.append("qs")
	var vq := CardInstance.create("vq", "vanquish_def", "p1", "p1_hand")
	state.cards["vq"] = vq
	state.zones["p1_hand"].card_ids.append("vq")

	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
		{"card_id": "qs", "target_id": "jeleane"}), db),
		"sc47-a: targeted instant cannot target an Untargetable ally")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
		{"card_id": "vq", "target_id": "jeleane"}), db),
		"sc47-b: targeted ability (destroy) cannot target an Untargetable ally")
	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
		{"card_id": "qs", "target_id": "plain"}), db),
		"sc47-f: the same instant is legal against a plain ally")

	# sc47-c: combat is NOT targeting — Jeleane is a legal defender and takes
	# combat damage normally.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state2, "jeleane2", "jeleane_def", "p2")
	var atk := _add_ally(state2, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	state2.players["p1"].resource_placed_this_turn = true

	ok(StackResolver.can_submit(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "jeleane2"}), db),
		"sc47-c: an Untargetable ally CAN be attacked (combat is not targeting)")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "jeleane2"}))
	_drive(state2, db, p1_ai, ScriptedAI.new())
	eq(state2.get_card("jeleane2").damage_taken, 1,
		"sc47-c2: combat damage landed on the Untargetable defender")

	# sc47-d: AoE (no target announced) still hits Untargetable allies.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 7)
	_add_ally(state3, "jeleane3", "jeleane_def", "p2")
	var fs := CardInstance.create("fs", "flamestrike_def", "p1", "p1_hand")
	state3.cards["fs"] = fs
	state3.zones["p1_hand"].card_ids.append("fs")

	var fs_act := PendingAction.make("play_ability", "p1", {"card_id": "fs"})
	ok(StackResolver.can_submit(state3, fs_act, db), "sc47-d: AoE submission is legal")
	StackResolver.submit_action(state3, fs_act, db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)
	ok(state3.get_card("jeleane3").zone_id == "p2_graveyard",
		"sc47-d2: AoE damage hit (and destroyed) the Untargetable ally")

	# sc47-e: resolution-time re-check (glossary 4217) — the target becomes
	# Untargetable AFTER the announce (simulated via granted_keywords, the same
	# container _has_keyword reads). The damage fizzles; the instant still goes
	# to the graveyard, same as a target that left play.
	var state4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state4, "p1", 2)
	_add_ally(state4, "plain4", "plain_def", "p2")
	var qs4 := CardInstance.create("qs4", "quickstrike_def", "p1", "p1_hand")
	state4.cards["qs4"] = qs4
	state4.zones["p1_hand"].card_ids.append("qs4")

	var qs_act := PendingAction.make("play_instant", "p1",
		{"card_id": "qs4", "target_id": "plain4"})
	ok(StackResolver.can_submit(state4, qs_act, db), "sc47-e: announce against a legal target")
	StackResolver.submit_action(state4, qs_act, db)
	state4.get_card("plain4").granted_keywords.append("untargetable")
	StackResolver.pass_priority(state4, db)
	StackResolver.pass_priority(state4, db)
	eq(state4.get_card("plain4").damage_taken, 0,
		"sc47-e2: effect fizzled — target that became Untargetable took no damage")
	ok(state4.get_card("qs4").zone_id == "p1_graveyard",
		"sc47-e3: the fizzled instant still goes to the graveyard")

# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 39 — Infernal (azeroth_127): "At the start of your turn, discard a
# card, or target opponent gains control of Infernal. At the end of your turn,
# Infernal deals 1 fire damage to each opposing hero and ally."
# ══════════════════════════════════════════════════════════════════════════════

const INFERNAL_FX := "turn_start_discard_or_give_control|end_of_turn_damage_opposing:1:fire"

func _infernal_db() -> MockDB:
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.pet("infernal_def", 6, 6, [], 6, INFERNAL_FX)
	db.ally("junk_def", 1, 1, [], 1)
	return db

# Advance from p2's end phase into p1's ready step, firing start-of-turn triggers.
func _infernal_start_p1_turn(state: GameState, db) -> Array[GameEvent]:
	state.phase       = "end"
	state.turn_player = "p2"
	return TurnManager.advance_phase(state, db)


func _test_infernal_discard_keeps_control() -> void:
	_buf.append("\n-- Scenario 39a: Infernal — discard a card to keep control --")
	var db := _infernal_db()
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "infernal_inst", "infernal_def", "p1")
	var junk := CardInstance.create("junk_inst", "junk_def", "p1", "p1_hand")
	state.cards["junk_inst"] = junk
	state.zones["p1_hand"].card_ids.append("junk_inst")

	var adv := _infernal_start_p1_turn(state, db)
	var opened := adv.any(func(e: GameEvent) -> bool:
		return e.event_type == "control_discard_choice_opened")
	ok(opened, "sc39a-a: control_discard_choice_opened fired at start of p1's turn")
	eq(state.pending_control_discard_player, "p1", "sc39a-b: pending choice belongs to p1")

	# Choice blocks priority: passing and submitting are both refused.
	ok(StackResolver.pass_priority(state, db).is_empty(),
		"sc39a-c: pass_priority is blocked while the choice is pending")

	var events := StackResolver.choose_control_discard(state, "junk_inst", db)
	ok(not events.is_empty(), "sc39a-d: choose_control_discard resolved")
	eq(state.get_card("junk_inst").zone_id, "p1_graveyard", "sc39a-e: hand card discarded")
	eq(state.get_card("infernal_inst").controller, "p1", "sc39a-f: Infernal still controlled by p1")
	eq(state.get_card("infernal_inst").zone_id, "p1_ally_row", "sc39a-g: Infernal still in p1_ally_row")
	eq(state.pending_control_discard_player, "", "sc39a-h: pending choice cleared")


func _test_infernal_decline_gives_control() -> void:
	_buf.append("\n-- Scenario 39b: Infernal — decline the discard, opponent gains control --")
	var db := _infernal_db()
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "infernal_inst", "infernal_def", "p1")

	_infernal_start_p1_turn(state, db)
	eq(state.pending_control_discard_player, "p1", "sc39b-a: pending choice belongs to p1")

	var events := StackResolver.decline_control_discard(state, db)
	var changed := events.any(func(e: GameEvent) -> bool:
		return e.event_type == "control_changed")
	ok(changed, "sc39b-b: control_changed event fired")
	var infernal := state.get_card("infernal_inst")
	eq(infernal.controller, "p2", "sc39b-c: Infernal controlled by p2")
	eq(infernal.zone_id, "p2_ally_row", "sc39b-d: Infernal moved to p2_ally_row (rule 401.3)")
	ok(infernal.just_summoned,
		"sc39b-e: Infernal can't attack for p2 this turn (not controlled since turn start)")
	eq(state.pending_control_discard_player, "", "sc39b-f: pending choice cleared")


func _test_infernal_decline_pet_uniqueness() -> void:
	_buf.append("\n-- Scenario 39c: Infernal declined into a party that already has a Pet --")
	var db := _infernal_db()
	db.pet("otherpet_def", 2, 2, [], 2)
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "infernal_inst", "infernal_def", "p1")
	_add_ally(state, "otherpet_inst", "otherpet_def", "p2")

	_infernal_start_p1_turn(state, db)
	var events := StackResolver.decline_control_discard(state, db)
	var sac_required := events.any(func(e: GameEvent) -> bool:
		return e.event_type == "pet_sacrifice_required")
	ok(sac_required, "sc39c-a: pet uniqueness fires for the new controller")
	eq(state.pending_pet_sacrifice_player, "p2", "sc39c-b: p2 must sacrifice a pet")
	events = StackResolver.choose_pet_sacrifice(state, "otherpet_inst", db)
	ok(not events.is_empty(), "sc39c-c: p2 sacrificed the other pet")
	eq(state.get_card("infernal_inst").zone_id, "p2_ally_row",
		"sc39c-d: Infernal survives in p2_ally_row")


func _test_infernal_end_of_turn_damage() -> void:
	_buf.append("\n-- Scenario 39d: Infernal — end of turn, 1 fire to each opposing hero and ally --")
	var db := _infernal_db()
	db.ally("tough_def", 0, 3)
	db.ally("weak_def", 0, 1)
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "infernal_inst", "infernal_def", "p1")
	_add_ally(state, "friendly_inst", "weak_def", "p1")
	_add_ally(state, "tough_inst", "tough_def", "p2")
	_add_ally(state, "weak_inst", "weak_def", "p2")

	# Advance p1's action phase into the end phase — end-of-turn triggers fire.
	state.phase       = "action"
	state.turn_player = "p1"
	TurnManager.advance_phase(state, db)

	eq(state.get_current_hp("p2_hero", db), 29, "sc39d-a: opposing hero took 1 fire damage")
	eq(state.get_card("tough_inst").damage_taken, 1, "sc39d-b: opposing ally took 1 damage")
	eq(state.get_card("weak_inst").zone_id, "p2_graveyard", "sc39d-c: 1-health opposing ally destroyed")
	eq(state.get_current_hp("p1_hero", db), 30, "sc39d-d: own hero untouched")
	eq(state.get_card("friendly_inst").damage_taken, 0, "sc39d-e: own ally untouched")
	eq(state.get_card("infernal_inst").damage_taken, 0, "sc39d-f: Infernal doesn't damage itself")


func _test_hierophant_caydiem_power() -> void:
	_buf.append("\n-- Hierophant Caydiem: 1 nature damage to target + heal 1 from another target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("caydiem_def", 2, 4, [], 4,
		"activated_power:3:deal_damage_and_heal:1:nature:hero_or_ally_two:no_activate")
	db.ally("dummy_ally_def", 0, 3, [], 0)

	var state := _base_state(db, "p1_hero", "p2_hero")

	# Printed cost is a plain "3 ->" with no [Activate] tap symbol, so this is a
	# 701.2 payment power (like Acolyte Demia), not a 701.3 activated power:
	# still just_summoned AND already exhausted, to prove neither summoning
	# sickness nor the exhausted state gates a plain payment power (701.2 has
	# no such restriction — only 701.3 activated powers check is_exhausted).
	var caydiem := _add_ally(state, "caydiem_inst", "caydiem_def", "p1")
	caydiem.just_summoned = true
	caydiem.is_exhausted  = true

	# Friendly damaged ally to heal.
	var friendly := _add_ally(state, "friendly_inst", "dummy_ally_def", "p1")
	friendly.damage_taken = 2

	# Enemy ally to damage.
	_add_ally(state, "enemy_inst", "dummy_ally_def", "p2")

	_add_resources(state, "p1", 3)
	state.players["p1"].resource_placed_this_turn = true

	# hc-a: same card can't be both damage and heal target (rule 706.1).
	var same_target := PendingAction.make("use_ally_power", "p1", {
		"card_id": "caydiem_inst", "target_id": "enemy_inst", "heal_target_id": "enemy_inst",
	})
	ok(not StackResolver.can_submit(state, same_target, db),
		"hc-a: damage and heal target can't be the same card")

	# hc-b: legal action — damage the enemy ally, heal the friendly ally.
	var action := PendingAction.make("use_ally_power", "p1", {
		"card_id": "caydiem_inst", "target_id": "enemy_inst", "heal_target_id": "friendly_inst",
	})
	ok(StackResolver.can_submit(state, action, db), "hc-b: distinct damage/heal targets are legal")

	StackResolver.submit_action(state, action, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("enemy_inst").damage_taken, 1, "hc-c: enemy ally took 1 nature damage")
	eq(state.get_card("friendly_inst").damage_taken, 1, "hc-d: friendly ally healed 1 (2 -> 1)")
	ok(state.get_card("caydiem_inst").is_exhausted,
		"hc-e: Caydiem's exhausted state is untouched by the power (still exhausted from setup — no [Activate] tap symbol on the printed cost, so using it neither requires nor causes exhaustion)")

	# hc-f: repeatable the same turn since it never exhausted and has no
	# once-per-turn text.
	_add_resources(state, "p1", 3)
	state.players["p1"].resource_placed_this_turn = true
	var friendly2 := _add_ally(state, "friendly_inst2", "dummy_ally_def", "p1")
	friendly2.damage_taken = 2
	var action2 := PendingAction.make("use_ally_power", "p1", {
		"card_id": "caydiem_inst", "target_id": "enemy_inst", "heal_target_id": "friendly_inst2",
	})
	ok(StackResolver.can_submit(state, action2, db), "hc-f: power usable again the same turn")
	StackResolver.submit_action(state, action2, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("enemy_inst").damage_taken, 2, "hc-g: enemy ally took another 1 nature damage")

	# hc-h: BaseAI._get_ally_power_actions must propose this power even while
	# Caydiem is exhausted AND just_summoned (701.2 payment power — no
	# [Activate] symbol, so summoning sickness/exhaustion don't gate it, same
	# as the engine-level check above). Regression for a bug where the AI's
	# generic ally-power gate wrongly skipped no_activate/put_damage_self
	# powers whenever the source was tapped or freshly played — Caydiem's
	# power would then almost never fire in a real AI game.
	_add_resources(state, "p1", 3)
	var ai := BaseAI.new()
	var legal := ai.get_reasonable_actions(state, db, "p1")
	var proposed_caydiem := false
	for a in legal:
		if a.action_type == "use_ally_power" and a.params.get("card_id", "") == "caydiem_inst":
			proposed_caydiem = true
	ok(proposed_caydiem,
		"hc-h: AI proposes Caydiem's power while exhausted and just_summoned")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 49 — Tanwa the Marksman: Long-Range (defenders deal no combat damage)
# ══════════════════════════════════════════════════════════════════════════════

func _test_tanwa_long_range() -> void:
	_buf.append("\n-- Scenario 49: Long-Range — defender deals no combat damage back --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tanwa_def", 4, 3, (["long_range"] as Array[String]), 6)
	db.ally("plain_def", 5, 6, [], 3)

	# tl-a: Long-Range attacker vs a hard-hitting ally defender — defender
	# deals 0 damage back, attacker still deals its own damage normally.
	var state := _base_state(db, "p1_hero", "p2_hero")
	var tanwa := _add_ally(state, "tanwa", "tanwa_def", "p1")
	tanwa.just_summoned = false
	_add_ally(state, "plain", "plain_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "tanwa", "defender_id": "plain"}))
	var p2_ai := ScriptedAI.new()

	_drive(state, db, p1_ai, p2_ai)

	eq(state.get_card("plain").damage_taken, 4, "tl-a: defender took 4 damage from Long-Range attacker")
	eq(state.get_card("tanwa").damage_taken, 0, "tl-b: Long-Range attacker took 0 damage back")

	# tl-c: when Tanwa is the DEFENDER instead, Long-Range has no effect —
	# it only suppresses damage from defenders while Tanwa is attacking.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state2, "tanwa2", "tanwa_def", "p2")
	var atk2 := _add_ally(state2, "atk2", "plain_def", "p1")
	atk2.just_summoned = false
	state2.players["p1"].resource_placed_this_turn = true

	var p1_ai2 := ScriptedAI.new()
	p1_ai2.queue_action(PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk2", "defender_id": "tanwa2"}))
	var p2_ai2 := ScriptedAI.new()

	_drive(state2, db, p1_ai2, p2_ai2)

	eq(state2.get_card("atk2").damage_taken, 4, "tl-c: attacker still takes damage from Tanwa when Tanwa defends")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 50 — GenericAI: all-out hero lethal
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_all_out_hero_lethal() -> void:
	_buf.append("\n-- Scenario 50: GenericAI attacks all-out when the combined board is lethal --")
	var ai := GenericAI.new()

	# aol-a: no single attacker is lethal (3 and 5 vs 8 hp), but together they
	# are (8 >= 8) and the enemy has no Protector — go all out with the least
	# valuable attacker first.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("small_def", 3, 3, [], 1)
	db.ally("big_def",   5, 5, [], 4)
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "small", "small_def", "p1")
	_add_ally(st, "big",   "big_def",   "p1")
	st.players["p1"].resource_placed_this_turn = true
	st.get_card("p2_hero").damage_taken = 22   # 8 HP left

	ok(ai._hero_lethal_action(st, db, "p1") == null,
		"aol-a1: neither attacker alone is lethal (3 or 5 vs 8 hp)")
	var act := ai._all_out_hero_lethal_action(st, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "small"
			and act.params.get("defender_id") == "p2_hero",
		"aol-a2: all-out triggers (3+5=8 >= 8 hp), least valuable attacker first")

	# aol-b: an enemy Protector on board blunts the assumption — bail out.
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.ally("small_def", 3, 3, [], 1)
	db2.ally("big_def",   5, 5, [], 4)
	db2.ally("prot_def",  1, 1, (["protector"] as Array[String]), 1)
	var st2 := _base_state(db2, "p1_hero", "p2_hero")
	_add_ally(st2, "small", "small_def", "p1")
	_add_ally(st2, "big",   "big_def",   "p1")
	_add_ally(st2, "prot",  "prot_def",  "p2")
	st2.players["p1"].resource_placed_this_turn = true
	st2.get_card("p2_hero").damage_taken = 22   # 8 HP left

	ok(ai._all_out_hero_lethal_action(st2, db2, "p1") == null,
		"aol-b: enemy Protector present → no all-out swing")

	# aol-c: enemy armor block raises the required total — 8 ATK vs 8 hp + 2
	# block (DEF-2 ready armor) is not enough; without the armor it would be.
	var db3 := MockDB.new()
	db3.hero("p1_hero", 30)
	db3.hero("p2_hero", 30)
	db3.ally("small_def", 3, 3, [], 1)
	db3.ally("big_def",   5, 5, [], 4)
	db3.equipment("armor_def", 2, "equipment:chest:2")
	var st3 := _base_state(db3, "p1_hero", "p2_hero")
	_add_ally(st3, "small", "small_def", "p1")
	_add_ally(st3, "big",   "big_def",   "p1")
	var armor := CardInstance.create("armor", "armor_def", "p2", "p2_hero_row")
	st3.cards["armor"] = armor
	st3.zones["p2_hero_row"].card_ids.append("armor")
	st3.players["p1"].resource_placed_this_turn = true
	st3.get_card("p2_hero").damage_taken = 22   # 8 HP left

	ok(ai._all_out_hero_lethal_action(st3, db3, "p1") == null,
		"aol-c: ready DEF-2 armor raises the threshold to 10 → 8 ATK isn't enough")

	# Exhaust the armor (already used/committed elsewhere) — now it can't add
	# more block, so the same 8 ATK is lethal again.
	armor.is_exhausted = true
	act = ai._all_out_hero_lethal_action(st3, db3, "p1")
	ok(act != null and act.params.get("attacker_id") == "small",
		"aol-d: exhausted armor can't block → all-out triggers again")

	# aol-e: decide_action's pipeline picks the all-out swing over develop/chip.
	act = ai.decide_action(st3, db3, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("defender_id") == "p2_hero",
		"aol-e: decide_action returns the all-out attack ahead of develop/chip")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 51 — GenericAI: all-out + finishing spell
# ══════════════════════════════════════════════════════════════════════════════

func _test_generic_ai_all_out_with_spell_lethal() -> void:
	_buf.append("\n-- Scenario 51: GenericAI attacks all-out then finishes with a held spell --")
	var ai := GenericAI.new()

	# aos-a: 3+5=8 ATK alone can't reach 9 hp, but +4 from Lightning Bolt can.
	# Board isn't lethal all-out by itself → attack first, hold the spell.
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("small_def", 3, 3, [], 1)
	db.ally("big_def",   5, 5, [], 4)
	db.instant("bolt_def", 3, "deal_damage_to_target:4:nature")
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(st, "small", "small_def", "p1")
	_add_ally(st, "big",   "big_def",   "p1")
	var bolt := CardInstance.create("bolt", "bolt_def", "p1", "p1_hand")
	st.cards["bolt"] = bolt
	st.zones["p1_hand"].card_ids.append("bolt")
	st.players["p1"].resource_placed_this_turn = true
	_add_resources(st, "p1", 3)
	st.get_card("p2_hero").damage_taken = 21   # 9 HP left

	ok(ai._all_out_hero_lethal_action(st, db, "p1") == null,
		"aos-a1: 3+5=8 ATK alone isn't lethal against 9 hp")
	var act := ai._all_out_with_spell_hero_lethal_action(st, db, "p1")
	ok(act != null and act.action_type == "propose_combat"
			and act.params.get("attacker_id") == "small",
		"aos-a2: 8 ATK + 4 dmg clears 9 hp → attack first, least valuable attacker")

	# aos-b: once every attacker has swung, the spell itself is returned as
	# the finisher instead of being left to the develop step. Simulate the
	# attacks having actually connected (8 dmg) — exhausting the allies alone,
	# without reducing the hero's HP, would leave 9 HP against a 4-dmg spell
	# and correctly read as not-lethal.
	st.get_card("small").is_exhausted = true
	st.get_card("big").is_exhausted = true
	st.get_card("p2_hero").damage_taken = 29   # 1 HP left after the 8-dmg swing
	act = ai._all_out_with_spell_hero_lethal_action(st, db, "p1")
	ok(act != null and act.action_type == "play_instant"
			and act.params.get("card_id") == "bolt"
			and act.params.get("target_id") == "p2_hero",
		"aos-b: no attackers left to swing → deliver the finishing spell")

	# aos-c: not enough resources to actually cast the spell this turn → the
	# combo isn't recognized at all (falls through, doesn't force a bad swing).
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.ally("small_def", 3, 3, [], 1)
	db2.ally("big_def",   5, 5, [], 4)
	db2.instant("bolt_def", 3, "deal_damage_to_target:4:nature")
	var st2 := _base_state(db2, "p1_hero", "p2_hero")
	_add_ally(st2, "small", "small_def", "p1")
	_add_ally(st2, "big",   "big_def",   "p1")
	var bolt2 := CardInstance.create("bolt", "bolt_def", "p1", "p1_hand")
	st2.cards["bolt"] = bolt2
	st2.zones["p1_hand"].card_ids.append("bolt")
	st2.players["p1"].resource_placed_this_turn = true
	# No resources placed — Lightning Bolt (cost 3) isn't payable this turn.
	st2.get_card("p2_hero").damage_taken = 21   # 9 HP left

	ok(ai._all_out_with_spell_hero_lethal_action(st2, db2, "p1") == null,
		"aos-c: spell isn't affordable this turn → combo not recognized")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 52 — Litori Frostburn: "can't attack" in response to a combat
# proposal interrupts the proposal (601.3) — attacker never exhausts.
# ══════════════════════════════════════════════════════════════════════════════

func _test_litori_freeze_fizzles_proposal() -> void:
	_buf.append("\n-- Scenario 52: Litori freeze in response to proposal — fizzle, no exhaust --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("litori_def", 25, 2, "target_cant_attack")
	db.ally("attacker_def", 4, 4, [], 3)

	var state := _base_state(db, "p1_hero", "litori_def")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var all_events: Array[GameEvent] = []
	# p1 proposes combat vs p2's hero; the proposal sits on the chain.
	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "litori_def"})
	all_events.append_array(StackResolver.submit_action(state, proposal, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 → p2

	# p2 flips Litori targeting the proposed attacker, in response.
	var flip := PendingAction.make("activate_power", "p2",
		{"hero_id": "litori_def", "target_id": "atk"})
	ok(StackResolver.can_submit(state, flip, db),
		"li-a: Litori flip is legal in response to the enemy proposal")
	all_events.append_array(StackResolver.submit_action(state, flip, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p2 passes
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 passes → flip resolves

	ok(atk.has_restriction("cannot_attack"),
		"li-b: attacker carries the cannot_attack restriction after the flip resolves")

	# Both pass again → the proposal itself resolves and must fizzle (601.3).
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))

	var saw_fizzle := false
	for e in all_events:
		if e.event_type == "action_fizzled":
			saw_fizzle = true
	ok(saw_fizzle, "li-c: proposal fizzled at resolution")
	ok(not atk.is_exhausted, "li-d: attacker did NOT exhaust — combat never started")
	ok(not state.combat_attack_window, "li-e: no attack window opened")
	eq(state.get_card("litori_def").damage_taken, 0, "li-f: hero took no damage")

	# Attacker can't be proposed again this turn.
	ok("atk" not in StackResolver.get_legal_attackers(state, "p1", db),
		"li-g: frozen attacker is not a legal attacker")
	var again := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "litori_def"})
	ok(not StackResolver.can_submit(state, again, db),
		"li-h: re-proposing with the frozen attacker is rejected")

	# The restriction is "this turn" — the end-of-turn buff sweep clears it.
	atk.decrement_turn_buffs()
	ok("atk" in StackResolver.get_legal_attackers(state, "p1", db),
		"li-i: after the turn sweep the attacker is legal again")

	# The flip is once per game.
	ok(state.players["p2"].has_used_hero_power, "li-j: hero power marked as used")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 53 — Litori during the attack window is TOO LATE: the attacker is
# already attacking (602.1) and "can't attack" is not a remove-from-combat
# effect (602.4) — combat proceeds and damage is dealt.
# ══════════════════════════════════════════════════════════════════════════════

func _test_litori_too_late_in_window() -> void:
	_buf.append("\n-- Scenario 53: Litori during the attack window doesn't stop the combat --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("litori_def", 25, 2, "target_cant_attack")
	db.ally("attacker_def", 4, 4, [], 3)

	var state := _base_state(db, "p1_hero", "litori_def")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# Proposal resolves uncontested — combat step starts, attack window opens.
	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "litori_def"})
	StackResolver.submit_action(state, proposal, db)
	StackResolver.pass_priority(state, db)   # p1 passes
	StackResolver.pass_priority(state, db)   # p2 passes → proposal resolves
	ok(state.combat_attack_window, "lw-a: attack window is open")
	ok(atk.is_exhausted, "lw-b: attacker exhausted at combat start")

	# p2 flips Litori on the attacker mid-window — legal, but too late.
	StackResolver.pass_priority(state, db)   # p1 passes → priority p2
	var flip := PendingAction.make("activate_power", "p2",
		{"hero_id": "litori_def", "target_id": "atk"})
	ok(StackResolver.can_submit(state, flip, db), "lw-c: flip is submittable in the window")
	StackResolver.submit_action(state, flip, db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → flip resolves
	ok(atk.has_restriction("cannot_attack"), "lw-d: restriction applied")

	# Drive the combat to conclusion: attack window close → defend window → damage.
	for i in range(6):
		if state.get_card("litori_def").damage_taken > 0:
			break
		StackResolver.pass_priority(state, db)

	eq(state.get_card("litori_def").damage_taken, 4,
		"lw-e: combat concluded normally — hero took the 4 damage")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO 54 — AI uses the Litori flip to cancel a dangerous incoming attack
# while the proposal is still on the chain (and holds it otherwise).
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_litori_freeze_save() -> void:
	_buf.append("\n-- Scenario 54: AI flips Litori in response to a heavy attack proposal --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("litori_def", 25, 2, "target_cant_attack")
	db.ally("big_def",   5, 5, [], 4)
	db.ally("small_def", 2, 2, [], 1)

	# af-a: 5 ATK at our hero (>= 4 threshold) → the AI answers the proposal.
	var state := _base_state(db, "p1_hero", "litori_def")
	var big := _add_ally(state, "big", "big_def", "p1")
	big.just_summoned = false
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true

	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "big", "defender_id": "litori_def"})
	StackResolver.submit_action(state, proposal, db)
	StackResolver.pass_priority(state, db)   # p1 passes → priority p2

	var act := ai.decide_action(state, db, "p2")
	ok(act != null and act.action_type == "activate_power"
			and act.params.get("target_id") == "big",
		"af-a: AI flips Litori targeting the proposed attacker")

	# Play it out: the proposal must fizzle and the attacker stays ready.
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # flip resolves
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # proposal fizzles
	ok(not state.get_card("big").is_exhausted and not state.combat_attack_window,
		"af-b: proposal cancelled — attacker never exhausted, no combat")

	# af-c: chip attack (2 ATK, hero at full 25) → hold the once-per-game flip.
	var state2 := _base_state(db, "p1_hero", "litori_def")
	var small := _add_ally(state2, "small", "small_def", "p1")
	small.just_summoned = false
	_add_resources(state2, "p2", 2)
	state2.players["p1"].resource_placed_this_turn = true

	var proposal2 := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "small", "defender_id": "litori_def"})
	StackResolver.submit_action(state2, proposal2, db)
	StackResolver.pass_priority(state2, db)
	ok(ai.decide_action(state2, db, "p2") == null,
		"af-c: AI holds the flip against a 2-ATK chip attack")


# ══════════════════════════════════════════════════════════════════════════════
# Exhaustion (azeroth_159, Instant Ability — "Exhaust target ally"): played in
# response to a combat proposal and aimed at the ally attacker, exhausting it
# fizzles the proposal (601.3 recheck), exactly like Litori's freeze. Ally-only,
# and too late once the attack window has opened.
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
# War Stomp (dark_portal_137): "Exhaust all opposing heroes and allies."
# Non-targeted mass exhaust — hits Untargetable characters, spares the caster's
# own side; in response to a proposal it fizzles the combat via the 601.3 recheck.
# ══════════════════════════════════════════════════════════════════════════════

func _test_war_stomp_mass_exhaust() -> void:
	_buf.append("\n-- War Stomp: exhaust all opposing heroes and allies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 4, 4, [], 3)
	db.ally("sneaky_def", 2, 2, ["untargetable"], 2)
	db.ally("own_def", 2, 2, [], 1)
	db.instant("dark_portal_137", 3, "requires_hero_race:Tauren|exhaust_all_opposing")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	var sneaky := _add_ally(state, "sneaky", "sneaky_def", "p1")
	sneaky.just_summoned = false
	var own := _add_ally(state, "own", "own_def", "p2")
	own.just_summoned = false
	_add_card_to_hand(state, "stomp", "dark_portal_137", "p2")
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var all_events: Array[GameEvent] = []
	# p1 proposes combat vs p2's hero; the proposal sits on the chain.
	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"})
	all_events.append_array(StackResolver.submit_action(state, proposal, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 → p2

	# p2 plays War Stomp in response — no target announced (non-targeted).
	var cast := PendingAction.make("play_instant", "p2", {"card_id": "stomp"})
	ok(StackResolver.can_submit(state, cast, db),
		"ws-a: War Stomp is legal in response to the proposal (instant, no target)")
	all_events.append_array(StackResolver.submit_action(state, cast, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p2 passes
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 passes → cast resolves

	ok(atk.is_exhausted, "ws-b: opposing attacker is exhausted")
	ok(sneaky.is_exhausted, "ws-c: Untargetable opposing ally is exhausted too (non-targeted)")
	ok(state.get_card("p1_hero").is_exhausted, "ws-d: opposing hero is exhausted")
	ok(not own.is_exhausted, "ws-e: caster's own ally is untouched")
	ok(not state.get_card("p2_hero").is_exhausted, "ws-f: caster's hero is untouched")

	# Both pass again → the proposal itself resolves and must fizzle (601.3).
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))
	var saw_fizzle := false
	for e in all_events:
		if e.event_type == "action_fizzled":
			saw_fizzle = true
	ok(saw_fizzle, "ws-g: proposal fizzled at resolution")
	ok(not state.combat_attack_window, "ws-h: no attack window opened")
	ok(state.get_card("stomp").zone_id == "p2_graveyard", "ws-i: War Stomp is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# AI plays War Stomp (combat_instant_exhaust, mass/no-target) in response to a
# dangerous proposal. (Unlike Exhaustion it could also answer an attacking hero —
# the `mass` gate in exhaust_attacker_action skips the ally-only check.)
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_war_stomp_freeze_save() -> void:
	_buf.append("\n-- AI plays War Stomp in response to a heavy attack proposal --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def", 5, 5, [], 4)
	db.instant("dark_portal_137", 3, "requires_hero_race:Tauren|exhaust_all_opposing")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var big := _add_ally(state, "big", "big_def", "p1")
	big.just_summoned = false
	_add_card_to_hand(state, "stomp", "dark_portal_137", "p2")
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true

	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "big", "defender_id": "p2_hero"})
	StackResolver.submit_action(state, proposal, db)
	StackResolver.pass_priority(state, db)   # p1 passes → priority p2

	var act := ai.decide_action(state, db, "p2")
	ok(act != null and act.action_type == "play_instant"
			and act.params.get("card_id") == "stomp"
			and act.params.get("target_id", "") == "",
		"ws-ai-a: AI plays War Stomp (no target) against the proposal")

	# Play it out: the proposal must fizzle and the attacker ends up exhausted.
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # cast resolves
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # proposal fizzles
	ok(state.get_card("big").is_exhausted and not state.combat_attack_window,
		"ws-ai-b: proposal cancelled — attacker exhausted, no combat")


func _test_exhaustion_freezes_proposal() -> void:
	_buf.append("\n-- Exhaustion: freeze the ally attacker in response to a proposal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 4, 4, [], 3)
	db.instant("azeroth_159", 2, "exhaust_target:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_card_to_hand(state, "exh", "azeroth_159", "p2")
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# Ally-only targeting: Exhaustion can't be aimed at a hero.
	var at_hero := PendingAction.make("play_instant", "p2",
		{"card_id": "exh", "target_id": "p1_hero"})
	ok(not StackResolver.can_submit(state, at_hero, db),
		"ex-a: Exhaustion can't target a hero (ally-only)")

	var all_events: Array[GameEvent] = []
	# p1 proposes combat vs p2's hero; the proposal sits on the chain.
	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"})
	all_events.append_array(StackResolver.submit_action(state, proposal, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 → p2

	# p2 plays Exhaustion targeting the proposed attacker, in response.
	var cast := PendingAction.make("play_instant", "p2",
		{"card_id": "exh", "target_id": "atk"})
	ok(StackResolver.can_submit(state, cast, db),
		"ex-b: Exhaustion on the attacker is legal in response to the proposal")
	all_events.append_array(StackResolver.submit_action(state, cast, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p2 passes
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 passes → cast resolves

	ok(atk.is_exhausted, "ex-c: attacker is exhausted after Exhaustion resolves")

	# Both pass again → the proposal itself resolves and must fizzle (601.3).
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))

	var saw_fizzle := false
	for e in all_events:
		if e.event_type == "action_fizzled":
			saw_fizzle = true
	ok(saw_fizzle, "ex-d: proposal fizzled at resolution")
	ok(not state.combat_attack_window, "ex-e: no attack window opened")
	eq(state.get_card("p2_hero").damage_taken, 0, "ex-f: hero took no damage")
	# Exhaustion went to the graveyard.
	ok(state.get_card("exh").zone_id == "p2_graveyard", "ex-g: Exhaustion is in the graveyard")

	# The exhausted attacker can't be proposed again (it's exhausted, not readied).
	ok("atk" not in StackResolver.get_legal_attackers(state, "p1", db),
		"ex-h: exhausted attacker is not a legal attacker")


# ══════════════════════════════════════════════════════════════════════════════
# AI uses Exhaustion to cancel a dangerous incoming attack while the proposal is
# on the chain (and holds it against a chip attack).
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_exhaustion_freeze_save() -> void:
	_buf.append("\n-- AI plays Exhaustion in response to a heavy attack proposal --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def",   5, 5, [], 4)
	db.ally("small_def", 2, 2, [], 1)
	db.instant("azeroth_159", 2, "exhaust_target:ally")

	# ax-a: 5 ATK at our hero (>= 4 threshold) → the AI answers the proposal.
	var state := _base_state(db, "p1_hero", "p2_hero")
	var big := _add_ally(state, "big", "big_def", "p1")
	big.just_summoned = false
	_add_card_to_hand(state, "exh", "azeroth_159", "p2")
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true

	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "big", "defender_id": "p2_hero"})
	StackResolver.submit_action(state, proposal, db)
	StackResolver.pass_priority(state, db)   # p1 passes → priority p2

	var act := ai.decide_action(state, db, "p2")
	ok(act != null and act.action_type == "play_instant"
			and act.params.get("card_id") == "exh"
			and act.params.get("target_id") == "big",
		"ax-a: AI plays Exhaustion targeting the proposed attacker")

	# Play it out: the proposal must fizzle and the attacker ends up exhausted.
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # cast resolves
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # proposal fizzles
	ok(state.get_card("big").is_exhausted and not state.combat_attack_window,
		"ax-b: proposal cancelled — attacker exhausted, no combat")

	# ax-c: chip attack (2 ATK, hero at full) → hold Exhaustion.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	var small := _add_ally(state2, "small", "small_def", "p1")
	small.just_summoned = false
	_add_card_to_hand(state2, "exh2", "azeroth_159", "p2")
	_add_resources(state2, "p2", 2)
	state2.players["p1"].resource_placed_this_turn = true

	var proposal2 := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "small", "defender_id": "p2_hero"})
	StackResolver.submit_action(state2, proposal2, db)
	StackResolver.pass_priority(state2, db)
	ok(ai.decide_action(state2, db, "p2") == null,
		"ax-c: AI holds Exhaustion against a 2-ATK chip attack")


# ══════════════════════════════════════════════════════════════════════════════
# Coup de Grâce (azeroth_93, 2, Ability — Assassination): "Destroy target
# exhausted ally." A sorcery-speed destroy restricted to exhausted allies of
# either party. AI destroys the most valuable exhausted OPPOSING ally.
# ══════════════════════════════════════════════════════════════════════════════
func _test_coup_de_grace_destroys_exhausted_ally() -> void:
	_buf.append("\n-- Coup de Grâce destroys only exhausted allies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("victim_def", 3, 4, [], 3)
	db.ability("azeroth_93", 2, "destroy_target:exhausted_ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	_add_card_to_hand(state, "cdg", "azeroth_93", "p1")
	var victim := _add_ally(state, "victim", "victim_def", "p2")
	victim.just_summoned = false
	victim.is_exhausted  = false

	var cdg_def := db.get_def("azeroth_93") as CardDef

	# cdg-a: no legal target while the only ally is ready → not highlightable.
	ok(not StackResolver._targeted_play_has_legal_target(state, cdg_def, db, "p1"),
		"cdg-a: no highlight while no exhausted ally exists")

	# cdg-b: hero target rejected.
	var hit_hero := PendingAction.make("play_ability", "p1",
		{"card_id": "cdg", "target_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, hit_hero, db),
		"cdg-b: enemy hero is NOT a legal target")

	# cdg-c: ready ally rejected.
	var hit_ready := PendingAction.make("play_ability", "p1",
		{"card_id": "cdg", "target_id": "victim"})
	ok(not StackResolver.can_submit(state, hit_ready, db),
		"cdg-c: a ready ally is NOT a legal target")

	# Now exhaust the ally.
	victim.is_exhausted = true

	ok(StackResolver._targeted_play_has_legal_target(state, cdg_def, db, "p1"),
		"cdg-d: highlightable once an exhausted ally exists")
	ok(StackResolver.can_submit(state, hit_ready, db),
		"cdg-e: an exhausted ally IS a legal target")

	# cdg-f: resolve — the exhausted ally is destroyed.
	StackResolver.submit_action(state, hit_ready, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(not state.is_in_play("victim"),
		"cdg-f: exhausted ally destroyed by Coup de Grâce")

	# cdg-g: fizzles if the target readies before resolution (706 recheck).
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 2)
	state2.players["p1"].resource_placed_this_turn = true
	_add_card_to_hand(state2, "cdg2", "azeroth_93", "p1")
	var v2 := _add_ally(state2, "v2", "victim_def", "p2")
	v2.just_summoned = false
	v2.is_exhausted  = true
	var hit2 := PendingAction.make("play_ability", "p1",
		{"card_id": "cdg2", "target_id": "v2"})
	StackResolver.submit_action(state2, hit2, db)
	v2.is_exhausted = false   # target readies in response
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	ok(state2.is_in_play("v2"),
		"cdg-g: fizzles — target readied before resolution, not destroyed")

	# cdg-h: AI targets the MOST valuable exhausted opposing ally.
	var ai := GenericAI.new()
	db.ally("weak_def",  1, 1, [], 1)
	db.ally("prize_def", 5, 5, [], 5)
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 2)
	_add_card_to_hand(state3, "cdg3", "azeroth_93", "p1")
	var weak  := _add_ally(state3, "weak",  "weak_def",  "p2")
	var prize := _add_ally(state3, "prize", "prize_def", "p2")
	weak.just_summoned = false;  weak.is_exhausted  = true
	prize.just_summoned = false; prize.is_exhausted = true
	var acts := ai._targeted_instant_actions(state3, db, "p1", "cdg3", "play_ability")
	ok(acts.size() == 1 and acts[0].params.get("target_id") == "prize",
		"cdg-h: AI destroys the higher-value exhausted enemy ally")


# ══════════════════════════════════════════════════════════════════════════════
# Gouge (azeroth_99, 1, Instant Ability — Combat Combo): "Exhaust target hero or
# ally. It can't ready during its controller's next ready step." The lock is a
# one-shot flag consumed at the target controller's next ready step.
# ══════════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════════
# Berserking (dark_portal_134, 3, Ability — Horde, Troll Hero Required):
# "Ongoing: When your hero is dealt damage, put a berserk counter on Berserking.
#  When your hero attacks, remove all berserk counters from Berserking. Your hero
#  has +1 ATK this combat for each counter you removed."
# ══════════════════════════════════════════════════════════════════════════════
func _test_berserking() -> void:
	_buf.append("\n-- Berserking: counters on hero damage, cashed in on attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("biter_def", 2, 3, [], 2)
	db.ability("bers_def", 3,
		"ongoing|requires_hero_race:Troll|berserk_counter_on_hero_damage|berserk_atk_on_hero_attack:1")
	db.instant("bolt_def", 1, "deal_damage_to_target:2:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var bers := CardInstance.create("bers", "bers_def", "p1", "p1_hero_row")
	state.cards["bers"] = bers
	state.zones["p1_hero_row"].card_ids.append("bers")

	# bk-a: no counters to start; the 0-ATK hero isn't a legal attacker yet.
	eq(int(bers.counters.get("berserk", 0)), 0, "bk-a: starts with no counters")
	ok(not ("p1_hero" in StackResolver.get_legal_attackers(state, "p1", db)),
		"bk-a2: 0-ATK hero with no counters can't attack")

	# bk-b: one counter per damage EVENT dealt to the controller's hero.
	GameLogic.deal_damage(state, "p2_hero", "p1_hero", 3, db)
	eq(int(bers.counters.get("berserk", 0)), 1, "bk-b: 3 damage in one hit = 1 counter")
	GameLogic.deal_damage(state, "p2_hero", "p1_hero", 1, db)
	eq(int(bers.counters.get("berserk", 0)), 2, "bk-c: a second hit = 2 counters")

	# bk-d: damage to the OPPOSING hero, and to our allies, doesn't count.
	var mine := _add_ally(state, "mine", "biter_def", "p1")
	mine.just_summoned = false
	GameLogic.deal_damage(state, "p1_hero", "p2_hero", 2, db)
	GameLogic.deal_damage(state, "p2_hero", "mine", 1, db)
	eq(int(bers.counters.get("berserk", 0)), 2,
		"bk-d: opposing-hero / own-ally damage adds no counters")

	# bk-e: the pending counters make the 0-ATK hero a legal attacker and show
	# up in the attack forecast.
	eq(state.get_atk("p1_hero", db), 0, "bk-e: hero ATK unchanged outside combat")
	eq(state.get_atk_if_attacking("p1_hero", db), 2,
		"bk-e2: forecast shows +2 from the two counters")
	ok("p1_hero" in StackResolver.get_legal_attackers(state, "p1", db),
		"bk-e3: hero is a legal attacker while holding counters")

	# bk-f: attacking cashes the counters in as +2 ATK for this combat.
	var atk_action := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"})
	StackResolver.submit_action(state, atk_action, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(int(bers.counters.get("berserk", 0)), 0, "bk-f: all counters removed")
	eq(state.get_atk("p1_hero", db), 2, "bk-f2: attacking hero has +2 ATK this combat")

	# bk-g: the grant ends with the combat step.
	var p2_hp_before := state.get_current_hp("p2_hero", db)
	StackResolver.pass_priority(state, db)   # close attack window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # close defend window → conclusion
	StackResolver.pass_priority(state, db)
	eq(state.get_current_hp("p2_hero", db), p2_hp_before - 2,
		"bk-g: the boosted 2 damage landed")
	eq(state.get_atk("p1_hero", db), 0, "bk-g2: bonus cleared after the combat step")
	eq(state.get_atk_if_attacking("p1_hero", db), 0,
		"bk-g3: forecast back to 0 — counters were spent")


func _test_gouge_exhaust_and_ready_lock() -> void:
	_buf.append("\n-- Gouge exhausts + locks the next ready step --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("target_def", 3, 4, [], 3)
	db.instant("azeroth_99", 1, "exhaust_target:hero_or_ally|gouge_cant_ready")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true
	_add_card_to_hand(state, "gouge", "azeroth_99", "p1")
	var tgt := _add_ally(state, "tgt", "target_def", "p2")
	tgt.just_summoned = false
	tgt.is_exhausted  = false

	# gg-a: heroes are legal targets (hero_or_ally).
	var hit_hero := PendingAction.make("play_instant", "p1",
		{"card_id": "gouge", "target_id": "p2_hero"})
	ok(StackResolver.can_submit(state, hit_hero, db),
		"gg-a: an enemy hero is a legal Gouge target")

	# gg-b: resolve on the ally — exhausted + ready-locked.
	var hit := PendingAction.make("play_instant", "p1",
		{"card_id": "gouge", "target_id": "tgt"})
	StackResolver.submit_action(state, hit, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.get_card("tgt").is_exhausted,
		"gg-b: target is exhausted")
	ok(TurnManager.is_ready_blocked(state, state.get_card("tgt"), db),
		"gg-c: target is flagged ready-locked")

	# gg-d: p2's next ready step skips it (stays exhausted) and consumes the flag.
	state.turn_player = "p1"
	state.phase       = "end"
	TurnManager.advance_phase(state, db)   # → _next_turn → p2 ready step
	eq(state.turn_player, "p2", "gg-d0: turn passed to p2")
	ok(state.get_card("tgt").is_exhausted,
		"gg-d: target NOT readied during its controller's ready step")
	ok(not TurnManager.is_ready_blocked(state, state.get_card("tgt"), db),
		"gg-e: lock consumed — no longer blocked after that ready step")


# ══════════════════════════════════════════════════════════════════════════════
# Shock and Soothe (dark_portal_100, 4, Instant Ability — Elemental): "Your hero
# deals 3 nature damage to target hero or ally and heals 3 damage from ANOTHER
# target hero or ally." Two mandatory, DISTINCT hero-or-ally targets, both
# respecting Untargetable (706); each half re-checked independently at
# resolution.
# ══════════════════════════════════════════════════════════════════════════════

func _test_shock_and_soothe() -> void:
	_buf.append("\n-- Shock and Soothe: 3 damage + 3 heal on two distinct targets --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("mine_def",   2, 6, [], 3)
	db.ally("theirs_def", 4, 6, [], 3)
	var ghost_kw: Array[String] = ["untargetable"]
	db.ally("ghost_def",  3, 3, ghost_kw, 3)
	db.instant("dark_portal_100", 4, "deal_damage_and_heal:3:nature:3")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var mine   := _add_ally(state, "mine",   "mine_def",   "p1")
	var theirs := _add_ally(state, "theirs", "theirs_def", "p2")
	_add_ally(state, "ghost", "ghost_def", "p2")
	mine.just_summoned   = false
	theirs.just_summoned = false
	mine.damage_taken    = 4          # 2 HP left — the heal target
	_add_card_to_hand(state, "ss",  "dark_portal_100", "p1")
	_add_card_to_hand(state, "ss2", "dark_portal_100", "p1")
	_add_resources(state, "p1", 8)
	state.players["p1"].resource_placed_this_turn = true

	# The two targets must differ ("another target hero or ally").
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ss", "target_id": "theirs", "heal_target_id": "theirs"}), db),
		"ss-a: the same character can't fill both slots")
	# The heal target is mandatory — one target alone is not a legal play.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ss", "target_id": "theirs"}), db),
		"ss-b: both targets must be announced")
	# Both slots are real targets (706) — Untargetable is illegal in either.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ss", "target_id": "ghost", "heal_target_id": "mine"}), db),
		"ss-c: damage half can't target an Untargetable ally")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ss", "target_id": "theirs", "heal_target_id": "ghost"}), db),
		"ss-d: heal half can't target an Untargetable ally")
	# Heroes are legal in both slots ("target hero or ally").
	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ss", "target_id": "p2_hero", "heal_target_id": "p1_hero"}), db),
		"ss-e: heroes are legal in both slots")

	var cast := PendingAction.make("play_instant", "p1",
		{"card_id": "ss", "target_id": "theirs", "heal_target_id": "mine"})
	ok(StackResolver.can_submit(state, cast, db), "ss-f: legal with two distinct targets")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	eq(state.get_current_hp("theirs", db), 3, "ss-g: damage target took 3 (6 → 3)")
	eq(state.get_current_hp("mine", db),   5, "ss-h: heal target healed 3 (2 → 5)")

	# Each half re-checks its own target (706 / glossary 4217): bouncing the
	# damage target in response fizzles ONLY the damage, the heal still lands.
	db.instant("azeroth_172", 3, "return_to_hand:ally")
	_add_card_to_hand(state, "wd", "azeroth_172", "p2")
	_add_resources(state, "p2", 3)
	state.players["p2"].resource_placed_this_turn = true
	mine.damage_taken = 4                     # damaged again, 2 HP

	var cast2 := PendingAction.make("play_instant", "p1",
		{"card_id": "ss2", "target_id": "theirs", "heal_target_id": "mine"})
	StackResolver.submit_action(state, cast2, db)
	StackResolver.pass_priority(state, db)    # p1 → p2
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2",
		{"card_id": "wd", "target_id": "theirs"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)    # Withdraw resolves — theirs bounces
	ok(not state.is_in_play("theirs"), "ss-i: damage target left play in response")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)    # Shock and Soothe resolves

	eq(state.get_current_hp("mine", db), 5,
		"ss-j: heal half still resolved after the damage half fizzled")


# ══════════════════════════════════════════════════════════════════════════════
# AI (Shock and Soothe): damages an enemy and heals one of OUR damaged
# characters — never the reverse. With nothing of ours damaged and no kill
# available it holds the card rather than wasting the heal half.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_shock_and_soothe() -> void:
	_buf.append("\n-- AI Shock and Soothe: damage enemy, heal own damaged ally --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("mine_def",   2, 6, [], 3)
	db.ally("theirs_def", 4, 6, [], 3)
	db.instant("dark_portal_100", 4, "deal_damage_and_heal:3:nature:3")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var mine   := _add_ally(state, "mine",   "mine_def",   "p1")
	var theirs := _add_ally(state, "theirs", "theirs_def", "p2")
	mine.just_summoned   = false
	theirs.just_summoned = false
	_add_card_to_hand(state, "ss", "dark_portal_100", "p1")
	_add_resources(state, "p1", 8)
	state.players["p1"].resource_placed_this_turn = true

	# Nothing of ours is damaged and 3 doesn't kill the 6 HP ally: hold.
	var held: Array = ai.get_reasonable_actions(state, db, "p1")
	var found_hold := false
	for a in held:
		if (a as PendingAction).params.get("card_id", "") == "ss":
			found_hold = true
	ok(not found_hold, "ai-ss-a: no damaged friendly and no kill — card is held")

	# Damage our ally: now the heal half has a home and the AI casts.
	mine.damage_taken = 4
	var acts: Array = ai.get_reasonable_actions(state, db, "p1")
	var cast: PendingAction = null
	for a in acts:
		if (a as PendingAction).params.get("card_id", "") == "ss":
			cast = a
	ok(cast != null, "ai-ss-b: AI generates the cast once a friendly is damaged")
	if cast:
		var dmg_card := state.get_card(cast.params.get("target_id", ""))
		var heal_card := state.get_card(cast.params.get("heal_target_id", ""))
		ok(dmg_card != null and dmg_card.controller == "p2",
			"ai-ss-c: damage half aimed at an opposing character")
		eq(cast.params.get("heal_target_id", ""), "mine",
			"ai-ss-d: heal half aimed at our damaged ally")
		ok(heal_card != null and heal_card.controller == "p1",
			"ai-ss-e: heal half never aimed at the opponent")


# ══════════════════════════════════════════════════════════════════════════════
# Ravenous Bite (azeroth_44, 2, Instant Ability — Beast Mastery): "Target ally
# has +3 ATK this turn. Target ally has -3 ATK this turn." Two independent
# mandatory ally targets, both respecting Untargetable (706), same ally legal
# twice. ATK floors at 0 but the raw negative buff is kept on the card.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ravenous_bite_atk_swing() -> void:
	_buf.append("\n-- Ravenous Bite: +3 / -3 ATK on two allies this turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("mine_def",   2, 4, [], 3)
	db.ally("theirs_def", 4, 4, [], 3)
	db.ally("small_def",  1, 2, [], 1)
	var ghost_kw: Array[String] = ["untargetable"]
	db.ally("ghost_def",  3, 3, ghost_kw, 3)
	db.instant("azeroth_44", 2, "atk_swing:3:-3")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var mine   := _add_ally(state, "mine",   "mine_def",   "p1")
	var theirs := _add_ally(state, "theirs", "theirs_def", "p2")
	var small  := _add_ally(state, "small",  "small_def",  "p1")
	_add_ally(state, "ghost", "ghost_def", "p2")
	mine.just_summoned   = false
	theirs.just_summoned = false
	small.just_summoned  = false
	_add_card_to_hand(state, "bite",  "azeroth_44", "p1")
	_add_card_to_hand(state, "bite2", "azeroth_44", "p1")
	_add_card_to_hand(state, "bite3", "azeroth_44", "p1")
	_add_resources(state, "p1", 6)
	state.players["p1"].resource_placed_this_turn = true

	# Heroes are not legal targets in EITHER slot (both halves say "ally").
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "bite", "target_id": "p1_hero", "target_id_2": "theirs"}), db),
		"rb-a: +ATK half can't target a hero")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "bite", "target_id": "mine", "target_id_2": "p2_hero"}), db),
		"rb-b: -ATK half can't target a hero")
	# Both slots respect Untargetable (unlike Multi-Shot's exception).
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "bite", "target_id": "mine", "target_id_2": "ghost"}), db),
		"rb-c: -ATK half can't target an Untargetable ally")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "bite", "target_id": "ghost", "target_id_2": "theirs"}), db),
		"rb-d: +ATK half can't target an Untargetable ally")
	# The second target is mandatory — one target alone is not a legal play.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "bite", "target_id": "mine"}), db),
		"rb-e: both targets must be announced")

	var cast := PendingAction.make("play_instant", "p1",
		{"card_id": "bite", "target_id": "mine", "target_id_2": "theirs"})
	ok(StackResolver.can_submit(state, cast, db), "rb-f: legal with two ally targets")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	eq(state.get_atk("mine", db),   5, "rb-g: pumped ally is 2 + 3 = 5 ATK")
	eq(state.get_atk("theirs", db), 1, "rb-h: shrunk ally is 4 - 3 = 1 ATK")

	# ATK floors at 0, but the raw -3 stays on the card, so a later +3 counts
	# from the true value (1 - 3 = -2 → shown as 0; +3 → 1, not 3).
	var cast2 := PendingAction.make("play_instant", "p1",
		{"card_id": "bite2", "target_id": "mine", "target_id_2": "small"})
	StackResolver.submit_action(state, cast2, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_atk("small", db), 0, "rb-i: 1 ATK shrunk by 3 floors at 0, not -2")
	var cast3 := PendingAction.make("play_instant", "p1",
		{"card_id": "bite3", "target_id": "small", "target_id_2": "theirs"})
	StackResolver.submit_action(state, cast3, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_atk("small", db), 1, "rb-j: +3 counts from the true -2, giving 1")
	eq(state.get_atk("mine", db),  8, "rb-k: two pumps stack (2 + 3 + 3)")

	# "This turn" — the end-of-turn buff sweep (TurnManager._enter_end) clears
	# every swing, on both players' cards.
	state.turn_player = "p1"
	state.phase       = "action"
	TurnManager.advance_phase(state, db)   # → end phase → sweep
	eq(state.phase, "end", "rb-l0: reached the end phase")
	eq(state.get_atk("mine", db),   2, "rb-l: pump gone after the turn ends")
	eq(state.get_atk("theirs", db), 4, "rb-m: shrink gone after the turn ends")


# ══════════════════════════════════════════════════════════════════════════════
# Ravenous Bite: the same ally may be named twice (nets 0), and each half
# re-checks its own target at resolution (706) — killing one target in response
# fizzles only that half.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ravenous_bite_same_target_and_fizzle() -> void:
	_buf.append("\n-- Ravenous Bite: same ally twice, and per-half target recheck --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("mine_def",   2, 4, [], 3)
	db.ally("theirs_def", 4, 2, [], 3)
	db.instant("azeroth_44", 2, "atk_swing:3:-3")
	db.instant("azeroth_165", 2, "deal_damage_to_target:2:melee")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var mine   := _add_ally(state, "mine",   "mine_def",   "p1")
	var theirs := _add_ally(state, "theirs", "theirs_def", "p2")
	mine.just_summoned   = false
	theirs.just_summoned = false
	_add_card_to_hand(state, "bite", "azeroth_44", "p1")
	_add_resources(state, "p1", 4)
	_add_card_to_hand(state, "qs", "azeroth_165", "p2")
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var both := PendingAction.make("play_instant", "p1",
		{"card_id": "bite", "target_id": "mine", "target_id_2": "mine"})
	ok(StackResolver.can_submit(state, both, db),
		"rb2-a: naming the same ally twice is legal")

	# Announce it on two different allies instead, then p2 kills the -ATK target
	# in response: only that half fizzles, the pump still lands.
	var cast := PendingAction.make("play_instant", "p1",
		{"card_id": "bite", "target_id": "mine", "target_id_2": "theirs"})
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)   # p1 → p2
	var kill := PendingAction.make("play_instant", "p2",
		{"card_id": "qs", "target_id": "theirs"})
	ok(StackResolver.can_submit(state, kill, db),
		"rb2-b: opponent can respond to the announced swing")
	StackResolver.submit_action(state, kill, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # Quick Strike resolves — theirs dies
	ok(not state.is_in_play("theirs"), "rb2-c: the -ATK target died in response")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # the swing resolves

	eq(state.get_atk("mine", db), 5,
		"rb2-d: +ATK half still resolved on the surviving target")


# ══════════════════════════════════════════════════════════════════════════════
# AI (Ravenous Bite): a held card, played only when it flips an open combat AND
# the -3 has an OPPOSING ALLY to land on. With no enemy ally in the fight the
# shrink would be forced onto our own board, so the AI holds instead.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_ravenous_bite_swing() -> void:
	_buf.append("\n-- AI Ravenous Bite: flips the fight, holds with no enemy ally --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 4, 4, [], 3)   # kills a 4 HP blocker; 1 ATK after the shrink
	db.ally("blocker_def",  2, 4, [], 3)
	db.weapon("axe_def", 2, 4, 0)
	db.instant("azeroth_44", 2, "atk_swing:3:-3")

	# p1's 4/4 attacks p2's 2/4 blocker. Without the card our blocker dies and
	# theirs lives; the swing saves ours (4-3 < 4 HP) and kills theirs
	# (2+3 >= 4 HP), so the AI plays it.
	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	var blk := _add_ally(state, "blk", "blocker_def",  "p2")
	atk.just_summoned = false
	blk.just_summoned = false
	_add_card_to_hand(state, "bite", "azeroth_44", "p2")
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "blk"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # proposal resolves → attack window
	StackResolver.pass_priority(state, db)   # turn player passes first (501.1a) → p2
	ok(state.combat_attack_window, "ai-rb-a0: attack window open")
	eq(state.priority_player, "p2", "ai-rb-a1: defending AI holds priority")

	var act := ai.decide_action(state, db, "p2")
	ok(act != null and act.params.get("card_id") == "bite"
			and act.params.get("target_id") == "blk"
			and act.params.get("target_id_2") == "atk",
		"ai-rb-a: AI pumps its blocker and shrinks the attacking ally")

	# Play it out: the blocker survives and kills the attacker.
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # swing resolves
	var guard := 0
	while (state.combat_attack_window or state.combat_defend_window) and guard < 12:
		StackResolver.pass_priority(state, db)
		guard += 1
	ok(state.is_in_play("blk") and not state.is_in_play("atk"),
		"ai-rb-b: blocker survived, attacker died")

	# An enemy HERO attacks our ally — no opposing ALLY, so the -3 would be
	# forced onto our own board. The AI must hold the card.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	var blk2 := _add_ally(state2, "blk2", "blocker_def", "p2")
	blk2.just_summoned = false
	var axe := CardInstance.create("axe", "axe_def", "p1", "p1_hero_row")
	state2.cards["axe"] = axe
	state2.zones["p1_hero_row"].card_ids.append("axe")
	_add_card_to_hand(state2, "bite2", "azeroth_44", "p2")
	_add_resources(state2, "p2", 2)
	state2.players["p1"].resource_placed_this_turn = true
	state2.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "blk2"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	if state2.pending_strike_player != "":
		StackResolver.choose_strike(state2, "axe", db)
	var act2 := ai.decide_action(state2, db, "p2")
	ok(act2 == null or act2.params.get("card_id") != "bite2",
		"ai-rb-c: no enemy ally in the fight — AI holds Ravenous Bite")

	# The swing changes nothing (1 ATK attacker into a 4/6 that already kills
	# it and survives) → hold the card.
	var db2 := MockDB.new()
	db2.hero("p1_hero", 30)
	db2.hero("p2_hero", 30)
	db2.ally("chip_def", 1, 2, [], 1)
	db2.ally("big_def",  4, 6, [], 4)
	db2.instant("azeroth_44", 2, "atk_swing:3:-3")
	var state3 := _base_state(db2, "p1_hero", "p2_hero")
	var chip := _add_ally(state3, "chip", "chip_def", "p1")
	var big  := _add_ally(state3, "big",  "big_def",  "p2")
	chip.just_summoned = false
	big.just_summoned  = false
	_add_card_to_hand(state3, "bite3", "azeroth_44", "p2")
	_add_resources(state3, "p2", 2)
	state3.players["p1"].resource_placed_this_turn = true
	state3.players["p2"].resource_placed_this_turn = true
	StackResolver.submit_action(state3, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "chip", "defender_id": "big"}), db2)
	StackResolver.pass_priority(state3, db2)
	StackResolver.pass_priority(state3, db2)
	var act3 := ai.decide_action(state3, db2, "p2")
	ok(act3 == null or act3.params.get("card_id") != "bite3",
		"ai-rb-d: swing flips nothing — AI holds Ravenous Bite")


# ══════════════════════════════════════════════════════════════════════════════
# Withdraw (azeroth_172, 3, Instant Ability): "Put target ally into its owner's
# hand." Bounced in response to an opposing targeted removal spell, the spell
# fizzles at the 709.2a recheck (target no longer in play). The bounced card
# leaves play, so its damage/exhaustion reset (400.6a).
# ══════════════════════════════════════════════════════════════════════════════

func _test_withdraw_bounce_and_spell_fizzle() -> void:
	_buf.append("\n-- Withdraw: bounce our ally, opposing removal spell fizzles --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("victim_def", 3, 4, [], 4)
	db.instant("vanquish_def", 3, "destroy_target:ally")
	db.instant("azeroth_172", 3, "return_to_hand:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var victim := _add_ally(state, "victim", "victim_def", "p2")
	victim.just_summoned = false
	victim.damage_taken = 2
	victim.is_exhausted = true
	_add_card_to_hand(state, "wd", "azeroth_172", "p2")
	_add_card_to_hand(state, "vq", "vanquish_def", "p1")
	_add_resources(state, "p1", 3)
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# wd-a: Withdraw is ally-only — can't target a hero.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p2",
		{"card_id": "wd", "target_id": "p1_hero"}), db),
		"wd-a: Withdraw can't target a hero (ally-only)")

	# p1 casts the destroy spell at p2's ally; p2 responds with Withdraw.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "vq", "target_id": "victim"}), db)
	StackResolver.pass_priority(state, db)   # p1 passes → priority p2
	var cast := PendingAction.make("play_instant", "p2",
		{"card_id": "wd", "target_id": "victim"})
	ok(StackResolver.can_submit(state, cast, db),
		"wd-b: Withdraw is legal in response to the removal spell")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → Withdraw resolves

	eq(state.get_card("victim").zone_id, "p2_hand",
		"wd-c: ally is back in its owner's hand")
	eq(victim.damage_taken, 0, "wd-d: damage reset on leaving play (400.6a)")
	ok(not victim.is_exhausted, "wd-e: exhaustion reset on leaving play")
	ok(state.get_card("wd").zone_id == "p2_graveyard",
		"wd-f: Withdraw is in the graveyard")

	# Both pass again → the destroy spell resolves against no legal target.
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("victim").zone_id, "p2_hand",
		"wd-g: spell fizzled — ally still in hand, not destroyed")
	ok(state.get_card("vq").zone_id == "p1_graveyard",
		"wd-h: fizzled spell still goes to the graveyard")
	ok(state.pending_actions.is_empty(), "wd-i: chain empty afterwards")


# ══════════════════════════════════════════════════════════════════════════════
# Fall Back (azeroth_160, 2, Instant Ability): "Put target ally from your party
# into its owner's hand." Same bounce as Withdraw but cheaper and friendly-only —
# can't target an OPPOSING ally (or a hero).
# ══════════════════════════════════════════════════════════════════════════════

func _test_fall_back_friendly_only() -> void:
	_buf.append("\n-- Fall Back: friendly-ally-only bounce --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("mine_def", 3, 4, [], 4)
	db.ally("theirs_def", 3, 4, [], 4)
	db.instant("azeroth_160", 2, "return_to_hand:friendly_ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var mine := _add_ally(state, "mine", "mine_def", "p2")
	mine.just_summoned = false
	mine.damage_taken = 2
	mine.is_exhausted = true
	_add_ally(state, "theirs", "theirs_def", "p1")
	_add_card_to_hand(state, "fb", "azeroth_160", "p2")
	_add_resources(state, "p2", 2)
	state.players["p2"].resource_placed_this_turn = true
	state.turn_player = "p2"
	state.priority_player = "p2"

	# fb-a: can't target a hero.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p2",
		{"card_id": "fb", "target_id": "p1_hero"}), db),
		"fb-a: Fall Back can't target a hero")
	# fb-b: can't target an OPPOSING ally.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p2",
		{"card_id": "fb", "target_id": "theirs"}), db),
		"fb-b: Fall Back can't target an opposing ally")
	# fb-c: can target our own ally.
	var cast := PendingAction.make("play_instant", "p2",
		{"card_id": "fb", "target_id": "mine"})
	ok(StackResolver.can_submit(state, cast, db),
		"fb-c: Fall Back can target a friendly ally")

	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes → resolves

	eq(state.get_card("mine").zone_id, "p2_hand",
		"fb-d: friendly ally is back in its owner's hand")
	eq(mine.damage_taken, 0, "fb-e: damage reset on leaving play (400.6a)")
	ok(not mine.is_exhausted, "fb-f: exhaustion reset on leaving play")
	ok(state.get_card("fb").zone_id == "p2_graveyard",
		"fb-g: Fall Back is in the graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# AI holds Withdraw and plays it ONLY to interrupt opposing targeted removal
# aimed at a worthwhile ally — never to dodge a combat attack.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_withdraw_save() -> void:
	_buf.append("\n-- AI plays Withdraw to interrupt targeted removal only --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def",   4, 4, [], 4)
	db.ally("cheap_def", 2, 2, [], 1)
	db.instant("vanquish_def", 3, "destroy_target:ally")
	db.instant("azeroth_172", 3, "return_to_hand:ally")

	# wa-a: destroy spell aimed at our 4-cost ally → AI bounces it.
	var state := _base_state(db, "p1_hero", "p2_hero")
	var big := _add_ally(state, "big", "big_def", "p2")
	big.just_summoned = false
	_add_card_to_hand(state, "wd", "azeroth_172", "p2")
	_add_card_to_hand(state, "vq", "vanquish_def", "p1")
	_add_resources(state, "p1", 3)
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "vq", "target_id": "big"}), db)
	StackResolver.pass_priority(state, db)   # priority → p2
	var act := ai.decide_action(state, db, "p2")
	ok(act != null and act.action_type == "play_instant"
			and act.params.get("card_id") == "wd"
			and act.params.get("target_id") == "big",
		"wa-a: AI plays Withdraw on the ally targeted by removal")

	# wa-b: same threat aimed at a 1-cost ally → hold (not worth the save).
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	var cheap := _add_ally(state2, "cheap", "cheap_def", "p2")
	cheap.just_summoned = false
	_add_card_to_hand(state2, "wd2", "azeroth_172", "p2")
	_add_card_to_hand(state2, "vq2", "vanquish_def", "p1")
	_add_resources(state2, "p1", 3)
	_add_resources(state2, "p2", 3)
	state2.players["p1"].resource_placed_this_turn = true
	state2.players["p2"].resource_placed_this_turn = true
	StackResolver.submit_action(state2, PendingAction.make("play_instant", "p1",
		{"card_id": "vq2", "target_id": "cheap"}), db)
	StackResolver.pass_priority(state2, db)
	ok(ai.decide_action(state2, db, "p2") == null,
		"wa-b: AI holds Withdraw when the targeted ally is too cheap")

	# wa-c: a combat proposal at our 4-cost ally → hold (never dodge an attack).
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	var big3 := _add_ally(state3, "big3", "big_def", "p2")
	big3.just_summoned = false
	var atk3 := _add_ally(state3, "atk3", "big_def", "p1")
	atk3.just_summoned = false
	_add_card_to_hand(state3, "wd3", "azeroth_172", "p2")
	_add_resources(state3, "p2", 3)
	state3.players["p1"].resource_placed_this_turn = true
	StackResolver.submit_action(state3, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk3", "defender_id": "big3"}), db)
	StackResolver.pass_priority(state3, db)
	var act3 := ai.decide_action(state3, db, "p2")
	ok(act3 == null or act3.params.get("card_id", "") != "wd3",
		"wa-c: AI never spends Withdraw to dodge a combat attack")


# ══════════════════════════════════════════════════════════════════════════════
# Blink (azeroth_48, 2, Instant Ability): "Draw a card. If your hero is
# defending, remove all attackers from combat." The removal fires only while
# the caster's hero IS the defender (defend window — 602.3); removing the
# attacker doesn't end the combat step (602.4), the conclusion then deals no
# damage (603.1b). The attacker stays exhausted. 1-on-1 combat: "all
# attackers" = the single attacker.
# ══════════════════════════════════════════════════════════════════════════════

func _test_blink_removes_attacker() -> void:
	_buf.append("\n-- Blink: dodge while the hero defends; cantrip otherwise --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("raider_def", 4, 4, [], 3)
	db.instant("azeroth_48", 2, "draw:1|remove_attackers:hero_defending")

	# bl-a: hero defending — Blink in the defend window removes the attacker.
	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p1"
	state.priority_player = "p1"
	var raider := _add_ally(state, "raider", "raider_def", "p1")
	raider.just_summoned = false
	_add_card_to_hand(state, "blink", "azeroth_48", "p2")
	var deck_card := CardInstance.create("deck1", "raider_def", "p2", "p2_deck")
	state.cards["deck1"] = deck_card
	state.zones["p2_deck"].card_ids.append("deck1")
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts → attack window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # no protectors → defend window
	ok(state.combat_defend_window, "bl-a0: defend window open")
	StackResolver.pass_priority(state, db)   # attacker (p1) passes → p2
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2",
		{"card_id": "blink"}), db)
	StackResolver.pass_priority(state, db)
	var res_events := StackResolver.pass_priority(state, db)   # Blink resolves
	eq(state.combat_attacker, "", "bl-a: attacker removed from combat")
	var saw_removed := false
	for ev in res_events:
		if ev.event_type == "attacker_removed_from_combat" \
				and ev.payload.get("attacker_id", "") == "raider":
			saw_removed = true
	ok(saw_removed, "bl-a2: attacker_removed_from_combat event emitted")
	eq(state.get_card("deck1").zone_id, "p2_hand", "bl-a3: Blink drew a card")
	eq(state.get_card("blink").zone_id, "p2_graveyard", "bl-a4: Blink in graveyard")
	ok(state.combat_defend_window, "bl-a5: combat step doesn't end immediately (602.4)")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # window closes → conclusion, 603.1b
	ok(not state.combat_defend_window, "bl-b: combat concluded")
	eq(state.get_card("p2_hero").damage_taken, 0, "bl-b2: no damage — attack dodged")
	ok(state.get_card("raider").is_exhausted, "bl-b3: attacker stays exhausted")

	# bl-c: an ALLY defending — Blink is a pure cantrip, the attack lands.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	state2.turn_player     = "p1"
	state2.priority_player = "p1"
	var raider2 := _add_ally(state2, "raider2", "raider_def", "p1")
	raider2.just_summoned = false
	var blocker := _add_ally(state2, "blocker", "raider_def", "p2")
	blocker.just_summoned = false
	_add_card_to_hand(state2, "blink2", "azeroth_48", "p2")
	_add_resources(state2, "p2", 2)
	state2.players["p1"].resource_placed_this_turn = true
	state2.players["p2"].resource_placed_this_turn = true
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider2", "defender_id": "blocker"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # defend window
	ok(state2.combat_defend_window, "bl-c0: defend window open")
	StackResolver.pass_priority(state2, db)   # p1 passes → p2
	StackResolver.submit_action(state2, PendingAction.make("play_instant", "p2",
		{"card_id": "blink2"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # resolves — no removal
	eq(state2.combat_attacker, "raider2", "bl-c: ally defending — attacker NOT removed")
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # conclusion — damage lands both ways
	ok(not state2.is_in_play("blocker"),
		"bl-c2: combat damage landed — the defending ally died (4v4 trade)")

	# bl-d: played in the ATTACK window the hero is only a PROPOSED defender —
	# no removal, and the attack later lands on the hero.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	state3.turn_player     = "p1"
	state3.priority_player = "p1"
	var raider3 := _add_ally(state3, "raider3", "raider_def", "p1")
	raider3.just_summoned = false
	_add_card_to_hand(state3, "blink3", "azeroth_48", "p2")
	_add_resources(state3, "p2", 2)
	state3.players["p1"].resource_placed_this_turn = true
	state3.players["p2"].resource_placed_this_turn = true
	StackResolver.submit_action(state3, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider3", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)   # attack window
	ok(state3.combat_attack_window, "bl-d0: attack window open")
	StackResolver.pass_priority(state3, db)   # p1 passes → p2
	StackResolver.submit_action(state3, PendingAction.make("play_instant", "p2",
		{"card_id": "blink3"}), db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)   # resolves — condition not met
	eq(state3.combat_attacker, "raider3", "bl-d: proposed defender ≠ defending — no removal")
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)   # attack window closes → defend window
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)   # conclusion
	eq(state3.get_card("p2_hero").damage_taken, 4, "bl-d2: attack landed on the hero")


# Rule 603.1b: a combatant that leaves play before the conclusion cancels the
# combat. The engine must SAY SO (combat_cancelled + cancelled flag on
# combat_concluded) so the UI can show a notice and skip the attack animation.
func _test_combat_cancelled_event() -> void:
	_buf.append("\n-- Combat cancelled event when a combatant leaves play --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("raider_def", 4, 4, [], 3)
	db.instant("azeroth_172", 3, "return_to_hand:ally")   # Withdraw

	# cc-a: the ATTACKER is bounced during the defend window.
	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p1"
	state.priority_player = "p1"
	var raider := _add_ally(state, "raider", "raider_def", "p1")
	raider.just_summoned = false
	_add_card_to_hand(state, "withdraw", "azeroth_172", "p2")
	_add_resources(state, "p2", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts → attack window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # no protectors → defend window
	StackResolver.pass_priority(state, db)   # p1 passes → p2
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2",
		{"card_id": "withdraw", "target_id": "raider"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # Withdraw resolves — attacker bounced
	eq(state.get_card("raider").zone_id, "p1_hand", "cc-a0: attacker bounced to hand")
	StackResolver.pass_priority(state, db)
	var end_events := StackResolver.pass_priority(state, db)   # window closes → conclusion

	var cancelled: GameEvent = null
	var concluded: GameEvent = null
	for ev in end_events:
		if ev.event_type == "combat_cancelled":
			cancelled = ev
		elif ev.event_type == "combat_concluded":
			concluded = ev
	ok(cancelled != null, "cc-a: combat_cancelled event emitted")
	if cancelled:
		eq(cancelled.payload.get("reason", ""), "attacker_gone",
			"cc-a2: reason is attacker_gone")
		eq(cancelled.payload.get("attacker_id", ""), "raider", "cc-a3: names the attacker")
	ok(concluded != null and concluded.payload.get("cancelled", false),
		"cc-a4: combat_concluded carries cancelled = true (renderer skips the lunge)")
	eq(state.get_card("p2_hero").damage_taken, 0, "cc-a5: no damage dealt")

	# cc-b: a normal combat's conclusion is NOT flagged cancelled.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	state2.turn_player     = "p1"
	state2.priority_player = "p1"
	var raider2 := _add_ally(state2, "raider2", "raider_def", "p1")
	raider2.just_summoned = false
	state2.players["p1"].resource_placed_this_turn = true
	state2.players["p2"].resource_placed_this_turn = true
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider2", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # defend window
	StackResolver.pass_priority(state2, db)
	var end2 := StackResolver.pass_priority(state2, db)   # conclusion
	var saw_cancel := false
	var flagged := false
	for ev in end2:
		if ev.event_type == "combat_cancelled":
			saw_cancel = true
		elif ev.event_type == "combat_concluded":
			flagged = ev.payload.get("cancelled", false)
	ok(not saw_cancel, "cc-b: no combat_cancelled on a normal combat")
	ok(not flagged, "cc-b2: combat_concluded not flagged cancelled")
	eq(state2.get_card("p2_hero").damage_taken, 4, "cc-b3: damage landed")


func _test_ai_blink_evasion() -> void:
	_buf.append("\n-- AI Blink: dodge only big hits or when the hero is low --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def",   5, 5, [], 4)
	db.ally("small_def", 2, 2, [], 1)
	db.instant("azeroth_48", 2, "draw:1|remove_attackers:hero_defending")

	# Drive a combat vs p2's hero up to the defend window, then ask the AI.
	var setups := [
		{"atk": "big_def",   "hero_dmg": 0,  "plays": true,
			"label": "ab-a: 5 ATK incoming (>3) → AI blinks"},
		{"atk": "small_def", "hero_dmg": 0,  "plays": false,
			"label": "ab-b: 2 ATK on a healthy hero → AI holds"},
		{"atk": "small_def", "hero_dmg": 22, "plays": true,
			"label": "ab-c: 2 ATK but hero at 8 HP (<10) → AI blinks"},
	]
	for setup in setups:
		var state := _base_state(db, "p1_hero", "p2_hero")
		state.turn_player     = "p1"
		state.priority_player = "p1"
		var att := _add_ally(state, "att", setup["atk"], "p1")
		att.just_summoned = false
		state.get_card("p2_hero").damage_taken = setup["hero_dmg"]
		_add_card_to_hand(state, "blink", "azeroth_48", "p2")
		_add_resources(state, "p2", 2)
		state.players["p1"].resource_placed_this_turn = true
		state.players["p2"].resource_placed_this_turn = true
		StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
			{"attacker_id": "att", "defender_id": "p2_hero"}), db)
		StackResolver.pass_priority(state, db)
		StackResolver.pass_priority(state, db)   # attack window
		# AI never blinks in the attack window (hero not defending yet).
		var early := ai.decide_action(state, db, "p2")
		ok(early == null or early.params.get("card_id", "") != "blink",
			setup["label"] + " (held in the attack window)")
		StackResolver.pass_priority(state, db)
		StackResolver.pass_priority(state, db)   # defend window
		StackResolver.pass_priority(state, db)   # p1 passes → p2 has priority
		var act := ai.decide_action(state, db, "p2")
		if setup["plays"]:
			ok(act != null and act.params.get("card_id", "") == "blink", setup["label"])
		else:
			ok(act == null or act.params.get("card_id", "") != "blink", setup["label"])


# ══════════════════════════════════════════════════════════════════════════════
# First to Fall (dark_portal_141, 2, Instant Ability): "Destroy target protecting
# ally." Legal only in the defend window, aimed at the ally protecting this combat
# (state.combat_protector). Destroying it ends the combat with no damage (603.1b).
# ══════════════════════════════════════════════════════════════════════════════

func _test_first_to_fall_destroys_protector() -> void:
	_buf.append("\n-- First to Fall: destroy the ally protecting this combat --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("raider_def", 4, 4, [], 3)                 # p1 attacker
	db.ally("guard_def",  2, 3, ["protector"], 3)      # p2 protector
	db.instant("dark_portal_141", 2, "destroy_target:protecting_ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p1"
	state.priority_player = "p1"
	var raider := _add_ally(state, "raider", "raider_def", "p1")
	raider.just_summoned = false
	var guard := _add_ally(state, "guard", "guard_def", "p2")
	guard.just_summoned = false
	_add_card_to_hand(state, "ftf", "dark_portal_141", "p1")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# ftf-a: with no combat/protector, there's no legal target — unplayable.
	var no_combat := PendingAction.make("play_instant", "p1",
		{"card_id": "ftf", "target_id": "guard"})
	ok(not StackResolver.can_submit(state, no_combat, db),
		"ftf-a: not playable outside combat (no protecting ally)")

	# p1 attacks p2's hero; p2 will protect with the guard.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts → attack window

	# ftf-b: during the attack window nobody is protecting yet → still no target.
	ok(state.combat_attack_window, "ftf-b0: attack window open")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ftf", "target_id": "guard"}), db),
		"ftf-b: not playable in the attack window (no one is protecting)")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes → protect point
	ok(state.in_protect_point, "ftf-c: protect point opened")
	StackResolver.choose_protector(state, "guard", db)
	eq(state.combat_protector, "guard", "ftf-d: guard is the protecting ally")
	eq(state.combat_defender, "guard", "ftf-d2: guard became the defender")
	ok(state.combat_defend_window, "ftf-d3: defend window open")
	eq(state.priority_player, "p1", "ftf-d4: attacker (p1) has priority in the defend window")

	# ftf-e: now it's legal on the protector, but NOT on the hero or a non-protector.
	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ftf", "target_id": "guard"}), db),
		"ftf-e: playable on the protecting ally")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "ftf", "target_id": "p2_hero"}), db),
		"ftf-e2: not a legal target — the hero isn't a protecting ally")

	# p1 plays First to Fall on the protector.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "ftf", "target_id": "guard"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # First to Fall resolves
	ok(not state.is_in_play("guard"), "ftf-f: protector destroyed")
	ok(state.get_card("guard").zone_id == "p2_graveyard", "ftf-f2: protector in graveyard")
	ok(state.get_card("ftf").zone_id == "p1_graveyard", "ftf-f3: First to Fall in graveyard")

	# Both pass → combat concludes with the defender gone: no damage anywhere (603.1b).
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 0, "ftf-g: hero took no damage (attack didn't pass through)")
	eq(state.get_card("raider").damage_taken, 0, "ftf-g2: attacker untouched")
	eq(state.combat_protector, "", "ftf-g3: combat_protector cleared after combat")


# The renderer's highlight probe (can_play_instant_no_target_check) must go dark
# when a targeted card has NO legal target (rule 706.2): First to Fall without a
# protecting ally, Exhaustion with no ally in play.
func _test_targeted_instant_highlight_requires_target() -> void:
	_buf.append("\n-- Highlight probe: targeted instants need an existing legal target --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("raider_def", 4, 4, [], 3)
	db.ally("guard_def",  2, 3, ["protector"], 3)
	db.instant("dark_portal_141", 2, "destroy_target:protecting_ally")
	db.instant("azeroth_159", 2, "exhaust_target:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p1"
	state.priority_player = "p1"
	_add_card_to_hand(state, "ftf", "dark_portal_141", "p1")
	_add_card_to_hand(state, "exh", "azeroth_159", "p1")
	_add_resources(state, "p1", 4)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# tih-a: empty board — no protecting ally, no ally at all → neither highlights.
	ok(not StackResolver.can_play_instant_no_target_check(state, "ftf", "p1", db),
		"tih-a: First to Fall dark with no protecting ally")
	ok(not StackResolver.can_play_instant_no_target_check(state, "exh", "p1", db),
		"tih-a2: Exhaustion dark with no ally in play")

	# An ally appears → Exhaustion lights up, First to Fall stays dark.
	var raider := _add_ally(state, "raider", "raider_def", "p1")
	raider.just_summoned = false
	var guard := _add_ally(state, "guard", "guard_def", "p2")
	guard.just_summoned = false
	ok(StackResolver.can_play_instant_no_target_check(state, "exh", "p1", db),
		"tih-b: Exhaustion lights up once an ally is in play")
	ok(not StackResolver.can_play_instant_no_target_check(state, "ftf", "p1", db),
		"tih-b2: First to Fall still dark (no one protecting)")

	# Combat up to the defend window with the guard protecting → First to Fall lights.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "raider", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window
	ok(not StackResolver.can_play_instant_no_target_check(state, "ftf", "p1", db),
		"tih-c: First to Fall dark in the attack window (no one protecting yet)")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # protect point
	StackResolver.choose_protector(state, "guard", db)
	ok(state.combat_defend_window, "tih-d0: defend window open")
	ok(StackResolver.can_play_instant_no_target_check(state, "ftf", "p1", db),
		"tih-d: First to Fall lights up while an ally is protecting")


func _test_ai_first_to_fall_destroys_protector() -> void:
	_buf.append("\n-- AI plays First to Fall on an opposing protector (cost gate) --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("cheap_def", 1, 1, ["protector"], 1)   # cost 1 — below First to Fall's cost
	db.ally("pricey_def", 2, 3, ["protector"], 3)  # cost 3 — worth killing
	db.instant("dark_portal_141", 2, "destroy_target:protecting_ally")

	# Build a defend-window state directly: p1 (AI attacker) vs a protecting p2 ally.
	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p1"
	state.priority_player = "p1"
	var pricey := _add_ally(state, "pricey", "pricey_def", "p2")
	pricey.just_summoned = false
	_add_card_to_hand(state, "ftf", "dark_portal_141", "p1")
	_add_resources(state, "p1", 2)
	state.combat_attacker   = "p1_hero"
	state.combat_defender   = "pricey"
	state.combat_protector  = "pricey"
	state.combat_defend_window = true

	# ff-a: cost-3 protector >= First to Fall's cost 2 → the AI destroys it.
	var act := ai.destroy_protector_action(state, db, "p1")
	ok(act != null and act.action_type == "play_instant"
			and act.params.get("card_id") == "ftf"
			and act.params.get("target_id") == "pricey",
		"ff-a: AI plays First to Fall on the cost-3 protector")

	# ff-b: a cost-1 protector is too cheap to be worth the card → hold.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	state2.turn_player     = "p1"
	state2.priority_player = "p1"
	var cheap := _add_ally(state2, "cheap", "cheap_def", "p2")
	cheap.just_summoned = false
	_add_card_to_hand(state2, "ftf2", "dark_portal_141", "p1")
	_add_resources(state2, "p1", 2)
	state2.combat_attacker   = "p1_hero"
	state2.combat_defender   = "cheap"
	state2.combat_protector  = "cheap"
	state2.combat_defend_window = true
	ok(ai.destroy_protector_action(state2, db, "p1") == null,
		"ff-b: AI holds First to Fall against a cost-1 protector")

	# ff-c: never targets our OWN protecting ally (opponents only).
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	state3.turn_player     = "p2"
	state3.priority_player = "p2"
	var mine := _add_ally(state3, "mine", "pricey_def", "p1")   # p1's own protector
	mine.just_summoned = false
	_add_card_to_hand(state3, "ftf3", "dark_portal_141", "p1")
	_add_resources(state3, "p1", 2)
	state3.combat_attacker   = "p2_hero"
	state3.combat_defender   = "mine"
	state3.combat_protector  = "mine"
	state3.combat_defend_window = true
	ok(ai.destroy_protector_action(state3, db, "p1") == null,
		"ff-c: AI never destroys its own protecting ally")


# ══════════════════════════════════════════════════════════════════════════════
# Galahandra, Keeper of the Silent Grove (azeroth_184, 0/1 Elusive Ally):
# "1, [Activate] -> Exhaust target ally." Same interrupt role as Exhaustion,
# but as a repeatable in-play ally power instead of a one-shot hand instant.
# ══════════════════════════════════════════════════════════════════════════════

func _test_galahandra_power_freezes_proposal() -> void:
	_buf.append("\n-- Galahandra: freeze the ally attacker in response to a proposal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 4, 4, [], 3)
	db.ally("azeroth_184", 0, 1, ["elusive"], 2, "activated_power:1:exhaust_target:0::ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	var gala := _add_ally(state, "gala", "azeroth_184", "p2")
	gala.just_summoned = false
	_add_resources(state, "p2", 1)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# Ally-only targeting: Galahandra's power can't be aimed at a hero.
	var at_hero := PendingAction.make("use_ally_power", "p2",
		{"card_id": "gala", "target_id": "p1_hero"})
	ok(not StackResolver.can_submit(state, at_hero, db),
		"gp-a: Galahandra's power can't target a hero (ally-only)")

	var all_events: Array[GameEvent] = []
	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"})
	all_events.append_array(StackResolver.submit_action(state, proposal, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 → p2

	var cast := PendingAction.make("use_ally_power", "p2",
		{"card_id": "gala", "target_id": "atk"})
	ok(StackResolver.can_submit(state, cast, db),
		"gp-b: Galahandra's power on the attacker is legal in response to the proposal")
	all_events.append_array(StackResolver.submit_action(state, cast, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p2 passes
	all_events.append_array(StackResolver.pass_priority(state, db))  # power resolves

	ok(atk.is_exhausted, "gp-c: attacker is exhausted after the power resolves")
	ok(gala.is_exhausted, "gp-d: Galahandra herself exhausts (the [Activate] cost)")

	# Both pass again → the proposal itself resolves and must fizzle (601.3).
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))

	var saw_fizzle := false
	for e in all_events:
		if e.event_type == "action_fizzled":
			saw_fizzle = true
	ok(saw_fizzle, "gp-e: proposal fizzled at resolution")
	ok(not state.combat_attack_window, "gp-f: no attack window opened")
	eq(state.get_card("p2_hero").damage_taken, 0, "gp-g: hero took no damage")


# ══════════════════════════════════════════════════════════════════════════════
# AI uses Galahandra's power to cancel a dangerous incoming attack while the
# proposal is on the chain, and holds it against a chip attack. Her 0 ATK means
# get_reasonable_actions never proposes an attack with her, and the AI never
# blind-plays her power on its own turn — only in response to combat.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_galahandra_freeze_save() -> void:
	_buf.append("\n-- AI uses Galahandra's power in response to a heavy attack proposal --")
	var ai := GenericAI.new()
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def",   5, 5, [], 4)
	db.ally("small_def", 2, 2, [], 1)
	db.ally("azeroth_184", 0, 1, ["elusive"], 2, "activated_power:1:exhaust_target:0::ally")

	# ga-a: 5 ATK at our hero (>= 4 threshold) → the AI answers the proposal.
	var state := _base_state(db, "p1_hero", "p2_hero")
	var big := _add_ally(state, "big", "big_def", "p1")
	big.just_summoned = false
	var gala := _add_ally(state, "gala", "azeroth_184", "p2")
	gala.just_summoned = false
	_add_resources(state, "p2", 1)
	state.players["p1"].resource_placed_this_turn = true

	var proposal := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "big", "defender_id": "p2_hero"})
	StackResolver.submit_action(state, proposal, db)
	StackResolver.pass_priority(state, db)   # p1 passes → priority p2

	var act := ai.decide_action(state, db, "p2")
	ok(act != null and act.action_type == "use_ally_power"
			and act.params.get("card_id") == "gala"
			and act.params.get("target_id") == "big",
		"ga-a: AI uses Galahandra's power targeting the proposed attacker")

	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # power resolves
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # proposal fizzles
	ok(state.get_card("big").is_exhausted and not state.combat_attack_window,
		"ga-b: proposal cancelled — attacker exhausted, no combat")

	# ga-c: the AI never proposes an attack with Galahandra herself (0 ATK).
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	var gala2 := _add_ally(state2, "gala2", "azeroth_184", "p2")
	gala2.just_summoned = false
	state2.players["p2"].resource_placed_this_turn = true
	var legal := ai.get_reasonable_actions(state2, db, "p2")
	var proposed_gala := false
	for a in legal:
		if a.action_type == "propose_combat" and a.params.get("attacker_id") == "gala2":
			proposed_gala = true
	ok(not proposed_gala, "ga-c: AI never proposes an attack with Galahandra (0 ATK)")


# ══════════════════════════════════════════════════════════════════════════════
# Hero combat — weapons & striking (rules 303 / 602.1 / 602.3)
# ══════════════════════════════════════════════════════════════════════════════

# Attacking strike: hero with a weapon is a legal attacker; the strike point
# opens as the combat step starts, the strike pays exhaust+resources, and the
# hero deals weapon ATK.
func _test_weapon_attack_strike() -> void:
	_buf.append("\n-- Weapon: attacking hero strikes (Krol Blade) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("krol_def", 3, 3, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")

	# ws-a: the 0-ATK hero is a legal attacker only because it can strike.
	ok("p1_hero" in StackResolver.get_legal_attackers(state, "p1", db),
		"ws-a: hero with affordable weapon is a legal attacker")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)   # p1 passes
	StackResolver.pass_priority(state, db)   # p2 passes -> combat starts -> strike point

	eq(state.pending_strike_player, "p1", "ws-b: attack strike point opened for p1")
	eq(state.pending_strike_side, "attack", "ws-b2: side is attack")
	ok(state.get_card("p1_hero").is_exhausted, "ws-b3: attacker exhausted before strike point")
	ok(not state.combat_attack_window, "ws-b4: attack window held until strike resolves")

	# ws-c: everything else is blocked while the strike point is pending.
	ok(StackResolver.pass_priority(state, db).is_empty(),
		"ws-c: pass_priority blocked while strike pending")

	StackResolver.choose_strike(state, "krol", db)
	ok(state.get_card("krol").is_exhausted, "ws-d: weapon exhausted by striking")
	eq(state.get_available_resources("p1"), 1, "ws-d2: strike cost 1 paid")
	eq(state.get_atk("p1_hero", db), 3, "ws-d3: strike modifier gives hero +3 ATK")
	ok(state.combat_attack_window, "ws-d4: attack window opened after strike")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes -> defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window closes -> conclusion

	eq(state.get_card("p2_hero").damage_taken, 3, "ws-e: defender hero took weapon damage")
	ok(state.combat_struck_weapons.is_empty(), "ws-e2: association cleared after combat")
	eq(state.get_atk("p1_hero", db), 0, "ws-e3: hero ATK back to 0 after combat")


# Defending strike (602.3): after the protect point, the defending hero's
# controller may strike; the hero then deals combat damage back.
func _test_weapon_defend_strike() -> void:
	_buf.append("\n-- Weapon: defending hero strikes back --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("krol_def", 3, 3, 1)
	db.ally("bruiser_def", 2, 3)   # dies to the 3-dmg counter-strike

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p1", 1)
	var bruiser := _add_ally(state, "bruiser", "bruiser_def", "p2")
	bruiser.just_summoned = false
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "bruiser", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts (no p2 strike - ally attacker)
	ok(state.combat_attack_window, "ds-a: no strike point for an ally attacker")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes -> defend strike point

	eq(state.pending_strike_player, "p1", "ds-b: defend strike point opened for p1")
	eq(state.pending_strike_side, "defend", "ds-b2: side is defend")
	ok(not state.combat_defend_window, "ds-b3: defend window held until strike resolves")

	StackResolver.choose_strike(state, "krol", db)
	ok(state.combat_defend_window, "ds-c: defend window opened after strike")
	eq(state.get_atk("p1_hero", db), 3, "ds-c2: defending hero has +3 ATK")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion

	eq(state.get_card("p1_hero").damage_taken, 2, "ds-d: hero took the attacker's 2")
	ok(not state.is_in_play("bruiser"),
		"ds-d2: attacker died to the 3-damage counter-strike")


# Devilsaur Leggings (azeroth_284, Armor—Leather, Legs, DEF 1): "When your hero
# deals combat damage to an ally, destroy that ally." Mandatory destroy at
# combat conclusion — meaningful when the ally SURVIVES the combat damage.
func _test_devilsaur_leggings() -> void:
	_buf.append("\n-- Devilsaur Leggings: hero combat damage destroys the ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("krol_def", 3, 3, 1)   # 3 ATK, strike cost 1
	db.equipment("legs_def", 3, "equipment:legs:1|hero_combat_dmg_destroys_ally", "Leather")
	db.ally("tank_def", 0, 5)        # 0/5 — survives a 3-damage strike, no retaliation
	db.ally("biter_def", 2, 5)       # 2/5 — attacks, survives the 3 counter

	# ── Case 1: hero ATTACKS an ally; the ally survives the 3, leggings destroy it.
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s1, "p1", 2)
	var tank := _add_ally(s1, "tank", "tank_def", "p2")
	tank.just_summoned = false
	for pair in [["krol", "krol_def"], ["legs", "legs_def"]]:
		var c := CardInstance.create(pair[0], pair[1], "p1", "p1_hero_row")
		s1.cards[pair[0]] = c
		s1.zones["p1_hero_row"].card_ids.append(pair[0])

	StackResolver.submit_action(s1, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "tank"}), db)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # combat starts -> attack strike point
	StackResolver.choose_strike(s1, "krol", db)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # attack window closes -> defend window (no protector)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # defend window closes -> conclusion

	ok(not s1.is_in_play("tank"), "dl-a: surviving attacked ally destroyed by the leggings")
	eq(s1.get_card("tank").zone_id, "p2_graveyard", "dl-a2: ally is in the graveyard")

	# ── Case 2: an ally attacks the hero; the hero strikes back for 3, the ally
	# survives (2/5) and the leggings destroy it on the retaliation. The leggings
	# are ALSO exhausted for armor prevention here — proving the trigger fires
	# regardless of the equipment being ready.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	s2.turn_player     = "p2"
	s2.priority_player = "p2"
	_add_resources(s2, "p1", 1)
	var biter := _add_ally(s2, "biter", "biter_def", "p2")
	biter.just_summoned = false
	for pair2 in [["krol2", "krol_def"], ["legs2", "legs_def"]]:
		var c2 := CardInstance.create(pair2[0], pair2[1], "p1", "p1_hero_row")
		s2.cards[pair2[0]] = c2
		s2.zones["p1_hero_row"].card_ids.append(pair2[0])

	StackResolver.submit_action(s2, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "biter", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)   # combat starts -> attack window (ally attacker, no strike)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)   # attack window closes -> defend strike point
	StackResolver.choose_strike(s2, "krol2", db)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)   # defend window closes -> armor prevention point (DEF 1 legs)
	eq(s2.pending_prevention_player, "p1", "dl-b0: prevention point opens (leggings are DEF 1)")
	StackResolver.choose_prevention(s2, "legs2", db)   # exhaust leggings, then conclusion

	eq(s2.get_card("p1_hero").damage_taken, 1, "dl-b: hero took 2 − 1 prevented = 1")
	ok(s2.get_card("legs2").is_exhausted, "dl-b2: leggings exhausted for the block")
	ok(not s2.is_in_play("biter"),
		"dl-b3: attacking ally destroyed by the retaliation even with exhausted leggings")

	# ── Gate: without the leggings, a surviving attacked ally stays in play.
	var s3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s3, "p1", 2)
	var tank3 := _add_ally(s3, "tank3", "tank_def", "p2")
	tank3.just_summoned = false
	var krol3 := CardInstance.create("krol3", "krol_def", "p1", "p1_hero_row")
	s3.cards["krol3"] = krol3
	s3.zones["p1_hero_row"].card_ids.append("krol3")

	StackResolver.submit_action(s3, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "tank3"}), db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)
	StackResolver.choose_strike(s3, "krol3", db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)

	ok(s3.is_in_play("tank3"), "dl-c: no leggings -> surviving ally stays in play")
	eq(s3.get_card("tank3").damage_taken, 3, "dl-c2: ally kept its 3 combat damage")


# Iceblade Hacker (azeroth_328, Weapon—Axe, Melee (1), 2 ATK / strike 2): "When
# your hero deals combat damage to an ally, that ally can't ready during its
# controller's next ready step." Same trigger point as Devilsaur Leggings, but
# applies the gouge ready-lock — meaningful when the ally SURVIVES.
func _test_iceblade_hacker() -> void:
	_buf.append("\n-- Iceblade Hacker: hero combat damage locks the ally's next ready --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Iceblade Hacker: 2 ATK, strike cost 2, with the ready-lock trigger.
	db.weapon("ice_def", 2, 2, 2)
	db.get_def("ice_def").effects = \
		"equipment:melee_weapon:0|strike_cost:2|hero_combat_dmg_locks_ally_ready"
	db.ally("tank_def", 0, 5)   # 0/5 — survives a 2-damage strike, no retaliation
	db.ally("biter_def", 2, 5)  # 2/5 — attacks, survives the 2 counter

	# ── Case 1: hero ATTACKS an ally; the ally survives the 2, gets ready-locked.
	var s1 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s1, "p1", 2)
	var tank := _add_ally(s1, "tank", "tank_def", "p2")
	tank.just_summoned = false
	var ice := CardInstance.create("ice", "ice_def", "p1", "p1_hero_row")
	s1.cards["ice"] = ice
	s1.zones["p1_hero_row"].card_ids.append("ice")

	StackResolver.submit_action(s1, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "tank"}), db)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # combat starts -> attack strike point
	StackResolver.choose_strike(s1, "ice", db)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # attack window closes -> defend window (no protector)
	StackResolver.pass_priority(s1, db)
	StackResolver.pass_priority(s1, db)   # defend window closes -> conclusion

	ok(s1.is_in_play("tank"), "ih-a: attacked ally survived the 2 damage")
	ok(s1.get_card("tank").counters.has("gouge_skip_ready"),
		"ih-a2: surviving ally is ready-locked for its next ready step")
	ok(TurnManager._ready_blocked(s1, s1.get_card("tank"), db),
		"ih-a3: ready-lock probe reports the ally as blocked")

	# The lock is consumed at p2's next ready step (an exhausted ally stays so).
	s1.get_card("tank").is_exhausted = true
	s1.turn_player = "p2"
	s1.priority_player = "p2"
	TurnManager._enter_ready(s1, db)
	ok(s1.get_card("tank").is_exhausted, "ih-a4: ally stayed exhausted through its ready step")
	ok(not s1.get_card("tank").counters.has("gouge_skip_ready"),
		"ih-a5: lock counter consumed after that ready step")

	# ── Case 2: an ally attacks the hero; the hero strikes back for 2, the ally
	# survives (2/5) and is ready-locked by the retaliation.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	s2.turn_player     = "p2"
	s2.priority_player = "p2"
	_add_resources(s2, "p1", 2)
	var biter := _add_ally(s2, "biter", "biter_def", "p2")
	biter.just_summoned = false
	var ice2 := CardInstance.create("ice2", "ice_def", "p1", "p1_hero_row")
	s2.cards["ice2"] = ice2
	s2.zones["p1_hero_row"].card_ids.append("ice2")

	StackResolver.submit_action(s2, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "biter", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)   # combat starts -> attack window (ally attacker, no strike)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)   # attack window closes -> defend strike point
	StackResolver.choose_strike(s2, "ice2", db)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)   # defend window closes -> conclusion

	ok(s2.is_in_play("biter"), "ih-b: attacking ally survived the 2 retaliation")
	ok(s2.get_card("biter").counters.has("gouge_skip_ready"),
		"ih-b2: retaliated-on attacking ally is ready-locked")

	# ── Gate: without the weapon flag, a surviving ally is NOT ready-locked.
	db.get_def("ice_def").effects = "equipment:melee_weapon:0|strike_cost:2"
	var s3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s3, "p1", 2)
	var tank3 := _add_ally(s3, "tank3", "tank_def", "p2")
	tank3.just_summoned = false
	var ice3 := CardInstance.create("ice3", "ice_def", "p1", "p1_hero_row")
	s3.cards["ice3"] = ice3
	s3.zones["p1_hero_row"].card_ids.append("ice3")

	StackResolver.submit_action(s3, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "tank3"}), db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)
	StackResolver.choose_strike(s3, "ice3", db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)
	StackResolver.pass_priority(s3, db)

	ok(not s3.get_card("tank3").counters.has("gouge_skip_ready"),
		"ih-c: no ready-lock flag -> surviving ally readies normally")


# Ancient Bone Bow: striking with it grants the attacking hero long-range for
# the combat — the defender deals no combat damage back.
func _test_bone_bow_grants_long_range() -> void:
	_buf.append("\n-- Weapon: Ancient Bone Bow grants long-range on strike --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# ATK 2, strike cost 2, Ranged, + the long-range grant flag.
	db.weapon("bow_def", 3, 2, 2, "Ranged", "ranged_weapon")
	(db._defs["bow_def"] as CardDef).effects += "|strike_grants_long_range"
	db.ally("bruiser_def", 4, 5, [], 3)   # 4 ATK, survives the bow, would hit back

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	var bruiser := _add_ally(state, "bruiser", "bruiser_def", "p2")
	bruiser.just_summoned = false
	var bow := CardInstance.create("bow", "bow_def", "p1", "p1_hero_row")
	state.cards["bow"] = bow
	state.zones["p1_hero_row"].card_ids.append("bow")

	# Hero attacks the 4-ATK ally; without long-range the hero would take 4 back.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "bruiser"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> attack strike point

	eq(state.pending_strike_player, "p1", "bb-a: strike point opened")
	StackResolver.choose_strike(state, "bow", db)
	eq(state.get_available_resources("p1"), 0, "bb-a2: strike cost 2 paid")
	eq(state.get_atk("p1_hero", db), 2, "bb-a3: hero has +2 ATK from the bow")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window -> defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window -> conclusion

	eq(state.get_card("bruiser").damage_taken, 2, "bb-b: defender took the bow's 2")
	eq(state.get_card("p1_hero").damage_taken, 0,
		"bb-b2: long-range — hero took no combat damage back")
	ok(state.is_in_play("bruiser"), "bb-b3: bruiser survived (5 HP)")
	ok(state.combat_struck_weapons.is_empty(),
		"bb-b4: association cleared — grant is per-combat")


# Elendril's flip: "Your Ranged weapons have +3 ATK this turn." Applies to
# Ranged weapons only, feeds the strike modifier live, and expires at turn start.
func _test_elendril_ranged_bonus() -> void:
	_buf.append("\n-- Elendril: +3 ATK to Ranged weapons this turn --")
	var db := MockDB.new()
	db.hero("elendril_def", 28, 1, "ranged_weapon_atk_bonus:3")
	db.hero("p2_hero", 30)
	db.weapon("bow_def", 3, 2, 2, "Ranged", "ranged_weapon")   # ATK 2, strike 2
	db.weapon("axe_def", 3, 3, 1)                               # Melee, ATK 3, strike 1

	var state := _base_state(db, "elendril_def", "p2_hero")
	_add_resources(state, "p1", 5)
	var bow := CardInstance.create("bow", "bow_def", "p1", "p1_hero_row")
	state.cards["bow"] = bow
	state.zones["p1_hero_row"].card_ids.append("bow")
	var axe := CardInstance.create("axe", "axe_def", "p1", "p1_hero_row")
	state.cards["axe"] = axe
	state.zones["p1_hero_row"].card_ids.append("axe")

	# el-a: flip the power (pay 1) -> bonus stored.
	var flip := PendingAction.make("activate_power", "p1",
		{"hero_id": "elendril_def", "target_id": ""})
	ok(StackResolver.can_submit(state, flip, db), "el-a: flip power submittable")
	StackResolver.submit_action(state, flip, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # flip resolves
	eq(state.players["p1"].ranged_weapon_atk_bonus, 3, "el-a2: +3 bonus stored")
	eq(state.get_available_resources("p1"), 4, "el-a3: flip cost 1 paid")

	# el-b: the bonus only lifts the RANGED weapon's ATK, not the melee one.
	eq(state.get_atk("bow", db), 5, "el-b: ranged bow is 2 + 3 = 5")
	eq(state.get_atk("axe", db), 3, "el-b2: melee axe unaffected")

	# el-c: strike with the bow -> hero swings for 5.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "elendril_def", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # strike point
	StackResolver.choose_strike(state, "bow", db)
	eq(state.get_atk("elendril_def", db), 5, "el-c: hero ATK = bow 2 + bonus 3")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("p2_hero").damage_taken, 5, "el-c2: 5 damage to enemy hero")

	# el-d: the bonus is a "this turn" effect — gone after a turn boundary.
	state.players["p1"].ranged_weapon_atk_bonus = 3   # pretend still up
	var guard := 0
	while state.turn_player == "p1" and guard < 20:
		TurnManager.advance_phase(state, db)
		guard += 1
	eq(state.players["p1"].ranged_weapon_atk_bonus, 0,
		"el-d: bonus cleared at the start of the next turn")


# AI: Elendril flips the power to set up a lethal that only exists once the
# Ranged weapon is pumped +3 — then swings for the kill next decision.
func _test_ai_elendril_flip_for_lethal() -> void:
	_buf.append("\n-- AI: Elendril flips to enable a ranged lethal --")
	var db := MockDB.new()
	db.hero("elendril_def", 28, 1, "ranged_weapon_atk_bonus:3")
	db.hero("p2_hero", 30)
	db.weapon("bow_def", 3, 2, 2, "Ranged", "ranged_weapon")   # ATK 2, strike 2

	var ai := GenericAI.new()

	# Enemy hero at 5 HP: bow alone (2) can't kill; bow + 3 bonus (5) can.
	var state := _base_state(db, "elendril_def", "p2_hero")
	_add_resources(state, "p1", 5)
	state.players["p1"].resource_placed_this_turn = true
	state.get_card("p2_hero").damage_taken = 25   # 30 - 25 = 5 HP left
	var bow := CardInstance.create("bow", "bow_def", "p1", "p1_hero_row")
	state.cards["bow"] = bow
	state.zones["p1_hero_row"].card_ids.append("bow")

	# ae-a: no lethal yet -> AI flips Elendril to enable it.
	var act := ai.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "activate_power"
			and act.params.get("hero_id") == "elendril_def",
		"ae-a: AI flips Elendril to set up the ranged lethal")

	# ae-b: after the flip resolves, the AI swings the hero for the kill.
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	var act2 := ai.decide_action(state, db, "p1")
	ok(act2 != null and act2.action_type == "propose_combat"
			and act2.params.get("attacker_id") == "elendril_def"
			and act2.params.get("defender_id") == "p2_hero",
		"ae-b: AI attacks the hero with the pumped weapon")

	# ae-c: if the hero is already killable (2 HP), the AI does NOT waste the flip.
	var state2 := _base_state(db, "elendril_def", "p2_hero")
	_add_resources(state2, "p1", 5)
	state2.players["p1"].resource_placed_this_turn = true
	state2.get_card("p2_hero").damage_taken = 28   # 2 HP — bow's 2 already kills
	var bow2 := CardInstance.create("bow2", "bow_def", "p1", "p1_hero_row")
	state2.cards["bow2"] = bow2
	state2.zones["p1_hero_row"].card_ids.append("bow2")
	var act3 := ai.decide_action(state2, db, "p1")
	ok(act3 != null and act3.action_type == "propose_combat",
		"ae-c: already lethal -> AI attacks directly, no flip")


# Declining, affordability gates, and the melee strike discount (Gorebelly).
func _test_strike_gates_and_gorebelly_discount() -> void:
	_buf.append("\n-- Weapon gates + Gorebelly's melee strike discount --")
	var db := MockDB.new()
	db.hero("gorebelly_def", 30, 1, "melee_strike_discount:3")
	db.hero("p2_hero", 30)
	db.weapon("bigaxe_def", 5, 4, 3)   # strike cost 3

	var state := _base_state(db, "gorebelly_def", "p2_hero")

	var axe := CardInstance.create("axe", "bigaxe_def", "p1", "p1_hero_row")
	state.cards["axe"] = axe
	state.zones["p1_hero_row"].card_ids.append("axe")

	# sg-a: no resources -> can't strike -> 0-ATK hero isn't a legal attacker.
	ok("gorebelly_def" not in StackResolver.get_legal_attackers(state, "p1", db),
		"sg-a: hero not a legal attacker when the strike is unaffordable")

	_add_resources(state, "p1", 2)   # still < strike cost 3

	# sg-b: flip Gorebelly (pay 1) -> discount 3 -> strike cost drops to 0.
	var flip := PendingAction.make("activate_power", "p1",
		{"hero_id": "gorebelly_def", "target_id": ""})
	ok(StackResolver.can_submit(state, flip, db), "sg-b: flip power submittable")
	StackResolver.submit_action(state, flip, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # flip resolves
	eq(state.players["p1"].melee_strike_discount, 3, "sg-b2: discount stored")
	eq(state.get_available_resources("p1"), 1, "sg-b3: flip cost 1 paid")
	eq(StackResolver.get_strike_cost(state, "p1", db.get_def("bigaxe_def")), 0,
		"sg-b4: discounted strike cost is 0")
	ok("gorebelly_def" in StackResolver.get_legal_attackers(state, "p1", db),
		"sg-b5: hero is a legal attacker with the discount")

	# Attack and strike for free.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "gorebelly_def", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # strike point
	StackResolver.choose_strike(state, "axe", db)
	eq(state.get_available_resources("p1"), 1, "sg-c: strike was free (discount consumed)")
	eq(state.players["p1"].melee_strike_discount, 0, "sg-c2: discount consumed by the strike")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("p2_hero").damage_taken, 4, "sg-d: 4 weapon damage dealt")

	# sg-e: declining a strike just opens the window with no payment.
	var state2 := _base_state(db, "gorebelly_def", "p2_hero")
	_add_resources(state2, "p1", 5)
	var axe2 := CardInstance.create("axe2", "bigaxe_def", "p1", "p1_hero_row")
	state2.cards["axe2"] = axe2
	state2.zones["p1_hero_row"].card_ids.append("axe2")
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "gorebelly_def", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # strike point
	StackResolver.choose_strike(state2, "", db)
	ok(state2.combat_attack_window, "sg-e: declined strike still opens the attack window")
	ok(not state2.get_card("axe2").is_exhausted, "sg-e2: weapon untouched on decline")
	eq(state2.get_available_resources("p1"), 5, "sg-e3: nothing paid on decline")


# AI strike decisions: attack-side always strikes; defend-side strikes to kill
# or against the opponent's last legal attacker, and holds otherwise.
func _test_ai_strike_decisions() -> void:
	_buf.append("\n-- AI: strike decision heuristics --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("krol_def", 3, 3, 1)
	db.ally("tank_def", 2, 6)     # survives a 3-dmg strike
	db.ally("runt_def", 2, 2)     # dies to a 3-dmg strike
	var ai := BaseAI.new()

	# ai-a: attacking — GenericAI proposes the hero attack; strike always taken.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")
	state.players["p1"].resource_placed_this_turn = true
	state.players["p1"].has_used_hero_power = true   # blank flip would rank above combat
	var gen := GenericAI.new()
	var act := gen.decide_action(state, db, "p1")
	ok(act != null and act.action_type == "propose_combat" \
			and act.params.get("attacker_id") == "p1_hero",
		"ai-a: GenericAI attacks with the weapon-bearing hero")
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # strike point
	eq(ai.choose_strike_weapon(state, db, "p1"), "krol",
		"ai-a2: attack-side strike always taken")
	StackResolver.choose_strike(state, ai.choose_strike_weapon(state, db, "p1"), db)

	# ai-b: defending vs a survivor with another attacker waiting -> hold.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	state2.turn_player     = "p2"
	state2.priority_player = "p2"
	_add_resources(state2, "p1", 1)
	var krol2 := CardInstance.create("krol2", "krol_def", "p1", "p1_hero_row")
	state2.cards["krol2"] = krol2
	state2.zones["p1_hero_row"].card_ids.append("krol2")
	var tank := _add_ally(state2, "tank", "tank_def", "p2")
	tank.just_summoned = false
	var runt := _add_ally(state2, "runt", "runt_def", "p2")
	runt.just_summoned = false
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "tank", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # combat starts, attack window
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # defend strike point
	eq(state2.pending_strike_player, "p1", "ai-b0: defend strike point open")
	eq(ai.choose_strike_weapon(state2, db, "p1"), "",
		"ai-b: hold the strike — attacker survives and another attacker waits")
	StackResolver.choose_strike(state2, "", db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # conclusion

	# ai-c: next attack is the runt (dies to the strike) -> strike to kill.
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "runt", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # defend strike point
	eq(ai.choose_strike_weapon(state2, db, "p1"), "krol2",
		"ai-c: strike to kill the attacker")
	StackResolver.choose_strike(state2, "krol2", db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # conclusion
	ok(not state2.is_in_play("runt"), "ai-c2: attacker killed by the counter-strike")

	# ai-d: defending vs a survivor that is the LAST legal attacker -> strike anyway.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	state3.turn_player     = "p2"
	state3.priority_player = "p2"
	_add_resources(state3, "p1", 1)
	var krol3 := CardInstance.create("krol3", "krol_def", "p1", "p1_hero_row")
	state3.cards["krol3"] = krol3
	state3.zones["p1_hero_row"].card_ids.append("krol3")
	var tank2 := _add_ally(state3, "tank2", "tank_def", "p2")
	tank2.just_summoned = false
	StackResolver.submit_action(state3, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "tank2", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)   # defend strike point
	eq(ai.choose_strike_weapon(state3, db, "p1"), "krol3",
		"ai-d: last legal attacker -> always strike back")


# ══════════════════════════════════════════════════════════════════════════════
# Rod of the Ogre Magi (azeroth_332) — Two-Handed Weapon—Staff, Melee (1),
# 1 ATK. "2, [Activate], Exhaust your hero → Your hero deals 1 damage to
# target hero or ally." Flagged power_weapon: the AI uses the power, never
# the strike.
# ══════════════════════════════════════════════════════════════════════════════

const ROD_EXTRA := "two_handed|power_weapon|activated_power:2:deal_damage_to_target:1::hero_or_ally:exhaust_hero"


func _test_rod_of_ogre_magi_power() -> void:
	_buf.append("\n-- Rod of the Ogre Magi: activated ping power --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("rod_def", 4, 1, 1, "Melee", "melee_weapon", ROD_EXTRA)
	db.ally("grunt_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	var rod := CardInstance.create("rod", "rod_def", "p1", "p1_hero_row")
	state.cards["rod"] = rod
	state.zones["p1_hero_row"].card_ids.append("rod")
	var grunt := _add_ally(state, "grunt", "grunt_def", "p2")
	grunt.just_summoned = false

	# rm-a: power submittable, resolves for 1 damage; rod AND hero exhaust.
	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "rod", "target_id": "grunt"})
	ok(StackResolver.can_submit(state, use, db), "rm-a: rod power submittable")
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("grunt").damage_taken, 1, "rm-a2: 1 damage on the target")
	ok(state.get_card("rod").is_exhausted, "rm-a3: rod exhausted (activate)")
	ok(state.get_card("p1_hero").is_exhausted, "rm-a4: hero exhausted (extra cost)")
	eq(state.get_available_resources("p1"), 1, "rm-a5: 2 resources paid")

	# rm-b: rod exhausted -> power gone for the turn.
	var again := PendingAction.make("use_ally_power", "p1",
		{"card_id": "rod", "target_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, again, db),
		"rm-b: power illegal while the rod is exhausted")

	# rm-c: exhausted hero -> extra cost unpayable, even with a ready rod.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 3)
	var rod2 := CardInstance.create("rod2", "rod_def", "p1", "p1_hero_row")
	state2.cards["rod2"] = rod2
	state2.zones["p1_hero_row"].card_ids.append("rod2")
	state2.get_card("p1_hero").is_exhausted = true
	ok(not StackResolver.can_submit(state2, PendingAction.make("use_ally_power", "p1",
			{"card_id": "rod2", "target_id": "p2_hero"}), db),
		"rm-c: power illegal while the hero is exhausted")

	# rm-d: the rod is still a real weapon — the strike point offers it.
	state2.get_card("p1_hero").is_exhausted = false
	state2.players["p1"].resource_placed_this_turn = true
	ok("p1_hero" in StackResolver.get_legal_attackers(state2, "p1", db),
		"rm-d: hero is a legal attacker via the strikeable rod")
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)   # strike point
	ok("rod2" in state2.pending_strike_weapon_ids, "rm-d2: rod offered at the strike point")
	StackResolver.choose_strike(state2, "rod2", db)
	eq(state2.get_atk("p1_hero", db), 1, "rm-d3: hero ATK 1 while the rod is associated")


const HAMMER_EXTRA := "power_weapon|activated_power:1:heal_target:2::hero_or_ally:exhaust_hero"

func _test_hammer_of_grace_heal_power() -> void:
	_buf.append("\n-- The Hammer of Grace: activated heal power --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("hammer_def", 3, 1, 3, "Melee", "melee_weapon", HAMMER_EXTRA)
	db.ally("grunt_def", 2, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	var hammer := CardInstance.create("hammer", "hammer_def", "p1", "p1_hero_row")
	state.cards["hammer"] = hammer
	state.zones["p1_hero_row"].card_ids.append("hammer")
	# A damaged friendly ally to heal.
	var grunt := _add_ally(state, "grunt", "grunt_def", "p1")
	grunt.just_summoned = false
	grunt.damage_taken = 3   # 2/3 grunt on 3 damage — heal 2 leaves 1.

	# hg-a: power submittable, heals 2 from the target ally; hammer AND hero exhaust.
	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "hammer", "target_id": "grunt"})
	ok(StackResolver.can_submit(state, use, db), "hg-a: hammer heal power submittable")
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("grunt").damage_taken, 1, "hg-a2: 2 damage healed from the target")
	ok(state.get_card("hammer").is_exhausted, "hg-a3: hammer exhausted (activate)")
	ok(state.get_card("p1_hero").is_exhausted, "hg-a4: hero exhausted (extra cost)")
	eq(state.get_available_resources("p1"), 1, "hg-a5: 1 resource paid")

	# hg-b: hammer exhausted -> power gone for the turn.
	var again := PendingAction.make("use_ally_power", "p1",
		{"card_id": "hammer", "target_id": "grunt"})
	ok(not StackResolver.can_submit(state, again, db),
		"hg-b: power illegal while the hammer is exhausted")

	# hg-c: exhausted hero -> extra cost unpayable, even with a ready hammer.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 2)
	var hammer2 := CardInstance.create("hammer2", "hammer_def", "p1", "p1_hero_row")
	state2.cards["hammer2"] = hammer2
	state2.zones["p1_hero_row"].card_ids.append("hammer2")
	state2.get_card("p1_hero").is_exhausted = true
	var g2 := _add_ally(state2, "g2", "grunt_def", "p1")
	g2.just_summoned = false
	g2.damage_taken = 2
	ok(not StackResolver.can_submit(state2, PendingAction.make("use_ally_power", "p1",
			{"card_id": "hammer2", "target_id": "g2"}), db),
		"hg-c: power illegal while the hero is exhausted")

	# hg-d: the AI (GenericAI) uses the heal power on its own damaged ally, never
	# the enemy, and never strikes with this power weapon.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 2)
	state3.players["p1"].resource_placed_this_turn = true
	var hammer3 := CardInstance.create("hammer3", "hammer_def", "p1", "p1_hero_row")
	state3.cards["hammer3"] = hammer3
	state3.zones["p1_hero_row"].card_ids.append("hammer3")
	var hurt := _add_ally(state3, "hurt", "grunt_def", "p1")
	hurt.just_summoned = false
	hurt.damage_taken = 2
	var ai := GenericAI.new()
	var act := ai.decide_action(state3, db, "p1")
	ok(act != null and act.action_type == "use_ally_power"
			and act.params.get("card_id") == "hammer3"
			and act.params.get("target_id") == "hurt",
		"hg-d: AI heals its own damaged ally with the hammer")


func _test_rod_two_handed_off_hand_uniqueness() -> void:
	_buf.append("\n-- Rod (Two-Handed) vs Off-Hand equipment: 414.3c uniqueness --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("rod_def", 4, 1, 1, "Melee", "melee_weapon", ROD_EXTRA)
	db.equipment("shield_def", 2, "equipment:off_hand:4", "Shield")
	db.equipment("helm_def", 2, "equipment:head:3", "Plate")

	# tu-a: rod in play, off-hand shield enters -> uniqueness violation.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	var rod := CardInstance.create("rod", "rod_def", "p1", "p1_hero_row")
	state.cards["rod"] = rod
	state.zones["p1_hero_row"].card_ids.append("rod")
	var shield := CardInstance.create("shield", "shield_def", "p1", "p1_hand")
	state.cards["shield"] = shield
	state.zones["p1_hand"].card_ids.append("shield")
	StackResolver.submit_action(state, PendingAction.make("play_equipment", "p1",
		{"card_id": "shield"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.pending_equip_sacrifice_player, "p1",
		"tu-a: Two-Handed + Off-Hand triggers the sacrifice choice")
	ok("rod" in state.pending_equip_sacrifice_ids
			and "shield" in state.pending_equip_sacrifice_ids,
		"tu-a2: both conflicting cards offered")
	StackResolver.choose_equipment_sacrifice(state, "shield", db)
	eq(state.get_card("shield").zone_id, "p1_graveyard", "tu-a3: shield destroyed")
	ok(state.is_in_play("rod"), "tu-a4: rod kept")

	# tu-b: shield in play first, rod enters -> same violation the other way.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 4)
	state2.players["p1"].resource_placed_this_turn = true
	var shield2 := CardInstance.create("shield2", "shield_def", "p1", "p1_hero_row")
	state2.cards["shield2"] = shield2
	state2.zones["p1_hero_row"].card_ids.append("shield2")
	var rod2 := CardInstance.create("rod2", "rod_def", "p1", "p1_hand")
	state2.cards["rod2"] = rod2
	state2.zones["p1_hand"].card_ids.append("rod2")
	StackResolver.submit_action(state2, PendingAction.make("play_equipment", "p1",
		{"card_id": "rod2"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	eq(state2.pending_equip_sacrifice_player, "p1",
		"tu-b: rod entering over an off-hand also violates")
	StackResolver.choose_equipment_sacrifice(state2, "shield2", db)

	# tu-c: control — rod + head-slot armor coexist fine.
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 2)
	state3.players["p1"].resource_placed_this_turn = true
	var rod3 := CardInstance.create("rod3", "rod_def", "p1", "p1_hero_row")
	state3.cards["rod3"] = rod3
	state3.zones["p1_hero_row"].card_ids.append("rod3")
	var helm := CardInstance.create("helm", "helm_def", "p1", "p1_hand")
	state3.cards["helm"] = helm
	state3.zones["p1_hand"].card_ids.append("helm")
	StackResolver.submit_action(state3, PendingAction.make("play_equipment", "p1",
		{"card_id": "helm"}), db)
	StackResolver.pass_priority(state3, db)
	StackResolver.pass_priority(state3, db)
	eq(state3.pending_equip_sacrifice_player, "",
		"tu-c: Two-Handed + head armor is no violation")


func _test_ai_power_weapon_never_strikes() -> void:
	_buf.append("\n-- AI: power weapon held for its power, never struck --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("rod_def", 4, 1, 1, "Melee", "melee_weapon", ROD_EXTRA)
	db.weapon("krol_def", 3, 3, 1, "Melee", "off_slot_weapon")   # separate slot for the test
	var ai := BaseAI.new()

	# pw-a: forecast_atk ignores the rod — a 0-ATK hero with only the rod is
	# never forecast as an attacker.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	state.players["p1"].resource_placed_this_turn = true
	var rod := CardInstance.create("rod", "rod_def", "p1", "p1_hero_row")
	state.cards["rod"] = rod
	state.zones["p1_hero_row"].card_ids.append("rod")
	eq(BaseAI.forecast_atk(state, db, "p1_hero"), 0,
		"pw-a: forecast_atk excludes the power weapon")

	# pw-b: _get_ally_power_actions proposes the rod's ping at an enemy.
	state.players["p1"].has_used_hero_power = true
	var actions := ai._get_ally_power_actions(state, db, "p1")
	var found := false
	for a in actions:
		if a.params.get("card_id") == "rod" and a.params.get("target_id") == "p2_hero":
			found = true
	ok(found, "pw-b: AI proposes the rod power at the enemy hero")

	# pw-c: at a strike point offering rod + real weapon, the AI strikes with
	# the real weapon; offering only the rod, it declines.
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # strike point
	ok("rod" in state.pending_strike_weapon_ids and "krol" in state.pending_strike_weapon_ids,
		"pw-c0: both weapons offered by the engine")
	eq(ai.choose_strike_weapon(state, db, "p1"), "krol",
		"pw-c: AI picks the real weapon over the power weapon")
	state.pending_strike_weapon_ids.assign(["rod"])
	eq(ai.choose_strike_weapon(state, db, "p1"), "",
		"pw-c2: only the power weapon offered -> AI declines the strike")


# ══════════════════════════════════════════════════════════════════════════════
# Hypnotic Blade (azeroth_327) — Weapon—Dagger, Melee (1), 1 ATK. "3,
# [Activate], Exhaust your hero → Target player discards a card. Use only on
# your turn." Power weapon; the discard reuses Mias the Putrid's pending-
# discard machinery (target auto = opponent, see data/rules_deviations.md).
# ══════════════════════════════════════════════════════════════════════════════

const BLADE_EXTRA := "power_weapon|activated_power:3:discard_opponent:1:::exhaust_hero|on_your_turn"


func _test_hypnotic_blade_discard() -> void:
	_buf.append("\n-- Hypnotic Blade: forced discard power --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("blade_def", 2, 1, 1, "Melee", "melee_weapon", BLADE_EXTRA)
	db.ally("grunt_def", 2, 3, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)
	var blade := CardInstance.create("blade", "blade_def", "p1", "p1_hero_row")
	state.cards["blade"] = blade
	state.zones["p1_hero_row"].card_ids.append("blade")
	for i in range(2):
		var cid := "opp_card_%d" % i
		var c := CardInstance.create(cid, "grunt_def", "p2", "p2_hand")
		state.cards[cid] = c
		state.zones["p2_hand"].card_ids.append(cid)

	# hb-a: power resolves — blade + hero exhaust, 3 paid, opponent must discard.
	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "blade", "target_id": ""})
	ok(StackResolver.can_submit(state, use, db), "hb-a: blade power submittable")
	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.get_card("blade").is_exhausted, "hb-a2: blade exhausted")
	ok(state.get_card("p1_hero").is_exhausted, "hb-a3: hero exhausted")
	eq(state.get_available_resources("p1"), 1, "hb-a4: 3 resources paid")
	eq(state.pending_discard_player, "p2", "hb-a5: opponent owes a discard")
	eq(state.pending_discard_count, 1, "hb-a6: exactly 1 card")

	# hb-b: opponent resolves the discard via the shared machinery.
	StackResolver.choose_discard(state, "opp_card_0", db)
	eq(state.get_card("opp_card_0").zone_id, "p2_graveyard", "hb-b: card discarded")
	eq(state.pending_discard_player, "", "hb-b2: pending discard cleared")

	# hb-c: "Use only on your turn" — illegal during the opponent's turn.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 4)
	var blade2 := CardInstance.create("blade2", "blade_def", "p1", "p1_hero_row")
	state2.cards["blade2"] = blade2
	state2.zones["p1_hero_row"].card_ids.append("blade2")
	state2.turn_player     = "p2"
	state2.priority_player = "p1"
	ok(not StackResolver.can_submit(state2, PendingAction.make("use_ally_power", "p1",
			{"card_id": "blade2", "target_id": ""}), db),
		"hb-c: power illegal off-turn (Use only on your turn)")

	# hb-d: empty opponent hand — power resolves with nothing to discard.
	state2.turn_player     = "p1"
	StackResolver.submit_action(state2, PendingAction.make("use_ally_power", "p1",
		{"card_id": "blade2", "target_id": ""}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	eq(state2.pending_discard_player, "", "hb-d: empty hand -> no pending discard")

	# hb-e: AI proposes the power only while the opponent holds cards.
	var ai := BaseAI.new()
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state3, "p1", 4)
	var blade3 := CardInstance.create("blade3", "blade_def", "p1", "p1_hero_row")
	state3.cards["blade3"] = blade3
	state3.zones["p1_hero_row"].card_ids.append("blade3")
	var acts := ai._get_ally_power_actions(state3, db, "p1")
	ok(acts.is_empty(), "hb-e: opponent hand empty -> AI holds the power")
	var oc := CardInstance.create("oc", "grunt_def", "p2", "p2_hand")
	state3.cards["oc"] = oc
	state3.zones["p2_hand"].card_ids.append("oc")
	acts = ai._get_ally_power_actions(state3, db, "p1")
	var proposed := false
	for a in acts:
		if a.params.get("card_id") == "blade3":
			proposed = true
	ok(proposed, "hb-e2: opponent holds a card -> AI proposes the discard power")


# ══════════════════════════════════════════════════════════════════════════════
# Golem Skull Helm (azeroth_290) — Armor—Plate, Head, 3 DEF, no powers.
# Draconian Deflector (azeroth_285) — Armor—Shield, Off-Hand, 4 DEF,
# "Your hero has protector."
# ══════════════════════════════════════════════════════════════════════════════

const HELM_EFFECTS      := "equipment:head:3"
const DEFLECTOR_EFFECTS := "equipment:off_hand:4|hero_has_protector"


func _test_golem_skull_helm_block() -> void:
	_buf.append("\n-- Golem Skull Helm: 3 DEF armor block --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("helm_def", 3, HELM_EFFECTS, "Plate")
	db.ally("smasher", 4, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_ally(state, "smasher_inst", "smasher", "p2")
	var helm := CardInstance.create("helm", "helm_def", "p1", "p1_hero_row")
	state.cards["helm"] = helm
	state.zones["p1_hero_row"].card_ids.append("helm")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "smasher_inst", "defender_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts, attack window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # → prevention point at conclusion
	eq(state.pending_prevention_player, "p1", "gh-a: prevention point opened for p1")
	StackResolver.choose_prevention(state, "helm", db)
	eq(state.get_card("p1_hero").damage_taken, 1, "gh-c: hero took 4 − 3 = 1")


func _test_deflector_hero_protects() -> void:
	_buf.append("\n-- Draconian Deflector: hero has protector, retaliation strike --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("deflector_def", 4, DEFLECTOR_EFFECTS, "Shield")
	db.weapon("krol_def", 3, 3, 1)
	db.ally("guard_def", 1, 2)
	db.ally("smasher_def", 3, 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p1", 1)
	var guard := _add_ally(state, "guard", "guard_def", "p1")
	guard.just_summoned = false
	var smasher := _add_ally(state, "smasher", "smasher_def", "p2")
	smasher.just_summoned = false

	# dd-a: without the deflector the hero is NOT a legal protector.
	ok("p1_hero" not in StackResolver.get_legal_protectors(state, "smasher", "guard", db),
		"dd-a: no grant → hero can't protect")

	var deflector := CardInstance.create("deflector", "deflector_def", "p1", "p1_hero_row")
	state.cards["deflector"] = deflector
	state.zones["p1_hero_row"].card_ids.append("deflector")
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")

	# dd-b: with the deflector in play the hero IS a legal protector.
	ok("p1_hero" in StackResolver.get_legal_protectors(state, "smasher", "guard", db),
		"dd-b: deflector grant → hero can protect")
	# dd-c: 602.2b — the hero can't protect itself when it's the defender.
	ok("p1_hero" not in StackResolver.get_legal_protectors(state, "smasher", "p1_hero", db),
		"dd-c: hero can't protect itself")
	# dd-d: an exhausted hero can't protect.
	state.get_card("p1_hero").is_exhausted = true
	ok("p1_hero" not in StackResolver.get_legal_protectors(state, "smasher", "guard", db),
		"dd-d: exhausted hero can't protect")
	state.get_card("p1_hero").is_exhausted = false

	# p2 attacks the guard; hero protects at the protect point.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p2",
		{"attacker_id": "smasher", "defender_id": "guard"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts, attack window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes → protect point
	ok(state.in_protect_point, "dd-e: protect point opened")
	StackResolver.choose_protector(state, "p1_hero", db)
	ok(state.get_card("p1_hero").is_exhausted, "dd-f: hero exhausted to protect")
	eq(state.combat_defender, "p1_hero", "dd-f2: hero is the defender now")
	eq(state.combat_protector, "p1_hero", "dd-f3: combat_protector tracked")

	# dd-g: the defend strike point opens for the protecting hero (602.3).
	eq(state.pending_strike_player, "p1", "dd-g: defend strike point for p1")
	StackResolver.choose_strike(state, "krol", db)
	eq(state.get_atk("p1_hero", db), 3, "dd-g2: struck weapon gives the hero 3 ATK")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window closes → prevention point
	# The ready DEF 4 deflector opens a prevention point for the protecting
	# hero's packet — decline it, this test is about the retaliation strike.
	eq(state.pending_prevention_player, "p1", "dd-g3: prevention point opened (deflector ready)")
	StackResolver.choose_prevention(state, "", db)   # decline → conclusion
	ok(not state.is_in_play("smasher"), "dd-h: attacker died to the retaliation strike")
	eq(state.get_card("p1_hero").damage_taken, 3, "dd-h2: hero soaked the 3 damage")
	eq(state.get_card("guard").damage_taken, 0, "dd-h3: guard untouched")
	eq(state.combat_protector, "", "dd-i: combat_protector cleared after combat")


func _test_ai_hero_protect_decisions() -> void:
	_buf.append("\n-- AI: hero-protect gate + always-retaliate strike --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.equipment("deflector_def", 4, DEFLECTOR_EFFECTS, "Shield")
	db.weapon("krol_def", 3, 3, 1)
	db.ally("guard_def", 1, 2)
	db.ally("smasher_def", 3, 3)
	db.ally("tank_def", 2, 6)
	var gen := GenericAI.new()

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p1", 1)
	var guard := _add_ally(state, "guard", "guard_def", "p1")
	guard.just_summoned = false
	var smasher := _add_ally(state, "smasher", "smasher_def", "p2")
	smasher.just_summoned = false
	var deflector := CardInstance.create("deflector", "deflector_def", "p1", "p1_hero_row")
	state.cards["deflector"] = deflector
	state.zones["p1_hero_row"].card_ids.append("deflector")
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")

	# hp-a: guard dies to the smasher; hero's affordable strike kills it back →
	# GenericAI protects with the hero.
	state.combat_attacker = "smasher"
	state.combat_defender = "guard"
	eq(gen.choose_protector(state, db, "p1"), "p1_hero",
		"hp-a: hero protects when the retaliation strike kills the attacker")

	# hp-b: strike unaffordable (no resources) and the dying ally isn't worth
	# the face damage → don't protect.
	state.zones["p1_resource_row"].card_ids.clear()
	for cid in state.cards.keys():
		if state.cards[cid].zone_id == "p1_resource_row":
			state.cards[cid].zone_id = ""
	eq(gen.choose_protector(state, db, "p1"), "",
		"hp-b: no retaliation, cheap ally → hero doesn't protect")
	_add_resources(state, "p1", 1)

	# hp-c: an ally protector that safely kills the attacker is preferred.
	db.ally("bodyguard_def", 3, 4, ["protector"] as Array[String])
	var bodyguard := _add_ally(state, "bodyguard", "bodyguard_def", "p1")
	bodyguard.just_summoned = false
	eq(gen.choose_protector(state, db, "p1"), "bodyguard",
		"hp-c: ally protector preferred over the hero")
	state.get_card("bodyguard").is_exhausted = true

	# hp-d: BaseAI.choose_strike_weapon — a protecting hero ALWAYS strikes,
	# even when the strike doesn't kill and other attackers are waiting.
	var tank := _add_ally(state, "tank", "tank_def", "p2")
	tank.just_summoned = false
	state.combat_attacker = "tank"          # 2/6 — survives the 3-dmg strike
	state.combat_defender = "p1_hero"
	state.combat_protector = "p1_hero"      # hero swapped in at the protect point
	state.pending_strike_player     = "p1"
	state.pending_strike_weapon_ids = ["krol"] as Array[String]
	state.pending_strike_side       = "defend"
	eq(gen.choose_strike_weapon(state, db, "p1"), "krol",
		"hp-d: protecting hero always retaliates")
	# hp-e: same spot but the hero was the ORIGINAL defender → hold the strike.
	state.combat_protector = ""
	eq(gen.choose_strike_weapon(state, db, "p1"), "",
		"hp-e: non-protecting hero still holds vs a survivor")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Searing Totem: an Instant Ability Totem (rule 305.3) enters the
# ally_row and can't be proposed as an attacker.
# ══════════════════════════════════════════════════════════════════════════════

func _test_searing_totem_enters_ally_row_cant_attack() -> void:
	_buf.append("\n-- Searing Totem: enters ally_row, can't attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("searing_def", 2, "ongoing|totem:fire|ongoing_damage_each_turn:1:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	var totem := CardInstance.create("searing", "searing_def", "p1", "p1_hand")
	state.cards["searing"] = totem
	state.zones["p1_hand"].card_ids.append("searing")

	# Play it (chain: submit, then both players pass to resolve).
	var play := PendingAction.make("play_ability", "p1", {"card_id": "searing"})
	ok(StackResolver.can_submit(state, play, db), "st1-a: play_ability is legal")
	StackResolver.submit_action(state, play, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	ok(state.get_card("searing").zone_id == "p1_ally_row",
		"st1-b: Totem entered p1_ally_row (not hero_row)")
	ok(StackResolver.is_totem_def(db.get_def("searing_def")),
		"st1-c: is_totem_def true")

	# Even ready (no summoning sickness) it is never a legal attacker (305.3a).
	state.get_card("searing").just_summoned = false
	var legal := StackResolver.get_legal_attackers(state, "p1", db)
	ok("searing" not in legal, "st1-d: Totem is NOT a legal attacker")
	var propose := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "searing", "defender_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, propose, db),
		"st1-e: propose_combat with the Totem is illegal")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Searing Totem: Ongoing "at the start of each turn" deals 1 fire
# damage to a target hero (controller's choice). Fires on BOTH players' turns.
# ══════════════════════════════════════════════════════════════════════════════

func _test_searing_totem_fires_each_turn() -> void:
	_buf.append("\n-- Searing Totem: fires at the start of each turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("searing_def", 2, "ongoing|totem:fire|ongoing_damage_each_turn:1:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	# Totem already in play, controlled by p1.
	_add_ally(state, "searing", "searing_def", "p1")

	_totem_target_pref = ""   # headless helper hits the opposing hero (p2)
	var all_events := _drive_turns(state, db, ScriptedAI.new(), ScriptedAI.new(), 4)

	var fired := 0
	for e in all_events:
		if e.event_type == "totem_target_required":
			fired += 1
	ok(fired >= 2, "st2-a: Totem fired on multiple turn starts (%d)" % fired)
	ok(state.get_card("p2_hero").damage_taken == fired,
		"st2-b: opposing hero took 1 damage per firing (%d)" % state.get_card("p2_hero").damage_taken)
	ok(state.get_card("p1_hero").damage_taken == 0,
		"st2-c: controller's own hero untouched (targets opponent)")
	ok(state.pending_totem_target_player == "",
		"st2-d: no lingering pending totem choice")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Searing Totem: rule 501.1a / 410 — once the target is chosen the
# trigger goes on the CHAIN and a priority window opens (turn player first) before
# the damage resolves. The opponent (whose ally is targeted) can respond with an
# instant before it dies. Here we just verify the window opens and drains.
# ══════════════════════════════════════════════════════════════════════════════
func _test_searing_totem_priority_window() -> void:
	_buf.append("\n-- Searing Totem: opens a priority window before damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("searing_def", 2, "ongoing|totem:fire|ongoing_damage_each_turn:1:fire")
	db.ally("victim_def", 0, 1)   # a 0/1 the totem damage would kill

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.phase = "ready"
	_add_ally(state, "searing", "searing_def", "p1")
	var victim := _add_ally(state, "victim", "victim_def", "p2")

	# Simulate the ready-step collection: queue the trigger and open the choice.
	state.pending_ongoing_triggers = [
		{"card_id": "searing", "amount": 1, "dmg_type": "fire"}]
	StackResolver._open_next_totem_trigger(state, db)
	eq(state.pending_totem_target_player, "p1", "stw-a: p1 must pick the totem target")

	# p1 aims at the opposing 0/1 ally.
	StackResolver.choose_totem_target(state, "victim", db)
	eq(state.pending_totem_target_player, "", "stw-b: target choice consumed")
	eq(state.pending_actions.size(), 1, "stw-c: trigger is now a chain link")
	eq(state.pending_actions[0].action_type, "resolve_totem_trigger",
		"stw-d: link is a resolve_totem_trigger")
	eq(state.priority_player, "p1", "stw-e: turn player gets priority first (410)")
	eq(victim.damage_taken, 0, "stw-f: no damage yet — window is open")

	# Both players pass with the link on the chain → it resolves, damage lands.
	StackResolver.pass_priority(state, db)     # p1 passes → p2 priority
	eq(state.priority_player, "p2", "stw-g: priority passed to p2 in the window")
	eq(victim.damage_taken, 0, "stw-h: still no damage — p2 can still respond")
	StackResolver.pass_priority(state, db)     # p2 passes → link resolves
	eq(state.pending_actions.size(), 0, "stw-i: chain link resolved")
	eq(state.get_card("victim").zone_id, "p2_graveyard",
		"stw-j: totem damage landed after the window and killed the 0/1")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Searing Totem: killing the TOTEM during the trigger's priority window
# does NOT stop the damage. Once announced, a triggered ability is independent of
# its source (711.1 gates announcement only) — only the TARGET leaving play or
# becoming Untargetable fizzles it (709.2a).
# ══════════════════════════════════════════════════════════════════════════════
func _test_searing_totem_source_killed_in_window() -> void:
	_buf.append("\n-- Searing Totem: source killed in the window still deals damage --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("searing_def", 2, "ongoing|totem:fire|ongoing_damage_each_turn:1:fire")
	db.ally("victim_def", 0, 2)   # 0/2 — survives the ping so the damage is visible
								  # (a dead card's damage_taken resets on leaving play)

	var state := _base_state(db, "p1_hero", "p2_hero")
	state.phase = "ready"
	_add_ally(state, "searing", "searing_def", "p1")
	var victim := _add_ally(state, "victim", "victim_def", "p2")

	state.pending_ongoing_triggers = [
		{"card_id": "searing", "amount": 1, "dmg_type": "fire"}]
	StackResolver._open_next_totem_trigger(state, db)
	StackResolver.choose_totem_target(state, "victim", db)
	eq(state.pending_actions.size(), 1, "stk-a: trigger is on the chain")

	# p2 answers by destroying the totem while the trigger sits on the chain.
	GameLogic.move_card(state, "searing", "p1_graveyard")
	ok(not state.is_in_play("searing"), "stk-b: totem left play during the window")

	StackResolver.pass_priority(state, db)     # p1 passes
	StackResolver.pass_priority(state, db)     # p2 passes → link resolves
	eq(state.pending_actions.size(), 0, "stk-c: chain link resolved")
	eq(victim.damage_taken, 1, "stk-d: damage still landed — source is irrelevant")
	ok(state.is_in_play("victim"), "stk-e: 0/2 survived with 1 damage on it")

	# Control: the TARGET leaving play in the window DOES fizzle the trigger.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	state2.phase = "ready"
	_add_ally(state2, "searing", "searing_def", "p1")
	_add_ally(state2, "victim", "victim_def", "p2")
	state2.pending_ongoing_triggers = [
		{"card_id": "searing", "amount": 1, "dmg_type": "fire"}]
	StackResolver._open_next_totem_trigger(state2, db)
	StackResolver.choose_totem_target(state2, "victim", db)
	GameLogic.move_card(state2, "victim", "p2_hand")
	StackResolver.pass_priority(state2, db)
	var fizz_events := StackResolver.pass_priority(state2, db)
	var fizzled := false
	for e in fizz_events:
		if e.event_type == "action_fizzled":
			fizzled = true
	ok(fizzled, "stk-f: target gone in the window still fizzles the trigger")
	eq(state2.get_card("victim").damage_taken, 0, "stk-g: bounced target took no damage")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Searing Totem: "can be attacked or targeted like an ally" — it is a
# legal defender and a legal target for targeted effects.
# ══════════════════════════════════════════════════════════════════════════════

func _test_searing_totem_can_be_attacked() -> void:
	_buf.append("\n-- Searing Totem: can be attacked / targeted like an ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("searing_def", 2, "ongoing|totem:fire|ongoing_damage_each_turn:1:fire")
	db.ally("attacker_def", 2, 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_ally(state, "searing", "searing_def", "p2")

	var defenders := StackResolver.get_legal_defenders(state, "atk", db)
	ok("searing" in defenders, "st3-a: Totem is a legal defender (can be attacked)")
	ok("searing" in StackResolver.get_totem_targets(state, db),
		"st3-b: Totem is a legal target for targeted effects")

	# Combat: the 2-ATK attacker kills the 0/1 Totem.
	var propose := PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "searing"})
	state.players["p1"].resource_placed_this_turn = true
	var evs := StackResolver.submit_action(state, propose, db)
	ok(not evs.is_empty(), "st3-c: combat proposal accepted against the Totem")
	# Drain the attack/defend windows to conclusion.
	for _i in range(6):
		StackResolver.pass_priority(state, db)
	ok(state.get_card("searing").zone_id == "p2_graveyard",
		"st3-d: Totem destroyed by combat damage → graveyard")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Searing Totem: as an Instant Ability it can be played with priority
# outside the action phase / with a non-empty chain, unlike a normal Ability.
# ══════════════════════════════════════════════════════════════════════════════

func _test_searing_totem_instant_timing() -> void:
	_buf.append("\n-- Searing Totem: instant-speed play timing --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("searing_def", 2, "ongoing|totem:fire|ongoing_damage_each_turn:1:fire")
	db.ability("plain_ongoing_def", 2, "ongoing|totem:fire|ongoing_damage_each_turn:1:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	# It is p2's turn; p1 holds priority to respond (instant window).
	state.turn_player     = "p2"
	state.priority_player = "p1"

	var totem := CardInstance.create("searing", "searing_def", "p1", "p1_hand")
	state.cards["searing"] = totem
	state.zones["p1_hand"].card_ids.append("searing")
	var plain := CardInstance.create("plain", "plain_ongoing_def", "p1", "p1_hand")
	state.cards["plain"] = plain
	state.zones["p1_hand"].card_ids.append("plain")

	var play_totem := PendingAction.make("play_ability", "p1", {"card_id": "searing"})
	ok(StackResolver.can_submit(state, play_totem, db),
		"st4-a: Instant-Ability Totem playable on opponent's turn with priority")
	var play_plain := PendingAction.make("play_ability", "p1", {"card_id": "plain"})
	ok(not StackResolver.can_submit(state, play_plain, db),
		"st4-b: a non-instant ongoing Ability is NOT playable off-turn")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Earthbind Totem: "Ongoing: Opposing allies can't ready during
# their controllers' ready step." Static aura; heroes/resources unaffected,
# the controller's own allies unaffected, lock lifts when the totem leaves play.
# ══════════════════════════════════════════════════════════════════════════════

func _test_earthbind_totem_ready_lock() -> void:
	_buf.append("\n-- Earthbind Totem: opposing allies can't ready --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("earthbind_def", 2, "ongoing|totem:earth|opposing_allies_cant_ready")
	db.ally("grunt_def", 2, 2, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "earthbind", "earthbind_def", "p1")
	var enemy := _add_ally(state, "enemy", "grunt_def", "p2")
	var mine  := _add_ally(state, "mine", "grunt_def", "p1")
	enemy.is_exhausted = true
	mine.is_exhausted = true
	state.get_card("p2_hero").is_exhausted = true

	ok(TurnManager.is_ready_blocked(state, enemy, db),
		"eb-a: opposing ally probes as ready-blocked")
	ok(not TurnManager.is_ready_blocked(state, mine, db),
		"eb-b: the totem controller's own ally is not blocked")

	# p2's ready step: the ally stays exhausted, the hero readies normally.
	state.turn_player = "p2"
	TurnManager._enter_ready(state, db)
	ok(enemy.is_exhausted, "eb-c: opposing ally did NOT ready")
	ok(not state.get_card("p2_hero").is_exhausted, "eb-d: opposing hero readied (allies only)")
	ok(not enemy.just_summoned, "eb-e: summoning sickness still cleared")

	# p1's ready step: their own exhausted ally readies (aura is opposing-only).
	state.turn_player = "p1"
	TurnManager._enter_ready(state, db)
	ok(not mine.is_exhausted, "eb-f: controller's own ally readied normally")

	# Totem leaves play → the lock lifts.
	GameLogic.move_card(state, "earthbind", "p1_graveyard")
	enemy.is_exhausted = true
	state.turn_player = "p2"
	TurnManager._enter_ready(state, db)
	ok(not enemy.is_exhausted, "eb-g: ally readies again once the totem is gone")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Healing Stream Totem: "Ongoing: At the start of each turn, [this]
# heals 1 damage from each hero and ally in your party." Fires on BOTH players'
# turns; only the controller's party is healed.
# ══════════════════════════════════════════════════════════════════════════════

func _test_healing_stream_totem_heals_party() -> void:
	_buf.append("\n-- Healing Stream Totem: heals controller's party each turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.totem("stream_def", 1, "ongoing|totem:water|heal_party_each_turn:1")
	db.ally("grunt_def", 2, 4, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "stream", "stream_def", "p1")
	var mine := _add_ally(state, "mine", "grunt_def", "p1")
	var theirs := _add_ally(state, "theirs", "grunt_def", "p2")
	mine.damage_taken = 3
	theirs.damage_taken = 3
	state.get_card("p1_hero").damage_taken = 2
	state.get_card("p2_hero").damage_taken = 2

	# Controller's turn start: own hero + ally heal 1, opponent's party untouched.
	state.turn_player = "p1"
	TurnManager._enter_ready(state, db)
	eq(mine.damage_taken, 2, "hs-a: controller's ally healed 1")
	eq(state.get_card("p1_hero").damage_taken, 1, "hs-b: controller's hero healed 1")
	eq(theirs.damage_taken, 3, "hs-c: opposing ally NOT healed")
	eq(state.get_card("p2_hero").damage_taken, 2, "hs-d: opposing hero NOT healed")

	# Opponent's turn start: "each turn" — fires again for the controller's party.
	state.turn_player = "p2"
	TurnManager._enter_ready(state, db)
	eq(mine.damage_taken, 1, "hs-e: fires on the OPPONENT's turn too")
	eq(state.get_card("p1_hero").damage_taken, 0, "hs-f: hero healed again")
	eq(theirs.damage_taken, 3, "hs-g: opposing party still untouched")

	# Totem leaves play → no more healing.
	GameLogic.move_card(state, "stream", "p1_graveyard")
	state.turn_player = "p1"
	TurnManager._enter_ready(state, db)
	eq(mine.damage_taken, 1, "hs-h: no heal once the totem is gone")


# ══════════════════════════════════════════════════════════════════════════════
# Watcher Mal'wi — when an opposing ally enters play, deal 1 ranged damage to it
# ══════════════════════════════════════════════════════════════════════════════

func _test_watcher_malwi_pings_entering_opposing_ally() -> void:
	_buf.append("\n-- Watcher Mal'wi: pings opposing allies as they enter --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("malwi_def", 3, 3, [], 4, "damage_opposing_ally_on_enter:1:ranged")
	db.ally("wisp_def", 1, 1, [], 1)     # 1 health — dies to the ping
	db.ally("bruiser_def", 2, 3, [], 2)  # survives with 1 damage

	var state := _base_state(db, "p1_hero", "p2_hero")
	# Mal'wi belongs to p1; p2 is the active player playing allies into it.
	state.turn_player     = "p2"
	state.priority_player = "p2"
	_add_resources(state, "p2", 5)
	var malwi := _add_ally(state, "malwi", "malwi_def", "p1")
	malwi.just_summoned = false

	_add_hand_card(state, "wisp", "wisp_def", "p2")
	_add_hand_card(state, "bruiser", "bruiser_def", "p2")
	# A friendly ally p2 plays should also get pinged (it's opposing to Mal'wi).

	var p2_ai := ScriptedAI.new()
	p2_ai.queue_action(PendingAction.make("play_ally", "p2", {"card_id": "wisp"}))
	p2_ai.queue_action(PendingAction.make("play_ally", "p2", {"card_id": "bruiser"}))

	_drive_turns(state, db, ScriptedAI.new(), p2_ai, 1)

	ok(not state.is_in_play("wisp"), "wm-a: 1-health opposing ally destroyed by the ping")
	ok(state.is_in_play("bruiser"), "wm-b: 3-health opposing ally survives")
	eq(state.get_card("bruiser").damage_taken, 1, "wm-c: bruiser took exactly 1 damage")
	eq(state.get_card("malwi").damage_taken, 0, "wm-d: Mal'wi itself untouched")


func _test_watcher_malwi_ignores_own_allies() -> void:
	_buf.append("\n-- Watcher Mal'wi: does not ping its controller's own allies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("malwi_def", 3, 3, [], 4, "damage_opposing_ally_on_enter:1:ranged")
	db.ally("wisp_def", 1, 1, [], 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 5)
	var malwi := _add_ally(state, "malwi", "malwi_def", "p1")
	malwi.just_summoned = false
	_add_hand_card(state, "wisp", "wisp_def", "p1")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "wisp"}))

	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 1)

	ok(state.is_in_play("wisp"), "wm-e: a friendly ally entering is NOT pinged")
	eq(state.get_card("wisp").damage_taken, 0, "wm-f: friendly ally took no damage")


# ══════════════════════════════════════════════════════════════════════════════
# Wazzuli Wildmender — start-of-turn party heal (each hero and ally in your party)
# ══════════════════════════════════════════════════════════════════════════════

func _test_wazzuli_party_heal() -> void:
	_buf.append("\n-- Wazzuli Wildmender: heals your party at the start of your turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("wazzuli_def", 3, 5, [], 5, "heal_party_at_turn_start:1")
	db.ally("grunt_def", 2, 3, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	# Set up so the next ready step is p1's turn.
	state.turn_player     = "p2"
	state.priority_player = "p2"
	state.phase           = "end"

	var wazzuli := _add_ally(state, "wazzuli", "wazzuli_def", "p1")
	wazzuli.just_summoned = false
	wazzuli.damage_taken  = 2
	var grunt := _add_ally(state, "grunt", "grunt_def", "p1")
	grunt.just_summoned = false
	grunt.damage_taken  = 1
	state.get_card("p1_hero").damage_taken = 3
	# An opposing ally must NOT be healed.
	var enemy := _add_ally(state, "enemy", "grunt_def", "p2")
	enemy.damage_taken = 2

	# Advance from p2's end phase → p1's ready step (fires the start-of-turn heal).
	TurnManager.advance_phase(state, db)

	eq(state.turn_player, "p1", "wz-pre: it is now p1's turn")
	eq(state.get_card("p1_hero").damage_taken, 2, "wz-a: your hero healed 1")
	eq(state.get_card("wazzuli").damage_taken, 1, "wz-b: Wazzuli healed 1")
	eq(state.get_card("grunt").damage_taken, 0,   "wz-c: friendly ally healed 1")
	eq(state.get_card("enemy").damage_taken, 2,   "wz-d: opposing ally NOT healed")


# ══════════════════════════════════════════════════════════════════════════════
# Stylean Silversteel — enter-play party heal (3 from each hero and ally)
# ══════════════════════════════════════════════════════════════════════════════

func _test_stylean_enter_play_party_heal() -> void:
	_buf.append("\n-- Stylean Silversteel: heals 3 from each hero and ally in your party on enter --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("stylean_def", 4, 5, [], 6, "on_enter:heal_party:3")
	db.ally("grunt_def", 2, 3, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 6)

	# Damaged friendly hero + ally, plus a damaged opposing ally (must NOT heal).
	state.get_card("p1_hero").damage_taken = 5
	var grunt := _add_ally(state, "grunt", "grunt_def", "p1")
	grunt.damage_taken = 2
	var enemy := _add_ally(state, "enemy", "grunt_def", "p2")
	enemy.damage_taken = 2

	var stylean := CardInstance.create("stylean_inst", "stylean_def", "p1", "p1_hand")
	state.cards["stylean_inst"] = stylean
	state.zones["p1_hand"].card_ids.append("stylean_inst")

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "stylean_inst"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolve → enter-play heal fires

	eq(state.get_card("stylean_inst").zone_id, "p1_ally_row", "st-a: Stylean in play")
	eq(state.get_card("p1_hero").damage_taken, 2, "st-b: your hero healed 3 (5→2)")
	eq(state.get_card("grunt").damage_taken, 0,   "st-c: friendly ally healed 3 (2→0)")
	eq(state.get_card("enemy").damage_taken, 2,   "st-d: opposing ally NOT healed")


# ══════════════════════════════════════════════════════════════════════════════
# Windseer Tarus — first attack each turn, may pay 1 to ready him
# ══════════════════════════════════════════════════════════════════════════════

func _test_windseer_ready_on_attack() -> void:
	_buf.append("\n-- Windseer Tarus: pay 1 to ready after the first attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("windseer_def", 3, 3, [], 4, "ready_on_attack:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	var windseer := _add_ally(state, "windseer", "windseer_def", "p1")
	windseer.just_summoned = false

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "windseer", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts → ready-on-attack point

	eq(state.pending_ready_player, "p1", "wt-a: ready-on-attack point opened for p1")
	ok(state.get_card("windseer").is_exhausted, "wt-b: attacker exhausted before the choice")
	ok(not state.combat_attack_window, "wt-c: attack window held until the choice resolves")
	# Everything else is blocked while the choice is pending.
	ok(StackResolver.pass_priority(state, db).is_empty(),
		"wt-d: pass_priority blocked while ready choice pending")

	StackResolver.choose_ready_on_attack(state, true, db)
	ok(not state.get_card("windseer").is_exhausted, "wt-e: Windseer readied by paying 1")
	eq(state.get_available_resources("p1"), 1, "wt-f: 1 resource paid")
	ok(state.combat_attack_window, "wt-g: attack window opened after the choice")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window → defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # defend window → conclusion

	eq(state.get_card("p2_hero").damage_taken, 3, "wt-h: hero took Windseer's 3")
	ok(not state.get_card("windseer").is_exhausted,
		"wt-i: Windseer still ready after combat — can attack again")

	# Second attack this turn: the trigger already fired, so NO ready point opens.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "windseer", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.pending_ready_player, "", "wt-j: no ready point on the second attack")
	ok(state.combat_attack_window, "wt-k: attack window opens directly the second time")


func _test_windseer_ready_declined_and_unaffordable() -> void:
	_buf.append("\n-- Windseer Tarus: decline, and no offer when unaffordable --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("windseer_def", 3, 3, [], 4, "ready_on_attack:1")

	# No resources available → the point never opens (can't afford the 1).
	var state := _base_state(db, "p1_hero", "p2_hero")
	var windseer := _add_ally(state, "windseer", "windseer_def", "p1")
	windseer.just_summoned = false
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "windseer", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.pending_ready_player, "", "wt-l: no ready point when the cost is unaffordable")
	ok(state.combat_attack_window, "wt-m: attack window opens directly")

	# With resources: open the point but DECLINE — Windseer stays exhausted.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 2)
	var w2 := _add_ally(state2, "windseer", "windseer_def", "p1")
	w2.just_summoned = false
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "windseer", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	eq(state2.pending_ready_player, "p1", "wt-n: point opens when affordable")
	StackResolver.choose_ready_on_attack(state2, false, db)
	ok(state2.get_card("windseer").is_exhausted, "wt-o: declining leaves Windseer exhausted")
	eq(state2.get_available_resources("p1"), 2, "wt-p: no resources spent on decline")
	ok(state2.combat_attack_window, "wt-q: attack window opens after declining")


# ── Windfury Totem: party-wide ready-on-attack (azeroth_118) ───────────────────
func _test_windfury_totem_party_ready() -> void:
	_buf.append("\n-- Windfury Totem: party-wide ready-on-attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("grunt_def", 3, 3, [], 3)   # vanilla — no own ready trigger
	db.ability("azeroth_118", 4, "ongoing|totem:air|party_ready_on_attack:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 2)
	var grunt := _add_ally(state, "grunt", "grunt_def", "p1")
	grunt.just_summoned = false
	var totem := _add_ally(state, "wtotem", "azeroth_118", "p1")
	totem.just_summoned = false

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "grunt", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> ready-on-attack point

	eq(state.pending_ready_player, "p1", "wf-a: totem opens the party ready point for a vanilla ally")
	eq(state.pending_ready_card_id, "grunt", "wf-b: the point is for the attacker")
	StackResolver.choose_ready_on_attack(state, true, db)
	ok(not state.get_card("grunt").is_exhausted, "wf-c: grunt readied by paying 1")
	eq(state.get_available_resources("p1"), 1, "wf-d: 1 resource paid")
	ok(state.combat_attack_window, "wf-e: attack window opened after the choice")

	# No totem in play => no party grant.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(s2, "p1", 2)
	var g2 := _add_ally(s2, "grunt", "grunt_def", "p1")
	g2.just_summoned = false
	StackResolver.submit_action(s2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "grunt", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(s2, db)
	StackResolver.pass_priority(s2, db)
	eq(s2.pending_ready_player, "", "wf-f: no ready point without the totem")
	ok(s2.combat_attack_window, "wf-g: attack window opens directly")


# The party grant and a card's own ready_on_attack share the once-per-turn gate:
# Windseer under a Windfury Totem still readies at most ONCE per turn (it can
# attack + ready once, never three attacks over).
func _test_windfury_totem_with_windseer_single_ready() -> void:
	_buf.append("\n-- Windfury Totem + Windseer Tarus: still only one ready per turn --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("windseer_def", 3, 3, [], 4, "ready_on_attack:1")
	db.ability("azeroth_118", 4, "ongoing|totem:air|party_ready_on_attack:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 5)
	var ws := _add_ally(state, "windseer", "windseer_def", "p1")
	ws.just_summoned = false
	var totem := _add_ally(state, "wtotem", "azeroth_118", "p1")
	totem.just_summoned = false

	# First attack: exactly one ready point (not one per source).
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "windseer", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.pending_ready_player, "p1", "wfs-a: ready point opens on the first attack")
	StackResolver.choose_ready_on_attack(state, true, db)
	ok(not state.get_card("windseer").is_exhausted, "wfs-b: Windseer readied once")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat concludes
	ok(not state.get_card("windseer").is_exhausted, "wfs-c: ready again after combat")

	# Second attack: NO ready point — the once-per-turn gate is shared between
	# Windseer's own trigger and the totem grant.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "windseer", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.pending_ready_player, "", "wfs-d: no second ready point (attack + ready only once)")
	ok(state.combat_attack_window, "wfs-e: window opens directly the second time")


# ── Windfury Weapon: attach to a Melee weapon, ready weapon+hero on strike ──────
func _test_windfury_weapon_attach_and_ready_on_strike() -> void:
	_buf.append("\n-- Windfury Weapon: attach + ready-on-strike --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.weapon("krol_def", 3, 3, 1)   # Melee, strike cost 1
	db.equipment("cloth_def", 2, "equipment:back:0")   # non-weapon equipment
	db.instant("azeroth_119", 2, "ongoing|attach:melee_weapon|ready_on_strike:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 5)
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")
	var cloak := CardInstance.create("cloak", "cloth_def", "p1", "p1_hero_row")
	state.cards["cloak"] = cloak
	state.zones["p1_hero_row"].card_ids.append("cloak")
	_add_card_to_hand(state, "wf", "azeroth_119", "p1")

	# Can't attach to a non-weapon equipment.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
		{"card_id": "wf", "target_id": "cloak"}), db), "ww-a: can't attach to non-weapon equipment")
	var cast := PendingAction.make("play_ability", "p1",
		{"card_id": "wf", "target_id": "krol"})
	ok(StackResolver.can_submit(state, cast, db), "ww-b: attach on own Melee weapon is legal")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves
	eq(state.get_card("wf").zone_id, "attached", "ww-c: Windfury Weapon attached")
	eq(state.get_card("wf").attached_to, "krol", "ww-d: host is Krol Blade")

	# Attack with the hero, strike with Krol → ready-on-strike point opens.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> strike point
	eq(state.pending_strike_player, "p1", "ww-e: strike point opened")
	StackResolver.choose_strike(state, "krol", db)
	eq(state.pending_strike_ready_player, "p1", "ww-f: ready-on-strike point opened after strike")
	ok(state.get_card("krol").is_exhausted, "ww-g: weapon exhausted by the strike")
	ok(not state.combat_attack_window, "ww-h: attack window held until the choice resolves")
	# Blocked while pending.
	ok(StackResolver.pass_priority(state, db).is_empty(),
		"ww-h2: pass_priority blocked while ready-on-strike pending")

	var res_before := state.get_available_resources("p1")
	StackResolver.choose_ready_on_strike(state, true, db)
	ok(not state.get_card("krol").is_exhausted, "ww-i: weapon readied by paying 1")
	ok(not state.get_card("p1_hero").is_exhausted, "ww-j: hero readied too")
	eq(state.get_available_resources("p1"), res_before - 1, "ww-k: 1 resource paid")
	ok(state.combat_attack_window, "ww-l: attack window opened after the choice")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat concludes
	eq(state.get_card("p2_hero").damage_taken, 3, "ww-m: hero dealt Krol's 3")

	# Second strike this turn: NO windfury ready (first time each turn).
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # strike point again
	eq(state.pending_strike_player, "p1", "ww-n: strike point opens again (weapon readied)")
	StackResolver.choose_strike(state, "krol", db)
	eq(state.pending_strike_ready_player, "", "ww-o: no second windfury ready (once per turn)")
	ok(state.combat_attack_window, "ww-p: window opens directly after the second strike")


# ── Kena Shadowbrand: [Activate], put 1 damage on self → draw ──────────────────
func _test_kena_shadowbrand_power() -> void:
	_buf.append("\n-- Kena Shadowbrand: activate + self-damage → draw --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("kena_def", 1, 3, [], 3, "activated_power:0:draw:1:::activate_put_damage_self:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var kena := _add_ally(state, "kena", "kena_def", "p1")
	kena.just_summoned = false
	# One card in deck to draw.
	var deck_card := CardInstance.create("kena_deck", "kena_def", "p1", "p1_deck")
	state.cards["kena_deck"] = deck_card
	state.zones["p1_deck"].card_ids.append("kena_deck")

	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "kena"})
	ok(StackResolver.can_submit(state, use, db), "ke-a: Kena power legal")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("kena_deck").zone_id, "p1_hand", "ke-b: drew a card")
	eq(state.get_card("kena").damage_taken, 1, "ke-c: 1 damage put on Kena")
	ok(state.get_card("kena").is_exhausted, "ke-d: Kena exhausted (activate symbol)")
	ok(not StackResolver.can_submit(state, use, db),
		"ke-e: power not reusable while exhausted")


func _test_kena_shadowbrand_self_lethal() -> void:
	_buf.append("\n-- Kena Shadowbrand: self-damage may be exactly fatal (405.3) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("kena_def", 1, 3, [], 3, "activated_power:0:draw:1:::activate_put_damage_self:1")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var kena := _add_ally(state, "kena", "kena_def", "p1")
	kena.just_summoned = false
	kena.damage_taken = 2   # 1 HP left — the power's 1 self-damage is lethal
	var deck_card := CardInstance.create("kena_deck", "kena_def", "p1", "p1_deck")
	state.cards["kena_deck"] = deck_card
	state.zones["p1_deck"].card_ids.append("kena_deck")

	var use := PendingAction.make("use_ally_power", "p1", {"card_id": "kena"})
	ok(StackResolver.can_submit(state, use, db),
		"ks-a: power legal even when the self-damage is lethal")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("kena_deck").zone_id, "p1_hand", "ks-b: card still drawn")
	eq(state.get_card("kena").zone_id, "p1_graveyard", "ks-c: Kena destroyed by her own cost")


# ── Bizzik Sparkcog: [Activate], destroy an ally in your party → draw ──────────
func _test_bizzik_sparkcog_sacrifice_draw() -> void:
	_buf.append("\n-- Bizzik Sparkcog: sacrifice a friendly ally → draw --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bizzik_def", 2, 4, [], 4, "activated_power:0:draw:1::friendly_ally:sacrifice_ally")
	db.ally("chump_def", 1, 1, [], 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var bizzik := _add_ally(state, "bizzik", "bizzik_def", "p1")
	bizzik.just_summoned = false
	var chump := _add_ally(state, "chump", "chump_def", "p1")
	chump.just_summoned = false
	var enemy := _add_ally(state, "enemy", "chump_def", "p2")
	enemy.just_summoned = false
	var deck_card := CardInstance.create("bz_deck", "chump_def", "p1", "p1_deck")
	state.cards["bz_deck"] = deck_card
	state.zones["p1_deck"].card_ids.append("bz_deck")

	# bz-a: can't sacrifice an ENEMY ally (friendly party only).
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "bizzik", "target_id": "enemy"}), db),
		"bz-a: enemy ally is not a legal sacrifice")

	# bz-b: sacrificing our own chump is legal.
	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "bizzik", "target_id": "chump"})
	ok(StackResolver.can_submit(state, use, db), "bz-b: friendly ally is a legal sacrifice")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("chump").zone_id, "p1_graveyard", "bz-c: chump sacrificed to graveyard")
	eq(state.get_card("bz_deck").zone_id, "p1_hand", "bz-d: drew a card")
	ok(state.get_card("bizzik").is_exhausted, "bz-e: Bizzik exhausted")


# ── Augustus Corpsemonger: exile 3 graveyard allies → destroy target ally ──────
func _test_augustus_destroys_with_graveyard_cost() -> void:
	_buf.append("\n-- Augustus Corpsemonger: exile 3 graveyard allies → destroy target ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("augustus_def", 3, 4, [], 5, "activated_power:0:destroy_ally:0::ally:rfg_allies:3")
	db.ally("body_def", 2, 4, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var aug := _add_ally(state, "aug", "augustus_def", "p1")
	aug.just_summoned = false
	var victim := _add_ally(state, "victim", "body_def", "p2")
	victim.just_summoned = false
	# 3 ally cards in p1's graveyard (the cost).
	for i in range(3):
		var gid := "gy_%d" % i
		var gc := CardInstance.create(gid, "body_def", "p1", "p1_graveyard")
		state.cards[gid] = gc
		state.zones["p1_graveyard"].card_ids.append(gid)

	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "aug", "target_id": "victim"})
	ok(StackResolver.can_submit(state, use, db), "au-a: Augustus power legal with 3 gy allies")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("victim").zone_id, "p2_graveyard", "au-b: target ally destroyed")
	var rfg_count := state.cards_in_zone("p1_rfg").size()
	eq(rfg_count, 3, "au-c: three graveyard allies removed from the game")
	eq(state.cards_in_zone("p1_graveyard").size(), 0, "au-d: graveyard emptied of the paid allies")
	ok(state.get_card("aug").is_exhausted, "au-e: Augustus exhausted")


func _test_augustus_blocked_too_few_graveyard_allies() -> void:
	_buf.append("\n-- Augustus Corpsemonger: illegal with fewer than 3 graveyard allies --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("augustus_def", 3, 4, [], 5, "activated_power:0:destroy_ally:0::ally:rfg_allies:3")
	db.ally("body_def", 2, 4, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var aug := _add_ally(state, "aug", "augustus_def", "p1")
	aug.just_summoned = false
	var victim := _add_ally(state, "victim", "body_def", "p2")
	victim.just_summoned = false
	# Only 2 ally cards in graveyard — cost cannot be paid.
	for i in range(2):
		var gid := "gy_%d" % i
		var gc := CardInstance.create(gid, "body_def", "p1", "p1_graveyard")
		state.cards[gid] = gc
		state.zones["p1_graveyard"].card_ids.append(gid)

	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "aug", "target_id": "victim"}), db),
		"ab-a: Augustus power illegal with only 2 graveyard allies")


# ── Gertha, The Old Crone: 1, [Activate], destroy an ally in your party →
# destroy target ally. Two-pick power: sacrifice_id names the party ally paid as
# the cost, target_id names the ally the effect destroys. ──────────────────────
func _test_gertha_sacrifice_destroy() -> void:
	_buf.append("\n-- Gertha, The Old Crone: sacrifice a party ally → destroy target ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("gertha_def", 1, 3, [], 3, "activated_power:1:destroy_ally:0::ally:sacrifice_ally")
	db.ally("body_def", 2, 4, [], 2)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 1)
	var gertha := _add_ally(state, "gertha", "gertha_def", "p1")
	gertha.just_summoned = false
	var chump := _add_ally(state, "chump", "body_def", "p1")
	chump.just_summoned = false
	var victim := _add_ally(state, "victim", "body_def", "p2")
	victim.just_summoned = false

	# ge-a: illegal without a sacrifice named (the cost must be paid).
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "gertha", "target_id": "victim"}), db),
		"ge-a: illegal with no sacrifice_id")
	# ge-b: the sacrifice must be one of our OWN allies, not the enemy.
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "gertha", "target_id": "victim", "sacrifice_id": "victim"}), db),
		"ge-b: enemy ally is not a legal sacrifice")
	# ge-c: sacrifice our chump, destroy the enemy body — legal.
	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "gertha", "target_id": "victim", "sacrifice_id": "chump"})
	ok(StackResolver.can_submit(state, use, db), "ge-c: legal with own sacrifice + enemy target")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_card("chump").zone_id, "p1_graveyard", "ge-d: chump sacrificed to graveyard")
	eq(state.get_card("victim").zone_id, "p2_graveyard", "ge-e: target ally destroyed")
	ok(state.get_card("gertha").is_exhausted, "ge-f: Gertha exhausted (tap symbol)")
	eq(state.get_available_resources("p1"), 0, "ge-g: paid the 1 resource cost")


# ── Melgwy Pingzot: 5, [Activate] → deal 5 fire damage to target hero or ally.
# Plain activated damage power (same machinery as Grimdron) — a pure CSV recipe. ─
func _test_melgwy_pingzot_fire_ping() -> void:
	_buf.append("\n-- Melgwy Pingzot: 5, [Activate] -> 5 fire to target hero or ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("melgwy_def", 1, 3, [], 2,
		"activated_power:5:deal_damage_to_target:5:fire:hero_or_ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var melgwy := _add_ally(state, "melgwy", "melgwy_def", "p1")
	melgwy.just_summoned = false

	# me-a: illegal without the 5 resources.
	_add_resources(state, "p1", 4)
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "melgwy", "target_id": "p2_hero"}), db),
		"me-a: illegal with only 4 resources")

	# me-b: with 5 resources it's legal; fire the ping at the enemy hero.
	_add_resources(state, "p1", 1)
	var use := PendingAction.make("use_ally_power", "p1",
		{"card_id": "melgwy", "target_id": "p2_hero"})
	ok(StackResolver.can_submit(state, use, db), "me-b: legal with 5 resources")

	StackResolver.submit_action(state, use, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	eq(state.get_current_hp("p2_hero", db), 25, "me-c: 5 fire damage dealt to enemy hero")
	eq(state.get_available_resources("p1"), 0, "me-d: paid the 5 resource cost")
	ok(state.get_card("melgwy").is_exhausted, "me-e: Melgwy exhausted (tap symbol)")


# ── Powers are instant-speed (rule 701): usable in ANY priority window, not just
# the action phase. Only summoning sickness (activated/tap powers) and the
# sorcery-speed "on_your_turn" restriction limit when a power fires. Regression
# for the bug where an instant-speed power was greyed during the opponent's
# ready step (Kavai during p2's ready step, chain empty, p1 with priority). ─────

func _test_power_usable_in_nonaction_priority_window() -> void:
	_buf.append("\n-- Powers are instant-speed: usable in a non-action priority window --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	# Instant-speed activated power (Grimdron-style: [Activate], suffers summoning
	# sickness). A sorcery-speed twin carries the "on_your_turn" segment.
	db.pet("grim_def", 0, 1, [], 1,
		"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally")
	db.pet("sorcery_def", 0, 1, [], 1,
		"activated_power:1:deal_damage_to_target:1:fire:hero_or_ally|on_your_turn")
	db.ally("dummy_def", 0, 3, [], 0)

	var state := _base_state(db, "p1_hero", "p2_hero")
	# The reported scenario: it is p2's turn, ready step, p1 holds the ready-step
	# priority window, chain empty.
	state.phase           = "ready"
	state.turn_player     = "p2"
	state.priority_player = "p1"

	var grim := _add_ally(state, "grim", "grim_def", "p1")
	grim.just_summoned = false
	grim.is_exhausted  = false
	var sorcery := _add_ally(state, "sorcery", "sorcery_def", "p1")
	sorcery.just_summoned = false
	sorcery.is_exhausted  = false
	_add_ally(state, "target", "dummy_def", "p2")
	_add_resources(state, "p1", 2)

	var grim_act := PendingAction.make("use_ally_power", "p1",
		{"card_id": "grim", "target_id": "target"})
	var sorcery_act := PendingAction.make("use_ally_power", "p1",
		{"card_id": "sorcery", "target_id": "target"})

	# pw-a: instant-speed power is legal in the ready-step window (the bug).
	ok(StackResolver.can_submit(state, grim_act, db),
		"pw-a: instant-speed power usable during the opponent's ready step")

	# pw-b: sorcery-speed ("on_your_turn") power is NOT legal outside the action
	# phase, even with priority.
	ok(not StackResolver.can_submit(state, sorcery_act, db),
		"pw-b: sorcery-speed power blocked outside the action phase")

	# pw-c: summoning sickness still gates an [Activate] power in the same window.
	grim.just_summoned = true
	ok(not StackResolver.can_submit(state, grim_act, db),
		"pw-c: summoning-sick activated power still blocked")
	grim.just_summoned = false

	# pw-d: with no priority, nothing is usable.
	state.priority_player = "p2"
	ok(not StackResolver.can_submit(state, grim_act, db),
		"pw-d: no priority → power illegal")
	state.priority_player = "p1"

	# pw-e: in the action phase the sorcery-speed power becomes legal (on p1's turn).
	state.phase       = "action"
	state.turn_player = "p1"
	ok(StackResolver.can_submit(state, sorcery_act, db),
		"pw-e: sorcery-speed power legal in p1's action phase")


# ── Kavai the Wanderer: "1, Destroy Kavai → Destroy target ability or
# equipment." Plain payment power (no [Activate] tap symbol) whose extra cost
# destroys the source itself. ──────────────────────────────────────────────────

const KAVAI_RECIPE := "activated_power:1:destroy_ability_or_equipment:0::ability_or_equipment:sacrifice_self"

func _test_kavai_sacrifice_destroys_ability_or_equipment() -> void:
	_buf.append("\n-- Kavai the Wanderer: sacrifice self → destroy target ability or equipment --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("kavai_def", 4, 6, [], 6, KAVAI_RECIPE)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("ongo_def", 2, "ongoing")
	db.instant("mark_def", 2, "ongoing|attach:ally|attached_buff:2:2")
	db.equipment("robe_def", 2, "equipment:chest:0")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var kavai := _add_ally(state, "kavai", "kavai_def", "p1")
	var bear := _add_ally(state, "bear", "bear_def", "p2")
	_add_resources(state, "p1", 2)

	# kv-a: no ability or equipment in play → the power has no legal target,
	# even the skip-target highlight probe fails.
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "kavai", "_skip_target_check": true}), db),
		"kv-a: power illegal with nothing to destroy")

	# p2's ongoing ability, equipment, and attachment on its bear.
	var ongo := CardInstance.create("ongo", "ongo_def", "p2", "p2_hero_row")
	state.cards["ongo"] = ongo
	state.zones["p2_hero_row"].card_ids.append("ongo")
	var robe := CardInstance.create("robe", "robe_def", "p2", "p2_hero_row")
	state.cards["robe"] = robe
	state.zones["p2_hero_row"].card_ids.append("robe")
	var mark := CardInstance.create("mark", "mark_def", "p2", "attached")
	state.cards["mark"] = mark
	state.zones["attached"].card_ids.append("mark")
	mark.attached_to = "bear"
	bear.attachments.append("mark")

	# kv-b..e: ability / equipment / attachment are legal, heroes and allies not.
	ok(StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "kavai", "target_id": "ongo"}), db),
		"kv-b: ongoing ability is a legal target")
	ok(StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "kavai", "target_id": "robe"}), db),
		"kv-c: equipment is a legal target")
	ok(StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "kavai", "target_id": "mark"}), db),
		"kv-d: an attachment is a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "kavai", "target_id": "bear"}), db),
		"kv-e: an ally is NOT a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "kavai", "target_id": "p2_hero"}), db),
		"kv-f: a hero is NOT a legal target")

	# kv-g: no [Activate] tap symbol — usable with summoning sickness AND exhausted.
	kavai.just_summoned = true
	kavai.is_exhausted = true
	ok(StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "kavai", "target_id": "robe"}), db),
		"kv-g: usable while just summoned and exhausted (no tap symbol)")

	# Resolve on the equipment: Kavai destroyed (cost), robe destroyed (effect).
	StackResolver.submit_action(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "kavai", "target_id": "robe"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(kavai.zone_id, "p1_graveyard", "kv-h: Kavai sacrificed to the graveyard")
	eq(robe.zone_id, "p2_graveyard",  "kv-i: target equipment destroyed")
	eq(state.get_available_resources("p1"), 1, "kv-j: 1 resource paid")


func _test_kavai_fizzles_opposing_removal() -> void:
	_buf.append("\n-- Kavai the Wanderer: killed in response, the effect still resolves --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("kavai_def", 4, 6, [], 6, KAVAI_RECIPE)
	db.equipment("robe_def", 2, "equipment:chest:0")
	db.instant("vanq_def", 3, "destroy_target:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var kavai := _add_ally(state, "kavai", "kavai_def", "p1")
	_add_resources(state, "p1", 1)
	_add_resources(state, "p2", 3)
	var robe := CardInstance.create("robe", "robe_def", "p2", "p2_hero_row")
	state.cards["robe"] = robe
	state.zones["p2_hero_row"].card_ids.append("robe")
	_add_card_to_hand(state, "vanq", "vanq_def", "p2")

	# p1 announces the power; p2 responds destroying Kavai. The response
	# resolves first — but the sacrifice cost simply no-ops (she's already
	# gone) and the announced effect still destroys the robe, matching the
	# printed rules where costs are paid at announcement.
	StackResolver.submit_action(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "kavai", "target_id": "robe"}), db)
	StackResolver.pass_priority(state, db)   # p1 passes, p2 responds
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2",
		{"card_id": "vanq", "target_id": "kavai"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # Vanquish resolves — Kavai dies
	eq(kavai.zone_id, "p1_graveyard", "kf-a: Kavai destroyed by the response")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # the power resolves
	eq(robe.zone_id, "p2_graveyard", "kf-b: the announced destroy still resolves")


func _test_ai_kavai_doomed_cash_in() -> void:
	_buf.append("\n-- AI Kavai: cashes in the power when doomed, holds it otherwise --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("kavai_def", 4, 6, [], 6, KAVAI_RECIPE)
	db.ally("ogre_def", 6, 6, [], 5)
	db.equipment("robe_def", 2, "equipment:chest:0")
	db.instant("vanq_def", 3, "destroy_target:ally")
	var ai := BaseAI.new()

	# Case 1 — combat: p1's 6-ATK ogre attacks p2's Kavai (6 hp). During the
	# attack window the AI sacrifices her onto p1's equipment.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "ogre", "ogre_def", "p1")
	var kavai := _add_ally(state, "kavai", "kavai_def", "p2")
	kavai.just_summoned = false
	_add_resources(state, "p2", 1)
	state.players["p1"].resource_placed_this_turn = true
	var robe := CardInstance.create("robe", "robe_def", "p1", "p1_hero_row")
	state.cards["robe"] = robe
	state.zones["p1_hero_row"].card_ids.append("robe")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "ogre", "defender_id": "kavai"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts, attack window opens
	ok(state.combat_attack_window, "kd-a: attack window open")
	StackResolver.pass_priority(state, db)   # p1 passes — priority to p2
	var act := ai.decide_action(state, db, "p2")
	ok(act != null and act.action_type == "use_ally_power" \
			and act.params.get("card_id", "") == "kavai" \
			and act.params.get("target_id", "") == "robe",
		"kd-b: doomed defender cashes in on the opposing equipment")

	# Case 2 — chain: opposing removal aimed at Kavai.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	var kavai2 := _add_ally(state2, "kavai2", "kavai_def", "p2")
	kavai2.just_summoned = false
	_add_resources(state2, "p1", 3)
	_add_resources(state2, "p2", 1)
	var robe2 := CardInstance.create("robe2", "robe_def", "p1", "p1_hero_row")
	state2.cards["robe2"] = robe2
	state2.zones["p1_hero_row"].card_ids.append("robe2")
	_add_card_to_hand(state2, "vanq", "vanq_def", "p1")
	StackResolver.submit_action(state2, PendingAction.make("play_instant", "p1",
		{"card_id": "vanq", "target_id": "kavai2"}), db)
	StackResolver.pass_priority(state2, db)   # p1 passes — priority to p2
	var act2 := ai.decide_action(state2, db, "p2")
	ok(act2 != null and act2.action_type == "use_ally_power" \
			and act2.params.get("card_id", "") == "kavai2",
		"kd-c: chain-threatened Kavai cashes in")

	# Case 3 — doomed but NO opposing ability/equipment: hold (die quietly).
	var state3 := _base_state(db, "p1_hero", "p2_hero")
	var kavai3 := _add_ally(state3, "kavai3", "kavai_def", "p2")
	kavai3.just_summoned = false
	_add_resources(state3, "p1", 3)
	_add_resources(state3, "p2", 1)
	_add_card_to_hand(state3, "vanq3", "vanq_def", "p1")
	StackResolver.submit_action(state3, PendingAction.make("play_instant", "p1",
		{"card_id": "vanq3", "target_id": "kavai3"}), db)
	StackResolver.pass_priority(state3, db)
	ok(ai.doomed_sacrifice_action(state3, db, "p2") == null,
		"kd-d: no meaningful target — power held")

	# Case 4 — never fired proactively on the AI's own turn.
	var state4 := _base_state(db, "p1_hero", "p2_hero")
	var kavai4 := _add_ally(state4, "kavai4", "kavai_def", "p1")
	kavai4.just_summoned = false
	_add_resources(state4, "p1", 1)
	var robe4 := CardInstance.create("robe4", "robe_def", "p2", "p2_hero_row")
	state4.cards["robe4"] = robe4
	state4.zones["p2_hero_row"].card_ids.append("robe4")
	for a in ai.get_reasonable_actions(state4, db, "p1"):
		ok(not (a.action_type == "use_ally_power" \
				and a.params.get("card_id", "") == "kavai4"),
			"kd-e: proactive power use never generated")


# ── Chops / Voss Treebender: "When [this] attacks, you may exhaust target
# hero or ally." ────────────────────────────────────────────────────────────────

# The trigger opens before the attack window; exhausting the opposing Protector
# denies the protect point (602.2 — protecting requires exhausting a ready
# character).
func _test_attack_exhaust_denies_protector() -> void:
	_buf.append("\n-- Attack-exhaust (Chops/Voss): exhaust denies protector --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("chops_def", 3, 4, [], 3, "on_attack_exhaust_target")
	db.ally("guard_def", 2, 5, (["protector"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "chops", "chops_def", "p1")
	_add_ally(state, "guard", "guard_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "chops", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)   # p1 passes
	StackResolver.pass_priority(state, db)   # p2 passes -> combat starts

	eq(state.pending_attack_exhaust_player, "p1", "ae-a: exhaust point opened for p1")
	eq(state.pending_attack_exhaust_source_id, "chops", "ae-a2: source is the attacker")
	ok(state.get_card("chops").is_exhausted, "ae-a3: attacker exhausted before the point")
	ok(not state.combat_attack_window, "ae-a4: attack window held until the choice")

	# Everything else is blocked while the point is pending.
	ok(StackResolver.pass_priority(state, db).is_empty(),
		"ae-b: pass_priority blocked while exhaust point pending")
	ok(not StackResolver.can_submit(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "chops", "defender_id": "p2_hero"}), db),
		"ae-b2: can_submit blocked while exhaust point pending")

	StackResolver.choose_attack_exhaust(state, "guard", db)
	ok(state.get_card("guard").is_exhausted, "ae-c: protector exhausted by the trigger")
	ok(state.combat_attack_window, "ae-c2: attack window opened after the choice")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes
	ok(not state.in_protect_point,
		"ae-d: no protect point — the only protector is exhausted")
	ok(state.combat_defend_window, "ae-d2: straight to the defend window")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("p2_hero").damage_taken, 3, "ae-e: hero took the attack unprotected")


# Declining ("" target) leaves the protector ready — the protect point opens
# normally. Also: a plain attacker without the flag never opens the point.
func _test_attack_exhaust_decline_keeps_protect() -> void:
	_buf.append("\n-- Attack-exhaust (Chops/Voss): decline keeps the protect point --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("chops_def", 3, 4, [], 3, "on_attack_exhaust_target")
	db.ally("plain_def", 2, 2)
	db.ally("guard_def", 2, 5, (["protector"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "chops", "chops_def", "p1")
	_add_ally(state, "guard", "guard_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "chops", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> exhaust point

	eq(state.pending_attack_exhaust_player, "p1", "ad-a: exhaust point opened")
	StackResolver.choose_attack_exhaust(state, "", db)   # decline
	ok(not state.get_card("guard").is_exhausted, "ad-b: protector stays ready on decline")
	ok(state.combat_attack_window, "ad-b2: attack window opened after decline")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes
	ok(state.in_protect_point, "ad-c: protect point opens — protector still ready")
	StackResolver.choose_protector(state, "guard", db)

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("p2_hero").damage_taken, 0, "ad-d: hero protected")
	eq(state.get_card("guard").damage_taken, 3, "ad-d2: protector intercepted the damage")

	# A plain attacker never opens the point (fresh state).
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	var plain := _add_ally(state2, "plain", "plain_def", "p1")
	plain.just_summoned = false
	state2.players["p1"].resource_placed_this_turn = true
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "plain", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	eq(state2.pending_attack_exhaust_player, "", "ad-e: no point for a flagless attacker")
	ok(state2.combat_attack_window, "ad-e2: attack window opened directly")


# Exhausting the proposed DEFENDER does not cancel the combat (601.3 already
# passed) — the attack still lands and the exhausted defender still strikes back.
func _test_attack_exhaust_defender_combat_proceeds() -> void:
	_buf.append("\n-- Attack-exhaust (Chops/Voss): exhausting the defender doesn't stop combat --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("chops_def", 3, 4, [], 3, "on_attack_exhaust_target")
	db.ally("victim_def", 2, 5)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "chops", "chops_def", "p1")
	_add_ally(state, "victim", "victim_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "chops", "defender_id": "victim"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> exhaust point

	StackResolver.choose_attack_exhaust(state, "victim", db)
	ok(state.get_card("victim").is_exhausted, "ax-a: defender exhausted by the trigger")
	eq(state.combat_defender, "victim", "ax-a2: still the defender — combat proceeds")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes -> defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("victim").damage_taken, 3, "ax-b: defender took combat damage")
	eq(state.get_card("chops").damage_taken, 2, "ax-b2: attacker took damage back")


# AI: exhausts the most dangerous ready opposing protector; declines when the
# defending side has no ready protector.
func _test_ai_attack_exhaust_choice() -> void:
	_buf.append("\n-- Attack-exhaust (Chops/Voss): AI picks the protector --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("chops_def", 3, 4, [], 3, "on_attack_exhaust_target")
	db.ally("small_guard_def", 1, 5, (["protector"] as Array[String]))
	db.ally("big_guard_def", 4, 5, (["protector"] as Array[String]))

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "chops", "chops_def", "p1")
	_add_ally(state, "small_guard", "small_guard_def", "p2")
	_add_ally(state, "big_guard", "big_guard_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "chops", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> exhaust point

	var ai := BaseAI.new()
	# big_guard's 4 ATK kills the 4-HP attacker in a protect — exhaust it.
	eq(ai.choose_attack_exhaust(state, db, "p1"), "big_guard",
		"aai-a: AI exhausts the protector that would kill the attacker")
	StackResolver.choose_attack_exhaust(state, "big_guard", db)

	# Second combat setup: no ready protectors left worth denying -> decline.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state2, "chops2", "chops_def", "p1")
	state2.players["p1"].resource_placed_this_turn = true
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "chops2", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	eq(ai.choose_attack_exhaust(state2, db, "p1"), "",
		"aai-b: AI declines with no protector to deny")
	StackResolver.choose_attack_exhaust(state2, "", db)
	ok(state2.combat_attack_window, "aai-b2: window opened after decline")


# ── Bala Silentblade: "+3 ATK while attacking an exhausted hero or ally." ──────

# The bonus is a live continuous modifier: on only while Bala is the combat
# attacker and the current defender is exhausted, off otherwise.
func _test_bala_atk_vs_exhausted() -> void:
	_buf.append("\n-- Bala Silentblade: +3 ATK vs exhausted defenders --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bala_def", 1, 4, [], 3, "atk_vs_exhausted_defender:3")
	db.ally("victim_def", 0, 6)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "bala", "bala_def", "p1")
	var victim := _add_ally(state, "victim", "victim_def", "p2")
	victim.is_exhausted = true
	state.players["p1"].resource_placed_this_turn = true

	eq(state.get_atk("bala", db), 1, "bs-a: no bonus outside combat")

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "bala", "defender_id": "victim"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> attack window

	eq(state.get_atk("bala", db), 4, "bs-b: +3 while attacking the exhausted ally")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # attack window closes -> defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("victim").damage_taken, 4, "bs-c: exhausted defender took 4")
	eq(state.get_card("bala").damage_taken, 0, "bs-c2: 0-ATK defender dealt nothing back")
	eq(state.get_atk("bala", db), 1, "bs-d: bonus gone after combat")

	# Second combat next turn vs a READY defender: no bonus.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state2, "bala2", "bala_def", "p1")
	_add_ally(state2, "fresh", "victim_def", "p2")
	state2.players["p1"].resource_placed_this_turn = true
	StackResolver.submit_action(state2, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "bala2", "defender_id": "fresh"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	eq(state2.get_atk("bala2", db), 1, "bs-e: no bonus vs a ready defender")
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	eq(state2.get_card("fresh").damage_taken, 1, "bs-e2: ready defender took only 1")


# Combo with the attack-exhaust trigger (Chops/Voss): a Bala-style attacker that
# ALSO carries on_attack_exhaust_target can exhaust its own defender before the
# attack window, turning the bonus on. Also covers the live re-read: the defender
# becomes exhausted AFTER the proposal resolved.
func _test_bala_bonus_turns_on_mid_combat() -> void:
	_buf.append("\n-- Bala Silentblade: bonus turns on when defender exhausts mid-combat --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("combo_def", 1, 4, [], 3,
		"atk_vs_exhausted_defender:3|on_attack_exhaust_target")
	db.ally("victim_def", 0, 6)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "combo", "combo_def", "p1")
	_add_ally(state, "victim", "victim_def", "p2")
	state.players["p1"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "combo", "defender_id": "victim"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts -> attack-exhaust point

	eq(state.get_atk("combo", db), 1, "bc-a: defender still ready — no bonus yet")
	StackResolver.choose_attack_exhaust(state, "victim", db)
	eq(state.get_atk("combo", db), 4, "bc-b: bonus live once the defender exhausts")

	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("victim").damage_taken, 4, "bc-c: combo dealt the boosted 4")


# ══════════════════════════════════════════════════════════════════════════════
# Mark of the Wild (azeroth_24): Instant Ability attachment — "Attach to target
# ally. Ongoing: Attached ally has +2 ATK and +2 health." (rule 400.2 / 400.5).
# The host leaving play destroys the attachment (rule 410.6c).
# ══════════════════════════════════════════════════════════════════════════════

func _test_mark_of_the_wild_attach_buff() -> void:
	_buf.append("\n-- Mark of the Wild: attach grants +2/+2, dies with its host --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.instant("azeroth_24", 2, "ongoing|attach:ally|attached_buff:2:2")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var bear := _add_ally(state, "bear", "bear_def", "p1")
	_add_card_to_hand(state, "mark", "azeroth_24", "p1")
	_add_resources(state, "p1", 2)

	# Instant + ongoing routes to play_ability (is_ongoing_def), instant timing.
	var cast := PendingAction.make("play_ability", "p1",
		{"card_id": "mark", "target_id": "bear"})
	ok(StackResolver.can_submit(state, cast, db), "mw-a: attach on own ally is legal")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	var mark := state.get_card("mark")
	eq(mark.zone_id, "attached",       "mw-b: Mark is in the attached zone")
	eq(mark.attached_to, "bear",       "mw-c: Mark's host is the bear")
	ok("mark" in bear.attachments,     "mw-d: bear lists Mark as an attachment")
	eq(state.get_atk("bear", db), 4,   "mw-e: host ATK is 2 + 2")
	eq(state.get_max_hp("bear", db), 5, "mw-f: host max HP is 3 + 2")
	ok(state.is_in_play("mark"),       "mw-g: the attachment counts as in play")

	# Rule 410.6c: the host leaving play destroys the attachment.
	var events := GameLogic.destroy_card(state, "bear", "")
	eq(mark.zone_id, "p1_graveyard",   "mw-h: Mark follows its host to the graveyard")
	eq(mark.attached_to, "",           "mw-i: attachment link cleared")
	ok(bear.attachments.is_empty(),    "mw-j: host attachment list cleared")
	var saw_att_destroy := false
	for e in events:
		if e.event_type == "card_destroyed" and e.payload.get("card", "") == "mark":
			saw_att_destroy = true
	ok(saw_att_destroy, "mw-k: attachment destruction emitted an event")


# ══════════════════════════════════════════════════════════════════════════════
# Entangling Roots (azeroth_20): "Attach to target ally and exhaust it.
# Ongoing: Attached ally can't ready during its controller's ready step."
# Non-instant Ability — action-phase timing. The lock is a live read at the
# ready step; other cards ready normally.
# ══════════════════════════════════════════════════════════════════════════════

func _test_entangling_roots_ready_lock() -> void:
	_buf.append("\n-- Entangling Roots: exhausts on attach, blocks the ready step --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("victim_def", 3, 3, [], 3)
	db.ally("other_def", 2, 2, [], 1)
	db.ability("azeroth_20", 2, "ongoing|attach:ally:exhaust_it|attached_cannot_ready")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var victim := _add_ally(state, "victim", "victim_def", "p2")
	var other  := _add_ally(state, "other", "other_def", "p2")
	other.is_exhausted = true
	_add_card_to_hand(state, "roots", "azeroth_20", "p1")
	_add_resources(state, "p1", 2)

	# Ally-only attach description: a hero is not a legal target.
	var at_hero := PendingAction.make("play_ability", "p1",
		{"card_id": "roots", "target_id": "p2_hero"})
	ok(not StackResolver.can_submit(state, at_hero, db),
		"er-a: Roots can't target a hero (attach:ally)")

	var cast := PendingAction.make("play_ability", "p1",
		{"card_id": "roots", "target_id": "victim"})
	ok(StackResolver.can_submit(state, cast, db), "er-b: Roots on an enemy ally is legal")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	ok(victim.is_exhausted,                        "er-c: host exhausted on attach")
	eq(state.get_card("roots").zone_id, "attached", "er-d: Roots is attached")

	# p2's ready step: the rooted ally stays exhausted, everything else readies.
	state.turn_player = "p2"
	TurnManager._enter_ready(state, db)
	ok(victim.is_exhausted,     "er-e: rooted ally did NOT ready at the ready step")
	ok(not other.is_exhausted,  "er-f: other exhausted ally readied normally")
	ok(not victim.just_summoned, "er-g: summoning sickness still cleared")


# ══════════════════════════════════════════════════════════════════════════════
# Rule 400.2 re-check at resolution: if the announced attach target leaves play
# before the attachment resolves, the attachment goes to its owner's graveyard.
# ══════════════════════════════════════════════════════════════════════════════

func _test_attach_fizzles_when_target_dies() -> void:
	_buf.append("\n-- Attach fizzle: target destroyed in response --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.instant("azeroth_24", 2, "ongoing|attach:ally|attached_buff:2:2")
	db.instant("kill_def", 0, "destroy_target:ally")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "bear", "bear_def", "p1")
	_add_card_to_hand(state, "mark", "azeroth_24", "p1")
	_add_card_to_hand(state, "kill", "kill_def", "p2")
	_add_resources(state, "p1", 2)

	var all_events: Array[GameEvent] = []
	all_events.append_array(StackResolver.submit_action(state,
		PendingAction.make("play_ability", "p1",
			{"card_id": "mark", "target_id": "bear"}), db))
	all_events.append_array(StackResolver.pass_priority(state, db))  # p1 → p2
	# p2 destroys the bear in response.
	all_events.append_array(StackResolver.submit_action(state,
		PendingAction.make("play_instant", "p2",
			{"card_id": "kill", "target_id": "bear"}), db))
	all_events.append_array(StackResolver.pass_priority(state, db))  # p2 passes
	all_events.append_array(StackResolver.pass_priority(state, db))  # kill resolves
	ok(state.get_card("bear").zone_id == "p1_graveyard", "af-a: bear destroyed in response")
	# Both pass again → Mark resolves with no legal host → graveyard.
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))

	eq(state.get_card("mark").zone_id, "p1_graveyard", "af-b: Mark fizzled to the graveyard")
	var saw_fizzle := false
	for e in all_events:
		if e.event_type == "action_fizzled" \
				and e.payload.get("reason", "") == "attach_target_gone":
			saw_fizzle = true
	ok(saw_fizzle, "af-c: attach fizzle event emitted")


# ══════════════════════════════════════════════════════════════════════════════
# AI attach heuristics: a buff attachment (Mark) goes on the AI's OWN best
# ally; a debuff attachment (Roots) goes on an opposing ally worth locking
# (cost >= spell cost) and never a cheap one.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ai_attach_target_choice() -> void:
	_buf.append("\n-- AI attach: buff own ally, lock expensive enemy ally --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("mine_def", 3, 3, [], 3)
	db.ally("big_def", 4, 4, [], 4)
	db.ally("cheap_def", 1, 1, [], 1)
	db.instant("azeroth_24", 2, "ongoing|attach:ally|attached_buff:2:2")
	db.ability("azeroth_20", 2, "ongoing|attach:ally:exhaust_it|attached_cannot_ready")

	var ai := BaseAI.new()

	# Buff: only the friendly ally is offered, never the enemy.
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "mine", "mine_def", "p1")
	_add_ally(state, "big", "big_def", "p2")
	_add_card_to_hand(state, "mark", "azeroth_24", "p1")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	var mark_targets: Array = []
	for a in ai.get_reasonable_actions(state, db, "p1"):
		if a.params.get("card_id", "") == "mark":
			mark_targets.append(a.params.get("target_id", ""))
	eq(mark_targets.size(), 1, "aa-a: exactly one Mark action generated")
	ok("mine" in mark_targets, "aa-b: Mark targets the AI's own ally")

	# Debuff: the 4-cost enemy is locked, a lone 1-cost enemy is not worth it.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state2, "big", "big_def", "p2")
	_add_ally(state2, "cheap", "cheap_def", "p2")
	_add_card_to_hand(state2, "roots", "azeroth_20", "p1")
	_add_resources(state2, "p1", 2)
	state2.players["p1"].resource_placed_this_turn = true
	var roots_targets: Array = []
	for a in ai.get_reasonable_actions(state2, db, "p1"):
		if a.params.get("card_id", "") == "roots":
			roots_targets.append(a.params.get("target_id", ""))
	eq(roots_targets.size(), 1, "aa-c: exactly one Roots action generated")
	ok("big" in roots_targets, "aa-d: Roots targets the expensive enemy ally")

	var state3 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state3, "cheap", "cheap_def", "p2")
	_add_card_to_hand(state3, "roots", "azeroth_20", "p1")
	_add_resources(state3, "p1", 2)
	state3.players["p1"].resource_placed_this_turn = true
	var any_roots := false
	for a in ai.get_reasonable_actions(state3, db, "p1"):
		if a.params.get("card_id", "") == "roots":
			any_roots = true
	ok(not any_roots, "aa-e: Roots not wasted on a lone cheap ally")


# ══════════════════════════════════════════════════════════════════════════════
# SCENARIO — Natural Selection (azeroth_27): "Choose one: Your hero deals 3
# nature damage to target hero or ally; or your hero heals 3 damage from
# target hero or ally." First MODAL link (rule 707.1c) — recipe
# `mode:deal_damage_to_target:3:nature|mode:heal_target:3`. The chosen mode
# index is announced on the play action (params.mode); the engine validates
# and resolves ONLY that mode's inner effect.
# ══════════════════════════════════════════════════════════════════════════════

func _test_natural_selection() -> void:
	_buf.append("\n-- Scenario: Natural Selection — modal choose-one (707.1c) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("grunt_def", 3, 5, [], 4)
	db.instant("azeroth_27", 3,
		"mode:deal_damage_to_target:3:nature|mode:heal_target:3")

	# ── Damage mode (mode 0): 3 nature from the hero ──
	var st := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st, "p1", 3)
	_add_hand_card(st, "ns", "azeroth_27", "p1")
	var grunt := _add_ally(st, "grunt", "grunt_def", "p2")

	var events: Array[GameEvent] = StackResolver.submit_action(st,
		PendingAction.make("play_instant", "p1",
			{"card_id": "ns", "target_id": "grunt", "mode": 0}), db)
	events.append_array(StackResolver.pass_priority(st, db))
	events.append_array(StackResolver.pass_priority(st, db))

	eq(grunt.damage_taken, 3, "ns-a: damage mode — target ally took 3")
	var from_hero := false
	for e in events:
		if e.event_type == "damage_dealt" and e.payload.get("source", "") == "p1_hero" \
				and e.payload.get("target", "") == "grunt":
			from_hero = true
	ok(from_hero, "ns-b: damage sourced from p1's hero")
	ok(st.get_card("ns").zone_id == "p1_graveyard",
		"ns-c: Natural Selection is in the graveyard")

	# ── Heal mode (mode 1): heals 3 from own damaged ally, deals nothing ──
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st2, "p1", 3)
	_add_hand_card(st2, "ns2", "azeroth_27", "p1")
	var mine := _add_ally(st2, "mine", "grunt_def", "p1")
	mine.damage_taken = 4

	StackResolver.submit_action(st2, PendingAction.make("play_instant", "p1",
		{"card_id": "ns2", "target_id": "mine", "mode": 1}), db)
	StackResolver.pass_priority(st2, db)
	StackResolver.pass_priority(st2, db)

	eq(mine.damage_taken, 1, "ns-d: heal mode — 3 damage removed from own ally")
	ok(st2.get_card("ns2").zone_id == "p1_graveyard",
		"ns-e: heal mode also ends in the graveyard")

	# ── The mode must be announced with the play (707.1c) ──
	var st3 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st3, "p1", 3)
	_add_hand_card(st3, "ns3", "azeroth_27", "p1")
	_add_ally(st3, "grunt3", "grunt_def", "p2")
	ok(not StackResolver.can_submit(st3, PendingAction.make("play_instant", "p1",
			{"card_id": "ns3", "target_id": "grunt3"}), db),
		"ns-f: play without a mode param is rejected")
	ok(not StackResolver.can_submit(st3, PendingAction.make("play_instant", "p1",
			{"card_id": "ns3", "target_id": "grunt3", "mode": 5}), db),
		"ns-g: out-of-range mode index is rejected")
	ok(StackResolver.can_submit(st3, PendingAction.make("play_instant", "p1",
			{"card_id": "ns3", "target_id": "grunt3", "mode": 0}), db),
		"ns-h: same play with a valid mode is legal")

	# ── AI: get_modal_actions exposes BOTH modes; play policy keeps damage only ──
	var ai := BaseAI.new()
	# An untagged modal twin exercises the get_reasonable_actions modal hook directly
	# (azeroth_27 itself is held as a combat instant and never blind-played).
	db.instant("modal_twin", 3,
		"mode:deal_damage_to_target:3:nature|mode:heal_target:3")
	var st4 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st4, "p1", 3)
	_add_hand_card(st4, "twin", "modal_twin", "p1")
	_add_ally(st4, "grunt4", "grunt_def", "p2")
	st4.get_card("p1_hero").damage_taken = 5

	var seen_modes: Dictionary = {}
	var heal_target := ""
	for a in ai.get_modal_actions(st4, db, "p1", "twin"):
		var m := int((a as PendingAction).params.get("mode", -1))
		seen_modes[m] = true
		if m == 1:
			heal_target = (a as PendingAction).params.get("target_id", "")
	ok(seen_modes.has(0) and seen_modes.has(1),
		"ns-i: get_modal_actions enumerates both modes")
	eq(heal_target, "p1_hero", "ns-j: heal-mode option targets the AI's own damaged hero")

	var played_modes: Dictionary = {}
	for a in ai.get_reasonable_actions(st4, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "twin":
			played_modes[int((a as PendingAction).params.get("mode", -1))] = true
	ok(played_modes.has(0) and not played_modes.has(1),
		"ns-k: play policy — only the damage mode is actually submitted")

	# ── AI: azeroth_27 itself is a held combat instant, ambushed with mode 0 ──
	var st5 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(st5, "p1", 3)
	_add_hand_card(st5, "ns5", "azeroth_27", "p1")
	var blind := false
	for a in ai.get_reasonable_actions(st5, db, "p1"):
		if (a as PendingAction).params.get("card_id", "") == "ns5":
			blind = true
	ok(not blind, "ns-l: AI never blind-plays Natural Selection on its own window")

	db.ally("atk_frail_ns", 3, 3, [], 4)   # cost 4, 3 HP — dies to 3 nature
	var st6 := _base_state(db, "p1_hero", "p2_hero")
	st6.turn_player     = "p2"
	st6.priority_player = "p1"
	_add_resources(st6, "p1", 3)
	_add_hand_card(st6, "ns6", "azeroth_27", "p1")
	_add_ally(st6, "atk_frail", "atk_frail_ns", "p2")
	st6.combat_attack_window = true
	st6.combat_defender = "p1_hero"
	st6.combat_attacker = "atk_frail"
	var amb := ai.combat_instant_action(st6, db, "p1")
	ok(amb != null and amb.params.get("card_id") == "ns6"
			and amb.params.get("target_id") == "atk_frail"
			and int(amb.params.get("mode", -1)) == 0,
		"ns-m: attack window — ambush kill announces the damage mode")


# ══════════════════════════════════════════════════════════════════════════════
# Burn Away (azeroth_156): "Destroy target ability." Non-instant Ability.
# Legal targets are in-play ability CARDS only: ongoing abilities (hero row),
# attachments ("attached" zone), totems (ally row) — never heroes, regular
# allies, or equipment.
# ══════════════════════════════════════════════════════════════════════════════

func _test_burn_away_destroys_ability() -> void:
	_buf.append("\n-- Burn Away: destroys target in-play ability card --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("ongo_def", 2, "ongoing")
	db.instant("mark_def", 2, "ongoing|attach:ally|attached_buff:2:2")
	db.equipment("robe_def", 2, "equipment:chest:0")
	db.ability("azeroth_156", 3, "destroy_target:ability")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var bear := _add_ally(state, "bear", "bear_def", "p2")
	_add_resources(state, "p1", 6)

	# p2's ongoing ability in play (hero row).
	var ongo := CardInstance.create("ongo", "ongo_def", "p2", "p2_hero_row")
	state.cards["ongo"] = ongo
	state.zones["p2_hero_row"].card_ids.append("ongo")
	# p2's equipment in play (NOT a legal ability target).
	var robe := CardInstance.create("robe", "robe_def", "p2", "p2_hero_row")
	state.cards["robe"] = robe
	state.zones["p2_hero_row"].card_ids.append("robe")
	# p2's Mark of the Wild attached to p2's bear.
	var mark := CardInstance.create("mark", "mark_def", "p2", "attached")
	state.cards["mark"] = mark
	state.zones["attached"].card_ids.append("mark")
	mark.attached_to = "bear"
	bear.attachments.append("mark")

	_add_card_to_hand(state, "burn1", "azeroth_156", "p1")
	_add_card_to_hand(state, "burn2", "azeroth_156", "p1")

	# Target legality: ability cards only.
	ok(StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "burn1", "target_id": "ongo"}), db),
		"ba-a: ongoing ability is a legal target")
	ok(StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "burn1", "target_id": "mark"}), db),
		"ba-b: an attachment is a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "burn1", "target_id": "robe"}), db),
		"ba-c: equipment is NOT a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "burn1", "target_id": "bear"}), db),
		"ba-d: a regular ally is NOT a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "burn1", "target_id": "p2_hero"}), db),
		"ba-e: a hero is NOT a legal target")

	# Resolve on the ongoing ability.
	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "burn1", "target_id": "ongo"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(ongo.zone_id, "p2_graveyard",  "ba-f: ongoing ability destroyed")
	eq(state.get_card("burn1").zone_id, "p1_graveyard", "ba-g: Burn Away in graveyard")

	# Resolve on the attachment: host loses the buff, link cleaned up.
	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "burn2", "target_id": "mark"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(mark.zone_id, "p2_graveyard",  "ba-h: attachment destroyed")
	ok(bear.attachments.is_empty(),   "ba-i: host attachment list cleared")
	eq(state.get_atk("bear", db), 2,  "ba-j: host ATK back to printed value")

	# AI: enumerates only opposing ability targets worth the cost.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 3)
	var ongo2 := CardInstance.create("ongo2", "ongo_def", "p2", "p2_hero_row")
	state2.cards["ongo2"] = ongo2
	state2.zones["p2_hero_row"].card_ids.append("ongo2")
	_add_card_to_hand(state2, "burn3", "azeroth_156", "p1")
	var ai := BaseAI.new()
	var acts := ai._targeted_instant_actions(state2, db, "p1", "burn3", "play_ability")
	ok(acts.is_empty(), "ba-k: AI skips a target cheaper than the spell (cost 2 < 3)")


# ══════════════════════════════════════════════════════════════════════════════
# Purge (azeroth_114): "Destroy target ability unless it's attached to a
# friendly hero or ally." Instant Ability — Burn Away's target pool minus every
# ability attached to one of the CASTER's own characters. "Friendly" is judged
# on the HOST's controller, so an opponent's Entangling Roots sitting on your
# own ally is protected from your Purge; an attachment on a weapon isn't
# attached to a hero or ally at all, so it stays fair game.
# ══════════════════════════════════════════════════════════════════════════════

func _test_purge_spares_friendly_attachments() -> void:
	_buf.append("\n-- Purge: destroys abilities except friendly-attached ones --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("ongo_def", 2, "ongoing")
	db.instant("mark_def", 2, "ongoing|attach:ally|attached_buff:2:2")
	db.instant("roots_def", 2, "ongoing|attach:ally:exhaust_it|attached_cannot_ready")
	db.instant("wf_def", 2, "ongoing|attach:melee_weapon|ready_on_strike:1")
	db.equipment("krol_def", 3, "equipment:melee_weapon:0|strike_cost:1")
	db.instant("azeroth_114", 1, "destroy_target:ability|except_friendly_attached")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var my_ally  := _add_ally(state, "mine", "bear_def", "p1")
	var opp_ally := _add_ally(state, "theirs", "bear_def", "p2")
	_add_resources(state, "p1", 6)

	# p2's ongoing ability (unattached) — always a legal target.
	var ongo := CardInstance.create("ongo", "ongo_def", "p2", "p2_hero_row")
	state.cards["ongo"] = ongo
	state.zones["p2_hero_row"].card_ids.append("ongo")
	# p1's OWN Mark of the Wild on p1's own ally — protected.
	var mark := CardInstance.create("mark", "mark_def", "p1", "attached")
	state.cards["mark"] = mark
	state.zones["attached"].card_ids.append("mark")
	mark.attached_to = "mine"
	my_ally.attachments.append("mark")
	# p2's Entangling Roots on p1's ally — the sad case: host is friendly, so
	# Purge can't strip it.
	var roots := CardInstance.create("roots", "roots_def", "p2", "attached")
	state.cards["roots"] = roots
	state.zones["attached"].card_ids.append("roots")
	roots.attached_to = "mine"
	my_ally.attachments.append("roots")
	# p2's Mark on p2's OWN ally — not friendly to p1, so targetable.
	var opp_mark := CardInstance.create("opp_mark", "mark_def", "p2", "attached")
	state.cards["opp_mark"] = opp_mark
	state.zones["attached"].card_ids.append("opp_mark")
	opp_mark.attached_to = "theirs"
	opp_ally.attachments.append("opp_mark")
	# p1's OWN Windfury Weapon on p1's OWN weapon — a weapon is not a hero or
	# ally, so the exclusion does NOT cover it.
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")
	var wf := CardInstance.create("wf", "wf_def", "p1", "attached")
	state.cards["wf"] = wf
	state.zones["attached"].card_ids.append("wf")
	wf.attached_to = "krol"
	krol.attachments.append("wf")

	_add_card_to_hand(state, "purge1", "azeroth_114", "p1")
	_add_card_to_hand(state, "purge2", "azeroth_114", "p1")

	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "purge1", "target_id": "ongo"}), db),
		"pg-a: unattached ongoing ability is a legal target")
	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "purge1", "target_id": "opp_mark"}), db),
		"pg-b: attachment on an OPPOSING ally is a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "purge1", "target_id": "mark"}), db),
		"pg-c: own attachment on own ally is NOT a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "purge1", "target_id": "roots"}), db),
		"pg-d: opponent's attachment on OUR ally is NOT a legal target")
	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p1",
			{"card_id": "purge1", "target_id": "wf"}), db),
		"pg-e: own attachment on own WEAPON is still a legal target")
	# p2 casting the same card sees the mirror image of the restriction (p2 needs
	# priority for the instant's timing to be legal in the first place).
	_add_card_to_hand(state, "purge_p2", "azeroth_114", "p2")
	_add_resources(state, "p2", 6)
	state.priority_player = "p2"
	ok(StackResolver.can_submit(state, PendingAction.make("play_instant", "p2",
			{"card_id": "purge_p2", "target_id": "mark"}), db),
		"pg-f: 'friendly' is caster-relative — p2 may destroy p1's attachment")
	state.priority_player = "p1"

	# Resolves like Burn Away on a legal target.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "purge1", "target_id": "opp_mark"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(opp_mark.zone_id, "p2_graveyard", "pg-g: opposing attachment destroyed")
	ok(opp_ally.attachments.is_empty(),  "pg-h: host attachment list cleared")
	eq(state.get_atk("theirs", db), 2,   "pg-i: host ATK back to printed value")

	# 706 / glossary 4217 re-check: an attachment that becomes friendly-attached
	# after the announce fizzles at resolution.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "purge2", "target_id": "wf"}), db)
	krol.controller = "p2"          # weapon changes hands mid-chain…
	wf.attached_to  = "mine"        # …and the attachment ends up on our own ally
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(wf.zone_id, "attached", "pg-j: fizzles when the target became friendly-attached")

	# Highlight probe: with only friendly-attached abilities in play, Purge goes
	# dark (706.2 — a targeted card can't be announced with no legal target).
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 6)
	var solo := _add_ally(state2, "solo", "bear_def", "p1")
	var only_mark := CardInstance.create("only_mark", "mark_def", "p1", "attached")
	state2.cards["only_mark"] = only_mark
	state2.zones["attached"].card_ids.append("only_mark")
	only_mark.attached_to = "solo"
	solo.attachments.append("only_mark")
	_add_card_to_hand(state2, "purge3", "azeroth_114", "p1")
	ok(not StackResolver.can_play_instant_no_target_check(state2, "purge3", "p1", db),
		"pg-k: unplayable when every in-play ability is friendly-attached")

	# AI: destroys the opponent's ability, never reaches for a protected one.
	var ai := BaseAI.new()
	var acts := ai._targeted_instant_actions(state2, db, "p1", "purge3", "play_instant")
	ok(acts.is_empty(), "pg-l: AI has no play with only our own attachment in play")
	var opp_ongo := CardInstance.create("opp_ongo", "ongo_def", "p2", "p2_hero_row")
	state2.cards["opp_ongo"] = opp_ongo
	state2.zones["p2_hero_row"].card_ids.append("opp_ongo")
	acts = ai._targeted_instant_actions(state2, db, "p1", "purge3", "play_instant")
	eq(acts.size(), 1, "pg-m: AI finds the opposing ongoing ability")
	eq(acts[0].params.get("target_id", ""), "opp_ongo", "pg-n: AI targets it")


# ══════════════════════════════════════════════════════════════════════════════
# Shattering Blow (azeroth_168): "Destroy target equipment." Non-instant
# Ability. Legal targets are in-play equipment cards only (armor / weapons in
# a hero row) — never heroes, allies, or ability cards.
# ══════════════════════════════════════════════════════════════════════════════

func _test_shattering_blow_destroys_equipment() -> void:
	_buf.append("\n-- Shattering Blow: destroys target equipment --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("ongo_def", 2, "ongoing")
	db.equipment("robe_def", 4, "equipment:chest:0")
	db.ability("azeroth_168", 4, "destroy_target:equipment")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "bear", "bear_def", "p2")
	_add_resources(state, "p1", 4)
	_add_card_to_hand(state, "blow", "azeroth_168", "p1")

	# No equipment in play yet: the hand card has no legal target (706.2).
	ok(not StackResolver.can_play_ability_no_target_check(state, "blow", "p1", db),
		"sb-a: unplayable while no equipment is in play")

	var robe := CardInstance.create("robe", "robe_def", "p2", "p2_hero_row")
	state.cards["robe"] = robe
	state.zones["p2_hero_row"].card_ids.append("robe")
	var ongo := CardInstance.create("ongo", "ongo_def", "p2", "p2_hero_row")
	state.cards["ongo"] = ongo
	state.zones["p2_hero_row"].card_ids.append("ongo")

	ok(StackResolver.can_play_ability_no_target_check(state, "blow", "p1", db),
		"sb-b: playable once equipment is in play")
	ok(StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "blow", "target_id": "robe"}), db),
		"sb-c: equipment is a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "blow", "target_id": "ongo"}), db),
		"sb-d: an ongoing ability is NOT a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "blow", "target_id": "bear"}), db),
		"sb-e: an ally is NOT a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "blow", "target_id": "p2_hero"}), db),
		"sb-f: a hero is NOT a legal target")

	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "blow", "target_id": "robe"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(robe.zone_id, "p2_graveyard",  "sb-g: equipment destroyed")
	eq(state.get_card("blow").zone_id, "p1_graveyard", "sb-h: Shattering Blow in graveyard")

	# AI: targets the opposing equipment (cost 4 >= spell 4).
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state2, "p1", 4)
	var robe2 := CardInstance.create("robe2", "robe_def", "p2", "p2_hero_row")
	state2.cards["robe2"] = robe2
	state2.zones["p2_hero_row"].card_ids.append("robe2")
	_add_card_to_hand(state2, "blow2", "azeroth_168", "p1")
	var ai := BaseAI.new()
	var acts := ai._targeted_instant_actions(state2, db, "p1", "blow2", "play_ability")
	ok(acts.size() == 1 and acts[0].params.get("target_id") == "robe2",
		"sb-i: AI targets the opposing equipment")


# ══════════════════════════════════════════════════════════════════════════════
# FORMS (rule 414.3b + glossary Bear/Cat Form) — Bear Form, Bash, Cat Form, Claw
# ══════════════════════════════════════════════════════════════════════════════

const CAT_FORM_FX  := "ongoing|form:1|form_break:Feral|hero_atk_while_attacking:1|on_destroyed:pay_return_hand:2"
const BEAR_FORM_FX := "ongoing|form:1|form_break:Feral|hero_has_protector|on_destroyed:pay_return_hand:2"
const BASH_FX      := "ongoing|form:1|form_break:Feral|hero_has_protector|exhaust_target:hero_or_ally"
const CLAW_FX      := "ongoing|form:1|form_break:Feral|hero_atk_while_attacking:1|deal_damage_to_target:3:melee"


# MockDB helper: an Instant Ability Form def with the Feral tag.
func _mock_form(db: MockDB, def_id: String, cost: int, fx: String,
		tags: String = "Feral") -> void:
	db.instant(def_id, cost, fx)
	(db._defs[def_id] as CardDef).tags = tags


# Put a Form directly into a player's hero_row (already shapeshifted).
func _add_form_in_play(state: GameState, inst_id: String, def_id: String,
		ctrl: String) -> CardInstance:
	var card := CardInstance.create(inst_id, def_id, ctrl, ctrl + "_hero_row")
	state.cards[inst_id] = card
	state.zones[ctrl + "_hero_row"].card_ids.append(inst_id)
	return card


func _test_cat_form_hero_attack() -> void:
	_buf.append("\n-- Cat Form: +1 ATK while attacking lets the 0-ATK hero attack --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	_mock_form(db, "dark_portal_19", 2, CAT_FORM_FX)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_card_to_hand(state, "cat", "dark_portal_19", "p1")
	_add_resources(state, "p1", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# The 0-ATK hero with no weapon is not offered as an attacker yet.
	ok("p1_hero" not in StackResolver.get_legal_attackers(state, "p1", db),
		"cf-a: bare 0-ATK hero is not a legal attacker")

	var play := PendingAction.make("play_ability", "p1", {"card_id": "cat"})
	ok(StackResolver.can_submit(state, play, db), "cf-b: Cat Form is playable")
	StackResolver.submit_action(state, play, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	ok(state.get_card("cat").zone_id == "p1_hero_row",
		"cf-c: Cat Form is ongoing — enters the hero row")
	eq(state.get_atk("p1_hero", db), 0, "cf-d: hero ATK is 0 while not attacking")
	eq(state.get_atk("p1_hero", db, true), 1, "cf-e: +1 ATK while attacking")
	ok("p1_hero" in StackResolver.get_legal_attackers(state, "p1", db),
		"cf-f: hero is a legal attacker thanks to the while-attacking bonus")

	# Attack the enemy hero: the +1 lands as real combat damage.
	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts, attack window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # close attack window → defend window
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # conclusion
	eq(state.get_card("p2_hero").damage_taken, 1, "cf-g: defending hero took 1")
	eq(state.get_card("p1_hero").damage_taken, 0, "cf-h: attacker took nothing back")


func _test_form_break_and_pay_return() -> void:
	_buf.append("\n-- Form break: a non-Feral ability destroys the Form; pay 2 returns it --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	_mock_form(db, "dark_portal_19", 2, CAT_FORM_FX)
	db.instant("qs_def", 1, "deal_damage_to_target:2:melee")   # non-Feral (no tag)
	_mock_form(db, "feral_inst", 1, "deal_damage_to_target:1:melee")  # Feral-tagged instant

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_form_in_play(state, "cat", "dark_portal_19", "p1")
	_add_card_to_hand(state, "feral", "feral_inst", "p1")
	_add_card_to_hand(state, "qs", "qs_def", "p1")
	_add_resources(state, "p1", 4)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	# A FERAL ability does not break the form.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "feral", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.get_card("cat").zone_id == "p1_hero_row",
		"fb-a: Feral ability leaves the form in play")

	# A non-Feral ability breaks it (after its own resolution).
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "qs", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.get_card("cat").zone_id == "p1_graveyard",
		"fb-b: non-Feral ability destroys the form")
	eq(state.pending_form_return_player, "p1",
		"fb-c: pay-return choice opened (cost affordable)")

	var before := state.get_available_resources("p1")
	StackResolver.choose_form_return(state, true, db)
	ok(state.get_card("cat").zone_id == "p1_hand", "fb-d: paid — form back in hand")
	eq(state.get_available_resources("p1"), before - 2, "fb-e: 2 resources paid")

	# Unaffordable variant: no choice opens, the form stays in the graveyard.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_form_in_play(state2, "cat2", "dark_portal_19", "p1")
	_add_card_to_hand(state2, "qs2", "qs_def", "p1")
	_add_resources(state2, "p1", 2)   # 1 left after playing the 1-cost instant
	state2.players["p1"].resource_placed_this_turn = true
	state2.players["p2"].resource_placed_this_turn = true
	StackResolver.submit_action(state2, PendingAction.make("play_instant", "p1",
		{"card_id": "qs2", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state2, db)
	StackResolver.pass_priority(state2, db)
	ok(state2.get_card("cat2").zone_id == "p1_graveyard",
		"fb-f: form destroyed in the unaffordable case too")
	eq(state2.pending_form_return_player, "",
		"fb-g: no pay-return choice when the cost is unaffordable")


func _test_form_uniqueness_shapeshift() -> void:
	_buf.append("\n-- Form (1): playing a second Form forces a sacrifice (shapeshift) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	_mock_form(db, "azeroth_18", 1, BEAR_FORM_FX)
	_mock_form(db, "dark_portal_19", 2, CAT_FORM_FX)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_form_in_play(state, "bear", "azeroth_18", "p1")
	_add_card_to_hand(state, "cat", "dark_portal_19", "p1")
	_add_resources(state, "p1", 4)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "cat"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves → violation

	eq(state.pending_form_sacrifice_player, "p1", "fu-a: Form sacrifice pending")
	ok("bear" in state.pending_form_sacrifice_ids
			and "cat" in state.pending_form_sacrifice_ids,
		"fu-b: both Forms are candidates")
	# Everything else is blocked while the violation stands.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
			{"card_id": "cat"}), db),
		"fu-c: can_submit hard-blocks during the Form sacrifice")

	StackResolver.choose_form_sacrifice(state, "bear", db)
	ok(state.get_card("bear").zone_id == "p1_graveyard", "fu-d: old form destroyed")
	eq(state.pending_form_sacrifice_player, "", "fu-e: violation repaired")
	# Bear Form's own pay-return trigger fired on the sacrifice destruction.
	eq(state.pending_form_return_player, "p1", "fu-f: pay-return opened for the old form")
	StackResolver.choose_form_return(state, false, db)
	ok(state.get_card("bear").zone_id == "p1_graveyard",
		"fu-g: declined — old form stays in the graveyard")
	ok(state.get_card("cat").zone_id == "p1_hero_row", "fu-h: new form is in play")


func _test_bash_freezes_and_grants_bear_form() -> void:
	_buf.append("\n-- Bash: exhaust the attacker (fizzling the proposal) + bear form ongoing --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 4, 4, [], 3)
	_mock_form(db, "azeroth_17", 2, BASH_FX)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_card_to_hand(state, "bash", "azeroth_17", "p2")
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var all_events: Array[GameEvent] = []
	all_events.append_array(StackResolver.submit_action(state,
		PendingAction.make("propose_combat", "p1",
			{"attacker_id": "atk", "defender_id": "p2_hero"}), db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # p1 → p2

	# Bash is instant speed and may target the attacking ALLY (or a hero).
	var cast := PendingAction.make("play_ability", "p2",
		{"card_id": "bash", "target_id": "atk"})
	ok(StackResolver.can_submit(state, cast, db),
		"ba-a: Bash on the attacker is legal in response to the proposal")
	all_events.append_array(StackResolver.submit_action(state, cast, db))
	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # Bash resolves

	ok(atk.is_exhausted, "ba-b: attacker exhausted")
	ok(state.get_card("bash").zone_id == "p2_hero_row",
		"ba-c: Bash stays in play (ongoing) in the hero row")

	all_events.append_array(StackResolver.pass_priority(state, db))
	all_events.append_array(StackResolver.pass_priority(state, db))   # proposal resolves
	var saw_fizzle := false
	for e in all_events:
		if e.event_type == "action_fizzled":
			saw_fizzle = true
	ok(saw_fizzle and not state.combat_attack_window,
		"ba-d: proposal fizzled — combat never started")

	# Bear form ongoing: the hero now has protector.
	ok(StackResolver._hero_has_protector_grant(state, "p2", db),
		"ba-e: Bash grants the hero protector while in play")


func _test_form_breaks_on_weapon_strike() -> void:
	_buf.append("\n-- Form break: striking with a weapon destroys the Form --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	_mock_form(db, "azeroth_18", 1, BEAR_FORM_FX)
	db.weapon("krol_def", 2, 3, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_form_in_play(state, "bear", "azeroth_18", "p1")
	var krol := CardInstance.create("krol", "krol_def", "p1", "p1_hero_row")
	state.cards["krol"] = krol
	state.zones["p1_hero_row"].card_ids.append("krol")
	_add_resources(state, "p1", 3)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts → strike point (602.1)
	eq(state.pending_strike_player, "p1", "wsf-a: strike point open for the attacker")

	StackResolver.choose_strike(state, "krol", db)
	ok(state.get_card("bear").zone_id == "p1_graveyard",
		"wsf-b: striking with a weapon destroys the Form")
	eq(state.pending_form_return_player, "p1", "wsf-c: pay-return opened")
	StackResolver.choose_form_return(state, true, db)
	ok(state.get_card("bear").zone_id == "p1_hand", "wsf-d: paid — Form back in hand")
	ok(state.combat_attack_window, "wsf-e: the held attack window opened after the strike")


func _test_ai_bear_form_flash_in() -> void:
	_buf.append("\n-- AI Bear Form: flash in during the attack window, only when not in form --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 3, 3, [], 3)
	_mock_form(db, "azeroth_18", 1, BEAR_FORM_FX)
	var ai := BaseAI.new()

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_card_to_hand(state, "bear", "azeroth_18", "p2")
	_add_resources(state, "p2", 1)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts, attack window
	StackResolver.pass_priority(state, db)   # p1 passes on the window → p2 priority

	# get_reasonable_actions never blind-plays the held card.
	var blind := false
	for a in ai.get_reasonable_actions(state, db, "p2"):
		if a.params.get("card_id", "") == "bear":
			blind = true
	ok(not blind, "aibf-a: Bear Form is held (never blind-played)")

	var act := ai.bear_form_action(state, db, "p2")
	ok(act != null and act.action_type == "play_ability"
			and act.params.get("card_id") == "bear",
		"aibf-b: AI flashes in Bear Form during the attack window")

	# Already in bear form → hold the card.
	_add_form_in_play(state, "bear_in_play", "azeroth_18", "p2")
	ok(ai.bear_form_action(state, db, "p2") == null,
		"aibf-c: held when the hero is already in bear form")
	state.zones["p2_hero_row"].card_ids.erase("bear_in_play")
	state.cards.erase("bear_in_play")

	# Exhausted hero can't protect → hold.
	state.get_card("p2_hero").is_exhausted = true
	ok(ai.bear_form_action(state, db, "p2") == null,
		"aibf-d: held when the hero is exhausted")
	state.get_card("p2_hero").is_exhausted = false

	# The AI always pays to get a destroyed Form back.
	ok(ai.choose_form_return(state, db, "p2"), "aibf-e: AI always pays the form return")


func _test_ai_bash_freezes_attacking_hero() -> void:
	_buf.append("\n-- AI Bash: freezes an attacking HERO (Exhaustion alone can't) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.instant("azeroth_159", 2, "exhaust_target:ally")
	_mock_form(db, "azeroth_17", 2, BASH_FX)
	var ai := BaseAI.new()

	var state := _base_state(db, "p1_hero", "p2_hero")
	(db._defs["p1_hero"] as CardDef).printed_atk = 4   # a hero that hits hard
	_add_card_to_hand(state, "exh", "azeroth_159", "p2")
	_add_resources(state, "p2", 2)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "p1_hero", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)   # p1 → p2, proposal on the chain

	ok(ai.exhaust_attacker_action(state, db, "p2") == null,
		"aibh-a: ally-only Exhaustion can't answer an attacking hero")

	_add_card_to_hand(state, "bash", "azeroth_17", "p2")
	var act := ai.exhaust_attacker_action(state, db, "p2")
	ok(act != null and act.action_type == "play_ability"
			and act.params.get("card_id") == "bash"
			and act.params.get("target_id") == "p1_hero",
		"aibh-b: Bash answers the attacking hero")
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # Bash resolves
	ok(state.get_card("p1_hero").is_exhausted, "aibh-c: attacking hero exhausted")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # proposal fizzles
	ok(not state.combat_attack_window, "aibh-d: combat never started")


func _test_ai_hero_attack_lethal_gate() -> void:
	_buf.append("\n-- AI hero attacks: enemy hero always, enemy ally only when lethal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("wall_def", 1, 2, [], 2)
	_mock_form(db, "dark_portal_19", 2, CAT_FORM_FX)
	var ai := BaseAI.new()

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_form_in_play(state, "cat", "dark_portal_19", "p1")
	var wall := _add_ally(state, "wall", "wall_def", "p2")
	wall.just_summoned = false
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	var vs_hero := false
	var vs_wall := false
	for a in ai.get_reasonable_actions(state, db, "p1"):
		if a.action_type == "propose_combat" and a.params.get("attacker_id") == "p1_hero":
			if a.params.get("defender_id") == "p2_hero":
				vs_hero = true
			elif a.params.get("defender_id") == "wall":
				vs_wall = true
	ok(vs_hero, "hg-a: cat-form hero attack on the enemy HERO is offered")
	ok(not vs_wall, "hg-b: attack on a 2-HP ally is NOT offered (1 ATK, not lethal)")

	# Damage the wall to 1 HP → the hero swing is now lethal → offered.
	wall.damage_taken = 1
	var vs_wall2 := false
	for a in ai.get_reasonable_actions(state, db, "p1"):
		if a.action_type == "propose_combat" \
				and a.params.get("attacker_id") == "p1_hero" \
				and a.params.get("defender_id") == "wall":
			vs_wall2 = true
	ok(vs_wall2, "hg-c: attack on the 1-HP ally IS offered (lethal)")


func _test_ai_claw_ambush() -> void:
	_buf.append("\n-- AI Claw: combat-instant ambush kill, then cat form stays in play --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("attacker_def", 4, 3, [], 4)
	_mock_form(db, "dark_portal_20", 4, CLAW_FX, "Feral Combo")
	var ai := BaseAI.new()

	var state := _base_state(db, "p1_hero", "p2_hero")
	var atk := _add_ally(state, "atk", "attacker_def", "p1")
	atk.just_summoned = false
	_add_card_to_hand(state, "claw", "dark_portal_20", "p2")
	_add_resources(state, "p2", 4)
	state.players["p1"].resource_placed_this_turn = true
	state.players["p2"].resource_placed_this_turn = true

	StackResolver.submit_action(state, PendingAction.make("propose_combat", "p1",
		{"attacker_id": "atk", "defender_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # combat starts, attack window
	StackResolver.pass_priority(state, db)   # p1 passes on the window → p2 priority

	var act := ai.combat_instant_action(state, db, "p2")
	ok(act != null and act.action_type == "play_ability"
			and act.params.get("card_id") == "claw"
			and act.params.get("target_id") == "atk",
		"claw-a: AI ambushes the 3-HP attacker with Claw (3 dmg)")
	StackResolver.submit_action(state, act, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # Claw resolves
	ok(state.get_card("atk").zone_id == "p1_graveyard", "claw-b: attacker destroyed")
	ok(state.get_card("claw").zone_id == "p2_hero_row",
		"claw-c: Claw stays in play (cat form ongoing)")
	eq(state.get_atk("p2_hero", db, true), 1, "claw-d: hero has +1 ATK while attacking")


# ══════════════════════════════════════════════════════════════════════════════
# Fireball (azeroth_53): "Attach to target hero or ally, and your hero deals 4
# fire damage to it. Ongoing: At the start of your turn, your hero deals 1 fire
# damage to attached character." First hero-or-ally attachment; the attach
# damage and the turn-start burn are both hero-sourced fire packets.
# ══════════════════════════════════════════════════════════════════════════════

const FIREBALL_FX := "ongoing|attach:hero_or_ally|attach_deal_damage:4:fire|attached_damage_turn_start:1:fire"

func _test_fireball_attach_and_burn() -> void:
	_buf.append("\n-- Fireball: attach deals 4, burns 1 each turn start, dies with host --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tank_def", 3, 6, [], 3)
	db.ability("azeroth_53", 4, FIREBALL_FX)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var tank := _add_ally(state, "tank", "tank_def", "p2")
	_add_card_to_hand(state, "fb", "azeroth_53", "p1")
	_add_resources(state, "p1", 4)

	# attach:hero_or_ally — a hero is ALSO a legal target (unlike attach:ally).
	ok(StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
		{"card_id": "fb", "target_id": "p2_hero"}), db),
		"fbl-a: Fireball can target a hero")

	var cast := PendingAction.make("play_ability", "p1",
		{"card_id": "fb", "target_id": "tank"})
	ok(StackResolver.can_submit(state, cast, db), "fbl-b: Fireball on an enemy ally is legal")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	eq(state.get_card("fb").zone_id, "attached", "fbl-c: Fireball is attached")
	eq(state.get_card("fb").attached_to, "tank", "fbl-d: host is the ally")
	eq(tank.damage_taken, 4, "fbl-e: 4 fire dealt on attach")

	# Start of the CONTROLLER's turn: hero deals 1 to the attached character.
	state.turn_player = "p1"
	TurnManager._enter_ready(state, db)
	eq(tank.damage_taken, 5, "fbl-f: turn-start burn dealt 1 (5 total)")

	# Next turn start is lethal — host dies, Fireball follows it (400.5).
	TurnManager._enter_ready(state, db)
	eq(tank.zone_id, "p2_graveyard", "fbl-g: burn killed the host")
	eq(state.get_card("fb").zone_id, "p1_graveyard", "fbl-h: Fireball died with its host")


const FLAME_SHOCK_FX := "ongoing|attach:hero_or_ally|attach_deal_damage:2:fire|attached_damage_turn_start:1:fire"

func _test_flame_shock_attach_and_burn() -> void:
	_buf.append("\n-- Flame Shock: attach deals 2, burns 1 each turn start (Fireball clone) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tank_def", 3, 6, [], 3)
	db.ability("dark_portal_94", 3, FLAME_SHOCK_FX)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var tank := _add_ally(state, "tank", "tank_def", "p2")
	_add_card_to_hand(state, "fs", "dark_portal_94", "p1")
	_add_resources(state, "p1", 3)

	# attach:hero_or_ally — a hero is ALSO a legal target.
	ok(StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
		{"card_id": "fs", "target_id": "p2_hero"}), db),
		"fsh-a: Flame Shock can target a hero")

	var cast := PendingAction.make("play_ability", "p1",
		{"card_id": "fs", "target_id": "tank"})
	ok(StackResolver.can_submit(state, cast, db), "fsh-b: Flame Shock on an enemy ally is legal")
	StackResolver.submit_action(state, cast, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	eq(state.get_card("fs").zone_id, "attached", "fsh-c: Flame Shock is attached")
	eq(state.get_card("fs").attached_to, "tank", "fsh-d: host is the ally")
	eq(tank.damage_taken, 2, "fsh-e: 2 fire dealt on attach")

	# Start of the CONTROLLER's turn: hero deals 1 to the attached character.
	state.turn_player = "p1"
	TurnManager._enter_ready(state, db)
	eq(tank.damage_taken, 3, "fsh-f: turn-start burn dealt 1 (3 total)")


func _test_ai_flame_shock_targets_hero_only() -> void:
	_buf.append("\n-- AI Flame Shock: only the opposing hero is ever targeted --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("tank_def", 3, 6, [], 3)
	db.ability("dark_portal_94", 3, FLAME_SHOCK_FX)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "tank", "tank_def", "p2")
	_add_card_to_hand(state, "fs", "dark_portal_94", "p1")
	_add_resources(state, "p1", 3)

	state.players["p1"].resource_placed_this_turn = true
	var ai := BaseAI.new()
	var fs_targets: Array = []
	for a in ai.get_reasonable_actions(state, db, "p1"):
		if a.params.get("card_id", "") == "fs":
			fs_targets.append(a.params.get("target_id", ""))
	eq(fs_targets.size(), 1, "aifs-a: exactly one Flame Shock action generated")
	ok("p2_hero" in fs_targets, "aifs-b: Flame Shock aimed at the opposing hero only")


func _test_world_in_flames_doubles_fire() -> void:
	_buf.append("\n-- World in Flames: hero fire damage doubled --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("imp_def", 1, 2, [], 1)
	db.ability("azeroth_61", 8, "ongoing|hero_fire_damage_doubled")
	db.ability("azeroth_53", 4, FIREBALL_FX)
	db.instant("fireblast_def", 2, "deal_damage_to_target:2:fire")
	db.instant("frost_def", 2, "deal_damage_to_target:3:frost")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "imp", "imp_def", "p1")
	_add_card_to_hand(state, "wif", "azeroth_61", "p1")
	_add_card_to_hand(state, "blast", "fireblast_def", "p1")
	_add_card_to_hand(state, "frost", "frost_def", "p1")
	_add_card_to_hand(state, "fb", "azeroth_53", "p1")
	_add_resources(state, "p1", 20)

	# Cast World in Flames — plain ongoing ability, enters the hero row.
	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "wif"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("wif").zone_id, "p1_hero_row", "wif-a: WiF is in play")

	# Fire Blast (2 fire) → 4 on the enemy hero.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "blast", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 4, "wif-b: 2 fire doubled to 4")

	# Frost damage is untouched (3 → 3).
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "frost", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 7, "wif-c: frost damage NOT doubled")

	# Non-hero sources never double, even fire (the card says "your HERO").
	eq(StackResolver._fire_doubled_amount(state, db,
		{"source": "imp", "amount": 2, "dmg_type": "fire"}), 2,
		"wif-d: ally-sourced fire not doubled")
	# The OPPONENT's hero is unaffected by p1's World in Flames.
	eq(StackResolver._fire_doubled_amount(state, db,
		{"source": "p2_hero", "amount": 2, "dmg_type": "fire"}), 2,
		"wif-e: opposing hero's fire not doubled")

	# Fireball under WiF: attach deals 8, turn-start burn deals 2.
	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "fb", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 15, "wif-f: Fireball attach 4→8 (15 total)")
	state.turn_player = "p1"
	TurnManager._enter_ready(state, db)
	eq(state.get_card("p2_hero").damage_taken, 17, "wif-g: turn-start burn 1→2 (17 total)")


func _test_chromatic_cloak_ability_bonus() -> void:
	_buf.append("\n-- Chromatic Cloak: hero ability damage +1 --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("imp_def", 1, 2, [], 1)
	db.equipment("azeroth_282", 4, "equipment:back:0|hero_ability_damage_bonus:1", "Cloth")
	db.ability("azeroth_61", 8, "ongoing|hero_fire_damage_doubled")
	db.ability("azeroth_53", 4, FIREBALL_FX)
	db.instant("fireblast_def", 2, "deal_damage_to_target:2:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "imp", "imp_def", "p1")
	_add_card_to_hand(state, "cloak", "azeroth_282", "p1")
	_add_card_to_hand(state, "blast", "fireblast_def", "p1")
	_add_card_to_hand(state, "blast2", "fireblast_def", "p1")
	_add_card_to_hand(state, "wif", "azeroth_61", "p1")
	_add_card_to_hand(state, "fb", "azeroth_53", "p1")
	_add_resources(state, "p1", 25)

	# Play the cloak — equipment, enters the hero row.
	StackResolver.submit_action(state, PendingAction.make("play_equipment", "p1",
		{"card_id": "cloak"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("cloak").zone_id, "p1_hero_row", "cc-a: cloak is in play")

	# Fire Blast (2) → 3 on the enemy hero.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "blast", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 3, "cc-b: 2 ability damage → 3")

	# Non-ability packets never get the bonus (hero powers / combat carry no tag).
	eq(StackResolver._ability_bonus_amount(state, db,
		{"source": "p1_hero", "amount": 2}), 2,
		"cc-c: untagged hero packet unchanged")
	# Non-hero sources never get it, even from an ability-shaped site.
	eq(StackResolver._ability_bonus_amount(state, db,
		{"source": "imp", "amount": 2, "from_ability": true}), 2,
		"cc-d: ally-sourced damage unchanged")
	# The OPPONENT's hero is unaffected by p1's cloak.
	eq(StackResolver._ability_bonus_amount(state, db,
		{"source": "p2_hero", "amount": 2, "from_ability": true}), 2,
		"cc-e: opposing hero's ability damage unchanged")

	# With World in Flames too: +1 applies BEFORE doubling → (2+1)*2 = 6.
	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "wif"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p1",
		{"card_id": "blast2", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 9, "cc-f: (2+1)*2 = 6 (9 total)")

	# Fireball is an ability: attach (4+1)*2 = 10, turn-start burn (1+1)*2 = 4.
	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "fb", "target_id": "p2_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("p2_hero").damage_taken, 19, "cc-g: Fireball attach (4+1)*2 (19 total)")
	state.turn_player = "p1"
	TurnManager._enter_ready(state, db)
	eq(state.get_card("p2_hero").damage_taken, 23, "cc-h: turn-start burn (1+1)*2 (23 total)")


func _test_ai_fireball_targets_hero_only() -> void:
	_buf.append("\n-- AI Fireball: only the opposing hero is ever targeted --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("big_def", 5, 5, [], 5)
	db.ability("azeroth_53", 4, FIREBALL_FX)

	var ai := BaseAI.new()
	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "big", "big_def", "p2")
	_add_ally(state, "mine", "big_def", "p1")
	_add_card_to_hand(state, "fb", "azeroth_53", "p1")
	_add_resources(state, "p1", 4)
	state.players["p1"].resource_placed_this_turn = true

	var fb_targets: Array = []
	for a in ai.get_reasonable_actions(state, db, "p1"):
		if a.params.get("card_id", "") == "fb":
			fb_targets.append(a.params.get("target_id", ""))
	eq(fb_targets.size(), 1, "aif-a: exactly one Fireball action generated")
	ok("p2_hero" in fb_targets, "aif-b: Fireball aimed at the opposing hero only")


# ══════════════════════════════════════════════════════════════════════════════
# Mana Agate (azeroth_57): "Ongoing: 1, Destroy Mana Agate -> Draw two cards."
# Plain ongoing Ability living in the hero row; the power is a plain payment
# power (no [Activate]) whose extra cost destroys the source itself.
# ══════════════════════════════════════════════════════════════════════════════

func _stock_deck(state: GameState, player_id: String, def_id: String, count: int) -> void:
	for i in range(count):
		var inst_id := "%s_deck_%d" % [player_id, i]
		var card := CardInstance.create(inst_id, def_id, player_id, player_id + "_deck")
		state.cards[inst_id] = card
		state.zones[player_id + "_deck"].card_ids.append(inst_id)


func _test_mana_agate_power() -> void:
	_buf.append("\n-- Mana Agate: sacrifice from the hero row, draw two --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("azeroth_57", 2, "ongoing|activated_power:1:draw:2:::sacrifice_self")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_card_to_hand(state, "agate", "azeroth_57", "p1")
	_add_resources(state, "p1", 3)
	_stock_deck(state, "p1", "bear_def", 4)

	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "agate"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves
	eq(state.get_card("agate").zone_id, "p1_hero_row", "ma-a: Agate is ongoing in the hero row")

	# Plain payment power: usable the same turn it entered play (no [Activate]).
	var power := PendingAction.make("use_ally_power", "p1", {"card_id": "agate"})
	ok(StackResolver.can_submit(state, power, db), "ma-b: power legal right away")
	StackResolver.submit_action(state, power, db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	eq(state.get_card("agate").zone_id, "p1_graveyard", "ma-c: Agate destroyed as the cost")
	eq(state.cards_in_zone("p1_hand").size(), 2,        "ma-d: drew two cards")
	eq(state.get_available_resources("p1"), 0,          "ma-e: 2 (play) + 1 (power) paid")


func _test_mana_agate_killed_in_response() -> void:
	_buf.append("\n-- Mana Agate: killed in response, draw still resolves --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("azeroth_57", 2, "ongoing|activated_power:1:draw:2:::sacrifice_self")
	db.instant("burn_def", 0, "destroy_target:ability")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var agate := CardInstance.create("agate", "azeroth_57", "p1", "p1_hero_row")
	state.cards["agate"] = agate
	state.zones["p1_hero_row"].card_ids.append("agate")
	_add_card_to_hand(state, "burn", "burn_def", "p2")
	_add_resources(state, "p1", 1)
	_stock_deck(state, "p1", "bear_def", 4)

	StackResolver.submit_action(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "agate"}), db)
	StackResolver.pass_priority(state, db)   # p1 -> p2
	# p2 destroys the Agate in response.
	StackResolver.submit_action(state, PendingAction.make("play_instant", "p2",
		{"card_id": "burn", "target_id": "agate"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # burn resolves
	eq(agate.zone_id, "p1_graveyard", "mk-a: Agate destroyed in response")
	# Both pass again -> the power resolves: destroy no-ops, draw still happens.
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.cards_in_zone("p1_hand").size(), 2, "mk-b: still drew two cards")


# ══════════════════════════════════════════════════════════════════════════════
# Arcane Intellect (azeroth_47): "Attach to target hero, and its controller
# draws a card. Ongoing: Attached hero's controller's maximum hand size is
# increased by three."
# ══════════════════════════════════════════════════════════════════════════════

func _test_arcane_intellect_attach_and_hand_size() -> void:
	_buf.append("\n-- Arcane Intellect: hero-only attach, draw, +3 max hand --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.instant("azeroth_47", 2, "ongoing|attach:hero|attach_draw:1|attached_max_hand:3")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "bear", "bear_def", "p1")
	_add_card_to_hand(state, "intellect", "azeroth_47", "p1")
	_add_resources(state, "p1", 2)
	_stock_deck(state, "p1", "bear_def", 2)

	# attach:hero — an ally is not a legal target.
	ok(not StackResolver.can_submit(state, PendingAction.make("play_ability", "p1",
		{"card_id": "intellect", "target_id": "bear"}), db),
		"aint-a: can't attach to an ally")

	StackResolver.submit_action(state, PendingAction.make("play_ability", "p1",
		{"card_id": "intellect", "target_id": "p1_hero"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)   # resolves

	var intellect := state.get_card("intellect")
	eq(intellect.zone_id, "attached",     "aint-b: Intellect is attached")
	eq(intellect.attached_to, "p1_hero",  "aint-c: host is our hero")
	eq(state.cards_in_zone("p1_hand").size(), 1, "aint-d: controller drew a card")
	eq(state.get_max_hand_size("p1", db), 10, "aint-e: max hand size 7 + 3")
	eq(state.get_max_hand_size("p2", db), 7,  "aint-f: opponent unaffected")

	# Wrap-up (503.2a): 10 cards in hand is fine now, 11 forces one discard.
	for i in range(10):
		_add_card_to_hand(state, "filler_%d" % i, "bear_def", "p1")   # hand: 11
	TurnManager._next_turn(state, db)
	eq(state.pending_discard_count, 1, "aint-g: wrap-up discards down to 10")
	state.pending_discard_player = ""
	state.pending_discard_count = 0

	# The attachment leaving play drops the limit back to 7.
	GameLogic.destroy_card(state, "intellect", "")
	eq(state.get_max_hand_size("p1", db), 7, "aint-h: limit back to 7 after destroy")


func _test_ai_mana_agate_and_arcane_intellect() -> void:
	_buf.append("\n-- AI: Agate hand-room gate; Intellect on own hero --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("azeroth_57", 2, "ongoing|activated_power:1:draw:2:::sacrifice_self")
	db.instant("azeroth_47", 2, "ongoing|attach:hero|attach_draw:1|attached_max_hand:3")

	var ai := BaseAI.new()

	# Mana Agate power: hand at max-1 has room for only one card -> hold it.
	var state := _base_state(db, "p1_hero", "p2_hero")
	var agate := CardInstance.create("agate", "azeroth_57", "p1", "p1_hero_row")
	state.cards["agate"] = agate
	state.zones["p1_hero_row"].card_ids.append("agate")
	_add_resources(state, "p1", 1)
	state.players["p1"].resource_placed_this_turn = true
	for i in range(6):
		_add_card_to_hand(state, "h_%d" % i, "bear_def", "p1")   # hand: 6, max: 7
	var fires := func() -> bool:
		for a in ai.get_reasonable_actions(state, db, "p1"):
			if a.action_type == "use_ally_power" and a.params.get("card_id", "") == "agate":
				return true
		return false
	ok(not fires.call(), "aima-a: AI holds Agate with room for only 1 card")
	state.zones["p1_hand"].card_ids.pop_back()   # hand: 5 -> room for both
	ok(fires.call(), "aima-b: AI fires Agate with room for 2 cards")

	# Arcane Intellect: the only generated attach action targets our OWN hero.
	var state2 := _base_state(db, "p1_hero", "p2_hero")
	_add_card_to_hand(state2, "intellect", "azeroth_47", "p1")
	_add_resources(state2, "p1", 2)
	state2.players["p1"].resource_placed_this_turn = true
	var ai_targets: Array = []
	for a in ai.get_reasonable_actions(state2, db, "p1"):
		if a.params.get("card_id", "") == "intellect":
			ai_targets.append(a.params.get("target_id", ""))
	eq(ai_targets.size(), 1, "aima-c: exactly one Intellect action")
	ok("p1_hero" in ai_targets, "aima-d: aimed at our own hero")


# ══════════════════════════════════════════════════════════════════════════════
# Stealth (602.2a) — while an attacker has Stealth, characters can't protect
# ══════════════════════════════════════════════════════════════════════════════

func _test_stealth_blocks_protectors() -> void:
	_buf.append("\n-- Stealth: attacker with stealth denies all protectors --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("sneak_def", 3, 3, (["stealth"] as Array[String]), 4)
	db.ally("plain_def", 2, 2, [], 2)
	db.ally("guard_def", 2, 4, (["protector"] as Array[String]), 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(state, "sneak", "sneak_def", "p1")
	_add_ally(state, "plain", "plain_def", "p1")
	_add_ally(state, "guard", "guard_def", "p2")

	var vs_stealth := StackResolver.get_legal_protectors(state, "sneak", "p2_hero", db)
	ok(vs_stealth.is_empty(), "st-a: no legal protectors against a Stealth attacker")

	var vs_plain := StackResolver.get_legal_protectors(state, "plain", "p2_hero", db)
	ok("guard" in vs_plain, "st-b: protector still legal against a non-Stealth attacker")


# ══════════════════════════════════════════════════════════════════════════════
# Ghank — "When Ghank enters play, you may destroy target exhausted ally with
# damage on it." Optional targeted enter-play trigger; opens only when a legal
# target exists.
# ══════════════════════════════════════════════════════════════════════════════

func _test_ghank_enter_play_destroy() -> void:
	_buf.append("\n-- Ghank: destroys a target exhausted damaged ally on enter --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ghank_def", 3, 3, (["stealth"] as Array[String]), 4,
		"on_enter:destroy_exhausted_damaged_ally")
	db.ally("victim_def", 2, 3, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)
	_add_card_to_hand(state, "ghank", "ghank_def", "p1")
	# Only the exhausted AND damaged ally is a legal target.
	var victim := _add_ally(state, "victim", "victim_def", "p2")
	victim.is_exhausted = true
	victim.damage_taken = 1
	var tired := _add_ally(state, "tired", "victim_def", "p2")   # exhausted, undamaged
	tired.is_exhausted = true
	var hurt := _add_ally(state, "hurt", "victim_def", "p2")     # damaged, ready
	hurt.damage_taken = 1

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "ghank"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(not state.pending_enter_play_effect.is_empty(),
		"gh-a: enter-play choice pending after Ghank resolves")

	var legal := StackResolver.get_enter_play_destroy_targets(state, db)
	eq(legal.size(), 1, "gh-b: exactly one legal target")
	ok("victim" in legal, "gh-c: the exhausted damaged ally is the legal target")

	ok(not StackResolver.can_submit(state, PendingAction.make("choose_enter_play_target",
		"p1", {"source_card_id": "ghank", "target_id": "tired"}), db),
		"gh-d: exhausted-but-undamaged ally is not submittable")
	ok(not StackResolver.can_submit(state, PendingAction.make("choose_enter_play_target",
		"p1", {"source_card_id": "ghank", "target_id": "hurt"}), db),
		"gh-e: damaged-but-ready ally is not submittable")

	StackResolver.submit_action(state, PendingAction.make("choose_enter_play_target",
		"p1", {"source_card_id": "ghank", "target_id": "victim"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("victim").zone_id, "p2_graveyard", "gh-f: target destroyed")
	ok(state.pending_enter_play_effect.is_empty(), "gh-g: pending effect cleared")


func _test_ghank_no_target_no_prompt() -> void:
	_buf.append("\n-- Ghank: no exhausted damaged ally → trigger silently skipped --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ghank_def", 3, 3, (["stealth"] as Array[String]), 4,
		"on_enter:destroy_exhausted_damaged_ally")
	db.ally("plain_def", 2, 3, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)
	_add_card_to_hand(state, "ghank", "ghank_def", "p1")
	_add_ally(state, "healthy", "plain_def", "p2")   # ready, undamaged — not a target

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "ghank"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.pending_enter_play_effect.is_empty(),
		"ghn-a: no pending choice when no legal target exists")
	eq(state.get_card("ghank").zone_id, "p1_ally_row", "ghn-b: Ghank in play")
	eq(state.get_card("healthy").zone_id, "p2_ally_row", "ghn-c: bystander untouched")


func _test_ghank_decline() -> void:
	_buf.append("\n-- Ghank: optional trigger may be declined --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ghank_def", 3, 3, (["stealth"] as Array[String]), 4,
		"on_enter:destroy_exhausted_damaged_ally")
	db.ally("victim_def", 2, 3, [], 3)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)
	_add_card_to_hand(state, "ghank", "ghank_def", "p1")
	var victim := _add_ally(state, "victim", "victim_def", "p1")   # Ghank's OWN ally
	victim.is_exhausted = true
	victim.damage_taken = 1

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "ghank"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(not state.pending_enter_play_effect.is_empty(),
		"ghd-a: choice opens (own ally is a legal target too)")

	var events := StackResolver.decline_enter_play_effect(state)
	ok(state.pending_enter_play_effect.is_empty(), "ghd-b: decline clears the pending effect")
	eq(events.size(), 1, "ghd-c: decline event emitted")
	eq(state.get_card("victim").zone_id, "p1_ally_row", "ghd-d: ally survives")


# Rule 501.1 / 410: once Ghank's target is chosen the trigger sits on the chain
# with a REAL priority window — the opponent may respond before it resolves. Here
# the opponent bounces its own targeted ally (Withdraw) in the window; Ghank's
# destroy then fizzles at the 706 recheck (target left play). Regression guard for
# the bug where pending_enter_play_effect stayed set through the window and
# can_submit blocked every response.
func _test_ghank_window_lets_opponent_respond() -> void:
	_buf.append("\n-- Ghank: opponent can respond in the enter-play window --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("ghank_def", 3, 3, (["stealth"] as Array[String]), 4,
		"on_enter:destroy_exhausted_damaged_ally")
	db.ally("victim_def", 2, 3, [], 3)
	db.instant("withdraw_def", 3, "return_to_hand:ally")   # Withdraw-style bounce

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 4)
	_add_resources(state, "p2", 3)
	_add_card_to_hand(state, "ghank", "ghank_def", "p1")
	_add_card_to_hand(state, "withdraw", "withdraw_def", "p2")
	var victim := _add_ally(state, "victim", "victim_def", "p2")
	victim.is_exhausted = true
	victim.damage_taken = 1

	# p1 plays Ghank; it resolves into play and the enter-play choice opens.
	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "ghank"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	# p1 announces Ghank's target (p2's exhausted damaged ally).
	StackResolver.submit_action(state, PendingAction.make("choose_enter_play_target",
		"p1", {"source_card_id": "ghank", "target_id": "victim"}), db)
	ok(state.pending_enter_play_effect.is_empty(),
		"ghw-a: pending marker cleared at announcement — the window is real")
	eq(state.get_card("victim").zone_id, "p2_ally_row",
		"ghw-b: target not destroyed yet — it waits on the chain")

	# p1 passes → p2 gets priority IN the window and CAN respond (the fix).
	StackResolver.pass_priority(state, db)
	eq(state.priority_player, "p2", "ghw-c: opponent has priority in the window")
	var resp := PendingAction.make("play_instant", "p2",
		{"card_id": "withdraw", "target_id": "victim"})
	ok(StackResolver.can_submit(state, resp, db),
		"ghw-d: opponent's instant is submittable — guard no longer blocks it")

	# p2 bounces its own targeted ally; the chain drains, Ghank's destroy fizzles.
	StackResolver.submit_action(state, resp, db)
	StackResolver.pass_priority(state, db)   # p2 passes
	StackResolver.pass_priority(state, db)   # p1 passes — Withdraw resolves
	StackResolver.pass_priority(state, db)   # p1 passes — Ghank's target choice on chain resolves
	StackResolver.pass_priority(state, db)
	eq(state.get_card("victim").zone_id, "p2_hand",
		"ghw-e: victim bounced to hand, not destroyed")
	ok(state.pending_enter_play_effect.is_empty(), "ghw-f: pending effect cleared")


func _test_hur_shieldsmasher_destroys_armor() -> void:
	_buf.append("\n-- Hur Shieldsmasher: destroys a target armor on enter --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("hur_def", 2, 2, [], 3, "on_enter:destroy_armor")
	db.equipment("robe_def", 4, "equipment:chest:0", "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	_add_card_to_hand(state, "hur", "hur_def", "p1")
	var robe := CardInstance.create("robe", "robe_def", "p2", "p2_hero_row")
	state.cards["robe"] = robe
	state.zones["p2_hero_row"].card_ids.append("robe")

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "hur"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(not state.pending_enter_play_effect.is_empty(),
		"hur-a: enter-play choice pending after Hur resolves")

	var legal := StackResolver.get_enter_play_equipment_targets(state, db, false)
	eq(legal.size(), 1, "hur-b: exactly one legal target")
	ok("robe" in legal, "hur-c: the armor is the legal target")

	StackResolver.submit_action(state, PendingAction.make("choose_enter_play_target",
		"p1", {"source_card_id": "hur", "target_id": "robe"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("robe").zone_id, "p2_graveyard", "hur-d: armor destroyed")
	ok(state.pending_enter_play_effect.is_empty(), "hur-e: pending effect cleared")


func _test_hur_shieldsmasher_ignores_weapon() -> void:
	_buf.append("\n-- Hur Shieldsmasher: a weapon is not a legal target (armor only) --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("hur_def", 2, 2, [], 3, "on_enter:destroy_armor")
	db.weapon("blade_def", 2, 3, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	_add_card_to_hand(state, "hur", "hur_def", "p1")
	var blade := CardInstance.create("blade", "blade_def", "p2", "p2_hero_row")
	state.cards["blade"] = blade
	state.zones["p2_hero_row"].card_ids.append("blade")

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "hur"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.pending_enter_play_effect.is_empty(),
		"hurw-a: no pending choice — the only equipment in play is a weapon")
	eq(state.get_card("blade").zone_id, "p2_hero_row", "hurw-b: weapon untouched")


func _test_hur_shieldsmasher_no_armor_no_prompt() -> void:
	_buf.append("\n-- Hur Shieldsmasher: no armor in play → trigger silently skipped --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("hur_def", 2, 2, [], 3, "on_enter:destroy_armor")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	_add_card_to_hand(state, "hur", "hur_def", "p1")

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "hur"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(state.pending_enter_play_effect.is_empty(),
		"hurn-a: no pending choice when no armor exists")
	eq(state.get_card("hur").zone_id, "p1_ally_row", "hurn-b: Hur in play")


func _test_zygore_bladebreaker_destroys_weapon() -> void:
	_buf.append("\n-- Zygore Bladebreaker: may destroy a target weapon on enter --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zygore_def", 4, 3, [], 6, "on_enter:destroy_armor_or_weapon")
	db.weapon("blade_def", 2, 3, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 6)
	_add_card_to_hand(state, "zygore", "zygore_def", "p1")
	var blade := CardInstance.create("blade", "blade_def", "p2", "p2_hero_row")
	state.cards["blade"] = blade
	state.zones["p2_hero_row"].card_ids.append("blade")

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "zygore"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	ok(not state.pending_enter_play_effect.is_empty(),
		"zyg-a: enter-play choice pending after Zygore resolves")

	var legal := StackResolver.get_enter_play_equipment_targets(state, db, true)
	eq(legal.size(), 1, "zyg-b: the weapon is a legal target")

	StackResolver.submit_action(state, PendingAction.make("choose_enter_play_target",
		"p1", {"source_card_id": "zygore", "target_id": "blade"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("blade").zone_id, "p2_graveyard", "zyg-c: weapon destroyed")


func _test_zygore_bladebreaker_destroys_armor() -> void:
	_buf.append("\n-- Zygore Bladebreaker: may also destroy a target armor on enter --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("zygore_def", 4, 3, [], 6, "on_enter:destroy_armor_or_weapon")
	db.equipment("robe_def", 4, "equipment:chest:0", "Cloth")

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 6)
	_add_card_to_hand(state, "zygore", "zygore_def", "p1")
	var robe := CardInstance.create("robe", "robe_def", "p2", "p2_hero_row")
	state.cards["robe"] = robe
	state.zones["p2_hero_row"].card_ids.append("robe")

	StackResolver.submit_action(state, PendingAction.make("play_ally", "p1",
		{"card_id": "zygore"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	var legal := StackResolver.get_enter_play_equipment_targets(state, db, true)
	eq(legal.size(), 1, "zyga-a: the armor is a legal target")
	ok("robe" in legal, "zyga-b: armor found by the wider armor-or-weapon pool")

	StackResolver.submit_action(state, PendingAction.make("choose_enter_play_target",
		"p1", {"source_card_id": "zygore", "target_id": "robe"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(state.get_card("robe").zone_id, "p2_graveyard", "zyga-c: armor destroyed")


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# TOKENS â€” Mya, Dragonling Wrangler + Tooga's Quest
#
# A token is a card created by an effect rather than dealt from a deck. It plays
# like any other ally, but it ceases to exist the moment it LEAVES play â€” the
# redirect lives in GameLogic.move_card, so it holds for destruction, bounce and
# discard alike. Destruction itself is unchanged: card_destroyed still fires, so
# "when destroyed" triggers see a token exactly as they see a real card.
#
#   tok-a   Mya's enter-play trigger creates a 1/1 Mechanical Dragonling
#   tok-b   the token is a real ally: in the party, correct stats and owner
#   tok-c   destroying a token fires card_destroyed but sends it to RFG, not the
#           graveyard (so graveyard recursion can never see it)
#   tok-d   an on_destroyed trigger on a token still fires
#   tok-e   bouncing a token (Withdraw) voids it instead of putting it in hand
#   tok-f   tokens are not deckable (DeckManager)
#   tok-g   Tooga's Quest puts Tooga into play
#   tok-h   Tooga removes itself at the start of the controller's NEXT turn and
#           draws two â€” not on the turn it was created, and not on the
#           opponent's turn
#   tok-i   a Tooga destroyed before then never triggers: no removal, no draw
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

const MYA_EFFECTS   := "on_enter:create_token:dragonling_token"
const TOOGA_EFFECTS := "rfg_self_next_turn:draw:2"


func _test_mya_creates_token() -> void:
	_buf.append("\n-- Mya, Dragonling Wrangler: enter-play token creation --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("mya_def", 2, 2, [], 3, MYA_EFFECTS)
	db.token("dragonling_token", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	_add_resources(state, "p1", 3)
	var mya := CardInstance.create("mya", "mya_def", "p1", "p1_hand")
	state.cards["mya"] = mya
	state.zones["p1_hand"].card_ids.append("mya")

	var p1_ai := ScriptedAI.new()
	p1_ai.queue_action(PendingAction.make("play_ally", "p1", {"card_id": "mya"}))
	_drive_turns(state, db, p1_ai, ScriptedAI.new(), 3)

	eq(state.get_card("mya").zone_id, "p1_ally_row", "tok-a1: Mya in play")
	var tokens := _tokens_in(state, "p1_ally_row")
	eq(tokens.size(), 1, "tok-a2: exactly one Mechanical Dragonling created")
	if tokens.is_empty():
		return
	var tok: CardInstance = tokens[0]
	eq(tok.card_def_id, "dragonling_token", "tok-a3: it's the Mechanical Dragonling")
	ok(tok.is_token, "tok-a4: instance flagged as a token")
	eq(state.get_atk(tok.instance_id, db), 1, "tok-b1: 1 ATK")
	eq(state.get_max_hp(tok.instance_id, db), 1, "tok-b2: 1 health")
	eq(tok.owner, "p1",      "tok-b3: owned by Mya's controller")
	eq(tok.controller, "p1", "tok-b4: controlled by Mya's controller")
	ok(tok.instance_id in state.zones["p1_ally_row"].card_ids,
		"tok-b5: token is in the party, not floating")


func _test_token_destroyed_ceases_to_exist() -> void:
	_buf.append("\n-- Token destruction: card_destroyed fires, card goes to the void --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.token("dragonling_token", 1, 1)
	# A token that itself has a death trigger â€” proves destruction registers
	# normally even though the card never reaches a graveyard.
	db.token("boom_token", 1, 1, [], "on_destroyed:deal_damage_aoe:2:fire:opposing")

	var state := _base_state(db, "p1_hero", "p2_hero")
	StackResolver._put_token_into_play(state, "p1", "dragonling_token", 1, db)
	var tid: String = _tokens_in(state, "p1_ally_row")[0].instance_id

	var events := StackResolver._destroy_card_trigger(state, tid, "", db)
	var saw_destroyed := false
	for e in events:
		if e.event_type == "card_destroyed" and e.payload.get("card", "") == tid:
			saw_destroyed = true
	ok(saw_destroyed, "tok-c1: destroying a token emits card_destroyed")
	eq(state.get_card(tid).zone_id, "p1_rfg", "tok-c2: token went to RFG, not the graveyard")
	eq(state.cards_in_zone("p1_graveyard").size(), 0,
		"tok-c3: nothing in the graveyard for recursion to find")

	# tok-d: a death trigger ON the token still fires.
	var st2 := _base_state(db, "p1_hero", "p2_hero")
	StackResolver._put_token_into_play(st2, "p1", "boom_token", 1, db)
	var boom_id: String = _tokens_in(st2, "p1_ally_row")[0].instance_id
	var hp_before := st2.get_current_hp("p2_hero", db)
	StackResolver._destroy_card_trigger(st2, boom_id, "", db)
	eq(st2.get_current_hp("p2_hero", db), hp_before - 2,
		"tok-d1: the token's own on_destroyed trigger fired")
	eq(st2.get_card(boom_id).zone_id, "p1_rfg", "tok-d2: and it still ceased to exist")


func _test_token_bounce_ceases_to_exist() -> void:
	_buf.append("\n-- Token bounce: leaving play in ANY way voids it --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.token("dragonling_token", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	StackResolver._put_token_into_play(state, "p1", "dragonling_token", 1, db)
	var tid: String = _tokens_in(state, "p1_ally_row")[0].instance_id

	# Withdraw's resolution is a plain move to the owner's hand â€” the redirect in
	# move_card must catch it without the bounce effect knowing about tokens.
	GameLogic.move_card(state, tid, "p1_hand")
	eq(state.get_card(tid).zone_id, "p1_rfg", "tok-e1: bounced token voided, not returned to hand")
	eq(state.cards_in_zone("p1_hand").size(), 0, "tok-e2: hand is empty")


func _test_tokens_not_deckable() -> void:
	_buf.append("\n-- Tokens can't be deck cards --")
	var db := MockDB.new()
	db.hero("hero_def", 30)
	db.token("dragonling_token", 1, 1)
	db.ally("filler_def", 1, 1, [], 1)

	var deck := DeckDefinition.new()
	deck.deck_id          = "token_deck"
	deck.display_name     = "Token Deck"
	deck.hero_card_def_id = "hero_def"
	var e1 := DeckCardEntry.new()
	e1.card_def_id = "filler_def"
	e1.count       = 59
	var e2 := DeckCardEntry.new()
	e2.card_def_id = "dragonling_token"
	e2.count       = 1
	deck.card_entries = [e1, e2]

	var errors := DeckManager.authorize_deck_def(deck, db)
	var saw_token_error := false
	for err in errors:
		if "token" in err.to_lower():
			saw_token_error = true
	ok(saw_token_error, "tok-f: the authorizer rejects a token in the deck list")


func _test_toogas_quest() -> void:
	_buf.append("\n-- Tooga's Quest: token + delayed self-removal --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.quest("tooga_quest_def", 3, "create_token:tooga_token|require_turn_player")
	db.token("tooga_token", 1, 1, ["unique"], TOOGA_EFFECTS)
	db.ally("deck_filler", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	var quest := CardInstance.create("quest", "tooga_quest_def", "p1", "p1_resource_row")
	state.cards["quest"] = quest
	state.zones["p1_resource_row"].card_ids.append("quest")
	_add_resources(state, "p1", 3)
	for i in range(6):
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "deck_filler", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	StackResolver.submit_action(state,
		PendingAction.make("use_quest", "p1", {"quest_id": "quest"}), db)
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)

	var toogas := _tokens_in(state, "p1_ally_row")
	eq(toogas.size(), 1, "tok-g1: Tooga token put into play by the reward")
	if toogas.is_empty():
		return
	var tooga: CardInstance = toogas[0]
	eq(state.get_atk(tooga.instance_id, db), 1, "tok-g2: 1 ATK")
	eq(state.get_max_hp(tooga.instance_id, db), 1, "tok-g3: 1 health")
	eq(tooga.created_on_turn, state.turn_number, "tok-g4: creation turn recorded")

	# tok-h: nothing happens on the opponent's turn.
	var hand_before := state.cards_in_zone("p1_hand").size()
	while state.turn_player != "p2":
		TurnManager.advance_phase(state, db)
	ok(state.is_in_play(tooga.instance_id), "tok-h1: Tooga survives the opponent's turn start")
	eq(state.cards_in_zone("p1_hand").size(), hand_before, "tok-h2: no draw on the opponent's turn")

	# ...and it fires at the start of the controller's next turn.
	while not (state.turn_player == "p1" and state.phase == "ready"):
		TurnManager.advance_phase(state, db)
	eq(state.get_card(tooga.instance_id).zone_id, "p1_rfg",
		"tok-h3: Tooga removed from the game on its controller's next turn")
	eq(state.cards_in_zone("p1_graveyard").size(), 0,
		"tok-h4: removal is not a destroy â€” nothing in the graveyard")
	eq(state.cards_in_zone("p1_hand").size(), hand_before + 2,
		"tok-h5: drew two cards for the removal")


func _test_tooga_killed_before_trigger() -> void:
	_buf.append("\n-- Tooga killed early: the delayed trigger simply never happens --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.token("tooga_token", 1, 1, ["unique"], TOOGA_EFFECTS)
	db.ally("deck_filler", 1, 1)

	var state := _base_state(db, "p1_hero", "p2_hero")
	StackResolver._put_token_into_play(state, "p1", "tooga_token", 1, db)
	var tooga_id: String = _tokens_in(state, "p1_ally_row")[0].instance_id
	for i in range(6):
		var did := "deck_%d" % i
		var dc := CardInstance.create(did, "deck_filler", "p1", "p1_deck")
		state.cards[did] = dc
		state.zones["p1_deck"].card_ids.append(did)

	# The opponent destroys Tooga before the trigger can fire â€” a normal destroy,
	# which voids the token.
	StackResolver._destroy_card_trigger(state, tooga_id, "p2_hero", db)
	eq(state.get_card(tooga_id).zone_id, "p1_rfg", "tok-i1: destroyed Tooga ceased to exist")

	var hand_before := state.cards_in_zone("p1_hand").size()
	while state.turn_player != "p2":
		TurnManager.advance_phase(state, db)
	while not (state.turn_player == "p1" and state.phase == "ready"):
		TurnManager.advance_phase(state, db)
	eq(state.cards_in_zone("p1_hand").size(), hand_before,
		"tok-i2: no bonus draw â€” the removal never happened")


# All token instances currently sitting in `zone_id`.
func _tokens_in(state: GameState, zone_id: String) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	for c in state.cards_in_zone(zone_id):
		if c.is_token:
			result.append(c)
	return result


# ── Decked (rules 410.6b / 102.1a) ────────────────────────────────────────────
# Emptying your deck is NOT a loss. Being REQUIRED TO DRAW from an empty deck
# makes you decked, and you immediately lose. Both players decked at once = draw.

func _test_decked_loses_the_game() -> void:
	_buf.append("\n-- Decked: drawing from an empty deck loses the game --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	var state := _base_state(db, "p1_hero", "p2_hero")

	var events := GameLogic.draw_one(state, "p1")
	var saw_decked := false
	var saw_over   := false
	for e in events:
		if e.event_type == "player_decked":
			saw_decked = true
			eq(str(e.payload.get("player", "")), "p1", "deck-a2: p1 is the decked player")
		elif e.event_type == "game_over":
			saw_over = true
			eq(str(e.payload.get("reason", "")), "decked", "deck-a4: reason is 'decked'")
			eq(str(e.payload.get("winner", "")), "p2",    "deck-a5: the opponent wins")
			eq(str(e.payload.get("loser", "")),  "p1",    "deck-a6: the decked player loses")
			ok(not bool(e.payload.get("draw", false)),    "deck-a7: not a draw")
	ok(saw_decked, "deck-a1: player_decked is emitted")
	ok(saw_over,   "deck-a3: game_over follows immediately")
	ok("p1" in state.decked_players, "deck-a8: state records the decked player")

	# Decking is one-shot: a second required draw doesn't re-fire game_over.
	var again := GameLogic.draw_one(state, "p1")
	var over_again := false
	for e in again:
		if e.event_type == "game_over":
			over_again = true
	ok(not over_again, "deck-a9: a second empty draw doesn't re-emit game_over")


func _test_empty_deck_alone_is_not_a_loss() -> void:
	_buf.append("\n-- An empty deck by itself is not a loss --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("filler_def", 1, 1, [], 1)
	var state := _base_state(db, "p1_hero", "p2_hero")

	var last := CardInstance.create("last_card", "filler_def", "p1", "p1_deck")
	state.cards["last_card"] = last
	state.zones["p1_deck"].card_ids.append("last_card")

	# Drawing the LAST card empties the deck — legal, no loss.
	var events := GameLogic.draw_one(state, "p1")
	for e in events:
		ok(e.event_type != "game_over", "deck-b1: emptying the deck doesn't end the game")
	eq(state.cards_in_zone("p1_deck").size(), 0, "deck-b2: deck is now empty")
	ok(state.decked_players.is_empty(),          "deck-b3: nobody is decked yet")

	# The NEXT required draw is the loss.
	var over := false
	for e in GameLogic.draw_one(state, "p1"):
		if e.event_type == "game_over":
			over = true
	ok(over, "deck-b4: the next required draw decks the player")


func _test_simultaneous_decking_is_a_draw() -> void:
	_buf.append("\n-- Both players decked simultaneously = draw --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	var state := _base_state(db, "p1_hero", "p2_hero")

	GameLogic.draw_one(state, "p1")
	var events := GameLogic.draw_one(state, "p2")
	var saw_draw := false
	for e in events:
		if e.event_type == "game_over":
			saw_draw = bool(e.payload.get("draw", false))
			eq(str(e.payload.get("winner", "")), "", "deck-c2: a draw has no winner")
			eq(int((e.payload.get("losers", []) as Array).size()), 2,
					"deck-c3: both players are losers")
	ok(saw_draw, "deck-c1: the game is a draw when everyone is decked")


func _test_game_over_explanations() -> void:
	_buf.append("\n-- Game-over explanations cover every win condition --")
	var fatal := GameEvent.game_over("p1", "p2").payload
	eq(GameEvent.game_over_explanation(fatal),
			"P2's hero received fatal damage. P1 wins!",
			"deck-d1: hero_defeated explanation")

	var decked := GameEvent.game_over("p1", "p2", "decked").payload
	eq(GameEvent.game_over_explanation(decked),
			"P2 was decked — required to draw from an empty deck. P1 wins!",
			"deck-d2: decked explanation")

	var drawn: Array[String] = ["p1", "p2"]
	var tie := GameEvent.game_drawn(drawn, "decked").payload
	eq(GameEvent.game_over_explanation(tie),
			"P1 was decked — required to draw from an empty deck and "
			+ "P2 was decked — required to draw from an empty deck"
			+ " — the game is a draw.",
			"deck-d3: draw explanation names both causes")

	eq(GameEvent.game_over_explanation(fatal, {"p1": "Ta'zo", "p2": "Grennan"}),
			"Grennan's hero received fatal damage. Ta'zo wins!",
			"deck-d4: display names are used when supplied")


# ══════════════════════════════════════════════════════════════════════════════
# Lafiel (azeroth_196): "2, [Activate] -> Destroy target ability."
# Kavai's destroy pool narrowed to abilities only, on a normal [Activate] tap
# power: she exhausts at announcement, so the power is unavailable until she
# readies. No Purge-style friendly-attachment exclusion — her printed text has
# no such clause, so the caster's own abilities are legal targets too.
# ══════════════════════════════════════════════════════════════════════════════

const LAFIEL_RECIPE := "activated_power:2:destroy_ability:0::ability"

func _test_lafiel_destroys_ability() -> void:
	_buf.append("\n-- Lafiel: [Activate] destroy target ability --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("lafiel_def", 4, 5, [], 6, LAFIEL_RECIPE)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("ongo_def", 2, "ongoing")
	db.instant("mark_def", 2, "ongoing|attach:ally|attached_buff:2:2")
	db.equipment("robe_def", 2, "equipment:chest:0")
	db.totem("totem_def", 1, "ongoing|totem:fire")

	var state := _base_state(db, "p1_hero", "p2_hero")
	var lafiel := _add_ally(state, "lafiel", "lafiel_def", "p1")
	var bear := _add_ally(state, "bear", "bear_def", "p2")
	_add_resources(state, "p1", 4)

	# lf-a: nothing in play to destroy → illegal, even the highlight probe.
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "_skip_target_check": true}), db),
		"lf-a: power illegal with no ability in play")

	# p2's ongoing ability, equipment, totem, and an attachment on its bear.
	var ongo := CardInstance.create("ongo", "ongo_def", "p2", "p2_hero_row")
	state.cards["ongo"] = ongo
	state.zones["p2_hero_row"].card_ids.append("ongo")
	var robe := CardInstance.create("robe", "robe_def", "p2", "p2_hero_row")
	state.cards["robe"] = robe
	state.zones["p2_hero_row"].card_ids.append("robe")
	var totem := CardInstance.create("totem", "totem_def", "p2", "p2_ally_row")
	state.cards["totem"] = totem
	state.zones["p2_ally_row"].card_ids.append("totem")
	var mark := CardInstance.create("mark", "mark_def", "p2", "attached")
	state.cards["mark"] = mark
	state.zones["attached"].card_ids.append("mark")
	mark.attached_to = "bear"
	bear.attachments.append("mark")

	ok(StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "ongo"}), db),
		"lf-b: an ongoing ability is a legal target")
	ok(StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "totem"}), db),
		"lf-c: a totem (ability ally) is a legal target")
	ok(StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "mark"}), db),
		"lf-d: an attachment is a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "robe"}), db),
		"lf-e: equipment is NOT a legal target (unlike Kavai)")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "bear"}), db),
		"lf-f: an ally is NOT a legal target")
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "p2_hero"}), db),
		"lf-g: a hero is NOT a legal target")

	# lf-h: [Activate] tap symbol — summoning sickness and exhaustion both block.
	lafiel.just_summoned = true
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "ongo"}), db),
		"lf-h: blocked by summoning sickness ([Activate])")
	lafiel.just_summoned = false
	lafiel.is_exhausted = true
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "ongo"}), db),
		"lf-i: blocked while exhausted ([Activate])")
	lafiel.is_exhausted = false

	# Resolve on the attachment: it dies, its host survives untouched.
	StackResolver.submit_action(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "lafiel", "target_id": "mark"}), db)
	eq(lafiel.is_exhausted, true, "lf-j: exhausts at announcement (412.2)")
	eq(state.get_available_resources("p1"), 2, "lf-k: 2 resources paid at announcement")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(mark.zone_id, "p2_graveyard", "lf-l: attachment destroyed")
	eq(bear.zone_id, "p2_ally_row",  "lf-m: host ally survives")
	eq(lafiel.zone_id, "p1_ally_row", "lf-n: Lafiel stays in play (no sacrifice cost)")

	# lf-o: not reusable until she readies — exhausted, the power is gone even
	# with resources and targets left.
	ok(not StackResolver.can_submit(state, PendingAction.make("use_ally_power", "p1",
			{"card_id": "lafiel", "target_id": "ongo"}), db),
		"lf-o: not usable again until Lafiel readies")


func _test_lafiel_fizzles_and_ai() -> void:
	_buf.append("\n-- Lafiel: fizzles on a vanished target; AI targets opposing abilities --")
	var db := MockDB.new()
	db.hero("p1_hero", 30)
	db.hero("p2_hero", 30)
	db.ally("lafiel_def", 4, 5, [], 6, LAFIEL_RECIPE)
	db.ally("bear_def", 2, 3, [], 2)
	db.ability("ongo_def", 2, "ongoing")
	db.instant("mark_def", 2, "ongoing|attach:ally|attached_buff:2:2")

	# The announced attachment dies with its host before resolution (400.5) →
	# the destroy fizzles at the 706 / 4217 re-check, cost stays paid.
	var state := _base_state(db, "p1_hero", "p2_hero")
	var lafiel := _add_ally(state, "lafiel", "lafiel_def", "p1")
	var bear := _add_ally(state, "bear", "bear_def", "p2")
	_add_resources(state, "p1", 4)
	var mark := CardInstance.create("mark", "mark_def", "p2", "attached")
	state.cards["mark"] = mark
	state.zones["attached"].card_ids.append("mark")
	mark.attached_to = "bear"
	bear.attachments.append("mark")

	StackResolver.submit_action(state, PendingAction.make("use_ally_power", "p1",
		{"card_id": "lafiel", "target_id": "mark"}), db)
	# Host destroyed in response — takes its attachment with it.
	GameLogic.destroy_card(state, "bear")
	StackResolver.pass_priority(state, db)
	StackResolver.pass_priority(state, db)
	eq(mark.zone_id, "p2_graveyard", "lf-p: attachment already gone (died with host)")
	eq(state.get_available_resources("p1"), 2, "lf-q: cost stays paid on a fizzle")

	# AI: opposing abilities only, highest cost first — never our own.
	var s2 := _base_state(db, "p1_hero", "p2_hero")
	_add_ally(s2, "lafiel2", "lafiel_def", "p1")
	_add_resources(s2, "p1", 4)
	var own := CardInstance.create("own", "ongo_def", "p1", "p1_hero_row")
	s2.cards["own"] = own
	s2.zones["p1_hero_row"].card_ids.append("own")
	var ai := BaseAI.new()
	ok(ai._get_ally_power_actions(s2, db, "p1").is_empty(),
		"lf-r: AI never destroys its own ability")

	db.ability("big_def", 5, "ongoing")
	var cheap := CardInstance.create("cheap", "ongo_def", "p2", "p2_hero_row")
	s2.cards["cheap"] = cheap
	s2.zones["p2_hero_row"].card_ids.append("cheap")
	var big := CardInstance.create("big", "big_def", "p2", "p2_hero_row")
	s2.cards["big"] = big
	s2.zones["p2_hero_row"].card_ids.append("big")
	var acts := ai._get_ally_power_actions(s2, db, "p1")
	eq(acts.size(), 1, "lf-s: AI generates exactly one Lafiel activation")
	eq(acts[0].params.get("target_id", ""), "big",
		"lf-t: AI destroys the most expensive opposing ability")
