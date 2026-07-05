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

static func hp_changed(card_id: String, old_hp: int, new_hp: int, max_hp: int, source_id: String = "") -> GameEvent:
	return make("hp_changed", {"card": card_id, "old_hp": old_hp, "new_hp": new_hp, "max_hp": max_hp, "source": source_id})

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

static func combat_started(attacker_id: String, defender_id: String) -> GameEvent:
	return make("combat_started", {"attacker_id": attacker_id, "defender_id": defender_id})

static func protect_point_opened(attacker_id: String, defender_id: String,
		legal_protectors: Array) -> GameEvent:
	return make("protect_point_opened", {
		"attacker_id":      attacker_id,
		"defender_id":      defender_id,
		"legal_protectors": legal_protectors,
	})

static func protect_chosen(protector_id: String, defending_player: String) -> GameEvent:
	return make("protect_chosen", {
		"protector_id":     protector_id,
		"defending_player": defending_player,
	})

static func combat_concluded(attacker_id: String, defender_id: String,
		attacker_damage: int, defender_damage: int) -> GameEvent:
	return make("combat_concluded", {
		"attacker_id":     attacker_id,
		"defender_id":     defender_id,
		"attacker_damage": attacker_damage,
		"defender_damage": defender_damage,
	})

static func game_over(winner: String, loser: String) -> GameEvent:
	return make("game_over", {"winner": winner, "loser": loser, "reason": "hero_defeated"})

static func discard_choice_opened(player_id: String, count: int, reason: String = "card_effect") -> GameEvent:
	return make("discard_choice_opened", {"player": player_id, "count": count, "reason": reason})

static func pet_sacrifice_required(player_id: String, candidate_ids: Array[String]) -> GameEvent:
	return make("pet_sacrifice_required", {"player": player_id, "candidates": candidate_ids})

static func equipment_sacrifice_required(player_id: String, candidate_ids: Array[String]) -> GameEvent:
	return make("equipment_sacrifice_required", {"player": player_id, "candidates": candidate_ids})

static func armor_prevention_used(player_id: String, card_id: String,
		def_value: int, total_prevention: int) -> GameEvent:
	return make("armor_prevention_used", {
		"player":     player_id,
		"card_id":    card_id,
		"def":        def_value,
		"prevention": total_prevention,   # pool total after adding this armor's DEF
	})

static func damage_prevented(target_id: String, amount: int, remaining: int) -> GameEvent:
	return make("damage_prevented", {
		"target_id": target_id,
		"amount":    amount,      # damage points absorbed by the pool
		"remaining": remaining,   # pool left after absorbing
	})

static func hero_power_used(player_id: String, hero_id: String) -> GameEvent:
	return make("hero_power_used", {"player": player_id, "hero_id": hero_id})

static func mulligan_phase_started(first_player: String, player_order: Array) -> GameEvent:
	return make("mulligan_phase_started", {
		"first_player": first_player, "player_order": player_order,
	})

static func mulligan_committed(player_id: String, wants_mulligan: bool) -> GameEvent:
	return make("mulligan_committed", {"player": player_id, "mulligan": wants_mulligan})

static func mulligan_shuffle_done() -> GameEvent:
	return make("mulligan_shuffle_done", {})

static func mulligan_phase_ended() -> GameEvent:
	return make("mulligan_phase_ended", {})

static func attack_window_opened(attacker_id: String, defender_id: String) -> GameEvent:
	return make("attack_window_opened", {
		"attacker_id": attacker_id, "defender_id": defender_id,
	})

static func defend_window_opened(attacker_id: String, defender_id: String) -> GameEvent:
	return make("defend_window_opened", {
		"attacker_id": attacker_id, "defender_id": defender_id,
	})

static func enter_play_target_required(card_id: String, dmg_type: String, amount: int) -> GameEvent:
	return make("enter_play_target_required", {
		"card_id": card_id, "dmg_type": dmg_type, "amount": amount,
	})

static func card_returned_from_graveyard(card_id: String, player_id: String) -> GameEvent:
	return make("card_returned_from_graveyard", {
		"card_id": card_id, "player": player_id,
	})

static func card_removed_from_game(card_id: String, player_id: String) -> GameEvent:
	return make("card_removed_from_game", {
		"card_id": card_id, "player": player_id,
	})
