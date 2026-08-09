class_name GameState
extends Resource

# Single source of truth for everything that can change during a game.
# No Godot node references — this object is fully serializable and can be
# built and manipulated in a headless test without any scene tree.
#
# Read-only access pattern: call the get_* helpers below rather than
# reading nested dictionaries directly — helpers validate keys and apply
# derived-value logic (stat summing, hp calculation) in one place.

# ── Core data ──────────────────────────────────────────────────────────────────
var players: Dictionary = {}   # player_id (String) -> PlayerState
var zones: Dictionary = {}     # zone_id (String)   -> Zone
var cards: Dictionary = {}     # instance_id (String) -> CardInstance
# Monotonic counter behind token instance ids (GameLogic.create_token). Tokens
# are minted mid-game, so unlike deck cards they can't get a setup-time id.
var token_counter: int = 0

# ── Turn / phase state ─────────────────────────────────────────────────────────
# Phases follow the WoW TCG turn structure:
#   "setup"     — pre-game (deck reveal, hero selection, opening hand)
#   "ready"     — ready step: ready all cards, instants-only priority window
#   "draw"      — draw step: draw one card, instants-only priority window
#   "action"    — action phase: full priority window (allies, instants, resources, combat)
#   "end"       — end phase: instants-only priority window, then wrap-up (no window)
var turn_number: int = 0
var turn_player: String = ""       # player_id of who has the active turn
var first_player: String = ""      # player_id who goes first (set once at game start)
var phase: String = "setup"
var priority_player: String = ""   # player_id who currently holds priority

# ── Interrupt stack (rule 409 / 410) ──────────────────────────────────────────
# A stack of proposed-but-not-yet-resolved actions. Last in, first resolved.
# PendingAction class is defined in Phase 4 (stack_resolver.gd).
# Declared here as untyped Array so state serializes correctly before that
# class exists; typed enforcement added when PendingAction is implemented.
var pending_actions: Array = []
var consecutive_passes: int = 0

