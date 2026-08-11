class_name GameLogic
extends RefCounted

# Primitive rules functions. Every function:
#   - Takes GameState (mutated in place) plus action-specific args
#   - Returns Array[GameEvent] describing exactly what changed
#   - Never touches Godot nodes, autoloads, or the event bus
#   - Calls other primitives and folds their events in with append_array
#
# The caller (stack resolver) is responsible for emitting the returned events.
# See CLAUDE.md — architecture invariants.


# ── create_token ───────────────────────────────────────────────────────────────
# Register a brand-new token CardInstance and return its instance_id (or "" if
# the def is unknown / isn't a token). The instance starts in NO zone — the
# caller puts it into play (StackResolver._put_token_into_play), which is what
# fires its enter-play triggers and uniqueness checks.
#
# The token has no deck of origin, so `owner` is set to the player whose effect
# created it: party, graveyard-side and control-change logic all key off owner
# and controller, and a later control change (Infernal) moves it without
# changing owner, exactly like any other card.
static func create_token(state: GameState, controller: String,
		token_def_id: String, db) -> String:
	if not db:
		return ""
	var def := db.get_def(token_def_id) as CardDef
	if not def or not def.is_token:
		push_warning("create_token: '%s' is not a known token def" % token_def_id)
		return ""
	state.token_counter += 1
	var inst_id := "%s_token_%d" % [controller, state.token_counter]
	var inst := CardInstance.create(inst_id, token_def_id, controller, "")
	inst.is_token       = true
	inst.created_on_turn = state.turn_number
	state.cards[inst_id] = inst
	return inst_id


# ── move_card ──────────────────────────────────────────────────────────────────
# Move a card from one zone to another. All zone changes go through here —
# never mutate zone.card_ids or card.zone_id directly elsewhere.
#
# Handles attachment bookkeeping: if the card is currently an attachment,
# removes it from its host's attachments list. If it's moving TO "attached",
# the caller is responsible for setting card.attached_to and adding the
# instance_id to the new host's attachments list before calling this.
# (Attachment setup is intentionally kept in the caller so move_card stays
# a generic primitive with no knowledge of attachment semantics.)
#
# Also handles graveyard entry: cards entering the graveyard are readied
# (damage tokens removed, exhausted state cleared) per WoW TCG rules.
static func move_card(state: GameState, card_id: String, to_zone_id: String) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card:
		return []

	var events: Array[GameEvent] = []
	var from_zone_id := card.zone_id

	# A token that leaves play ceases to exist — it never reaches a graveyard, a
	# hand or a deck, whatever sent it there (destroyed, bounced by Withdraw,
	# discarded). Redirecting here rather than at each removal effect means the
	# rule holds by construction for every present and future one.
	#
	# This is purely a change of DESTINATION: a destroy still emits
	# card_destroyed before calling move_card, so "when [this] is destroyed" and
	# "when an ally is destroyed" triggers fire on tokens exactly as on real
	# cards (see GameLogic.destroy_card / StackResolver._destroy_card_trigger).
	#
	# The instance stays in state.cards rather than being deleted — the RFG zone
	# is the void here (nothing in the engine reads it as a resource), and
	# keeping it means the renderer can animate it away and no stale instance_id
	# reference can crash a lookup.
	if card.is_token:
		var was_in_play := state.is_in_play(card_id)
		var dest_zone := state.zones.get(to_zone_id) as Zone
		var goes_to_play: bool = dest_zone != null \
			and dest_zone.zone_type in GameState.PLAY_ZONE_TYPES
		if was_in_play and not goes_to_play:
			to_zone_id = card.owner + "_rfg"

	# If leaving an attachment relationship, clean up the host's list.
	if card.attached_to != "" and to_zone_id != "attached":
		var host := state.get_card(card.attached_to)
		if host:
			host.attachments.erase(card_id)
		card.attached_to = ""

	# Remove from source zone.
	var from_zone := state.zones.get(from_zone_id) as Zone
	if from_zone:
		from_zone.card_ids.erase(card_id)

	# Add to destination zone.
	var to_zone := state.zones.get(to_zone_id) as Zone
	if to_zone:
		to_zone.card_ids.append(card_id)
	card.zone_id = to_zone_id

	events.append(GameEvent.card_moved(card_id, from_zone_id, to_zone_id))

	# Rule 400.5 / 410.6c: a host leaving play takes its attachments with it —
	# each attachment is destroyed by the game (moves within play, e.g. a
	# control change to the other ally_row, keep attachments attached).
	if not card.attachments.is_empty():
		var new_zone := state.zones.get(to_zone_id) as Zone
		if new_zone == null or not (new_zone.zone_type in GameState.PLAY_ZONE_TYPES):
			for att_id in card.attachments.duplicate():
				var att := state.get_card(att_id)
				if att:
					_record_ally_destroyed(state, att_id)
					events.append(GameEvent.card_destroyed(att_id, card_id))
					events.append_array(move_card(state, att_id, att.owner + "_graveyard"))
			card.attachments.clear()

	# Cards leaving play (rule 400.6a — to a graveyard, a hand via Withdraw, the
	# deck, or RFG): all continuous effects end, so the card is reset to a fresh
	# state and starts clean if it ever re-enters play. This clears exhaustion,
	# damage, buffs (including "this turn" buffs that would otherwise linger —
	# e.g. an attack buff that survives a Finkle Einhorn recursion), granted
	# keywords, counters, and per-turn/summon flags.
	# No hp_changed event here — deal_damage already emitted it before calling
	# move_card, and the card is leaving play so no renderer update is needed.
	var dest_zone := state.zones.get(to_zone_id) as Zone
	var src_zone  := state.zones.get(from_zone_id) as Zone
	if dest_zone and not (dest_zone.zone_type in GameState.PLAY_ZONE_TYPES) \
			and src_zone and src_zone.zone_type in GameState.PLAY_ZONE_TYPES:
		if card.is_exhausted:
			card.is_exhausted = false
			events.append(GameEvent.card_readied(card_id))
		card.damage_taken = 0
		card.active_buffs.clear()
		card.granted_keywords.clear()
		card.counters.clear()
		card.chosen_x = 0
		card.just_summoned = false
		card.used_this_turn = false

	return events


