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
static func deal_damage(state: GameState, source_id: String, target_id: String,
		amount: int, db) -> Array[GameEvent]:
	if amount <= 0:
		return []

	var target := state.get_card(target_id)
	if not target or not state.is_in_play(target_id):
		return []

	var events: Array[GameEvent] = []

	# Rule 304.3: exhausted armor prevents damage dealt to the controller's HERO.
	# The prevention pool (PlayerState.damage_prevention) was built up in advance
	# via use_armor_prevention; consume it before any damage is placed.
	var target_ps := state.players.get(target.controller) as PlayerState
	if target_ps and target_ps.hero_instance_id == target_id \
			and target_ps.damage_prevention > 0:
		var prevented: int = min(amount, target_ps.damage_prevention)
		target_ps.damage_prevention -= prevented
		amount -= prevented
		events.append(GameEvent.damage_prevented(
			target_id, prevented, target_ps.damage_prevention))
		if amount <= 0:
			return events

	# Torek's Assault condition: track when a hero is damaged by an opposing ally.
	if target_ps and target_ps.hero_instance_id == target_id:
		var source_card := state.get_card(source_id)
		if source_card and source_card.controller != target.controller:
			var source_zone := state.zones.get(source_card.zone_id) as Zone
			if source_zone and source_zone.zone_type == "ally_row":
				target_ps.hero_damaged_by_ally_this_turn = true

	var old_hp := state.get_current_hp(target_id, db)

	# Rule 405.3: excess damage beyond fatal is lost, not placed.
	var actual: int = min(amount, old_hp)
	if actual <= 0:
		return []
	target.damage_taken += actual
	var new_hp := state.get_current_hp(target_id, db)
	var max_hp := state.get_max_hp(target_id, db)

	events.append(GameEvent.damage_dealt(source_id, target_id, actual))
	events.append(GameEvent.hp_changed(target_id, old_hp, new_hp, max_hp))

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
	events.append(GameEvent.card_destroyed(card_id, source_id))
	events.append_array(move_card(state, card_id, card.owner + "_graveyard"))
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
	# Draw the same number of cards.
	for _i in range(draw_count):
		var deck := state.zones.get(player_id + "_deck") as Zone
		if not deck or deck.card_ids.is_empty():
			break
		events.append_array(move_card(state, deck.card_ids[0], player_id + "_hand"))
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