# ── Active combat state (cleared after each combat concludes) ──────────────────
var combat_attacker: String = ""   # instance_id of attacker; "" = no combat
var combat_defender: String = ""   # instance_id of proposed/actual defender
var in_protect_point: bool  = false # true while waiting for protect decision
var combat_protector: String = ""  # who exhausted to protect this combat; "" = nobody
# Rule 602.1 / 602.3: priority windows within a combat step.
var combat_attack_window: bool  = false  # true during the Attack Window
var combat_defend_window: bool  = false  # true during the Defend Window
# Weapon strikes (rule 303.2a): wielder instance_id -> Array[String] of weapon
# instance_ids associated with it for the current combat step. Cleared at
# combat conclusion. Feeds the strike modifier (+weapon ATK) in get_atk.
var combat_struck_weapons: Dictionary = {}
# "+N ATK this combat" grants (Berserking: "Your hero has +1 ATK this combat for
# each counter you removed."): wielder instance_id -> int. Applied live in
# get_atk, cleared alongside combat_struck_weapons at combat conclusion.
var combat_atk_bonus: Dictionary = {}
# Strike point (rules 602.1 / 602.3): non-empty while a hero's controller must
# decide whether to strike with a weapon. Doesn't use the chain — resolved via
# StackResolver.choose_strike() (direct call, like the protect point).
var pending_strike_player: String = ""
var pending_strike_weapon_ids: Array[String] = []  # strikeable weapons offered
var pending_strike_side: String = ""  # "attack" (602.1) or "defend" (602.3)
# Ready-on-attack point (Windseer Tarus, rule 601.x triggered ability): non-empty
# while an attacker's controller may pay to ready it after it attacks for the
# first time this turn. Opened at combat-step start (602.1), like the strike
# point; resolved via StackResolver.choose_ready_on_attack() (direct call).
var pending_ready_player: String = ""
var pending_ready_card_id: String = ""
var pending_ready_cost: int = 0
# Ready-on-strike point (Windfury Weapon: "When you strike with attached weapon
# for the first time each turn, you may pay 1. If you do, ready that weapon and
# your hero."): non-empty while the striking player may pay to ready the struck
# weapon + their hero. Opened inside choose_strike (602.1 / 602.3), before the
# held combat window; resolved via StackResolver.choose_ready_on_strike().
var pending_strike_ready_player: String = ""
var pending_strike_ready_weapon_id: String = ""
var pending_strike_ready_cost: int = 0
var pending_strike_ready_side: String = ""
# Green Whelp Armor triggered bounce (rule 305.2 triggered equipment power): after
# an attacking ally deals combat damage to the armor wielder's hero, the wielder
# MAY pay to bounce that ally to its owner's hand. Opened at combat conclusion,
# resolved via StackResolver.choose_whelp_bounce() (direct call, like the strike
# point). "" = none pending.
var pending_whelp_bounce_player: String = ""
var pending_whelp_bounce_ally_id: String = ""
var pending_whelp_bounce_cost: int = 0
# Attack-exhaust point (Chops / Voss Treebender: "When [this] attacks, you may
# exhaust target hero or ally."): non-empty while the attacker's controller may
# pick a target to exhaust (or decline). Opened at combat-step start (602.1),
# BEFORE the attack window — resolving it against a ready Protector denies the
# protect point (602.2). Resolved via StackResolver.choose_attack_exhaust()
# (direct call, like the ready-on-attack point). "" = none pending.
var pending_attack_exhaust_player: String = ""
var pending_attack_exhaust_source_id: String = ""
# Armor prevention point (rule 717.2c): opened at the moment a damage packet
# would be dealt to a hero whose controller has ready DEF>0 equipment — at
# combat conclusion, or just before a hero-damaging chain link resolves. The
# player exhausts any number of armors back-to-back (each choose_prevention
# call), or declines; then the (reduced) packet lands. Direct call, NOT the
# chain ("None of this uses the chain" — 717.2c); can_submit / pass_priority
# hard-block while pending. Resolved via StackResolver.choose_prevention().
var pending_prevention_player: String = ""   # who must decide; "" = none
var pending_prevention_amount: int = 0       # damage remaining in the current packet
var pending_prevention_source: String = ""   # packet source card (UI)
var pending_prevention_target: String = ""   # hero about to be hit
var pending_prevention_offers: Array = []    # queued packets: {player, amount, source, target}
var pending_prevention_resume: String = ""   # what to resume: "combat" or "packets"
# Deferred packet groups (resume == "packets"): EVERY non-combat damage effect
# hands its packets to StackResolver.defer_packets instead of calling
# deal_damage — each group is {packets: [{source, target, amount, riders,
# discard_per, drain_heal_per, drain_heal_to}], after: String,
# recursive_destroy: bool} and lands (pool-reduced) once its prevention offers
# are decided. This makes new damage effects preventable by construction.
var pending_prevention_deferred: Array = []

