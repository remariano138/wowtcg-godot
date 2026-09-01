class_name TurnManager
extends RefCounted

# Phase sequencing for a 2-player WoW TCG game.
#
# Call start_game() once to begin. Thereafter, call advance_phase() each
# time a priority_window_closed event fires to move to the next phase.
#
# Phase order per turn:
#   ready  → draw → action → end → (next player's ready …)
#
# Priority windows:
#   ready / draw / end  → instants only (enforced by _can_play_non_instant phase check)
#   action              → full window (allies, instants, resources, combat)


# ── Public entry points ────────────────────────────────────────────────────────

static func start_game(state: GameState, first_player: String,
		db = null) -> Array[GameEvent]:
	state.turn_number  = 1
	state.turn_player  = first_player
	state.first_player = first_player
	return _enter_mulligan(state, db)


# Called by the scene once per player when they commit their mulligan decision.
# The player's own mulligan is executed IMMEDIATELY, so they see (and hear) their
# new hand on their own screen before the seat is handed over. The game itself
# only starts once every player has decided — see finish_mulligan_if_ready, which
# the caller runs after the deciding player has acknowledged their new hand.
static func commit_mulligan(state: GameState, player_id: String,
		wants_mulligan: bool, _db = null) -> Array[GameEvent]:
	if state.phase != "mulligan":
		return []
	state.mulligan_decided[player_id] = true
	state.mulligan_wants[player_id]   = wants_mulligan
	var events: Array[GameEvent] = [GameEvent.mulligan_committed(player_id, wants_mulligan)]
	if not wants_mulligan:
		return events

	# Two phases separated by mulligan_shuffle_done.
	# Phase 1: return this player's hand and shuffle their deck.
	var hand := state.cards_in_zone(player_id + "_hand").duplicate()
	for card in hand:
		events.append_array(GameLogic.move_card(state, card.instance_id, player_id + "_deck"))
	var deck := state.zones.get(player_id + "_deck") as Zone
	if deck:
		deck.card_ids.shuffle()
	# Marker: renderer uses this to pause before the draw phase fires.
	events.append(GameEvent.mulligan_shuffle_done())
	# Phase 2: always redraw exactly STARTING_HAND_SIZE cards (rule 103.4).
	for _i in GameManager.STARTING_HAND_SIZE:
		events.append_array(_draw_one(state, player_id))
	return events


# Ends the mulligan phase and starts turn 1 — but only once every player has
# committed. Safe (and a no-op) to call after every commit.
static func finish_mulligan_if_ready(state: GameState, db = null) -> Array[GameEvent]:
	if state.phase != "mulligan":
		return []
	for pid in state.players:
		if not state.mulligan_decided.get(pid, false):
			return []
	var events: Array[GameEvent] = [GameEvent.mulligan_phase_ended()]
	events.append_array(_enter_ready(state, db))
	return events


static func advance_phase(state: GameState, db = null) -> Array[GameEvent]:
	match state.phase:
		"ready":  return _enter_draw(state, db)
		"draw":   return _enter_action(state, db)
		"action": return _enter_end(state, db)
		"end":    return _next_turn(state, db)
	return []


# ── Mulligan phase ─────────────────────────────────────────────────────────────

static func _enter_mulligan(state: GameState, _db) -> Array[GameEvent]:
	state.phase           = "mulligan"
	state.mulligan_decided = {}
	state.mulligan_wants   = {}
	# Player order: first player decides first, then opponents clockwise (2-player: just the two).
	var order: Array = [state.first_player]
	for pid in state.players:
		if pid != state.first_player:
			order.append(pid)
	return [GameEvent.mulligan_phase_started(state.first_player, order)]


# ── Phase transitions ──────────────────────────────────────────────────────────