# Silent variant for setup time (starting hand, hero placement). Same zone
# bookkeeping as move_card but emits no events — callers handle UI separately.
static func move_card_silent(state: GameState, card_id: String, to_zone_id: String) -> void:
	var card := state.get_card(card_id)
	if not card:
		return
	var from_zone := state.zones.get(card.zone_id) as Zone
	if from_zone:
		from_zone.card_ids.erase(card_id)
	var to_zone := state.zones.get(to_zone_id) as Zone
	if to_zone:
		to_zone.card_ids.append(card_id)
	card.zone_id = to_zone_id


# ── deal_damage ────────────────────────────────────────────────────────────────
# Apply damage to an in-play card and emit the relevant events.
# Does NOT destroy the card — call check_destroyed afterwards when ready.
# This keeps damage and destruction as separate steps, which is required for
# simultaneous combat (both hits land before either fatality is checked).
#
# INVARIANT: effect resolutions never call this directly — they hand packets to
# StackResolver.defer_packets (the prevention pipeline, rule 717.2c), which is
# what makes every new damage effect armor-preventable by construction. The
# only sanctioned direct callers are the pipeline itself (_apply_packet_group)
# and _do_combat_conclusion (combat runs its own prevention point first).
# `opts` is the packet's prevention context — see `prevent` below. Callers that
# don't care omit it entirely (the default is "ordinary preventable damage").
static func deal_damage(state: GameState, source_id: String, target_id: String,
		amount: int, db, opts: Dictionary = {}) -> Array[GameEvent]:
	if amount <= 0:
		return []

	var target := state.get_card(target_id)
	if not target or not state.is_in_play(target_id):
		return []

	var events: Array[GameEvent] = []

	# Rule 717.2: every prevention effect in the game is applied here, in one
	# place, before any damage is placed.
	var pr := prevent(state, db, source_id, target_id, amount, opts)
	events.append_array(pr.get("events", []) as Array)
	amount = int(pr.get("amount", 0))
	if amount <= 0:
		return events
	var target_ps := state.players.get(target.controller) as PlayerState

	var old_hp := state.get_current_hp(target_id, db)

	# Rule 405.3: excess damage beyond fatal is lost, not placed.
	var actual: int = min(amount, old_hp)
	if actual <= 0:
		return []
	target.damage_taken += actual
	var new_hp := state.get_current_hp(target_id, db)
	var max_hp := state.get_max_hp(target_id, db)

	# Turn event log (turn-history conditions — Thysta Spiritlasher's "if no
	# damage was dealt this turn", Torek's Assault's "opposing hero damaged by
	# an ally in your party this turn"; see game_logic/turn_state_flags.md).
	# Recorded here and nowhere else, deliberately paired with the damage_dealt
	# event so log truth == event truth:
	#   - AFTER prevention, so damage absorbed in full doesn't count (717.2b);
	#   - AFTER the 405.3 excess guard above, so a packet at an already-0-HP
	#     target (possible mid-combat, since deal_damage only places damage and
	#     check_destroyed runs separately) doesn't count either.
	# The controller/zone facts are SNAPSHOTTED now — by the time a condition
	# scans the log the source may be in a graveyard or under new control
	# (Infernal), and re-deriving from the id would answer a different question.
	# Every damage source funnels through here, so new effects feed the log by
	# construction. put_damage (405.3 self-damage costs) is a separate primitive
	# and correctly does not record — same call made for Berserking's counters.
	var source_card := state.get_card(source_id)
	var source_zone: Zone = null
	if source_card:
		source_zone = state.zones.get(source_card.zone_id) as Zone
	state.record("damage_dealt", {
		"source_id":         source_id,
		"target_id":         target_id,
		"amount":            actual,
		"source_controller": source_card.controller if source_card else "",
		"target_controller": target.controller,
		"source_is_ally":    source_zone != null and source_zone.zone_type == "ally_row",
		"target_is_hero":    target_ps != null and target_ps.hero_instance_id == target_id,
	})

	events.append(GameEvent.damage_dealt(source_id, target_id, actual))
	events.append(GameEvent.hp_changed(target_id, old_hp, new_hp, max_hp))

	# Berserking: "Ongoing: When your hero is dealt damage, put a berserk counter
	# on Berserking." One counter per damage EVENT (the card says "is dealt
	# damage", not "for each damage"), regardless of source or amount. Only
	# damage that is DEALT counts — put_damage (405.3) has its own path.
	if target_ps and target_ps.hero_instance_id == target_id:
		events.append_array(_add_berserk_counters(state, target.controller, db))

	return events