# ── Pending interactive choices (cleared once resolved) ────────────────────────
var pending_discard_player: String = ""  # player who must discard; "" = none pending
var pending_discard_count:  int    = 0   # how many cards still to discard
# Non-empty while an enters-play targeted effect is waiting for the controller to choose a target.
# Keys: card_id (String), effect (String), dmg_type (String), amount (int).
var pending_enter_play_effect: Dictionary = {}
# Pet uniqueness: player must sacrifice pets until at most 1 remains in play.
var pending_pet_sacrifice_player: String = ""
var pending_pet_sacrifice_ids: Array[String] = []  # instance_ids of ALL pets currently in play for that player
# Equipment slot uniqueness (rule 414.3): player must destroy equipment until at
# most one occupies the conflicting slot.
var pending_equip_sacrifice_player: String = ""
var pending_equip_sacrifice_ids: Array[String] = []  # instance_ids of same-slot equipment in play
# Name-based uniqueness (rule 414.3a — the "Unique" tag): a player may not
# control two or more in-play cards with the same name that both carry Unique.
# On violation the player destroys duplicates until only one remains.
var pending_unique_sacrifice_player: String = ""
var pending_unique_sacrifice_ids: Array[String] = []  # instance_ids of the same-named Unique cards in play
# Form (1) tag-count uniqueness (rule 414.3b — Bear Form / Cat Form / Bash / Claw):
# a player may control at most one card with the Form (1) tag (`form:1` effects
# segment) in play. On violation the player destroys Forms until one remains
# (normally keeping the newly played one). Mirrors the Unique-tag flow.
var pending_form_sacrifice_player: String = ""
var pending_form_sacrifice_ids: Array[String] = []  # instance_ids of the in-play Form cards
# Bear/Cat Form death trigger: "When [this] is destroyed, you may pay (2). If you
# do, put it into your hand" (`on_destroyed:pay_return_hand:2`). Opened only when
# the controller can afford the cost; resolved via choose_form_return() (direct
# call, like the whelp bounce). See data/rules_deviations.md "Form return timing".
var pending_form_return_player: String = ""
var pending_form_return_card_id: String = ""
var pending_form_return_cost: int = 0
# Infernal-style start-of-turn choice: discard a card OR give the opponent
# control of the source. Optional discard — declining is a legal resolution
# (unlike pending_discard, which is mandatory).
var pending_control_discard_player: String = ""
var pending_control_discard_ids: Array[String] = []  # source instance_ids, resolved front-first
# Reveal-and-pick quest reward (Big Game Hunter, Kibler's Exotic Pets, Zapped
# Giants): "Reveal the top N cards; put a revealed <type> card into your hand and
# the rest on the bottom of your deck." The revealed cards stay physically at the
# top of the deck while pending (everything else is blocked); on resolution the
# picked card goes to hand and the rest are pushed to the bottom in revealed order.
# The DECIDER may differ from the owner (The Princess Trapped: "Target opponent
# chooses one" — the cards are revealed from, and go to, pending_reveal_pick_player's
# deck/hand, but pending_reveal_pick_chooser is who clicks). The chooser defaults
# to the owner; every guard/blocker keys off _player, only the input routing and
# the AI's pick-quality key off _chooser.
var pending_reveal_pick_player: String = ""   # owner: whose deck was revealed, whose hand the pick goes to
var pending_reveal_pick_chooser: String = ""  # decider: who makes the pick ("" while no choice is open)
var pending_reveal_pick_ids: Array[String] = []   # revealed cards matching the type — the selectable set
var pending_reveal_pick_all: Array[String] = []   # every revealed card, in top→down order
# It's a Secret to Everybody: the picked card goes back on TOP of the owner's
# deck instead of into hand (the rest still go to the bottom), and the reveal is
# a private "look at" rather than a public reveal — the opponent sees nothing.
var pending_reveal_pick_to_top: bool = false
var pending_reveal_pick_private: bool = false
# Ongoing Totem "at the start of each turn" targeted-damage triggers (Searing
# Totem) waiting to fire this ready step. Each entry is a dict
# {card_id, amount, dmg_type}. They are drained one at a time: index 0 is the
# ACTIVE trigger while pending_totem_target_player is non-empty, resolved by that
# player via StackResolver.choose_totem_target() (a direct call, like the strike
# and reveal-pick choices — NOT a chain action). Turn player's totems fire first
# (rule 501.1a). pass_priority / can_submit hard-block while a totem choice is open.
var pending_ongoing_triggers: Array = []
var pending_totem_target_player: String = ""  # controller who must pick a target; "" = none

