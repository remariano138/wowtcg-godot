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

# A card was played from hand (ally / instant / ability / equipment). Emitted at
# submission (rule 409.1, hand→chain). Placing a resource is deliberately NOT a
# "play" and does not emit this. Consumed by StatTracker for match stats.
static func card_played(player_id: String, card_id: String) -> GameEvent:
	return make("card_played", {"player": player_id, "card": card_id})

static func damage_dealt(source_id: String, target_id: String, amount: int) -> GameEvent:
	return make("damage_dealt", {"source": source_id, "target": target_id, "amount": amount})

static func card_destroyed(card_id: String, by_source: String) -> GameEvent:
	return make("card_destroyed", {"card": card_id, "source": by_source})

# An attachment entered play attached to a host (rule 400.2). Emitted right
# after the card_moved into the "attached" zone so the renderer knows the host.
static func card_attached(card_id: String, host_id: String) -> GameEvent:
	return make("card_attached", {"card": card_id, "host": host_id})

static func card_exhausted(card_id: String) -> GameEvent:
	return make("card_exhausted", {"card": card_id})

static func card_readied(card_id: String) -> GameEvent:
	return make("card_readied", {"card": card_id})

static func hp_changed(card_id: String, old_hp: int, new_hp: int, max_hp: int, source_id: String = "") -> GameEvent:
	return make("hp_changed", {"card": card_id, "old_hp": old_hp, "new_hp": new_hp, "max_hp": max_hp, "source": source_id})

static func buff_added(card_id: String, buff_id: String) -> GameEvent:
	return make("buff_added", {"card": card_id, "buff_id": buff_id})

# A "target ally has +/-N ATK this turn" grant (Ravenous Bite). Carries the
# signed amount so the renderer/log can show the pump and the shrink apart.
static func atk_swing_applied(target_id: String, source_id: String, amount: int) -> GameEvent:
	return make("atk_swing_applied",
		{"target_id": target_id, "source_id": source_id, "amount": amount})

static func buff_removed(card_id: String, buff_id: String) -> GameEvent:
	return make("buff_removed", {"card": card_id, "buff_id": buff_id})

# A player-wide "while attacking this turn" ATK buff (Rayder, For the Horde!)
# that applies to the whole party for the rest of the turn, including allies
# that enter play afterward — not attached to any specific card instance.
static func party_atk_buff_added(player_id: String, amount: int, alignment: String) -> GameEvent:
	return make("party_atk_buff_added", {"player": player_id, "amount": amount, "alignment": alignment})

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

# Rule 603.1b: a combatant left play (bounced, destroyed, removed from combat)
# before the conclusion, so no damage is dealt. Emitted right before the
# combat_concluded that carries cancelled = true; `reason` is one of
# "attacker_gone" / "defender_gone" / "attacker_removed".
static func combat_cancelled(attacker_id: String, defender_id: String,
		reason: String) -> GameEvent:
	return make("combat_cancelled", {
		"attacker_id": attacker_id,
		"defender_id": defender_id,
		"reason":      reason,
	})

static func combat_concluded(attacker_id: String, defender_id: String,
		attacker_damage: int, defender_damage: int,
		cancelled: bool = false) -> GameEvent:
	return make("combat_concluded", {
		"attacker_id":     attacker_id,
		"defender_id":     defender_id,
		"attacker_damage": attacker_damage,
		"defender_damage": defender_damage,
		"cancelled":       cancelled,
	})

# `reason` is the win condition, used by the UI to explain HOW the game ended:
#   "hero_defeated" — the loser's hero was dealt fatal damage / destroyed (102.1a)
#   "decked"        — the loser was required to draw from an empty deck (410.6b)
# `losers` is always the full list; `draw` is true when every remaining player
# lost simultaneously (102.1a), in which case `winner` is "".
static func game_over(winner: String, loser: String,
		reason: String = "hero_defeated") -> GameEvent:
	return make("game_over", {
		"winner": winner, "loser": loser, "losers": [loser],
		"reason": reason, "draw": false,
	})


static func game_drawn(losers: Array[String], reason: String) -> GameEvent:
	return make("game_over", {
		"winner": "", "loser": "", "losers": losers,
		"reason": reason, "draw": true,
	})


static func player_decked(player_id: String) -> GameEvent:
	return make("player_decked", {"player": player_id})