static func _enter_ready(state: GameState, db) -> Array[GameEvent]:
	state.phase = "ready"
	var events: Array[GameEvent] = [GameEvent.turn_changed(state.turn_number, state.turn_player)]

	# Reset once-per-turn flags.
	# The turn event log (turn-history conditions — Thysta, Torek's Assault)
	# starts clean each turn: "this turn" means "in the log". The end-phase
	# triggers read it before this next reset.
	state.turn_events.clear()
	# The ally-damage watchers' cursor indexes into that log, so it resets with it.
	state.damage_watch_index = 0
	state.ally_destroy_watch_index = 0
	state.destroy_discard_marks.clear()   # Shadow Bolt: "…destroyed THIS TURN"
	# Brain Freeze's "players can't draw cards THIS TURN" likewise. Cleared
	# before the draw step below, so a lock set on the previous turn never
	# swallows this turn's 501.2a draw.
	state.draws_locked_this_turn = false
	var ps := state.players.get(state.turn_player) as PlayerState
	if ps:
		ps.resource_placed_this_turn = false
		# has_used_hero_power intentionally NOT reset here — using the hero power
		# "flips" the hero for the rest of the game; it cannot be reused.

	# Safety: leftover armor block never survives into a new turn (rule 304.3
	# block is scoped to the window/combat it was declared in).
	for pid in state.players:
		var p := state.players[pid] as PlayerState
		if p:
			p.damage_prevention = 0
			p.party_atk_buffs_this_turn.clear()
			# "This turn" strike discount (Gorebelly) never survives into a new turn.
			p.melee_strike_discount = 0
			# Elendril's "+3 ATK to Ranged weapons this turn" likewise expires.
			p.ranged_weapon_atk_bonus = 0
			# Heroic Strike's "+3 ATK to your weapons this turn" likewise.
			p.weapon_atk_bonus_this_turn = 0
			# Rapid Fire's "whenever you strike ... this turn" grant likewise.
			p.rapid_fire_ready_cost = -1
			# Cold Blood's "when your hero deals damage to an ally this turn"
			# grant likewise — and its index would be meaningless anyway once
			# turn_events is cleared above.
			p.cold_blood_from_index = -1
			# Operation Recombobulation's "when an opposing non-token ally is
			# destroyed this turn" grant — same shape, same reason.
			p.recomb_from_index = -1
			# Nature's Swiftness' "next card this turn" discount likewise — an
			# unused discount expires with the turn it was gained in.
			p.next_card_cost_mod = 0

	# Clear summoning sickness and ready all in-play cards for the turn player.
	for card in state.cards_in_play(state.turn_player):
		card.just_summoned = false
		var blocked := _ready_blocked(state, card, db)
		# Gouge's one-shot lock is consumed at the controller's ready step,
		# whether or not something else also blocked the ready this turn.
		card.counters.erase("gouge_skip_ready")
		if blocked:
			continue
		# Helwen: "You may choose not to ready Helwen during your ready step."
		# Leave it exhausted and queue the choice — the DEFAULT is staying
		# exhausted, so nothing is lost if the step is interrupted, and the
		# borrowed-control link she may be holding survives until the controller
		# actually says "ready". Only an exhausted card poses the question:
		# readying a ready one is a no-op nobody needs to be asked about.
		if card.is_exhausted and _may_stay_exhausted(state, card, db):
			if card.instance_id not in state.pending_ready_choice_ids:
				state.pending_ready_choice_ids.append(card.instance_id)
			continue
		events.append_array(GameLogic.ready_card(state, card.instance_id))
	for card in state.cards_in_zone(state.turn_player + "_resource_row"):
		events.append_array(GameLogic.ready_card(state, card.instance_id))

	# Reset once-per-turn power gates for every in-play card (both players' —
	# these powers aren't turn-restricted, e.g. Deacon Johanna).
	for pid in state.players:
		for card in state.cards_in_play(pid):
			card.used_this_turn = false
			# "attacks for the first time each turn" trigger gate (Windseer Tarus /
			# Windfury Totem).
			card.counters.erase("attacked_this_turn")
			# "strike with attached weapon for the first time each turn" gate
			# (Windfury Weapon).
			card.counters.erase("windfury_struck_this_turn")
			# "deals combat damage with [this weapon] for the first time on each
			# of your turns" gate (Thrash Blade).
			card.counters.erase("weapon_dmg_readied_this_turn")

	# Rule 500.2 / 501.1a: start-of-turn powers TRIGGER here, but a triggered
	# effect is not resolved here — it is added to the chain during PPP (410.5 /
	# 708.1), so every one of them is respondable. Collect them all into one
	# ordered queue; nothing fires yet.
	_collect_turn_start_triggers(state, db)

	# Helwen's optional-ready choices, opened one at a time. can_submit and
	# pass_priority are hard-blocked while one is pending, so the window below
	# opens but the game waits here until the controller answers.
	if not state.pending_ready_choice_ids.is_empty():
		state.pending_ready_choice_player = state.turn_player
		events.append(GameEvent.ready_choice_opened(
			state.turn_player, state.pending_ready_choice_ids[0]))

	events.append(GameEvent.make("phase_changed", {
		"phase": "ready", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)

	# PPP: announce the first queued trigger onto the chain (picking its targets
	# first, 707.1d). The rest wait — each one fires only once the chain has
	# emptied again, from pass_priority's window-close branch. See
	# StackResolver.advance_turn_start_triggers.
	events.append_array(StackResolver.advance_turn_start_triggers(state, db))
	return events


# Helwen: "You may choose not to ready [this] during your ready step."
static func _may_stay_exhausted(state: GameState, card: CardInstance, db) -> bool:
	if not db:
		return false
	var def := state.effective_def(card.instance_id, db)
	return def != null and StackResolver._has_effect_flag(def, "may_stay_exhausted")


static func _enter_draw(state: GameState, _db) -> Array[GameEvent]:
	state.phase = "draw"
	var events: Array[GameEvent] = []
	# Rule 501.2b: first player skips the draw step on the very first turn.
	var is_first_turn_first_player: bool = (state.turn_number == 1 and state.turn_player == state.first_player)
	if not is_first_turn_first_player:
		events.append_array(_draw_one(state, state.turn_player))
	events.append(GameEvent.make("phase_changed", {
		"phase": "draw", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)
	return events


static func _enter_action(state: GameState, _db) -> Array[GameEvent]:
	state.phase = "action"
	var events: Array[GameEvent] = []
	events.append(GameEvent.make("phase_changed", {
		"phase": "action", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)
	return events


static func _enter_end(state: GameState, db) -> Array[GameEvent]:
	state.phase = "end"
	var events: Array[GameEvent] = []

	# Triggered effects: "at the end of your turn" (only the turn player's chars).
	for card in state.cards_in_play(state.turn_player):
		events.append_array(_apply_end_of_turn_effects(state, card, db))

	# "At the end of EACH player's turn" triggers (Thysta Spiritlasher) fire on
	# both turns, so they need their own sweep over every player's cards — the
	# scan above is deliberately scoped to the turn player and must stay that
	# way for "at the end of YOUR turn" (Infernal).
	# The "no damage was dealt this turn" condition is sampled ONCE, here: these
	# triggers all trigger simultaneously, so two Thystas both see the clean
	# turn and both fire. Re-reading it per card would let the first one's own
	# damage suppress the second — and would be unreliable anyway, since
	# defer_packets can hold the damage behind an armor prevention point.
	var none_dealt := not state.has_turn_event("damage_dealt")
	for pid in state.players:
		for card in state.cards_in_play(pid):
			events.append_array(_apply_each_turn_end_effects(state, card, db, none_dealt))

	# Expire "this turn" buffs (duration_type == "turns"). Sweep every card in
	# play for both players — a "this turn" modifier ends at end of turn no
	# matter whose card it sits on.
	for pid in state.players:
		for card in state.cards_in_play(pid):
			card.decrement_turn_buffs()

	events.append(GameEvent.make("phase_changed", {
		"phase": "end", "turn_player": state.turn_player,
		"turn_number": state.turn_number,
	}))
	_open_window(state)
	return events


static func _next_turn(state: GameState, db) -> Array[GameEvent]:
	# Rule 503.2a: wrap-up step — discard to max hand size before turn advances.
	var outgoing := state.turn_player
	var hand_count := state.cards_in_zone(outgoing + "_hand").size()
	var max_hand := state.get_max_hand_size(outgoing, db)
	var excess := hand_count - max_hand
	if excess > 0:
		state.pending_discard_player = outgoing
		state.pending_discard_count  = excess
		# Phase stays "end" — scene handles discards then calls advance_phase("end") again.
		return [GameEvent.discard_choice_opened(outgoing, excess, "wrap_up")]

	state.turn_number += 1
	for pid in state.players:
		if pid != state.turn_player:
			state.turn_player = pid
			break
	return _enter_ready(state, db)


# ── Helpers ────────────────────────────────────────────────────────────────────

# Public probe for the UI (playtest ready-lock badge): would this card be
# skipped by its controller's next ready step? Same live read as the ready step.
static func is_ready_blocked(state: GameState, card: CardInstance, db) -> bool:
	return _ready_blocked(state, card, db)


# Entangling Roots: a card hosting an attachment with `attached_cannot_ready`
# ("Attached ally can't ready during its controller's ready step") skips the
# ready step. Only the ready STEP is blocked — explicit ready effects
# (e.g. ready_self_at_turn_end) still work. Live read — never cached.
static func _ready_blocked(state: GameState, card: CardInstance, db) -> bool:
	if not db:
		return false
	# Gouge: "It can't ready during its controller's next ready step." One-shot
	# flag set at resolution; consumed in _enter_ready at that ready step. Live
	# read here (drives the ⛓ badge probe) — consumption is done in _enter_ready.
	if card.counters.has("gouge_skip_ready"):
		return true
	# Earthbind Totem: "Opposing allies can't ready during their controllers'
	# ready step." Static aura — live scan of every opponent's in-play cards.
	# Only allies (ally_row cards, totems included) are locked; heroes, equipment
	# and resources ready normally.
	if card.zone_id == card.controller + "_ally_row":
		for pid in state.players:
			if pid == card.controller:
				continue
			for aura_card in state.cards_in_play(pid):
				var aura_def := state.effective_def(aura_card.instance_id, db)
				if not aura_def:
					continue
				for aura_seg in aura_def.effects.split("|"):
					if aura_seg.strip_edges() == "opposing_allies_cant_ready":
						return true
	for att_id in card.attachments:
		var att := state.get_card(att_id)
		if not att or att.zone_id != "attached":
			continue
		var att_def := db.get_def(att.card_def_id) as CardDef
		if not att_def:
			continue
		for seg in att_def.effects.split("|"):
			if seg.strip_edges() == "attached_cannot_ready":
				return true
	return false


static func _open_window(state: GameState) -> void:
	state.priority_player    = state.turn_player
	state.consecutive_passes = 0


# ── Start-of-turn trigger collection (rule 501.1a / 500.2 / 708.1a) ───────────
# Effects segments that trigger "at the start of EACH player's turn" — collected
# from every player's in-play cards, on every turn.
const EACH_TURN_TRIGGERS := [
	"heal_party_each_turn",        # Healing Stream Totem
	"heal_at_each_turn_start",     # plain self-heal, either turn
	"ongoing_damage_each_turn",    # Searing Totem
]
# Effects segments that trigger "at the start of YOUR turn" — collected only
# from the turn player's in-play cards.
const YOUR_TURN_TRIGGERS := [
	"heal_party_at_turn_start",         # Wazzuli Wildmender
	"heal_at_turn_start",               # plain self-heal
	"attached_damage_turn_start",       # Fireball
	"turn_start_heal_hero_and_pets",    # Spirit Bond
	"rfg_self_next_turn",               # Tooga
	"turn_start_discard_or_give_control",  # Infernal
	"turn_start_look_top_card",         # Track Humanoids
	"turn_start_pay_or_destroy",        # Rain of Fire (upkeep, paid in resources)
	"turn_start_discard_or_destroy",    # Last Stand (upkeep, paid in cards)
	"turn_start_destroy_self_damage_opposing",  # Fire Nova Totem
	"turn_start_destroy_self",          # Shadowmeld (plain self-destroy, no rider)
	"turn_start_remove_counter_destroy", # Cyclone (counter countdown, then self-destroy)
]
# Effects segments that trigger "at the start of YOUR turn" while the card is in
# that player's GRAVEYARD — rule 703.3a: "a card's power that can trigger only
# while that card is in a non-play zone is active only while that card is
# revealed in that zone", an explicit exception to 703.3's face-up-in-play rule.
# These are collected from the turn player's graveyard instead of from the board,
# which is the ONLY difference; everything downstream (the chain link, the
# response window, 707.3) is shared with the in-play triggers.
#
# Keep this list disjoint from the two above: membership is what decides which
# ZONE a trigger's source is looked for in, both here and in the
# still-active re-check at announcement (StackResolver._trigger_source_active).
const GRAVEYARD_TURN_TRIGGERS := [
	"graveyard_turn_start_pay_to_hand",  # Wisp
]


# Build the queue of this ready step's triggered effects. Nothing fires and
# nothing goes on the chain here — 500.2: the powers trigger as the step starts,
# but the effects are added to the chain during PPP.
#
# The queue is grouped by player in 708.1a order — the turn player's triggers
# first, then the opponent's — because that is the order they are ADDED to the
# chain. The chain being LIFO, the opponent's therefore RESOLVE first, which is
# the rulebook's own Voss/Donna example. Order WITHIN a player is not decided
# here: 708.1a gives that player the choice, and StackResolver asks him for it as
# the triggers go on (see pending_trigger_order_player), so board order here is
# only the order the candidates are offered in.
#
# Two zones are scanned per player: the board (703.3), and — for the turn player
# only, since every key on the list is a "your turn" one — his graveyard, for
# the powers 703.3a keeps active there (Wisp).
static func _collect_turn_start_triggers(state: GameState, db) -> void:
	state.pending_turn_start_triggers.clear()
	if not db:
		return
	var ordered_pids: Array = [state.turn_player]
	for pid in state.players:
		if pid != state.turn_player:
			ordered_pids.append(pid)
	for pid in ordered_pids:
		var is_turn_player: bool = (pid == state.turn_player)
		for card in state.cards_in_play(pid):
			_collect_from_card(state, card, is_turn_player, false, db)
		# 703.3a: powers that function from the graveyard. Only the turn player's
		# is scanned — every GRAVEYARD_TURN_TRIGGERS key is "at the start of YOUR
		# turn" — and the def is read from the DATABASE rather than through
		# effective_def, which answers about cards in play (700.3's blanking is a
		# modifier on an in-play card; a card in a graveyard has no such state).
		if is_turn_player:
			for card in state.cards_in_zone(pid + "_graveyard"):
				_collect_from_card(state, card, true, true, db)


# Scan one card's effects for start-of-turn trigger segments and queue what
# fires. `in_graveyard` selects which key list applies, so an in-play card can
# never fire a graveyard power and vice versa.
static func _collect_from_card(state: GameState, card: CardInstance,
		is_turn_player: bool, in_graveyard: bool, db) -> void:
	var def: CardDef = null
	if in_graveyard:
		def = db.get_def(card.card_def_id) as CardDef
	else:
		def = state.effective_def(card.instance_id, db)
	if not def or def.effects == "":
		return
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		var key := parts[0].strip_edges()
		var fires := false
		if in_graveyard:
			fires = GRAVEYARD_TURN_TRIGGERS.has(key)
		else:
			fires = EACH_TURN_TRIGGERS.has(key) \
				or (is_turn_player and YOUR_TURN_TRIGGERS.has(key))
		if not fires:
			continue
		var args: Array = []
		for i in range(1, parts.size()):
			args.append(parts[i].strip_edges())
		if not _heal_trigger_has_work(state, card, key, db):
			continue
		# A card in a graveyard has no controller — 401.2, it is only ever in its
		# OWNER's graveyard (415.2), and "your turn"/"your graveyard" both mean
		# that owner. An in-play card's controller can differ from its owner
		# (Infernal, Helwen), so the two cases genuinely need different reads.
		state.pending_turn_start_triggers.append({
			"card_id":    card.instance_id,
			"controller": card.owner if in_graveyard else card.controller,
			"key":        key,
			"args":       args,
			"zone":       "graveyard" if in_graveyard else "play",
		})


# Pure-heal turn-start triggers are SKIPPED when nothing in their scope carries
# damage. A heal on an undamaged target does literally nothing (GameLogic.heal
# no-ops and emits no event), so putting the trigger on the chain would only ask
# both players to pass through a link that cannot change the game state.
# Deviation from 500.2/708.1 in favour of fluid play — see
# data/rules_deviations.md "Empty heal triggers".
# Note this is judged as the queue is built, so a heal is not queued on account
# of damage another trigger deals later in the SAME ready step (Searing Totem
# pinging the would-be heal target). Every other key is always queued.
static func _heal_trigger_has_work(state: GameState, card: CardInstance, key: String, db) -> bool:
	match key:
		"heal_at_turn_start", "heal_at_each_turn_start":
			return card.damage_taken > 0
		"heal_party_each_turn", "heal_party_at_turn_start":
			return _party_has_damage(state, card.controller)
		"turn_start_heal_hero_and_pets":
			# Spirit Bond: no Pet → the trigger does nothing at all either.
			var any_pet := false
			var damaged := false
			for ally in state.cards_in_zone(card.controller + "_ally_row"):
				var adef := db.get_def(ally.card_def_id) as CardDef if db else null
				if adef and adef.card_subtype == "Pet":
					any_pet = true
					if ally.damage_taken > 0:
						damaged = true
			if not any_pet:
				return false
			var sb_hero := state.get_hero(card.controller)
			return damaged or (sb_hero != null and sb_hero.damage_taken > 0)
		_:
			return true


static func _party_has_damage(state: GameState, pid: String) -> bool:
	for ally in state.cards_in_zone(pid + "_ally_row"):
		if ally.damage_taken > 0:
			return true
	var hero := state.get_hero(pid)
	return hero != null and hero.damage_taken > 0


# Parse the effects string and fire any end-of-turn triggers.
static func _apply_end_of_turn_effects(state: GameState, card: CardInstance, db) -> Array[GameEvent]:
	if not db:
		return []
	var def := state.effective_def(card.instance_id, db)
	if not def or def.effects == "":
		return []
	var events: Array[GameEvent] = []
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		match parts[0].strip_edges():
			"ready_self_at_turn_end":
				events.append_array(GameLogic.ready_card(state, card.instance_id))
			"end_of_turn_damage_opposing":
				# Infernal: "At the end of your turn, [this] deals AMOUNT DMG_TYPE
				# damage to each opposing hero and ally."
				# Packets go through the prevention machinery (rule 717.2c) —
				# the opposing hero's controller may exhaust DEF armor first.
				# The end-phase priority window that follows is hard-blocked
				# until the point resolves, so nothing advances early.
				var amount := int(parts[1]) if parts.size() > 1 else 1
				var opp := ""
				for pid in state.players:
					if pid != card.controller:
						opp = pid
						break
				if opp == "":
					continue
				var packets: Array = []
				for target in state.cards_in_zone(opp + "_ally_row").duplicate():
					packets.append({"source": card.instance_id,
						"target": target.instance_id, "amount": amount})
				var opp_hero := state.get_hero(opp)
				if opp_hero:
					packets.append({"source": card.instance_id,
						"target": opp_hero.instance_id, "amount": amount})
				events.append_array(StackResolver.defer_packets(state, db, packets))
			"end_of_turn_hero_damage_opposing":
				# Rain of Fire: "At the end of your turn, YOUR HERO deals AMOUNT
				# DMG_TYPE damage to each opposing hero and ally."
				#
				# Infernal's arm above with the source changed, and the source is
				# the whole difference between the two keys. Here the packets come
				# from the controller's HERO, so they are tagged `from_ability`
				# (this is an in-play Ability dealing the damage — the same call as
				# Fireball's ongoing turn-start burn), which means Chromatic Cloak's
				# +1 applies; and they carry the printed dmg_type, so a fire version
				# also doubles under World in Flames. Infernal's packets are dealt
				# by the ALLY and get neither.
				#
				# The board is read HERE, at the end phase, so an ally that arrived
				# this turn is hit and one that left is not. Rule 703.3 needs no
				# code: the sweep only visits cards_in_play, so a Rain of Fire
				# already destroyed this turn — by its own unpaid upkeep, among
				# other things — never burns.
				var hero_amount := int(parts[1]) if parts.size() > 1 else 1
				var hero_type := parts[2].strip_edges() if parts.size() > 2 else ""
				var own_hero := state.get_hero(card.controller)
				if not own_hero:
					continue
				var foe := ""
				for pid in state.players:
					if pid != card.controller:
						foe = pid
						break
				if foe == "":
					continue
				# Packets go through defer_packets, so the opposing hero's
				# controller gets the armor prevention point (717.2c) in a fixed
				# order — allies first, then their hero.
				var hero_packets: Array = []
				for target in state.cards_in_zone(foe + "_ally_row").duplicate():
					hero_packets.append({
						"source": own_hero.instance_id,
						"target": target.instance_id,
						"amount": hero_amount, "dmg_type": hero_type,
						"from_ability": true,
					})
				var foe_hero := state.get_hero(foe)
				if foe_hero:
					hero_packets.append({
						"source": own_hero.instance_id,
						"target": foe_hero.instance_id,
						"amount": hero_amount, "dmg_type": hero_type,
						"from_ability": true,
					})
				events.append_array(StackResolver.defer_packets(state, db, hero_packets))
			"end_of_turn_destroy_if_no_damage_dealt":
				# Outrider Zarg: "At the end of your turn, if [this] dealt no damage
				# this turn, destroy him." Venomstrike's victim list inverted: the
				# condition is turn HISTORY, read off the turn event log's
				# `damage_dealt` entries filtered to this card as source — so combat
				# damage, ability/power damage and any future way it deals damage
				# all satisfy it by construction. Damage absorbed in full by
				# prevention is not damage DEALT (717.2b) and does not save him.
				#
				# "At the end of YOUR turn", so this arm lives in the turn-player
				# sweep: an attack made on the opponent's turn cannot save him, and
				# his controller's own turn is the only one that judges him.
				# Rule 703.3 needs no code: the sweep only visits cards_in_play, so
				# a Zarg already gone this turn is never asked.
				var dealt := false
				for log_entry in state.turn_events_of("damage_dealt"):
					if String(log_entry.get("source_id", "")) == card.instance_id:
						dealt = true
						break
				if not dealt:
					# Mandatory, free, no cost, no choice, no target — resolves
					# inline rather than on the chain (same deviation as Thysta /
					# Venomstrike, see data/rules_deviations.md "Outrider Zarg").
					# Through _destroy_card_trigger so on_destroyed triggers and the
					# `ally_destroyed` turn-log entry behave as for any destruction.
					events.append_array(StackResolver._destroy_card_trigger(
						state, card.instance_id, card.instance_id, db))
	return events


# "At the end of each player's turn" triggers — fired for EVERY player's cards
# (see the sweep in _enter_end), not just the turn player's.
static func _apply_each_turn_end_effects(state: GameState, card: CardInstance, db,
		none_dealt: bool) -> Array[GameEvent]:
	if not db:
		return []
	var def := state.effective_def(card.instance_id, db)
	if not def or def.effects == "":
		return []
	var events: Array[GameEvent] = []
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		match parts[0].strip_edges():
			"end_of_turn_damage_hero_if_none_dealt":
				# Thysta Spiritlasher: "At the end of each player's turn, if no
				# damage was dealt this turn, [this] deals AMOUNT DMG_TYPE damage
				# to that player's hero."
				# "That player" is the player whose turn is ending — the TURN
				# PLAYER, whoever controls Thysta. On her controller's own idle
				# turn she burns their hero: the clock is symmetric.
				if not none_dealt:
					continue
				var amount := int(parts[1]) if parts.size() > 1 else 1
				var dmg_type := parts[2].strip_edges() if parts.size() > 2 else ""
				var hero := state.get_hero(state.turn_player)
				if not hero:
					continue
				# Through defer_packets like every other damage source, so the
				# hero's controller gets the armor prevention point (717.2c).
				events.append_array(StackResolver.defer_packets(state, db, [{
					"source": card.instance_id,
					"target": hero.instance_id,
					"amount": amount,
					"dmg_type": dmg_type,
				}]))
			"end_of_turn_create_token":
				# King Magni Bronzebeard: "At the end of each turn, put an
				# Alliance Dwarf Warrior ally token with 1 ATK and 1 health into
				# play." Mya's on_enter token creation moved onto the each-turn
				# end sweep — "each turn", so it lives HERE and not in the
				# turn-player-scoped _apply_end_of_turn_effects: it must tick on
				# the OPPONENT's turn too, which is what makes it two bodies a
				# round rather than one.
				#
				# The token enters the SOURCE's controller's party ("into play",
				# with no other player named), through _put_token_into_play →
				# _bring_ally_into_play like any other entry — so summoning
				# sickness, the uniqueness queue and the opposing-ally-enters
				# watchers (Stone Guard Rashun) all apply. It arrives during the
				# END phase, so it is summoning-sick either way and can attack on
				# its controller's next turn.
				#
				# Rule 703.3 needs no code: this sweep only visits cards_in_play,
				# so a Magni destroyed earlier in the turn makes nothing.
				# Mandatory, free, no target and no choice, so it resolves inline
				# rather than on the chain, like every other end-of-turn trigger
				# (see data/rules_deviations.md).
				var token_def: String = parts[1].strip_edges() if parts.size() > 1 else ""
				var token_count: int = int(parts[2]) if parts.size() > 2 else 1
				if token_def == "" or token_count <= 0:
					continue
				events.append_array(StackResolver.put_token_into_play(
					state, card.controller, token_def, token_count, db))
			"attached_heal_turn_end":
				# Primal Mending: "Ongoing: At the end of each turn, your hero
				# heals N damage from attached ally." Fireball's
				# attached_damage_turn_start with both halves inverted — a heal
				# rather than a burn, and at the END of EACH turn rather than the
				# start of the controller's own. That is why it lives in this
				# sweep and not in the YOUR_TURN_TRIGGERS queue: an "each turn"
				# trigger placed in the turn-player-scoped sweep would silently
				# skip the opponent's turn, and the whole point of this card is
				# that it ticks twice per round.
				#
				# "Your hero" is the ATTACHMENT's controller's hero — the healer
				# — and the target is whatever it is attached to, which may be an
				# opposing ally (the attach text says simply "target ally"). Both
				# are read live, so the trigger simply doesn't fire once the
				# attachment is gone: the sweep only visits cards_in_play, and
				# 400.5 already destroyed it with any host that left play.
				#
				# The heal lands inline (nothing to prevent) and no-ops on an
				# undamaged host. Resolves inline rather than on the chain, like
				# every other end-of-turn trigger — mandatory, free, no target,
				# no choice (see data/rules_deviations.md).
				if card.attached_to == "":
					continue
				var heal_amt := int(parts[1]) if parts.size() > 1 else 1
				var heal_host := state.get_card(card.attached_to)
				var heal_hero := state.get_hero(card.controller)
				if heal_amt <= 0 or not heal_host or not heal_hero:
					continue
				events.append_array(GameLogic.heal(
					state, heal_host.instance_id, heal_amt, db,
					heal_hero.instance_id))
			"end_of_turn_damage_own_victims":
				# Venomstrike: "At the end of each turn, [this] deals AMOUNT
				# DMG_TYPE damage to each hero and ally it dealt damage to this
				# turn." The victim list is turn HISTORY, read off the turn event
				# log's `damage_dealt` entries filtered to this card as source —
				# so it covers combat damage, ability/power damage and any future
				# way it deals damage, by construction.
				#
				# Rule 703.3 needs no code here: the sweep above only visits
				# cards_in_play, so a Venomstrike that died earlier this turn
				# never reaches this arm and burns nothing. (Killing him in the
				# response window AFTER this has gone out is a different matter —
				# by then the packets exist independently of him, 707.3.)
				var amount := int(parts[1]) if parts.size() > 1 else 1
				var dmg_type := parts[2].strip_edges() if parts.size() > 2 else ""
				var packets: Array = []
				var seen := {}
				for log_entry in state.turn_events_of("damage_dealt"):
					if String(log_entry.get("source_id", "")) != card.instance_id:
						continue
					var victim := String(log_entry.get("target_id", ""))
					if victim == "" or seen.has(victim):
						continue
					seen[victim] = true
					# 408.2b: no packet is created for a character no longer in
					# play — an ally he killed in combat isn't burned again.
					if not state.is_in_play(victim):
						continue
					packets.append({
						"source": card.instance_id,
						"target": victim,
						"amount": amount,
						"dmg_type": dmg_type,
					})
				# One deferred group, so several victims' armor prevention
				# offers open in a fixed order (first damaged first).
				if not packets.is_empty():
					events.append_array(StackResolver.defer_packets(state, db, packets))
	return events


static func _draw_one(state: GameState, player_id: String) -> Array[GameEvent]:
	# Decked rule (410.6b/102.1a) lives in the primitive — see GameLogic.draw_one.
	return GameLogic.draw_one(state, player_id)