# ── Quest reward "Choose one … you may choose both" (Hidden Enemies / A New
# Plague / Thwarting Kolkar Aggression / Crown of the Earth) ──────────────────
# When a `qmode:` quest resolves, the completer must pick one reward mode — or
# both, in an order of their choosing, when the `qchoice_both_race:RACE` hero
# condition is met AND both modes are currently available. Direct-call flow
# (NOT the chain, like the reveal pick): StackResolver.choose_quest_modes()
# resolves the pick; pass_priority / can_submit hard-block while any of these
# pendings is set. The chosen modes queue in quest_mode_queue and run one at a
# time; a mode needing further input opens its own pending choice below and the
# queue resumes once it resolves.
var pending_quest_choice_player: String = ""   # completer who must pick; "" = none
var pending_quest_choice_quest: String = ""    # quest instance id (UI)
var pending_quest_choice_modes: Array = []     # [{mode: String, available: bool}] in printed order
var pending_quest_choice_can_both: bool = false
var quest_mode_queue: Array = []               # [{player, quest_id, mode}] — front = next to run
# Hidden Enemies "Target ally has ferocity this turn": completer picks the ally.
var pending_quest_ferocity_player: String = ""
var pending_quest_ferocity_source: String = ""  # quest instance id (buff source / UI)
# A New Plague "each player destroys an ally in his party": each player with an
# ally picks their own sacrifice; completer first, drained front-first.
var pending_plague_destroy_player: String = ""
var pending_plague_destroy_queue: Array[String] = []
var pending_plague_destroy_source: String = ""  # quest instance id (UI)
# Thwarting Kolkar Aggression "target player turns one of his quests face down":
# the TARGET player picks which of their face-up quests flips.
var pending_quest_facedown_player: String = ""
var pending_quest_facedown_ids: Array[String] = []  # that player's face-up quest ids

# Death-triggered targeted effects (Boneshanks: "When [this] is destroyed,
# destroy target ally."). When such a card dies, a trigger dict {card_id,
# controller} is queued here and the front one opens as a mandatory choice:
# pending_death_target_player is the controller who must pick an ally to destroy.
# Drained one at a time (index 0 = active), resolved via
# StackResolver.choose_death_target() — a direct call, NOT a chain action, like
# the totem / strike choices. pass_priority / can_submit hard-block while pending.
# Prompted for a HUMAN controller even in hotseat (the choice is board-public).
var pending_death_triggers: Array = []
var pending_death_target_player: String = ""  # controller who must pick a target ally; "" = none

# Players who have been required to draw a card from an empty deck (rule
# 410.6b). A decked player immediately loses the game (102.1a); if every
# remaining player becomes decked simultaneously, the game is a draw.
# Set by GameLogic.draw_one / mark_decked, never cleared during a game.
var decked_players: Array[String] = []

# ── Mulligan state (cleared once both players have committed) ──────────────────
# player_id -> true once the player has made their mulligan decision.
var mulligan_decided: Dictionary = {}
# player_id -> true if the player chose to mulligan (shuffle+redraw).
var mulligan_wants:   Dictionary = {}


# ── Factory ────────────────────────────────────────────────────────────────────
static func create_new(player_ids: Array[String]) -> GameState:
	var gs := GameState.new()
	gs.zones = Zone.create_standard_zones()
	for pid in player_ids:
		gs.players[pid] = PlayerState.make(pid)
	return gs


# ── Card accessors ─────────────────────────────────────────────────────────────
# Play zones are where cards can be exhausted, damaged, buffed, etc.
# Hand, deck, graveyard, and rfg are out-of-play zones for these purposes.
const PLAY_ZONE_TYPES := ["ally_row", "hero_row", "resource_row", "attached"]

func is_in_play(instance_id: String) -> bool:
	var card := get_card(instance_id)
	if not card:
		return false
	var zone := zones.get(card.zone_id) as Zone
	return zone != null and zone.zone_type in PLAY_ZONE_TYPES


func get_card(instance_id: String) -> CardInstance:
	return cards.get(instance_id) as CardInstance

func cards_in_zone(zone_id: String) -> Array[CardInstance]:
	var zone := zones.get(zone_id) as Zone
	if not zone:
		return []
	var result: Array[CardInstance] = []
	for cid in zone.card_ids:
		var c := get_card(cid)
		if c:
			result.append(c)
	return result

