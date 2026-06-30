extends SandboxTable

# DuelTable layers real rule-enforcement on top of SandboxTable's mechanics.
# Sandbox's can_propose_attacker/can_propose_defender hooks default to "always legal";
# override them here to enforce keywords.

func can_propose_attacker(card: Control) -> bool:
	if card.just_summoned and not card.has_keyword("ferocity"):
		return false
	return true

func can_propose_defender(card: Control) -> bool:
	if card.has_keyword("elusive"):
		return false
	return true
