class_name CardEffects
extends RefCounted

# Bespoke per-card power implementations, keyed by card_id ("expansion-collector_number",
# matching CardDatabase's key format). Used when a card's effects-column recipe has
# action=custom — i.e. its power doesn't fit a generic templated action.
#
# Each implementation is called after the generic engine has already paid the power's
# cost (exhaust/resources) and set any once-per-turn/power-used flags — these only need
# to implement what the power actually DOES. They're async (may await a target pick via
# sandbox._prompt_target()), so callers must `await CardEffects.run(...)`.
#
# Currently empty — every card implemented so far has fit a generic templated action.

const SUPPORTED_IDS: Array = []

static func is_implemented(card_id: String) -> bool:
	return card_id in SUPPORTED_IDS

static func run(sandbox, card: Control) -> void:
	match card.card_id:
		_:
			pass
