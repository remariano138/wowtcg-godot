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
#   "combat_instant_exhaust_on_enter" — Instant ALLY whose enters-play trigger
#       exhausts a target ally (effects: on_enter:exhaust_ally). Exactly the
#       role above, on a body instead of a spell: flashed in while an opposing
#       combat proposal is on the chain, the play_ally link resolves first, her
#       trigger exhausts the attacking ALLY, and the proposal fizzles at the
#       601.3 recheck. The play announces NO target_id — the target is picked
#       at her own enter-play choice point (playtest _handle_enter_play_target,
#       which aims at state.combat_attacker). See exhaust_attacker_action().
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
# Total resources below which the AI won't pay a quest's "destroy this quest"
# completion cost (Into the Maw of Madness) — the quest is a resource itself, so
# completing it is a permanent -1 ramp for one card.
const DESTROY_SELF_QUEST_MIN_RESOURCES := 6
# Poison Water: recycle the graveyard instead of drawing only once the deck is
# down to this many cards (410.6b — being decked is an instant loss).
const GRAVEYARD_RECYCLE_DECK_FLOOR := 10

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
	"azeroth_105": "combat_instant_exhaust",     # Waylay — exhaust target ally (+ a stealth-gated kill: waylay_action)
	"azeroth_17":  "combat_instant_exhaust",     # Bash — exhaust target hero or ally (+ bear form ongoing)
	"dark_portal_137": "combat_instant_exhaust", # War Stomp — exhaust ALL opposing heroes and allies (no target)
	"azeroth_68":  "combat_instant_exhaust",     # Hammer of Justice — Gouge's exhaust + ready-lock plus a cantrip (ready-lock not modeled for AI)
	"azeroth_99":  "combat_instant_exhaust",     # Gouge — exhaust target hero or ally (+ can't-ready-next-step rider, not modeled for AI)
	"dark_portal_199": "combat_instant_exhaust_on_enter", # Bhenn Checks-the-Sky — Instant Ally, on enter: you may exhaust target ally
	"dark_portal_121": "combat_instant_exhaust",     # Intercept — exhaust target hero or ally + 1 melee dmg (ready-lock N/A; damage rider not modeled for AI)
	"dark_portal_20": "combat_instant_dmg",      # Claw — 3 melee damage (+ cat form ongoing)
	"azeroth_18":  "combat_instant_bear_form",   # Bear Form — hero gains protector (see bear_form_action)
	"azeroth_25":  "combat_instant_bear_form",   # Maul — bear form + "your hero has +1 ATK this turn" (same hook; the pump rides along on the retaliation)
	"azeroth_172": "combat_instant_save_bounce", # Withdraw — put target ally into its owner's hand
	"azeroth_160": "combat_instant_save_bounce", # Fall Back — put target friendly ally into its owner's hand
	"azeroth_48":  "combat_instant_evasion",     # Blink — draw + remove attacker while hero defends
	"dark_portal_141": "combat_instant_destroy_protector",  # First to Fall — destroy target protecting ally
	"azeroth_44":  "combat_instant_atk_swing",   # Ravenous Bite — +3 ATK / -3 ATK on two allies (see atk_swing_action)
	"azeroth_152": "combat_instant_save_elusive", # Sneak — target ally has elusive this turn (see elusive_save_action)
	"azeroth_35":  "combat_instant_pet_shield", # Bestial Wrath -- target Pet +3 ATK and takes no damage this turn (see bestial_wrath_action)
	"azeroth_155": "combat_instant_ally_atk",  # Skewer — a chosen friendly ally deals its ATK to target ally
	"dark_portal_129": "combat_instant_escape",   # Escape Artist — modal: interrupt an ability targeting our hero, or remove attackers (see escape_artist_action)
	"azeroth_51":  "combat_instant_counterspell", # Counterspell — interrupt ANY ability card on the chain (see counterspell_action)
	"azeroth_70":  "combat_instant_holy_shield", # Holy Shield — counted, source-scoped hero shield that reflects (see holy_shield_action)
	"azeroth_145": "combat_instant_mortal_strike", # Mortal Strike — damage + "can't be healed this turn" (see mortal_strike_action)
	"dark_portal_37": "combat_instant_dmg",  # Point Blank — 3 ranged to target attacker, but ONLY while our hero is the settled defender (the require_hero_defending gate below)
	"dark_portal_42": "combat_instant_wing_clip",  # Wing Clip — 1 melee + "can't attack your hero this turn" (see wing_clip_action)
	"azeroth_49":  "combat_instant_brain_freeze", # Brain Freeze — "players can't draw cards this turn" (see brain_freeze_action)
}


# Return a PendingAction to submit, or null to pass priority.
# Called once each time this player has priority.
# Even the base AI plays combat instants — the ambush behavior is universal.
func decide_action(state: GameState, db, player_id: String) -> PendingAction:
	var ambush := combat_instant_action(state, db, player_id)
	if ambush != null:
		return ambush
	var escape := escape_artist_action(state, db, player_id)
	if escape != null:
		return escape
	var counter := counterspell_action(state, db, player_id)
	if counter != null:
		return counter
	# Brain Freeze — nullify a draw link the opponent has already paid for.
	var freeze_draws := brain_freeze_action(state, db, player_id)
	if freeze_draws != null:
		return freeze_draws
	# Wing Clip: the same interrupt point as Litori's freeze, on a 1-cost
	# hand card, and narrowed to proposals aimed at our own HERO.
	var clip := wing_clip_action(state, db, player_id)
	if clip:
		return clip
	var freeze := hero_disable_action(state, db, player_id)
	if freeze != null:
		return freeze
	var exhaust := exhaust_attacker_action(state, db, player_id)
	if exhaust != null:
		return exhaust
	var power_exhaust := exhaust_attacker_ally_power_action(state, db, player_id)
	if power_exhaust != null:
		return power_exhaust
	# Lynda Steele (rule 600.2) — force a bad attack on the opponent's turn.
	var force_attack := must_attack_action(state, db, player_id)
	if force_attack != null:
		return force_attack
	var sneak := elusive_save_action(state, db, player_id)
	if sneak != null:
		return sneak
	var wrath := bestial_wrath_action(state, db, player_id)
	if wrath != null:
		return wrath
	# Mortal Strike — lethal on their hero, or a hard counter to a heal on it.
	var mortal := mortal_strike_action(state, db, player_id)
	if mortal != null:
		return mortal
	# Katsin Bloodoath — shield an ally that would die in this combat.
	# Avanthera — pull her out of a combat she would not survive.
	var avanthera := avanthera_escape_action(state, db, player_id)
	if avanthera != null:
		return avanthera
	# Ghost Wolf — cancel an ally attack our hero is defending against.
	var ghost_wolf := ghost_wolf_action(state, db, player_id)
	if ghost_wolf != null:
		return ghost_wolf
	# Waylay — with a stealthed hero it KILLS the attacking ally, which the
	# shared combat_instant_exhaust path would misprice as a mere freeze.
	var waylay := waylay_action(state, db, player_id)
	if waylay != null:
		return waylay
	var katsin := katsin_shield_action(state, db, player_id)
	if katsin != null:
		return katsin
	# Soul Link — move incoming hero damage onto the party, a point at a time.
	var soul_link := soul_link_action(state, db, player_id)
	if soul_link != null:
		return soul_link
	# Graccus — the game's one flip, spent on damage already on its way.
	# Holy Shield — ward our hero against one attacker, and reflect it back.
	var holy := holy_shield_action(state, db, player_id)
	if holy != null:
		return holy
	var graccus := graccus_shield_action(state, db, player_id)
	if graccus != null:
		return graccus
	var korthas := korthas_shield_action(state, db, player_id)
	if korthas != null:
		return korthas
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
	# Dragonkin Menace (BaseAI) — ready a spent protector while attacked.
	var ready_quest := ready_protector_quest_action(state, db, player_id)
	if ready_quest != null:
		return ready_quest
	var thangal := thangal_ready_action(state, db, player_id)
	if thangal != null:
		return thangal
	var warrax := warrax_protector_action(state, db, player_id)
	if warrax != null:
		return warrax
	var dodge := evasion_action(state, db, player_id)
	if dodge != null:
		return dodge
	var swing := atk_swing_action(state, db, player_id)
	if swing != null:
		return swing
	var bear := bear_form_action(state, db, player_id)
	if bear != null:
		return bear
	# Outrider Zarg: he dies at end of turn unless he dealt damage, so swing with
	# him rather than end the turn holding a card that is about to destroy itself.
	var use_it := use_it_or_lose_it_attack_action(state, db, player_id)
	if use_it != null:
		return use_it
	# Rule 600.2 last resort: one of ours must attack if able and we have nothing
	# else we want to do. The engine will REFUSE our pass while that is true, so
	# without this the AI would sit on a blocked pass forever. Kept last so every
	# voluntary line above is tried first — the lock constrains only the pass.
	return forced_attack_action(state, db, player_id)


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
		# get_armor_def, not the printed value: Natural Defenses' aura is what
		# put a DEF 0 armor in this pool in the first place, and the bonus is
		# what it actually prevents.
		var dv := StackResolver.get_armor_def(state, armor_id, db)
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
		var tag: String = COMBAT_INSTANT_TAGS.get(card.card_def_id, "")
		if tag != "combat_instant_dmg" and tag != "combat_instant_ally_atk":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		# Skewer (`combat_instant_ally_atk`): the damage isn't printed on the
		# card — it is the ATK of an ally we CHOOSE from our own party, so the
		# AI values the card at its best ally's ATK and always announces that
		# ally (the choice is free: no cost, no exhaust, it just has to be in
		# play). The victim is a target ALLY, so unlike a damage instant this
		# can only ever answer an attacking ALLY, never an attacking hero.
		var skewer_source := ""
		var dmg := 0
		if tag == "combat_instant_ally_atk":
			if not _is_ally_in_play(state, attacker_id):
				continue
			skewer_source = _best_ally_atk_source(state, db, player_id)
			if skewer_source == "":
				continue
			dmg = state.get_atk(skewer_source, db)
		else:
			dmg = _combat_instant_dmg(def)
		if dmg <= 0:
			continue
		# Point Blank: "If your hero is defending…" is an EFFECT condition, so
		# the card is legal anywhere but resolves into nothing unless our own
		# hero is the settled defender (602.3 — never during the attack window,
		# where it is only a PROPOSED defender). Playing it there would burn the
		# card for zero, so the AI asks the engine's own condition rather than
		# re-deriving it. Data-driven: any future card printing the clause
		# inherits the gate.
		if not StackResolver.hero_defending_condition_ok(state, def, player_id):
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
		# Skewer: the chosen source rides the play as its own param.
		if skewer_source != "":
			params["source_id"] = skewer_source
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


# The ally in `player_id`'s party with the highest CURRENT ATK — the source
# Skewer should always choose, since the card deals damage equal to whatever
# ally is named and choosing costs nothing. Read live (get_atk), so buffs,
# auras and a "+N while attacking" bonus on an ally of ours that is itself
# attacking are all counted.
static func _best_ally_atk_source(state: GameState, db, player_id: String) -> String:
	var best_id := ""
	var best_atk := 0
	for ally: CardInstance in state.cards_in_zone(player_id + "_ally_row"):
		var atk := state.get_atk(ally.instance_id, db)
		if atk > best_atk:
			best_atk = atk
			best_id = ally.instance_id
	return best_id


static func _is_ally_in_play(state: GameState, instance_id: String) -> bool:
	var card := state.get_card(instance_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	return zone != null and zone.zone_type == "ally_row"


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
# Wing Clip (dark_portal_42): "Target hero or ally can't attack your hero this
# turn. Your hero deals 1 melee damage to that character."
#
# Litori Frostburn's interrupt (hero_disable_action) as a 1-cost hand card, and
# narrowed the same way the card is: it bars the target from attacking OUR HERO
# only, so it saves the hero and nothing else. The 601.3 re-check is what makes
# it an interrupt — the named defender is no longer legal when the proposal
# resolves, so combat never starts and the attacker never exhausts.
#
# Fired ONLY in response to an opposing propose_combat that names our own hero
# as the defender. Everywhere else the lock is close to worthless (once the
# attack window is open the moment has passed, and "this turn" expires before
# their next attack step), which is also what the `no_combat_proposal` mute
# token expresses for the human UI — see the Auto-mute section in CLAUDE.md.
#
# The bar is the hero's SKIN, not a trade: nothing dies here, so the question is
# only whether the hit is worth a 1-cost card. Litori's hero branch is reused —
# lethal on our hero, or 4+ incoming — plus a "we can just kill it instead"
# check, since a damage instant that removes the attacker is strictly better
# than one that sends it at our allies.
func wing_clip_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.pending_actions.is_empty():
		return null
	var top: PendingAction = state.pending_actions.back()
	if top.action_type != "propose_combat" or top.source_player == player_id:
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	var attacker_id: String = top.params.get("attacker_id", "")
	var defender_id: String = top.params.get("defender_id", "")
	# The card only bars attacks on OUR HERO, so a proposal aimed at one of our
	# allies is not something it can answer at all.
	if defender_id != ps.hero_instance_id:
		return null
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null

	var a_atk := state.get_atk(attacker_id, db, true)
	var a_hp  := state.get_current_hp(attacker_id, db)
	if a_atk < 4 and a_atk < state.get_current_hp(defender_id, db):
		return null   # a scratch — not worth a card

	# Killing the attacker outright is strictly better than redirecting it.
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_dmg":
			continue
		var d := db.get_def(card.card_def_id) as CardDef
		if d and _combat_instant_dmg(d) >= a_hp \
				and d.cost <= state.get_available_resources(player_id):
			return null

	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_wing_clip":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id, "target_id": attacker_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


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

	# Bhenn Checks-the-Sky (combat_instant_exhaust_on_enter): the same interrupt
	# on an Instant ALLY. Playing her announces no target — her enters-play
	# trigger opens its own choice point once the play_ally link resolves, and
	# the scene aims it at the attacker. Her pool is allies only, so like
	# Exhaustion she can't answer an attacking hero.
	if attacker_is_ally:
		for card in state.cards_in_zone(player_id + "_hand"):
			if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_exhaust_on_enter":
				continue
			var b_act := PendingAction.make(_action_type_for(card, db), player_id,
				{"card_id": card.instance_id})
			if StackResolver.can_submit(state, b_act, db):
				return b_act
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


# ── Bestial Wrath (azeroth_35) ────────────────────────────────────────────────
# "Target Pet has +3 ATK this turn. Prevent all damage that would be dealt to it
# this turn." Held (combat_instant_pet_shield), never blind-played: the +3 alone
# is not worth a card, and the shield is only worth anything against damage that
# is actually coming.
#
# The card is legal on ANY Pet in play, the opponent's included, but the AI only
# ever targets its OWN -- buffing and shielding an enemy Pet is never wanted.
#
# Three uses, in priority order:
#   1. DEFENCE. Our Pet is the proposed defender of an opposing attack that would
#      kill it. The shield zeroes the damage, so the Pet survives AND retaliates
#      at +3 -- often killing the attacker outright.
#   2. LETHAL DAMAGE ON THE CHAIN aimed at our Pet (_chain_threatened_ally with
#      damage_only, since a shield stops damage but NOT a destroy effect).
#   3. OFFENCE. Our own Pet is the proposed attacker and would die to the
#      defender's retaliation. The shield makes the attack free; the +3 may also
#      turn a bounce into a kill. Long-Range attackers take no retaliation at
#      all, so there is nothing to save there and only the +3 would apply --
#      not worth a card on its own, so those are skipped.
func bestial_wrath_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var target_id := ""

	if not state.pending_actions.is_empty():
		var top: PendingAction = state.pending_actions.back()
		if top.action_type == "propose_combat":
			var attacker_id: String = top.params.get("attacker_id", "")
			var defender_id: String = top.params.get("defender_id", "")
			if state.is_in_play(attacker_id) and state.is_in_play(defender_id):
				var attacker := state.get_card(attacker_id)
				var defender := state.get_card(defender_id)
				if top.source_player != player_id \
						and defender and defender.controller == player_id \
						and _is_own_pet(state, db, defender_id, player_id):
					# (1) Our Pet defends and would die to the hit.
					if state.get_atk(attacker_id, db, true) \
							>= state.get_current_hp(defender_id, db):
						target_id = defender_id
				elif top.source_player == player_id \
						and attacker and attacker.controller == player_id \
						and _is_own_pet(state, db, attacker_id, player_id):
					# (3) Our Pet attacks into lethal retaliation.
					var retaliation := state.get_atk(defender_id, db)
					if retaliation >= state.get_current_hp(attacker_id, db) \
							and not StackResolver._has_keyword(
								attacker, "long_range", db, state):
						target_id = attacker_id

	# (2) Lethal targeted DAMAGE on the chain aimed at one of our Pets.
	if target_id == "":
		var threatened := _chain_threatened_ally(state, db, player_id, true)
		if threatened != "" and _is_own_pet(state, db, threatened, player_id):
			target_id = threatened

	if target_id == "":
		return null
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_pet_shield":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id, "target_id": target_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# An in-play Pet this player controls. The engine's own _is_pet answers the
# subtype question; the controller check is the AI-side policy that keeps
# Bestial Wrath off the opponent's Pets.
func _is_own_pet(state: GameState, db, card_id: String, player_id: String) -> bool:
	var card := state.get_card(card_id)
	return card != null and card.controller == player_id \
		and StackResolver._is_pet(state, card_id, db)


# True when the card mass-exhausts every opposing character with no target
# (War Stomp: exhaust_all_opposing) — answers attacking heroes AND allies.
static func _exhausts_all_opposing(def: CardDef) -> bool:
	if not def:
		return false
	for entry in def.effects.split("|"):
		if entry.strip_edges().split(":")[0] == "exhaust_all_opposing":
			return true
	return false


# True when the def carries an `exhaust_target:KIND` segment (Charge,
# Exhaustion, Bash, Gouge). Returns "" when it doesn't.
static func _exhaust_target_kind(def: CardDef) -> String:
	if not def:
		return ""
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "exhaust_target" and parts.size() > 1:
			return parts[1]
	return ""


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


# ── Escape Artist (dark_portal_129 / combat_instant_escape) ───────────────────
# "Choose one: Interrupt target ability card that's targeting your hero; or if
# your hero is defending, remove all attackers from combat." Held like every
# combat instant and never blind-played — both halves are answers.
#
# Mode priority is the card's whole policy:
#   • INTERRUPT whenever an opposing ability on the chain targets our hero, with
#     no value bar at all. An ability aimed at a hero is a discard, a lasting
#     debuff or a burn that never trades — reliably worth a 1-cost card, and
#     unlike a damage answer there is nothing to compute. Never our own link.
#   • REMOVE ATTACKERS only in the defend window with our hero defending, and
#     only when the hit is worth a card: the attacker is an ALLY costing 3 or
#     more, or the forecast incoming damage is 4+ (which is what catches a cheap
#     ally that has been pumped into a real threat).
func escape_artist_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.pending_enter_play_effect.is_empty():
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_escape":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var modes := StackResolver.modal_modes(def)
		var i_mode := _mode_index(modes, "interrupt_ability")
		if i_mode >= 0:
			var victim := _best_interrupt_target(state, db, player_id)
			if victim != "":
				var act := PendingAction.make(_action_type_for(card, db), player_id, {
					"card_id": card.instance_id, "target_id": victim, "mode": i_mode,
				})
				if StackResolver.can_submit(state, act, db):
					return act
		var r_mode := _mode_index(modes, "remove_attackers")
		if r_mode >= 0 and _escape_dodge_worth_it(state, db, player_id):
			var dodge_act := PendingAction.make(_action_type_for(card, db), player_id, {
				"card_id": card.instance_id, "mode": r_mode,
			})
			if StackResolver.can_submit(state, dodge_act, db):
				return dodge_act
	return null


# ── Mortal Strike (azeroth_145) ───────────────────────────────────────────────
#
# "Your hero deals X melee damage to target hero or ally, where X is 1 plus the
# ATK of one of your Melee weapons. That character can't be healed this turn."
#
# Held (COMBAT_INSTANT_TAGS) and never blind-played, and — unlike every other
# held instant here — it is aimed at the opposing HERO and nothing else. Two
# reasons to fire it, in order:
#
#   1. LETHAL. X is a live board read (weapon ATK included), so the same
#      question every burn asks: does it finish the hero right now? Armor is
#      respected — a ready DEF>0 piece can absorb the difference at the
#      prevention point (717.2c), so a "lethal" that their armor covers is not
#      one, and firing it there would spend the card for nothing.
#
#   2. HARD COUNTER TO A HEAL. An opposing link on the chain heals their hero →
#      resolve first (the chain is LIFO), stamp "can't be healed this turn", and
#      their heal resolves into a no-op. Note this is NOT an interrupt: their
#      card is still spent, which is exactly why it is worth our 2 — we trade a
#      card for a card AND deal the damage on top.
#
# Deliberately never pointed at an ALLY, even to kill one: the two conditions
# above are what the card is being held for, and an ally kill would spend the
# resources the heal-counter wants.
func mortal_strike_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.pending_enter_play_effect.is_empty():
		return null
	var opp := _other_player_id(state, player_id)
	var opp_ps := state.players.get(opp) as PlayerState
	var opp_hero: String = opp_ps.hero_instance_id if opp_ps else ""
	if opp_hero == "":
		return null
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_mortal_strike":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var amount := StackResolver.weapon_atk_damage_amount(state, def, player_id, db)
		var lethal := amount > 0 			and amount - _hero_armor_soak(state, db, opp) >= state.get_current_hp(opp_hero, db)
		if not (lethal or _chain_heals_hero(state, db, opp, opp_hero)):
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id, {
			"card_id": card.instance_id, "target_id": opp_hero,
		})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Damage a player's ready armor could still prevent (717.2c). Used to keep a
# "lethal" honest — the defender gets the prevention point before the packet
# lands, and every DEF they can exhaust comes off it.
func _hero_armor_soak(state: GameState, db, player_id: String) -> int:
	var soak := 0
	for armor_id in StackResolver.get_ready_def_armor(state, player_id, db):
		soak += StackResolver.get_armor_def(state, armor_id, db)
	return soak


# Does a link on the chain heal `hero_id` (that player's own hero)? The chain is
# just state.pending_actions, and each link names the card that made it —
# `card_id` for a hand card or an ally/equipment power, `hero_id` for a hero
# flip power — so the def's effect segments answer "is this a heal", and the
# announced target slot answers "at their hero".
#
# Covers the targeted heals (heal_target, deal_damage_and_heal's second slot, a
# chosen heal MODE, heal_x_from_target) via the target slots, plus the
# untargeted party sweeps (heal_party), which name nobody but include their
# hero by definition. Only the OPPONENT's own links count: a heal we are casting
# is not something to counter.
func _chain_heals_hero(state: GameState, db, healer_id: String, hero_id: String) -> bool:
	if not db:
		return false
	for pending in state.pending_actions:
		var pa := pending as PendingAction
		if not pa or pa.source_player != healer_id:
			continue
		var src_id: String = str(pa.params.get("card_id", ""))
		if src_id == "":
			src_id = str(pa.params.get("hero_id", ""))
		var src := state.get_card(src_id)
		var src_def := db.get_def(src.card_def_id) as CardDef if src else null
		if not src_def or src_def.effects == "":
			continue
		# A modal link only does what its ANNOUNCED mode says (707.1c), so the
		# chosen mode's inner segment is the only one that counts.
		if StackResolver.is_modal_def(src_def):
			var chosen: String = StackResolver.selected_mode(src_def, pa)
			if chosen.begins_with("heal_target") 					and str(pa.params.get("target_id", "")) == hero_id:
				return true
			continue
		for entry in src_def.effects.split("|"):
			var parts := entry.strip_edges().split(":")
			var head := parts[0].strip_edges()
			# A party sweep heals their hero without naming it as a target.
			if head in ["heal_party", "heal_party_each_turn"]:
				return true
			# An activated power (a weapon's or ally's) carries its effect key in
			# field 2; every other heal shape carries it in field 0.
			var heals := head in ["heal_target", "deal_damage_and_heal", "heal_x_from_target"]
			if head == "activated_power":
				heals = parts.size() > 2 and parts[2].strip_edges() == "heal_target"
			if not heals:
				continue
			# heal_target / heal_x_from_target announce the healed character in
			# target_id; Shock and Soothe's heal half rides heal_target_id.
			for slot in ["target_id", "heal_target_id"]:
				if str(pa.params.get(slot, "")) == hero_id:
					return true
	return false


