class_name BaseAI
extends RefCounted

# Abstract base for all AI players.
#
# Subclasses must override decide_action().
# get_reasonable_actions() is a shared utility all subclasses can call.


# ── Combat instants (held cards) ───────────────────────────────────────────────
# Cards tagged here are HELD in hand — get_reasonable_actions never blind-plays them
# on the AI's own action window. They only come out through
# combat_instant_action() during combat attack/defend windows. Keyed by
# card_def_id. Tags:
#   "combat_instant_dmg" — instant dealing targeted damage
#       (effects: deal_damage_to_target:N:TYPE). Played on the ATTACKING
#       character when the AI is being attacked and the math works out.
#   "combat_instant_protector" — Instant Ally with Protector. Played during the
#       ATTACK window (never the defend window — the protect point is already
#       past) when the AI is being attacked and the protector-choice logic
#       would want to protect with it; the AI then protects with it at the
#       following protect point via the normal choose_protector call.
#       See instant_protector_action().
#   "combat_instant_exhaust" — Instant Ability that exhausts a target ally
#       (effects: exhaust_target:ally). Played on an opposing ALLY attacker while
#       its combat proposal is still on the chain: exhausting it fizzles the
#       proposal at the 601.3 recheck (an exhausted character can't attack). Same
#       timing/role as Litori's target_cant_attack freeze — see
#       exhaust_attacker_action(). Too late once the attack window is open.
#   "combat_instant_destroy_protector" — Instant Ability that destroys the ally
#       currently protecting this combat (effects: destroy_target:protecting_ally).
#       Unlike the defensive tags above, this is played by the ATTACKER during the
#       DEFEND window once the opponent has protected with an ally: destroying the
#       protector ends the combat (603.1b). Played only on an opposing protecting
#       ally whose cost >= this card's cost — see destroy_protector_action().
#   "combat_instant_save_bounce" — Instant Ability that returns a target ally to
#       its owner's hand (effects: return_to_hand:ally). Held to INTERRUPT an
#       opposing targeted removal spell on the chain aimed at one of our allies
#       (destroy, or lethal targeted damage): bouncing the target makes the
#       spell fizzle at the 709.2a recheck, a card-for-card trade. Deliberately
#       NOT played to dodge a combat attack — that trades our card (plus
#       re-paying the ally's cost later) against an attack that cost the
#       opponent nothing. See save_bounce_action().
#   "combat_instant_evasion" — Instant Ability that removes the attacker from
#       combat while our HERO is defending (effects: remove_attackers:
#       hero_defending, e.g. Blink). Played during the DEFEND window only (the
#       card's condition needs the hero to actually be defending — 602.3), when
#       the incoming hit is worth the card: attacker ATK > 3 or our hero is
#       below 10 HP. See evasion_action().
const COMBAT_INSTANT_TAGS: Dictionary = {
	"azeroth_165": "combat_instant_dmg",   # Quick Strike — 2 melee damage
	"azeroth_33":  "combat_instant_dmg",   # Arcane Shot — 1 arcane damage + draw a card
	"azeroth_52":  "combat_instant_dmg",   # Fire Blast — 2 fire damage
	"azeroth_56":  "combat_instant_dmg",   # Frostbolt — 3 frost damage (can't-attack rider not modeled for AI)
	"azeroth_109": "combat_instant_dmg",   # Frost Shock — 2 frost damage (can't-attack/protect rider not modeled for AI)
	"azeroth_134": "combat_instant_dmg",   # Steal Essence — 2 shadow damage (drain heal not modeled for AI)
	"azeroth_27":  "combat_instant_dmg",   # Natural Selection — modal: damage mode only (heal mode enumerated by get_modal_actions but never played — future work)
	"azeroth_221": "combat_instant_protector",   # Tristan Rapidstrike — 3/3 Protector
	"azeroth_159": "combat_instant_exhaust",     # Exhaustion — exhaust target ally
	"azeroth_17":  "combat_instant_exhaust",     # Bash — exhaust target hero or ally (+ bear form ongoing)
	"dark_portal_137": "combat_instant_exhaust", # War Stomp — exhaust ALL opposing heroes and allies (no target)
	"azeroth_99":  "combat_instant_exhaust",     # Gouge — exhaust target hero or ally (+ can't-ready-next-step rider, not modeled for AI)
	"dark_portal_20": "combat_instant_dmg",      # Claw — 3 melee damage (+ cat form ongoing)
	"azeroth_18":  "combat_instant_bear_form",   # Bear Form — hero gains protector (see bear_form_action)
	"azeroth_172": "combat_instant_save_bounce", # Withdraw — put target ally into its owner's hand
	"azeroth_160": "combat_instant_save_bounce", # Fall Back — put target friendly ally into its owner's hand
	"azeroth_48":  "combat_instant_evasion",     # Blink — draw + remove attacker while hero defends
	"dark_portal_141": "combat_instant_destroy_protector",  # First to Fall — destroy target protecting ally
	"azeroth_44":  "combat_instant_atk_swing",   # Ravenous Bite — +3 ATK / -3 ATK on two allies (see atk_swing_action)
	"azeroth_152": "combat_instant_save_elusive", # Sneak — target ally has elusive this turn (see elusive_save_action)
}


# Return a PendingAction to submit, or null to pass priority.
# Called once each time this player has priority.
# Even the base AI plays combat instants — the ambush behavior is universal.
func decide_action(state: GameState, db, player_id: String) -> PendingAction:
	var ambush := combat_instant_action(state, db, player_id)
	if ambush != null:
		return ambush
	var freeze := hero_disable_action(state, db, player_id)
	if freeze != null:
		return freeze
	var exhaust := exhaust_attacker_action(state, db, player_id)
	if exhaust != null:
		return exhaust
	var power_exhaust := exhaust_attacker_ally_power_action(state, db, player_id)
	if power_exhaust != null:
		return power_exhaust
	var sneak := elusive_save_action(state, db, player_id)
	if sneak != null:
		return sneak
	var kill_protector := destroy_protector_action(state, db, player_id)
	if kill_protector != null:
		return kill_protector
	var save := save_bounce_action(state, db, player_id)
	if save != null:
		return save
	var cash_in := doomed_sacrifice_action(state, db, player_id)
	if cash_in != null:
		return cash_in
	var flash := instant_protector_action(state, db, player_id)
	if flash != null:
		return flash
	var dodge := evasion_action(state, db, player_id)
	if dodge != null:
		return dodge
	var swing := atk_swing_action(state, db, player_id)
	if swing != null:
		return swing
	return bear_form_action(state, db, player_id)


# ── Armor damage prevention (rule 717.2c prevention point) ────────────────────
# Called by the scene when this player must decide at an open prevention point
# (state.pending_prevention_*). Returns the armor instance_id to exhaust, or ""
# to take the remaining damage. The engine re-opens the point after each
# exhaust while damage remains and ready armor exists, so this is called once
# per armor. Heuristic: exhaust the highest-DEF ready armor for which
# remaining >= DEF − 1 (avoids wasting a big armor on chip damage).
func choose_prevention(state: GameState, db, player_id: String) -> String:
	if not db or state.pending_prevention_player != player_id:
		return ""
	var remaining := state.pending_prevention_amount
	if remaining <= 0:
		return ""
	var best_id := ""
	var best_def := 0
	for armor_id in StackResolver.get_ready_def_armor(state, player_id, db):
		var card := state.get_card(armor_id)
		var def := db.get_def(card.card_def_id) as CardDef
		var dv := int(StackResolver._equipment_info(def).get("def", 0))
		if dv <= best_def:
			continue
		if remaining >= dv - 1:   # worth exhausting — little wasted potential
			best_def = dv
			best_id  = armor_id
	return best_id


