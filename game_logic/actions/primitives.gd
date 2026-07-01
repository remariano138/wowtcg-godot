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

	# Cards entering the graveyard are readied: exhausted state and damage
	# cleared so the card starts fresh if it ever re-enters play.
	# No hp_changed event here — deal_damage already emitted it before calling
	# move_card, and the card is leaving play so no renderer update is needed.
	var dest_zone := state.zones.get(to_zone_id) as Zone
	if dest_zone and dest_zone.zone_type == "graveyard":
		if card.is_exhausted:
			card.is_exhausted = false
			events.append(GameEvent.card_readied(card_id))
		card.damage_taken = 0

	return events


# ── deal_damage ────────────────────────────────────────────────────────────────
# Apply damage to a card. If damage meets or exceeds current HP, the card is
# destroyed (moved to its owner's graveyard). Returns all events including
# any destruction.
static func deal_damage(state: GameState, source_id: String, target_id: String,
		amount: int, db) -> Array[GameEvent]:
	if amount <= 0:
		return []

	var target := state.get_card(target_id)
	if not target or not state.is_in_play(target_id):
		return []

	var events: Array[GameEvent] = []
	var old_hp := state.get_current_hp(target_id, db)

	# Rule 405.3: excess damage beyond fatal is lost, not placed.
	var actual: int = min(amount, old_hp)
	if actual <= 0:
		return []
	target.damage_taken += actual
	var new_hp := state.get_current_hp(target_id, db)

	events.append(GameEvent.damage_dealt(source_id, target_id, actual))
	events.append(GameEvent.hp_changed(target_id, old_hp, new_hp))

	if new_hp <= 0:
		events.append(GameEvent.card_destroyed(target_id, source_id))
		var graveyard_id := target.owner + "_graveyard"
		events.append_array(move_card(state, target_id, graveyard_id))

	return events


# ── heal ──────────────────────────────────────────────────────────────────────
# Remove damage from a card, up to its max HP. Does nothing if already at
# full health. Healing cannot bring a card above max HP.
static func heal(state: GameState, target_id: String, amount: int, db) -> Array[GameEvent]:
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
		events.append(GameEvent.hp_changed(target_id, old_hp, new_hp))

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