# ── Brain Freeze (azeroth_49 / combat_instant_brain_freeze) ───────────────────
# "Players can't draw cards this turn." Held, and NEVER blind-played — which is
# the whole policy question, so it is worth stating why.
#
# The obvious line is to cast it on the opponent's turn before their draw step,
# denying one card. That is a bad trade: a 3-cost card and 3 resources for a
# single draw. The card is instead a COUNTER — priority is LIFO, so a Brain
# Freeze announced on top of a draw link resolves FIRST and the link beneath it
# then resolves into nothing, with its controller having already paid for it
# (412.2). Cancelling a completed quest's reward, a Mana Agate cracked for two
# cards, or an Ilandre refill is several cards' worth of denial for one, and the
# resources are gone either way.
#
# So the trigger is exactly: an OPPOSING link on the chain that draws.
#   • Our own draw links are never a reason to fire — the lock is SYMMETRIC and
#     would swallow our own draw too.
#   • And we hold the card entirely while a draw link of OURS is on the chain,
#     for the same reason: locking there would be pure self-harm.
# The rest of the turn's collateral (their next draw effect, and ours) is
# accepted: on the opponent's turn our own draws are rarely queued anyway.
#
# Nothing is announced (no target, no choice), so there is no pool to rank and
# no fizzle to guard against — one call to can_submit is the whole check.
func brain_freeze_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.pending_enter_play_effect.is_empty():
		return null
	var opp := _other_player_id(state, player_id)
	if opp == player_id:
		return null
	# Locking while our own draw sits on the chain would deny us, not them.
	if _chain_draws_cards(state, db, player_id):
		return null
	if not _chain_draws_cards(state, db, opp):
		return null
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_brain_freeze":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id, {
			"card_id": card.instance_id,
		})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Does a link on the chain make `drawer_id` draw cards? Same shape as
# _chain_heals_hero: the chain is just state.pending_actions and each link names
# the card that made it, so the def's effect segments answer "does this draw".
#
# Per rule 415.9f only an event that says the card is DRAWN is a draw, so a
# graveyard fetch (Call the Spirit), a reveal-pick (Eagle Eye) and a "look at"
# (Track Humanoids) are deliberately NOT counted — Brain Freeze does nothing
# about them, and firing at one would waste the card.
#
# A QUEST is counted on its printed reward alone: its `qmode:` choice is made at
# RESOLUTION (709.2b), so at announcement there is nothing to read — and a quest
# whose reward might be a draw is exactly the link this card wants to answer,
# since completing it has already cost resources.
func _chain_draws_cards(state: GameState, db, drawer_id: String) -> bool:
	if not db:
		return false
	for pending in state.pending_actions:
		var pa := pending as PendingAction
		if not pa or pa.source_player != drawer_id:
			continue
		var src_id: String = str(pa.params.get("card_id", ""))
		if src_id == "":
			src_id = str(pa.params.get("hero_id", ""))
		var src := state.get_card(src_id)
		var src_def := db.get_def(src.card_def_id) as CardDef if src else null
		if not src_def or src_def.effects == "":
			continue
		# A modal link only does what its ANNOUNCED mode says (707.1c).
		if StackResolver.is_modal_def(src_def):
			if StackResolver.selected_mode(src_def, pa).begins_with("draw"):
				return true
			continue
		for entry in src_def.effects.split("|"):
			var parts := entry.strip_edges().split(":")
			var head := parts[0].strip_edges()
			# Field 0 for a plain effect segment, field 1 for a quest reward
			# mode, field 2 for an activated power — the same positional
			# convention _chain_heals_hero reads.
			var key := head
			if head in ["qmode", "mode"] and parts.size() > 1:
				key = parts[1].strip_edges()
			elif head == "activated_power" and parts.size() > 2:
				key = parts[2].strip_edges()
			if key in ["draw", "hand_to_deck_draw"]:
				return true
	return false

# ── Counterspell (azeroth_51 / combat_instant_counterspell) ───────────────────
# "Interrupt target ability card." Escape Artist's interrupt half with the
# "targeting your hero" clause gone, so the pool is EVERY ability card on the
# chain — which makes the value question real in a way Escape Artist's isn't.
#
# Two bars, in priority order:
#   • An opposing ability aimed at our HERO is countered at ANY printed cost —
#     Escape Artist's reasoning verbatim: a discard, a lasting debuff or burn
#     never trades on its own, so the card is always worth spending.
#   • Otherwise counter the most expensive opposing ability whose printed cost
#     is at least Counterspell's own (the `_destroy_is_worth_it` convention).
#     Countering a 1-cost cantlet with a 2-cost card is how this gets wasted.
# Never our own link — the printed text allows it, but it is pure self-harm.
# Held like every combat instant, and it is never blind-played: with an empty
# chain the card is not even legal (706.2 — no targetless mode to fall back on).
func counterspell_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.pending_enter_play_effect.is_empty():
		return null
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_counterspell":
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		# Pass 1: anything aimed at our hero, no value bar.
		var victim := _best_interrupt_target(state, db, player_id, true, -1)
		if victim == "":
			# Pass 2: the rest of the chain, gated on printed cost.
			victim = _best_interrupt_target(state, db, player_id, false,
					StackResolver.printed_cost(def))
		if victim == "":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id, {
			"card_id": card.instance_id, "target_id": victim,
		})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# Index of the mode whose inner effect starts with `head`; -1 when absent.
static func _mode_index(modes: Array, head: String) -> int:
	for i in modes.size():
		if (modes[i] as String).begins_with(head):
			return i
	return -1


# The link Escape Artist should interrupt: the most expensive OPPOSING ability on
# the chain that targets our hero, "" when there is none. Printed cost is the
# value proxy used everywhere else in the AI. Our own abilities are never
# candidates — the printed text allows it, but interrupting our own play is
# strictly self-harm.
func _best_interrupt_target(state: GameState, db, player_id: String,
		require_hero_target: bool = true, min_cost: int = -1) -> String:
	var best := ""
	var best_cost := -1
	for cid in StackResolver.get_interrupt_candidates(state, db, player_id,
			require_hero_target):
		var owner_player := ""
		for link in state.pending_actions:
			if str((link as PendingAction).params.get("card_id", "")) == cid:
				owner_player = (link as PendingAction).source_player
				break
		if owner_player == player_id:
			continue
		var card := state.get_card(cid)
		var def := db.get_def(card.card_def_id) as CardDef if card else null
		var cost := StackResolver.printed_cost(def) if def else 0
		# Counterspell's value bar: a general interrupt trades card-for-card, so
		# spending it on something cheaper than itself is a loss. Escape Artist
		# passes -1 (no bar) — an ability aimed at a HERO is a discard, a lasting
		# debuff or burn that never trades, worth the card at any printed cost.
		if min_cost >= 0 and cost < min_cost:
			continue
		if cost > best_cost:
			best_cost = cost
			best = cid
	return best


# Is the remove-attackers half worth the card? Our hero must actually be
# defending (602.3 — the defend window, not the attack window, where the clause
# would no-op), and the incoming hit must clear one of the two bars described on
# escape_artist_action.
func _escape_dodge_worth_it(state: GameState, db, player_id: String) -> bool:
	if not state.combat_defend_window:
		return false
	if not state.pending_actions.is_empty():
		return false   # respond on the window floor
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return false
	var ps := state.players.get(player_id) as PlayerState
	if not ps or defender_id != ps.hero_instance_id:
		return false   # only when OUR HERO is the defender
	var incoming := state.get_atk(attacker_id, db)
	if incoming <= 0:
		return false   # nothing to dodge
	if incoming >= 4:
		return true
	# A cheap body hitting for little isn't worth a card; a real ally is.
	if StackResolver._is_ally(state, attacker_id):
		var a_card := state.get_card(attacker_id)
		var a_def := db.get_def(a_card.card_def_id) as CardDef if a_card else null
		return a_def != null and StackResolver.printed_cost(a_def) >= 3
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
#   • the hero is NOT already in bear form (hero_is_in_form, by NAME),
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
	# Already in bear form? Ask the FORM STATE by name, never a grant it happens
	# to carry — the grant now lives in GameState.FORM_GRANTS, not on the card,
	# and even before that "any Form granting protector" was a proxy that would
	# have matched a future non-bear protector Form.
	if StackResolver.hero_is_in_form(state, player_id, "bear", db):
		return null
	# A board protector already answers this attack — save the card.
	if choose_protector(state, db, player_id) != "":
		return null

	# Several cards grant bear form (Bear Form, Maul). They are interchangeable
	# for the purpose this hook serves — the hero becomes a legal protector — so
	# spend the CHEAPEST affordable one and keep the rest: Maul's +1 ATK only
	# adds to the retaliation, which is worth less than the resources and than
	# Bear Form's pay-2 return clause. Form (1) uniqueness means the second copy
	# would have to eat the first anyway.
	var bf_best: PendingAction = null
	var bf_cost := -1
	for card in state.cards_in_zone(player_id + "_hand"):
		if COMBAT_INSTANT_TAGS.get(card.card_def_id, "") != "combat_instant_bear_form":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id})
		if not StackResolver.can_submit(state, act, db):
			continue
		var c := state.get_play_cost(card.instance_id, db, 0)
		if bf_best == null or c < bf_cost:
			bf_best = act
			bf_cost = c
	return bf_best


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


# Lynda Steele: "(1) -> Target ally must attack this turn if able." (rule 600.2)
#
# Played during the OPPONENT's turn only — the lock applies during the target's
# controller's own action phase, and the grant expires at end of turn, so on our
# turn it is strictly wasted. `_get_ally_power_actions` therefore holds the power
# and this is the one place it fires.
#
# What we are buying is a bad attack made by a body that would rather have stayed
# home, so the bar is that the forced attack is bad FOR THEM: after it, their
# ally is exhausted (so it can't protect our swing back) and we can take the hit
# or kill it. We fire it on the opposing ally that:
#   * is a legal attacker for them right now (an exhausted or summoning-sick
#     ally is "unable", so the lock would be a no-op — 600.2's "if able"), and
#   * can't kill the best defender it could be forced into, or dies to it.
# The most valuable such ally is chosen, since forcing their biggest threat to
# throw itself at a wall is the whole point.
#
# Deliberately NOT modeled: forcing an attack purely to strip a would-be
# protector for OUR next turn. It is a real use, but it needs a read of our own
# next turn's board that the heuristic AI doesn't have, and paying 1 a turn for
# a guess is worse than holding the resource.
# Katsin Bloodoath: "(3) -> Prevent all combat damage that would be dealt to and
# dealt by target friendly ally this turn." A pure SAVE — the shield stops what
# the ally deals as well as what it takes, so it never wins a fight, it only
# refuses to lose one. Fired when one of our allies is in a combat it would not
# survive, held otherwise (the power costs 3 a shot and does nothing outside
# combat).
#
# The "dealt by" half is what shapes the policy: shielding an ally that would
# kill its opponent and live throws away a kill, so that case is skipped
# outright. A mutual trade is shielded only when OUR body is worth at least
# theirs — otherwise letting the trade happen is the better deal.
#
# Works in the attack window, the defend window and in response to a combat
# proposal still on the chain: the grant lasts the turn, so any of those is
# early enough to cover the conclusion.
# ── Avanthera (dark_portal_154) ───────────────────────────────────────────────
# "(1) -> If Avanthera is in combat, remove her from combat."
#
# WHEN: only while she would actually DIE to the combat. She is a 3/2, so she
# wins plenty of fights and pulling out of one throws the kill away and pays 1
# for the privilege — which is what the generic untargeted branch would do every
# defend window. `combat_kills` is the shared "does this combat remove that
# card?" predicate, so a Devotion Aura reduction, a Brigg-style finisher and a
# Meatwall reflect are all counted for free.
#
# A trade she does not survive is still worth escaping: removing her from combat
# cancels the conclusion in BOTH directions (603.1b), so we lose the kill either
# way — the only question is whether we keep the body, and 1 resource for a
# 2-cost 3/2 is a good price. So unlike Katsin's shield there is no
# card_value_score comparison: any death is enough.
#
# The engine's own legality gate (StackResolver.is_in_combat) restricts this to
# the defend window, so there is no window check here — can_submit is the
# authority, and asking it is what keeps the hook and the rule from disagreeing.
func avanthera_escape_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if state.combat_attacker == "" or state.combat_defender == "":
		return null
	for card in state.cards_in_zone(player_id + "_ally_row"):
		var cid := card.instance_id
		if not StackResolver.is_in_combat(state, cid):
			continue
		var def := state.effective_def(cid, db) as CardDef
		if not def:
			continue
		if StackResolver._ally_activated_power(def).get(
				"effect", "") != "remove_self_from_combat":
			continue
		var is_attacker := (cid == state.combat_attacker)
		var foe: String = state.combat_defender if is_attacker else state.combat_attacker
		if not combat_kills(state, db, foe, cid, not is_attacker):
			continue
		var act := PendingAction.make("use_ally_power", player_id, {"card_id": cid})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# ── Ghost Wolf (azeroth_110) ───────────────────────────────────────────────────
# "Ongoing: Exhaust your hero -> If your hero is defending, remove all attacking
# allies from combat."
#
# Held out of _get_ally_power_actions entirely: the generic untargeted branch
# would fire it at every priority window, and outside an open DEFEND window with
# our own hero defending the power resolves into nothing (602.3) while the
# hero-exhaust cost is still spent.
#
# The gate is exactly the situation the card answers: our hero is the settled
# defender and the attacker is an ALLY (an attacking HERO is not removed, so
# firing then buys nothing). Given that, the removal is close to free — 602.4
# leaves the combat step running and 603.1b then deals no damage in EITHER
# direction, while our hero was not going to attack on the opponent's turn
# anyway — so there is deliberately no value bar beyond it. Sole cost: the hero
# is exhausted and so can no longer PROTECT this turn, which matters only for a
# later attack, whereas the attack in front of us is cancelled outright.
#
# can_submit is the authority on affordability (a ready hero, rule 412.2) and on
# the source still being in play, which is what keeps the hook and the rule from
# disagreeing.
# ── Waylay (azeroth_105, combat_instant_exhaust) ──────────────────────────
# "Exhaust target ally. If your hero is stealthed, it deals damage to that ally
# equal to that ally's health."
#
# The card is TWO cards, and the shared exhaust_attacker_action only knows the
# first one. Un-stealthed it is Exhaustion, and the tag gives us that interrupt
# for free — this hook returns null and lets that path handle it. STEALTHED it
# is unconditional removal that also freezes, and that difference matters twice
# over: the shared worth gate is calibrated for a freeze (it declines an attacker
# our own ally beats anyway), and its "hold if a damage instant kills it" bail
# would hold Waylay in favour of a card that does strictly less. So the stealthed
# case gets its own, much lower bar here, ahead of that hook in decide_action.
#
# Deliberately RESPONSE-ONLY, never proactive on our own turn. The damage breaks
# our own Stealth (destroy_self_on_hero_damage), which on our turn costs the
# unblockable hero swing stealth exists for — that is a tempo call this AI has no
# model for, the same one left unmade for Thangal's second attack and Maul. In an
# opposing combat window our hero is not attacking, so the stealth is doing
# nothing that turn and spending it is pure profit.
func waylay_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.pending_actions.is_empty():
		return null
	var top: PendingAction = state.pending_actions.back()
	if top.action_type != "propose_combat" or top.source_player == player_id:
		return null
	# The kill half is what we are here for, so this needs a stealthed hero.
	if not StackResolver.hero_is_stealthed(state, player_id, db):
		return null

	var attacker_id: String = top.params.get("attacker_id", "")
	var defender_id: String = top.params.get("defender_id", "")
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null
	# The pool is allies only, so an attacking HERO is out of reach.
	if not StackResolver._is_ally(state, attacker_id):
		return null
	var defender := state.get_card(defender_id)
	if not defender or defender.controller != player_id:
		return null   # only answer attacks on our own side

	# The bar is a removal spell's, not a freeze's: the attacker must be worth
	# the card (_destroy_is_worth_it's convention — printed cost at least the
	# spell's own, so we don't trade 2 for a token). Nothing about our defender
	# enters into it, because unlike a freeze this REMOVES the attacker: the
	# board is better off afterwards whatever happens in this one combat.
	var a_def := db.get_def(state.get_card(attacker_id).card_def_id) as CardDef
	if a_def == null:
		return null
	for card in state.cards_in_zone(player_id + "_hand"):
		if card.card_def_id != "azeroth_105":
			continue
		var w_def := db.get_def(card.card_def_id) as CardDef
		if w_def == null or a_def.cost < w_def.cost:
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id, "target_id": attacker_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


func ghost_wolf_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	if not state.combat_defend_window:
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	if state.combat_defender != ps.hero_instance_id:
		return null
	# An attacking hero is not removed by this power — see the resolution arm.
	var attacker := state.get_card(state.combat_attacker)
	if not attacker or attacker.zone_id != attacker.controller + "_ally_row":
		return null
	for card in state.cards_in_zone(player_id + "_hero_row"):
		var def := state.effective_def(card.instance_id, db) as CardDef
		if not def:
			continue
		if StackResolver._ally_activated_power(def).get(
				"effect", "") != "remove_attacking_allies":
			continue
		var act := PendingAction.make("use_ally_power", player_id,
			{"card_id": card.instance_id})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


func katsin_shield_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var attacker_id := ""
	var defender_id := ""
	if state.combat_attack_window or state.combat_defend_window:
		attacker_id = state.combat_attacker
		defender_id = state.combat_defender
	elif not state.pending_actions.is_empty():
		var top: PendingAction = state.pending_actions.back()
		if top.action_type == "propose_combat":
			attacker_id = top.params.get("attacker_id", "")
			defender_id = top.params.get("defender_id", "")
	if attacker_id == "" or defender_id == "":
		return null
	if not state.is_in_play(attacker_id) or not state.is_in_play(defender_id):
		return null

	# Which side is ours, and is it an ALLY? (The power can't shield a hero.)
	var ours := ""
	var theirs := ""
	for pair in [[attacker_id, defender_id], [defender_id, attacker_id]]:
		var card := state.get_card(pair[0])
		if card and card.controller == player_id \
				and StackResolver._is_ally(state, pair[0]):
			ours = pair[0]
			theirs = pair[1]
			break
	if ours == "":
		return null

	# Only worth 3 resources if our ally is actually about to die.
	var ours_is_attacker := (ours == attacker_id)
	var verdict := combat_trade_value(state, db, ours, theirs, ours_is_attacker)
	if verdict == "both":
		# A trade: shield only if our body is worth at least theirs.
		if card_value_score(state, db, ours) < card_value_score(state, db, theirs):
			return null
	elif verdict != "suicide":
		# "safe_lethal" — we kill it and live, so shielding throws the kill away.
		# "no_one"      — nothing of ours dies, so there is no save to make.
		return null

	for katsin in state.cards_in_zone(player_id + "_ally_row"):
		var def := db.get_def(katsin.card_def_id) as CardDef
		if not def:
			continue
		if StackResolver._ally_activated_power(def).get(
				"effect", "") != "prevent_combat_damage_target":
			continue
		var act := PendingAction.make("use_ally_power", player_id,
			{"card_id": katsin.instance_id, "target_id": ours})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# ── Soul Link (azeroth_133) ───────────────────────────────────────────────────