# ── prevent ───────────────────────────────────────────────────────────────────
# The ONE place damage prevention is applied (rule 717.2). Takes the amount a
# packet WOULD deal and returns what actually reaches the target, together with
# the damage_prevented events for whatever was absorbed:
#
#     {"amount": int, "events": Array[GameEvent]}
#
# An UNPREVENTABLE packet (Lionheart Helm, Annihilator) is returned unchanged
# with no events — and, importantly, consumes nothing: an armor pool built for
# this packet survives unspent, and a shield like Brother Rhone still blocks the
# next attacker. "Can't be prevented" removes the prevention, not the shield.
#
# `opts` (all optional):
#   unpreventable — explicit override. When absent it is DERIVED from the source
#                   (is_damage_unpreventable, non-combat), so a new damage effect
#                   respects Lionheart Helm by construction. Combat passes it
#                   explicitly because it must be read before the combat step's
#                   weapon associations are cleared (303.2a).
#   combat_attack — true only for the attacker→defender packet of a combat
#                   conclusion; what Brother Rhone's shield keys off.
static func prevent(state: GameState, db, source_id: String, target_id: String,
		amount: int, opts: Dictionary = {}) -> Dictionary:
	var events: Array[GameEvent] = []
	if amount <= 0:
		return {"amount": amount, "events": events}

	var unpreventable: bool = bool(opts.get("unpreventable",
		is_damage_unpreventable(state, db, source_id, false)))
	if unpreventable:
		return {"amount": amount, "events": events}

	var target := state.get_card(target_id)
	if not target:
		return {"amount": amount, "events": events}

	# (a) Character-side prevention shields (Brother Rhone). Automatic and free —
	# no decision point and no cost, unlike armor. Rhone's clause is
	# self-referential ("dealt to Brother Rhone"), so the flag is read off the
	# TARGET's own def.
	if bool(opts.get("combat_attack", false)) \
			and blocks_all_combat_damage(state, db, source_id, target_id):
		events.append(GameEvent.damage_prevented(target_id, amount, 0))
		return {"amount": 0, "events": events}

	# (b) Rule 717.2c: exhausted armor prevents damage dealt to the controller's
	# HERO. The pool (PlayerState.damage_prevention) was built at the prevention
	# point (StackResolver.choose_prevention) opened right before this packet.
	var target_ps := state.players.get(target.controller) as PlayerState
	if target_ps and target_ps.hero_instance_id == target_id \
			and target_ps.damage_prevention > 0:
		var absorbed: int = min(amount, target_ps.damage_prevention)
		target_ps.damage_prevention -= absorbed
		amount -= absorbed
		events.append(GameEvent.damage_prevented(
			target_id, absorbed, target_ps.damage_prevention))

	return {"amount": amount, "events": events}