# All cards in play for a player: ally_row + hero_row + attachments they control.
# "Attached" is a positional zone, not an out-of-play zone — Cyclone attached to
# an ally is still in play and counts for "abilities in play" queries.
# Callers filter by card_type as needed; zone separation already ensures
# ally_row queries don't accidentally include abilities or attachments.
# Resource row is excluded — use cards_in_zone(player_id + "_resource_row") for that.
func cards_in_play(player_id: String) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	result.append_array(cards_in_zone(player_id + "_ally_row"))
	result.append_array(cards_in_zone(player_id + "_hero_row"))
	for card in cards_in_zone("attached"):
		if card.controller == player_id:
			result.append(card)
	return result

func get_hero(player_id: String) -> CardInstance:
	var ps := players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	return get_card(ps.hero_instance_id)

func get_attachments(host_instance_id: String) -> Array[CardInstance]:
	var host := get_card(host_instance_id)
	if not host:
		return []
	var result: Array[CardInstance] = []
	for aid in host.attachments:
		var a := get_card(aid)
		if a:
			result.append(a)
	return result


# ── Derived stat helpers ───────────────────────────────────────────────────────
# These require a CardDatabase reference to look up printed (base) stats.
# Passing db as a parameter keeps GameState free of Godot node dependencies
# and allows headless unit testing with a mock database.

func get_atk(instance_id: String, db, assume_attacking: bool = false) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	var is_attacking := assume_attacking or (instance_id != "" and instance_id == combat_attacker)
	# (1) Direct buffs placed on this card. Conditional buffs (e.g. "while
	# attacking", from Rayder / For the Horde!) only count when their gate is met.
	var atk := def.printed_atk
	for b in inst.active_buffs:
		if b.stat != "atk":
			continue
		if b.condition == "while_attacking" and not is_attacking:
			continue
		atk += b.amount
	# (1b) Attachments on this card (rule 400): Ongoing "Attached ally has
	# +A ATK" (Mark of the Wild). Live read — never cached.
	atk += _attachment_stat_mods(inst, db, 1)
	# (2) This card's own printed continuous self-modifiers.
	var is_weapon := false
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "atk_per_ally":
			var per_ally := int(parts[1]) if parts.size() > 1 else 1
			var ally_count := cards_in_zone(inst.controller + "_ally_row").size()
			atk += per_ally * ally_count
		elif parts[0] == "atk_per_damage_self":
			var per_damage := int(parts[1]) if parts.size() > 1 else 1
			atk += per_damage * inst.damage_taken
		elif parts[0] == "atk_vs_exhausted_defender":
			# Bala Silentblade: "+N ATK while attacking an exhausted hero or
			# ally." Live continuous modifier — only while this card is the
			# actual combat attacker AND the current defender is exhausted
			# (re-read at every get_atk, so a defender exhausted or readied
			# mid-combat changes the bonus immediately).
			if instance_id == combat_attacker and combat_defender != "":
				var dfd := get_card(combat_defender)
				if dfd and dfd.is_exhausted:
					atk += int(parts[1]) if parts.size() > 1 else 0
		elif parts[0] == "strike_cost":
			is_weapon = true
	# (2b) Elendril's flip: "Your Ranged weapons have +3 ATK this turn."
	# Player-tracked bonus (ranged_weapon_atk_bonus) applied to this player's
	# Ranged weapons. Reads live so a struck weapon's contribution reflects it.
	if is_weapon and def.dmg_type == "Ranged":
		var wps := players.get(inst.controller) as PlayerState
		if wps:
			atk += wps.ranged_weapon_atk_bonus
	# (3) Party auras granted by other cards in play (e.g. Zorm Stonefury).
	atk += _aura_atk_mods(inst, is_attacking, db)
	# (3b) Strike modifier (rule 303.2b): +X ATK per weapon associated with this
	# wielder for the current combat step. Live lookup — never cached.
	for weapon_id in combat_struck_weapons.get(instance_id, []):
		atk += get_atk(weapon_id, db)
	# (3c) "+N ATK this combat" grants (Berserking). Live lookup — never cached;
	# cleared with the combat step.
	atk += int(combat_atk_bonus.get(instance_id, 0))
	# (3d) Berserking, forecast half: an attacking hero WILL cash its berserk
	# counters in as +N ATK the moment the combat step starts, so show them here
	# too (attacker gate + attack cursor). No double-count once combat is real —
	# the trigger erases the counters as it fills combat_atk_bonus above.
	if is_attacking:
		var b_ps := players.get(inst.controller) as PlayerState
		if b_ps and b_ps.hero_instance_id == instance_id:
			atk += _pending_berserk_atk(inst.controller, db)
	# (4) Party-wide "while attacking this turn" grants (Rayder, For the
	# Horde!) — tracked per-player, not per-card, so they also cover allies
	# that entered play after the effect resolved. Card text is "allies", so
	# a hero attacking never gets these.
	if is_attacking:
		var zone := zones.get(inst.zone_id) as Zone
		var is_ally := zone != null and zone.zone_type == "ally_row"
		if is_ally:
			var ps := players.get(inst.controller) as PlayerState
			if ps:
				for grant in ps.party_atk_buffs_this_turn:
					var alignment: String = grant.get("alignment", "")
					if alignment != "" and def.alignment != alignment:
						continue
					atk += int(grant.get("amount", 0))
	# ATK floors at 0 — a character can't have negative ATK. Only the clamp is
	# applied here; the raw negative buff (Ravenous Bite's -3) stays on the card,
	# so a later +ATK effect counts from the true value, not from 0.
	return max(atk, 0)