# "Put 1 damage on an ally in your party -> Prevent the next 1 damage that would
# be dealt to your hero this turn."
#
# The card is a way to move damage OFF the hero and ONTO the party, one point at
# a time, and it is free and repeatable — so the whole policy is (a) when, and
# (b) which ally eats it.
#
# WHEN: only while damage is actually on its way to our hero — an opposing
# combat where our hero is a combatant, or an opposing link on the chain aimed
# at it. Priority is LIFO, so a shield announced in response to that link
# resolves first and is standing when the damage lands. One point is bought per
# call; decide_action is re-entered after each, so the shield grows to match the
# forecast and stops there (already-banked shield is netted out, and unpreventable
# damage buys nothing at all — the shield would not be consumed).
#
# WHICH ALLY: deliberately a dumb, cruel heuristic — the sturdiest ally in the
# party, and NEVER one at 1 health. Putting the last point on an ally destroys
# it, which trades a whole card for 1 point of hero damage; the card is meant to
# grind the party down, not to feed it. When every ally is at 1 health the power
# simply isn't used.
func soul_link_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	var hero := state.get_card(ps.hero_instance_id)
	if not hero:
		return null

	var needed := _forecast_hero_damage(state, db, player_id)
	needed -= GameLogic.granted_shield(hero)
	if needed <= 0:
		return null   # nothing coming, or already covered

	# The ally that pays: highest remaining health, never one the point would
	# kill. Ties go to the ally we would miss least.
	var best := ""
	var best_hp := 1
	for ally in state.cards_in_zone(player_id + "_ally_row"):
		var hp := state.get_current_hp(ally.instance_id, db)
		if hp < 2:
			continue   # the last point destroys it — never worth 1 hero damage
		if hp > best_hp or (hp == best_hp and best != "" 				and card_value_score(state, db, ally.instance_id)
					< card_value_score(state, db, best)):
			best_hp = hp
			best = ally.instance_id
	if best == "":
		return null

	for card in state.cards_in_zone(player_id + "_hero_row"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		if StackResolver._ally_activated_power(def).get(
				"effect", "") != "prevent_next_hero_damage":
			continue
		var act := PendingAction.make("use_ally_power", player_id,
			{"card_id": card.instance_id, "target_id": best})
		if StackResolver.can_submit(state, act, db):
			return act
	return null


# How much damage is on its way to player_id's hero right now. A thin wrapper
# over _forecast_damage_to, kept because "the hero" is by far the common case
# (Soul Link names it outright).
func _forecast_hero_damage(state: GameState, db, player_id: String) -> int:
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return 0
	return _forecast_damage_to(state, db, player_id, ps.hero_instance_id)


# How much damage is on its way to one of player_id's characters right now: the
# combat it is in (as defender, or as an attacker facing retaliation) plus any
# opposing link on the chain aimed at it. Unpreventable sources contribute
# nothing — a shield is not consumed by them (rule 717), so buying one would be
# pure waste. Works for a hero or an ally; Graccus needs both.
func _forecast_damage_to(state: GameState, db, player_id: String,
		hero_id: String) -> int:
	if hero_id == "" or not state.is_in_play(hero_id):
		return 0
	var total := 0

	# (1) Combat — an open window, or a proposal of theirs still on the chain.
	var attacker_id := ""
	var defender_id := ""
	if state.combat_attack_window or state.combat_defend_window:
		attacker_id = state.combat_attacker
		defender_id = state.combat_defender
	else:
		for pending in state.pending_actions:
			var p := pending as PendingAction
			if p and p.action_type == "propose_combat" and p.source_player != player_id:
				attacker_id = p.params.get("attacker_id", "")
				defender_id = p.params.get("defender_id", "")
				break
	if state.is_in_play(attacker_id) and state.is_in_play(defender_id):
		if defender_id == hero_id:
			if not GameLogic.is_damage_unpreventable(state, db, attacker_id, true):
				total += max(forecast_atk(state, db, attacker_id, true), 0)
		elif attacker_id == hero_id 				and not StackResolver._has_keyword(
					state.get_card(hero_id), "long_range", db, state):
			# Our own hero swinging: the defender's retaliation comes back at it.
			if not GameLogic.is_damage_unpreventable(state, db, defender_id, true):
				total += max(state.get_atk(defender_id, db), 0)

	# (2) An opposing damage link on the chain aimed at our hero. Only the
	# announced target is read — the shield has to be standing before the link
	# resolves, and by then nothing else is knowable.
	for pending in state.pending_actions:
		var p := pending as PendingAction
		if not p or p.source_player == player_id:
			continue
		var src: String = p.params.get("card_id", p.params.get("hero_id", ""))
		var src_card := state.get_card(src)
		var src_def := db.get_def(src_card.card_def_id) as CardDef if src_card else null
		if not src_def:
			continue
		var aimed := false
		for slot in ["target_id", "target_id_2", "target_id_3"]:
			if p.params.get(slot, "") == hero_id:
				aimed = true
		if not aimed:
			continue
		if GameLogic.is_damage_unpreventable(state, db, src, false):
			continue
		# Chastise prints unpreventability on the DAMAGE rather than on the
		# source, so it can't be read off `src` — banking a shield against it
		# would buy nothing.
		if StackResolver._has_effect_flag(src_def, "damage_unpreventable"):
			continue
		for seg in src_def.effects.split("|"):
			var parts := seg.split(":")
			if parts[0] in ["deal_damage_to_target", "multi_shot",
					"deal_damage_and_heal", "deal_damage_weapon_atk"] 					and parts.size() > 1:
				total += int(p.params.get("x_value", 0)) if parts[1] == "X" 					else int(parts[1])
		# Eviscerate: X is the printed part PLUS the Combo cards its additional
		# cost already exiled — a count captured on the link at announcement.
		total += StackResolver.damage_per_cost_removed(src_def) \
				* int(p.params.get("_gy_cost_removed", 0))
	return total


# ── Holy Shield (azeroth_70) ─────────────────────────────────────────────────
# "Prevent the next 5 damage that would be dealt to your hero BY target hero or
# ally this turn. When damage is prevented this way, your hero deals that amount
# of holy damage to that character."
#
# Read the target carefully: it is the character WARDED AGAINST, not the one
# shielded — the shield always sits on our own hero. So this can never save an
# ally, and the whole question is which incoming damage source is worth 2
# resources and a card.
#
# Two independent bars, either of which fires it:
#   (1) it prevents at least HOLY_SHIELD_MIN_PREVENT of the incoming damage —
#       "full value" on a 5-point shield; and
#   (2) the REFLECT kills the character it wards against. That is the half a
#       plain shield doesn't have: prevention and removal in one card, worth
#       taking even for a small block.
#
# Held (never blind-played) and fired from the combat windows or in response to
# a damage link on the chain — priority is LIFO, so a shield announced in
# response is standing when the damage lands.
const HOLY_SHIELD_MIN_PREVENT := 3


func holy_shield_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	var hero_id := ps.hero_instance_id
	var hero := state.get_card(hero_id)
	if not hero or not state.is_in_play(hero_id):
		return null

	var threats := _hero_damage_sources(state, db, player_id)
	if threats.is_empty():
		return null

	for card in state.cards_in_zone(player_id + "_hand"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var shield := 0
		for entry in def.effects.split("|"):
			var parts := entry.strip_edges().split(":")
			if parts[0].strip_edges() == "prevent_hero_damage_from_target" \
					and parts.size() > 1:
				shield = int(parts[1])
		if shield <= 0:
			continue

		# Already-banked shield against the same source is netted out — a second
		# copy on a threat the first one fully covers buys nothing.
		var best := ""
		var best_kills := false
		var best_prevented := 0
		for src: String in threats:
			var incoming: int = int(threats[src]) - GameLogic.granted_shield(hero, src)
			if incoming <= 0:
				continue
			var prevented: int = min(shield, incoming)
			var kills: bool = prevented >= state.get_current_hp(src, db)
			if not kills and prevented < HOLY_SHIELD_MIN_PREVENT:
				continue
			# A kill outranks a bigger block: it removes the card, not one swing.
			if best == "" or (kills and not best_kills) \
					or (kills == best_kills and prevented > best_prevented):
				best = src
				best_kills = kills
				best_prevented = prevented
		if best == "":
			continue
		var act := PendingAction.make(_action_type_for(card, db), player_id,
			{"card_id": card.instance_id, "target_id": best})
		if StackResolver.can_submit(state, act, db):
			return act
		return null
	return null


# Which CHARACTERS are about to deal damage to player_id's hero, and how much
# each. The per-source split _forecast_damage_to deliberately doesn't keep —
# Soul Link only needs the total, while Holy Shield wards against exactly one
# character and must know which. Unpreventable sources are dropped: a shield is
# not consumed by them (717), so warding against one buys nothing.
func _hero_damage_sources(state: GameState, db, player_id: String) -> Dictionary:
	var out := {}
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return out
	var hero_id := ps.hero_instance_id

	# (1) Combat — an open window, or a proposal of theirs still on the chain.
	var attacker_id := ""
	var defender_id := ""
	if state.combat_attack_window or state.combat_defend_window:
		attacker_id = state.combat_attacker
		defender_id = state.combat_defender
	else:
		for pending in state.pending_actions:
			var p := pending as PendingAction
			if p and p.action_type == "propose_combat" and p.source_player != player_id:
				attacker_id = p.params.get("attacker_id", "")
				defender_id = p.params.get("defender_id", "")
				break
	if state.is_in_play(attacker_id) and state.is_in_play(defender_id):
		if defender_id == hero_id:
			if not GameLogic.is_damage_unpreventable(state, db, attacker_id, true):
				var a: int = max(forecast_atk(state, db, attacker_id, true), 0)
				if a > 0:
					out[attacker_id] = int(out.get(attacker_id, 0)) + a
		elif attacker_id == hero_id \
				and not StackResolver._has_keyword(
					state.get_card(hero_id), "long_range", db, state):
			# Our own hero swinging: the defender's retaliation comes back at it,
			# and warding against the defender turns that into a reflect.
			if not GameLogic.is_damage_unpreventable(state, db, defender_id, true):
				var d: int = max(state.get_atk(defender_id, db), 0)
				if d > 0:
					out[defender_id] = int(out.get(defender_id, 0)) + d

	# (2) An opposing damage link on the chain aimed at our hero. The character
	# that will DEAL it is what we ward against — the opponent's hero for an
	# ability ("YOUR HERO deals..."), the ally itself for an ally power.
	for pending in state.pending_actions:
		var p2 := pending as PendingAction
		if not p2 or p2.source_player == player_id:
			continue
		var src: String = p2.params.get("card_id", p2.params.get("hero_id", ""))
		var src_card := state.get_card(src)
		var src_def := db.get_def(src_card.card_def_id) as CardDef if src_card else null
		if not src_def:
			continue
		var aimed := false
		for slot in ["target_id", "target_id_2", "target_id_3"]:
			if p2.params.get(slot, "") == hero_id:
				aimed = true
		if not aimed:
			continue
		if GameLogic.is_damage_unpreventable(state, db, src, false):
			continue
		if StackResolver._has_effect_flag(src_def, "damage_unpreventable"):
			continue
		var amount := 0
		for seg in src_def.effects.split("|"):
			var sp := seg.split(":")
			if sp[0] in ["deal_damage_to_target", "multi_shot",
					"deal_damage_and_heal", "deal_damage_weapon_atk"] and sp.size() > 1:
				amount += int(p2.params.get("x_value", 0)) if sp[1] == "X" \
					else int(sp[1])
		# Eviscerate: plus what its additional cost already exiled (see above).
		amount += StackResolver.damage_per_cost_removed(src_def) \
				* int(p2.params.get("_gy_cost_removed", 0))
		if amount <= 0:
			continue
		# An ally POWER is dealt by the ally; an ability is dealt by their hero.
		var dealer := src
		if p2.action_type != "use_ally_power":
			var opp_ps := state.players.get(_other_player_id(state, player_id)) as PlayerState
			dealer = opp_ps.hero_instance_id if opp_ps else ""
		if dealer == "" or not state.is_in_play(dealer):
			continue
		out[dealer] = int(out.get(dealer, 0)) + amount
	return out


# ── Graccus (azeroth_4) — the one-shot counted shield ────────────────────────
# "(3), Flip Graccus -> Prevent the next 3 damage that would be dealt to target
# hero or ally this turn."
#
# Soul Link's counted shield pointed at a TARGET, but with the opposite economy:
# Soul Link is free and repeatable, so it is bought a point at a time, while the
# hero flip is once per GAME. So this is held (never blind-flipped on our own
# turn — see the gate in _get_hero_power_actions) and fired only on damage
# already on its way, at whichever of two things it can actually save.
#
# (a) THE HERO — the character whose loss ends the game, so the bar is low: any
#     incoming damage that is lethal, or that would drop us to the free-block
#     floor. A 1-damage poke at a full-health hero is not worth the game's only
#     flip.
#
# (b) AN ALLY — and here the point is deliberately NOT to be frugal. The shield
#     is worth spending to save a body worth more than the power costs, even
#     when only 1 of the 3 points is used: the value is the ally, not the
#     damage. The two real conditions are that the ally would otherwise DIE and
#     that the shield actually SAVES it (3 points against a 6-damage swing at a
#     2-health ally buys nothing), plus a printed-cost floor of the power's own
#     cost, the _destroy_is_worth_it convention.
#
# Works from the attack window, the defend window, or in response to a link
# still on the chain — the grant lasts the turn, so any of those is early enough
# to cover the conclusion, and priority is LIFO so a shield announced in
# response resolves before the damage.
func graccus_shield_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.has_used_hero_power or ps.hero_instance_id == "":
		return null
	var hero_id := ps.hero_instance_id
	var hero := state.get_card(hero_id)
	if not hero or not state.is_in_play(hero_id):
		return null
	var hero_def := db.get_def(hero.card_def_id) as CardDef
	if not hero_def:
		return null
	var shield := 0
	for entry in hero_def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "prevent_next_damage_target":
			shield = int(parts[1]) if parts.size() > 1 else 1
	if shield <= 0:
		return null

	var target := ""

	# (a) The hero itself — lethal, or a hit that takes us to the floor.
	var need := _forecast_damage_to(state, db, player_id, hero_id)
	need -= GameLogic.granted_shield(hero)
	if need > 0:
		var hero_hp := state.get_current_hp(hero_id, db)
		if need >= hero_hp or hero_hp - need <= FREE_BLOCK_HERO_FLOOR:
			target = hero_id

	# (b) Otherwise the most expensive ally of ours the shield would actually
	#     save. No frugality about unused points — the body is the payoff.
	if target == "":
		var best_cost: int = max(hero_def.cost, 0)
		for ally in state.cards_in_zone(player_id + "_ally_row"):
			var aid: String = ally.instance_id
			var incoming := _forecast_damage_to(state, db, player_id, aid)
			if incoming <= 0:
				continue
			var hp := state.get_current_hp(aid, db) + GameLogic.granted_shield(ally)
			if incoming < hp:
				continue          # survives on its own — nothing to save
			if incoming - shield >= hp:
				continue          # the shield is not enough — it dies anyway
			var ally_def := db.get_def(ally.card_def_id) as CardDef
			if not ally_def or ally_def.cost <= best_cost:
				continue          # not worth the game's only flip
			best_cost = ally_def.cost
			target = aid
	if target == "":
		return null

	var act := PendingAction.make("activate_power", player_id,
		{"hero_id": hero_id, "target_id": target})
	if StackResolver.can_submit(state, act, db):
		return act
	return null


# ── Korthas Greybeard (dark_portal_174) — the small repeatable shield ───────
# "[Activate] -> Prevent the next 1 damage that would be dealt to target hero or
# ally this turn."
#
# Graccus' counted shield on a body, with the opposite economy: his flip is once
# per GAME for 3 points, so it is spent generously; hers is 1 point every time
# she readies, so the bar is that the point must actually CHANGE AN OUTCOME. A
# single prevented damage almost never does — so unlike Graccus there is no
# "drops us to the free-block floor" arm, and no unused-points generosity for a
# body: both arms require the shield to be exactly the difference between dying
# and surviving.
#
# The tap also costs us her Protector block for the turn (602.2), which is the
# real competing use of the card; that trade is deliberately not modelled — the
# protector decision happens later, at its own point, and by then the shield is
# already standing on whoever needed it.
#
# Held out of _get_ally_power_actions entirely, and fired from any window: the
# grant lasts the turn, and priority is LIFO, so a shield announced in response
# to a damage link is standing when it resolves.
func korthas_shield_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var best_action: PendingAction = null
	var best_score := -1
	for card in state.cards_in_zone(player_id + "_ally_row"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var ap := StackResolver._ally_activated_power(def)
		if ap.get("effect", "") != "prevent_next_damage_target":
			continue
		var shield: int = int(ap.get("amount", 1))
		if shield <= 0:
			continue
		# Our own hero first (its loss ends the game), then our allies, most
		# valuable first — but every candidate must clear the same bar.
		var pool: Array[String] = []
		var ps := state.players.get(player_id) as PlayerState
		if ps and ps.hero_instance_id != "":
			pool.append(ps.hero_instance_id)
		for ally in state.cards_in_zone(player_id + "_ally_row"):
			pool.append(ally.instance_id)
		for tid in pool:
			if not state.is_in_play(tid):
				continue
			var target := state.get_card(tid)
			if not target:
				continue
			var incoming := _forecast_damage_to(state, db, player_id, tid)
			if incoming <= 0:
				continue
			var hp := state.get_current_hp(tid, db) + GameLogic.granted_shield(target)
			if incoming < hp:
				continue                      # survives on its own
			if incoming - shield >= hp:
				continue                      # dies anyway — the point buys nothing
			# The hero outranks every body; among allies, the dearest.
			var score := 9999
			if tid != (ps.hero_instance_id if ps else ""):
				var t_def := db.get_def(target.card_def_id) as CardDef
				score = t_def.cost if t_def else 0
			if score <= best_score:
				continue
			var act := PendingAction.make("use_ally_power", player_id,
				{"card_id": card.instance_id, "target_id": tid})
			if StackResolver.can_submit(state, act, db):
				best_score = score
				best_action = act
	return best_action


# ── Helwen (azeroth_126) — the optional ready ────────────────────────────────
# "You may choose not to ready Helwen during your ready step."
#
# Readying her ENDS the control link she is holding ("while Helwen remains
# exhausted"), so the question is only ever "is the stolen ally worth more than
# having her back?" — and while she holds anything the answer is yes: an ally we
# took is a body they don't have AND one we do, whereas a readied Helwen is a
# 2/2. So: stay exhausted while holding something, ready otherwise (a Helwen
# exhausted for any other reason — she attacked, she protected — should come
# back). Overridable.
func choose_ready_card(state: GameState, db, player_id: String,
		card_id: String) -> bool:
	var card := state.get_card(card_id)
	if not card:
		return true   # ready it — nothing to protect
	return card.stolen_ids.is_empty()


func must_attack_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var opp := _other_player_id(state, player_id)
	# Opponent's turn only, and only while nothing is mid-combat — a lock applied
	# during their combat window can no longer force anything this turn.
	if state.turn_player != opp:
		return null
	if state.combat_attack_window or state.combat_defend_window or state.in_protect_point:
		return null

	var best_action: PendingAction = null
	var best_value := -1
	for lynda in state.cards_in_zone(player_id + "_ally_row"):
		var def := db.get_def(lynda.card_def_id) as CardDef
		if not def:
			continue
		var ap := StackResolver._ally_activated_power(def)
		if ap.get("effect", "") != "must_attack_target":
			continue
		for foe in state.cards_in_zone(opp + "_ally_row"):
			var foe_id: String = foe.instance_id
			# 600.2 "if able": a body that can't attack anyway takes no lock.
			if foe_id not in productive_attackers(state, opp, db):
				continue
			var defenders := StackResolver.get_legal_defenders(state, foe_id, db)
			if defenders.is_empty():
				continue
			if not _forced_attack_hurts_them(state, db, player_id, foe_id, defenders):
				continue
			var value := card_value_score(state, db, foe_id)
			if value <= best_value:
				continue
			var act := PendingAction.make("use_ally_power", player_id,
				{"card_id": lynda.instance_id, "target_id": foe_id})
			if StackResolver.can_submit(state, act, db):
				best_value = value
				best_action = act
	return best_action


# True when the attack we'd force on `foe_id` is one we can answer: the best
# defender it could legally be pointed at survives the hit, or trades up. We can
# only reason about what THEY would pick, so take the worst case for us — the
# defender of ours that fares worst is the one they'd choose.
func _forced_attack_hurts_them(state: GameState, db, player_id: String,
		foe_id: String, defenders: Array[String]) -> bool:
	var atk := forecast_atk(state, db, foe_id, true)
	var foe_hp := state.get_current_hp(foe_id, db)
	var ps := state.players.get(player_id) as PlayerState
	for did in defenders:
		var d := state.get_card(did)
		if not d or d.controller != player_id:
			continue
		# Our hero eating a big hit is not a win for us.
		if ps and did == ps.hero_instance_id:
			if atk >= state.get_current_hp(did, db) or atk >= 4:
				return false
			continue
		# A defending ally of ours dying without killing the attacker is a loss.
		var kills_ours := atk >= state.get_current_hp(did, db)
		var kills_theirs := state.get_atk(did, db) >= foe_hp \
			and not StackResolver._has_keyword(state.get_card(foe_id), "long_range", db, state)
		if kills_ours and not kills_theirs:
			return false
	return true


# Rule 600.2, the receiving end: one of OUR characters must attack if able, so
# the engine refuses our sorcery-speed pass until it has. Returns the combat
# proposal that satisfies the lock, or null when nothing is locked.
#
# Called last in every decide_action, so it only ever fires once the AI has
# decided it wants to end the turn — it never pre-empts a line the AI would
# rather take, including attacking with that same character voluntarily.
#
# Target choice: the modifier says nothing about WHAT to attack (Lynda's whole
# distinction from Mocking Blow — see get_must_attack_ids), and the pool is
# already narrowed by any `can_attack_only` restriction, so pick the least bad
# defender by the usual combat math: a kill we survive, else a trade, else the
# opposing hero, else whatever is left (the attack is compulsory — there may be
# no good answer, and refusing is not an option).
func forced_attack_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or not StackResolver.must_attack_blocks_pass(state, player_id, db):
		return null
	for attacker_id in StackResolver.get_must_attack_ids(state, player_id, db):
		var act := _least_bad_attack(state, db, player_id, attacker_id)
		if act != null:
			return act
	return null


# Outrider Zarg (`end_of_turn_destroy_if_no_damage_dealt`): he destroys himself at
# the end of our turn unless he dealt damage, so an idle Zarg is a dead Zarg —
# swinging costs us nothing we were not about to lose anyway. Nothing in the RULES
# forces the attack (unlike rule 600.2 above); this is purely the AI refusing to
# throw the card away.
#
# Called last in every decide_action, immediately before forced_attack_action, so
# every voluntary line — lethal, safe kills, trades, developing, chip — has already
# had its say and may well have attacked with him for better reasons. What is left
# here is the case where the AI was about to end the turn with him still ready.
#
# Only fires on our own turn (the end-of-turn check is turn-player scoped, so an
# attack made on the opponent's turn would not save him) and only while he has
# in fact dealt no damage yet this turn. Target choice is forced_attack_action's:
# a kill we survive, else a trade, else their hero, else whatever is legal — the
# alternative is losing him for free, so even a bad attack beats no attack.
func use_it_or_lose_it_attack_action(state: GameState, db,
		player_id: String) -> PendingAction:
	if not db or state.turn_player != player_id:
		return null
	for attacker_id in productive_attackers(state, player_id, db):
		var card := state.get_card(attacker_id)
		if not card:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not StackResolver._has_effect_flag(
				def, "end_of_turn_destroy_if_no_damage_dealt"):
			continue
		var dealt := false
		for log_entry in state.turn_events_of("damage_dealt"):
			if String(log_entry.get("source_id", "")) == attacker_id:
				dealt = true
				break
		if dealt:
			continue   # already earned his keep this turn
		var act := _least_bad_attack(state, db, player_id, attacker_id)
		if act != null:
			return act
	return null


# The best available attack for a character that is going to attack no matter what
# (rule 600.2's compulsion, or Outrider Zarg's use-it-or-lose-it clause). Ranking:
# 3 = kill it and live, 2 = trade, 1 = their hero, 0 = anything else. Returns null
# when no legal, submittable proposal exists.
func _least_bad_attack(state: GameState, db, player_id: String,
		attacker_id: String) -> PendingAction:
	var best := ""
	var best_rank := -1
	var opp := _other_player_id(state, player_id)
	var opp_ps := state.players.get(opp) as PlayerState
	for did in StackResolver.get_legal_defenders(state, attacker_id, db):
		var rank := 0
		if opp_ps and did == opp_ps.hero_instance_id:
			rank = 1
		else:
			var kills_theirs := forecast_atk(state, db, attacker_id, true) \
				>= state.get_current_hp(did, db)
			var kills_ours := state.get_atk(did, db) \
					>= state.get_current_hp(attacker_id, db) \
				and not StackResolver._has_keyword(
					state.get_card(attacker_id), "long_range", db, state)
			if kills_theirs:
				rank = 3 if not kills_ours else 2
		if rank > best_rank:
			best_rank = rank
			best = did
	if best == "":
		return null
	var act := PendingAction.make("propose_combat", player_id,
		{"attacker_id": attacker_id, "defender_id": best})
	return act if StackResolver.can_submit(state, act, db) else null


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
func _chain_threatened_ally(state: GameState, db, player_id: String,
		damage_only: bool = false) -> String:
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
				lethal = lethal or not damage_only
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
					# Skipped for damage_only callers (Bestial Wrath): a
					# prevention shield stops damage, not destruction.
					lethal = lethal or (not damage_only \
							and (parts.size() < 2 or parts[1] == "ally" \
								or (parts[1] == "protecting_ally" \
									and target_id == state.combat_protector)))
				"deal_damage_to_target":
					var amt := int(parts[1]) if parts.size() > 1 else 0
					lethal = lethal or amt >= v_hp
	return target_id if lethal else ""


# The ally a sacrifice_ally power should eat: our least valuable body, never the
# source itself (Gertha and Besh'iah are both repeatable engines — spending the
# engine to fire it once is a downgrade). Returns [instance_id, value]; the id is
# "" when we control nothing else. Random tiebreak on equal value.
func _cheapest_sacrifice_ally(state: GameState, db, player_id: String,
		source_id: String) -> Array:
	var sac_id := ""
	var sac_val := INF
	for own in state.cards_in_zone(player_id + "_ally_row"):
		if own.instance_id == source_id:
			continue
		var v := card_value_score(state, db, own.instance_id)
		if v < sac_val or (v == sac_val and randi() % 2 == 0):
			sac_val = v
			sac_id = own.instance_id
	return [sac_id, sac_val]


# Kavai the Wanderer (destroy_ability_or_equipment + sacrifice_self) and Moira
# Darkheart (destroy_equipment + sacrifice_self): the power
# destroys the SOURCE as a cost, so it is never fired proactively —
# _get_ally_power_actions doesn't generate it. Instead, when she is DOOMED —
# targeted by a lethal opposing removal/damage link on the chain, or about to
# die when the open combat window concludes — cash her in on the opponent's
# most expensive in-play ability or equipment, so her death isn't wasted (and
# an opposing removal spell aimed at her fizzles at its 709.2a recheck).
# The X an ability/equipment-destroy power must announce for a given target.
# 0 for every fixed-cost power ("Chipper" Ironbane is the only X one so far),
# where the resolver ignores x_value entirely.
func _power_x_for(db, state: GameState, ap: Dictionary, target_id: String) -> int:
	if not bool(ap.get("cost_x", false)):
		return 0
	var t := state.get_card(target_id)
	var t_def := db.get_def(t.card_def_id) as CardDef if t else null
	return StackResolver.printed_cost(t_def) if t_def else 0


# The opponent's most valuable in-play ability/equipment this power can destroy,
# "" if none qualifies. Printed cost is the value proxy (as everywhere else in
# the AI) and, for an X-cost power, it is ALSO the price — which is exactly the
# heuristic "Chipper" Ironbane needs: see the target first, then pay for it,
# rather than picking an X and hunting for something that matches. Unaffordable
# targets are dropped here rather than left for can_submit to reject, so a rich
# target we can't pay for doesn't hide a cheaper one we can.
# `min_cost` filters out targets not worth the source's life (0 = no floor).
func _best_power_destroy_target(state: GameState, db, player_id: String,
		ap: Dictionary, kinds: Array, min_cost: int) -> String:
	var opp := "p2" if player_id == "p1" else "p1"
	var avail := state.get_available_resources(player_id)
	var best := ""
	var best_cost := min_cost - 1
	for kind in kinds:
		for cid in StackResolver.get_destroy_kind_candidates(state, db, kind):
			var t := state.get_card(cid)
			if not t or t.controller != opp:
				continue
			var t_def := db.get_def(t.card_def_id) as CardDef
			var t_cost: int = StackResolver.printed_cost(t_def) if t_def else 0
			if t_cost <= best_cost:
				continue
			if StackResolver.power_resource_cost(ap, _power_x_for(db, state, ap, cid)) > avail:
				continue
			best_cost = t_cost
			best = cid
	return best


func doomed_sacrifice_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db:
		return null
	var threatened := _chain_threatened_ally(state, db, player_id)
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
		if sac_kinds.is_empty() or not StackResolver.power_has_extra_cost(
				ap.get("extra_cost", ""), "sacrifice_self"):
			continue
		if not _is_doomed(state, db, card.instance_id, threatened):
			continue
		# Meaningful target only: the opponent's most expensive candidate.
		var best := _best_power_destroy_target(state, db, player_id, ap, sac_kinds, 0)
		if best == "":
			continue
		var act := PendingAction.make("use_ally_power", player_id,
			{"card_id": card.instance_id, "target_id": best,
				"x_value": _power_x_for(db, state, ap, best)})
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
			if def and StackResolver.is_cleave_def(def):
				# Cleave: up to 2 enemy ALLY targets (no hero fallback — the
				# card can't target one), each taking the same weapon-derived
				# amount. AI always targets opponents only.
				var cv_action := _cleave_action(state, db, player_id, card.instance_id, action_type)
				if cv_action:
					result.append(cv_action)
				continue
			if def and StackResolver.is_destroy_targets_per_cost_def(def):
				# Expose Armor: the additional cost IS the number of targets, so
				# the decision is HOW MUCH armor is worth breaking - and unlike
				# Eviscerate, over-paying is illegal rather than merely wasteful.
				# See _expose_armor_action().
				var ea_action := _expose_armor_action(state, db, player_id,
					card.instance_id, action_type)
				if ea_action:
					result.append(ea_action)
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
			if def and StackResolver.is_multi_modal_def(def):
				# Totemic Call: "choose one or more", each mode gated on a
				# totem. See _multi_modal_action().
				var mm_action := _multi_modal_action(state, db, player_id,
					card.instance_id, action_type)
				if mm_action:
					result.append(mm_action)
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
			if def and StackResolver.get_graveyard_search_requirement(def).get("dest", "")\
					in ["play", "hand"]:
				# Ancestral Spirit: reanimate the best affordable ally in our
				# own graveyard. Call the Spirit (dest "hand") fetches one back
				# to hand instead — same announce, same "best body" pick.
				# Cold Snap fetches SEVERAL ("up to X"), which is a different
				# decision (how many to buy, not which one), so it has its own.
				var gy_req0 := StackResolver.get_graveyard_search_requirement(def)
				var rz_act: PendingAction = null
				if gy_req0.get("source", "graveyard") == "deck":
					# Premeditation searches the DECK, not a graveyard — no X to buy
					# and no distinct-name constraint, so neither hook below fits.
					rz_act = _deck_search_action(state, db, player_id,
							card.instance_id, action_type)
				elif StackResolver.graveyard_pick_is_multi(gy_req0):
					rz_act = _graveyard_multi_fetch_action(state, db, player_id,
							card.instance_id, action_type)
				else:
					rz_act = _reanimate_action(state, db, player_id,
							card.instance_id, action_type)
				if rz_act:
					result.append(rz_act)
				continue
			if def and StackResolver.get_graveyard_search_requirement(def).get("dest", "") == "rfg":
				# Cannibalize: exile ally cards out of the graveyards for the heal.
				var gx_act := _graveyard_exile_action(state, db, player_id, card.instance_id, action_type)
				if gx_act:
					result.append(gx_act)
				continue
			if def and StackResolver._has_effect_flag_prefix(def, "enters_with_counters"):
				# Blood Fury: the card does nothing on its own — its whole value is
				# the X counters it enters play with, and X is also the price. So the
				# AI buys the largest X it can afford right now and holds the card
				# entirely below X = 2: at X = 1 it is a 5-resource ability granting
				# +1 ATK on hero attacks, which is not worth a card.
				var bf_act := _counter_x_action(state, db, player_id, card.instance_id,
					action_type, 2)
				if bf_act:
					result.append(bf_act)
				continue
			if def and StackResolver._has_effect_flag_prefix(def, "next_card_cost_mod"):
				# Nature's Swiftness: only play it when the discount can be spent
				# on a big card in hand this turn — otherwise it's a dead 3 drop.
				if not _next_card_discount_worth_playing(state, db, player_id,
						card.instance_id, def):
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
			if def and StackResolver.play_cost_sacrifices_pet(def):
				# Dark Pact: no target, but the announcement needs a chosen
				# `sacrifice_id` (a Pet in our own party) before it can submit.
				var dp_act := _dark_pact_action(state, db, player_id, card.instance_id, action_type)
				if dp_act:
					result.append(dp_act)
				continue
			# Life Tap: the draw is not free — it is bought with our own hero's
			# health (405.3, so no armor or shield can soften it), and the cost
			# is paid at ANNOUNCEMENT, so a countered link leaves us paying for
			# nothing. Two gates, and the health one is the important half: the
			# cost may be exactly fatal, so an ungated AI would eventually tap
			# itself to death for cards it never gets to play. Require the hero
			# to be comfortably clear of the payment afterwards, and — as for
			# every draw effect — hand room for both cards (503.2a), minus one
			# because playing the spell itself frees a slot.
			if def and StackResolver.play_cost_puts_damage_on_hero(def):
				var lt_ps := state.players.get(player_id) as PlayerState
				var lt_hero: String = lt_ps.hero_instance_id if lt_ps else ""
				if lt_hero == "":
					continue
				var lt_cost := StackResolver.play_cost_hero_damage_amount(def)
				if state.get_current_hp(lt_hero, db) - lt_cost <= FREE_BLOCK_HERO_FLOOR:
					continue
				var lt_draw := _draw_segment_amount(def)
				if lt_draw > 0:
					var lt_max_hand := state.get_max_hand_size(player_id, db)
					if state.cards_in_zone(player_id + "_hand").size() - 1 > lt_max_hand - lt_draw:
						continue
				var lt_action := PendingAction.make(action_type, player_id,
						{"card_id": card.instance_id})
				if StackResolver.can_submit(state, lt_action, db):
					result.append(lt_action)
				continue
			# Prayer of Healing (`heal_party:N`): a non-targeted friendly party
			# sweep, so it falls through to the generic play below and would be
			# cast on an undamaged board every time it is drawn. Same gate as the
			# `heal_party` activated power in _get_ally_power_actions, and the same
			# reasoning as Healing Touch's held-while-nothing-is-damaged branch:
			# only cast it when someone in our own party actually carries damage.
			# Deliberately no "heals at least N total" bar — the card is cheap and
			# the sweep is capped by damage present, so any real repair is fine.
			if def and StackResolver._top_level_heal_party_amount(def) > 0:
				var ph_worth := false
				var ph_hero := state.get_hero(player_id)
				if ph_hero and ph_hero.damage_taken > 0:
					ph_worth = true
				if not ph_worth:
					for ph_ally in state.cards_in_zone(player_id + "_ally_row"):
						if ph_ally.damage_taken > 0:
							ph_worth = true
							break
				if not ph_worth:
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
			# "Destroy this quest to complete it" (Into the Maw of Madness): the
			# quest is a RESOURCE while it sits face-up, so the cost is a card
			# AND a permanent -1 resource. Early on that ramp is worth more than
			# a card, and a full hand would discard the draw at wrap-up (503.2a).
			if db:
				var ds_def := db.get_def(card.card_def_id) as CardDef
				if ds_def and StackResolver.quest_cost_destroys_self(ds_def):
					if state.get_total_resources(player_id) < DESTROY_SELF_QUEST_MIN_RESOURCES:
						continue
					var ds_hand := state.cards_in_zone(player_id + "_hand").size()
					if ds_hand >= state.get_max_hand_size(player_id, db):
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
				# Rule 600.3 (Winter's Grasp): this attack costs RESOURCES to
				# announce. can_submit already filters what we can't afford, but
				# affording it is not the same as it being worth it — the card's
				# whole purpose is to make marginal attacks a bad deal. So a
				# taxed proposal is offered only when the combat actually
				# removes the defender, or when it's face damage the attacker
				# survives; chucking an ally into a wall AND paying for the
				# privilege is exactly what the tax is meant to punish.
				if StackResolver.attack_tax(state, atk_id, def_id, db) > 0:
					var tax_trade := combat_trade_value(state, db, atk_id, def_id)
					var tax_kills := tax_trade in ["safe_lethal", "both"]
					var tax_face := not StackResolver._is_ally(state, def_id) \
						and tax_trade != "suicide"
					if not (tax_kills or tax_face):
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


# Cards drawn by a spell's `draw:N` segments, whatever ELSE it does. Unlike
# _pure_draw_amount this doesn't bail on a second segment — Life Tap's other
# segment is a COST, not a second payoff, so its hand-room gate is the same
# question a pure-draw spell asks.
static func _draw_segment_amount(def: CardDef) -> int:
	if not def:
		return 0
	var total := 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "draw":
			total += int(parts[1]) if parts.size() > 1 else 1
	return total


# Dark Pact: "As an additional cost to play Dark Pact, destroy one of your
# Pets. Draw X cards, where X is the cost of the Pet you destroyed." The draw
# amount IS the announcement, so the AI maximizes it — sacrifice the highest-
# printed-cost Pet in our party — and skips the card entirely with no Pet to
# pay it, or when the draw would just be discarded at wrap-up (503.2a; -1
# because playing the spell itself frees one hand slot).
static func _dark_pact_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var pets := StackResolver.get_play_pet_sacrifice_candidates(state, player_id, db)
	if pets.is_empty():
		return null
	var best_id := ""
	var best_cost := -1
	for pid in pets:
		var pdef := db.get_def(state.get_card(pid).card_def_id) as CardDef
		var pc := StackResolver.printed_cost(pdef)
		if pc > best_cost:
			best_cost = pc
			best_id = pid
	if best_cost <= 0:
		return null
	var max_hand := state.get_max_hand_size(player_id, db)
	if state.cards_in_zone(player_id + "_hand").size() - 1 > max_hand - best_cost:
		return null
	var action := PendingAction.make(action_type, player_id,
		{"card_id": card_id, "sacrifice_id": best_id})
	if not StackResolver.can_submit(state, action, db):
		return null
	return action


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
# Nature's Swiftness ("you pay (5) less to play your next card this turn")
# grants nothing on its own, so the AI plays it only when the discount can
# actually be cashed in THIS turn: some other card in hand must
#   (a) cost at least the discount — anything cheaper wastes part of it, and
#   (b) be affordable once discounted, out of what is left after paying for
#       Nature's Swiftness itself (a 6-cost needs 1 spare resource, and so on).
# X-cost cards are skipped: their printed cost is a floor, not the price.
func _next_card_discount_worth_playing(state: GameState, db, player_id: String,
		card_id: String, def: CardDef) -> bool:
	if not db:
		return false
	var discount := 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "next_card_cost_mod":
			discount = -int(parts[1]) if parts.size() > 1 else 0
	if discount <= 0:
		return false
	var left := state.get_available_resources(player_id) \
		- state.get_play_cost(card_id, db)
	if left < 0:
		return false
	for card in state.cards_in_zone(player_id + "_hand"):
		if card.instance_id == card_id:
			continue
		var c_def := db.get_def(card.card_def_id) as CardDef
		if not c_def or c_def.cost_x or c_def.card_type == "Quest":
			continue
		var cost := state.get_play_cost(card.instance_id, db)
		if cost >= discount and cost - discount <= left:
			return true
	return false


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


# The legal attackers this player could USEFULLY propose right now — the rules
# list minus the ones that would accomplish nothing.
#
# `StackResolver.get_legal_attackers` is deliberately the RULES answer and has
# no ATK gate: by the printed rules a 0-ATK character may be proposed as an
# attacker, and rule 600.2's "must attack if able" binds it (Mocking Blow,
# Lynda Steele). But volunteering such an attack only exhausts the character
# and feeds it to the retaliation, so every AI line that CHOOSES to attack
# filters through here. The one place that must NOT is `_least_bad_attack`,
# which serves the 600.2 compulsion and has to find a proposal even when every
# option is bad.
#
# forecast_atk is used rather than raw ATK so defender-independent "while
# attacking" bonuses (Cat Form, Berserking's counters, Predatory Strikes) and
# an affordable weapon strike all count — those are exactly the cases where a
# printed-0 hero really does hit for something.
static func productive_attackers(state: GameState, player_id: String,
		db) -> Array[String]:
	var result: Array[String] = []
	for aid in StackResolver.get_legal_attackers(state, player_id, db):
		if forecast_atk(state, db, aid, true) > 0:
			result.append(aid)
	return result


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
		atk += _forecast_strike_atk(state, db, card.controller, attacker_id)
	return atk


# The ATK a wielder would ADD by striking, forecast honestly. Rule 406.6 lets a
# Dual Wield hero strike with TWO Melee weapons in one combat, and 303.2b sums
# every struck weapon's ATK into the one combat packet — so forecasting a single
# best weapon under-reads both our own lethals and the opponent's threat.
#
# Two things the naive "best weapon" version got to ignore and this can't:
#   • RESOURCES. get_strikeable_weapons filters each weapon against the CURRENT
#     pool, but strikes are paid one at a time, so a second one is only real if
#     the budget survives the first. Tracked here as a running budget, which is
#     what the engine does for real when it re-opens the strike point.
#   • 406.6 forbids mixing a Melee and a Ranged strike in one combat, so once
#     the first pick is made the rest must match its damage type.
# Greedy by ATK, which is optimal here: the cap is a count, and taking the
# biggest affordable weapon first can only ever be right.
static func _forecast_strike_atk(state: GameState, db, player_id: String,
		wielder_id: String) -> int:
	var offered := StackResolver.get_strikeable_weapons(state, player_id, wielder_id, db)
	if offered.is_empty():
		return 0
	# (atk, cost, type) per candidate, power weapons dropped — the AI never
	# strikes with one, so counting it would forecast damage it won't deal.
	var cands: Array = []
	for wid in offered:
		if _is_power_weapon(state, db, wid):
			continue
		var wcard := state.get_card(wid)
		var wdef := (db.get_def(wcard.card_def_id) as CardDef) if wcard else null
		if not wdef:
			continue
		cands.append({
			"atk":  state.get_atk(wid, db),
			"cost": StackResolver.get_strike_cost(state, player_id, wdef, db),
			"type": wdef.dmg_type.to_lower(),
		})
	cands.sort_custom(func(a, b): return int(a["atk"]) > int(b["atk"]))
	var limits := StackResolver.get_wielding_limits(state, player_id, db)
	var budget := state.get_available_resources(player_id)
	var total := 0
	var taken := 0
	var cap := 1
	var required_type := ""
	for c in cands:
		if required_type != "" and str(c["type"]) != required_type:
			continue
		var cost := int(c["cost"])
		if cost < 0 or cost > budget:
			continue
		if taken >= cap:
			break
		budget -= cost
		total += int(c["atk"])
		taken += 1
		if required_type == "":
			required_type = str(c["type"])
			# Only the Melee cap is raised by anything shipped (Dual Wield);
			# Ranged stays at 1 until a Ranged Dual Wield dial exists.
			cap = int(limits.get("melee_strikes", StackResolver.BASE_MELEE_STRIKES)) \
				if required_type == "melee" else StackResolver.BASE_MELEE_STRIKES
	return total


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
	if productive_attackers(state, attacker.controller, db).is_empty():
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


# Galway Steamwhistle's weapon pick — called by the scene on
# weapon_ready_required when the pending player is an AI. The point of readying
# a weapon is striking with it again, so take the highest-ATK candidate among
# those we can actually afford to strike with once readied (get_strike_cost
# against our resources) — a weapon we can't pay to swing is a wasted ready. A
# `power_weapon` (Rod of the Ogre Magi, Hypnotic Blade) is valued for its
# activated power instead, so its ATK says nothing and it loses every tie.
# The choice is only ever opened with two or more candidates; if none are
# affordable to strike with, fall back to the highest-ATK candidate anyway
# (the hero still readies, which is never wasted).
func choose_weapon_ready(state: GameState, db, player_id: String) -> String:
	var resources := state.get_available_resources(player_id)
	var best := ""
	var best_atk := -1
	var fallback := ""
	var fallback_atk := -1
	for weapon_id in StackResolver.get_weapon_ready_candidates(state, player_id, db):
		var card := state.get_card(weapon_id)
		if not card:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def:
			continue
		var atk := def.printed_atk
		if "power_weapon" in def.effects:
			atk = -1
		if atk > fallback_atk:
			fallback_atk = atk
			fallback = weapon_id
		var strike_cost := StackResolver.get_strike_cost(state, player_id, def, db)
		if strike_cost < 0 or strike_cost > resources:
			continue
		if atk > best_atk:
			best_atk = atk
			best = weapon_id
	return best if best != "" else fallback


# Chops / Voss Treebender: "When [this] attacks, you may exhaust target hero or
# ally." Pick the target to exhaust, or "" to decline. The point of the trigger
# is denying the protect point (602.2 — a protector must exhaust to protect), so
# exhaust the most dangerous READY legal protector on the defending side: prefer
# one whose retaliation would kill our attacker, else the highest-ATK one.
# Exhausting anything else (e.g. the defender) buys nothing — decline instead.
func choose_attack_exhaust(state: GameState, db, player_id: String) -> String:
	var attacker_id := state.combat_attacker
	if attacker_id == "" or not db:
		return ""
	if state.pending_attack_exhaust_kind == "armor":
		return _best_attack_exhaust_armor(state, db, player_id)
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


# Gartok Skullsplitter: "When Gartok Skullsplitter attacks, you may exhaust
# target armor." Exhausting armor spends its damage prevention for the turn
# (717.2c — only READY armor may be exhausted at the prevention point), so the
# only worthwhile target is a ready armor on the DEFENDING side, and the best
# one is the highest DEF (that is exactly what it denies). Exhausted armor is
# already spent and our own armor is ours to keep, so decline otherwise.
func _best_attack_exhaust_armor(state: GameState, db, player_id: String) -> String:
	var opp := "p2" if player_id == "p1" else "p1"
	var legal := StackResolver.get_attack_exhaust_targets(state, db)
	var best := ""
	var best_def := 0
	for cid in legal:
		var card := state.get_card(cid)
		if not card or card.controller != opp or card.is_exhausted:
			continue
		# Effective DEF (Natural Defenses' aura included) — stripping an
		# aura-boosted armor is worth strictly more than its printed value says.
		var dv := StackResolver.get_armor_def(state, cid, db)
		if dv > best_def:
			best     = cid
			best_def = dv
	return best


# Nightbloom: "(1), [Activate] -> You may put a card from your hand into your
# resource row face down and exhausted." Which card to bury, or "" to decline.
#
# The placement is pure ramp — it costs a card, so it is only worth it while the
# hand can spare one. With two or fewer cards left the AI declines: at that point
# the card in hand is likelier to be the play that matters than the resource
# would be. Otherwise it buries the card it would miss least (the AI's own
# discard pick, which is the same question asked the same way).
func choose_hand_resource(state: GameState, db, player_id: String) -> String:
	if not db:
		return ""
	if state.cards_in_zone(player_id + "_hand").size() <= 2:
		return ""
	return choose_discard_card(state, db, player_id)


# Seraph the Exalted: "[Activate] -> Put an ally card from your hand into play if
# its cost is <= the number of resources you have."
#
# The choice is MANDATORY (no "may" printed), so this never declines — the engine
# only opens it when the pool is non-empty, and the scene falls back to the first
# candidate if this somehow returns "". The ally arrives FREE, so the only
# question is which body is worth most on the board: take the highest
# card_value_score, breaking ties on the printed cost (the free ride is worth
# more the dearer the ally, and cheap bodies are the ones we can still hard-cast).
func choose_hand_play(state: GameState, db, player_id: String) -> String:
	if not db:
		return ""
	var best := ""
	var best_score := -INF
	var best_cost := -1
	for cid in StackResolver.get_hand_play_candidates(state, player_id, db):
		var def: CardDef = db.get_def(state.get_card(cid).card_def_id)
		var cost: int = def.cost_base if def.cost_x else def.cost
		var score := card_value_score(state, db, cid)
		if score > best_score or (score == best_score and cost > best_cost):
			best = cid
			best_score = score
			best_cost = cost
	return best


# Boneshanks death trigger: "When [this] is destroyed, destroy target ally."
# The choice is MANDATORY if any ally is in play, so this never declines. Prefer
# the most valuable OPPOSING ally; only if the opponent has none, destroy our own
# least valuable ally (forced — the trigger must resolve). `player_id` is the
# destroyed Boneshanks' controller.
func choose_death_target(state: GameState, db, player_id: String) -> String:
	if not db:
		return ""
	var legal := StackResolver.get_active_death_target_targets(state, db)
	if legal.is_empty():
		return ""
	var opp := "p2" if player_id == "p1" else "p1"
	# Vexra Darkfall's pool is HEROES, not allies: "she deals 1 arcane damage to
	# target hero for each card in its controller's hand." Always the opposing
	# hero — the damage scales with the TARGET's own hand, so pointing it at
	# ourselves is pure self-harm, and the choice is mandatory.
	var death_key := ""
	if not state.pending_death_triggers.is_empty():
		death_key = str((state.pending_death_triggers[0] as Dictionary).get("key", ""))
	if death_key == "deal_damage_hero_per_hand":
		var opp_ps := state.players.get(opp) as PlayerState
		if opp_ps and opp_ps.hero_instance_id in legal:
			return opp_ps.hero_instance_id
		return legal[0]
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


# Operation Recombobulation: "When an opposing non-token ally is destroyed this
# turn, you may put an ally card from your graveyard into your hand." The fetch
# is free — no cost, no card spent — so the only reason to decline is a full
# hand, where the card would be discarded at wrap-up (503.2a) for nothing.
# Otherwise take the most valuable ally card back.
func choose_recombobulation(state: GameState, db, player_id: String) -> String:
	if not db:
		return ""
	var candidates := StackResolver.get_recomb_candidates(state, player_id, db)
	if candidates.is_empty():
		return ""
	var hand := state.zones.get(player_id + "_hand") as Zone
	if hand and hand.card_ids.size() >= state.get_max_hand_size(player_id, db):
		return ""
	return sort_valuable_cards(state, db, candidates)[0]


# Dark Cleric Jocasta: "When [she] enters play, you may put target ally card
# from your graveyard into your hand." The fetch is free, so take the most
# valuable ally card back — the Recombobulation heuristic verbatim, including
# its full-hand decline (a card drawn into a full hand is discarded at wrap-up,
# 503.2a, for nothing). "" declines.
func choose_enter_play_graveyard(state: GameState, db, player_id: String) -> String:
	if not db:
		return ""
	var candidates := StackResolver.get_enter_play_graveyard_targets(state, db, player_id)
	if candidates.is_empty():
		return ""
	var hand := state.zones.get(player_id + "_hand") as Zone
	if hand and hand.card_ids.size() >= state.get_max_hand_size(player_id, db):
		return ""
	return sort_valuable_cards(state, db, candidates)[0]


# Circle of Life: "When an ally is destroyed, its controller may search his deck
# for an ally card with the same name and put it into play exhausted." Always
# take it. Unlike the Recombobulation fetch there is no hand-size reason to
# decline — the card goes straight into PLAY, not into hand — and it costs
# nothing, so replacing a body that just died is free value. Every candidate is
# a copy of the same card by construction (they share a name), so which instance
# is picked cannot matter; take the first.
#
# Deliberately not modelled: thinning your own deck is a real cost in a long
# game, and 413.2 shuffles it. Neither is something this AI reasons about, and
# a body on the board is worth more than either.
func choose_circle_of_life(state: GameState, db, player_id: String,
		card_name: String) -> String:
	if not db:
		return ""
	var candidates := StackResolver.get_circle_candidates(state, player_id, card_name, db)
	if candidates.is_empty():
		return ""
	return candidates[0]


# Herod's Shoulder: "you may search your deck for a CARD_TYPE card and reveal
# it. If you do, shuffle your deck and put that card on top." Always takes it
# — there's no downside (the deck gets shuffled either way, rule 413.2) and
# guaranteeing the next draw is pure upside — picking the highest-cost
# candidate as the value proxy.
func choose_deck_search_to_top(state: GameState, db, player_id: String,
		card_type: String) -> String:
	if not db:
		return ""
	var candidates := StackResolver.get_deck_search_to_top_candidates(state, player_id, card_type, db)
	if candidates.is_empty():
		return ""
	var best := ""
	var best_cost := -1
	for cid in candidates:
		var card := state.get_card(cid)
		var def := db.get_def(card.card_def_id) as CardDef if card else null
		if not def:
			continue
		var c := StackResolver.printed_cost(def)
		if c > best_cost:
			best_cost = c
			best = cid
	return best


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
		"ally_cant_attack_this_turn":
			# The Perfect Stout. A lock is only worth a card when there is
			# something to lock: the opponent must have an ally that could
			# actually attack right now. The grant is "this turn", so on OUR
			# own turn it would expire before they could ever have used it —
			# a card for nothing. That makes the mode worth taking only when
			# the quest is completed on THEIR turn, which is exactly the
			# Lynda Steele timing.
			if state.turn_player == player_id:
				return false
			var lock_opp := _other_player_id(state, player_id)
			for tid in productive_attackers(state, lock_opp, db):
				var lc := state.get_card(tid)
				if lc and lc.zone_id == lock_opp + "_ally_row":
					return true
			return false
		"each_player_destroys_ally":
			# Availability already requires an ally of ours; useful only when the
			# opponent loses one too (never plain self-harm — AI convention).
			var opp := "p2" if player_id == "p1" else "p1"
			return not state.cards_in_zone(opp + "_ally_row").is_empty()
		"opponent_quest_face_down":
			return true   # available implies an opposing quest to deny
		"ready_equipment":
			# A Refugee's Quandary. Availability already requires an exhausted
			# equipment of ours, and readying one is strictly better than the
			# draw only when the readied card can still DO something this turn:
			# a weapon we could strike with again (303.2c allows one weapon per
			# combat, so a ready weapon is a second strike), armor that could
			# still shield at a prevention point (717.2c), or an activated power
			# to fire. Every shipped Equipment is one of those three, so the
			# check is really "is anything of ours exhausted" — but it is
			# written out so an Equipment that is genuinely spent for the turn
			# would fall through to the draw.
			for eid in StackResolver.get_quest_ready_candidates(
					state, player_id, db, "equipment"):
				var ec := state.get_card(eid)
				if not ec:
					continue
				var edef := db.get_def(ec.card_def_id) as CardDef if db else null
				if not edef:
					continue
				if StackResolver.is_weapon_card_def(edef) 						or StackResolver.get_armor_def(state, eid, db) > 0 						or "activated_power" in edef.effects:
					return true
			return false
		"hand_to_deck_draw":
			return _hand_is_dead(state, db, player_id)
		"shuffle_graveyard_pick":
			# Poison Water. Recycling the graveyard is only worth giving up a
			# card for when the deck is about to run out (410.6b — the next
			# required draw off an empty deck loses the game outright).
			return state.cards_in_zone(player_id + "_graveyard").size() > 0 \
				and state.cards_in_zone(player_id + "_deck").size() \
					<= GRAVEYARD_RECYCLE_DECK_FLOOR
	return false


# Poison Water: which graveyard cards to shuffle back. The mode is only ever
# taken to refill a dying deck (see _quest_mode_useful), so the answer is "all
# of them" — judging which cards are worth having back needs a curve/board model
# the AI doesn't have, and every extra card is another turn of not being decked.
# Overridable; a future AI should replace it rather than tune it.
func choose_quest_graveyard_shuffle(state: GameState, _db,
		player_id: String) -> Array:
	return StackResolver.get_quest_shuffle_candidates(state, player_id)


# Stoneform: which of our hero's attachments to destroy. An attachment we
# control ourselves (Arcane Intellect on our own hero) is beneficial, so it
# stays; one an opponent attached (Fireball, Rend, Shadow Word: Pain) is
# working against us, so it goes. Controller, not owner, is what the attach
# resolution actually sets on the card (see _resolve_attach), so this can't
# be judged from the def alone.
func choose_stoneform_destroy(state: GameState, db,
		player_id: String) -> Array:
	var result: Array = []
	for aid in StackResolver.get_stoneform_destroy_candidates(state, player_id, db):
		var card := state.get_card(aid)
		if card and card.controller != player_id:
			result.append(aid)
	return result


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
# ── Dragonkin Menace: ready a spent protector mid-attack ──────────────────────
# "During an opponent's turn, pay (3) to complete this quest. Reward: Ready a
# hero or ally in your party." The completion is legal at any priority in the
# opponent's turn, so the AI has to be told WHEN it is worth 3 resources. The
# heuristic is deliberately narrow: an opposing attack is underway and we hold
# an EXHAUSTED PROTECTOR. Readying it during the attack window puts it back on
# its feet before the protect point (602.2), so it blocks this attack; readying
# it later still buys a block against the opponent's next attack this turn.
#
# This deliberately misses the card's other use — refunding a spent [Activate]
# power for a second use in one round. Whether a second use is worth 3 resources
# is card-specific and hard to judge, while a re-usable protector is almost
# always good, so only the protector case is modeled.
func ready_protector_quest_action(state: GameState, db,
		player_id: String) -> PendingAction:
	if not db or state.turn_player == player_id:
		return null
	if not _opposing_attack_underway(state, player_id):
		return null
	# Something worth readying: an exhausted PROTECTOR ally in our own party.
	var have_protector := false
	for cid in StackResolver.get_quest_ready_candidates(state, player_id):
		var card := state.get_card(cid)
		if card and card.zone_id == player_id + "_ally_row" 				and StackResolver._has_keyword(card, "protector", db, state):
			have_protector = true
			break
	if not have_protector:
		return null
	for quest in state.cards_in_zone(player_id + "_resource_row"):
		if quest.face_down:
			continue
		var def := db.get_def(quest.card_def_id) as CardDef
		if not def or def.card_type != "Quest":
			continue
		if not StackResolver.requires_opponent_turn(def):
			continue
		if not ("ready_party_character" in def.effects):
			continue
		var action := PendingAction.make("use_quest", player_id,
				{"quest_id": quest.instance_id})
		if StackResolver.can_submit(state, action, db):
			return action
	return null


# ── Thangal: ready our hero mid-attack so it can protect again ───────────────
# "(3), Flip Thangal → Ready Thangal. Use only while he's in bear form."
# Dragonkin Menace's heuristic with the choice removed — the readied character
# is always the hero. Bear Form is what makes it worth 3: it grants the hero
# PROTECTOR, so a hero readied during an opposing attack is a blocker for that
# very attack (readying happens before the protect point, 602.2), and the form
# requirement means the protector grant is up by construction.
#
# Like the quest, this deliberately misses the card's other use — readying a
# spent hero to attack a second time on our own turn. That is a tempo call the
# AI has no model for, while an extra block on an incoming attack is almost
# always good.
func thangal_ready_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.turn_player == player_id:
		return null
	if not _opposing_attack_underway(state, player_id):
		return null
	var hero := state.get_hero(player_id)
	if not hero or not hero.is_exhausted:
		return null   # nothing to ready
	var hero_def := db.get_def(hero.card_def_id) as CardDef
	if not hero_def or not StackResolver._power_effect_is(hero_def, "ready_hero"):
		return null   # some other hero's flip — can_submit would happily fire it
	var action := PendingAction.make("activate_power", player_id,
			{"hero_id": hero.instance_id})
	# can_submit carries every gate that matters: the flip being unspent, the 3
	# resources, and the bear-form requirement (which is also the protector
	# grant we are paying for).
	if StackResolver.can_submit(state, action, db):
		return action
	return null


# Warrax's flip: "(1), Flip Warrax -> Warrax has protector this turn." Thangal's
# hook with the grant swapped for the keyword itself — and, unlike Thangal, with
# no form requirement, so the only question is whether a block is wanted.
#
# THE FLIP IS ONCE PER GAME, not once per turn: PlayerState.has_used_hero_power
# is deliberately never reset (see TurnManager._enter_ready), so this is a
# one-shot resource and the grant lasts only the single turn it is spent on.
# That is what makes the gate below strict — an "any attack will do" heuristic
# burns the whole game's flip on the first 2/2 that swings.
#
# Off-turn only, and only while the opponent is actually attacking: the grant is
# "this turn", so on OUR turn it would expire without ever being usable. The
# hero must be READY (protecting exhausts it, 602.2) and must not already have
# protector from another source (Draconian Deflector is in this very deck, and
# paying 1 for a keyword we already have wastes the flip outright).
#
# Then the block must actually be worth a one-shot: the current defender is an
# ALLY of ours that DIES to this attack (602.2b means the hero can never protect
# itself, so an attack already aimed at our hero is not a case), and the hero can
# absorb the hit and stay above FREE_BLOCK_HERO_FLOOR. Trading a chunk of a
# 30-health hero for a doomed ally is the trade the card exists to make; doing it
# for an ally that survives anyway is not.
func warrax_protector_action(state: GameState, db, player_id: String) -> PendingAction:
	if not db or state.turn_player == player_id:
		return null
	if not _opposing_attack_underway(state, player_id):
		return null
	var hero := state.get_hero(player_id)
	if not hero or hero.is_exhausted:
		return null   # a protector must be ready to step in
	var hero_def := db.get_def(hero.card_def_id) as CardDef
	if not hero_def or not StackResolver._power_effect_is(hero_def, "hero_grant_keyword"):
		return null   # some other hero's flip — can_submit would happily fire it
	# Already a protector — the flip would buy nothing, and it is once per GAME.
	# EVERY recipe that grants a hero Protector (Draconian Deflector's and
	# Treesong's `hero_keyword:protector`, bear form's FORM_GRANTS entry, a
	# printed keyword, a timed grant) is read by _has_keyword — which is exactly
	# what get_legal_protectors asks, so this one call cannot disagree with the
	# rule. Draconian Deflector is in Warrax's own deck, so a hero that could
	# already step in is the likely case, not an exotic one.
	if StackResolver._has_keyword(hero, "protector", db, state):
		return null
	# Is there a doomed ally of ours to save, and can the hero take the hit?
	var attacker := state.combat_attacker
	var defender := state.combat_defender
	if attacker == "" or defender == "" or defender == hero.instance_id:
		return null
	# Nothing can protect at all, so the grant would change nothing: Hannah the
	# Unstoppable's aura, or 602.2a while a Stealth attacker is attacking. These
	# are the two blanket gates get_legal_protectors applies before it looks at
	# any individual card, and they are checked separately there too.
	if StackResolver._protect_locked(state, player_id, db):
		return null
	var atk_card := state.get_card(attacker)
	if atk_card and StackResolver._has_keyword(atk_card, "stealth", db, state):
		return null
	var def_card := state.get_card(defender)
	if not def_card or def_card.controller != player_id:
		return null
	if not combat_kills(state, db, attacker, defender, true):
		return null   # the ally survives — save the flip
	var incoming := forecast_atk(state, db, attacker, true)
	if state.get_current_hp(hero.instance_id, db) - incoming <= FREE_BLOCK_HERO_FLOOR:
		return null   # we cannot afford to eat this hit
	var action := PendingAction.make("activate_power", player_id,
			{"hero_id": hero.instance_id})
	# can_submit carries the rest: the flip being unspent and the resource cost.
	if StackResolver.can_submit(state, action, db):
		return action
	return null


# Is the opponent attacking us right now — a combat proposal of theirs still on
# the chain, or an open attack/defend window whose attacker is theirs?
func _opposing_attack_underway(state: GameState, player_id: String) -> bool:
	for pending in state.pending_actions:
		var p := pending as PendingAction
		if p and p.action_type == "propose_combat" and p.source_player != player_id:
			return true
	if state.combat_attack_window or state.combat_defend_window:
		var attacker := state.get_card(state.combat_attacker)
		if attacker and attacker.controller != player_id:
			return true
	return false


func choose_quest_ready_target(state: GameState, db,
		player_id: String) -> String:
	# The kind comes from the open point; the POOL is built from the player_id
	# this hook was handed, which is what its signature promises (and what lets a
	# test ask the question without opening the point at all).
	var kind := state.pending_quest_ready_kind
	if kind == "":
		kind = "character"
	var legal := StackResolver.get_quest_ready_candidates(state, player_id, db, kind)
	if legal.is_empty():
		return ""
	# A Refugee's Quandary's equipment pool. Nothing here is a character, so the
	# protector reasoning below does not apply: rank by ATK, which puts the
	# weapon we would most want to strike with again first (303.2c makes a ready
	# weapon a second strike), and falls through to the dearest card when nothing
	# in the pool has ATK — armor, whose value is its DEF at the prevention
	# point, and Items. A power_weapon (Rod of the Ogre Magi) loses every ATK tie
	# for the same reason choose_weapon_ready drops it: its ATK says nothing
	# about its worth.
	if kind == "equipment":
		var best := ""
		var best_atk := -1
		for eid in legal:
			var edef := db.get_def(state.get_card(eid).card_def_id) as CardDef 					if db and state.get_card(eid) else null
			var atk := 0
			if edef and not ("power_weapon" in edef.effects):
				atk = state.get_atk(eid, db)
			if atk > best_atk:
				best_atk = atk
				best = eid
		if best_atk > 0:
			return best
		return sort_valuable_cards(state, db, legal)[0]
	# A spent PROTECTOR is what the quest is for (see ready_protector_quest_action):
	# readying one during the opponent's turn buys another block this combat.
	var protectors: Array[String] = []
	var others: Array[String] = []
	var hero := state.get_hero(player_id)
	var hero_id: String = hero.instance_id if hero else ""
	for cid in legal:
		if cid == hero_id:
			continue   # the hero is the last resort — see below
		var card := state.get_card(cid)
		if card and StackResolver._has_keyword(card, "protector", db, state):
			protectors.append(cid)
		else:
			others.append(cid)
	if not protectors.is_empty():
		return sort_valuable_cards(state, db, protectors)[0]
	if not others.is_empty():
		return sort_valuable_cards(state, db, others)[0]
	return legal[0]


# Which ally receives the pending quest reward's this-turn grant. The two kinds
# want OPPOSITE sides of the board, which is the whole reason the kind rides on
# the pending state:
#   ferocity      — a gift, so it goes on one of OUR summoning-sick attackers
#   cannot_attack — a lock, so it goes on the opponent's best attacker
# Both pools are "any in-play ally either party" (the printed text says just
# "target ally"), so the side is a heuristic choice, not a legality one.
func choose_quest_ally_grant_target(state: GameState, db,
		player_id: String) -> String:
	var legal := StackResolver.get_quest_ally_grant_targets(state, db)
	if legal.is_empty():
		return ""
	if state.pending_quest_ally_grant_kind == "cannot_attack":
		return _best_attack_lock_target(state, db, player_id, legal)
	var best := _best_ferocity_target(state, db, player_id, true)
	if best != "":
		return best
	var own: Array[String] = []
	for tid in legal:
		var card := state.get_card(tid)
		if card and card.controller == player_id:
			own.append(tid)
	if not own.is_empty():
		return sort_valuable_cards(state, db, own)[0]
	return legal[0]


# The Perfect Stout's lock: the opponent's most dangerous ally that could still
# attack this turn. Prefers one that is actually a legal attacker right now —
# locking an exhausted or already-locked body buys nothing — and falls back to
# their most valuable ally, then to anything legal (the grant is mandatory once
# the mode is chosen, so there is always an answer). Never our own ally.
func _best_attack_lock_target(state: GameState, db, player_id: String,
		legal: Array) -> String:
	var opp := _other_player_id(state, player_id)
	var attackers: Array[String] = []
	var theirs: Array[String] = []
	var can_attack := productive_attackers(state, opp, db)
	for tid in legal:
		var card := state.get_card(tid)
		if not card or card.controller != opp:
			continue
		theirs.append(tid)
		if tid in can_attack:
			attackers.append(tid)
	if not attackers.is_empty():
		# Highest forecast ATK — the lock is worth most against the biggest hit.
		var best_id := attackers[0]
		var best_atk := -1
		for tid in attackers:
			var atk := state.get_atk(tid, db, true)
			if atk > best_atk:
				best_atk = atk
				best_id = tid
		return best_id
	if not theirs.is_empty():
		return sort_valuable_cards(state, db, theirs)[0]
	return legal[0]


# Our best summoning-sick ally to un-sick: highest ATK, must be a legal target
# and not already ferocious. "" when none qualifies.
func _best_ferocity_target(state: GameState, db, player_id: String,
		_require_sick: bool) -> String:
	var legal := StackResolver.get_quest_ally_grant_targets(state, db)
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


# We looked at the top card of our deck — return true to MOVE it to the pending
# destination, false to keep it on top (drawing it next).
#
# Track Humanoids (dest "bottom"): a flat 80/20 in favour of keeping, by design.
# Judging this properly means asking whether the card helps the CURRENT board and
# what we'd rather draw instead, which is a plan the AI doesn't have; a fixed
# bias at least makes the ongoing do something and keeps the deck moving.
#
# Gustaf Trueshot (dest "graveyard"): the mill is only ever fired when we hold a
# graveyard-ally payoff (see _has_graveyard_ally_payoff), so the question here is
# narrower and answerable — bin the card only when it is an ALLY card, i.e. the
# kind that payoff can actually fetch back. Anything else is a real card we would
# be throwing away for nothing, so it stays on top.
#
# Gift of the Elven Magi (dest "hand"): free upside — the card is an extra card
# for no cost beyond what the power already charged — so TAKE it whenever the
# rules allow, i.e. whenever it is an ability card. The only reason to decline is
# a full hand, where it would be discarded at wrap-up (503.2a) for nothing.
#
# Overridable — a future AI with a curve/board model should replace all three
# branches outright rather than tune them.
func choose_track_placement(state: GameState, db, player_id: String) -> bool:
	if state.pending_track_look_dest == "hand":
		if not StackResolver.track_look_take_allowed(state, db):
			return false
		var gm_hand := state.zones.get(player_id + "_hand") as Zone
		return gm_hand == null \
				or gm_hand.card_ids.size() < state.get_max_hand_size(player_id, db)
	if state.pending_track_look_dest == "graveyard":
		var def := _card_def(state, db, state.pending_track_look_card_id)
		return def != null and def.is_ally_card()
	return randf() < 0.2


# Do we control (or hold) something that turns a card in our own graveyard back
# into a resource? Gustaf Trueshot's mill is a straight card loss without one, so
# it gates his power.
#
# Read off the card's RECIPE rather than from a list of ids, so any future
# own-graveyard ally recursion qualifies for free: the graveyard-search
# requirement segment covers Medoc Spiritwarden, Call the Spirit and Ancestral
# Spirit, and the two flag effects cover the cards that carry no such segment
# (Circle of Life's deck search, Dark Cleric Jocasta's enter-play fetch).
const GRAVEYARD_ALLY_PAYOFF_FLAGS: Array = [
	"recursion_on_ally_death_same_name", "graveyard_to_hand_ally"]

func _has_graveyard_ally_payoff(state: GameState, db, player_id: String) -> bool:
	if not db:
		return false
	for zone_id in [player_id + "_ally_row", player_id + "_hero_row", player_id + "_hand"]:
		for card in state.cards_in_zone(zone_id):
			var def := db.get_def(card.card_def_id) as CardDef
			if not def or def.effects == "":
				continue
			var flagged := false
			for flag in GRAVEYARD_ALLY_PAYOFF_FLAGS:
				if flag in def.effects:
					flagged = true
					break
			if flagged:
				return true
			# A graveyard search only counts when it actually fetches ALLY cards
			# out of a graveyard and puts them somewhere useful — Cold Snap
			# fetches Abilities and Cannibalize exiles, so neither pays a milled
			# ally back.
			var req := StackResolver.get_graveyard_search_requirement(def)
			if req.is_empty():
				continue
			if String(req.get("card_type", "")) == "Ally" \
					and String(req.get("dest", "")) in ["hand", "play"]:
				return true
	return false


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


# Vestia Abiectus: "you may put an ability you control into its owner's hand."
# Return "" to decline, or the instance id of one of the candidates.
#
# ALWAYS DECLINES, deliberately. The effect is extremely situational — bouncing
# your own in-play ability is right only when you specifically want to REPLAY it
# (Entangling Roots moving to a better host, an attachment about to die with its
# host) and catastrophic otherwise (an 8-cost Circle of Life would have to be
# re-paid in full). Distinguishing those needs a model of what the ability is
# still doing and what you intend next turn, which this AI does not have, so a
# plausible-looking heuristic would mostly throw away its own board.
#
# Overridable — an AI that gains that model should replace this outright rather
# than bolt conditions onto it.
func choose_vestia_return(_state: GameState, _db, _player_id: String) -> String:
	return ""


# Feral Rage: our hero was dealt combat damage in bear form, so we may pay (1)
# to draw a card. ALWAYS pay. The offer only opens on damage we have already
# taken — the resources are otherwise likely to go unspent on the opponent's
# turn, which is when a bear-form druid gets hit — so a card for 1 is a trade
# worth taking every time it is available. The engine has already checked
# affordability, both when queueing the offer and again when opening it.
#
# Deliberately not gated on hand size: drawing into a full hand means discarding
# at wrap-up (503.2a), which would waste the resource. That case is rare enough
# (it needs a full hand AND a bear-form hero being attacked) that the gate would
# cost more games than it saves — but it is the one thing to revisit if the AI
# is ever seen throwing cards away here.
func choose_feral_rage(_state: GameState, _db, _player_id: String) -> bool:
	return true


# The Shatterer: our hero was hit by a struck Shatterer, so we may pay (2) or
# lose one of our weapons — and WHICH one is not our choice, so the question is
# only "is 2 resources worth the best weapon they could take from us".
#
# We pay whenever we control a weapon worth at least the 2, judged on printed
# cost (the pool's own value bar, _destroy_is_worth_it's convention), because
# the striker picks and will take the best. A player holding only a Scarlet Kris
# lets it go. Declining is also correct when we would be spending resources we
# still need — but the offer resolves inside the opponent's combat step, at the
# end of a turn we have usually already spent, so no floor is applied.
func choose_weapon_break_pay(state: GameState, db, player_id: String) -> bool:
	if not db:
		return false
	var cost := state.pending_weapon_break_cost
	if state.get_available_resources(player_id) < cost:
		return false
	var best := 0
	for wid in StackResolver.get_weapon_break_candidates(state, player_id, db):
		var card := state.get_card(str(wid))
		if not card:
			continue
		var wdef := db.get_def(card.card_def_id) as CardDef
		if wdef and wdef.cost > best:
			best = wdef.cost
	return best >= cost


# The Shatterer: they declined to pay, so we pick which of their weapons breaks.
# Mandatory — there is no decline — so this always returns a candidate.
#
# Take the most expensive, the same board-value proxy the reanimate and steal
# heuristics use, with ATK breaking a tie: between two equally-priced weapons the
# one that hits harder is the one we would rather not be swung at with.
func choose_weapon_break(state: GameState, db, _player_id: String) -> String:
	var ids: Array = state.pending_weapon_break_ids
	if ids.is_empty():
		return ""
	var best := ""
	var best_cost := -1
	var best_atk := -1
	for wid in ids:
		var card := state.get_card(str(wid))
		if not card:
			continue
		var c := 0
		var a := 0
		if db:
			var wdef := db.get_def(card.card_def_id) as CardDef
			if wdef:
				c = wdef.cost
			a = state.get_atk(str(wid), db)
		if c > best_cost or (c == best_cost and a > best_atk):
			best = str(wid)
			best_cost = c
			best_atk = a
	return best if best != "" else str(ids[0])


# Wisp: "you may pay (1). If you do, put Wisp into your hand." A 1-cost 0/1 body
# back for 1 resource is a fine rate, and unlike a draw it cannot be wasted on a
# full hand — so the only reasons to decline are the two provable wastes.
#
# (1) HAND ROOM. The card arrives in hand, so with no room it would be discarded
#     at wrap-up (503.2a) and we would have paid for nothing. Declining is free
#     and the offer returns next turn, so waiting costs us only tempo.
# (2) RESOURCES WE STILL NEED. The offer resolves in the READY step, before the
#     action phase, so paying here is spending against the whole turn ahead. We
#     buy the Wisp only out of resources we would otherwise not miss — hence the
#     spare-resource floor rather than mere affordability.
const WISP_MIN_SPARE_RESOURCES := 2


func choose_gy_return(state: GameState, db, player_id: String,
		_card_id: String, cost: int) -> bool:
	var hand := state.zones.get(player_id + "_hand") as Zone
	if hand != null and hand.card_ids.size() >= state.get_max_hand_size(player_id, db):
		return false
	# A FREE return (Masten Everspirit's death trigger) has no downside at all
	# once the hand has room — the spare-resource floor below is Wisp's, and it
	# exists only because paying for the body competes with the turn's plays.
	if cost <= 0:
		return true
	return state.get_available_resources(player_id) - cost >= WISP_MIN_SPARE_RESOURCES


# 708.1a: with two or more of our own triggers waiting, we choose which goes on
# the chain next. The chain is LIFO, so the one picked FIRST resolves LAST.
#
# The ordering only matters when one trigger changes what another can do, and the
# one case in the shipped pool is a KILL: Searing Totem's ping (and Fire Nova
# Totem's burn) can remove a character another trigger wanted, and a heal can
# save one. So the heuristic is simply "do the damage last" — pick damage
# triggers FIRST here, since picking first means resolving last, which lets the
# heals and the payments resolve while the board is still whole.
#
# Overridable, and a future AI should replace it outright rather than tune it:
# judging this properly needs a model of what each trigger will do to a board
# that the other triggers are still going to change.
const _LATE_RESOLVING_TRIGGER_KEYS := [
	"ongoing_damage_each_turn",                 # Searing Totem
	"turn_start_destroy_self_damage_opposing",  # Fire Nova Totem
	"attached_damage_turn_start",               # Fireball, Rend
]


func choose_trigger_order(state: GameState, _db, _player_id: String,
		card_ids: Array) -> String:
	for trigger in state.pending_turn_start_triggers:
		var cid := String(trigger.get("card_id", ""))
		if card_ids.has(cid) \
				and _LATE_RESOLVING_TRIGGER_KEYS.has(String(trigger.get("key", ""))):
			return cid
	return String(card_ids[0]) if not card_ids.is_empty() else ""


# The smallest end-of-turn burn worth an upkeep payment. With Rain of Fire's
# printed 1 damage that means the opponent must hold at least two allies (hero +
# 2 allies = 3), which is roughly where a 4-resource-a-turn tax starts paying for
# itself. Below it the card is bleeding us dry for chip damage and is better let
# go — the alternative heuristic, "always pay", loses games to its own upkeep.
const UPKEEP_MIN_DAMAGE := 3


# Rain of Fire: "At the start of your turn, pay (COST) or destroy [this]."
# Return true to pay and keep the card, false to let it be destroyed.
#
# The decision is entirely about what the card will DO at the end of this turn,
# because that is all we are buying: the burn hits the opposing hero and every
# opposing ally, so its value is read live off their board (`_upkeep_burn_value`)
# rather than off the card's cost.
#
# Three bars, in order:
#  1. LETHAL — the burn kills their hero this turn. Pay whatever it costs; there
#     is no next turn to save the resources for.
#  2. Too small to matter — pay only once the burn totals UPKEEP_MIN_DAMAGE.
#  3. Never tap out for chip damage. The upkeep is charged at the START of our
#     turn, so every resource spent here is one we do not have for the rest of
#     it; we keep at least one back unless the payment is lethal.
#
# The engine has already checked affordability (the point never opens otherwise).
func choose_upkeep(state: GameState, db, player_id: String,
		card_id: String, cost: int) -> bool:
	# Last Stand: "Ongoing: Your hero has +20 health. At the start of your turn,
	# discard two cards or destroy Last Stand." Here the card is not buying an
	# effect at all — it is holding up the hero's max health — so the question is
	# simply what happens the instant we let it go. Read off the def, so a future
	# card with a different bonus is judged on its own number.
	#
	# Checked before the burn branch because it is EXISTENTIAL: dropping the aura
	# can be an immediate state-based loss (see _hero_state_based_death), and no
	# amount of end-of-turn damage outranks not losing the game.
	# Crippling Poison: "exhaust attached character unless its controller pays."
	# Checked FIRST because it is a different question from the two below — this
	# is a tax levied by an OPPOSING card, not the rent on one of ours, so
	# reading the source's def (as both branches below do) answers nothing and
	# would fall through to a blanket decline, making the card free for them.
	#
	# The bar is whether READINESS is actually worth the money right now:
	#   - an already-exhausted host buys nothing (the tax is still legal on one,
	#     so this case really does come up) — decline;
	#   - keep a resource back, the same floor the burn branch below uses, since
	#     the tax is charged in the ready step before the whole action phase;
	#   - our HERO is always worth keeping ready (it attacks, it protects, and an
	#     exhausted hero can't be a protector at 602.2);
	#   - an ally only when the body is worth at least what it costs to keep.
	# Deliberately not modelled: whose turn it is. Readiness is worth having on
	# both — attacking on ours, protecting on theirs — and the difference is a
	# tempo judgement this AI has no model for.
	if state.pending_upkeep_consequence == "exhaust_host":
		var cp_host := state.get_card(state.pending_upkeep_target_id)
		if not cp_host or cp_host.is_exhausted:
			return false
		if state.get_available_resources(player_id) - cost < 1:
			return false
		var cp_ps := state.players.get(player_id) as PlayerState
		if cp_ps and cp_ps.hero_instance_id == cp_host.instance_id:
			return true
		return card_value_score(state, db, cp_host.instance_id) >= float(cost)

	var hero_bonus := _upkeep_hero_health_bonus(state, db, card_id)
	if hero_bonus > 0:
		var up_hero := state.get_hero(player_id)
		if not up_hero:
			return false
		var hp_after := state.get_current_hp(up_hero.instance_id, db) - hero_bonus
		if hp_after <= 0:
			return true    # letting it go LOSES THE GAME — pay whatever it costs
		# Still standing without it, but only just: keep paying while the hero is
		# inside burn range. Once it is comfortably clear, two cards a turn is far
		# too steep a rent for health we are not using.
		return hp_after <= FREE_BLOCK_HERO_FLOOR
	var burn := _upkeep_burn_amount(state, db, card_id)
	if burn <= 0:
		return false   # nothing to buy — the card does nothing at end of turn
	var opp := ""
	for pid in state.players:
		if pid != player_id:
			opp = pid
			break
	if opp == "":
		return false
	var opp_hero := state.get_hero(opp)
	if opp_hero and state.get_current_hp(opp_hero.instance_id, db) <= burn:
		return true    # (1) lethal on their hero — buy it at any price
	var total := burn * (state.cards_in_zone(opp + "_ally_row").size() + (1 if opp_hero else 0))
	if total < UPKEEP_MIN_DAMAGE:
		return false   # (2) not worth the tax yet
	# (3) keep something back to actually play with this turn.
	return state.get_available_resources(player_id) - cost >= 1


# How much the card charging us upkeep will deal to each opposing character at
# the end of this turn, 0 if it has no such power. Read off the def rather than
# assumed, so a future upkeep card with a different burn — or none at all — is
# judged on what it actually does.
func _upkeep_burn_amount(state: GameState, db, card_id: String) -> int:
	if not db:
		return 0
	var card := state.get_card(card_id)
	if not card:
		return 0
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.effects == "":
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() in [
				"end_of_turn_hero_damage_opposing", "end_of_turn_damage_opposing"]:
			return int(parts[1]) if parts.size() > 1 else 1
	return 0


# How much max health the card charging us upkeep is granting our hero, 0 if it
# grants none (Last Stand's `hero_health_bonus:20`). Read off the def for the
# same reason _upkeep_burn_amount is: the AI judges what the card actually does,
# not what we assumed when it was written.
func _upkeep_hero_health_bonus(state: GameState, db, card_id: String) -> int:
	if not db:
		return 0
	var card := state.get_card(card_id)
	if not card:
		return 0
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.effects == "":
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "hero_health_bonus":
			return int(parts[1]) if parts.size() > 1 else 0
	return 0


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
		# The source's own power, or — for a hero with none of its own — one a
		# friendly in-play card grants it (Field Repair Bot 74A).
		var def := StackResolver.power_source_def(state, card.instance_id, db)
		if not def:
			continue
		var ap := StackResolver._ally_activated_power(def)
		if ap.is_empty():
			continue
		var extra_cost_str: String = ap.get("extra_cost", "")
		var once_per_turn: bool = StackResolver.power_has_extra_cost(extra_cost_str, "once_per_turn")
		# put_damage_self / no_activate (e.g. Acolyte Demia, Hierophant Caydiem)
		# have no [Activate] tap symbol — 701.2 payment powers, not gated by
		# summoning sickness or exhaustion. Mirrors StackResolver._can_use_ally_power.
		var no_activate_symbol: bool = StackResolver._power_has_no_activate_symbol(extra_cost_str)
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
			if StackResolver.power_has_extra_cost(extra_cost_str, "activate_put_damage_self"):
				var self_dmg := StackResolver.power_extra_cost_arg(
					extra_cost_str, "activate_put_damage_self", 1)
				if state.get_current_hp(card.instance_id, db) <= self_dmg:
					continue
		# Ilandre Moonspear: only cycle a hand that is actually dead — the swap
		# costs every card we hold, so it must be trading nothing for something.
		if ap.get("effect", "") == "hand_to_deck_draw" \
				and not _hand_is_dead(state, db, player_id):
			continue
		# Nightbloom: the placement costs a card out of hand, so don't tap her
		# (and pay 1) for a choice we would only decline — choose_hand_resource
		# is the single place that judgement lives.
		if ap.get("effect", "") == "put_hand_card_as_resource" \
				and choose_hand_resource(state, db, player_id) == "":
			continue
		# Seraph the Exalted: her tap costs us her attack, and the untargeted
		# else-branch below would fire it every turn regardless. Only tap her
		# when there is actually an ally in hand cheap enough to drop for free.
		if ap.get("effect", "") == "put_hand_ally_into_play" \
				and StackResolver.get_hand_play_candidates(state, player_id, db).is_empty():
			continue
		# Gustaf Trueshot: milling our own deck is a straight card loss unless
		# something can buy the card back, and the untargeted else-branch below
		# would pay 1 for it every turn regardless. Fire it only with an
		# own-graveyard ally payoff out AND a deck that can afford to lose
		# cards — decking is a loss condition (410.6b) and his power is
		# repeatable (no_activate), so an ungated AI would mill itself to death.
		if ap.get("effect", "") == "look_top_card_to_graveyard":
			if not _has_graveyard_ally_payoff(state, db, player_id):
				continue
			if state.cards_in_zone(player_id + "_deck").size() \
					<= GRAVEYARD_RECYCLE_DECK_FLOOR:
				continue
		# Gift of the Elven Magi: the untargeted else-branch below would fire this
		# every turn regardless, so gate it on the two cases where it is a PROVABLE
		# waste - Nightbloom and Seraph's "don't tap for a choice we would only
		# decline" reasoning. An empty deck means there is nothing to look at, and
		# a full hand means choose_track_placement would refuse the card anyway
		# (503.2a). Whether the top card is an ABILITY is deliberately NOT checked:
		# that is private information the AI must not read before paying to look.
		# The hero-exhaust tempo cost is likewise not modelled - the same call left
		# unmade for Rod of the Ogre Magi and The Hammer of Grace.
		if ap.get("effect", "") == "look_top_card_to_hand":
			if state.cards_in_zone(player_id + "_deck").is_empty():
				continue
			var gm_hand := state.zones.get(player_id + "_hand") as Zone
			if gm_hand and gm_hand.card_ids.size() >= state.get_max_hand_size(player_id, db):
				continue
		# Ramstein's Lightning Bolts: the AoE is SYMMETRIC (it hits our own hero
		# and allies too) and destroying the item is the cost, so firing it on a
		# neutral board is a straight card loss. Simple gate for now: only when
		# the opponent has more allies on the board than we do — and never when
		# our own hero would die to it, which would hand them the game.
		if ap.get("effect", "") == "deal_damage_aoe_all":
			var opp_id := _other_player_id(state, player_id)
			if state.cards_in_zone(opp_id + "_ally_row").size() \
					<= state.cards_in_zone(player_id + "_ally_row").size():
				continue
			var own_hero: String = (state.players.get(player_id) as PlayerState).hero_instance_id
			if own_hero != "" \
					and state.get_current_hp(own_hero, db) <= int(ap.get("amount", 0)):
				continue
		# The Immovable Object / The Unstoppable Force: the destroy is symmetric
		# and costs us the card, so firing it with nothing of theirs to break is
		# a straight card loss. Only fire when the OPPONENT actually controls a
		# matching card; our own matching copy going with it is priced in (the
		# pair is mutually exclusive by design, and their copy is the threat).
		if ap.get("effect", "") == "destroy_all_named":
			var dn_spec := StackResolver.destroy_named_spec(def)
			var dn_opp := _other_player_id(state, player_id)
			var dn_hits := StackResolver.get_named_destroy_targets(
				state, db, dn_spec, player_id)
			var dn_worth := false
			for dn_id in dn_hits:
				var dn_card := state.get_card(dn_id)
				if dn_card and dn_card.controller == dn_opp:
					dn_worth = true
					break
			if not dn_worth:
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
		elif ap.get("effect", "") == "destroy_ally" \
				and ap.get("targets", "") == "exhausted_ally":
			# Lhurg Venomblade: "[Activate] -> Destroy target exhausted ally."
			# Coup de Grâce's heuristic on a repeatable power — destroy the MOST
			# valuable exhausted OPPOSING ally. No value floor: the whole price is
			# his tap, and an exhausted ally is a spent attacker, so any kill is a
			# profit. Never our own allies, which are exhausted precisely because
			# they just attacked.
			var opp_x := _other_player_id(state, player_id)
			var best_x := ""
			var best_x_score := -1.0
			for enemy in state.cards_in_zone(opp_x + "_ally_row"):
				if not enemy.is_exhausted:
					continue
				var x_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": enemy.instance_id})
				if not StackResolver.can_submit(state, x_act, db):
					continue
				var x_score := card_value_score(state, db, enemy.instance_id)
				if x_score > best_x_score:
					best_x_score = x_score
					best_x = enemy.instance_id
			if best_x != "":
				result.append(PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_x}))
		elif ap.get("effect", "") == "destroy_ally" 				and ap.get("targets", "") == "undead_ally":
			# Wyneth Harridan: "(3), [Activate] -> Destroy target Undead ally."
			# Lhurg Venomblade's heuristic with the race filter doing the
			# narrowing instead of the exhaust state — destroy the MOST valuable
			# OPPOSING Undead ally, judged by can_submit so the race test is the
			# engine's own. Never our own allies (the printed pool allows it, the
			# AI never wants it), and no value floor beyond the 3 resources: a
			# repeatable hard removal is worth any body it can legally take.
			var opp_u := _other_player_id(state, player_id)
			var best_u := ""
			var best_u_score := -1.0
			for enemy_u in state.cards_in_zone(opp_u + "_ally_row"):
				var u_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": enemy_u.instance_id})
				if not StackResolver.can_submit(state, u_act, db):
					continue
				var u_score := card_value_score(state, db, enemy_u.instance_id)
				if u_score > best_u_score:
					best_u_score = u_score
					best_u = enemy_u.instance_id
			if best_u != "":
				result.append(PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_u}))
		elif ap.get("effect", "") == "heal_party":
			# Lady Courtney Noel: "[Activate] -> heals N damage from each hero and
			# ally in your party." Non-targeted, so the generic else-branch below
			# would tap her every turn for nothing. Only fire when the heal does
			# real work — someone in our party is actually damaged.
			var party_amt: int = int(ap.get("amount", 0))
			var party_worth := false
			if party_amt > 0:
				var party_hero := state.get_hero(player_id)
				if party_hero and party_hero.damage_taken > 0:
					party_worth = true
				if not party_worth:
					for own_ally in state.cards_in_zone(player_id + "_ally_row"):
						if own_ally.damage_taken > 0:
							party_worth = true
							break
			if party_worth:
				var party_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id})
				if StackResolver.can_submit(state, party_act, db):
					result.append(party_act)
		elif ap.get("effect", "") == "buff_atk_self":
			# Warmaster Hork: "(2) -> Warmaster Hork has +1 ATK this turn."
			# Untargeted AND repeatable, so the generic else-branch below would
			# fire it every turn and drain every spare resource for nothing.
			# Pay only when the extra ATK converts a non-kill into a kill.
			var pump: int = int(ap.get("amount", 0))
			var pump_act := PendingAction.make("use_ally_power", player_id,
				{"card_id": card.instance_id})
			if pump > 0 and _pump_converts_a_kill(state, db, player_id,
					card.instance_id, pump) \
					and StackResolver.can_submit(state, pump_act, db):
				result.append(pump_act)
		elif ap.get("effect", "") == "ready_hero_and_weapon":
			# Galway Steamwhistle: "[Activate] -> Ready your hero and one of your
			# weapons." Non-targeted, so the generic else-branch below would tap
			# her every turn for nothing. Tapping her costs us her attack, so
			# only fire when the power actually readies something: our hero is
			# exhausted, or a weapon of ours is (a spent weapon readied is a
			# second strike this turn — the whole point of the card).
			var galway_worth := false
			var galway_hero := state.get_hero(player_id)
			if galway_hero and galway_hero.is_exhausted:
				galway_worth = true
			if not galway_worth and not StackResolver.get_weapon_ready_candidates(
					state, player_id, db).is_empty():
				galway_worth = true
			if galway_worth:
				var galway_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id})
				if StackResolver.can_submit(state, galway_act, db):
					result.append(galway_act)
		elif ap.get("effect", "") == "destroy_ally" \
				and StackResolver.power_has_extra_cost(extra_cost_str, "sacrifice_ally"):
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
			var sac := _cheapest_sacrifice_ally(state, db, player_id, card.instance_id)
			var sac_id: String = sac[0]
			var sac_val: float = sac[1]
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
		elif ap.get("effect", "") == "destroy_ability_or_equipment" \
				and StackResolver.power_has_extra_cost(extra_cost_str, "sacrifice_self") \
				and bool(ap.get("cost_x", false)):
			# "Chipper" Ironbane: "(X), Destroy [this] -> Destroy target ability
			# or equipment with cost X." Kavai's power on a 2-cost 3/1, so unlike
			# Kavai (doomed-only — a 6-cost 4/6 body is worth more than most
			# targets) he is ALSO fired proactively: the body is cheap enough
			# that trading it for a real threat is a fine deal on its own.
			#
			# The heuristic runs target-first, which is what the X demands: pick
			# the best OPPOSING target we can afford, then pay exactly its
			# printed cost. `min_cost` is the source's own printed cost, so he
			# won't spend himself on a 1-cost totem or Form; a cheaper target is
			# still available to doomed_sacrifice_action, which has no floor and
			# fires when he's dying anyway.
			var chip_cost := StackResolver.printed_cost(def)
			var best_dae := _best_power_destroy_target(state, db, player_id, ap,
				["ability", "equipment"], chip_cost)
			if best_dae != "":
				var act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_dae,
						"x_value": _power_x_for(db, state, ap, best_dae)})
				if StackResolver.can_submit(state, act, db):
					result.append(act)
		elif ap.get("effect", "") == "destroy_ability" \
				and not StackResolver.power_has_extra_cost(extra_cost_str, "sacrifice_self"):
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
				var ab_params := {"card_id": card.instance_id, "target_id": best_ab}
				# Besh'iah pays the same destroy with an ALLY instead of a tap:
				# "Destroy an ally in your party -> Destroy target ability." Spend
				# our least valuable body (never Besh'iah herself — she's the
				# engine, and she's repeatable since the power has no tap symbol),
				# and only when the ability is worth at least what we give up.
				if StackResolver.power_sacrifice_is_separate(ap):
					var ab_sac := _cheapest_sacrifice_ally(state, db, player_id, card.instance_id)
					var ab_sac_id: String = ab_sac[0]
					if ab_sac_id == "" or float(best_ab_cost) < float(ab_sac[1]):
						continue
					ab_params["sacrifice_id"] = ab_sac_id
				var act := PendingAction.make("use_ally_power", player_id, ab_params)
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
		elif ap.get("effect", "") in ["graveyard_to_hand_ally", "graveyard_to_hand_equipment"]:
			# Medoc Spiritwarden: "[Activate] -> Put target ally card from your
			# graveyard into your hand." The fetch is free (only her tap), so
			# the heuristic is the reanimate one: the highest-cost ally card
			# back, cost being the board-value proxy. The pool is our OWN
			# graveyard by construction (the paired requirement is owner:own),
			# so unlike Ophelia there is no side to choose.
			#
			# Field Repair Bot 74A grants the hero the identical power over
			# EQUIPMENT cards instead of allies (see power_source_def) — same
			# heuristic, `def` and `card` both already resolve to the hero here.
			#
			# Declined on a full hand — the card would be discarded at wrap-up
			# (503.2a) for nothing, and her tap costs us her attack. She is a
			# 1-ATK body, so that is cheap, but a wasted fetch is not.
			var m_max_hand := state.get_max_hand_size(player_id, db)
			if state.cards_in_zone(player_id + "_hand").size() < m_max_hand:
				var m_req := StackResolver.get_graveyard_search_requirement(def)
				var m_cands := StackResolver.get_graveyard_search_candidates(
					state, player_id, m_req, db)
				var m_best := ""
				var m_best_cost := -1
				for tid in m_cands:
					var m_def := _card_def(state, db, tid)
					var m_cost: int = m_def.cost if m_def else 0
					if m_cost > m_best_cost:
						m_best_cost = m_cost
						m_best = tid
				if m_best != "":
					var m_act := PendingAction.make("use_ally_power", player_id,
						{"card_id": card.instance_id, "target_id": m_best})
					if StackResolver.can_submit(state, m_act, db):
						result.append(m_act)
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
		elif ap.get("effect", "") == "cant_protect_target":
			# Jin'lak Nightfang: "(3) -> Target hero or ally can't protect this
			# turn." Purely an offensive enabler, so it is worth 3 resources
			# only when it clears a body that would otherwise intercept our
			# attack on the opposing hero. Probe the real rule
			# (get_legal_protectors — so Stealth, Hannah's aura and an
			# already-applied restriction all count) with our best ready
			# attacker against the opposing hero, and strip the most dangerous
			# protector. Nothing to attack with, or no legal protector, means
			# the power changes nothing this turn: hold the resources rather
			# than firing it at the enemy hero, which the generic hero_or_ally
			# branch below would happily do.
			var cp_opp := _other_player_id(state, player_id)
			var cp_ps := state.players.get(cp_opp) as PlayerState
			if not cp_ps or cp_ps.hero_instance_id == "":
				continue
			var cp_attackers := productive_attackers(state, player_id, db)
			if cp_attackers.is_empty():
				continue
			var cp_best_attacker: String = cp_attackers[0]
			for aid in cp_attackers:
				if forecast_atk(state, db, aid) > forecast_atk(state, db, cp_best_attacker):
					cp_best_attacker = aid
			var cp_protectors := StackResolver.get_legal_protectors(
				state, cp_best_attacker, cp_ps.hero_instance_id, db)
			var cp_target := ""
			var cp_best := -1
			for pid2 in cp_protectors:
				var pv := forecast_atk(state, db, pid2, false)
				if pv > cp_best:
					cp_best = pv
					cp_target = pid2
			if cp_target != "":
				var cp_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": cp_target})
				if StackResolver.can_submit(state, cp_act, db):
					result.append(cp_act)
		elif ap.get("effect", "") == "deal_damage_to_target" \
			and str(ap.get("amount_raw", "")) != "sac_atk" \
				and StackResolver.power_sacrifice_is_separate(ap):
			# Ritual Sacrifice: "Destroy an ally in your party -> Your hero
			# deals 1 shadow damage to target hero or ally." A FIXED amount,
			# so — unlike Mezzik below — the sacrifice's ATK is irrelevant
			# and the two halves are independent questions:
			#
			#   WHICH ALLY TO EAT: only one that is ABOUT TO DIE anyway. The
			#     power is free and repeatable (no tap symbol, no resource
			#     cost), so this gate is the only thing stopping it eating the
			#     whole party for 1 damage a body. `_is_doomed` is the same
			#     "we are losing it regardless" test Kavai / Moira / Mildred
			#     cash themselves in on — a lethal opposing link on the chain,
			#     or death at the open combat window's conclusion.
			#   WHERE TO POINT IT: nowhere special. Once the body is free the
			#     damage is pure upside, so it reuses the ordinary damage
			#     targeting (lethal first via find_lethal, ranked by
			#     rank_lethal_targets, then most-damaged) rather than inventing
			#     a second heuristic.
			#
			# The forecast runs through preview_hero_damage_amount, so Chromatic
			# Cloak's +1, Shadowform's typed bonus and World in Flames'
			# doubling are all counted when asking what is lethal — the packet
			# is hero-sourced (`hero_deals_damage`), which is exactly what those
			# auras read.
			var rs_threatened := _chain_threatened_ally(state, db, player_id)
			var rs_doomed := ""
			for own in state.cards_in_zone(player_id + "_ally_row"):
				if own.instance_id == card.instance_id:
					continue
				if _is_doomed(state, db, own.instance_id, rs_threatened):
					rs_doomed = own.instance_id
					break
			if rs_doomed == "":
				continue   # nothing dying anyway — never spend a healthy body
			var rs_from_ability: bool = StackResolver._has_effect_flag(
				def, "hero_deals_damage") and def.card_type == "Ability"
			var rs_amount := StackResolver.preview_hero_damage_amount(
				state, db, player_id, int(ap.get("amount", 0)),
				str(ap.get("dmg_type", "")), rs_from_ability)
			var rs_opp := "p2" if player_id == "p1" else "p1"
			var rs_targets: Array[String] = []
			for foe in state.cards_in_zone(rs_opp + "_ally_row"):
				rs_targets.append(foe.instance_id)
			var rs_opp_ps := state.players.get(rs_opp) as PlayerState
			if rs_opp_ps and rs_opp_ps.hero_instance_id != "":
				rs_targets.append(rs_opp_ps.hero_instance_id)
			rs_targets.sort_custom(func(a: String, b: String) -> bool:
				var ca := state.get_card(a)
				var cb := state.get_card(b)
				return (ca.damage_taken if ca else 0) > (cb.damage_taken if cb else 0))
			var rs_lethal := find_lethal(state, db, player_id, rs_amount)
			var rs_pool: Array[String] = []
			for tid in rs_targets:
				if tid in rs_lethal:
					rs_pool.append(tid)
			var rs_ordered: Array[String] = rank_lethal_targets(state, db, rs_pool)
			for tid in rs_targets:
				if tid not in rs_ordered:
					rs_ordered.append(tid)
			for tid in rs_ordered:
				var rs_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": tid,
						"sacrifice_id": rs_doomed})
				if StackResolver.can_submit(state, rs_act, db):
					result.append(rs_act)
					break
		elif ap.get("effect", "") == "deal_damage_to_target" \
			and str(ap.get("amount_raw", "")) == "sac_atk" \
				and StackResolver.power_sacrifice_is_separate(ap):
			# Mezzik Darkspark: "[Activate], Destroy an ally in your party ->
			# Mezzik deals X shadow damage to target hero or ally, where X is
			# the ATK of the destroyed ally." The sacrifice IS the damage, which
			# inverts the usual sacrifice heuristic: Gertha and Besh'iah want
			# the ally they would miss least, this wants a HIGH-ATK one — so
			# the pick is made target-first, per candidate sacrifice, and the
			# power is only fired when the trade actually pays.
			var mez_opp := "p2" if player_id == "p1" else "p1"
			var mez_hero_id := ""
			var mez_opp_ps := state.players.get(mez_opp) as PlayerState
			if mez_opp_ps:
				mez_hero_id = mez_opp_ps.hero_instance_id
			var best_sac := ""
			var best_tid := ""
			var best_gain := 0.0
			for own in state.cards_in_zone(player_id + "_ally_row"):
				# Never eat Mezzik herself: she is the repeatable engine, and the
				# 1 damage her own ATK buys is never the reason to spend her.
				if own.instance_id == card.instance_id:
					continue
				var x := state.get_atk(own.instance_id, db)
				if x <= 0:
					continue
				var sac_val := card_value_score(state, db, own.instance_id)
				# Lethal on the opposing hero ends the game — nothing outranks it.
				if mez_hero_id != "" and state.is_in_play(mez_hero_id) \
						and state.get_current_hp(mez_hero_id, db) <= x:
					best_sac = own.instance_id
					best_tid = mez_hero_id
					best_gain = INF
					break
				# Otherwise it must KILL something worth more than the body we
				# feed it — chip damage for a whole ally is how this card is
				# wasted. An ally of ours that is already dying is cheap by
				# card_value_score, which is what makes cashing one in attractive.
				for foe in state.cards_in_zone(mez_opp + "_ally_row"):
					if state.get_current_hp(foe.instance_id, db) > x:
						continue
					var gain := card_value_score(state, db, foe.instance_id) - sac_val
					if gain > best_gain:
						best_gain = gain
						best_sac = own.instance_id
						best_tid = foe.instance_id
			if best_sac != "" and best_tid != "" and best_gain > 0.0:
				var mez_act := PendingAction.make("use_ally_power", player_id,
					{"card_id": card.instance_id, "target_id": best_tid,
						"sacrifice_id": best_sac})
				if StackResolver.can_submit(state, mez_act, db):
					result.append(mez_act)
		elif ap.get("effect", "") == "prevent_next_damage_target":
			# Korthas Greybeard: "[Activate] -> Prevent the next 1 damage that
			# would be dealt to target hero or ally this turn." The generic
			# hero_or_ally branch below reads a non-heal effect as DAMAGE and
			# would point the shield at the enemy, which is exactly backwards.
			# Held for damage actually on its way to our side; see
			# korthas_shield_action().
			continue
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
			# Seva Shadowdancer's X is the price AND the heal, freely chosen —
			# so heal exactly the damage on the target, capped by what we can
			# pay. Deliberately no Boris-style "only for 3+" floor: his flip is
			# once per GAME, hers is once per ready, so a cheap top-up is fine.
			var ap_free_x: bool = StackResolver.power_x_is_free(ap)
			var ap_avail := state.get_available_resources(player_id)
			for target_id in ordered:
				var ap_params := {"card_id": card.instance_id, "target_id": target_id}
				if ap_free_x:
					var seva_dmg := state.get_max_hp(target_id, db) 						- state.get_current_hp(target_id, db)
					var seva_x: int = min(seva_dmg, ap_avail)
					if seva_x < 1:
						continue
					ap_params["x_value"] = seva_x
				var act := PendingAction.make("use_ally_power", player_id, ap_params)
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
		elif ap.get("effect", "") == "must_attack_target":
			# Lynda Steele: "(1) -> Target ally must attack this turn if able."
			# Rule 600.2's lock bites during the TARGET's controller's action
			# phase, and the grant expires at end of turn — so fired on our own
			# turn at an opposing ally it does precisely nothing, and the generic
			# "ally" branch below would otherwise point it at our OWN best ally
			# and force us to attack with it. Held for the opponent's turn; see
			# must_attack_action().
			continue
		elif ap.get("effect", "") == "remove_self_from_combat":
			# Avanthera: "(1) -> If Avanthera is in combat, remove her from
			# combat." The generic untargeted branch below would fire it in every
			# defend window she is in — including fights she WINS, throwing the
			# kill away and paying 1 for it. Held for a combat she would not
			# survive; see avanthera_escape_action().
			continue
		elif ap.get("effect", "") == "remove_attacking_allies":
			# Ghost Wolf: "Exhaust your hero -> If your hero is defending, remove
			# all attacking allies from combat." The generic untargeted branch
			# below would exhaust our hero at any window for a clause that is only
			# true inside a defend window (602.3) — and the exhaust would then cost
			# us the hero's attack on our own turn. Held for an ally attack our
			# hero is actually defending against; see ghost_wolf_action().
			continue
		elif ap.get("effect", "") == "prevent_combat_damage_target":
			# Katsin Bloodoath: "(3) -> Prevent all combat damage dealt to and by
			# target friendly ally this turn." The shield does nothing outside a
			# combat, and the generic branch below would spend 3 resources on it
			# every turn for no effect. Held for a combat one of our allies would
			# not survive; see katsin_shield_action().
			continue
		elif ap.get("effect", "") == "prevent_next_hero_damage":
			# Soul Link: "Put 1 damage on an ally in your party -> Prevent the
			# next 1 damage that would be dealt to your hero this turn." The
			# power is FREE and repeatable, so the generic branch below would
			# chew through the whole party every turn for a shield nothing is
			# about to test. Held for damage actually on its way to our hero;
			# see soul_link_action().
			continue
		elif ap.get("effect", "") == "gain_control_ally":
			# Staff of Dominance: "(X), [Activate], Destroy [this] -> Gain control
			# of target ally with cost X." TARGET-FIRST, which is what the X
			# demands: the printed text reads "choose X, then find a match", but a
			# heuristic has to see an ally it can afford and pay accordingly. So
			# enumerate the OPPONENT's allies (taking our own does nothing and
			# burns the staff), drop the ones we can't pay for INSIDE the loop —
			# a rich target we can't afford must not hide a cheaper one we can —
			# and take the most valuable that remains. The steal is PERMANENT, so
			# there is no value floor beyond affordability: any body is worth a
			# staff that has already been paid for.
			var gc_opp := _other_player_id(state, player_id)
			var gc_pool: Array[String] = []
			for enemy in state.cards_in_zone(gc_opp + "_ally_row"):
				gc_pool.append(enemy.instance_id)
			for gc_best in sort_valuable_cards(state, db, gc_pool):
				var gc_target := state.get_card(gc_best)
				var gc_def := db.get_def(gc_target.card_def_id) as CardDef if gc_target else null
				if not gc_def:
					continue
				var gc_act := PendingAction.make("use_ally_power", player_id, {
					"card_id": card.instance_id, "target_id": gc_best,
					"x_value": StackResolver.printed_cost(gc_def),
				})
				if StackResolver.can_submit(state, gc_act, db):
					result.append(gc_act)
					break
		elif ap.get("effect", "") == "control_ally_while_exhausted":
			# Helwen: "[Activate] -> While Helwen remains exhausted, you control
			# target ally." Taking our OWN ally does nothing and taps her for
			# free, so the generic "ally" branch below (which aims at our own
			# board) is exactly wrong — steal the opponent's most valuable ally
			# instead. Her tap costs us a 2/2 attack, so it is only worth doing
			# when there is something on their side to take.
			var opp_id := _other_player_id(state, player_id)
			var steal_pool: Array[String] = []
			for enemy in state.cards_in_zone(opp_id + "_ally_row"):
				steal_pool.append(enemy.instance_id)
			if not steal_pool.is_empty():
				for best_steal in sort_valuable_cards(state, db, steal_pool):
					var steal_act := PendingAction.make("use_ally_power", player_id,
						{"card_id": card.instance_id, "target_id": best_steal})
					if StackResolver.can_submit(state, steal_act, db):
						result.append(steal_act)
						break
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
		# prevent_next_damage_target (Graccus): held for defense — the flip is
		# once per GAME, so it is never spent on a board with nothing incoming.
		# See graccus_shield_action().
		if _hero_power_is(state, db, hero_id, "prevent_next_damage_target"):
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
		# ready_hero (Thangal): the untargeted branch below would flip him every
		# turn for nothing, and a flip spent on an already-ready hero is 3
		# resources and the whole turn's power for a no-op. Only propose it when
		# there is actually something to ready. The defensive use — readying the
		# hero mid-attack so its bear-form protector grant blocks again — is
		# thangal_ready_action, which runs off-turn where this enumeration never
		# does.
		if _hero_power_is(state, db, hero_id, "ready_hero"):
			var self_hero := state.get_card(hero_id)
			if not self_hero or not self_hero.is_exhausted:
				return result
		# hero_grant_keyword (Warrax: "Warrax has protector this turn"). A purely
		# DEFENSIVE grant, and this enumeration only ever runs on our own turn —
		# where a protector grant does nothing, since the opponent isn't
		# attacking. Never propose it here; warrax_protector_action is the
		# off-turn hook that actually uses it.
		if _hero_power_is(state, db, hero_id, "hero_grant_keyword"):
			return result
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
	var attackers := productive_attackers(state, player_id, db)
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
	# Devotion Aura: "If a hero or ally in your party would be dealt damage,
	# prevent 1 of that damage." A blanket reduction on the TARGET's whole party,
	# so every packet in this combat is trimmed before it lands — a 2-ATK attacker
	# no longer kills a 1-health ally. Asked here, the one shared "does this combat
	# remove that card?" predicate behind find_safe_lethals and combat_trade_value,
	# so offence and defence both count it for free (the same spot Brother Rhone
	# and Plagueborn Meatwall were taught). Read live off the board, and floored at
	# 0 so a fully-trimmed swing kills nothing.
	var reduced: int = max(GameLogic.party_damage_reduction(state, db, target), 0)
	var atk: int = max(forecast_atk(state, db, source, source_is_attacker) - reduced, 0)
	if atk >= state.get_current_hp(target, db):
		return true
	# Plagueborn Meatwall: "When he DEFENDS against an ally, remove all damage
	# from him, and he deals that much melee damage to each attacking ally." The
	# reflect resolves in the defend window, BEFORE the conclusion, so a damaged
	# wall kills an attacking ally outright — and without this the AI reads him
	# as the 0-ATK body he looks like and never blocks with him on purpose.
	# Defending only, and never against a hero (the "against an ally" clause).
	if not source_is_attacker and StackResolver._is_ally(state, target):
		var wall := state.get_card(source)
		var wall_def := db.get_def(wall.card_def_id) as CardDef if wall else null
		# The reflect is damage dealt to the ATTACKER, so its own party's
		# Devotion Aura trims it exactly like any other packet.
		if wall_def and StackResolver._has_effect_flag_prefix(
				wall_def, "on_defend_vs_ally_reflect_damage") 				and wall.damage_taken - reduced >= state.get_current_hp(target, db):
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