# True when a character-side shield would prevent ALL of the combat damage
# `source_id` deals to `target_id` as its attacker (Brother Rhone). Pure — no
# state is touched — so the AI can probe it when picking a protector
# (BaseAI.blocks_for_free); `prevent` above is the enforcement site. A new
# shield card added here is answered by both at once.
static func blocks_all_combat_damage(state: GameState, db, source_id: String,
		target_id: String) -> bool:
	# Rhone's clause is self-referential ("dealt to Brother Rhone"), so the flag
	# is read off the TARGET's own def, and only ATTACKING allies are stopped.
	return _has_effect_flag(state, db, target_id,
			"prevent_combat_damage_from_attacking_allies") \
		and _is_ally_card(state, source_id)


# "Damage dealt by your hero can't be prevented" (Lionheart Helm) and its
# combat-and-weapon-scoped cousin (Annihilator). Both are read live off the
# SOURCE's controller's hero_row — the source must BE that player's hero.
#
# `is_combat` gates the weapon form: Annihilator only makes combat damage dealt
# WITH IT unpreventable, so the hero must have struck with that very weapon this
# combat (303.2b associations, GameState.combat_struck_weapons).
static func is_damage_unpreventable(state: GameState, db, source_id: String,
		is_combat: bool) -> bool:
	if not db or source_id == "":
		return false
	var source := state.get_card(source_id)
	if not source:
		return false
	var ps := state.players.get(source.controller) as PlayerState
	if not ps or ps.hero_instance_id != source_id:
		return false   # only "your hero" — ally/totem/equipment damage is unaffected
	var struck: Array = state.combat_struck_weapons.get(source_id, [])
	for card in state.cards_in_zone(source.controller + "_hero_row"):
		var def: CardDef = db.get_def(card.card_def_id)
		if not def or def.effects == "":
			continue
		var flags := def.effects.split("|")
		if "hero_damage_unpreventable" in flags:
			return true
		if is_combat and "combat_damage_unpreventable" in flags \
				and card.instance_id in struck:
			return true
	return false


# True when the card's def carries `flag` as a standalone effects segment.
static func _has_effect_flag(state: GameState, db, card_id: String,
		flag: String) -> bool:
	if not db:
		return false
	var card := state.get_card(card_id)
	if not card:
		return false
	var def: CardDef = db.get_def(card.card_def_id)
	if not def or def.effects == "":
		return false
	return flag in def.effects.split("|")


static func _is_ally_card(state: GameState, card_id: String) -> bool:
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	return zone != null and zone.zone_type == "ally_row"


