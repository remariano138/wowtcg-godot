class_name GameEvent
extends RefCounted

# A description of something that just happened to game state.
# Rules functions produce these; the stack resolver emits them to the bus;
# the renderer (and any other listener) reacts to them.
# GameEvent objects are read-only after creation — never mutate a returned event.
#
# event_type strings (add new ones as rules functions are implemented):
#   "card_moved"       — a card changed zones
#   "damage_dealt"     — damage was applied to a card
#   "card_destroyed"   — a card was destroyed (moved to graveyard as a result)
#   "card_exhausted"   — a card was exhausted
#   "card_readied"     — a card was readied
#   "hp_changed"       — a card's current HP changed (damage or healing)
#   "buff_added"       — a buff was added to a card
#   "buff_removed"     — a buff was removed from a card
#   "counter_changed"  — a counter on a card was added, changed, or removed
#   "card_revealed"    — a card in hand was revealed (e.g. before discarding)
#   "phase_changed"    — the game phase advanced
#   "turn_changed"     — a new turn began

var event_type: String
var payload: Dictionary   # event-specific data; keys vary by event_type


static func make(p_type: String, p_payload: Dictionary = {}) -> GameEvent:
	var e := GameEvent.new()
	e.event_type = p_type
	e.payload    = p_payload
	return e


# Convenience constructors so call sites are self-documenting and typo-resistant.

static func card_moved(card_id: String, from_zone: String, to_zone: String) -> GameEvent:
	return make("card_moved", {"card": card_id, "from": from_zone, "to": to_zone})

static func damage_dealt(source_id: String, target_id: String, amount: int) -> GameEvent:
	return make("damage_dealt", {"source": source_id, "target": target_id, "amount": amount})

static func card_destroyed(card_id: String, by_source: String) -> GameEvent:
	return make("card_destroyed", {"card": card_id, "source": by_source})

static func card_exhausted(card_id: String) -> GameEvent:
	return make("card_exhausted", {"card": card_id})

static func card_readied(card_id: String) -> GameEvent:
	return make("card_readied", {"card": card_id})

static func hp_changed(card_id: String, old_hp: int, new_hp: int) -> GameEvent:
	return make("hp_changed", {"card": card_id, "old_hp": old_hp, "new_hp": new_hp})

static func buff_added(card_id: String, buff_id: String) -> GameEvent:
	return make("buff_added", {"card": card_id, "buff_id": buff_id})

static func buff_removed(card_id: String, buff_id: String) -> GameEvent:
	return make("buff_removed", {"card": card_id, "buff_id": buff_id})

static func counter_changed(card_id: String, counter_name: String, old_val: int, new_val: int) -> GameEvent:
	return make("counter_changed", {
		"card": card_id, "counter": counter_name, "old": old_val, "new": new_val})

static func phase_changed(old_phase: String, new_phase: String, turn_player: String) -> GameEvent:
	return make("phase_changed", {"old": old_phase, "new": new_phase, "player": turn_player})

static func turn_changed(turn_number: int, turn_player: String) -> GameEvent:
	return make("turn_changed", {"turn": turn_number, "player": turn_player})