# ── Warmaster Hork's pump gate ───────────────────────────────────────────────
# Does +amount ATK on `card_id` turn a non-kill into a kill? Asked against the
# combat he is ALREADY in (the other combatant, with the attacking side taken
# from the board so "while attacking" bonuses land on the right one), else
# against every character he could still legally attack this turn. Anything
# else is a wasted payment: the buff is per-use and repeatable, so an ungated
# power would eat every spare resource for +1 ATK that changes no outcome.
# Self-limiting by construction — once the buff is in, forecast_atk already
# includes it and the same question answers false.
func _pump_converts_a_kill(state: GameState, db, player_id: String,
		card_id: String, amount: int) -> bool:
	if state.combat_attacker == card_id or state.combat_defender == card_id:
		var attacking := state.combat_attacker == card_id
		var other: String = state.combat_defender if attacking else state.combat_attacker
		if other == "" or not state.is_in_play(other):
			return false
		var c_atk := forecast_atk(state, db, card_id, attacking)
		var c_hp := state.get_current_hp(other, db)
		return c_atk < c_hp and c_atk + amount >= c_hp
	# Not in combat: the pump only pays for an attack he can still make.
	if not StackResolver.get_legal_attackers(state, player_id, db).has(card_id):
		return false
	var atk := forecast_atk(state, db, card_id, true)
	for target_id in StackResolver.get_legal_defenders(state, card_id, db):
		var hp := state.get_current_hp(target_id, db)
		if atk < hp and atk + amount >= hp:
			return true
	return false


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
		if key in ["deal_damage_to_target", "destroy_exhausted_ally", "deal_damage_and_heal", "deal_x_damage_to_ally", "deal_7_minus_hand_to_hero", "heal_x_from_target", "radak_pet_sacrifice", "target_cant_attack", "prevent_next_damage_target"]:
			return true
	return false


