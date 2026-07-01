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


static func make(p_player_id: String) -> PlayerState:
	var ps := PlayerState.new()
	ps.player_id = p_player_id
	return ps


func to_dict() -> Dictionary:
	return {
		"player_id":                player_id,
		"hero_instance_id":         hero_instance_id,
		"resource_placed_this_turn": resource_placed_this_turn,
	}

static func from_dict(d: Dictionary) -> PlayerState:
	var ps := PlayerState.new()
	ps.player_id                = d["player_id"]
	ps.hero_instance_id         = d.get("hero_instance_id", "")
	ps.resource_placed_this_turn = d.get("resource_placed_this_turn", false)
	return ps
