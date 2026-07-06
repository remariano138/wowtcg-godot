class_name Buff
extends Resource

# A single stat modifier or restriction applied to a CardInstance.
# Multiple buffs from different sources stack independently — the rules engine
# sums all buffs of a given stat when computing a derived value (e.g. current_atk).
#
# Duration types:
#   "turns"               — lasts turns_remaining turns; decremented by end-of-turn sweep
#   "while_source_in_play" — removed when source_id leaves play (zone-change sweep)
#   "permanent"           — never removed automatically; requires an explicit effect
#
# Stat strings (extensible — add new ones as cards require):
#   "atk"             — modifies attack value
#   "health"          — modifies max health (not damage)
#   "cost"            — modifies play cost (can be negative = discount)
#   "cannot_attack"   — restriction; rules engine treats total > 0 as "can't attack"
#   "cannot_protect"  — restriction; rules engine treats total > 0 as "can't protect"
#   "cannot_ready"    — restriction; rules engine treats total > 0 as "can't ready"
#   (add more as needed — the Buff data model doesn't need to change per new stat)

var buff_id: String        # human-readable type name, e.g. "cyclone_restrict_attack"
var source_id: String      # instance_id of the card that created this buff
var stat: String           # which stat or restriction this buff affects
var amount: int            # magnitude; negative = penalty; for restrictions, 1 = active
var duration_type: String  # "turns" | "while_source_in_play" | "permanent"
var turns_remaining: int   # only meaningful when duration_type == "turns"

# Optional gate on when the buff's amount actually applies. The buff always
# exists (and expires) per its duration; condition only affects whether the
# rules engine counts it in a derived stat at query time.
#   ""                — always applies (default)
#   "while_attacking" — applies only while the buffed card is the combat attacker
var condition: String = ""


static func make(
		p_buff_id: String,
		p_source_id: String,
		p_stat: String,
		p_amount: int,
		p_duration_type: String,
		p_turns_remaining: int = 0,
		p_condition: String = "") -> Buff:
	var b := Buff.new()
	b.buff_id          = p_buff_id
	b.source_id        = p_source_id
	b.stat             = p_stat
	b.amount           = p_amount
	b.duration_type    = p_duration_type
	b.turns_remaining  = p_turns_remaining
	b.condition        = p_condition
	return b


func to_dict() -> Dictionary:
	return {
		"buff_id":         buff_id,
		"source_id":       source_id,
		"stat":            stat,
		"amount":          amount,
		"duration_type":   duration_type,
		"turns_remaining": turns_remaining,
		"condition":       condition,
	}

static func from_dict(d: Dictionary) -> Buff:
	return Buff.make(
		d["buff_id"],
		d["source_id"],
		d["stat"],
		d["amount"],
		d["duration_type"],
		d.get("turns_remaining", 0),
		d.get("condition", "")
	)