func _other_player_id(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id


# An X-cost hand card with no target whose X is simply "how much do I want to
# buy" (Blood Fury: X fury counters, each worth +1 hero ATK while attacking
# for the rest of the game). Announces the largest X the player can pay for
# right now, asked of get_play_cost one X at a time so a cost aura buys the
# extra counter it should, and returns null below `min_x` — a token X on a
# card whose fixed cost is already high is how it gets wasted.
func _counter_x_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String, min_x: int) -> PendingAction:
	var avail := state.get_available_resources(player_id)
	var max_x := 0
	for x in range(1, avail + 1):
		if state.get_play_cost(card_id, db, x) <= avail:
			max_x = x
		else:
			break
	if max_x < min_x:
		return null
	var action := PendingAction.make(action_type, player_id, {
		"card_id": card_id, "x_value": max_x,
	})
	if StackResolver.can_submit(state, action, db):
		return action
	return null


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


# Cleave: "Your hero deals X melee damage to each of up to two target allies,
# where X is 1 plus the ATK of one of your Melee weapons." Multi-Shot's
# kills-first-then-soak heuristic, narrowed to 2 slots, ALLIES only (no hero
# fallback — the card can't target one) and X read LIVE off the board
# (StackResolver.cleave_damage_amount) instead of a flat parsed constant.
# Expose Armor (`destroy_targets_per_cost_removed:armor`): "remove up to five
# Combo cards in your graveyard from the game. Destroy X target armor, where X is
# the number of Combo cards removed."
#
# TARGET-FIRST, and that is the whole difference from Eviscerate. There, the AI
# always pays the maximum the graveyard can afford, because a card sitting in a
# graveyard does no work for anyone and the exile IS the damage. Here the removed
# count is the number of TARGETS, so per 707.1d an announcement that names more
# Combo cards than there is armor to break is ILLEGAL, not just wasteful - the
# question has to be asked from the board inwards: find the armor worth breaking,
# then buy exactly that many.
#
# Value bar is Burn Away's / Sunder Armor's (OPPOSING only, printed cost >= the
# spell's own), which is what stops a hard-won graveyard being spent on a pile of
# DEF 0 cloaks; the best armor goes first, so a cost-capped cast breaks the
# biggest pieces. WHICH Combo cards pay is left to graveyard order (Augustus'
# auto-chosen `rfg_allies` convention) - a human picks freely in the browser.
#
# N = 0 HOLDS THE CARD. The engine would happily accept "destroy 0 target armor"
# (see _can_play_destroy_targets_per_cost), but spending a card to do nothing is
# never a play; the mute_when tokens keep it quiet in the same situation.
func _expose_armor_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	if not db:
		return null
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var kind := StackResolver.destroy_targets_per_cost_kind(def)
	var opp := _other_player_id(state, player_id)

	# Opposing armor worth breaking, dearest first (printed cost is the value
	# proxy the destroy branches all use).
	var ranked: Array = []
	for cid in StackResolver.get_destroy_kind_candidates(state, db, kind):
		var t_card := state.get_card(cid)
		if not t_card or t_card.controller != opp:
			continue
		var t_def := db.get_def(t_card.card_def_id) as CardDef
		if not t_def or t_def.cost < def.cost:
			continue
		var pos := ranked.size()
		for i in ranked.size():
			if t_def.cost > int(ranked[i][0]):
				pos = i
				break
		ranked.insert(pos, [t_def.cost, cid])
	if ranked.is_empty():
		return null

	# ...capped by what the graveyard can actually pay, and by the printed five.
	var cost_cands := StackResolver.get_play_rfg_cost_candidates(
			state, player_id, def, db)
	var spec := StackResolver.play_cost_rfg_graveyard_spec(def)
	var n: int = ranked.size()
	if cost_cands.size() < n:
		n = cost_cands.size()
	var printed_max: int = int(spec.get("max", 0))
	if printed_max < n:
		n = printed_max
	if n < 1:
		return null

	var targets: Array = []
	for i in n:
		targets.append(ranked[i][1])
	var act := PendingAction.make(action_type, player_id, {
		"card_id":    card_id,
		"cost_ids":   cost_cands.slice(0, n),
		"target_ids": targets,
	})
	return act if StackResolver.can_submit(state, act, db) else null


