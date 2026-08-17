class_name StatTracker
extends RefCounted

# Per-player match statistics, fed from the game event stream.
#
# This is a passive OBSERVER: it never touches game state or the bus, it only
# reads GameEvents it is handed (see record_event). Wire it up by calling
# record_event() for every event the renderer receives, then read the counters
# when the game ends (Game Over screen). Reset() at the start of each match.
#
# Definitions:
#   cards_drawn  — starts at STARTING_HAND_SIZE (7) to account for the silent
#                  opening-hand deal (move_card_silent, not itself observed as
#                  an event), then increments for any further card that enters
#                  a player's hand from their deck (turn draws, effect draws,
#                  mulligan redraw). Cards moved from hand back to deck (the
#                  mulligan return) decrement, keeping the count symmetric so
#                  the base-7 opening deal isn't double-counted on a mulligan.
#   cards_played — a card played from hand (ally / instant / ability /
#                  equipment). Placing a resource is NOT a play and is excluded
#                  (it is a separate action; see submit_action). Fed by the
#                  dedicated "card_played" event.
#   damage_prevented — damage points that never landed on a player's characters
#                  because something prevented them (rule 717.2): armor exhausted
#                  at the prevention point, and the automatic shields (Brother
#                  Rhone, Bestial Wrath). Counted for the player who BENEFITED —
#                  the prevented packet's target's controller — so it reads as
#                  "how much did my armor save me". Unpreventable damage
#                  (Lionheart Helm, Annihilator) emits nothing and so counts 0.
#   resources_placed — cards put into a player's resource row FACE DOWN (rule
#                  412.1). Face-up placements (quests/locations, 412.1b) are
#                  excluded, since the metric is "how much did I ramp by burying
#                  cards". Counts both the once-per-turn placement and effect
#                  placements (Nightbloom, 412.1c) — both emit resource_placed —
#                  and decrements when a placement is retracted off the chain.
#   hero_combat_damage / hero_ability_damage — damage a player's HERO actually
#                  dealt, split by provenance and attributed to the hero's
#                  controller. Only damage that LANDED counts: the amount on a
#                  damage_dealt event is post-prevention (717.2b) and a fully
#                  prevented packet emits no event at all. Overkill counts in
#                  full (405.2), matching every other "damage dealt" reader.
#                  Combat = either combat-conclusion packet, so a hero's
#                  retaliation as defender counts as well as its attack.
#                  Ability = a packet from an ability resolution (instants,
#                  abilities, attachment burns) — hero POWERS, weapon/equipment
#                  powers and totems are none of the two and count in neither,
#                  exactly as the `from_ability` tag is defined for Chromatic
#                  Cloak. Damage dealt by a player's ALLIES is not hero damage.
#   ally_damage    — damage a player's ALLIES actually dealt, attributed to the
#                  ally's controller. Same "landed only" rule as the hero
#                  columns. Not split by provenance: it is every packet whose
#                  source sits in an ally_row — combat, activated powers,
#                  enter-play burns, totem pings (a totem IS an ally, 305.3a) —
#                  so Skewer, whose damage is dealt BY the chosen ally rather
#                  than by the hero, counts here and in neither hero column.

# player_id ("p1"/"p2") → count
var cards_drawn:        Dictionary = {"p1": 7, "p2": 7}
var cards_played:       Dictionary = {"p1": 0, "p2": 0}
var damage_prevented:   Dictionary = {"p1": 0, "p2": 0}
var resources_placed:   Dictionary = {"p1": 0, "p2": 0}
var hero_combat_damage: Dictionary = {"p1": 0, "p2": 0}
var hero_ability_damage: Dictionary = {"p1": 0, "p2": 0}
var ally_damage:        Dictionary = {"p1": 0, "p2": 0}

# instance_id → the player it was counted for, so a retraction can undo exactly
# the placements that were counted (a face-up quest placement is in neither).
var _counted_resources: Dictionary = {}


