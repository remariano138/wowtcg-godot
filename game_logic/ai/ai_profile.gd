class_name AIProfile
extends RefCounted

# AI profile referenced by DeckDefinition.recommended_ai_id (spec §9.7).
# Stored as its own JSON file under res://ai_profiles/, linked to decks by id.
# ai_class selects which AI implementation pilots the deck; strategy_data is
# free-form tuning data for that implementation (unused by current AIs).

var ai_id: String = ""
var ai_class: String = ""        # "base" -> BaseAI, "fullrandom" -> FullRandomAI,
                                 # "generic" -> GenericAI
var strategy_data: Dictionary = {}


func make_ai() -> Object:
	match ai_class:
		"base":       return BaseAI.new()
		"fullrandom": return FullRandomAI.new()
		"generic":    return GenericAI.new()
		_:
			push_error("AIProfile %s: unknown ai_class '%s'" % [ai_id, ai_class])
			return null


func to_dict() -> Dictionary:
	return {"ai_id": ai_id, "ai_class": ai_class, "strategy_data": strategy_data}


static func from_dict(d: Dictionary) -> AIProfile:
	var p := AIProfile.new()
	p.ai_id = str(d.get("ai_id", ""))
	p.ai_class = str(d.get("ai_class", ""))
	p.strategy_data = d.get("strategy_data", {})
	return p