func _cleave_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var amount := StackResolver.cleave_damage_amount(state, def, player_id, db)
	if amount <= 0:
		return null
	var opp := _other_player_id(state, player_id)
	var kills: Array[String] = []
	var soak:  Array[String] = []
	for ally in state.cards_in_zone(opp + "_ally_row"):
		if state.get_current_hp(ally.instance_id, db) <= amount:
			kills.append(ally.instance_id)
		else:
			soak.append(ally.instance_id)
	# Higher-HP allies soak the swing that won't kill anything.
	soak.sort_custom(func(a, b):
		return state.get_current_hp(a, db) > state.get_current_hp(b, db))
	var ordered: Array[String] = []
	ordered.append_array(kills)
	ordered.append_array(soak)
	if ordered.is_empty():
		return null
	var keys := ["target_id", "target_id_2"]
	var params := {"card_id": card_id}
	var chosen := 0
	for cand in ordered:
		if chosen >= 2:
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
# Shared with Call the Spirit's fetch-to-hand, where the same "best body" pick
# applies and the candidate pool simply carries no cost cap — the fetched card
# is paid for later, so nothing here has to check affordability. Hand size is
# not a concern either: the spell leaves the hand as the fetched card enters it.
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


# Cold Snap: "Remove Cold Snap from the game. Put up to X Frost ability cards
# with different names from your graveyard into your hand." The pick is not
# "which card" but "how many to buy", so X is chosen first and the cards follow.
#
# X = the smallest of what we can PAY for (asked of get_play_cost one X at a
# time, so a cost aura counts), how many DISTINCT names the graveyard actually
# holds (a second copy of a name is unfetchable, so paying for it is waste), and
# how much HAND ROOM we have once the spell itself leaves the hand — a card
# fetched over the limit is discarded at wrap-up (503.2a) for nothing. With
# nothing to fetch the card is held entirely: it would exile itself for a
# 2-resource cantrip that isn't even a cantrip.
# Premeditation: "Search your deck for up to two Combo cards, reveal them, and
# put them into your hand."
#
# Unlike Cold Snap's graveyard fetch there is no X to buy and no distinct-name
# constraint, so the only question is HOW MANY — and the cards are free once the
# spell is paid for, which makes the answer "as many as we can keep": the printed
# MAX, what the deck actually holds, and the HAND ROOM left once the spell itself
# leaves the hand (503.2a — a card fetched over the limit is discarded at wrap-up
# for nothing).
#
# WHICH cards: the most expensive first. Cost is the value proxy the rest of the
# AI uses, and a deck search hands us the pick for free.
#
# With nothing to find the card is HELD. Rule 413.3 makes an empty search
# perfectly legal, but paying 4 resources and a card to shuffle our own deck is
# not a play.
func _deck_search_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var req := StackResolver.get_graveyard_search_requirement(def)
	var cands := StackResolver.get_graveyard_search_candidates(state, player_id, req, db)
	if cands.is_empty():
		return null
	var ranked: Array = []
	for cid in cands:
		var c := state.get_card(cid)
		var cdef := db.get_def(c.card_def_id) as CardDef if c else null
		ranked.append({"id": cid, "cost": cdef.cost if cdef else 0})
	ranked.sort_custom(func(a, b): return int(a["cost"]) > int(b["cost"]))
	var hand := state.zones.get(player_id + "_hand") as Zone
	var hand_size: int = hand.card_ids.size() if hand else 0
	# The spell itself leaves the hand as it resolves, so it frees one slot.
	var room := state.get_max_hand_size(player_id, db) - (hand_size - 1)
	var take: int = min(min(StackResolver.graveyard_max_count(req), ranked.size()), room)
	if take < 1:
		return null
	var picks: Array = []
	for i in range(take):
		picks.append(ranked[i]["id"])
	var action := PendingAction.make(action_type, player_id,
			{"card_id": card_id, "target_ids": picks})
	if StackResolver.can_submit(state, action, db):
		return action
	return null