# Preview helper: what would this card's ATK be if it were the combat attacker
# right now? Used by the UI to show the true damage number on the attack
# targeting cursor before propose_combat actually runs (rule 601 — a card isn't
# "attacking" until combat is proposed, so plain get_atk correctly omits
# "while attacking" bonuses like Zorm/Rayder/For the Horde! during target
# selection). Never use this for anything but display — it doesn't reflect
# real game state and must not influence rules decisions.
func get_atk_if_attacking(instance_id: String, db) -> int:
	return get_atk(instance_id, db, true)


# ATK this player's hero would gain from berserk counters sitting on their
# in-play Berserkings (`berserk_atk_on_hero_attack:N`) if it attacked right now.
func _pending_berserk_atk(player_id: String, db) -> int:
	if not db:
		return 0
	var bonus := 0
	for card in cards_in_zone(player_id + "_hero_row"):
		var count := int(card.counters.get("berserk", 0))
		if count <= 0:
			continue
		var def: CardDef = db.get_def(card.card_def_id)
		if not def or def.effects == "":
			continue
		for seg in def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0].strip_edges() == "berserk_atk_on_hero_attack":
				bonus += (int(p[1]) if p.size() > 1 else 1) * count
				break
	return bonus


# Sum of ATK bonuses this card receives from static "aura" sources in its
# controller's party — continuous modifiers that live on another card in play
# and affect a dynamic set, so they can't be pre-placed as buffs (the source may
# outlive, or predate, the cards it buffs). New party auras add a match arm here.
func _aura_atk_mods(inst: CardInstance, is_attacking: bool, db) -> int:
	var bonus := 0
	var def: CardDef = db.get_def(inst.card_def_id)
	var inst_zone := zones.get(inst.zone_id) as Zone
	var inst_is_ally := inst_zone != null and inst_zone.zone_type == "ally_row"
	for source in cards_in_zone(inst.controller + "_ally_row"):
		var src_def: CardDef = db.get_def(source.card_def_id)
		if not src_def:
			continue
		for seg in src_def.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"party_atk_while_attacking":
					# Zorm Stonefury: "+X ATK while attacking" to your allies
					# (including the source itself) — card text says "allies",
					# so a hero attacking (with or without a weapon) does NOT
					# get this bonus. Stacks with multiple copies.
					if is_attacking and inst_is_ally:
						bonus += int(p[1]) if p.size() > 1 else 1
	for source in cards_in_zone(inst.controller + "_hero_row"):
		var src_def2: CardDef = db.get_def(source.card_def_id)
		if not src_def2:
			continue
		for seg in src_def2.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"pet_atk_health_aura":
					# Master of the Hunt: "Ongoing: Your Pets have +X ATK and
					# +Y health." Lives in the hero row (rule 305.2c).
					if def and def.card_subtype == "Pet":
						bonus += int(p[1]) if p.size() > 1 else 0
				"hero_atk_while_attacking":
					# Cat Form: "Your hero is in cat form. (+1 ATK while
					# attacking.)" — the ongoing Form in the hero row grants the
					# HERO (only) +N while attacking. Defender-independent, so
					# it's safe inside assume_attacking forecasts and the
					# get_legal_attackers hero gate (unlike Bala's
					# atk_vs_exhausted_defender). Never cached.
					if is_attacking:
						var owner_ps := players.get(inst.controller) as PlayerState
						if owner_ps and owner_ps.hero_instance_id == inst.instance_id:
							bonus += int(p[1]) if p.size() > 1 else 1
	return bonus

