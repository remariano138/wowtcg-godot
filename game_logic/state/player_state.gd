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

# Damage prevention pool from exhausted armor (rule 717.2c). Built at an open
# prevention point (StackResolver.choose_prevention) for the packet about to
# land; consumed by damage dealt to this player's HERO (allies are not
# protected). Excess DEF beyond the packet is wasted — cleared once the packet
# has landed (and defensively at window close / turn start).
var damage_prevention: int = 0

# Gorebelly's flip power: "You pay (3) less the next time you strike with a
# Melee weapon this turn." Consumed by the next melee strike; cleared at the
# start of every turn (so it lasts exactly the turn it was gained in).
var melee_strike_discount: int = 0

# Rapid Fire: "Whenever you strike with a Ranged weapon this turn, you may pay
# (1). If you do, ready that weapon and your hero." The COST to pay, or -1 when
# not active (cost 0 is a legal grant). Unlike Windfury Weapon's attachment this
# is a player-wide grant covering EVERY Ranged weapon, and it is deliberately
# NOT once per turn ("whenever") — the whole point is repeat strikes. Cleared at
# the start of every turn, so it lasts exactly the turn it was gained in.
var rapid_fire_ready_cost: int = -1

# Nature's Swiftness: "You pay (5) less to play your next card this turn."
# The DISCOUNT (a negative delta, 0 = inactive), read live inside
# GameState.get_play_cost and consumed by the next card this player plays
# (cost paid on chain entry, rule 412.2 — so retracting that announcement
# restores it). Cleared at the start of every turn, so it lasts exactly the
# turn it was gained in and is never refunded once the card resolved.
var next_card_cost_mod: int = 0

# Cold Blood: "When your hero deals damage to an ally this turn, destroy that
# ally." The turn-event-log INDEX at which the grant became active, or -1 when
# inactive. The trigger is forward-looking — an ally your hero damaged earlier
# this turn is not retroactively doomed — and the log is what carries the
# "which ally, dealt by whom" facts (see game_logic/turn_state_flags.md), so an
# index into it is the whole state this effect needs. Cleared at the start of
# every turn, so it lasts exactly the turn it was gained in.
var cold_blood_from_index: int = -1

# Operation Recombobulation (dark_portal_292): "When an opposing non-token ally
# is destroyed this turn, you may put an ally card from your graveyard into your
# hand." Cold Blood's shape exactly — the turn-event-log INDEX at which the quest
# reward became active, or -1 when inactive. Forward-looking as printed (an ally
# that died earlier this turn does not retro-trigger), and the log's
# `ally_destroyed` entries carry the facts (whose ally, was it a token) that are
# unrecoverable from the board once the card is in a graveyard. The sweep
# advances this index past every entry it has handled, so a death fires the
# reward exactly once. Cleared at the start of every turn.
var recomb_from_index: int = -1

# Elendril's flip power: "Your Ranged weapons have +3 ATK this turn." Applied
# to this player's Ranged weapons in GameState.get_atk; cleared at the start of
# every turn (so it lasts exactly the turn it was gained in).
var ranged_weapon_atk_bonus: int = 0

# Party-wide "+X ATK while attacking this turn" grants (Rayder, For the
# Horde!). Kept here instead of as per-card buffs so they also apply to
# allies that enter play AFTER the effect resolves, for the rest of the turn.
# Each entry: {"amount": int, "alignment": String (""=any, else e.g. "Horde")}.
# Reset at the start of each turn.
var party_atk_buffs_this_turn: Array = []


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