func _graveyard_multi_fetch_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var req := StackResolver.get_graveyard_search_requirement(def)
	var cands := StackResolver.get_graveyard_search_candidates(state, player_id, req, db)
	# Best copy per name, most expensive first — cost is the value proxy, and a
	# duplicate name can never join the same selection.
	var by_name := {}
	for cid in cands:
		var c := state.get_card(cid)
		var cdef := db.get_def(c.card_def_id) as CardDef if c else null
		if not cdef or by_name.has(cdef.card_name):
			continue
		by_name[cdef.card_name] = {"id": cid, "cost": cdef.cost}
	var ranked: Array = by_name.values()
	ranked.sort_custom(func(a, b): return int(a["cost"]) > int(b["cost"]))
	if ranked.is_empty():
		return null
	var avail := state.get_available_resources(player_id)
	var max_x := 0
	for x in range(1, avail + 1):
		if state.get_play_cost(card_id, db, x) <= avail:
			max_x = x
		else:
			break
	var hand := state.zones.get(player_id + "_hand") as Zone
	var hand_size: int = hand.card_ids.size() if hand else 0
	# The spell itself leaves the hand as it resolves, so it frees one slot.
	var room := state.get_max_hand_size(player_id, db) - (hand_size - 1)
	var take: int = min(min(max_x, ranked.size()), room)
	if take < 1:
		return null
	var picks: Array = []
	for i in range(take):
		picks.append(ranked[i]["id"])
	var action := PendingAction.make(action_type, player_id, {
		"card_id": card_id, "target_ids": picks, "x_value": take,
	})
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

	# Healing Touch (`heal_target:N` as a top-level segment): the ONE targeted
	# hand spell whose target must be FRIENDLY. The printed text is "target hero
	# or ally" — an opponent's character is perfectly legal for a human — but
	# repairing the enemy board is never what the AI wants, so it only ever sees
	# its own side, and only characters actually carrying damage (heal() no-ops
	# on an undamaged target, so an untargeted branch would burn the card for
	# nothing). Most-damaged first, our hero winning a tie: the hero is the one
	# character whose loss ends the game, and the heal is capped by the damage
	# present anyway. Falls out of the loop with no actions when nothing on our
	# side is damaged, so the card is simply held.
	if spell_def and StackResolver._heal_target_amount(spell_def) > 0:
		var heal_best := ""
		var heal_dmg := 0
		var heal_ps := state.players.get(player_id) as PlayerState
		if heal_ps and heal_ps.hero_instance_id != "":
			var heal_hero := state.get_card(heal_ps.hero_instance_id)
			if heal_hero and heal_hero.damage_taken > 0:
				heal_best = heal_hero.instance_id
				heal_dmg = heal_hero.damage_taken
		for heal_ally in state.cards_in_zone(player_id + "_ally_row"):
			if heal_ally.damage_taken > heal_dmg:
				heal_dmg = heal_ally.damage_taken
				heal_best = heal_ally.instance_id
		if heal_best != "":
			var heal_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": heal_best})
			if StackResolver.can_submit(state, heal_act, db):
				result.append(heal_act)
		return result

	# Burn Away / Shattering Blow / Sunder Armor (destroy_target:ability /
	# :equipment / :armor): targets are opposing in-play ability / equipment
	# cards, not heroes and allies.
	# Value gate: target cost >= spell cost (same bar as _destroy_is_worth_it's
	# first gate; the solo-kill check doesn't apply — you can't attack these).
	var destroy_kind := StackResolver.destroy_target_kind(spell_def) if spell_def else ""
	if destroy_kind in ["ability", "equipment", "armor"]:
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

	# Crushing Blow (`choose_destroy:armor:weapon`): "choose one or both" — the
	# two halves are announced TOGETHER in one submission, so unlike the
	# Sunder-Armor-style loop above (one action per candidate, left for scoring
	# to pick among) this builds ONE action carrying whichever half(s) clear the
	# same value bar (opposing, printed cost >= the spell's own — Burn Away's
	# convention). Both halves fire when both have a worthwhile target, one
	# fires alone when only that kind does, and the card is held when neither
	# opposing pool clears the bar.
	if spell_def and StackResolver.is_choose_destroy_def(spell_def):
		var cb_kinds := StackResolver.choose_destroy_kinds(spell_def)
		var cb_keys := ["target_id", "target_id_2"]
		var cb_params := {"card_id": card_id}
		var cb_picked := false
		for i in cb_kinds.size():
			if i >= cb_keys.size():
				break
			var cb_best_id := ""
			var cb_best_cost := -1
			for cid in StackResolver.get_destroy_kind_candidates(state, db, cb_kinds[i]):
				var cb_t_card := state.get_card(cid)
				if not cb_t_card or cb_t_card.controller != opp:
					continue
				var cb_t_def := db.get_def(cb_t_card.card_def_id) as CardDef
				if not cb_t_def or cb_t_def.cost < spell_def.cost:
					continue
				if cb_t_def.cost > cb_best_cost:
					cb_best_cost = cb_t_def.cost
					cb_best_id = cid
			if cb_best_id != "":
				cb_params[cb_keys[i]] = cb_best_id
				cb_picked = true
		if cb_picked:
			var cb_act := PendingAction.make(action_type, player_id, cb_params)
			if StackResolver.can_submit(state, cb_act, db):
				result.append(cb_act)
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

	# Fear (`return_to_hand:opposing_ally`): "Put target opposing ally into its
	# owner's hand." A BOUNCE, not removal — the opponent gets the card back and
	# only pays tempo — so the two things that matter are what the bounce costs
	# them and whether it is really temporary.
	#
	#  1. TOKENS FIRST. A token that leaves play ceases to exist (move_card sends
	#     it to RFG), so bouncing one is permanent removal for 1 resource — always
	#     better than tempo-ing a real ally, whatever the two are worth. No value
	#     gate applies: a token has no printed cost to compare and it is never
	#     coming back.
	#  2. Otherwise the most valuable opposing ally, gated on printed cost >= the
	#     spell's (`_destroy_is_worth_it`'s first bar). Bouncing a 1-cost body
	#     with a 1-cost card trades a card for nothing.
	#
	# Held combat saves (Withdraw, tagged combat_instant_save_bounce) never reach
	# here — get_reasonable_actions skips tagged cards, and Withdraw's own hook is
	# defensive. Fear is sorcery speed and offensive, so it is deliberately
	# untagged and plays from this branch in the develop step.
	#
	# Deliberately NOT modelled: an ally with an enter-play trigger hands its
	# controller the trigger again when it is replayed, so bouncing one is worth
	# less than its cost suggests. Judging that needs a model of the trigger's
	# value that the AI does not have.
	var rth_kind := StackResolver.return_to_hand_kind(spell_def) if spell_def else ""
	if rth_kind == "opposing_ally":
		var bounce_id := ""
		var bounce_score := -1.0
		var bounce_token := false
		for ally in state.cards_in_zone(opp + "_ally_row"):
			var b_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": ally.instance_id})
			if not StackResolver.can_submit(state, b_act, db):
				continue
			if ally.is_token:
				# A token is gone for good — take the most valuable one and stop
				# considering real allies at all.
				var t_score := card_value_score(state, db, ally.instance_id)
				if not bounce_token or t_score > bounce_score:
					bounce_token = true
					bounce_score = t_score
					bounce_id = ally.instance_id
				continue
			if bounce_token:
				continue   # a permanent kill outranks any tempo play
			var a_def := db.get_def(ally.card_def_id) as CardDef
			if a_def and spell_def and a_def.cost < spell_def.cost:
				continue   # bouncing something cheaper than the spell loses value
			var score := card_value_score(state, db, ally.instance_id)
			if score > bounce_score:
				bounce_score = score
				bounce_id = ally.instance_id
		if bounce_id != "":
			result.append(PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": bounce_id}))
		return result

	# X-cost spell (Aimed Shot, "1+X" — deal X damage): announce X with the
	# play. vs an ally: X = exactly its HP (kill for the least); vs the hero:
	# Charge (`exhaust_target:hero_or_ally` plus a `draw:1`, on a SORCERY-speed
	# Ability): unlike Exhaustion / Bash / Gouge this one is not a held combat
	# instant — it can only be played in our own action phase, so it can never
	# fizzle a combat proposal at the 601.3 recheck. What it CAN do is strip a
	# blocker before we swing: an exhausted ally is not a legal protector (602.2
	# requires a ready protector), so the play is the opponent's best READY ally.
	# Exhausting their HERO on our own turn does nothing (they ready at their own
	# turn start), and neither does hitting an already-exhausted ally — but the
	# card cantrips, so with no ready ally to strip we still cycle it rather than
	# sit on a dead card. The hero fallback is `can_submit`-filtered, so an
	# ally-only exhaust (Exhaustion) simply drops it.
	if spell_def and _exhaust_target_kind(spell_def) != "":
		var ex_order: Array[String] = []
		var best_ex := ""
		var best_ex_val := -1.0
		for ready_ally in state.cards_in_zone(opp + "_ally_row"):
			if ready_ally.is_exhausted:
				continue
			var ex_val := card_value_score(state, db, ready_ally.instance_id)
			if ex_val > best_ex_val:
				best_ex_val = ex_val
				best_ex = ready_ally.instance_id
		if best_ex != "":
			ex_order.append(best_ex)
		var ps_ex := state.players.get(opp) as PlayerState
		if ps_ex and ps_ex.hero_instance_id != "":
			ex_order.append(ps_ex.hero_instance_id)
		for ex_target in ex_order:
			var ex_act := PendingAction.make(action_type, player_id,
					{"card_id": card_id, "target_id": ex_target})
			if StackResolver.can_submit(state, ex_act, db):
				result.append(ex_act)
		return result

	# X = everything we can pay. max_x <= 0 → unaffordable, no actions.
	var max_x := 0
	if spell_def and spell_def.cost_x:
		max_x = state.get_available_resources(player_id) \
			- state.get_play_cost(card_id, db, 0)

	# Sever the Cord: "destroy an ally in your party" is an additional cost, so
	# every announcement below has to carry a sacrifice or can_submit rejects it.
	# Eat our least valuable body (the spell is in hand — there's no source ally
	# to exclude), and only when the target is worth strictly more than what we
	# give up: the card already costs a card and resources, and paying a better
	# ally for a worse one is how this gets misplayed. No ally to eat → no
	# actions at all, which is also what the highlight probe says.
	var sac_id := ""
	var sac_val := 0.0
	if spell_def and StackResolver.play_cost_sacrifices_ally(spell_def):
		var sac := _cheapest_sacrifice_ally(state, db, player_id, "")
		sac_id = str(sac[0])
		if sac_id == "":
			return result
		sac_val = float(sac[1])

	# Eviscerate: "remove up to five Combo cards in your graveyard from the game"
	# is an additional cost — and it IS the damage, X being 2 plus the number
	# removed — so every announcement below carries the most the graveyard can
	# pay. There is nothing to weigh here: a card sitting in a graveyard does no
	# work for us, so the AI always takes the full cost, and WHICH cards is left
	# to graveyard order (Augustus' auto-chosen rfg_allies convention). A human
	# picks freely in the browser. "Up to" includes zero, so an empty graveyard
	# is not a reason to hold the card — it just deals its flat part.
	var cost_ids: Array = []
	if spell_def:
		var pc_spec := StackResolver.play_cost_rfg_graveyard_spec(spell_def)
		if not pc_spec.is_empty():
			var pc_cands := StackResolver.get_play_rfg_cost_candidates(
					state, player_id, spell_def, db)
			cost_ids = pc_cands.slice(0, int(pc_spec.get("max", 0)))

	for ally in state.cards_in_zone(opp + "_ally_row"):
		var params := {"card_id": card_id, "target_id": ally.instance_id}
		if not cost_ids.is_empty():
			params["cost_ids"] = cost_ids.duplicate()
		if sac_id != "":
			if card_value_score(state, db, ally.instance_id) <= sac_val:
				continue
			params["sacrifice_id"] = sac_id
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
			if not cost_ids.is_empty():
				params["cost_ids"] = cost_ids.duplicate()
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

# ── Multi-modal "choose one or more" (Totemic Call) ───────────────────────────
# Unlike a single-choice modal there is nothing to trade off: the modes don't
# compete, they are all free once the card is paid for, and the only reason to
# decline one is that it would do nothing (or something we don't want). So the
# policy is "take every available mode that has work to do", which is also what
# makes the card's price fair — it scales with how many totems are out.
#
# Per mode:
#   Air   — only when something would actually ready (our hero is exhausted, or
#           a Melee weapon of ours is). Galway Steamwhistle's gate.
#   Earth — only with an ally in our party to receive the +1 ATK.
#   Fire  — only with a target worth burning, and it is the ONE mode with a
#           target, so declining it is also how we avoid announcing one. The
#           errata makes an illegal target at resolution interrupt the ENTIRE
#           card, so a mode we can aim well is worth having and a doubtful one
#           is genuinely dangerous: prefer a kill, else the opposing hero.
#   Water — only with room in hand for both cards (503.2a) and a deck to draw
#           from, since a blocked draw is a wasted mode.
#
# Announcing zero modes is not a legal play (707.1c), so with nothing worth
# taking the card is held entirely.
func _multi_modal_action(state: GameState, db, player_id: String,
		card_id: String, action_type: String) -> PendingAction:
	if not db:
		return null
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return null
	var modes := StackResolver.totem_modes(def)
	var chosen: Array[int] = []
	var target := ""
	for i in StackResolver.available_totem_modes(state, def, player_id, db):
		var effect := String(modes[i].get("effect", ""))
		match effect.split(":")[0]:
			"ready_hero_and_melee_weapon":
				if _multi_modal_ready_useful(state, db, player_id):
					chosen.append(i)
			"party_allies_atk_this_turn":
				if not state.cards_in_zone(player_id + "_ally_row").is_empty():
					chosen.append(i)
			"draw":
				var amount := int(effect.split(":")[1]) if effect.split(":").size() > 1 else 1
				var hand := state.cards_in_zone(player_id + "_hand").size()
				# The spell itself leaves the hand, hence the -1.
				if hand - 1 + amount <= state.get_max_hand_size(player_id, db) \
						and not state.cards_in_zone(player_id + "_deck").is_empty():
					chosen.append(i)
			"deal_damage_to_target":
				var parts := effect.split(":")
				var amount := int(parts[1]) if parts.size() > 1 else 0
				var dmg_type := parts[2] if parts.size() > 2 else ""
				var pick := _multi_modal_burn_target(state, db, player_id, amount, dmg_type)
				if pick != "":
					chosen.append(i)
					target = pick
	if chosen.is_empty():
		return null
	var params := {"card_id": card_id, "modes": chosen}
	if target != "":
		params["target_id"] = target
	var action := PendingAction.make(action_type, player_id, params)
	return action if StackResolver.can_submit(state, action, db) else null


# Would the Air mode ready anything? Our hero, or a Melee weapon of ours.
func _multi_modal_ready_useful(state: GameState, db, player_id: String) -> bool:
	var hero := state.get_hero(player_id)
	if hero and hero.is_exhausted:
		return true
	return not StackResolver.get_weapon_ready_candidates(
		state, player_id, db, true).is_empty()


# Where the fire mode points: an opposing ally the burn KILLS, else the opposing
# hero. Never our own board — and never nothing, since announcing a target we
# don't want is how the errata's "the entire card is interrupted" clause bites.
func _multi_modal_burn_target(state: GameState, db, player_id: String,
		amount: int, dmg_type: String) -> String:
	var opp := _other_player_id(state, player_id)
	var dealt := StackResolver.preview_hero_damage_amount(
		state, db, player_id, amount, dmg_type, true)
	var best := ""
	var best_score := -1.0
	for enemy in state.cards_in_zone(opp + "_ally_row"):
		if state.get_current_hp(enemy.instance_id, db) > dealt:
			continue
		var score := card_value_score(state, db, enemy.instance_id)
		if score > best_score:
			best_score = score
			best = enemy.instance_id
	if best != "":
		return best
	var opp_hero := state.get_hero(opp)
	return opp_hero.instance_id if opp_hero else ""


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
	# Marked for Death (`party_atk_vs_attached`): the bonus only pays off while one
	# of our allies is attacking the HOST, so put it where we attack most — the
	# opposing hero, which is also the one host that can never be killed to shed
	# it. Needs an ally in play to benefit at all ("allies in your party"), so with
	# an empty party the card is simply not played.
	if StackResolver._has_effect_flag_prefix(def, "party_atk_vs_attached"):
		if state.cards_in_zone(player_id + "_ally_row").is_empty():
			return result
		var m_opp := "p2" if player_id == "p1" else "p1"
		var m_hero := state.get_hero(m_opp)
		if m_hero:
			var m_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": m_hero.instance_id})
			if StackResolver.can_submit(state, m_act, db):
				result.append(m_act)
		return result
	# Thorns (`attached_combat_damage_reflect`): a FRIENDLY attachment, and the
	# one whose debuff-branch misread would be actively self-harming — put it on
	# the opponent and their character reflects at OUR attackers. It goes on our
	# own HERO: the character that gets attacked most, always in play, and the
	# one host that can never be killed to shed it. That is also where the
	# `from_ability` packet earns a Chromatic Cloak's +1, since the bonus needs a
	# HERO source (an ally host reflects for the printed 1).
	if StackResolver._has_effect_flag_prefix(def, "attached_combat_damage_reflect"):
		var t_hero := state.get_hero(player_id)
		if t_hero:
			var t_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": t_hero.instance_id})
			if StackResolver.can_submit(state, t_act, db):
				result.append(t_act)
		return result
	# Fireball / Rend / Deadly Poison (a damage attachment), and Crippling
	# Poison (a recurring exhaust tax) all want the same host for the same two
	# reasons: the opposing HERO is always in play, so it can never be killed
	# to shed the attachment, and -- for the Poison pair, whose attach rider
	# requires the host to have been combat-damaged by OUR hero this turn --
	# it is the character our hero most often connected with, an ally attack
	# usually having gone at a body instead. The generic debuff branch below
	# scans ally_row only, so without this Crippling Poison would never find a
	# legal target at all.
	if StackResolver._has_effect_flag_prefix(def, "attach_deal_damage") \
			or StackResolver._has_effect_flag_prefix(def, "attached_damage_turn_start") \
			or StackResolver._has_effect_flag_prefix(def,
				"attached_exhaust_each_turn_unless_pay"):
		var f_opp := "p2" if player_id == "p1" else "p1"
		var f_hero := state.get_hero(f_opp)
		if f_hero:
			var f_act := PendingAction.make(action_type, player_id,
				{"card_id": card_id, "target_id": f_hero.instance_id})
			if StackResolver.can_submit(state, f_act, db):
				result.append(f_act)
		return result
	# FRIENDLY attachments: a stat buff (Mark of the Wild) or a heal (Primal
	# Mending). "Target ally" makes an opposing ally legal for a human, but
	# putting either on the opponent's board is never what the AI wants — and a
	# heal attachment reaching the debuff branch below would do exactly that,
	# which is the bug this predicate exists to prevent. Anything else
	# (Entangling Roots' exhaust + ready-lock) is a debuff for the opponent.
	# A KEYWORD grant (Lessons in Lurking's stealth) is friendly for the same
	# reason: every keyword in the pool is a benefit, so handing one to the
	# opponent is never wanted even though "target ally" makes it legal. Ranked
	# by ATK like a stat buff — stealth pays off on the body we attack with.
	var is_heal := StackResolver._has_effect_flag_prefix(def, "attach_heal") or StackResolver._has_effect_flag_prefix(def, "attached_heal_turn_end")
	var is_grant := StackResolver._has_effect_flag_prefix(def, "attached_keyword")
	var is_buff := StackResolver._has_effect_flag_prefix(def, "attached_buff") or is_heal or is_grant
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
		# A heal attachment is ranked by DAMAGE, not ATK: the on-attach half only
		# does work on a damaged ally, and the ongoing half pays off best on the
		# body that keeps taking hits. ATK is the tiebreak, so with an undamaged
		# board it still lands on the ally most likely to get into combat rather
		# than doing nothing at all (the regen outlives the turn, unlike a
		# one-shot heal such as Healing Touch, so holding the card is worse).
		var score := state.get_atk(ally.instance_id, db, true)
		if is_heal:
			score += ally.damage_taken * 100
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
	# Asked for the board as it WOULD BE with this pet on it (Goldenmoon's grant
	# is conditional on the pets' names being distinct, so committing a duplicate
	# name lowers the capacity the moment it lands).
	var capacity: int = StackResolver.get_pet_capacity(state, player_id, db, def.card_name)
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