# One place that turns a game_over payload into a human sentence, shared by
# every surface that shows the result (game-over dialog, status bar, game log).
# `names` maps player_id -> display name; missing ids fall back to "P1"/"P2".
# New win conditions add a `reason` branch here and nowhere else.
static func game_over_explanation(payload: Dictionary, names: Dictionary = {}) -> String:
	var name := func(pid: String) -> String:
		return str(names.get(pid, "P1" if pid == "p1" else "P2"))
	var reason: String = str(payload.get("reason", ""))
	var winner: String = str(payload.get("winner", ""))
	var losers: Array   = payload.get("losers", [])
	if losers.is_empty() and str(payload.get("loser", "")) != "":
		losers = [str(payload.get("loser", ""))]

	var cause := func(pid: String) -> String:
		match reason:
			"hero_defeated":
				return "%s's hero received fatal damage" % name.call(pid)
			"decked":
				return "%s was decked — required to draw from an empty deck" % name.call(pid)
			_:
				return "%s lost the game" % name.call(pid)

	if bool(payload.get("draw", false)):
		var parts := PackedStringArray()
		for pid in losers:
			parts.append(cause.call(str(pid)))
		return "%s — the game is a draw." % " and ".join(parts)

	var loser_id: String = str(losers[0]) if not losers.is_empty() else ""
	return "%s. %s wins!" % [cause.call(loser_id), name.call(winner)]

static func discard_choice_opened(player_id: String, count: int, reason: String = "card_effect") -> GameEvent:
	return make("discard_choice_opened", {"player": player_id, "count": count, "reason": reason})

static func control_discard_choice_opened(player_id: String, source_card_id: String) -> GameEvent:
	return make("control_discard_choice_opened", {"player": player_id, "source": source_card_id})

static func control_changed(card_id: String, old_controller: String, new_controller: String) -> GameEvent:
	return make("control_changed", {"card": card_id, "old": old_controller, "new": new_controller})

static func pet_sacrifice_required(player_id: String, candidate_ids: Array[String]) -> GameEvent:
	return make("pet_sacrifice_required", {"player": player_id, "candidates": candidate_ids})

static func equipment_sacrifice_required(player_id: String, candidate_ids: Array[String]) -> GameEvent:
	return make("equipment_sacrifice_required", {"player": player_id, "candidates": candidate_ids})

static func unique_sacrifice_required(player_id: String, candidate_ids: Array[String]) -> GameEvent:
	return make("unique_sacrifice_required", {"player": player_id, "candidates": candidate_ids})

# Form (1) tag-count uniqueness violation (rule 414.3b): `player` must destroy
# Forms until one remains. `new_card_id` is the Form that just entered play
# (the AI keeps it; a human picks freely).
static func form_sacrifice_required(player_id: String, candidate_ids: Array[String],
		new_card_id: String) -> GameEvent:
	return make("form_sacrifice_required", {
		"player": player_id, "candidates": candidate_ids, "new_card_id": new_card_id,
	})

# A Form was destroyed by its own break condition ("strike with a weapon or
# play a non-Feral ability"). Informational — the card_destroyed event carries
# the actual zone change.
static func form_broken(card_id: String, player_id: String, reason: String) -> GameEvent:
	return make("form_broken", {"card_id": card_id, "player": player_id, "reason": reason})

# Bear/Cat Form pay-2 return choice opened for `player` (the destroyed Form's
# controller). Resolved via StackResolver.choose_form_return().
static func form_return_opened(player_id: String, card_id: String, cost: int) -> GameEvent:
	return make("form_return_opened", {"player": player_id, "card_id": card_id, "cost": cost})

static func form_return_resolved(player_id: String, card_id: String, paid: bool) -> GameEvent:
	return make("form_return_resolved", {"player": player_id, "card_id": card_id, "paid": paid})

static func armor_prevention_used(player_id: String, card_id: String,
		def_value: int, total_prevention: int) -> GameEvent:
	return make("armor_prevention_used", {
		"player":     player_id,
		"card_id":    card_id,
		"def":        def_value,
		"prevention": total_prevention,   # pool total after adding this armor's DEF
	})

# Armor prevention point opened (rule 717.2c): `player` may exhaust ready DEF
# armor against an `amount`-damage packet from `source` about to hit `target`
# (their hero). Re-emitted with the reduced amount after each armor exhausted
# while the packet still has damage left and more ready armor exists.
static func prevention_opened(player_id: String, amount: int,
		source_id: String, target_id: String) -> GameEvent:
	return make("prevention_opened", {
		"player": player_id,
		"amount": amount,
		"source": source_id,
		"target": target_id,
	})

static func damage_prevented(target_id: String, amount: int, remaining: int) -> GameEvent:
	return make("damage_prevented", {
		"target_id": target_id,
		"amount":    amount,      # damage points absorbed by the pool
		"remaining": remaining,   # pool left after absorbing
	})