func reset() -> void:
	cards_drawn         = {"p1": 7, "p2": 7}
	cards_played        = {"p1": 0, "p2": 0}
	damage_prevented    = {"p1": 0, "p2": 0}
	resources_placed    = {"p1": 0, "p2": 0}
	hero_combat_damage  = {"p1": 0, "p2": 0}
	hero_ability_damage = {"p1": 0, "p2": 0}
	ally_damage         = {"p1": 0, "p2": 0}
	_counted_resources  = {}


# Hand this every GameEvent as it is emitted. Cheap and idempotent per event.
func record_event(event: GameEvent) -> void:
	match event.event_type:
		"card_moved":
			var from_zone: String = event.payload.get("from", "")
			var to_zone:   String = event.payload.get("to", "")
			if from_zone.ends_with("_deck") and to_zone.ends_with("_hand"):
				_bump(cards_drawn, _player_of_zone(to_zone))
			# Symmetric un-draw: cards returned from hand to deck (mulligan
			# redraw, rule 103.4) decrement so the base-7 opening deal isn't
			# double-counted when the redrawn 7 come back as card_moved events.
			elif from_zone.ends_with("_hand") and to_zone.ends_with("_deck"):
				_unbump(cards_drawn, _player_of_zone(from_zone))
		"card_played":
			_bump(cards_played, event.payload.get("player", ""))
		"damage_prevented":
			_add(damage_prevented, event.payload.get("controller", ""),
				int(event.payload.get("amount", 0)))
		"resource_placed":
			if not bool(event.payload.get("face_up", false)):
				var placer: String = event.payload.get("player", "")
				_bump(resources_placed, placer)
				_counted_resources[event.payload.get("card_id", "")] = placer
		"action_retracted":
			# A retracted placement never happened (the card is back in hand).
			# Keyed on the CARD, not the action type: a retracted face-UP quest
			# placement was never counted and must not decrement anything.
			var back_id: String = event.payload.get("card_id", "")
			if event.payload.get("action_type", "") == "place_resource" \
					and _counted_resources.has(back_id):
				_unbump(resources_placed, _counted_resources[back_id])
				_counted_resources.erase(back_id)
		"damage_dealt":
			var dealer: String = event.payload.get("source_controller", "")
			var dmg := int(event.payload.get("amount", 0))
			# An ally source is its own column and never a hero one, so Skewer —
			# whose damage is dealt by the chosen ally, not by the caster's hero —
			# lands here rather than in Hero ability.
			if bool(event.payload.get("source_is_ally", false)):
				_add(ally_damage, dealer, dmg)
			elif bool(event.payload.get("source_is_hero", false)):
				if bool(event.payload.get("combat", false)):
					_add(hero_combat_damage, dealer, dmg)
				elif bool(event.payload.get("from_ability", false)):
					_add(hero_ability_damage, dealer, dmg)


func drawn(player_id: String) -> int:
	return int(cards_drawn.get(player_id, 0))


func played(player_id: String) -> int:
	return int(cards_played.get(player_id, 0))


func prevented(player_id: String) -> int:
	return int(damage_prevented.get(player_id, 0))


func resourced(player_id: String) -> int:
	return int(resources_placed.get(player_id, 0))


func hero_combat_dmg(player_id: String) -> int:
	return int(hero_combat_damage.get(player_id, 0))


func hero_ability_dmg(player_id: String) -> int:
	return int(hero_ability_damage.get(player_id, 0))


func ally_dmg(player_id: String) -> int:
	return int(ally_damage.get(player_id, 0))


func _bump(counter: Dictionary, player_id: String) -> void:
	if player_id == "":
		return
	counter[player_id] = int(counter.get(player_id, 0)) + 1


func _add(counter: Dictionary, player_id: String, amount: int) -> void:
	if player_id == "" or amount <= 0:
		return
	counter[player_id] = int(counter.get(player_id, 0)) + amount


func _unbump(counter: Dictionary, player_id: String) -> void:
	if player_id == "":
		return
	counter[player_id] = int(counter.get(player_id, 0)) - 1


# "p1_hand" → "p1"
static func _player_of_zone(zone_id: String) -> String:
	var idx := zone_id.find("_")
	return zone_id.substr(0, idx) if idx > 0 else ""
