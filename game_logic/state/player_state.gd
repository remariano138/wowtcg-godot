class_name PlayerState
extends Resource

# Per-player state that cannot be derived from zones or card instances alone.
# Available resources, hand size, board presence — all derived by querying
# GameState zones. Only flags that require explicit tracking live here.

var player_id: String

# Convenience reference to this player's hero — the same card is also in
# the p{N}_hero_row zone. Stored here so callers don't have to scan the zone.
var hero_instance_id: String = ""

# Enforces the once-per-turn resource placement rule (rule 412).
# Reset to false at the start of this player's turn.
var resource_placed_this_turn: bool = false

# Tracks whether this player's hero has already used their power this turn.
# In the physical game the hero card flips face-down; we track it here instead
# since we don't have hero back-art.  Reset at the start of this player's turn.
var has_used_hero_power: bool = false

# Rule 415.4b: default is 7; some card effects raise or lower it.
var max_hand_size: int = 7

# Maximum number of Pets a player may have in their ally_row simultaneously.
# Default is 1; some card effects increase this.
var pet_capacity: int = 1

# Damage prevention pool ("current block") from exhausted armor (rule 304.3).
# Built up via use_armor_prevention actions; consumed by damage dealt to this
# player's HERO (allies are not protected). Cleared at combat conclusion,
# when the priority window closes, and at the start of each turn.
var damage_prevention: int = 0

# Rule-condition tracking for quests like Torek's Assault: whether this
# player's hero was dealt damage by an opposing ally this turn. Reset at the
# start of each turn.
var hero_damaged_by_ally_this_turn: bool = false


static func make(p_player_id: String) -> PlayerState:
	var ps := PlayerState.new()
	ps.player_id = p_player_id
	return ps


func to_dict() -> Dictionary:
	return {
		"player_id":                player_id,
		"hero_instance_id":         hero_instance_id,
		"resource_placed_this_turn": resource_placed_this_turn,
		"has_used_hero_power":      has_used_hero_power,
		"max_hand_size":            max_hand_size,
		"pet_capacity":             pet_capacity,
	}

static func from_dict(d: Dictionary) -> PlayerState:
	var ps := PlayerState.new()
	ps.player_id                = d["player_id"]
	ps.hero_instance_id         = d.get("hero_instance_id", "")
	ps.resource_placed_this_turn = d.get("resource_placed_this_turn", false)
	ps.has_used_hero_power      = d.get("has_used_hero_power", false)
	ps.max_hand_size            = d.get("max_hand_size", 7)
	ps.pet_capacity             = d.get("pet_capacity", 1)
	return ps