static func hero_power_used(player_id: String, hero_id: String) -> GameEvent:
	return make("hero_power_used", {"player": player_id, "hero_id": hero_id})

# "Can't attack this turn" restriction placed on a hero or ally (Litori Frostburn).
static func cant_attack_applied(target_id: String, source_id: String) -> GameEvent:
	return make("cant_attack_applied", {"target_id": target_id, "source_id": source_id})

# "Can't protect this turn" restriction placed on a hero or ally (Frost Shock).
static func cant_protect_applied(target_id: String, source_id: String) -> GameEvent:
	return make("cant_protect_applied", {"target_id": target_id, "source_id": source_id})

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

# Strike point (rules 602.1 / 602.3): the wielder's controller may strike with
# a weapon. side = "attack" or "defend". Resolved via StackResolver.choose_strike().
static func strike_point_opened(player_id: String, wielder_id: String,
		weapon_ids: Array, side: String) -> GameEvent:
	return make("strike_point_opened", {
		"player":     player_id,
		"wielder_id": wielder_id,
		"weapon_ids": weapon_ids,
		"side":       side,
	})

static func weapon_struck(player_id: String, wielder_id: String,
		weapon_id: String, cost_paid: int) -> GameEvent:
	return make("weapon_struck", {
		"player":     player_id,
		"wielder_id": wielder_id,
		"weapon_id":  weapon_id,
		"cost_paid":  cost_paid,
	})

# Windseer Tarus: ready-on-attack point opened (may pay to ready the attacker).
static func ready_on_attack_opened(player_id: String, card_id: String, cost: int) -> GameEvent:
	return make("ready_on_attack_opened", {
		"player":  player_id,
		"card_id": card_id,
		"cost":    cost,
	})

static func readied_on_attack(player_id: String, card_id: String, cost_paid: int) -> GameEvent:
	return make("readied_on_attack", {
		"player":    player_id,
		"card_id":   card_id,
		"cost_paid": cost_paid,
	})

# Windfury Weapon: ready-on-strike point opened (may pay to ready the struck
# weapon and your hero), and resolved (paid → both readied).
static func ready_on_strike_opened(player_id: String, weapon_id: String, cost: int) -> GameEvent:
	return make("ready_on_strike_opened", {
		"player":    player_id,
		"weapon_id": weapon_id,
		"cost":      cost,
	})

static func readied_on_strike(player_id: String, weapon_id: String, cost_paid: int) -> GameEvent:
	return make("readied_on_strike", {
		"player":    player_id,
		"weapon_id": weapon_id,
		"cost_paid": cost_paid,
	})

# Green Whelp Armor: bounce point opened (wielder MAY pay to return the attacking
# ally to its owner's hand), and resolved (paid → ally bounced).
static func whelp_bounce_opened(player_id: String, ally_id: String, cost: int) -> GameEvent:
	return make("whelp_bounce_opened", {
		"player":  player_id,
		"ally_id": ally_id,
		"cost":    cost,
	})

static func whelp_bounce_resolved(player_id: String, ally_id: String) -> GameEvent:
	return make("whelp_bounce_resolved", {"player": player_id, "ally_id": ally_id})

# Chops / Voss Treebender: attack-exhaust point opened (attacker's controller MAY
# exhaust target hero or ally), and resolved (target_id == "" = declined).
static func attack_exhaust_opened(player_id: String, source_id: String) -> GameEvent:
	return make("attack_exhaust_opened", {
		"player":    player_id,
		"source_id": source_id,
	})

static func attack_exhaust_resolved(player_id: String, source_id: String,
		target_id: String) -> GameEvent:
	return make("attack_exhaust_resolved", {
		"player": player_id, "source_id": source_id, "target_id": target_id,
	})

# Gorebelly's flip: discount on the next melee weapon strike this turn.
static func strike_discount_gained(player_id: String, amount: int) -> GameEvent:
	return make("strike_discount_gained", {"player": player_id, "amount": amount})

static func ranged_weapon_bonus_gained(player_id: String, amount: int) -> GameEvent:
	return make("ranged_weapon_bonus_gained", {"player": player_id, "amount": amount})

static func enter_play_target_required(card_id: String, dmg_type: String, amount: int) -> GameEvent:
	return make("enter_play_target_required", {
		"card_id": card_id, "dmg_type": dmg_type, "amount": amount,
	})

# An ongoing Totem "at the start of each turn" trigger (Searing Totem) must pick
# a target hero or ally. Mandatory choice resolved by the totem's controller via
# StackResolver.choose_totem_target() — a direct call, like the strike / reveal
# choices, NOT a chain action.
static func totem_target_required(card_id: String, player_id: String,
		dmg_type: String, amount: int) -> GameEvent:
	return make("totem_target_required", {
		"card_id": card_id, "player": player_id,
		"dmg_type": dmg_type, "amount": amount,
	})