# Fires the `berserk_counter_on_hero_damage` flag on every in-play card the
# player controls (Berserking). Returns the counter_changed events.
static func _add_berserk_counters(state: GameState, player_id: String,
		db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if not db:
		return events
	for card in state.cards_in_zone(player_id + "_hero_row"):
		var def: CardDef = db.get_def(card.card_def_id)
		if not def or def.effects == "":
			continue
		if not ("berserk_counter_on_hero_damage" in def.effects.split("|")):
			continue
		var n: int = int(card.counters.get("berserk", 0)) + 1
		card.counters["berserk"] = n
		events.append(GameEvent.counter_changed(card.instance_id, "berserk", n - 1, n))
	return events


# ── put_damage ─────────────────────────────────────────────────────────────────
# Rule 405.3: damage "put on" a character (as opposed to "dealt") can't be
# prevented or replaced, and can never exceed the target's remaining health
# (if it would put more than fatal damage, put exactly fatal damage instead).
# Used for self-inflicted activated-power costs (e.g. Acolyte Demia).
static func put_damage(state: GameState, target_id: String, amount: int, db) -> Array[GameEvent]:
	if amount <= 0:
		return []
	var target := state.get_card(target_id)
	if not target or not state.is_in_play(target_id):
		return []

	var old_hp := state.get_current_hp(target_id, db)
	var actual: int = min(amount, old_hp)
	if actual <= 0:
		return []
	target.damage_taken += actual
	var new_hp := state.get_current_hp(target_id, db)
	var max_hp := state.get_max_hp(target_id, db)

	return [
		GameEvent.damage_dealt(target_id, target_id, actual),
		GameEvent.hp_changed(target_id, old_hp, new_hp, max_hp),
	]


# ── ally_destroyed turn-log entry ──────────────────────────────────────────────
# Co-located with every GameEvent.card_destroyed construction (see
# game_logic/turn_state_flags.md). Snapshot fields are frozen here because none
# of them survives to read time: the card is in a graveyard (zone lookup can no
# longer say "ally"), a token is on its way to RFG, and control may change.
static func _record_ally_destroyed(state: GameState, card_id: String) -> void:
	var card := state.get_card(card_id)
	if not card:
		return
	var zone := state.zones.get(card.zone_id) as Zone
	state.record("ally_destroyed", {
		"card_id": card_id,
		"controller": card.controller,
		"owner": card.owner,
		"is_ally": zone != null and zone.zone_type == "ally_row",
		"is_token": card.is_token,
	})


# ── check_destroyed ────────────────────────────────────────────────────────────
# State-based check: if the card is in play with HP <= 0, destroy it.
# Heroes are a special case — their death triggers game_over and they do NOT
# move to the graveyard (the stack resolver handles game_over separately).
# Returns [] if the card is alive or not in play.
static func check_destroyed(state: GameState, card_id: String,
		source_id: String = "", db = null) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card or not state.is_in_play(card_id):
		return []
	if state.get_current_hp(card_id, db) > 0:
		return []
	var zone := state.zones.get(card.zone_id) as Zone
	if zone and zone.zone_type == "hero_row":
		# Hero death is handled at the resolver level (game_over event).
		# check_destroyed must not move the hero — return empty and let the
		# resolver emit game_over directly.
		return []
	var events: Array[GameEvent] = []
	_record_ally_destroyed(state, card_id)
	events.append(GameEvent.card_destroyed(card_id, source_id))
	events.append_array(move_card(state, card_id, card.owner + "_graveyard"))
	return events


# ── heal ──────────────────────────────────────────────────────────────────────
# Remove damage from a card, up to its max HP. Does nothing if already at
# full health. Healing cannot bring a card above max HP.
static func heal(state: GameState, target_id: String, amount: int, db, source_id: String = "") -> Array[GameEvent]:
	if amount <= 0:
		return []

	var target := state.get_card(target_id)
	if not target or not state.is_in_play(target_id) or target.damage_taken == 0:
		return []

	var events: Array[GameEvent] = []
	var old_hp := state.get_current_hp(target_id, db)

	target.damage_taken = max(target.damage_taken - amount, 0)
	var new_hp := state.get_current_hp(target_id, db)

	if new_hp != old_hp:
		events.append(GameEvent.hp_changed(target_id, old_hp, new_hp, state.get_max_hp(target_id, db), source_id))

	return events


# ── exhaust_card ───────────────────────────────────────────────────────────────
# Exhaust a card. No-op if already exhausted.
static func exhaust_card(state: GameState, card_id: String) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card or card.is_exhausted or not state.is_in_play(card_id):
		return []
	card.is_exhausted = true
	return [GameEvent.card_exhausted(card_id)]


# ── ready_card ─────────────────────────────────────────────────────────────────
# Ready a card. No-op if already ready.
static func ready_card(state: GameState, card_id: String) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card or not card.is_exhausted or not state.is_in_play(card_id):
		return []
	card.is_exhausted = false
	return [GameEvent.card_readied(card_id)]


# ── destroy_card ──────────────────────────────────────────────────────────────
# Rule 415.9d: move a card from play to its owner's graveyard. No damage dealt.
# Only cards in play can be destroyed. Does NOT fire damage events.
# Use this for effects that say "destroy target ally/equipment/ability".
static func destroy_card(state: GameState, card_id: String,
		source_id: String = "") -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card or not state.is_in_play(card_id):
		return []
	var events: Array[GameEvent] = []
	_record_ally_destroyed(state, card_id)
	events.append(GameEvent.card_destroyed(card_id, source_id))
	events.append_array(move_card(state, card_id, card.owner + "_graveyard"))
	return events


# ── draw_one / mark_decked ────────────────────────────────────────────────────
# THE single "a player is required to draw a card" primitive. Every draw in the
# engine goes through here so the decked rule can't be forgotten at a new site.
#
# Rule 410.6b: a player required to draw from an empty deck becomes DECKED, and
# 102.1a makes him lose the game immediately. Emptying the deck is NOT itself a
# loss — only the next required draw is. Effects that merely LOOK at the deck
# (reveal_pick) are not draws and must not call this.
static func draw_one(state: GameState, player_id: String) -> Array[GameEvent]:
	var deck := state.zones.get(player_id + "_deck") as Zone
	if not deck or deck.card_ids.is_empty():
		var events: Array[GameEvent] = [
			GameEvent.make("deck_empty", {"player": player_id})]
		events.append_array(mark_decked(state, player_id))
		return events
	return move_card(state, deck.card_ids[0], player_id + "_hand")


# Mark a player decked and end the game (102.1a). If every player in the game is
# decked at that moment, it's a draw — otherwise the other player wins.
static func mark_decked(state: GameState, player_id: String) -> Array[GameEvent]:
	if player_id in state.decked_players:
		return []
	state.decked_players.append(player_id)
	var events: Array[GameEvent] = [GameEvent.player_decked(player_id)]
	var alive: Array[String] = []
	for pid in state.players:
		if not (pid in state.decked_players):
			alive.append(pid)
	if alive.is_empty():
		events.append(GameEvent.game_drawn(state.decked_players.duplicate(), "decked"))
	else:
		events.append(GameEvent.game_over(alive[0], player_id, "decked"))
	return events


# ── shuffle_hand_into_deck_and_draw ───────────────────────────────────────────
# Moonshadow-style effect: put all hand cards back into the deck face-down,
# shuffle, then draw the same number.  Net hand size stays the same unless the
# deck runs out.
static func shuffle_hand_into_deck_and_draw(state: GameState,
		player_id: String) -> Array[GameEvent]:
	var hand := state.cards_in_zone(player_id + "_hand").duplicate()
	var draw_count := hand.size()
	var events: Array[GameEvent] = []
	# Return hand cards to the deck with events so the renderer clears them.
	for card in hand:
		events.append_array(move_card(state, card.instance_id, player_id + "_deck"))
	# Shuffle the deck in-place.
	state.zones[player_id + "_deck"].card_ids.shuffle()
	events.append(GameEvent.make("deck_shuffled", {"player": player_id}))
	# Draw the same number of cards (a required draw — 410.6b applies).
	for _i in range(draw_count):
		events.append_array(draw_one(state, player_id))
	return events


# ── discard_card ───────────────────────────────────────────────────────────────
# Rule 415.9e: reveal a card from hand, then put it into its owner's graveyard.
# Only works on cards in hand. Use this for effects that say "discard a card".
static func discard_card(state: GameState, card_id: String) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card:
		return []
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return []
	var events: Array[GameEvent] = []
	# "Reveal" — opponents see it; renderer can animate a brief face-up flash.
	events.append(GameEvent.make("card_revealed", {"card": card_id, "reason": "discard"}))
	events.append_array(move_card(state, card_id, card.owner + "_graveyard"))
	return events


# ── add_buff / remove_buffs_from_source ───────────────────────────────────────
static func add_buff(state: GameState, target_id: String, buff: Buff) -> Array[GameEvent]:
	var target := state.get_card(target_id)
	if not target:
		return []
	target.active_buffs.append(buff)
	return [GameEvent.buff_added(target_id, buff.buff_id)]

static func remove_buffs_from_source(state: GameState, target_id: String,
		source_id: String) -> Array[GameEvent]:
	var target := state.get_card(target_id)
	if not target:
		return []
	var events: Array[GameEvent] = []
	var remaining: Array[Buff] = []
	for b in target.active_buffs:
		if b.source_id == source_id:
			events.append(GameEvent.buff_removed(target_id, b.buff_id))
		else:
			remaining.append(b)
	target.active_buffs = remaining
	return events


# ── set_counter ───────────────────────────────────────────────────────────────
# Set a named counter on a card to a new value. Removing a counter entirely
# is done by setting it to 0 (callers may then check and destroy the card).
static func set_counter(state: GameState, card_id: String,
		counter_name: String, new_value: int) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card:
		return []
	var old_value: int = card.counters.get(counter_name, 0)
	if old_value == new_value:
		return []
	if new_value <= 0:
		card.counters.erase(counter_name)
	else:
		card.counters[counter_name] = new_value
	return [GameEvent.counter_changed(card_id, counter_name, old_value, new_value)]