# Ambush logic — only the player being ATTACKED (controller of combat_defender)
# plays combat instants, on an open combat window with an empty chain:
#
#   Attack window:  attacker_hp <= dmg  AND  attacker_cost >= card_cost
#     ("kill the attacker before it even forces a protect, unless it's a cheap
#      bait not worth the card")
#   Defend window:  attacker_hp <= defender_atk + dmg
#                   AND attacker_hp > defender_atk
#                   AND attacker_cost >= card_cost
#     ("only if it finishes something the defender alone wouldn't kill")
#
# The target is announced at submission: always state.combat_attacker.
func combat_instant_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not (state.combat_attack_window or state.combat_defend_window):
		return null
	if not state.pending_actions.is_empty():
		return null   # respond on the window floor, after any chained effects resolve
	if not state.pending_enter_play_effect.is_empty():
		return null
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var defender := state.get_card(defender_id)
	if not defender or defender.controller != player_id:
		return null   # only the attacked side ambushes

	var attacker_hp := state.get_current_hp(attacker_id, db)
	var atk_def := db.get_def(state.get_card(attacker_id).card_def_id) as CardDef
	var attacker_cost: int = atk_def.cost if atk_def else 0

	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_dmg":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var dmg := _combat_instant_dmg(def)
		if dmg <= 0:
			continue
		if attacker_cost < def.cost:
			continue   # cheap bait — not worth the card
		var play := false
		if state.combat_attack_window:
			play = attacker_hp <= dmg
		else:
			var defender_atk := state.get_atk(defender_id, db)
			play = attacker_hp <= defender_atk + dmg and attacker_hp > defender_atk
		if not play:
			continue
		var params := {"card_id": card.instance_id, "target_id": attacker_id}
		# Modal card (Natural Selection): announce the damage mode with the play.
		var dmg_mode := _modal_dmg_mode_index(def)
		if dmg_mode >= 0:
			params["mode"] = dmg_mode
		# Action type per card — an ongoing Instant Ability (Claw) routes to
		# play_ability, a plain instant (Quick Strike) to play_instant.
		var act := PendingAction.make(_action_type_for(card, db), player_id, params)
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# ── Instant protector (e.g. Tristan Rapidstrike) ──────────────────────────────
# Flash in an Instant Ally with Protector during the ATTACK window of a combat
# where the AI is being attacked, so it can protect at the following protect
# point (the normal choose_protector call then picks it up — same decision
# logic). NEVER during the defend window: the protect point is already past.
#
# Mirrors GenericAI.choose_protector's decision tree, evaluated hypothetically
# on the in-hand card's printed stats:
#   • a protector already on board answers this attack (self.choose_protector
#     returns one) → hold the card, use the board;
#   • proposed defender survives the hit:
#       – attacker dies to the defender anyway → hold (free win);
#       – else play only if the fresh protector KILLS the attacker AND SURVIVES;
#   • proposed defender dies:
#       – it's our hero → play (interpose anything — losing the hero loses
#         the game);
#       – it's an ally → play only on a kill-and-survive block. (The board
#         logic also allows cheap fodder blocks, but paying a card AND its
#         resource cost from hand to chump for an ally is value-negative.)
func instant_protector_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.combat_attack_window:
		return null   # attack window only — never the defend window
	if not state.pending_actions.is_empty():
		return null   # respond on the window floor
	if not state.pending_enter_play_effect.is_empty():
		return null
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var defender := state.get_card(defender_id)
	if not defender or defender.controller != player_id:
		return null   # only the attacked side flashes in a protector

	var a_atk := state.get_atk(attacker_id, db, true)   # "while attacking" bonuses
	if a_atk <= 0:
		return null   # attacker deals no damage — nothing to block
	var a_hp  := state.get_current_hp(attacker_id, db)
	var d_hp  := state.get_current_hp(defender_id, db)
	var d_atk := state.get_atk(defender_id, db)
	var defender_dies := a_atk >= d_hp
	var attacker_dies_to_defender := d_atk >= a_hp

	# A board protector already answers this attack — hold the card.
	if choose_protector(state, db, player_id) != "":
		return null

	var ps := state.players.get(player_id) as PlayerState
	var defender_is_hero := ps != null and defender_id == ps.hero_instance_id

	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_protector":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		# Hypothetical block with the fresh body's printed stats (it enters
		# undamaged; protecting is legal despite summoning sickness — 601.2a
		# restricts attackers only).
		var kills_attacker := def.printed_atk >= a_hp
		var survives_block := def.printed_health > a_atk
		var safe_block := kills_attacker and survives_block
		var play := false
		if not defender_dies:
			play = (not attacker_dies_to_defender) and safe_block
		elif defender_is_hero:
			play = true
		else:
			play = safe_block
		if not play:
			continue
		var act := PendingAction.make("play_ally", player_id,
			{"card_id": card.instance_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# ── Hero disable flip (e.g. Litori Frostburn: target can't attack this turn) ──
# The instant save that does NOT kill the attacker. Timing is everything: a
# "can't attack" modifier can't remove an attacker already in combat (602.4),
# but applied while the enemy's combat PROPOSAL is still on the chain, the
# 601.3 legality recheck interrupts the proposal — combat never starts and the
# attacker doesn't even exhaust (it just can't attack again this turn).
#
# So this fires ONLY while the top pending action is an opposing propose_combat
# whose defender we control. The flip is once per game — spend it only on a
# real save:
#   • defender is our hero and the hit is lethal or heavy (ATK >= 4), or
#   • defender is an ally (cost >= 2) that would die without killing the
#     attacker back (a plain bad trade for us).
# Held if a tagged damage combat-instant in hand can kill the attacker instead
# (a cheaper, permanent answer that combat_instant_action will play later).
func hero_disable_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.pending_actions.is_empty():
		return null
	var top: PendingAction = state.pending_actions.back()
	if top.action_type != "propose_combat" or top.source_player == player_id:
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.has_used_hero_power or ps.hero_instance_id == "":
		return null
	var hero_id := ps.hero_instance_id
	if not _hero_power_is(state, db, hero_id, "target_cant_attack"):
		return null

	var attacker_id: String = top.params.get("attacker_id", "")
	var defender_id: String = top.params.get("defender_id", "")
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var defender := state.get_card(defender_id)
	if not defender or defender.controller != player_id:
		return null   # only save our own side

	var a_atk := state.get_atk(attacker_id, db, true)
	var a_hp  := state.get_current_hp(attacker_id, db)
	var d_hp  := state.get_current_hp(defender_id, db)
	var worth := false
	if defender_id == ps.hero_instance_id:
		worth = a_atk >= d_hp or a_atk >= 4
	else:
		var d_def := db.get_def(defender.card_def_id) as CardDef
		var d_atk := state.get_atk(defender_id, db)
		var kills_back := d_atk >= a_hp \
			and not StackResolver._has_keyword(state.get_card(attacker_id), "long_range", db, state)
		worth = a_atk >= d_hp and not kills_back and d_def != null and d_def.cost >= 2
	if not worth:
		return null

	# A kill is strictly better than a freeze — hold if a combat instant answers it.
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_dmg":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if def and _combat_instant_dmg(def) >= a_hp \
				and def.cost <= state.get_available_resources(player_id):
			return null

	var act := PendingAction.make("activate_power", player_id,
		{"hero_id": hero_id, "target_id": attacker_id})
	if StackResolver.can_submit(state, act, db):
		return act
	return null


# Exhaustion (combat_instant_exhaust): a held Instant Ability that exhausts a
# target ally. Played in RESPONSE to an opposing combat proposal on the chain,
# aimed at the attacker — exhausting it fizzles the proposal (601.3 recheck).
# Same defensive role and "is the trade worth answering?" math as
# hero_disable_action (Litori's freeze), with two extra constraints Exhaustion
# imposes: the attacker must be an ALLY (it can't target an attacking hero), and
# the answer is a hand card that costs resources (must be affordable).
func exhaust_attacker_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.pending_actions.is_empty():
		return null
	var top: PendingAction = state.pending_actions.back()
	if top.action_type != "propose_combat" or top.source_player == player_id:
		return null

	var attacker_id: String = top.params.get("attacker_id", "")
	var defender_id: String = top.params.get("defender_id", "")
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	# Exhaustion (exhaust_target:ally) can only freeze an attacking ALLY; Bash
	# (exhaust_target:hero_or_ally) can also freeze an attacking hero — the
	# per-card targeting gate is applied in the candidate loop below.
	var attacker := state.get_card(attacker_id)
	var attacker_is_ally := attacker != null and StackResolver._is_ally(state, attacker_id)
	if not attacker:
		return null
	var defender := state.get_card(defender_id)
	if not defender or defender.controller != player_id:
		return null   # only save our own side

	# Same worth heuristic as Litori (hero_disable_action): freeze when our hero
	# takes lethal / a big hit, or when a costed ally of ours dies in a bad trade.
	var a_atk := state.get_atk(attacker_id, db, true)
	var a_hp  := state.get_current_hp(attacker_id, db)
	var d_hp  := state.get_current_hp(defender_id, db)
	var ps := state.players.get(player_id) as PlayerState
	var worth := false
	if ps and defender_id == ps.hero_instance_id:
		worth = a_atk >= d_hp or a_atk >= 4
	else:
		var d_def := db.get_def(defender.card_def_id) as CardDef
		var d_atk := state.get_atk(defender_id, db)
		var kills_back := d_atk >= a_hp \
			and not StackResolver._has_keyword(attacker, "long_range", db, state)
		worth = a_atk >= d_hp and not kills_back and d_def != null and d_def.cost >= 2
	if not worth:
		return null

	# A kill is strictly better than a freeze — hold if a combat instant answers it.
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_dmg":
			continue
		var dmg_def := db.get_def(card.card_def_id) as CardDef
		if dmg_def and _combat_instant_dmg(dmg_def) >= a_hp \
				and dmg_def.cost <= state.get_available_resources(player_id):
			return null

	# Find an affordable Exhaustion/Bash in hand and aim it at the attacker.
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_exhaust":
			continue
		var e_def := db.get_def(card.card_def_id) as CardDef
		var mass := _exhausts_all_opposing(e_def)
		if not attacker_is_ally and not mass and not _exhausts_heroes(e_def):
			continue   # ally-only exhaust can't answer an attacking hero
		# Action type per card — Bash is an ongoing Instant Ability (play_ability).
		# War Stomp is non-targeted (mass exhaust) — no target_id announced.
		var e_params := {"card_id": card.instance_id}
		if not mass:
			e_params["target_id"] = attacker_id
		var act := PendingAction.make(_action_type_for(card, db), player_id, e_params)
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Sneak (combat_instant_save_elusive): a held Instant Ability granting an ally
# elusive ("can't be attacked") this turn. Played in RESPONSE to an opposing
# combat proposal on the chain, aimed at our OWN proposed defender — the 601.3
# legality recheck sees an elusive defender and fizzles the proposal, so combat
# never starts and the attacker never exhausts. Same interrupt point and same
# "is the trade worth answering?" math as Litori's freeze (hero_disable_action)
# and Exhaustion (exhaust_attacker_action), with two differences that follow
# from targeting our side rather than theirs:
#   * the defender must be an ALLY (Sneak targets allies, so a hero being
#     attacked can't be saved this way);
#   * the grant lasts the TURN, so it also blanks any follow-up attack aimed at
#     that ally — a strict bonus over the freeze, which is why there is no
#     extra gate for it.
# Too late once the attack window opens: elusive restricts who may be CHOSEN as
# defender, and by then the choice is made.
func elusive_save_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.pending_actions.is_empty():
		return null
	var top: PendingAction = state.pending_actions.back()
	if top.action_type != "propose_combat" or top.source_player == player_id:
		return null

	var attacker_id: String = top.params.get("attacker_id", "")
	var defender_id: String = top.params.get("defender_id", "")
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var attacker := state.get_card(attacker_id)
	var defender := state.get_card(defender_id)
	if not attacker or not defender:
		return null
	if defender.controller != player_id:
		return null   # only save our own side
	if not StackResolver._is_ally(state, defender_id):
		return null   # Sneak can't be cast on a hero

	# Worth: our ally dies to the hit and doesn't take the attacker with it,
	# and it cost enough to be worth spending a card on (the ally branch of
	# hero_disable_action's math).
	var a_atk := state.get_atk(attacker_id, db, true)
	var a_hp  := state.get_current_hp(attacker_id, db)
	var d_hp  := state.get_current_hp(defender_id, db)
	var d_atk := state.get_atk(defender_id, db)
	var d_def := db.get_def(defender.card_def_id) as CardDef
	var kills_back := d_atk >= a_hp \
		and not StackResolver._has_keyword(attacker, "long_range", db, state)
	if a_atk < d_hp or kills_back or d_def == null or d_def.cost < 2:
		return null

	# A kill is strictly better than a save — hold if a combat instant answers it.
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_dmg":
			continue
		var dmg_def := db.get_def(card.card_def_id) as CardDef
		if dmg_def and _combat_instant_dmg(dmg_def) >= a_hp \
				and dmg_def.cost <= state.get_available_resources(player_id):
			return null

	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_save_elusive":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id, "target_id": defender_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# True when the card mass-exhausts every opposing character with no target
# (War Stomp: exhaust_all_opposing) — answers attacking heroes AND allies.
static func _exhausts_all_opposing(def: CardDef) -> bool:
	if not def:
		return false
	for entry in def.effects.split("|"):
		if entry.strip_edges().split(":")[0] == "exhaust_all_opposing":
			return true
	return false


# True when the card's exhaust_target segment accepts heroes (Bash:
# exhaust_target:hero_or_ally).
static func _exhausts_heroes(def: CardDef) -> bool:
	if not def:
		return false
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "exhaust_target" and parts.size() > 1 \
				and parts[1] == "hero_or_ally":
			return true
	return false


# ── Evasion (azeroth_48 Blink / combat_instant_evasion) ───────────────────────
# "Draw a card. If your hero is defending, remove all attackers from combat."
# Played during the DEFEND window only (the removal clause requires the hero to
# actually be defending — during the attack window it would be a pure cantrip),
# with an empty chain, when our HERO is the current defender and the dodge is
# worth the card: incoming attacker ATK > 3, or our hero is below 10 HP (any
# hit matters when low). Never blind-played for the draw alone.
func evasion_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.combat_defend_window:
		return null   # the hero must BE defending — attack window is too early
	if not state.pending_actions.is_empty():
		return null   # respond on the window floor
	if not state.pending_enter_play_effect.is_empty():
		return null
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or defender_id != ps.hero_instance_id:
		return null   # only when OUR HERO is the defender
	var incoming := state.get_atk(attacker_id, db)
	if incoming <= 0:
		return null   # no damage to dodge
	var hero_hp := state.get_current_hp(defender_id, db)
	if incoming <= 3 and hero_hp >= 10:
		return null   # small hit, healthy hero — hold the card

	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_evasion":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# ── Bear Form (azeroth_18 / combat_instant_bear_form) ─────────────────────────
# "Ongoing: Your hero is in bear form. (Has protector.)" Held like a combat
# instant and flashed in during the ATTACK window of a combat where the AI is
# being attacked — the hero is then a legal protector at the protect point
# (choose_protector picks it up). Played only when:
#   • the attack window is open with an empty chain and we control the defender,
#   • the hero is NOT already in bear form (no in-play Form granting
#     hero_has_protector),
#   • the hero is ready (an exhausted hero can't protect),
#   • the attacker actually deals damage,
#   • no board protector already answers the attack (choose_protector == "").
func bear_form_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.combat_attack_window:
		return null   # before the protect point only — too late afterwards
	if not state.pending_actions.is_empty():
		return null
	if not state.pending_enter_play_effect.is_empty():
		return null
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var defender := state.get_card(defender_id)
	if not defender or defender.controller != player_id:
		return null   # only the attacked side shifts

	if state.get_atk(attacker_id, db, true) <= 0:
		return null   # attacker deals nothing — no reason to block
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	var hero := state.get_card(ps.hero_instance_id)
	if not hero or hero.is_exhausted:
		return null   # exhausted hero can't protect anyway
	# Already in bear form? (Any in-play Form of ours granting hero_has_protector.)
	for c in state.cards_in_zone(player_id + "_hero_row"):
		var c_def := db.get_def(c.card_def_id) as CardDef
		if c_def and StackResolver.is_form_def(c_def) \
				and StackResolver._has_effect_flag(c_def, "hero_has_protector"):
			return null
	# A board protector already answers this attack — save the card.
	if choose_protector(state, db, player_id) != "":
		return null

	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_bear_form":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Form pay-return choice (Bear/Cat Form death trigger): the engine only opens
# the point when the cost is affordable, and getting the Form back is always
# worth 2 — pay.
func choose_form_return(_state: GameState, _db, _player_id: String) -> bool:
	return true


# ── Destroy the protecting ally (First to Fall) ───────────────────────────────
# Offensive, not defensive: the AI is the ATTACKER. Once the opponent has
# protected with an ally, the DEFEND window opens and the protector is
# state.combat_protector. Destroying it ends the combat with no damage (603.1b),
# clearing the blocker the opponent just spent. We play it only when:
#   • we're in the defend window with an empty chain (respond on the floor),
#   • an OPPONENT ally is protecting (never a protecting hero, never our own),
#   • that protector's cost >= this card's cost (the standard "only spend removal
#     on something at least as expensive as the removal" heuristic — cost 2 here).
# The target is announced at submission: always state.combat_protector.
# ── Ravenous Bite (azeroth_44) — combat ATK swing ─────────────────────────────
# "Target ally has +3 ATK this turn. Target ally has -3 ATK this turn."
#
# Held (COMBAT_INSTANT_TAGS), never blind-played: off combat the swing expires
# the same turn and changes nothing. Played on an open attack/defend window,
# from EITHER side of the combat (unlike the damage ambush, which is
# defender-only — a +3 pump is at its best on our own attacker).
#
# HARD GATE — the -3 must land on the OPPOSING character in this combat, and
# that character must be an ALLY. Both halves target allies, so with no enemy
# ally in the fight (e.g. an enemy HERO attacking our ally) the -3 would be
# forced onto our own board — at best a wasted card, at worst self-sabotage or
# a net-zero double-pick on the same ally. In that case we never play it.
#
# With the shrink target settled, we play only when the swing FLIPS the fight:
#   - it saves our character that would otherwise die (their ATK - 3 < our HP), or
#   - it kills theirs when ours alone wouldn't (our ATK + 3 >= their HP).
# Plus the usual card-economy gate: the ally saved or killed must be worth at
# least the spell's cost.
#
# The +3 goes on our own character in the combat when that's an ally; when our
# HERO is the one fighting, the pump is a dump onto our best ally and we only
# spend the card to stop lethal-ish damage to the hero.
# Not modeled: Long-Range (no retaliation), protectors swapping in later, and
# the pump's value on a future attack.
func atk_swing_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not (state.combat_attack_window or state.combat_defend_window):
		return null
	if not state.pending_actions.is_empty():
		return null
	if not state.pending_enter_play_effect.is_empty():
		return null
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var attacker := state.get_card(attacker_id)
	var defender := state.get_card(defender_id)
	if not attacker or not defender:
		return null
	if attacker.controller != player_id and defender.controller != player_id:
		return null
	var we_attack := attacker.controller == player_id
	var ours_id: String   = attacker_id if we_attack else defender_id
	var theirs_id: String = defender_id if we_attack else attacker_id

	# The -3 target: the opposing combatant, and it must be an ally.
	if not StackResolver._is_ally(state, theirs_id):
		return null
	if not StackResolver._is_legal_target(state, theirs_id, db):
		return null   # Untargetable — 706 blocks BOTH slots of this card

	var ours_is_ally := StackResolver._is_ally(state, ours_id)
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_atk_swing":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var amounts := StackResolver.atk_swing_amounts(def)
		if amounts.size() < 2:
			continue
		var up: int   = amounts[0]
		var down: int = amounts[1]
		# Who receives the pump.
		var pump_id := ours_id if ours_is_ally else _best_pump_ally(state, db, player_id)
		if pump_id == "" or not StackResolver._is_legal_target(state, pump_id, db):
			continue
		var their_atk := state.get_atk(theirs_id, db)
		var their_hp  := state.get_current_hp(theirs_id, db)
		var our_hp    := state.get_current_hp(ours_id, db)
		var our_atk   := forecast_atk(state, db, ours_id, we_attack)
		var their_atk_after := maxi(their_atk + down, 0)
		var our_atk_after   := our_atk + (up if pump_id == ours_id else 0)
		var play := false
		if ours_is_ally:
			# Save our ally from a lethal hit, or turn a non-kill into a kill.
			var saved := our_hp <= their_atk and our_hp > their_atk_after
			var kills := their_hp > our_atk and their_hp <= our_atk_after
			# Worth the card: whatever we save or kill must cost at least as
			# much as the spell (same cheap-bait guard as the damage ambush).
			var stake_id := theirs_id if kills else ours_id
			var stake_def := db.get_def(state.get_card(stake_id).card_def_id) as CardDef
			play = (saved or kills) and stake_def != null and stake_def.cost >= def.cost
		else:
			# Our HERO is in this combat: no legal pump target on it, so the
			# card is bought purely for the -3. Only worth it against a hit
			# the hero can't take, and only when the shrink actually saves it.
			play = their_atk >= our_hp and their_atk_after < our_hp
		if not play:
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id, {
			"card_id": card.instance_id,
			"target_id": pump_id,       # +ATK half
			"target_id_2": theirs_id,   # -ATK half
		})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Highest-ATK own ally to soak Ravenous Bite's mandatory +ATK half when our
# hero, not an ally, is the one in combat. "" when we control no ally — the
# pump would then have to go on an enemy ally, so the card isn't played.
func _best_pump_ally(state: GameState, db, player_id: String) -> String:
	var best := ""
	var best_atk := -1
	for card in state.cards_in_zone(player_id + "_ally_row"):
		if not StackResolver._is_legal_target(state, card.instance_id, db):
			continue
		var a := state.get_atk(card.instance_id, db)
		if a > best_atk:
			best_atk = a
			best = card.instance_id
	return best


func destroy_protector_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.combat_defend_window:
		return null   # a protector only exists after the protect point
	if not state.pending_actions.is_empty():
		return null
	if not state.pending_enter_play_effect.is_empty():
		return null
	var protector_id := state.combat_protector
	if protector_id == "" or not state.is_in_play(protector_id):
		return null
	if not StackResolver._is_ally(state, protector_id):
		return null   # a protecting hero (Draconian Deflector) isn't a legal target
	var prot := state.get_card(protector_id)
	if not prot or prot.controller == player_id:
		return null   # only opponents' protectors — never our own ally
	var prot_def := db.get_def(prot.card_def_id) as CardDef
	var prot_cost: int = prot_def.cost if prot_def else 0

	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_destroy_protector":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		if prot_cost < def.cost:
			continue   # not worth spending the card on a cheaper protector
		var act := PendingAction.make("play_instant", player_id,
			{"card_id": card.instance_id, "target_id": protector_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Galahandra, Keeper of the Silent Grove (activated_power:1:exhaust_target:0::ally):
# same defensive role as exhaust_attacker_action above, but the exhaust comes
# from an in-play ally's repeatable activated power (use_ally_power), not a
# one-shot hand instant. Her 0 ATK means the AI never attacks with her, so the
# power is always available to answer combat on either player's turn.
func exhaust_attacker_ally_power_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.pending_actions.is_empty():
		return null
	var top: PendingAction = state.pending_actions.back()
	if top.action_type != "propose_combat" or top.source_player == player_id:
		return null

	var attacker_id: String = top.params.get("attacker_id", "")
	var defender_id: String = top.params.get("defender_id", "")
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	var attacker := state.get_card(attacker_id)
	if not attacker or not StackResolver._is_ally(state, attacker_id):
		return null
	var defender := state.get_card(defender_id)
	if not defender or defender.controller != player_id:
		return null   # only save our own side

	var a_atk := state.get_atk(attacker_id, db, true)
	var a_hp  := state.get_current_hp(attacker_id, db)
	var d_hp  := state.get_current_hp(defender_id, db)
	var ps := state.players.get(player_id) as PlayerState
	var worth := false
	if ps and defender_id == ps.hero_instance_id:
		worth = a_atk >= d_hp or a_atk >= 4
	else:
		var d_def := db.get_def(defender.card_def_id) as CardDef
		var d_atk := state.get_atk(defender_id, db)
		var kills_back := d_atk >= a_hp \
			and not StackResolver._has_keyword(attacker, "long_range", db, state)
		worth = a_atk >= d_hp and not kills_back and d_def != null and d_def.cost >= 2
	if not worth:
		return null

	# A kill is strictly better than a freeze — hold if a combat instant answers it.
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_dmg":
			continue
		var dmg_def := db.get_def(card.card_def_id) as CardDef
		if dmg_def and _combat_instant_dmg(dmg_def) >= a_hp \
				and dmg_def.cost <= state.get_available_resources(player_id):
			return null

	for card in state.cards_in_zone(player_id + "_ally_row"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var ap := StackResolver._ally_activated_power(def)
		if ap.get("effect", "") != "exhaust_target" or ap.get("targets", "") != "ally":
			continue
		var act := PendingAction.make("use_ally_power", player_id,
			{"card_id": card.instance_id, "target_id": attacker_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Withdraw (combat_instant_save_bounce): a held Instant that returns a target
# ally to its owner's hand. Played ONLY to interrupt an opposing removal SPELL
# on the chain aimed at one of our allies — the bounce makes the spell fizzle
# at the 709.2a recheck, a fair card-for-card trade (they spent a card too).
# Never played to dodge a combat attack: an attack costs the opponent no card,
# while we'd burn Withdraw AND have to re-pay the ally's cost to replay it.
# Threats recognized: destroy_target:ally (Vanquish), destroy_ally ally powers
# (Augustus), and targeted damage that is LETHAL to the ally (deal_damage_to_target
# instants incl. modal damage modes, and ally-power damage). Worth gate: the
# threatened ally's printed cost must be >= Withdraw's cost.
func save_bounce_action(state: GameState, db, player_id: String) -> PendingAction:
	var target_id := _chain_threatened_ally(state, db, player_id)
	if target_id == "":
		return null
	var victim := state.get_card(target_id)
	var v_def := db.get_def(victim.card_def_id) as CardDef
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_save_bounce":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or not v_def or v_def.cost < def.cost:
			continue   # not worth spending the save on a cheap ally
		var act := PendingAction.make("play_instant", player_id,
			{"card_id": card.instance_id, "target_id": target_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# The friendly ally targeted by a LETHAL opposing removal/damage link on top of
# the chain ("" when there is none). Threats recognized: destroy_target:ally
# (Vanquish), destroy_ally ally powers (Augustus), and targeted damage >= the
# ally's remaining health (deal_damage_to_target instants incl. modal damage
# modes, and ally-power damage). Shared by save_bounce_action (Withdraw) and
# doomed_sacrifice_action (Kavai the Wanderer).
func _chain_threatened_ally(state: GameState, db, player_id: String) -> String:
	if not db or state.pending_actions.is_empty():
		return ""
	var top: PendingAction = state.pending_actions.back()
	if top.source_player == player_id:
		return ""
	if not (top.action_type in ["play_instant", "play_ability", "use_ally_power"]):
		return ""
	var target_id: String = top.params.get("target_id", "")
	if target_id == "" or not state.is_in_play(target_id):
		return ""
	var victim := state.get_card(target_id)
	if not victim or victim.controller != player_id \
			or not StackResolver._is_ally(state, target_id):
		return ""

	# Is the link actually going to remove the ally?
	var threat_card := state.get_card(top.params.get("card_id", ""))
	var threat_def := db.get_def(threat_card.card_def_id) as CardDef if threat_card else null
	if not threat_def:
		return ""
	var lethal := false
	var v_hp := state.get_current_hp(target_id, db)
	if top.action_type == "use_ally_power":
		var ap := StackResolver._ally_activated_power(threat_def)
		match ap.get("effect", ""):
			"destroy_ally":
				lethal = true
			"deal_damage_to_target":
				lethal = int(ap.get("amount", 0)) >= v_hp
	else:
		var segs := threat_def.effects.split("|")
		if StackResolver.is_modal_def(threat_def):
			var chosen := StackResolver.selected_mode(threat_def, top)
			segs = PackedStringArray([chosen]) if chosen != "" else PackedStringArray()
		for seg in segs:
			var parts := (seg as String).strip_edges().split(":")
			match parts[0].strip_edges():
				"destroy_target":
					lethal = lethal or parts.size() < 2 or parts[1] == "ally" \
							or (parts[1] == "protecting_ally" \
								and target_id == state.combat_protector)
				"deal_damage_to_target":
					var amt := int(parts[1]) if parts.size() > 1 else 0
					lethal = lethal or amt >= v_hp
	return target_id if lethal else ""


# Kavai the Wanderer (destroy_ability_or_equipment + sacrifice_self) and Moira
# Darkheart (destroy_equipment + sacrifice_self): the power
# destroys the SOURCE as a cost, so it is never fired proactively —
# _get_ally_power_actions doesn't generate it. Instead, when she is DOOMED —
# targeted by a lethal opposing removal/damage link on the chain, or about to
# die when the open combat window concludes — cash her in on the opponent's
# most expensive in-play ability or equipment, so her death isn't wasted (and
# an opposing removal spell aimed at her fizzles at its 709.2a recheck).
func doomed_sacrifice_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var threatened := _chain_threatened_ally(state, db, player_id)
	var opp := "p2" if player_id == "p1" else "p1"
	for card in state.cards_in_zone(player_id + "_ally_row"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var ap := StackResolver._ally_activated_power(def)
		# Kavai destroys an ability OR equipment; Moira Darkheart only armor or
		# weapon (the equipment pool). Same doomed cash-in, narrower target list.
		var sac_kinds: Array = []
		match ap.get("effect", "") as String:
			"destroy_ability_or_equipment": sac_kinds = ["ability", "equipment"]
			"destroy_equipment":            sac_kinds = ["equipment"]
			"destroy_ability":              sac_kinds = ["ability"]
		if sac_kinds.is_empty() or ap.get("extra_cost", "") != "sacrifice_self":
			continue
		if not _is_doomed(state, db, card.instance_id, threatened):
			continue
		# Meaningful target only: the opponent's most expensive candidate.
		var best := ""
		var best_cost := -1
		for kind in sac_kinds:
			for cid in StackResolver.get_destroy_kind_candidates(state, db, kind):
				var t := state.get_card(cid)
				if not t or t.controller != opp:
					continue
				var t_def := db.get_def(t.card_def_id) as CardDef
				var t_cost: int = t_def.cost if t_def else 0
				if t_cost > best_cost:
					best_cost = t_cost
					best = cid
		if best == "":
			continue
		var act := PendingAction.make("use_ally_power", player_id,
			{"card_id": card.instance_id, "target_id": best})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Whether this ally is about to be removed: it's the victim of a lethal
# opposing link on the chain (chain_threatened, from _chain_threatened_ally),
# or the open combat window will conclude with lethal combat damage on it —
# as the defender, or as an attacker facing a lethal retaliation (which never
# comes when the attacker is Long-Range).
func _is_doomed(state: GameState, db, card_id: String, chain_threatened: String) -> bool:
	if card_id == chain_threatened:
		return true
	if not (state.combat_attack_window or state.combat_defend_window):
		return false
	var hp := state.get_current_hp(card_id, db)
	if card_id == state.combat_defender:
		return state.get_atk(state.combat_attacker, db) >= hp
	if card_id == state.combat_attacker:
		if StackResolver._has_keyword(state.get_card(card_id), "long_range", db, state):
			return false
		return state.get_atk(state.combat_defender, db) >= hp
	return false


# Damage amount of a combat_instant_dmg card (deal_damage_to_target:N:TYPE),
# including a modal card's damage mode (mode:deal_damage_to_target:N:TYPE —
# Natural Selection).
static func _combat_instant_dmg(def: CardDef) -> int:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "deal_damage_to_target" and parts.size() > 1:
			return int(parts[1])
		if parts[0].strip_edges() == "mode" and parts.size() > 2 \
				and parts[1].strip_edges() == "deal_damage_to_target":
			return int(parts[2])
	return 0


# Index of a modal card's deal_damage_to_target mode; -1 when none / not modal.
static func _modal_dmg_mode_index(def: CardDef) -> int:
	var modes := StackResolver.modal_modes(def)
	for i in modes.size():
		if (modes[i] as String).begins_with("deal_damage_to_target"):
			return i
	return -1


# Return true if this AI wants to mulligan its opening hand.
# Base heuristic: mulligan if the hand contains no quests or locations.
func wants_mulligan(state: GameState, db, player_id: String) -> bool:
	for card in state.cards_in_zone(player_id + "_hand"):
		if not db:
			return false
		var def := db.get_def(card.card_def_id) as CardDef
		if def and (def.card_type == "Quest" or def.card_type == "Location"):
			return false   # found at least one quest/location — keep
	return true   # no quest or location → mulligan


# ── Shared utilities ───────────────────────────────────────────────────────────

# The actions the AI is WILLING TO CONSIDER right now (hand plays + combat).
#
# NOT a legality check — that is the engine's job (StackResolver.can_submit),
# and this deliberately returns a subset of what is legal. Cards and attacks are
# dropped here when there is no upside to weigh at all, so the scoring layers
# never see them: held combat instants, pet-wasting ally plays, draws into a
# full hand, a hero swinging at an ally it can't kill, an ally attacking into a
# shield that prevents all of its damage. Anything with a real trade-off belongs
# in the AI's ranking steps, not in this filter.
func get_reasonable_actions(state: GameState, db, player_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []

	# Hand card plays.
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.has(card.card_def_id):
			continue   # held for combat windows — see combat_instant_action()
		var action_type := _action_type_for(card, db)
		if action_type == "":
			continue
		if action_type == "play_ally" and db and _would_waste_pet(state, db, player_id, card):
			continue
		if action_type in ["play_instant", "play_ability"] and db:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and StackResolver._has_effect_flag_prefix(def, "chain_lightning"):
				# Chain Lightning: up to 3 distinct enemy targets, first target may
				# not be Untargetable (2nd/3rd may). AI always targets opponents only.
				var cl_action := _chain_lightning_action(state, db, player_id, card.instance_id, action_type)
				if cl_action:
					result.append(cl_action)
				continue
			if def and StackResolver._has_effect_flag_prefix(def, "multi_shot"):
				# Multi-Shot: up to 3 enemy targets, each takes the same damage.
				# AI always targets opponents only.
				var ms_action := _multi_shot_action(state, db, player_id, card.instance_id, action_type)
				if ms_action:
					result.append(ms_action)
				continue
			if def and StackResolver.is_divided_damage_def(def):
				# Lightning Storm: X is both the price and the damage pool, so
				# the AI buys exactly the points it can convert into kills.
				var dd_action := _divided_damage_action(state, db, player_id, card.instance_id, action_type)
				if dd_action:
					result.append(dd_action)
				continue
			if def and StackResolver.is_attachment_def(def):
				# Attachment (rule 400): buff → own ally, debuff → enemy ally.
				result.append_array(_attach_actions(state, db, player_id, card.instance_id, action_type, def))
				continue
			if def and StackResolver.is_modal_def(def):
				# Modal spell (707.1c): every mode is enumerated (get_modal_actions)
				# so the option space is visible, then the play policy
				# (_modal_mode_playable) filters what's actually submitted.
				var modal_modes: Array = StackResolver.modal_modes(def)
				for m_act in get_modal_actions(state, db, player_id, card.instance_id, action_type):
					var m_idx := int((m_act as PendingAction).params.get("mode", 0))
					if _modal_mode_playable(modal_modes[m_idx]):
						result.append(m_act)
				continue
			if def and StackResolver.get_graveyard_search_requirement(def).get("dest", "") == "play":
				# Ancestral Spirit: reanimate the best affordable ally in our
				# own graveyard.
				var rz_act := _reanimate_action(state, db, player_id, card.instance_id, action_type)
				if rz_act:
					result.append(rz_act)
				continue
			if def and StackResolver.get_graveyard_search_requirement(def).get("dest", "") == "rfg":
				# Cannibalize: exile ally cards out of the graveyards for the heal.
				var gx_act := _graveyard_exile_action(state, db, player_id, card.instance_id, action_type)
				if gx_act:
					result.append(gx_act)
				continue
			if def and StackResolver._has_effect_flag_prefix(def, "rapid_fire_ready_on_strike"):
				# Rapid Fire grants nothing on its own — its whole value is chaining
				# ranged strikes, so only play it when we can actually pay for at
				# least TWO strikes with a ready Ranged weapon this turn:
				#   play cost + 2 x strike cost + the ready payment.
				# Anything less and the card is wasted.
				if not _rapid_fire_worth_playing(state, db, player_id,
						card.instance_id, def):
					continue
			if def and StackResolver._instant_needs_target(def):
				# Targeted spell: one action per valid target.
				result.append_array(_targeted_instant_actions(state, db, player_id, card.instance_id, action_type))
				continue
			# Pure-draw spell (Innervate): don't draw past max hand size — the
			# excess would just be discarded at wrap-up (503.2a). Same gate as
			# the `draw` activated power in _get_ally_power_actions, minus one
			# because playing the spell itself frees a slot in hand.
			var pure_draw := _pure_draw_amount(def) if def else 0
			if pure_draw > 0:
				var dr_max_hand := state.get_max_hand_size(player_id, db)
				if state.cards_in_zone(player_id + "_hand").size() - 1 > dr_max_hand - pure_draw:
					continue
		var action := PendingAction.make(action_type, player_id,
				{"card_id": card.instance_id})
		if StackResolver.can_submit(state, action, db):
			result.append(action)

	# Quest completions (face-up quests in resource row whose cost is payable).
	# Skip during combat windows — completing quests mid-combat is never useful and
	# prevents the attack/defend window from advancing cleanly.
	if not state.combat_attack_window and not state.combat_defend_window:
		for card in state.cards_in_zone(player_id + "_resource_row"):
			if card.face_down:
				continue
			if db:
				var def := db.get_def(card.card_def_id) as CardDef
				if not def or def.card_type != "Quest":
					continue
			var params := {"quest_id": card.instance_id}
			# A New Plague-style destroy mode: only complete while the OPPONENT
			# has an ally to lose too — otherwise the quest is pure self-harm
			# (or a bare draw the AI can wait on).
			if db:
				var gate_def := db.get_def(card.card_def_id) as CardDef
				if gate_def and "qmode:each_player_destroys_ally" in gate_def.effects:
					var qc_opp := "p2" if player_id == "p1" else "p1"
					if state.cards_in_zone(qc_opp + "_ally_row").is_empty():
						continue
			# Graveyard-target rewards: announce targets with the completion.
			# Target choice is an overridable hook (see _choose_graveyard_targets).
			if db:
				var q_def := db.get_def(card.card_def_id) as CardDef
				var gy_req := StackResolver.get_graveyard_search_requirement(q_def)
				if not gy_req.is_empty():
					var candidates := StackResolver.get_graveyard_search_candidates(
							state, player_id, gy_req, db)
					params["target_ids"] = _choose_graveyard_targets(
							state, db, player_id, gy_req, candidates)
				# "Exhaust N allies" extra cost (The Love Potion): announce the
				# allies with the completion. Overridable hook.
				var exh_req := StackResolver.get_quest_ally_exhaust_requirement(q_def)
				if exh_req > 0:
					params["ally_ids"] = _choose_quest_exhaust_allies(
							state, db, player_id, exh_req)
			var action := PendingAction.make("use_quest", player_id, params)
			if StackResolver.can_submit(state, action, db):
				result.append(action)

	# Combat proposals (only valid in action phase with empty chain and no combat window open).
	if state.phase == "action" and state.turn_player == player_id \
			and state.pending_actions.is_empty() \
			and not state.combat_attack_window and not state.combat_defend_window:
		var ps_self := state.players.get(player_id) as PlayerState
		var own_hero_id: String = ps_self.hero_instance_id if ps_self else ""
		for atk_id in StackResolver.get_legal_attackers(state, player_id, db):
			var fatk := forecast_atk(state, db, atk_id)
			if fatk <= 0:
				continue   # never propose combat with a 0-ATK attacker
			for def_id in StackResolver.get_legal_defenders(state, atk_id, db):
				# HERO attacks on an enemy ALLY only when lethal on it — a hero
				# swinging into an ally it can't kill just soaks retaliation for
				# nothing (attacks on the enemy hero always qualify).
				if atk_id == own_hero_id and StackResolver._is_ally(state, def_id) \
						and fatk < state.get_current_hp(def_id, db):
					continue
				# An ALLY naming a defender that prevents all of its combat
				# damage (Brother Rhone) achieves nothing whatsoever: no damage,
				# no kill, and the defender doesn't even exhaust — only
				# PROTECTING exhausts (602.2). Nothing to weigh, so it's cut
				# here rather than scored. Note this is source-dependent: our
				# HERO attacking Rhone is a fine play (he's 0/1 and the shield
				# only stops attacking allies), and stays offered.
				# Accepted corner: an attacker with an on-attack trigger
				# (Chops, Voss) loses a zero-risk platform for firing it —
				# but attacking the HERO and using that trigger to exhaust the
				# protector before the protect point dominates it anyway.
				if GameLogic.blocks_all_combat_damage(state, db, atk_id, def_id):
					continue
				result.append(PendingAction.make("propose_combat", player_id,
					{"attacker_id": atk_id, "defender_id": def_id}))

	# Ally activated powers.
	result.append_array(_get_ally_power_actions(state, db, player_id))

	# Hero power activations.
	result.append_array(_get_hero_power_actions(state, db, player_id))

	# Resource placement — smart selection: quest face-up first, else most-copied face-down.
	var res_action := _decide_resource_placement(state, db, player_id)
	if res_action != null:
		result.append(res_action)

	return result


# Total cards drawn by a spell whose ONLY effect is drawing (Innervate).
# Returns 0 when the card does anything else — Arcane Shot's damage is worth
# playing with a full hand, its draw rider isn't the reason to hold it.
static func _pure_draw_amount(def: CardDef) -> int:
	if def.effects.strip_edges() == "":
		return 0
	var total := 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() != "draw":
			return 0
		total += int(parts[1]) if parts.size() > 1 else 1
	return total


# Rapid Fire policy: the card does nothing by itself, so playing it without the
# resources to cash it in is a wasted card. Require a READY Ranged weapon in play
# and enough resources this turn to strike with it at least TWICE:
#
#     play cost + 2 x strike cost + the grant's ready payment
#
# (the second strike is only reachable by paying the ready payment after the
# first). The cheapest ready Ranged weapon sets the bar — a player may hold more
# than one. Strike cost is read through StackResolver.get_strike_cost so
# discounts and opposing strike taxes (Margaret Fowl) count.
func _rapid_fire_worth_playing(state: GameState, db, player_id: String,
		card_id: String, def: CardDef) -> bool:
	if not db:
		return false
	var ready_cost := -1
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "rapid_fire_ready_on_strike":
			ready_cost = int(parts[1]) if parts.size() > 1 else 0
	if ready_cost < 0:
		return false
	var strike_cost := -1
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if card.is_exhausted:
			continue
		var wdef := db.get_def(card.card_def_id) as CardDef
		if not wdef or wdef.dmg_type.to_lower() != "ranged":
			continue
		if StackResolver._weapon_info(wdef).is_empty():
			continue
		var c := StackResolver.get_strike_cost(state, player_id, wdef, db)
		if c >= 0 and (strike_cost < 0 or c < strike_cost):
			strike_cost = c
	if strike_cost < 0:
		return false   # no ready Ranged weapon equipped
	var play_cost := state.get_play_cost(card_id, db)
	return state.get_available_resources(player_id) \
		>= play_cost + 2 * strike_cost + ready_cost


# Returns the best resource placement action for this player, or null if none is appropriate.
# Priority 1 — Quest in hand: place one at random face-up.
# Priority 2 — Hand > 1 card: place face-down the card with the most copies in hand
#              (random tiebreak). Avoids placing the last card and leaving hand empty.
func _decide_resource_placement(state: GameState, db, player_id: String) -> PendingAction:
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.resource_placed_this_turn:
		return null
	if state.phase != "action" or state.turn_player != player_id:
		return null
	if not state.pending_actions.is_empty():
		return null

	var hand := state.cards_in_zone(player_id + "_hand")
	if hand.is_empty():
		return null

	# Priority 1: quest in hand → place face-up.
	var quests: Array[CardInstance] = []
	for card in hand:
		if db:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and def.card_type == "Quest":
				quests.append(card)
	if not quests.is_empty():
		var pick := quests[randi() % quests.size()]
		var action := PendingAction.make("place_resource", player_id,
			{"card_id": pick.instance_id, "face_up": true})
		if StackResolver.can_submit(state, action, db):
			return action

	# Priority 2: if hand > 1 and resources aren't already plentiful, place a card
	# face-down. Not worth ramping past 9 resources if there's nothing in hand to
	# spend them on.
	var resource_count := state.cards_in_zone(player_id + "_resource_row").size()
	if hand.size() <= 1 or resource_count >= 9:
		return null

	# Rank by distance from the resource total we'd have after this placement —
	# this keeps cheap, currently-playable cards in hand and cards near-future-
	# playable, while pushing out-of-reach expensive cards (or already-affordable
	# cheap ones) toward the resource row first.
	var next_total := resource_count + 1
	var best_dist: int = -1
	var candidates: Array[CardInstance] = []
	for card in hand:
		var dist := absi(_def_cost(state, db, card.instance_id) - next_total)
		if dist > best_dist:
			best_dist = dist
			candidates = [card]
		elif dist == best_dist:
			candidates.append(card)

	if candidates.size() > 1:
		# Tiebreak 1: most duplicates in hand.
		var counts: Dictionary = {}
		for card in hand:
			counts[card.card_def_id] = counts.get(card.card_def_id, 0) + 1
		var max_count: int = 0
		for card in candidates:
			var c: int = counts[card.card_def_id]
			if c > max_count:
				max_count = c
		var dup_candidates: Array[CardInstance] = []
		for card in candidates:
			if counts[card.card_def_id] == max_count:
				dup_candidates.append(card)
		candidates = dup_candidates

	var pick: CardInstance
	if candidates.size() > 1:
		# Tiebreak 2: least valuable card (sort_valuable_cards → most valuable first).
		var ids: Array[String] = []
		for card in candidates:
			ids.append(card.instance_id)
		var least_valuable_id: String = sort_valuable_cards(state, db, ids).back()
		pick = state.get_card(least_valuable_id) as CardInstance
	else:
		pick = candidates[0]

	var dup_action := PendingAction.make("place_resource", player_id,
		{"card_id": pick.instance_id, "face_up": false})
	if StackResolver.can_submit(state, dup_action, db):
		return dup_action

	return null


# Rule 602.2: the defending player may exhaust a ready Protector to intercept,
# or return "" to skip protection.  Called by the scene after protect_point_opened.
# Base behaviour: protect with the highest current HP protector (random on tie).
# The hero (Draconian Deflector grant) is only used when no ally can step in —
# its HP pool would otherwise always win the highest-HP pick and it would
# chump-block every attack with face damage.
# A protector that takes NO damage from this attacker (Brother Rhone vs an
# attacking ally). Blocking with it costs nothing at all, so it beats any pick
# made on stats — the only thing worth more is a block that also KILLS the
# attacker (safe_lethal), which removes a card instead of just one attack.
static func blocks_for_free(state: GameState, db, protector_id: String,
		attacker_id: String) -> bool:
	return GameLogic.blocks_all_combat_damage(state, db, attacker_id, protector_id)


# Hero HP at or below which we stop treating face damage as recoverable.
# Mirrors GenericAI.HERO_ALL_OUT_HP (kept here so BaseAI has no dependency on
# its own subclass).
const FREE_BLOCK_HERO_FLOOR := 10


# Should a free block be SPENT on this attack, or held for a bigger one?
# Protecting exhausts the protector (602.2), so the free block is once per turn
# and a cheap attacker can bait it away from a real threat. Decline only when
# the attack is genuinely a cheap bait:
#   (a) the opponent has another READY ALLY attacker — it must be an ally, since
#       a hero attacker couldn't be blocked for free either (the shield only
#       stops attacking allies, so the protector would simply die); and
#   (b) its forecast ATK is STRICTLY greater than this attacker's — on a tie,
#       certain value now beats equal uncertain value later; and
#   (c) this attack is recoverable — it kills nothing of ours and leaves our
#       hero above the floor. A dead ally is permanent, an unblocked hit is not,
#       so a "bait" that actually kills something is answered immediately.
# Residual risk (unavoidable without modelling intent): if they never swing the
# bigger ally, we ate the small hit and the block went unused. (b) and (c) bound
# that loss to something small, non-lethal and card-free. Allies arriving later
# (instant-speed or Ferocity) are outside this read for the same reason.
static func free_block_worth_spending(state: GameState, db, player_id: String,
		attacker_id: String, defender_id: String) -> bool:
	var a_atk := forecast_atk(state, db, attacker_id, true)

	# (c) — anything unrecoverable is blocked right now.
	var ps := state.players.get(player_id) as PlayerState
	var hero_id: String = ps.hero_instance_id if ps else ""
	if defender_id == hero_id:
		if state.get_current_hp(hero_id, db) - a_atk <= FREE_BLOCK_HERO_FLOOR:
			return true
	elif a_atk >= state.get_current_hp(defender_id, db):
		return true   # the defender would die — save the card now

	# (a) + (b) — hold the block only for a strictly bigger ready ALLY attacker.
	# The current attacker exhausted when combat started, so it can't appear here.
	var opp := "p2" if player_id == "p1" else "p1"
	for aid in StackResolver.get_legal_attackers(state, opp, db):
		if aid == attacker_id or not StackResolver._is_ally(state, aid):
			continue
		if forecast_atk(state, db, aid, true) > a_atk:
			return false
	return true


func choose_protector(state: GameState, db, player_id: String) -> String:
	var protectors := StackResolver.get_legal_protectors(
		state, state.combat_attacker, state.combat_defender, db)
	if protectors.is_empty():
		return ""
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.hero_instance_id in protectors and protectors.size() > 1:
		protectors.erase(ps.hero_instance_id)
	for p in protectors:
		if blocks_for_free(state, db, p, state.combat_attacker) \
				and free_block_worth_spending(state, db, player_id,
					state.combat_attacker, state.combat_defender):
			return p
	var best_id := protectors[0]
	var best_hp := state.get_current_hp(best_id, db)
	for i in range(1, protectors.size()):
		var hp := state.get_current_hp(protectors[i], db)
		if hp > best_hp:
			best_hp = hp
			best_id = protectors[i]
		elif hp == best_hp and randi() % 2 == 0:
			best_id = protectors[i]
	return best_id


# ── Weapon strikes (rules 303 / 602.1 / 602.3) ────────────────────────────────

# Forecast ATK for a would-be attacker: "while attacking" bonuses plus, for a
# hero that could still strike, the best affordable ready weapon's ATK.
# Affordability uses that controller's CURRENT resources — this also works for
# the OPPONENT's hero (resources are public information), so protector/trade
# math can anticipate an enemy strike. Once a strike has actually happened,
# get_atk already includes the association and get_strikeable_weapons returns
# [] (weapon exhausted / one-per-combat), so nothing is double-counted.
# assume_attacking=false forecasts the character as a DEFENDER (no "while
# attacking" bonuses, but a hero may still strike defensively per 602.3).
static func forecast_atk(state: GameState, db, attacker_id: String,
		assume_attacking: bool = true) -> int:
	var atk := state.get_atk(attacker_id, db, assume_attacking)
	var card := state.get_card(attacker_id)
	if card and db:
		var best := 0
		for wid in StackResolver.get_strikeable_weapons(state, card.controller, attacker_id, db):
			if _is_power_weapon(state, db, wid):
				continue   # held for its activated power, never forecast as strike ATK
			best = maxi(best, state.get_atk(wid, db))
		atk += best
	return atk


# "Power weapon" (effects flag `power_weapon`, e.g. Rod of the Ogre Magi):
# a weapon whose real value is its activated power — striking with it is an
# inefficient use of the exhaust (high cost, low ATK). The AI never strikes
# with one and never counts it in forecast_atk; the engine still allows a
# human to strike normally.
static func _is_power_weapon(state: GameState, db, weapon_id: String) -> bool:
	var card := state.get_card(weapon_id)
	if not card or not db:
		return false
	return StackResolver._has_effect_flag(db.get_def(card.card_def_id) as CardDef, "power_weapon")


# Strike decision — called by the scene on strike_point_opened when the pending
# player is an AI. Returns the weapon instance_id to strike with, or "" to pass.
#   Attacking: always strike with the best (highest-ATK) offered weapon — the
#   hero attack was proposed because of the weapon in the first place.
#   Defending: strike when the counter-damage KILLS the attacker, or when the
#   attacker is the opponent's LAST legal attacker (nothing later is worth
#   saving the weapon/resources for — no reason not to defend ourselves).
#   Earlier in the turn the weapon is held unless it kills: better to kill a
#   random attacker than to spend it on one that survives the strike.
#   Never strike defensively against a Long-Range attacker — the defender
#   deals no combat damage back, so the strike would be wasted.
func choose_strike_weapon(state: GameState, db, player_id: String) -> String:
	if state.pending_strike_weapon_ids.is_empty() or not db:
		return ""
	# Power weapons (Rod of the Ogre Magi) are held for their activated power —
	# never strike with one.
	var offered: Array[String] = []
	for wid in state.pending_strike_weapon_ids:
		if not _is_power_weapon(state, db, wid):
			offered.append(wid)
	if offered.is_empty():
		return ""
	var best := offered[0]
	var best_atk := state.get_atk(best, db)
	for i in range(1, offered.size()):
		var a := state.get_atk(offered[i], db)
		if a > best_atk:
			best_atk = a
			best = offered[i]

	if state.pending_strike_side == "attack":
		return best

	# Defending.
	var attacker := state.get_card(state.combat_attacker)
	if not attacker:
		return ""
	if StackResolver._has_keyword(attacker, "long_range", db, state):
		return ""   # we'd deal no combat damage back anyway
	# A PROTECTING hero always retaliates when it can afford to (offered
	# weapons are pre-filtered by affordability): the opponent is attacking
	# around the hero, so this is likely the weapon's only use this turn.
	var ps := state.players.get(player_id) as PlayerState
	if ps and state.combat_protector == state.combat_defender \
			and state.combat_defender == ps.hero_instance_id:
		return best
	var counter_dmg := state.get_atk(state.combat_defender, db) + best_atk
	if counter_dmg >= state.get_current_hp(state.combat_attacker, db):
		return best   # the strike kills the attacker — take the trade now
	# Last visible legal attacker? The current attacker is already exhausted, so
	# it no longer appears in get_legal_attackers — an empty list means nothing
	# else can attack us this turn.
	if StackResolver.get_legal_attackers(state, attacker.controller, db).is_empty():
		return best
	return ""


# Ready-on-attack decision (Windseer Tarus) — called by the scene on
# ready_on_attack_opened when the pending player is an AI. Returns true to pay and
# ready (attack again this turn). We pay only when the attacker will SURVIVE this
# combat: attacking the opposing hero (heroes deal no combat damage back), or an
# opposing ally whose counter-damage leaves the attacker alive. Otherwise the
# resource is likely wasted (it dies before the second attack).
func choose_ready_on_attack(state: GameState, db, _player_id: String) -> bool:
	var card_id := state.pending_ready_card_id
	if card_id == "" or not db:
		return false
	var defender_id := state.combat_defender
	var defender := state.get_card(defender_id)
	if not defender:
		return false
	# Attacking the hero: no combat damage back → the attacker always survives.
	var def_zone := state.zones.get(defender.zone_id) as Zone
	if def_zone and def_zone.zone_type == "hero_row":
		return true
	# Attacking an ally: only pay if we outlive the retaliation.
	var counter := state.get_atk(defender_id, db)
	return state.get_current_hp(card_id, db) > counter


# Ready-on-strike decision (Windfury Weapon) — called by the scene on
# ready_on_strike_opened when the pending player is an AI. Paying readies the
# struck weapon AND the hero, letting the hero attack again this turn. Only worth
# it while ATTACKING (the hero exhausted to attack, so readying frees a second
# attack); defending, the readied hero has nothing to spend it on this combat.
func choose_ready_on_strike(state: GameState, db, _player_id: String) -> bool:
	if not db:
		return false
	return state.pending_strike_ready_side == "attack"


# Chops / Voss Treebender: "When [this] attacks, you may exhaust target hero or
# ally." Pick the target to exhaust, or "" to decline. The point of the trigger
# is denying the protect point (602.2 — a protector must exhaust to protect), so
# exhaust the most dangerous READY legal protector on the defending side: prefer
# one whose retaliation would kill our attacker, else the highest-ATK one.
# Exhausting anything else (e.g. the defender) buys nothing — decline instead.
func choose_attack_exhaust(state: GameState, db, _player_id: String) -> String:
	var attacker_id := state.combat_attacker
	if attacker_id == "" or not db:
		return ""
	var protectors := StackResolver.get_legal_protectors(
		state, attacker_id, state.combat_defender, db)
	var targetable := StackResolver.get_attack_exhaust_targets(state, db)
	var our_hp  := state.get_current_hp(attacker_id, db)
	var best    := ""
	var best_atk := -1
	var best_kills := false
	for pid in protectors:
		if pid not in targetable:
			continue
		var p_atk := state.get_atk(pid, db)
		var kills := p_atk >= our_hp
		if (kills and not best_kills) or ((kills == best_kills) and p_atk > best_atk):
			best       = pid
			best_atk   = p_atk
			best_kills = kills
	return best


# Boneshanks death trigger: "When [this] is destroyed, destroy target ally."
# The choice is MANDATORY if any ally is in play, so this never declines. Prefer
# the most valuable OPPOSING ally; only if the opponent has none, destroy our own
# least valuable ally (forced — the trigger must resolve). `player_id` is the
# destroyed Boneshanks' controller.
func choose_death_target(state: GameState, db, player_id: String) -> String:
	if not db:
		return ""
	var legal := StackResolver.get_death_target_targets(state, db)
	if legal.is_empty():
		return ""
	var opp := "p2" if player_id == "p1" else "p1"
	var enemy: Array[String] = []
	var own:   Array[String] = []
	for tid in legal:
		var card := state.get_card(tid)
		if card and card.controller == opp:
			enemy.append(tid)
		else:
			own.append(tid)
	if not enemy.is_empty():
		# Highest-value enemy ally first.
		var ranked := sort_valuable_cards(state, db, enemy)
		return ranked[0]
	# Forced to hit our own board: give up the least valuable ally.
	var ranked_own := sort_valuable_cards(state, db, own)
	return ranked_own[ranked_own.size() - 1]


# ── Quest reward choices ("Choose one … you may choose both") ────────────────
# Hidden Enemies / A New Plague / Thwarting Kolkar Aggression / Crown of the
# Earth. Policy: ALWAYS take both modes when the race condition allows it
# (free value — draw last so an earlier mode can't eat the fresh card).
# Single pick: the special mode when it's currently useful, else the draw.
func choose_quest_modes(state: GameState, db, player_id: String) -> Array:
	var special := ""
	var draw_mode := ""
	for entry in state.pending_quest_choice_modes:
		if not entry.get("available", false):
			continue
		var m: String = entry.get("mode", "")
		if m.begins_with("draw"):
			draw_mode = m
		else:
			special = m
	if special == "":
		return [draw_mode]
	if draw_mode == "" :
		return [special]
	if state.pending_quest_choice_can_both:
		return [special, draw_mode]   # both, special first, draw last
	return [special] if _quest_mode_useful(state, db, player_id, special) \
			else [draw_mode]


# Is a non-draw reward mode worth taking over a plain draw right now?
func _quest_mode_useful(state: GameState, db, player_id: String,
		mode: String) -> bool:
	match mode.split(":")[0]:
		"ally_ferocity_this_turn":
			# Only useful on one of OUR summoning-sick attackers.
			return _best_ferocity_target(state, db, player_id, true) != ""
		"each_player_destroys_ally":
			# Availability already requires an ally of ours; useful only when the
			# opponent loses one too (never plain self-harm — AI convention).
			var opp := "p2" if player_id == "p1" else "p1"
			return not state.cards_in_zone(opp + "_ally_row").is_empty()
		"opponent_quest_face_down":
			return true   # available implies an opposing quest to deny
		"hand_to_deck_draw":
			return _hand_is_dead(state, db, player_id)
	return false


# Shared "is this hand worth cycling?" test behind every hand_to_deck_draw
# effect (Crown of the Earth's reward mode, Ilandre Moonspear's power): more
# than two cards in hand and none of them currently affordable. Below three
# cards the swap trades away more than it is likely to fix.
func _hand_is_dead(state: GameState, db, player_id: String) -> bool:
	var hand := state.cards_in_zone(player_id + "_hand")
	if hand.size() < 3:
		return false
	var avail := state.get_available_resources(player_id)
	for card in hand:
		var def: CardDef = db.get_def(card.card_def_id) if db else null
		if def and def.cost >= 0 and def.cost <= avail:
			return false
	return true


# Hidden Enemies: pick the ally that gains ferocity this turn — our highest-ATK
# summoning-sick ally, else (forced pick) our highest-value legal ally, else
# whatever is legal.
func choose_quest_ferocity_target(state: GameState, db,
		player_id: String) -> String:
	var best := _best_ferocity_target(state, db, player_id, true)
	if best != "":
		return best
	var legal := StackResolver.get_quest_ferocity_targets(state, db)
	if legal.is_empty():
		return ""
	var own: Array[String] = []
	for tid in legal:
		var card := state.get_card(tid)
		if card and card.controller == player_id:
			own.append(tid)
	if not own.is_empty():
		return sort_valuable_cards(state, db, own)[0]
	return legal[0]


# Our best summoning-sick ally to un-sick: highest ATK, must be a legal target
# and not already ferocious. "" when none qualifies.
func _best_ferocity_target(state: GameState, db, player_id: String,
		_require_sick: bool) -> String:
	var legal := StackResolver.get_quest_ferocity_targets(state, db)
	var best := ""
	var best_atk := 0
	for tid in legal:
		var card := state.get_card(tid)
		if not card or card.controller != player_id:
			continue
		if not card.just_summoned:
			continue
		if StackResolver._has_keyword(card, "ferocity", db, state):
			continue
		var atk := state.get_atk(tid, db)
		if atk > best_atk:
			best_atk = atk
			best = tid
	return best


# A New Plague: sacrifice our least valuable ally.
func choose_plague_destroy(state: GameState, db, player_id: String) -> String:
	var own: Array[String] = []
	for card in state.cards_in_zone(player_id + "_ally_row"):
		own.append(card.instance_id)
	if own.is_empty():
		return ""
	var ranked := sort_valuable_cards(state, db, own)
	return ranked[ranked.size() - 1]


# Thwarting Kolkar Aggression (as the TARGET): flip our least valuable face-up
# quest — lowest rarity first, then lowest reward resource cost, random tie.
func choose_quest_facedown(state: GameState, db, _player_id: String) -> String:
	var ids := state.pending_quest_facedown_ids
	if ids.is_empty():
		return ""
	var pool := ids.duplicate()
	pool.shuffle()   # random tiebreak
	pool.sort_custom(func(a, b) -> bool:
		var da: CardDef = db.get_def(state.get_card(a).card_def_id) if db else null
		var db_: CardDef = db.get_def(state.get_card(b).card_def_id) if db else null
		var ra: int = _RARITY_RANK.get(da.rarity.to_lower(), 1) if da else 1
		var rb: int = _RARITY_RANK.get(db_.rarity.to_lower(), 1) if db_ else 1
		if ra != rb:
			return ra < rb
		return (da.cost if da else 0) < (db_.cost if db_ else 0))
	return pool[0]


# Green Whelp Armor: after an attacking ally damaged our hero, decide whether to
# pay to bounce it to its owner's hand. Worth it when the ally is expensive enough
# that costing the opponent a re-cast (and our 2 resources) is a good trade — and
# especially when it's a strong repeat attacker we'd rather not face again.
func choose_whelp_bounce(state: GameState, db, _player_id: String) -> bool:
	var ally_id := state.pending_whelp_bounce_ally_id
	if ally_id == "" or not db:
		return false
	var ally := state.get_card(ally_id)
	if not ally:
		return false
	var def := db.get_def(ally.card_def_id) as CardDef
	if not def:
		return false
	# Bounce allies whose cost is at least the 2 we spend (net tempo neutral or
	# better; the opponent must also re-pay the full cost to redeploy it).
	return def.cost >= 2


# Returns activate_power actions for the player's hero.
func _get_ally_power_actions(state: GameState, db, player_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	if state.phase != "action" or state.turn_player != player_id:
		return result
	if not state.pending_actions.is_empty():
		return result
	# Activated powers come from allies (ally row) and equipment (hero row).
	var power_sources: Array[CardInstance] = []
	power_sources.append_array(state.cards_in_zone(player_id + "_ally_row"))
	power_sources.append_array(state.cards_in_zone(player_id + "_hero_row"))
	for card in power_sources:
		if not db:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var ap := StackResolver._ally_activated_power(def)
		if ap.is_empty():
			continue
		var extra_cost_str: String = ap.get("extra_cost", "")
		var once_per_turn: bool = extra_cost_str == "once_per_turn"
		# put_damage_self / no_activate (e.g. Acolyte Demia, Hierophant Caydiem)
		# have no [Activate] tap symbol — 701.2 payment powers, not gated by
		# summoning sickness or exhaustion. Mirrors StackResolver._can_use_ally_power.
		var no_activate_symbol: bool = extra_cost_str.begins_with("put_damage_self") \
			or extra_cost_str == "no_activate" or extra_cost_str == "sacrifice_self"
		if once_per_turn:
			if card.used_this_turn:
				continue
		elif not no_activate_symbol and (card.is_exhausted or card.just_summoned):
			continue
		# Don't draw past max hand size (the excess would just be discarded at
		# wrap-up) — amount-aware, so Mana Agate (draw 2) only fires when the
		# hand has room for both cards.
		if ap.get("effect", "") == "draw" and ap.get("targets", "") != "friendly_ally":
			var max_hand := state.get_max_hand_size(player_id, db)
			var draw_n: int = int(ap.get("amount", 1))
			if state.cards_in_zone(player_id + "_hand").size() > max_hand - draw_n:
				continue
			# Kena Shadowbrand pays with self-damage — don't draw herself to death.
			if extra_cost_str.begins_with("activate_put_damage_self"):
				var self_dmg := int(extra_cost_str.split(":")[1]) if extra_cost_str.split(":").size() > 1 else 1
				if state.get_current_hp(card.instance_id, db) <= self_dmg:
					continue
		# Ilandre Moonspear: only cycle a hand that is actually dead — the swap
		# costs every card we hold, so it must be trading nothing for something.
		if ap.get("effect", "") == "hand_to_deck_draw" \
				and not _hand_is_dead(state, db, player_id):
			continue
		if ap.get("effect", "") == "buff_atk_target_attacking":
			# Ryn Dreamstrider: friendly +ATK buff — never target the enemy.
			# Pick our own highest-ATK ready attacker (ally or hero).
			var best_id := ""
			var best_atk := -1
			for ally in state.cards_in_zone(player_id + "_ally_row"):
				if ally.instance_id == card.instance_id:
					continue  # Ryn exhausts to buff — buffing himself wastes his own attack
				if ally.is_exhausted or ally.just_summoned:
					continue
				var a := state.get_atk(ally.instance_id, db)
				if a > best_atk:
					best_atk = a
					best_id = ally.instance_id
			var ps_own := state.players.get(player_id) as PlayerState
			if ps_own and ps_own.hero_instance_id != "":
				var hero_card := state.get_card(ps_own.hero_instance_id)
				if hero_card and not hero_card.is_exhausted:
					var ha := state.get_atk(ps_own.hero_instance_id, db)
					if ha > best_atk:
						best_atk = ha
						best_id = ps_own.hero_instance_id
			if best_id != "":
				var act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_id})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
		elif ap.get("effect", "") == "destroy_ally" and extra_cost_str == "sacrifice_ally":
			# Gertha, The Old Crone: "1, Destroy an ally in your party -> Destroy
			# target ally." Sacrifice our LOWEST-value own ally (never Gertha
			# herself — she's the engine) to destroy the enemy's HIGHEST-value
			# ally, and only when the kill is worth more than what we give up
			# (don't trade a body for a token). Random tiebreak on equal value.
			var opp_g := "p2" if player_id == "p1" else "p1"
			var kill_id := ""
			var kill_val := -1.0
			for enemy in state.cards_in_zone(opp_g + "_ally_row"):
				var v := card_value_score(state, db, enemy.instance_id)
				if v > kill_val or (v == kill_val and randi() % 2 == 0):
					kill_val = v
					kill_id = enemy.instance_id
			var sac_id := ""
			var sac_val := INF
			for own in state.cards_in_zone(player_id + "_ally_row"):
				if own.instance_id == card.instance_id:
					continue  # keep Gertha in play to reuse the power
				var v := card_value_score(state, db, own.instance_id)
				if v < sac_val or (v == sac_val and randi() % 2 == 0):
					sac_val = v
					sac_id = own.instance_id
			if kill_id != "" and sac_id != "" and kill_val > sac_val:
				var act := PendingAction.make("use_ally_power", player_id, {
					"card_id": card.instance_id, "target_id": kill_id,
					"sacrifice_id": sac_id,
				})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
		elif ap.get("effect", "") == "destroy_ally":
			# Augustus Corpsemonger: "Destroy target ally" (cost: exile 3 ally
			# cards from your graveyard). Enemy allies only, and only when the
			# kill is worth it (target cost >= 3, no friendly solo-kill available).
			var opp_d := "p2" if player_id == "p1" else "p1"
			var best_kill := ""
			var best_kill_cost := -1
			for enemy in state.cards_in_zone(opp_d + "_ally_row"):
				if not _destroy_is_worth_it(state, db, player_id, enemy.instance_id, 3):
					continue
				var e_def := _card_def(state, db, enemy.instance_id)
				var e_cost := e_def.cost if e_def else 0
				if e_cost > best_kill_cost:
					best_kill_cost = e_cost
					best_kill = enemy.instance_id
			if best_kill != "":
				var act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_kill})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
		elif ap.get("effect", "") == "destroy_ability" \
				and ap.get("extra_cost", "") != "sacrifice_self":
			# Lafiel: "2, [Activate] -> Destroy target ability." Opposing in-play
			# abilities only (never our own ongoing/attachments), highest-cost
			# first — same value bar as Burn Away's AI branch, except the power
			# is repeatable across turns, so a cheap target is still fine once
			# there is nothing better: the only cost is 2 and her tap.
			# A sacrifice_self version (Confessor Mildred) is excluded above: it costs
			# the ally itself, so it goes through doomed_sacrifice_action instead and
			# is only cashed in when she is dying anyway.
			var opp_ab := "p2" if player_id == "p1" else "p1"
			var best_ab := ""
			var best_ab_cost := -1
			for cid in StackResolver.get_destroy_kind_candidates(state, db, "ability"):
				var ab_card := state.get_card(cid)
				if not ab_card or ab_card.controller != opp_ab:
					continue
				var ab_def := _card_def(state, db, cid)
				var ab_cost := ab_def.cost if ab_def else 0
				if ab_cost > best_ab_cost:
					best_ab_cost = ab_cost
					best_ab = cid
			if best_ab != "":
				var act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_ab})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
		elif ap.get("effect", "") == "rfg_graveyard_ally":
			# Ophelia Barrows: exile an ally card from any graveyard, heal 1 from
			# herself if it happens. Only ever exile from the OPPONENT's graveyard
			# (own graveyard denial is pure downside); worth the 1 resource when
			# she's damaged (the heal has value) or the exiled card is expensive
			# (denies graveyard recursion à la Chasing A-Me / Finkle Einhorn).
			var gy_req := StackResolver.get_graveyard_search_requirement(def)
			var gy_cands := StackResolver.get_graveyard_search_candidates(
				state, player_id, gy_req, db)
			var opp_gy := ("p2" if player_id == "p1" else "p1") + "_graveyard"
			var best_gy := ""
			var best_gy_cost := -1
			for tid in gy_cands:
				var t := state.get_card(tid)
				if not t or t.zone_id != opp_gy:
					continue
				var t_def := _card_def(state, db, tid)
				var t_cost := t_def.cost if t_def else 0
				if t_cost > best_gy_cost:
					best_gy_cost = t_cost
					best_gy = tid
			if best_gy != "" and (card.damage_taken > 0 or best_gy_cost >= 3):
				var gy_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_gy})
				if StackResolver.can_submit(state, gy_act, db):
					result.append(gy_act)
		elif ap.get("effect", "") == "discard_opponent":
			# Hypnotic Blade: force the opponent to discard. Only worth the cost
			# while they actually hold cards.
			var opp_disc := "p2" if player_id == "p1" else "p1"
			if not state.cards_in_zone(opp_disc + "_hand").is_empty():
				var disc_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": ""})
				if StackResolver.can_submit(state, disc_act, db):
					result.append(disc_act)
		elif ap.get("effect", "") == "draw" and ap.get("targets", "") == "friendly_ally":
			# Bizzik Sparkcog: "Destroy an ally in your party: draw a card."
			# Only sacrifice an ally that's already mortally wounded (about to die
			# anyway) — never throw away a healthy body for a single card.
			var max_hand2 := state.get_max_hand_size(player_id, db)
			if state.cards_in_zone(player_id + "_hand").size() < max_hand2:
				for own in state.cards_in_zone(player_id + "_ally_row"):
					if state.get_current_hp(own.instance_id, db) > 0 and own.damage_taken == 0:
						continue
					var act := PendingAction.make("use_ally_power", player_id,
						{"card_id": card.instance_id, "target_id": own.instance_id})
					if StackResolver.can_submit(state, act, db):
						result.append(act)
						break
		elif ap.get("targets", "") in ["hero_or_ally"]:
			var is_heal: bool = ap.get("effect", "") == "heal_target"
			var candidates: Array[String] = []
			if is_heal:
				# Heal: FRIENDLY damaged characters only — never heal the enemy.
				var ps_own := state.players.get(player_id) as PlayerState
				if ps_own and ps_own.hero_instance_id != "" \
						and state.get_card(ps_own.hero_instance_id).damage_taken > 0:
					candidates.append(ps_own.hero_instance_id)
				for ally in state.cards_in_zone(player_id + "_ally_row"):
					if ally.damage_taken > 0:
						candidates.append(ally.instance_id)
				if candidates.is_empty():
					continue   # nothing worth healing — don't waste the power
			else:
				# Damage: only consider enemy characters (never self-target friendlies).
				var opp := "p2" if player_id == "p1" else "p1"
				for ally in state.cards_in_zone(opp + "_ally_row"):
					candidates.append(ally.instance_id)
				var ps_opp := state.players.get(opp) as PlayerState
				if ps_opp and ps_opp.hero_instance_id != "":
					candidates.append(ps_opp.hero_instance_id)
			candidates.sort_custom(func(a: String, b: String) -> bool:
				var ca := state.get_card(a)
				var cb := state.get_card(b)
				var a_dmg := ca.damage_taken if ca else 0
				var b_dmg := cb.damage_taken if cb else 0
				return a_dmg > b_dmg)
			# Baseline: lethal targets first (hero-only when hero is lethal —
			# see find_lethal / ai_functions.md), ranked by the subclass hook,
			# then the remaining candidates in most-damaged order.
			var lethal := find_lethal(state, db, player_id, int(ap.get("amount", 0)))
			var lethal_pool: Array[String] = []
			for tid in candidates:
				if tid in lethal:
					lethal_pool.append(tid)
			var ordered: Array[String] = rank_lethal_targets(state, db, lethal_pool)
			for tid in candidates:
				if tid not in ordered:
					ordered.append(tid)
			for target_id in ordered:
				var act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": target_id})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
					break
		elif ap.get("targets", "") == "hero_or_ally_two":
			# Hierophant Caydiem: damage an enemy, heal a damaged friendly — two
			# distinct targets. Mirrors _damage_and_heal_actions for hero powers.
			result.append_array(_ally_damage_and_heal_actions(state, db, player_id, card.instance_id, int(ap.get("amount", 0))))
		elif ap.get("effect", "") == "exhaust_target":
			# Galahandra: held like Exhaustion, never blind-played on our own
			# turn — only used in response to an opposing combat proposal, see
			# exhaust_attacker_ally_power_action().
			continue
		elif ap.get("targets", "") == "ally":
			# Friendly buff powers (Elder Moorf): target our own highest-ATK ally
			# so the +ATK swing lands where it matters most. Never buffs the enemy.
			var best_ally := ""
			var best_atk := -1
			for ally in state.cards_in_zone(player_id + "_ally_row"):
				var a := state.get_atk(ally.instance_id, db)
				if a > best_atk:
					best_atk = a
					best_ally = ally.instance_id
			if best_ally != "":
				var act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_ally})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
		else:
			var action := PendingAction.make("use_ally_power", player_id,
				{"card_id": card.instance_id})
			if StackResolver.can_submit(state, action, db):
				result.append(action)
	return result


# For targeted powers, one action is created per valid target.
# For untargeted powers, one action is created with no target_id.
func _get_hero_power_actions(state: GameState, db, player_id: String) -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return result
	var hero_id := ps.hero_instance_id
	var needs_target := _hero_power_needs_target(state, db, hero_id)

	if needs_target:
		# target_cant_attack (Litori Frostburn): held for defense — never
		# blind-played on our own turn. See hero_disable_action().
		if _hero_power_is(state, db, hero_id, "target_cant_attack"):
			return result
		# deal_x_damage_to_ally: pick best target and optimal X.
		if _hero_power_is(state, db, hero_id, "deal_x_damage_to_ally"):
			result.append_array(_x_damage_ally_actions(state, db, player_id, hero_id))
		# deal_7_minus_hand_to_hero: only fire when damage > 0 (enemy hand has < 7 cards).
		elif _hero_power_is(state, db, hero_id, "deal_7_minus_hand_to_hero"):
			var opp_id2 := _other_player_id(state, player_id)
			var opp_hand := state.cards_in_zone(opp_id2 + "_hand").size()
			var dmg2: int = max(7 - opp_hand, 0)
			if dmg2 > 0:
				var opp_ps2 := state.players.get(opp_id2) as PlayerState
				if opp_ps2 and opp_ps2.hero_instance_id != "":
					var action := PendingAction.make("activate_power", player_id,
						{"hero_id": hero_id, "target_id": opp_ps2.hero_instance_id})
					if StackResolver.can_submit(state, action, db):
						result.append(action)
		elif _hero_power_is(state, db, hero_id, "heal_x_from_target"):
			result.append_array(_x_heal_actions(state, db, player_id, hero_id))
		elif _hero_power_is(state, db, hero_id, "radak_pet_sacrifice"):
			result.append_array(_radak_sacrifice_actions(state, db, player_id, hero_id))
		elif _hero_power_is(state, db, hero_id, "graveyard_to_hand"):
			result.append_array(_graveyard_to_hand_hero_actions(state, db, player_id, hero_id))
		# deal_damage_and_heal needs two distinct targets — enumerate all valid pairs.
		elif _hero_power_is(state, db, hero_id, "deal_damage_and_heal"):
			result.append_array(_damage_and_heal_actions(state, db, player_id, hero_id))
		else:
			# Single-target powers: enemy targets only (never damage/destroy own cards).
			var is_destroy_power := _hero_power_is(state, db, hero_id, "destroy_exhausted_ally")
			var power_cost := _hero_power_cost(state, db, hero_id)
			var opp_id3 := _other_player_id(state, player_id)
			var opp_ps3 := state.players.get(opp_id3) as PlayerState
			var legal: Array[PendingAction] = []
			var legal_ids: Array[String] = []
			if opp_ps3 and opp_ps3.hero_instance_id != "":
				var action := PendingAction.make("activate_power", player_id,
					{"hero_id": hero_id, "target_id": opp_ps3.hero_instance_id})
				if StackResolver.can_submit(state, action, db):
					legal.append(action)
					legal_ids.append(opp_ps3.hero_instance_id)
			for card in state.cards_in_zone(opp_id3 + "_ally_row"):
				var action := PendingAction.make("activate_power", player_id,
					{"hero_id": hero_id, "target_id": card.instance_id})
				if not StackResolver.can_submit(state, action, db):
					continue
				if is_destroy_power and not _destroy_is_worth_it(state, db, player_id, card.instance_id, power_cost):
					continue
				legal.append(action)
				legal_ids.append(card.instance_id)
			# Baseline for damage powers (e.g. Ta'zo): when any legal target dies
			# to this damage, offer ONLY lethal targets — so even a random AI
			# picks a kill (the hero alone if the hero is lethal). See
			# find_lethal / ai_functions.md.
			var dmg_amount := _hero_power_damage_amount(state, db, hero_id)
			if dmg_amount > 0:
				var lethal_pool: Array[String] = []
				for tid in find_lethal(state, db, player_id, dmg_amount):
					if tid in legal_ids:
						lethal_pool.append(tid)
				if not lethal_pool.is_empty():
					# Commit to the best-ranked kill (subclass hook decides "best").
					var top: String = rank_lethal_targets(state, db, lethal_pool)[0]
					legal = [legal[legal_ids.find(top)]]
			result.append_array(legal)
	else:
		# melee_strike_discount (Gorebelly): the flip is only worth it when the
		# discount saves more than the flip costs on a strike we can actually
		# make this turn — ready hero (it will attack), ready melee weapon, and
		# net save = min(discount, strike cost) − flip cost > 0. With cheap
		# weapons (e.g. Krol Blade, strike 1) the flip is never proposed.
		if _hero_power_is(state, db, hero_id, "melee_strike_discount"):
			if not _strike_discount_worth_it(state, db, player_id, hero_id):
				return result
			# Elendril: "Your Ranged weapons have +3 ATK this turn." Only flip when
			# it turns a non-lethal board into a lethal one (subclass hook — see
			# GenericAI._ranged_bonus_flip_worth_it). BaseAI/FullRandomAI never
			# blind-flip it (no lethal reasoning → the resource would be wasted).
			if _hero_power_is(state, db, hero_id, "ranged_weapon_atk_bonus"):
				if not _ranged_bonus_flip_worth_it(state, db, player_id, hero_id):
					return result
		var action := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": ""})
		if StackResolver.can_submit(state, action, db):
			result.append(action)

	return result


# Elendril's flip ("Your Ranged weapons have +3 ATK this turn"). Overridden by
# GenericAI to flip only when the bonus enables a lethal that isn't there now.
# BaseAI/FullRandomAI don't reason about lethal, so they never flip it.
func _ranged_bonus_flip_worth_it(_state: GameState, _db, _player_id: String,
		_hero_id: String) -> bool:
	return false


func _strike_discount_worth_it(state: GameState, db, player_id: String,
		hero_id: String) -> bool:
	var hero := state.get_card(hero_id)
	if not hero or hero.is_exhausted:
		return false   # hero can't attack anymore — no strike coming
	var hero_def := db.get_def(hero.card_def_id) as CardDef
	var flip_cost: int = max(hero_def.cost, 0) if hero_def else 0
	var discount := 0
	if hero_def:
		for entry in hero_def.effects.split("|"):
			var parts := entry.strip_edges().split(":")
			if parts[0] == "melee_strike_discount":
				discount = int(parts[1]) if parts.size() > 1 else 0
	if discount <= 0:
		return false
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if card.is_exhausted:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.dmg_type.to_lower() != "melee":
			continue
		var info := StackResolver._weapon_info(def)
		if info.is_empty():
			continue
		var strike_cost: int = info.get("strike_cost", 0)
		# Must be able to afford flip + discounted strike, and save net resources.
		var total: int = flip_cost + max(0, strike_cost - discount)
		if mini(discount, strike_cost) > flip_cost \
				and total <= state.get_available_resources(player_id):
			return true
	return false


func _hero_power_is(state: GameState, db, hero_id: String, effect_key: String) -> bool:
	var hero := state.get_card(hero_id)
	if not hero or not db:
		return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def:
		return false
	return StackResolver._power_effect_is(def, effect_key)


# Picks the best (target, x_value) pair for deal_x_damage_to_ally powers.
# X heuristic: min(enemy ally current HP, hero HP - 1), floored at 1.
# Prefers: lethal hit on highest-cost target; among non-lethal, maximize damage.
# Protector ties are broken the same as _best_damage_target.
func _x_damage_ally_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	var hero_hp := state.get_current_hp(hero_id, db)
	if hero_hp <= 1:
		return []   # Can't use without killing self (x >= 1 required, x < hero_hp).
	var max_x := hero_hp - 1
	var opp_id := _other_player_id(state, player_id)
	# Gather enemy allies and their current HP.
	var candidates: Array = []
	for card in state.cards_in_zone(opp_id + "_ally_row"):
		candidates.append(card.instance_id)
	if candidates.is_empty():
		return []
	# Sort by: lethal first (highest cost wins ties), then most damage dealt.
	candidates.sort_custom(func(a: String, b: String) -> bool:
		var hp_a: int = state.get_current_hp(a, db)
		var hp_b: int = state.get_current_hp(b, db)
		var x_a: int = min(hp_a, max_x)
		var x_b: int = min(hp_b, max_x)
		var lethal_a: bool = x_a >= hp_a
		var lethal_b: bool = x_b >= hp_b
		if lethal_a != lethal_b:
			return lethal_a
		# Both lethal or both non-lethal: prefer highest cost, then protector.
		var da := _card_def(state, db, a)
		var db_ := _card_def(state, db, b)
		var cost_a := da.cost if da else 0
		var cost_b := db_.cost if db_ else 0
		if cost_a != cost_b:
			return cost_a > cost_b
		var prot_a: bool = da != null and "Protector" in da.keywords
		var prot_b: bool = db_ != null and "Protector" in db_.keywords
		return prot_a and not prot_b
	)
	for target_id in candidates:
		var target_hp := state.get_current_hp(target_id, db)
		# Use the minimum X that kills, or max affordable if non-lethal.
		var x_value: int = min(target_hp, max_x)
		if x_value < 1:
			continue
		var act := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": target_id, "x_value": x_value})
		if StackResolver.can_submit(state, act, db):
			return [act]
	return []


# heal_x_from_target AI: find the most-damaged friendly target; heal it for
# min(damage_on_target, available_resources). Only fires if target has damage.
# Hero is preferred over allies (keeping the hero alive matters most).
func _x_heal_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	var avail := state.get_available_resources(player_id)
	if avail < 1:
		return []
	# Collect damaged friendly targets: hero first, then allies.
	var candidates: Array[String] = []
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.hero_instance_id != "" and state.is_in_play(ps.hero_instance_id):
		candidates.append(ps.hero_instance_id)
	for card in state.cards_in_zone(player_id + "_ally_row"):
		candidates.append(card.instance_id)
	# Pick the target with the most damage taken (max_hp - current_hp).
	var best_target := ""
	var best_damage := 0
	for tid in candidates:
		var max_hp := state.get_max_hp(tid, db)
		var cur_hp := state.get_current_hp(tid, db)
		var dmg_on := max_hp - cur_hp
		if dmg_on > best_damage:
			best_damage = dmg_on
			best_target = tid
	if best_target == "" or best_damage < 3:
		return []
	var x_value: int = min(best_damage, avail)
	var act := PendingAction.make("activate_power", player_id,
		{"hero_id": hero_id, "target_id": best_target, "x_value": x_value})
	if StackResolver.can_submit(state, act, db):
		return [act]
	return []


# radak_pet_sacrifice AI: one action per owned Pet (AI sees each sacrifice as a distinct option).
# For each Pet, pairs with the best damage target for that Pet's cost as X.
# Skips Pets whose cost is 0 (X=0 deals no damage).
func _radak_sacrifice_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	var opp_id := _other_player_id(state, player_id)
	# Collect enemy targets for damage heuristic.
	var all_targets: Array[String] = []
	var opp_ps := state.players.get(opp_id) as PlayerState
	if opp_ps and opp_ps.hero_instance_id != "":
		all_targets.append(opp_ps.hero_instance_id)
	for card in state.cards_in_zone(opp_id + "_ally_row"):
		all_targets.append(card.instance_id)
	if all_targets.is_empty():
		return []

	var result: Array[PendingAction] = []
	for pet_card in state.cards_in_zone(player_id + "_ally_row"):
		var pet_def := _card_def(state, db, pet_card.instance_id)
		if not pet_def or pet_def.card_subtype != "Pet":
			continue
		var x_value: int = pet_def.cost
		if x_value < 1:
			continue
		var best_target := _best_damage_target(state, db, player_id, all_targets, x_value)
		if best_target == "":
			continue
		var act := PendingAction.make("activate_power", player_id, {
			"hero_id":   hero_id,
			"pet_id":    pet_card.instance_id,
			"target_id": best_target,
			"x_value":   x_value,
		})
		if StackResolver.can_submit(state, act, db):
			result.append(act)
	return result


# graveyard_to_hand hero powers (e.g. Sen'zir Beastwalker: "Put a Pet card
# from your graveyard into your hand"). Skips when the hand is already full
# (the card would just be discarded at wrap-up). Picks via the overridable
# _choose_graveyard_targets hook (GenericAI ranks by sort_valuable_cards).
func _graveyard_to_hand_hero_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	var max_hand := state.get_max_hand_size(player_id, db)
	if state.cards_in_zone(player_id + "_hand").size() >= max_hand:
		return []
	var def := _card_def(state, db, hero_id)
	if not def:
		return []
	var gy_req := StackResolver.get_graveyard_search_requirement(def)
	if gy_req.is_empty():
		return []
	var candidates := StackResolver.get_graveyard_search_candidates(state, player_id, gy_req, db)
	if candidates.size() < int(gy_req.get("min_count", 1)):
		return []
	var picks := _choose_graveyard_targets(state, db, player_id, gy_req, candidates)
	if picks.is_empty():
		return []
	var act := PendingAction.make("activate_power", player_id,
		{"hero_id": hero_id, "target_id": picks[0]})
	if StackResolver.can_submit(state, act, db):
		return [act]
	return []


# Use the targeted-damage and targeted-heal heuristics to pick the single best
# (dmg_target, heal_target) pair for deal_damage_and_heal powers.
func _damage_and_heal_actions(state: GameState, db, player_id: String,
		hero_id: String) -> Array[PendingAction]:
	# Parse damage amount from effect string (format: deal_damage_and_heal:DMG:type:HEAL).
	var def := _card_def(state, db, hero_id)
	var damage := 3
	if def:
		var parts := def.effects.split(":")
		if parts.size() > 1:
			damage = int(parts[1])

	# Collect every in-play character.
	var all_ids: Array[String] = []
	for pid in state.players:
		var ps2 := state.players.get(pid) as PlayerState
		if ps2 and ps2.hero_instance_id != "":
			all_ids.append(ps2.hero_instance_id)
		for card in state.cards_in_zone(pid + "_ally_row"):
			all_ids.append(card.instance_id)

	# Find valid damage targets — enemy only (never damage own characters).
	var valid_dmg: Array[String] = []
	for dmg_id in all_ids:
		var dmg_card := state.get_card(dmg_id)
		if not dmg_card or dmg_card.controller == player_id:
			continue
		for heal_id in all_ids:
			if heal_id == dmg_id:
				continue
			var act := PendingAction.make("activate_power", player_id,
				{"hero_id": hero_id, "target_id": dmg_id, "heal_target_id": heal_id})
			if StackResolver.can_submit(state, act, db):
				valid_dmg.append(dmg_id)
				break

	if valid_dmg.is_empty():
		return []

	var best_dmg := _best_damage_target(state, db, player_id, valid_dmg, damage)
	if best_dmg == "":
		return []

	# Find valid heal targets for the chosen damage target — friendly only.
	# Require the target to actually be damaged: healing a full-HP character
	# is legal (no overheal) but wastes the heal half of the power, so the AI
	# holds the power for later rather than using it for damage alone.
	var valid_heal: Array[String] = []
	for heal_id in all_ids:
		if heal_id == best_dmg:
			continue
		var heal_card := state.get_card(heal_id)
		if not heal_card or heal_card.controller != player_id:
			continue
		if state.get_current_hp(heal_id, db) >= state.get_max_hp(heal_id, db):
			continue
		var act := PendingAction.make("activate_power", player_id,
			{"hero_id": hero_id, "target_id": best_dmg, "heal_target_id": heal_id})
		if StackResolver.can_submit(state, act, db):
			valid_heal.append(heal_id)

	if valid_heal.is_empty():
		return []

	var best_heal := _best_heal_target(state, db, player_id, valid_heal)
	if best_heal == "":
		return []

	var final_act := PendingAction.make("activate_power", player_id,
		{"hero_id": hero_id, "target_id": best_dmg, "heal_target_id": best_heal})
	if StackResolver.can_submit(state, final_act, db):
		return [final_act]
	return []


# Hand-card version of _damage_and_heal_actions (Shock and Soothe): pick the
# single best (dmg_target, heal_target) pair for a play_instant/play_ability.
# Enemy-only damage, friendly-only heal (AI targeting convention), and the two
# must differ ("another target"). Unlike the free, repeatable hero power this is
# a one-shot 4-drop, so it also fires with no damaged friendly to heal when the
# damage KILLS something — the heal half is then simply wasted.
func _instant_damage_and_heal_actions(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> Array[PendingAction]:
	var def := _card_def(state, db, card_id)
	var damage := 0
	if def:
		for seg in def.effects.split("|"):
			var parts := seg.strip_edges().split(":")
			if parts[0] == "deal_damage_and_heal" and parts.size() > 1:
				damage = int(parts[1])
				break
	if damage <= 0:
		return []

	var all_ids: Array[String] = []
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			all_ids.append(ps.hero_instance_id)
		for card in state.cards_in_zone(pid + "_ally_row"):
			all_ids.append(card.instance_id)

	var _mk := func(dmg_id: String, heal_id: String) -> PendingAction:
		return PendingAction.make(action_type, player_id,
			{"card_id": card_id, "target_id": dmg_id, "heal_target_id": heal_id})

	# Damage candidates: opposing characters that can legally be paired with SOME
	# heal target (the pairing is what can_submit validates).
	var valid_dmg: Array[String] = []
	for dmg_id in all_ids:
		var dmg_card := state.get_card(dmg_id)
		if not dmg_card or dmg_card.controller == player_id:
			continue
		for heal_id in all_ids:
			if heal_id == dmg_id:
				continue
			if StackResolver.can_submit(state, _mk.call(dmg_id, heal_id), db):
				valid_dmg.append(dmg_id)
				break
	if valid_dmg.is_empty():
		return []
	var best_dmg := _best_damage_target(state, db, player_id, valid_dmg, damage)
	if best_dmg == "":
		return []

	# Heal candidates: our own DAMAGED characters (healing a full-HP character is
	# legal but wastes the heal half).
	var valid_heal: Array[String] = []
	var any_heal := ""
	for heal_id in all_ids:
		if heal_id == best_dmg:
			continue
		var heal_card := state.get_card(heal_id)
		if not heal_card or heal_card.controller != player_id:
			continue
		if not StackResolver.can_submit(state, _mk.call(best_dmg, heal_id), db):
			continue
		if any_heal == "":
			any_heal = heal_id
		if state.get_current_hp(heal_id, db) < state.get_max_hp(heal_id, db):
			valid_heal.append(heal_id)

	var best_heal := _best_heal_target(state, db, player_id, valid_heal) \
		if not valid_heal.is_empty() else ""
	if best_heal == "":
		# No damaged friendly: cast anyway only if the damage kills the target.
		if any_heal == "" or state.get_current_hp(best_dmg, db) > damage:
			return []
		best_heal = any_heal

	var final_act := _mk.call(best_dmg, best_heal) as PendingAction
	if StackResolver.can_submit(state, final_act, db):
		return [final_act]
	return []


# Ally-power version of _damage_and_heal_actions (e.g. Hierophant Caydiem):
# pick the single best (dmg_target, heal_target) pair via use_ally_power.
func _ally_damage_and_heal_actions(state: GameState, db, player_id: String,
		ally_id: String, damage: int) -> Array[PendingAction]:
	var all_ids: Array[String] = []
	for pid in state.players:
		var ps2 := state.players.get(pid) as PlayerState
		if ps2 and ps2.hero_instance_id != "":
			all_ids.append(ps2.hero_instance_id)
		for card in state.cards_in_zone(pid + "_ally_row"):
			all_ids.append(card.instance_id)

	var valid_dmg: Array[String] = []
	for dmg_id in all_ids:
		var dmg_card := state.get_card(dmg_id)
		if not dmg_card or dmg_card.controller == player_id:
			continue
		for heal_id in all_ids:
			if heal_id == dmg_id:
				continue
			var act := PendingAction.make("use_ally_power", player_id,
				{"card_id": ally_id, "target_id": dmg_id, "heal_target_id": heal_id})
			if StackResolver.can_submit(state, act, db):
				valid_dmg.append(dmg_id)
				break

	if valid_dmg.is_empty():
		return []

	var best_dmg := _best_damage_target(state, db, player_id, valid_dmg, damage)
	if best_dmg == "":
		return []

	var valid_heal: Array[String] = []
	for heal_id in all_ids:
		if heal_id == best_dmg:
			continue
		var heal_card := state.get_card(heal_id)
		if not heal_card or heal_card.controller != player_id:
			continue
		if state.get_current_hp(heal_id, db) >= state.get_max_hp(heal_id, db):
			continue
		var act := PendingAction.make("use_ally_power", player_id,
			{"card_id": ally_id, "target_id": best_dmg, "heal_target_id": heal_id})
		if StackResolver.can_submit(state, act, db):
			valid_heal.append(heal_id)

	if valid_heal.is_empty():
		return []

	var best_heal := _best_heal_target(state, db, player_id, valid_heal)
	if best_heal == "":
		return []

	var final_act := PendingAction.make("use_ally_power", player_id,
		{"card_id": ally_id, "target_id": best_dmg, "heal_target_id": best_heal})
	if StackResolver.can_submit(state, final_act, db):
		return [final_act]
	return []


# Damage dealt by a deal_damage_to_target hero power (format:
# deal_damage_to_target:AMOUNT:DMG_TYPE). 0 if the hero has no such power.
func _hero_power_damage_amount(state: GameState, db, hero_id: String) -> int:
	var def := _card_def(state, db, hero_id)
	if not def:
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "deal_damage_to_target":
			return int(parts[1]) if parts.size() > 1 else 0
	return 0


func _hero_power_cost(state: GameState, db, hero_id: String) -> int:
	var def := _card_def(state, db, hero_id)
	return def.cost if def else 0


# ── sort_valuable_cards / card_value_score ──────────────────────────────────
# See game_logic/ai/ai_functions.md for the full contract.
# Sorts card instance ids from most to least valuable. Primary criterion is
# the numeric card_value_score; remaining ties fall back to the keyword
# heuristic (allies-before-non-allies > Protector > HP > Ferocity > Elusive >
# ATK > random). `bonus` is an optional {card_id: float} map of situational
# score adjustments (e.g. +1 to specific cards in a given context).
const _RARITY_RANK := {"epic": 4, "rare": 3, "uncommon": 2, "common": 1}

static func sort_valuable_cards(state: GameState, db,
		card_ids: Array[String], bonus: Dictionary = {}) -> Array[String]:
	var result: Array[String] = card_ids.duplicate()
	result.shuffle()   # random final tiebreak — everything else is deterministic
	result.sort_custom(func(a: String, b: String) -> bool:
		var ka := _card_value_key(state, db, a)
		var kb := _card_value_key(state, db, b)
		ka[0] += float(bonus.get(a, 0.0))
		kb[0] += float(bonus.get(b, 0.0))
		return ka > kb)
	return result


# Numeric base value of a card: cost + rarity (Common 1 … Epic 4) +
# 0.2*(ATK+HP). ATK/HP use current values for in-play allies (a 3-HP-left
# target is worth more than a 1-HP-left one), printed values otherwise
# (graveyard, hand); non-allies contribute 0 so a hero's 30 HP doesn't
# dominate and an ally outscores an equal-cost spell.
static func card_value_score(state: GameState, db, cid: String) -> float:
	var card := state.get_card(cid)
	var def: CardDef = db.get_def(card.card_def_id) if (card and db) else null
	if not def:
		return 0.0
	var score := float(def.cost) + float(_RARITY_RANK.get(def.rarity.to_lower(), 1))
	if def.card_type == "Ally":
		var hp  := def.printed_health
		var atk := def.printed_atk
		if state.is_in_play(cid):
			hp  = state.get_current_hp(cid, db)
			atk = state.get_atk(cid, db)
		score += 0.2 * float(atk + hp)
	return score


# Lexicographic value key: card_value_score first, then the keyword tiebreaks.
# Non-allies zero out the combat fields, so at an equal score an ally always
# outranks a non-ally. HP/ATK resolve like card_value_score (current in play,
# printed otherwise).
static func _card_value_key(state: GameState, db, cid: String) -> Array:
	var card := state.get_card(cid)
	var def: CardDef = db.get_def(card.card_def_id) if (card and db) else null
	if not def:
		return [0.0, 0, 0, 0, 0, 0, 0]
	var kw: Array[String] = []
	for k in def.keywords:
		kw.append(str(k).to_lower())
	var is_ally := def.card_type == "Ally"
	var hp  := def.printed_health
	var atk := def.printed_atk
	if state.is_in_play(cid):
		hp  = state.get_current_hp(cid, db)
		atk = state.get_atk(cid, db)
	return [
		card_value_score(state, db, cid),
		1 if is_ally else 0,
		1 if is_ally and "protector" in kw else 0,
		hp if is_ally else 0,
		1 if is_ally and "ferocity" in kw else 0,
		1 if is_ally and "elusive" in kw else 0,
		atk if is_ally else 0,
	]


# Hook: pick graveyard targets for a quest reward (Chasing A-Me, Darrowshire).
# Base heuristic: to hand → highest-cost candidates (best card back);
# to RFG → lowest-cost ones (removing your own cards is a cost, not a gain).
# Subclasses may override (GenericAI uses sort_valuable_cards).
func _choose_graveyard_targets(state: GameState, db, _player_id: String,
		gy_req: Dictionary, candidates: Array[String]) -> Array[String]:
	var picks := candidates.duplicate()
	var to_rfg: bool = gy_req.get("dest", "hand") == "rfg"
	picks.sort_custom(func(a, b):
		if to_rfg:
			return _def_cost(state, db, a) < _def_cost(state, db, b)
		return _def_cost(state, db, a) > _def_cost(state, db, b))
	var take: int = min(int(gy_req.get("max_count", 1)), picks.size())
	return picks.slice(0, take)


# Hook: pick which allies pay an "exhaust N allies" quest cost (The Love Potion).
# Base heuristic: spend the allies we'd miss least — ones that can't attack right
# now (summoning-sick, 0 ATK, totems) first, then the lowest-value bodies.
func _choose_quest_exhaust_allies(state: GameState, db, player_id: String,
		count: int) -> Array[String]:
	var candidates := StackResolver.get_quest_exhaust_candidates(state, player_id)
	var attackers := StackResolver.get_legal_attackers(state, player_id, db)
	candidates.sort_custom(func(a, b):
		var a_att := 1 if a in attackers else 0
		var b_att := 1 if b in attackers else 0
		if a_att != b_att:
			return a_att < b_att
		return card_value_score(state, db, a) < card_value_score(state, db, b))
	return candidates.slice(0, min(count, candidates.size()))


# Hook: pick the card to discard when this player must discard (wrap-up or
# card effect). Called once per card by the scene. Base heuristic: lowest-cost
# non-quest/location card; fall back to a random quest/location.
func choose_discard_card(state: GameState, db, player_id: String) -> String:
	var hand := state.cards_in_zone(player_id + "_hand")
	if hand.is_empty():
		return ""
	var non_resource: Array[String] = []
	var resource_only: Array[String] = []
	for card in hand:
		var def: CardDef = db.get_def(card.card_def_id) if db else null
		if def and def.card_type in ["Quest", "Location"]:
			resource_only.append(card.instance_id)
		else:
			non_resource.append(card.instance_id)
	if not non_resource.is_empty():
		non_resource.sort_custom(func(a, b) -> bool:
			return _def_cost(state, db, a) < _def_cost(state, db, b))
		return non_resource[0]
	return resource_only[randi() % resource_only.size()]


# Hook: order a find_lethal pool before this AI commits to a target.
# Base keeps the incoming order (hero first, then ally_row order); subclasses
# decide if and when to apply a real heuristic (FullRandomAI sorts by
# sort_valuable_cards so it always kills the most valuable target).
func rank_lethal_targets(state: GameState, db,
		lethal: Array[String]) -> Array[String]:
	return lethal


# ── find_lethal ────────────────────────────────────────────────────────────
# See game_logic/ai/ai_functions.md for the full contract.
# Returns opposing in-play characters that would die to `damage` points
# (current HP <= damage). If the opposing HERO is lethal, returns ONLY the
# hero — killing the hero wins the game, nothing else matters.
static func find_lethal(state: GameState, db, player_id: String,
		damage: int) -> Array[String]:
	var result: Array[String] = []
	if damage <= 0:
		return result
	var opp := "p2" if player_id == "p1" else "p1"
	var ps_opp := state.players.get(opp) as PlayerState
	if ps_opp and ps_opp.hero_instance_id != "" \
			and state.is_in_play(ps_opp.hero_instance_id) \
			and state.get_current_hp(ps_opp.hero_instance_id, db) <= damage:
		result.append(ps_opp.hero_instance_id)
		return result
	for card in state.cards_in_zone(opp + "_ally_row"):
		if state.get_current_hp(card.instance_id, db) <= damage:
			result.append(card.instance_id)
	return result


# ── find_safe_lethals ───────────────────────────────────────────────────────
# See game_logic/ai/ai_functions.md for the full contract.
# For every (attacker, defender) combination, keeps the pairs where the
# attacker kills AND survives:
#   attacker current ATK >= defender current HP
#   attacker current HP  >  defender current ATK
# Returns an Array of [attacker_id, defender_id] pairs. Pure math — no
# combat-legality check (Elusive, exhaustion, …); callers filter with
# can_submit / get_legal_defenders.
static func find_safe_lethals(state: GameState, db, attackers: Array[String],
		defenders: Array[String]) -> Array:
	var result: Array = []
	for a in attackers:
		var a_hp  := state.get_current_hp(a, db)
		for d in defenders:
			if combat_kills(state, db, a, d) \
					and a_hp > forecast_atk(state, db, d, false):   # defender may strike back
				result.append([a, d])
	return result


# "Does `source` remove `target` from the board in a combat between them?" —
# raw damage math, OR a Brigg-style triggered finisher.
#
# Brigg (`on_combat_damage_destroys_damaged_ally`): "When Brigg deals combat
# damage to an ally with damage on it, destroy that ally." Damage the target
# already carries is exactly what `damage_taken > 0` reads at decision time
# (pre-combat), so a damaged ally Brigg can reach is a kill regardless of how
# much HP it has left. Without this the AI would never use the power on purpose:
# both find_safe_lethals and combat_trade_value ask only "atk >= hp", so Brigg
# would look like a 1-ATK chump against anything bigger.
#
# Not modeled: prevention shields that would stop Brigg's damage landing (the
# trigger needs damage to actually land), which the surrounding combat math
# doesn't model either.
static func combat_kills(state: GameState, db, source: String, target: String,
		source_is_attacker: bool = true) -> bool:
	var atk := forecast_atk(state, db, source, source_is_attacker)
	if atk >= state.get_current_hp(target, db):
		return true
	if atk <= 0:
		return false   # no damage dealt → no "deals combat damage" trigger
	var src := state.get_card(source)
	var tgt := state.get_card(target)
	if not src or not tgt or tgt.damage_taken <= 0:
		return false
	if not StackResolver._is_ally(state, target):
		return false   # the trigger destroys an ALLY, never a hero
	return StackResolver._has_effect_flag(
		db.get_def(src.card_def_id) as CardDef,
		"on_combat_damage_destroys_damaged_ally")


# ── combat_trade_value ───────────────────────────────────────────────────────
# Evaluates a would-be combat between two characters from c1's point of view.
# Pure ATK/HP math (like find_safe_lethals) — no combat-legality or Ranged /
# Long-Range check; callers gate with can_submit / get_legal_defenders. Damage
# is treated as symmetric (each deals its ATK to the other), so the function is
# reusable for future defensive choices too (e.g. picking a Protector: call with
# your protector as c1, the attacker as c2).
#   c1 kills c2  = c1.atk >= c2.hp
#   c1 survives  = c1.hp  >  c2.atk
# Returns:
#   "safe_lethal" — c2 dies, c1 survives
#   "both"        — both die
#   "suicide"     — only c1 dies
#   "no_one"      — neither dies
# `c1_is_attacker` (default true) marks which side is the ATTACKER, so "while
# attacking" bonuses (Zorm/Rayder/For the Horde!) are forecast onto the right
# side only — exactly one side attacks; the defender never gets them. On offense
# c1 is our attacker. For a Protector, c1 is our defending protector and c2 is
# the incoming attacker → pass c1_is_attacker=false.
static func combat_trade_value(state: GameState, db, c1: String, c2: String,
		c1_is_attacker: bool = true) -> String:
	# The attacking side gets the strike forecast too (a hero that can still
	# strike will — resources are public, so this also covers the enemy hero).
	# Both directions go through combat_kills, so a Brigg-style finisher counts
	# on offence AND when the other side is the one holding it (a damaged
	# attacker of ours dies to a defending Brigg's retaliation trigger).
	var c2_dies := combat_kills(state, db, c1, c2, c1_is_attacker)
	var c1_dies := combat_kills(state, db, c2, c1, not c1_is_attacker)
	if c2_dies and not c1_dies:
		return "safe_lethal"
	if c2_dies and c1_dies:
		return "both"
	if c1_dies:
		return "suicide"
	return "no_one"


# ── Targeted damage heuristic ──────────────────────────────────────────────
# Picks the best damage target from a list of candidate instance IDs.
# Priority 0 — lethal on enemy hero.
# Priority 1 — any lethal hit; tiebreak: highest HP → highest cost →
#              Protector → Elusive → first in list.
# Priority 2 — no lethal: maximize effective damage dealt (min(dmg, cur_hp)).
func _best_damage_target(state: GameState, db, player_id: String,
		candidates: Array[String], damage: int) -> String:
	if candidates.is_empty():
		return ""
	var enemy_pid := _other_player_id(state, player_id)
	var ep := state.players.get(enemy_pid) as PlayerState
	var enemy_hero_id: String = ep.hero_instance_id if ep else ""

	# Priority 0: lethal on enemy hero (find_lethal returns only the hero then).
	var lethal_scan := find_lethal(state, db, player_id, damage)
	if lethal_scan.size() == 1 and lethal_scan[0] == enemy_hero_id \
			and enemy_hero_id in candidates:
		return enemy_hero_id

	var lethal: Array[String] = []
	var non_lethal: Array[String] = []
	for c in candidates:
		if state.get_current_hp(c, db) <= damage:
			lethal.append(c)
		else:
			non_lethal.append(c)

	if not lethal.is_empty():
		lethal.sort_custom(func(a: String, b: String) -> bool:
			var hp_a := state.get_current_hp(a, db)
			var hp_b := state.get_current_hp(b, db)
			if hp_a != hp_b:
				return hp_a > hp_b
			var da := _card_def(state, db, a)
			var db_ := _card_def(state, db, b)
			var cost_a := da.cost if da else 0
			var cost_b := db_.cost if db_ else 0
			if cost_a != cost_b:
				return cost_a > cost_b
			var prot_a: bool = da != null and "Protector" in da.keywords
			var prot_b: bool = db_ != null and "Protector" in db_.keywords
			if prot_a != prot_b:
				return prot_a
			var elu_a: bool = da != null and "Elusive" in da.keywords
			var elu_b: bool = db_ != null and "Elusive" in db_.keywords
			return elu_a and not elu_b
		)
		return lethal[0]

	# Priority 2: maximize effective damage.
	non_lethal.sort_custom(func(a: String, b: String) -> bool:
		return min(damage, state.get_current_hp(a, db)) > min(damage, state.get_current_hp(b, db))
	)
	return non_lethal[0]


# ── Targeted heal heuristic ────────────────────────────────────────────────
# Picks the most damaged friendly character from candidates.
# Allies are preferred over the hero, UNLESS the hero is at ≤ 1/3 of its max HP
# (then the hero's survival outweighs keeping an ally).
func _best_heal_target(state: GameState, db, player_id: String,
		candidates: Array[String]) -> String:
	if candidates.is_empty():
		return ""
	var ps := state.players.get(player_id) as PlayerState
	var hero_id: String = ps.hero_instance_id if ps else ""
	var hero_low_hp := false
	if hero_id != "" and hero_id in candidates:
		hero_low_hp = state.get_current_hp(hero_id, db) <= 12

	var best := candidates[0]
	for i in range(1, candidates.size()):
		var cid := candidates[i]
		var cid_card := state.get_card(cid)
		if not cid_card:
			continue
		var cid_is_hero := (cid == hero_id)
		var best_is_hero := (best == hero_id)
		# Bucket preference.
		if hero_low_hp:
			if cid_is_hero and not best_is_hero:
				best = cid
				continue
			if not cid_is_hero and best_is_hero:
				continue
		else:
			if not cid_is_hero and best_is_hero:
				best = cid
				continue
			if cid_is_hero and not best_is_hero:
				continue
		# Same bucket: most damage_taken wins.
		var best_card := state.get_card(best)
		if best_card and cid_card.damage_taken > best_card.damage_taken:
			best = cid
	return best


func _hero_power_needs_target(state: GameState, db, hero_id: String) -> bool:
	if not db:
		return false
	var hero := state.get_card(hero_id)
	if not hero:
		return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def:
		return false
	for entry in def.effects.split("|"):
		var key := entry.strip_edges().split(":")[0].strip_edges()
		if key in ["deal_damage_to_target", "destroy_exhausted_ally", "deal_damage_and_heal", "deal_x_damage_to_ally", "deal_7_minus_hand_to_hero", "heal_x_from_target", "radak_pet_sacrifice", "target_cant_attack"]:
			return true
	return false


func _other_player_id(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id


# Multi-Shot (azeroth_41): builds a single action announcing up to 3 distinct
# enemy targets, each taking the same N damage. AI targets opponents only.
# Candidate order: allies the shot KILLS first (efficient removal), then the
# remaining allies (highest HP soak), then the opposing hero. Each candidate is
# validated with an incremental can_submit probe (announce order enforced).
# ── Lightning Storm (dark_portal_98) — `divided_damage:X:TYPE:ally` ──────────
# "Your hero deals X nature damage divided as you choose to any number of
# target allies", cost "2+X" — so X is BOTH the price and the damage pool, and
# the AI's whole decision is how many points are worth buying.
#
# Policy: buy exactly the points it can convert into DEAD opposing allies, and
# nothing more. Candidates are the opponent's allies only (never our own, per
# the CLAUDE.md AI targeting convention; heroes aren't legal targets at all),
# taken most-valuable-first and skipped when their remaining HP doesn't fit the
# budget left. If no ally can be killed outright the card is held — spending 2
# resources plus a card on chip damage spread over a board is the classic way
# to waste this card, and the X paid for it is gone either way.
#
# The announce is one target id per point of damage (repeats allowed), which
# the engine tallies back into one packet per ally.
func _divided_damage_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	# Largest X we can pay for right now, asked of get_play_cost one X at a time
	# so a cost aura (Elemental Focus) buys the extra point it should.
	var avail := state.get_available_resources(player_id)
	var max_x := 0
	for x in range(1, avail + 1):
		if state.get_play_cost(card_id, db, x) <= avail:
			max_x = x
		else:
			break
	if max_x < 1:
		return null

	var opp := _other_player_id(state, player_id)
	var candidates: Array = []
	for ally in state.cards_in_zone(opp + "_ally_row"):
		var hp := state.get_current_hp(ally.instance_id, db)
		if hp <= 0:
			continue
		candidates.append({
			"id": ally.instance_id, "hp": hp,
			"value": card_value_score(state, db, ally.instance_id),
		})
	if candidates.is_empty():
		return null
	candidates.sort_custom(func(a, b): return float(a["value"]) > float(b["value"]))

	var budget := max_x
	var picks: Array[String] = []
	for cand in candidates:
		var hp: int = int(cand["hp"])
		if hp > budget:
			continue   # can't finish it off — don't waste points on it
		budget -= hp
		for _i in hp:
			picks.append(cand["id"] as String)
		if budget <= 0:
			break
	if picks.is_empty():
		return null   # nothing dies — hold the card

	var action := PendingAction.make(action_type, player_id, {
		"card_id": card_id, "x_value": picks.size(), "target_ids": picks,
	})
	if StackResolver.can_submit(state, action, db):
		return action
	return null


func _multi_shot_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var amount := 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "multi_shot" and parts.size() > 1:
			amount = int(parts[1])
	var opp := _other_player_id(state, player_id)
	var opp_ps := state.players.get(opp) as PlayerState
	var kills: Array[String] = []
	var soak:  Array[String] = []
	for ally in state.cards_in_zone(opp + "_ally_row"):
		if state.get_current_hp(ally.instance_id, db) <= amount:
			kills.append(ally.instance_id)
		else:
			soak.append(ally.instance_id)
	# Higher-HP allies soak the shots that won't kill anything.
	soak.sort_custom(func(a, b):
		return state.get_current_hp(a, db) > state.get_current_hp(b, db))
	var ordered: Array[String] = []
	ordered.append_array(kills)
	ordered.append_array(soak)
	if opp_ps and opp_ps.hero_instance_id != "":
		ordered.append(opp_ps.hero_instance_id)
	if ordered.is_empty():
		return null
	var keys := ["target_id", "target_id_2", "target_id_3"]
	var params := {"card_id": card_id}
	var chosen := 0
	for cand in ordered:
		if chosen >= 3:
			break
		var probe_params := params.duplicate()
		probe_params[keys[chosen]] = cand
		var probe := PendingAction.make(action_type, player_id, probe_params)
		if StackResolver.can_submit(state, probe, db):
			params = probe_params
			chosen += 1
	if chosen == 0:
		return null
	return PendingAction.make(action_type, player_id, params)


# Parses "chain_lightning:A1:A2:A3:DMG_TYPE" into [A1, A2, A3].
func _chain_lightning_amounts(def: CardDef) -> Array[int]:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "chain_lightning":
			var result: Array[int] = []
			for i in range(1, 4):
				result.append(int(parts[i]) if parts.size() > i else 0)
			return result
	return [0, 0, 0]


# Chain Lightning (azeroth_106): builds a single action announcing up to 3
# distinct enemy targets, one per wave (target_id/target_id_2/target_id_3).
# AI always targets opponents only (never self-targets, per CLAUDE.md AI
# conventions).
#
# Global wave assignment (not per-wave greedy): first maximize kills by
# matching each killable target with the SMALLEST wave that suffices (waves
# ascending, each killing the toughest candidate it can), then dump leftover
# waves — largest first — onto the highest-HP remaining targets. This avoids
# wasting the 3-damage wave on a 1-HP ally the 1-damage wave could kill
# (e.g. two 1-HP allies + hero → waves 1 and 2 kill the allies, wave 3 hits
# the hero).
#
# Legality is verified with can_submit probes per slot (which also excludes
# Untargetable candidates from the 1st wave only); if a planned slot is
# illegal, the offending candidate is dropped from the pool and the plan is
# rebuilt.
func _chain_lightning_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var amounts := _chain_lightning_amounts(def)
	var opp := _other_player_id(state, player_id)
	var opp_ps := state.players.get(opp) as PlayerState
	var pool: Array[String] = []
	for ally in state.cards_in_zone(opp + "_ally_row"):
		pool.append(ally.instance_id)
	if opp_ps and opp_ps.hero_instance_id != "":
		pool.append(opp_ps.hero_instance_id)

	var keys := ["target_id", "target_id_2", "target_id_3"]
	while not pool.is_empty():
		var plan := _chain_lightning_plan(state, db, amounts, pool)
		if plan[0] == "":
			return null   # no mandatory target plannable
		# Validate slot by slot; on failure drop that candidate and re-plan.
		var params := {"card_id": card_id}
		var bad := ""
		for i in range(3):
			if plan[i] == "":
				break
			var probe_params: Dictionary = params.duplicate()
			probe_params[keys[i]] = plan[i]
			if not StackResolver.can_submit(state,
					PendingAction.make(action_type, player_id, probe_params), db):
				bad = plan[i]
				break
			params[keys[i]] = plan[i]
		if bad != "":
			pool.erase(bad)
			continue
		if not params.has("target_id"):
			return null
		var action := PendingAction.make(action_type, player_id, params)
		if StackResolver.can_submit(state, action, db):
			return action
		return null
	return null


# Plans wave→target assignment for Chain Lightning. Returns a 3-element
# Array[String] (one per wave slot, "" = unassigned). Phase 1: waves in
# ascending damage order each kill the highest-HP candidate they can
# (smallest sufficient wave per kill). Phase 2: leftover waves, largest
# first, hit the highest-HP remaining candidates.
func _chain_lightning_plan(state: GameState, db, amounts: Array[int],
		pool: Array[String]) -> Array[String]:
	var plan: Array[String] = ["", "", ""]
	var remaining := pool.duplicate()

	# Wave indices sorted by damage ascending (ties keep printed order).
	var order := [0, 1, 2]
	order.sort_custom(func(a, b): return amounts[a] < amounts[b])

	# Phase 1: kills with the smallest sufficient wave.
	for i in order:
		if amounts[i] <= 0:
			continue
		var best := ""
		var best_hp := -1
		for cand in remaining:
			var hp := state.get_current_hp(cand, db)
			if hp <= amounts[i] and hp > best_hp:
				best = cand
				best_hp = hp
		if best != "":
			plan[i] = best
			remaining.erase(best)

	# Phase 2: leftover waves (largest first) onto toughest remaining targets.
	for i in range(3):
		if plan[i] != "" or amounts[i] <= 0 or remaining.is_empty():
			continue
		var best := ""
		var best_hp := -1
		for cand in remaining:
			var hp := state.get_current_hp(cand, db)
			if hp > best_hp:
				best = cand
				best_hp = hp
		plan[i] = best
		remaining.erase(best)

	# Slots must be contiguous (target_id_3 requires target_id_2, and
	# target_id is mandatory): compact assigned targets forward. Wave
	# amounts are fixed per slot, so compacting changes which damage each
	# target takes — re-sort so bigger waves keep their bigger targets:
	# collect assigned targets, order by HP descending, refill slots in
	# printed (descending-damage) order.
	var assigned: Array[String] = []
	for i in range(3):
		if plan[i] != "":
			assigned.append(plan[i])
	if assigned.is_empty():
		return plan   # all slots empty
	# Keep kills on their planned waves when possible: only re-slot if
	# there are gaps (e.g. wave 2 unassigned but wave 3 assigned).
	var has_gap := false
	for i in range(assigned.size()):
		if plan[i] == "":
			has_gap = true
			break
	if not has_gap:
		return plan
	# Re-plan compactly against only the assigned targets.
	return _chain_lightning_plan_compact(state, db, amounts, assigned)


# Compact re-plan: given the chosen targets, assign them to the first N wave
# slots so that each killable target gets the smallest wave that still kills
# it, and non-killable targets soak the biggest leftover waves (HP desc).
func _chain_lightning_plan_compact(state: GameState, db, amounts: Array[int],
		targets: Array[String]) -> Array[String]:
	var plan: Array[String] = ["", "", ""]
	var remaining := targets.duplicate()
	var slots := range(mini(3, targets.size()))
	# Kill phase over the compact slots, ascending damage.
	var order := []
	for i in slots:
		order.append(i)
	order.sort_custom(func(a, b): return amounts[a] < amounts[b])
	for i in order:
		var best := ""
		var best_hp := -1
		for cand in remaining:
			var hp := state.get_current_hp(cand, db)
			if hp <= amounts[i] and hp > best_hp:
				best = cand
				best_hp = hp
		if best != "":
			plan[i] = best
			remaining.erase(best)
	# Leftovers: biggest wave → toughest target.
	for i in slots:
		if plan[i] != "" or remaining.is_empty():
			continue
		var best := ""
		var best_hp := -1
		for cand in remaining:
			var hp := state.get_current_hp(cand, db)
			if hp > best_hp:
				best = cand
				best_hp = hp
		plan[i] = best
		remaining.erase(best)
	return plan


# Ancestral Spirit: pick the highest-cost affordable ally card in our own
# graveyard to bring back (its cost — capped at our resources — is a fair proxy
# for board value; the reanimated ally arrives at 1 HP but is still a body).
func _reanimate_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var req := StackResolver.get_graveyard_search_requirement(def)
	var cands := StackResolver.get_graveyard_search_candidates(state, player_id, req, db)
	var best := ""
	var best_cost := -1
	for cid in cands:
		var c := state.get_card(cid)
		var cdef := db.get_def(c.card_def_id) as CardDef if c else null
		if not cdef:
			continue
		if cdef.cost > best_cost:
			best_cost = cdef.cost
			best = cid
	if best == "":
		return null
	var action := PendingAction.make(action_type, player_id,
			{"card_id": card_id, "target_id": best})
	if StackResolver.can_submit(state, action, db):
		return action
	return null


# Cannibalize: "Remove any number of ally cards in graveyards from the game.
# Your hero heals 2 damage from itself for each card removed." Held until the
# heal is worth a card and two resources — the AI never casts it as a pure
# denial spell — and then it exiles EVERY ally card in the opponent's graveyard
# (free recursion denial: Ophelia / Finkle / Ancestral Spirit all lose fuel),
# topping up from its OWN graveyard only while the heal is still doing work.
func _graveyard_exile_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var ps := state.players.get(player_id) as PlayerState
	var hero_id: String = ps.hero_instance_id if ps else ""
	if hero_id == "":
		return null
	var hero := state.get_card(hero_id)
	var damage: int = hero.damage_taken if hero else 0
	var per_card := StackResolver.rfg_heal_per_card(def)
	# No damage to heal ⇒ the card would only deny the opponent's graveyard,
	# which isn't worth a card in hand. Wait until it heals at least one card's
	# worth (a heal that overshoots on the LAST card is fine — that one still
	# healed something).
	if per_card <= 0 or damage < per_card:
		return null
	var req := StackResolver.get_graveyard_search_requirement(def)
	var cands := StackResolver.get_graveyard_search_candidates(state, player_id, req, db)
	if cands.is_empty():
		return null
	var opp := "p2" if player_id == "p1" else "p1"
	var picks: Array = []
	var healed := 0
	for cid in cands:
		var c := state.get_card(cid)
		if c and c.zone_id == opp + "_graveyard":
			picks.append(cid)
			healed += per_card
	for cid in cands:
		if healed >= damage:
			break
		if cid in picks:
			continue
		picks.append(cid)
		healed += per_card
	if picks.is_empty():
		return null
	var action := PendingAction.make(action_type, player_id,
			{"card_id": card_id, "target_ids": picks})
	if StackResolver.can_submit(state, action, db):
		return action
	return null


func _targeted_instant_actions(state: GameState, db, player_id: String,
		card_id: String, action_type: String = "play_instant") -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	var spell_card := state.get_card(card_id)
	var spell_def  := db.get_def(spell_card.card_def_id) as CardDef if spell_card else null

	var opp := "p2" if player_id == "p1" else "p1"

	# Shock and Soothe (deal_damage_and_heal from hand): two distinct targets —
	# damage an enemy, heal a friendly. Same shape as the hero-power version.
	if spell_def and StackResolver.is_damage_and_heal_def(spell_def):
		return _instant_damage_and_heal_actions(state, db, player_id, card_id, action_type)

	# Into the Fray (grant_keyword_target:friendly_ally:ferocity) — and any
	# future keyword grant. Two AI policies, both narrower than the printed
	# targeting:
	#   * FRIENDLY ONLY. Sneak's printed text is "target ally" (an opposing ally
	#     is a legal target for a human), but handing the opponent elusive or
	#     ferocity is never what the AI wants, so it only ever sees its own.
	#   * FEROCITY only on a summoning-sick ally. On an ally that can already
	#     attack the grant does nothing — the card would be burned for no board
	#     change. ATK > 0 too: readying a 0-ATK ally buys no attack either.
	# Held combat saves (Sneak, tagged combat_instant_*) never reach here —
	# get_reasonable_actions skips tagged cards; they play from their own hook.
	var gk := StackResolver.grant_keyword_parts(spell_def) if spell_def else PackedStringArray()
	if gk.size() > 2:
		var gk_word := gk[2].strip_edges()
		for ally in state.cards_in_zone(player_id + "_ally_row"):
			if gk_word == "ferocity":
				if not ally.just_summoned:
					continue
				if state.get_atk(ally.instance_id, db, true) <= 0:
					continue
			if StackResolver._has_keyword(ally, gk_word, db, state):
				continue   # already has it — the grant would do nothing
			var gk_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": ally.instance_id})
			if StackResolver.can_submit(state, gk_act, db):
				result.append(gk_act)
		return result

	# Burn Away / Shattering Blow (destroy_target:ability / :equipment): targets
	# are opposing in-play ability / equipment cards, not heroes and allies.
	# Value gate: target cost >= spell cost (same bar as _destroy_is_worth_it's
	# first gate; the solo-kill check doesn't apply — you can't attack these).
	var destroy_kind := StackResolver.destroy_target_kind(spell_def) if spell_def else ""
	if destroy_kind in ["ability", "equipment"]:
		for cid in StackResolver.get_destroy_kind_candidates(state, db, destroy_kind):
			var t_card := state.get_card(cid)
			if not t_card or t_card.controller != opp:
				continue
			var t_def := db.get_def(t_card.card_def_id) as CardDef
			if t_def and spell_def and t_def.cost < spell_def.cost:
				continue
			var d_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": cid})
			if StackResolver.can_submit(state, d_act, db):
				result.append(d_act)
		return result

	# Coup de Grâce (destroy_target:exhausted_ally): destroy the MOST valuable
	# exhausted opposing ally (random tie-break by iteration order). Always worth
	# it — an exhausted ally is a spent attacker; unconditional removal for 2.
	if destroy_kind == "exhausted_ally":
		var best_id := ""
		var best_score := -1.0
		for ally in state.cards_in_zone(opp + "_ally_row"):
			if not ally.is_exhausted:
				continue
			var cg_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": ally.instance_id})
			if not StackResolver.can_submit(state, cg_act, db):
				continue
			var score := card_value_score(state, db, ally.instance_id)
			if score > best_score:
				best_score = score
				best_id = ally.instance_id
		if best_id != "":
			result.append(PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": best_id}))
		return result

	# X-cost spell (Aimed Shot, "1+X" — deal X damage): announce X with the
	# play. vs an ally: X = exactly its HP (kill for the least); vs the hero:
	# X = everything we can pay. max_x <= 0 → unaffordable, no actions.
	var max_x := 0
	if spell_def and spell_def.cost_x:
		max_x = state.get_available_resources(player_id) \
			- state.get_play_cost(card_id, db, 0)

	for ally in state.cards_in_zone(opp + "_ally_row"):
		var params := {"card_id": card_id, "target_id": ally.instance_id}
		if spell_def and spell_def.cost_x:
			var x: int = min(max_x, state.get_current_hp(ally.instance_id, db))
			if x < 1:
				continue
			params["x_value"] = x
		var act := PendingAction.make(action_type, player_id, params)
		if not StackResolver.can_submit(state, act, db):
			continue
		if spell_def and _effect_is_destroy_ally(spell_def) \
				and not _destroy_is_worth_it(state, db, player_id, ally.instance_id, spell_def.cost):
			continue
		result.append(act)
	# Heroes are valid targets only if the spell allows it (destroy_target:ally excludes them).
	if spell_def and not _effect_is_destroy_ally(spell_def):
		var ps_opp := state.players.get(opp) as PlayerState
		if ps_opp and ps_opp.hero_instance_id != "":
			var params := {"card_id": card_id, "target_id": ps_opp.hero_instance_id}
			if spell_def and spell_def.cost_x:
				if max_x < 1:
					return result
				params["x_value"] = max_x
			var act := PendingAction.make(action_type, player_id, params)
			if StackResolver.can_submit(state, act, db):
				result.append(act)
	return result


# Modal spells (rule 707.1c — "Choose one:", Natural Selection): enumerate
# EVERY mode × legal target, each action carrying its `mode` index, so any AI
# (current or future) can see the full option space before deciding. Damage /
# removal modes follow the usual targeting rule (opponents only); heal modes
# target our own side, and only characters with damage to remove. Which of
# these options actually get played is a separate policy — see
# _modal_mode_playable below.
func get_modal_actions(state: GameState, db, player_id: String,
		card_id: String, action_type: String = "play_instant") -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	var spell_card := state.get_card(card_id)
	var spell_def  := db.get_def(spell_card.card_def_id) as CardDef if spell_card else null
	if not spell_def:
		return result
	var modes := StackResolver.modal_modes(spell_def)
	var opp := "p2" if player_id == "p1" else "p1"
	for i in modes.size():
		var mode_effect: String = modes[i]
		var candidates: Array[String] = []
		if mode_effect.begins_with("heal_target"):
			var ps := state.players.get(player_id) as PlayerState
			if ps and ps.hero_instance_id != "" \
					and state.get_card(ps.hero_instance_id).damage_taken > 0:
				candidates.append(ps.hero_instance_id)
			for ally in state.cards_in_zone(player_id + "_ally_row"):
				if ally.damage_taken > 0:
					candidates.append(ally.instance_id)
		else:
			for ally in state.cards_in_zone(opp + "_ally_row"):
				candidates.append(ally.instance_id)
			var ps_opp := state.players.get(opp) as PlayerState
			if ps_opp and ps_opp.hero_instance_id != "":
				candidates.append(ps_opp.hero_instance_id)
		for target_id in candidates:
			var act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": target_id, "mode": i})
			if StackResolver.can_submit(state, act, db):
				result.append(act)
	return result


# Play policy over a modal card's modes: which enumerated options the current
# heuristics actually play. For now only damage modes (played with the usual
# combat-instant / targeted-damage logic); heal modes are enumerated by
# get_modal_actions but filtered here — future work.
func _modal_mode_playable(mode_effect: String) -> bool:
	return mode_effect.begins_with("deal_damage_to_target")


# Attachments (rule 400). A buff attachment (`attached_buff` — Mark of the
# Wild) goes on our own highest-ATK ally. A debuff attachment (Entangling
# Roots: exhaust + `attached_cannot_ready`) goes on the opposing highest-ATK
# ally whose cost >= the spell's cost (same value bar as _destroy_is_worth_it's
# first gate — don't spend 2 to lock a 1-drop). At most one action is
# generated (the best target), never a self-target for a debuff.
func _attach_actions(state: GameState, db, player_id: String,
		card_id: String, action_type: String, def: CardDef) -> Array[PendingAction]:
	var result: Array[PendingAction] = []
	# Damage attachment (Fireball's burst, Shadow Word: Pain's turn-start burn):
	# AI policy — only ever aimed at the opposing HERO (guaranteed value, no
	# fizzle risk, and a hero host can't be killed to shed the attachment). Any
	# printed target stays legal for human players; a targeting heuristic, not
	# a rule. The rider on SW:P (its controller discards) follows the host, so
	# aiming at the opponent is what makes that half hurt them rather than us.
	# Hero-only attachment (Arcane Intellect: `attach:hero`): always our OWN
	# hero — the ongoing benefit (max hand size) follows the attached hero's
	# controller, so an enemy hero would gift it away.
	# Weapon attachment (Windfury Weapon): put it on one of our own Melee weapons
	# (the highest-ATK one), so striking with it can ready the weapon + hero.
	if StackResolver._attach_targets_weapon_only(def):
		var best_w: PendingAction = null
		var best_w_atk := -1
		for card in state.cards_in_zone(player_id + "_hero_row"):
			if not StackResolver._is_melee_weapon(state, card.instance_id, db):
				continue
			var w_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": card.instance_id})
			if not StackResolver.can_submit(state, w_act, db):
				continue
			var w_atk := state.get_atk(card.instance_id, db)
			if w_atk > best_w_atk:
				best_w_atk = w_atk
				best_w = w_act
		if best_w:
			result.append(best_w)
		return result
	if StackResolver._attach_targets_hero_only(def):
		var own_hero := state.get_hero(player_id)
		if own_hero:
			var h_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": own_hero.instance_id})
			if StackResolver.can_submit(state, h_act, db):
				result.append(h_act)
		return result
	if StackResolver._has_effect_flag_prefix(def, "attach_deal_damage") \
			or StackResolver._has_effect_flag_prefix(def, "attached_damage_turn_start"):
		var f_opp := "p2" if player_id == "p1" else "p1"
		var f_hero := state.get_hero(f_opp)
		if f_hero:
			var f_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": f_hero.instance_id})
			if StackResolver.can_submit(state, f_act, db):
				result.append(f_act)
		return result
	var is_buff := StackResolver._has_effect_flag_prefix(def, "attached_buff")
	var side := player_id if is_buff else ("p2" if player_id == "p1" else "p1")
	var best: PendingAction = null
	var best_score := -1
	for ally in state.cards_in_zone(side + "_ally_row"):
		var act := PendingAction.make(action_type, player_id,
			{"card_id": card_id, "target_id": ally.instance_id})
		if not StackResolver.can_submit(state, act, db):
			continue
		if not is_buff and _def_cost(state, db, ally.instance_id) < def.cost:
			continue
		var score := state.get_atk(ally.instance_id, db, true)
		if score > best_score:
			best_score = score
			best = act
	if best:
		result.append(best)
	return result


# Returns true if this spell's effects include destroy_target:ally.
func _effect_is_destroy_ally(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "destroy_target" and parts.size() > 1 and parts[1] == "ally":
			return true
	return false


# A destroy effect is "worth it" on a target if:
#   - Target's cost >= spell cost (value-neutral or better trade)
#   - AND no single ready friendly ally can solo-kill it in combat (ATK >= target current HP)
# Un-attackable targets (Elusive, "can't attack" effects, etc.) fail the solo-lethal check
# naturally since get_legal_defenders won't include them — no special keyword check needed.
func _destroy_is_worth_it(state: GameState, db, player_id: String,
		target_id: String, spell_cost: int) -> bool:
	var t_def  := _card_def(state, db, target_id)
	var t_cost := t_def.cost if t_def else 0
	if t_cost < spell_cost:
		return false
	var t_hp := state.get_current_hp(target_id, db)
	return not _has_solo_lethal_attacker(state, db, player_id, target_id, t_hp)


# Returns true if any single ready ally controlled by player_id can legally attack
# target_id and has ATK >= target's current HP (solo kill without needing another attacker).
func _has_solo_lethal_attacker(state: GameState, db, player_id: String,
		target_id: String, target_hp: int) -> bool:
	for ally in state.cards_in_play(player_id):
		# Forecast "while attacking" bonuses — the ally would have them if it
		# swung, so a spell isn't needed when combat alone already kills.
		if state.get_atk(ally.instance_id, db, true) >= target_hp:
			var legal := StackResolver.get_legal_defenders(state, ally.instance_id, db)
			if target_id in legal:
				return true
	return false


func _card_def(state: GameState, db, card_id: String) -> CardDef:
	var card := state.get_card(card_id)
	if not card or not db:
		return null
	return db.get_def(card.card_def_id) as CardDef


# True if playing this Pet from hand would just trigger a sacrifice with no gain:
# already at pet capacity and no pet in play is worth less than the new one.
func _would_waste_pet(state: GameState, db, player_id: String, card: CardInstance) -> bool:
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.card_subtype != "Pet":
		return false
	var ps := state.players.get(player_id) as PlayerState
	var capacity: int = ps.pet_capacity if ps else 1
	var pets_in_play: Array[CardInstance] = []
	for ally in state.cards_in_zone(player_id + "_ally_row"):
		var ally_def := db.get_def(ally.card_def_id) as CardDef
		if ally_def and ally_def.card_subtype == "Pet":
			pets_in_play.append(ally)
	if pets_in_play.size() < capacity:
		return false
	var new_cost: int = def.cost
	for pet in pets_in_play:
		var pet_def := db.get_def(pet.card_def_id) as CardDef
		var pet_cost: int = pet_def.cost if pet_def else 0
		if new_cost > pet_cost:
			return false   # worth replacing this one — sacrifice heuristic will keep the best
	return true


func _def_cost(state: GameState, db, card_id: String) -> int:
	var def := _card_def(state, db, card_id)
	return def.cost if def else 0


func _action_type_for(card: CardInstance, db) -> String:
	if not db:
		return "play_ally"
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return ""
	if def.card_type in ["Quest", "Location"]:
		return ""   # go to resource row via place_resource
	if def.card_type == "Ally":
		return "play_ally"
	if def.card_type == "Equipment":
		return "play_equipment"
	# An ongoing Ability (e.g. Searing Totem, an Instant Ability that ENTERS play)
	# routes to play_ability even when Instant — play_instant would resolve-and-
	# graveyard it instead of leaving it in play. Non-ongoing Instant Abilities
	# (Quick Strike) still route to play_instant.
	if def.card_type == "Ability" and StackResolver.is_ongoing_def(def):
		return "play_ability"
	if def.is_instant:
		return "play_instant"
	if def.card_type == "Ability":
		return "play_ability"
	return ""
