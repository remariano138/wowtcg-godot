extends SandboxTable

# DuelTable layers real rule-enforcement on top of SandboxTable's mechanics.
# Sandbox's can_propose_attacker/can_propose_defender/can_play_card hooks default
# to "always legal"; override them here to enforce actual rules.

func show_sandbox_tools() -> bool:
	return false

func can_propose_attacker(card: Control) -> bool:
	if card.card_owner != _current_turn_player():
		return false
	if card.just_summoned and not card.has_keyword("ferocity"):
		return false
	if card.has_keyword("cant_attack"):
		return false
	return true

func can_propose_defender(card: Control, attacker: Control = null) -> bool:
	if card.has_keyword("elusive"):
		return false
	# 601.2c: "can attack only [X] if able" — if attacker has one or more legal
	# lockers (e.g. Sarmoth), it must target one of them; this only narrows the
	# defender pool, it never forces an attack. If attacker has no legal lockers
	# (none in play, or attacker can't legally hit any of them), normal legality
	# resumes for any other defender.
	if attacker != null:
		var lockers = _attack_lockers_for(attacker)
		if not lockers.is_empty():
			return card in lockers
	return true

func can_play_card(card: Control) -> bool:
	var payer = _hand_owner_of(card)
	if payer != _current_turn_player():
		_warn_dialog.dialog_text = "It's not %s's turn." % _player_name(payer)
		_warn_dialog.popup_centered()
		return false
	var min_cost = card.cost_base if card.cost_x else card.cost
	if min_cost > 0 and _available_resources(payer) < min_cost:
		_warn_not_enough_resources(card)
		return false
	return true

func can_place_resource(player: String) -> bool:
	return not _resource_placed_this_turn.get(player, false)

func can_act() -> bool:
	# Nothing is a legal action during the Beginning phase except mulligan/ready,
	# which go through their own dedicated buttons, not this gate.
	return game_manager.turn_state != GameManager.TurnState.BEGINNING

func can_use_power_reason(card: Control) -> String:
	# A face-down card is just a resource — same as Sandbox's check, see there.
	if card.face_down:
		return "Face down"
	if card.card_type == "Hero" and card.power_used:
		return "Already used this game"
	for r in _parse_effects(card.effects):
		if r.get("trigger", "") != "activate":
			continue
		if r.get("turn_restricted", "false") == "true" and card.card_owner != _current_turn_player():
			return "Use only on your turn"
		var cost_tokens = r.get("cost", "").split(",")
		var has_exhaust_cost = false
		for token in cost_tokens:
			token = token.strip_edges()
			if token.begins_with("exhaust"):
				has_exhaust_cost = true
				if card.exhausted:
					return "Already exhausted"
			if token.begins_with("resources"):
				var parts = token.split(":")
				var amount = int(parts[1]) if parts.size() > 1 else 0
				if _available_resources(card.card_owner) < amount:
					return "Not enough resources (need %d, have %d)" % [amount, _available_resources(card.card_owner)]
			if token.begins_with("flip") and card.card_type == "Hero" and card.cost > 0:
				if _available_resources(card.card_owner) < card.cost:
					return "Not enough resources (need %d, have %d)" % [card.cost, _available_resources(card.card_owner)]
		if r.get("once_per_turn", "false") == "true" and not card.can_activate_once_per_turn():
			return "Already used this turn"
		# 701.3: an activated power is specifically a payment power with the Activate
		# symbol, defined by exhausting being part of its cost. ONLY those powers
		# carry the "must have been in your party since the start of your turn"
		# restriction — a payment power that doesn't exhaust (e.g. Hierophant
		# Caydiem, Acolyte Demia) is not a 701.3 "activated power" and has no such
		# restriction (Ferocity is irrelevant here either way, since it only ever
		# matters for the powers this restriction actually applies to).
		if has_exhaust_cost and card.card_type == "Ally" and card.just_summoned:
			return "Hasn't been in your party since the start of your turn"
		return ""
	return "No activatable power"