func get_max_hp(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	var hp := def.printed_health + inst.sum_stat("health")
	hp += _aura_health_mods(inst, db)
	hp += _attachment_stat_mods(inst, db, 2)
	return max(hp, 0)


# Rule 503.2a max hand size, with live attachment modifiers: Arcane Intellect
# ("Ongoing: Attached hero's controller's maximum hand size is increased by
# three", `attached_max_hand:3`) raises it per copy attached to the player's
# hero. Live read — never cached.
func get_max_hand_size(player_id: String, db) -> int:
	var ps := players.get(player_id) as PlayerState
	var max_hand: int = ps.max_hand_size if ps else 7
	var hero := get_hero(player_id)
	if hero and db:
		for att_id in hero.attachments:
			var att := get_card(att_id)
			if not att or att.zone_id != "attached":
				continue
			var att_def: CardDef = db.get_def(att.card_def_id)
			if not att_def:
				continue
			for seg in att_def.effects.split("|"):
				var p := seg.split(":")
				if p[0] == "attached_max_hand" and p.size() > 1:
					max_hand += int(p[1])
	return max_hand


# Sum of one stat granted by this card's attachments' `attached_buff:ATK:HP`
# segments (rule 400 — Mark of the Wild). field: 1 = ATK, 2 = health.
# Live read on every stat query — never cached.
func _attachment_stat_mods(inst: CardInstance, db, field: int) -> int:
	var bonus := 0
	for att_id in inst.attachments:
		var att := get_card(att_id)
		if not att or att.zone_id != "attached":
			continue
		var att_def: CardDef = db.get_def(att.card_def_id)
		if not att_def:
			continue
		for seg in att_def.effects.split("|"):
			var p := seg.split(":")
			if p[0] == "attached_buff" and p.size() > field:
				bonus += int(p[field])
	return bonus

# Sum of max-health bonuses this card receives from static "aura" sources in
# its controller's party — continuous modifiers that live on another card in
# play and affect a dynamic set. New party health auras add a match arm here.
func _aura_health_mods(inst: CardInstance, db) -> int:
	var bonus := 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if def and def.card_type == "Hero":
		return bonus
	for source in cards_in_zone(inst.controller + "_ally_row"):
		if source.instance_id == inst.instance_id:
			continue
		var src_def: CardDef = db.get_def(source.card_def_id)
		if not src_def:
			continue
		for seg in src_def.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"party_health_aura":
					# Nerra Lifeboon: "Other allies in your party have +X health."
					# Only actual allies — never equipment, abilities, or totems
					# (which are ability cards) even if they sit in a party zone.
					if def and def.card_type == "Ally":
						bonus += int(p[1]) if p.size() > 1 else 1
	for source in cards_in_zone(inst.controller + "_hero_row"):
		var src_def2: CardDef = db.get_def(source.card_def_id)
		if not src_def2:
			continue
		for seg in src_def2.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"pet_atk_health_aura":
					# Master of the Hunt: "Ongoing: Your Pets have +X ATK and
					# +Y health." Lives in the hero row (rule 305.2c).
					if def and def.card_subtype == "Pet":
						bonus += int(p[2]) if p.size() > 2 else 0
	return bonus

func get_current_hp(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	return max(get_max_hp(instance_id, db) - inst.damage_taken, 0)

# Cost of playing a card from hand, after applying any cost-reduction buffs.
# For X-cost cards (Aimed Shot, cost "1+X") the announced X (action params
# "x_value") must be passed in — the printed cost alone is cost_base.
func get_play_cost(instance_id: String, db, x: int = 0) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	if def.cost_x:
		return max(def.cost_base + x + inst.sum_stat("cost"), 0)
	return max(def.cost + inst.sum_stat("cost"), 0)


# ── Resource helpers ───────────────────────────────────────────────────────────
# Available resources = ready (non-exhausted) cards in the player's resource row.
func get_available_resources(player_id: String) -> int:
	var count := 0
	for card in cards_in_zone(player_id + "_resource_row"):
		if not card.is_exhausted:
			count += 1
	return count

func get_total_resources(player_id: String) -> int:
	return cards_in_zone(player_id + "_resource_row").size()

# Face-up resources (quests/locations) retain their card identity and effects.
# Face-down resources are blank — no name, no type, no effect.
func get_face_up_resources(player_id: String) -> Array[CardInstance]:
	return cards_in_zone(player_id + "_resource_row").filter(
		func(c: CardInstance) -> bool: return not c.face_down)

# "For as many quests with that name" — count face-up resources sharing a def.
func count_face_up_resources_by_def(player_id: String, card_def_id: String) -> int:
	var count := 0
	for card in get_face_up_resources(player_id):
		if card.card_def_id == card_def_id:
			count += 1
	return count


# ── Serialization ──────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	var players_data: Dictionary = {}
	for pid in players:
		players_data[pid] = (players[pid] as PlayerState).to_dict()

	var zones_data: Dictionary = {}
	for zid in zones:
		zones_data[zid] = (zones[zid] as Zone).to_dict()

	var cards_data: Dictionary = {}
	for cid in cards:
		cards_data[cid] = (cards[cid] as CardInstance).to_dict()

	return {
		"players":           players_data,
		"zones":             zones_data,
		"cards":             cards_data,
		"token_counter":     token_counter,
		"turn_number":       turn_number,
		"turn_player":       turn_player,
		"phase":             phase,
		"priority_player":   priority_player,
		"pending_actions":   _serialize_pending_actions(),
		"consecutive_passes": consecutive_passes,
	}

static func from_dict(d: Dictionary) -> GameState:
	var gs := GameState.new()
	for pid in d.get("players", {}):
		gs.players[pid] = PlayerState.from_dict(d["players"][pid])
	for zid in d.get("zones", {}):
		gs.zones[zid] = Zone.from_dict(d["zones"][zid])
	for cid in d.get("cards", {}):
		gs.cards[cid] = CardInstance.from_dict(d["cards"][cid])
	gs.token_counter      = d.get("token_counter", 0)
	gs.turn_number        = d.get("turn_number", 0)
	gs.turn_player        = d.get("turn_player", "")
	gs.phase              = d.get("phase", "setup")
	gs.priority_player    = d.get("priority_player", "")
	gs.consecutive_passes = d.get("consecutive_passes", 0)
	for a in d.get("pending_actions", []):
		gs.pending_actions.append(PendingAction.from_dict(a))
	return gs


func _serialize_pending_actions() -> Array:
	var result: Array = []
	for a in pending_actions:
		result.append((a as PendingAction).to_dict())
	return result