# A death-triggered "destroy target ally" effect (Boneshanks) must pick an ally
# to destroy. Mandatory choice resolved by the destroyed card's controller via
# StackResolver.choose_death_target() — a direct call, like the totem / strike
# choices, NOT a chain action. Prompted for a human controller even in hotseat.
static func death_target_required(card_id: String, player_id: String) -> GameEvent:
	return make("death_target_required", {
		"card_id": card_id, "player": player_id,
	})

static func card_returned_from_graveyard(card_id: String, player_id: String) -> GameEvent:
	return make("card_returned_from_graveyard", {
		"card_id": card_id, "player": player_id,
	})

static func card_revealed_from_deck(card_id: String, player_id: String) -> GameEvent:
	return make("card_revealed_from_deck", {
		"card_id": card_id, "player": player_id,
	})

# A card in play was put back into its owner's hand by an effect (Withdraw).
static func card_returned_to_hand(card_id: String, source_id: String) -> GameEvent:
	return make("card_returned_to_hand", {
		"card_id": card_id, "source_id": source_id,
	})

static func attacker_removed_from_combat(attacker_id: String, source_id: String) -> GameEvent:
	return make("attacker_removed_from_combat", {
		"attacker_id": attacker_id, "source_id": source_id,
	})

static func card_removed_from_game(card_id: String, player_id: String) -> GameEvent:
	return make("card_removed_from_game", {
		"card_id": card_id, "player": player_id,
	})

# A reveal-and-pick quest reward (Big Game Hunter etc.) revealed the top cards
# and found at least one card of the required type — the controller must choose
# one to keep. selectable = matching-type ids; revealed = all revealed ids.
# `chooser` is the player who makes the pick — the owner unless the card hands
# the choice to the opponent (The Princess Trapped).
# `to_top` puts the picked card back on top of the owner's deck instead of into
# hand; `is_private` marks a "look at" (only the chooser sees the cards).
static func reveal_pick_opened(player_id: String, selectable_ids: Array,
		revealed_ids: Array, card_type: String, chooser: String = "",
		to_top: bool = false, is_private: bool = false) -> GameEvent:
	return make("reveal_pick_opened", {
		"player":     player_id,
		"chooser":    chooser if chooser != "" else player_id,
		"selectable": selectable_ids,
		"revealed":   revealed_ids,
		"card_type":  card_type,
		"to_top":     to_top,
		"private":    is_private,
	})


# ── Quest reward choice ("Choose one … you may choose both") ──────────────────
# The completer of a qmode: quest must pick one reward mode — or both, in an
# order of their choosing, when can_both. modes = [{mode, available}] in printed
# order. Resolved via StackResolver.choose_quest_modes() (direct call).
static func quest_choice_opened(player_id: String, quest_id: String,
		modes: Array, can_both: bool) -> GameEvent:
	return make("quest_choice_opened", {
		"player": player_id, "quest_id": quest_id,
		"modes": modes, "can_both": can_both,
	})

# Hidden Enemies: the completer must pick the ally that gains ferocity this turn.
static func quest_ferocity_target_required(quest_id: String,
		player_id: String) -> GameEvent:
	return make("quest_ferocity_target_required", {
		"quest_id": quest_id, "player": player_id,
	})

static func ferocity_granted(card_id: String, source_id: String) -> GameEvent:
	return make("ferocity_granted", {
		"card_id": card_id, "source_id": source_id,
	})

# A New Plague: player must destroy an ally in their own party.
static func plague_destroy_required(player_id: String,
		source_id: String) -> GameEvent:
	return make("plague_destroy_required", {
		"player": player_id, "source_id": source_id,
	})

# Thwarting Kolkar Aggression: the target player must turn one of their
# face-up quests face down. quest_ids = that player's face-up quests.
static func quest_facedown_required(player_id: String,
		quest_ids: Array) -> GameEvent:
	return make("quest_facedown_required", {
		"player": player_id, "quest_ids": quest_ids,
	})

# A quest was turned face down by an effect (NOT completed — no reward).
static func quest_turned_face_down(quest_id: String,
		player_id: String) -> GameEvent:
	return make("quest_turned_face_down", {
		"quest_id": quest_id, "player": player_id,
	})

# Crown of the Earth: the completer put their whole hand on the bottom of
# their deck (count cards), then draws that many.
static func hand_returned_to_deck(player_id: String, count: int) -> GameEvent:
	return make("hand_returned_to_deck", {
		"player": player_id, "count": count,
	})
