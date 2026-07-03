class_name InputRouter
extends Node

# Translates human input into PendingActions submitted to StackResolver.
# The ONLY place that calls submit_action / pass_priority for a human player.
#
# Responsibilities:
#   - Spacebar / Enter → pass_priority
#   - Card click → build PendingAction → submit_action
#   - Emit highlights_updated so BoardRenderer can tint playable cards
#
# Never mutates GameState directly.
# Never touches card visual nodes — BoardRenderer owns those.
# Both human and AI call the same StackResolver entry points (spec §7.1).

signal highlights_updated(playable_ids: Array, color: Color)
signal conditional_highlights_updated(orange_ids: Array)
# dmg_type: "fire", "melee", etc.  "" = unspecified (show crosshair)
# dmg_amount: damage shown on the cursor overlay; 0 = don't show
signal targeting_started(source_id: String, dmg_type: String, dmg_amount: int)
signal targeting_cancelled()
signal discard_mode_started(count: int)
signal discard_mode_ended()
signal pet_sacrifice_mode_started(candidate_ids: Array)
signal pet_sacrifice_mode_ended()
# Emitted when a power requires the player to select a numeric X value before targeting.
# hero_id: the hero whose power is being used. max_x: maximum selectable value (hero HP - 1).
signal x_select_requested(hero_id: String, max_x: int)

var state: GameState
var db
var local_player: String

# ── Targeting state ────────────────────────────────────────────────────────────
var _targeting_source:      String = ""   # instance_id of attacker / hero; "" = not targeting
var _targeting_action_type: String = ""   # "propose_combat" or "activate_power"
var _targeting_dmg_type:    String = ""   # damage type icon key (or "" for crosshair)
var _in_discard_mode: bool = false        # true while player must choose cards to discard
var _in_pet_sacrifice_mode: bool = false  # true while player must choose a pet to sacrifice
var _pet_sacrifice_candidates: Array[String] = []
# Two-phase targeting for deal_damage_and_heal: first pick is stored here, second completes the action.
var _targeting_first_target: String = ""  # "" = first pick pending; non-empty = waiting for second
# Stored X value for deal_x_damage_to_ally powers; set when player confirms the X dialog.
var _targeting_x_value: int = 0
# Color used for card highlights; changes per mode (green = play, red = mandatory choice).
var _highlight_color: Color = Color(0.2, 1.0, 0.3)


func setup(p_state: GameState, p_db, p_player: String) -> void:
	state        = p_state
	db           = p_db
	local_player = p_player


# ── Input handling ─────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not state:
		return
	if event.is_action_pressed("ui_accept"):   # Spacebar or Enter
		pass_priority_action()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"): # Escape
		if _targeting_source != "":
			cancel_targeting()
		else:
			retract_last_action()
		get_viewport().set_input_as_handled()


# Called by BoardRenderer when a card visual is clicked.
func handle_card_click(instance_id: String) -> void:
	if not state:
		return

	# ── Pet sacrifice mode: click sacrifices the chosen pet ──────────────────
	if _in_pet_sacrifice_mode:
		_handle_pet_sacrifice_click(instance_id)
		return

	# ── Discard mode: click discards the chosen hand card ─────────────────────
	if _in_discard_mode:
		_handle_discard_click(instance_id)
		return

	# ── Targeting mode: click selects the target ─────────────────────────────
	if _targeting_source != "":
		_handle_targeting_click(instance_id)
		return

	if state.priority_player != local_player:
		return
	var card := state.get_card(instance_id)
	if not card or card.controller != local_player:
		return

	# ── In-play ally / hero left-click → enter attack targeting ───────────────
	if state.is_in_play(instance_id):
		var zone := state.zones.get(card.zone_id) as Zone
		if zone and zone.zone_type in ["ally_row", "hero_row"]:
			# Only enter targeting if combat can actually be proposed right now (rule 601.1).
			var can_propose := state.phase == "action" \
				and state.turn_player == local_player \
				and state.pending_actions.is_empty() \
				and not state.combat_attack_window \
				and not state.combat_defend_window \
				and not state.in_protect_point
			if can_propose:
				var legal := StackResolver.get_legal_attackers(state, local_player, db)
				if instance_id in legal:
					start_attack_targeting(instance_id)
			return

	# ── Hand card left-click → play / place ───────────────────────────────────
	var action_type := _action_type_for(instance_id)
	if action_type == "":
		return
	# Abilities with targets: enter targeting mode rather than submitting directly.
	if action_type == "play_ability" and _ability_needs_target(instance_id):
		start_targeting(instance_id, "play_ability", _card_dmg_type(instance_id), 0)
		return
	var action := PendingAction.make(action_type, local_player,
			_params_for(instance_id, action_type))
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	var pass_events := StackResolver.pass_priority(state, db)
	EventBus.emit_events(pass_events)
	refresh_highlights()


# ── Discard mode ───────────────────────────────────────────────────────────────

func start_discard_mode(count: int) -> void:
	_in_discard_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)  # red — mandatory discard
	refresh_highlights()
	discard_mode_started.emit(count)


func _handle_discard_click(instance_id: String) -> void:
	var card := state.get_card(instance_id)
	if not card or card.controller != local_player:
		return
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return
	var events := StackResolver.choose_discard(state, instance_id, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	# Stay in discard mode if more cards still need to be discarded.
	if state.pending_discard_count <= 0:
		_in_discard_mode = false
		_highlight_color = Color(0.2, 1.0, 0.3)
		discard_mode_ended.emit()
	refresh_highlights()


# ── Pet sacrifice mode ─────────────────────────────────────────────────────────

func start_pet_sacrifice_mode(candidate_ids: Array) -> void:
	_in_pet_sacrifice_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)  # red — mandatory pet sacrifice
	_pet_sacrifice_candidates.clear()
	for cid in candidate_ids:
		_pet_sacrifice_candidates.append(cid as String)
	refresh_highlights()
	pet_sacrifice_mode_started.emit(candidate_ids)


func _handle_pet_sacrifice_click(instance_id: String) -> void:
	if instance_id not in _pet_sacrifice_candidates:
		return
	var events := StackResolver.choose_pet_sacrifice(state, instance_id, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	if state.pending_pet_sacrifice_player == "":
		_in_pet_sacrifice_mode = false
		_highlight_color = Color(0.2, 1.0, 0.3)
		_pet_sacrifice_candidates.clear()
		pet_sacrifice_mode_ended.emit()
	else:
		_pet_sacrifice_candidates.clear()
		for cid: String in state.pending_pet_sacrifice_ids:
			_pet_sacrifice_candidates.append(cid)
	refresh_highlights()


# ── Targeting ──────────────────────────────────────────────────────────────────

# General entry point.  action_type is "propose_combat" or "activate_power".
# dmg_type is the icon key ("fire", "melee", …) or "" for a crosshair cursor.
func start_targeting(source_id: String, action_type: String,
		dmg_type: String, dmg_amount: int = 0) -> void:
	_targeting_source      = source_id
	_targeting_action_type = action_type
	_targeting_dmg_type    = dmg_type
	refresh_highlights()
	targeting_started.emit(source_id, dmg_type, dmg_amount)


# Convenience wrapper: look up the attacker's dmg_type / ATK and enter combat targeting.
func start_attack_targeting(attacker_id: String) -> void:
	var dmg_type   := ""   # default → crosshair; set only when card has an explicit dmg_type
	var dmg_amount := 0
	if db:
		var card := state.get_card(attacker_id)
		if card:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and def.dmg_type != "":
				dmg_type = def.dmg_type.to_lower()
	if state:
		dmg_amount = state.get_atk(attacker_id, db)
	start_targeting(attacker_id, "propose_combat", dmg_type, dmg_amount)


# Convenience wrapper for enters-play targeted effects (e.g. Taz'dingo).
func start_enter_play_targeting(card_id: String, dmg_type: String, dmg_amount: int) -> void:
	start_targeting(card_id, "choose_enter_play_target", dmg_type, dmg_amount)


# Abort targeting — called by Escape key or scene logic.
func cancel_targeting() -> void:
	_targeting_source       = ""
	_targeting_action_type  = ""
	_targeting_dmg_type     = ""
	_targeting_first_target = ""
	_targeting_x_value      = 0
	refresh_highlights()
	targeting_cancelled.emit()


func _handle_targeting_click(instance_id: String) -> void:
	match _targeting_action_type:
		"propose_combat":            _handle_combat_targeting_click(instance_id)
		"activate_power":            _handle_power_targeting_click(instance_id)
		"activate_power_x":          _handle_x_power_targeting_click(instance_id)
		"choose_enter_play_target":  _handle_enter_play_targeting_click(instance_id)
		"play_instant":              _handle_instant_targeting_click(instance_id)
		"play_ability":              _handle_ability_targeting_click(instance_id)
		"use_ally_power":            _handle_ally_power_targeting_click(instance_id)


func _handle_combat_targeting_click(instance_id: String) -> void:
	var legal := StackResolver.get_legal_defenders(state, _targeting_source, db)
	if instance_id in legal:
		var action := PendingAction.make("propose_combat", local_player, {
			"attacker_id": _targeting_source, "defender_id": instance_id,
		})
		_targeting_source = ""
		targeting_cancelled.emit()
		var events := StackResolver.submit_action(state, action, db)
		if events.is_empty():
			return
		EventBus.emit_events(events)
		var pass_events := StackResolver.pass_priority(state, db)
		EventBus.emit_events(pass_events)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


func _handle_enter_play_targeting_click(instance_id: String) -> void:
	var action := PendingAction.make("choose_enter_play_target", local_player, {
		"source_card_id": _targeting_source, "target_id": instance_id,
	})
	if StackResolver.can_submit(state, action, db):
		var events := StackResolver.submit_action(state, action, db)
		EventBus.emit_events(events)
		# cancel_targeting fires targeting_cancelled; playtest._on_targeting_cancelled
		# checks pending_actions for an existing choose_enter_play_target before restarting.
		cancel_targeting()
		var pass_events := StackResolver.pass_priority(state, db)
		EventBus.emit_events(pass_events)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


func _handle_ability_targeting_click(instance_id: String) -> void:
	var action := PendingAction.make("play_ability", local_player, {
		"card_id": _targeting_source, "target_id": instance_id,
	})
	if StackResolver.can_submit(state, action, db):
		_targeting_source = ""
		targeting_cancelled.emit()
		var events := StackResolver.submit_action(state, action, db)
		if not events.is_empty():
			EventBus.emit_events(events)
			var pass_events := StackResolver.pass_priority(state, db)
			EventBus.emit_events(pass_events)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


func _handle_instant_targeting_click(instance_id: String) -> void:
	var action := PendingAction.make("play_instant", local_player, {
		"card_id": _targeting_source, "target_id": instance_id,
	})
	if StackResolver.can_submit(state, action, db):
		_targeting_source = ""
		targeting_cancelled.emit()
		var events := StackResolver.submit_action(state, action, db)
		if events.is_empty():
			return
		EventBus.emit_events(events)
		var pass_events := StackResolver.pass_priority(state, db)
		EventBus.emit_events(pass_events)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


func _handle_power_targeting_click(instance_id: String) -> void:
	# Two-phase for deal_damage_and_heal: first click = damage target, second = heal target.
	if _is_damage_and_heal_power(_targeting_source):
		if _targeting_first_target == "":
			# Phase 1: validate as a damage target by probing with a placeholder heal target.
			var probe_heal := _any_valid_heal_target(_targeting_source, instance_id)
			if probe_heal != "":
				_targeting_first_target = instance_id
				targeting_started.emit(_targeting_source, "heal", 0)   # re-emit to update status
				refresh_highlights()
			elif instance_id == _targeting_source:
				cancel_targeting()
			return
		else:
			# Phase 2: instance_id is the heal target.
			var action := PendingAction.make("activate_power", local_player, {
				"hero_id": _targeting_source,
				"target_id": _targeting_first_target,
				"heal_target_id": instance_id,
			})
			if StackResolver.can_submit(state, action, db):
				_targeting_source       = ""
				_targeting_first_target = ""
				targeting_cancelled.emit()
				var events := StackResolver.submit_action(state, action, db)
				if events.is_empty():
					return
				EventBus.emit_events(events)
				var pass_events := StackResolver.pass_priority(state, db)
				EventBus.emit_events(pass_events)
				refresh_highlights()
			elif instance_id == _targeting_first_target:
				# Clicked the damage target again — go back to phase 1.
				_targeting_first_target = ""
				targeting_started.emit(_targeting_source, _targeting_dmg_type, 0)
				refresh_highlights()
			return

	var action := PendingAction.make("activate_power", local_player, {
		"hero_id": _targeting_source, "target_id": instance_id,
	})
	if StackResolver.can_submit(state, action, db):
		_targeting_source = ""
		targeting_cancelled.emit()
		var events := StackResolver.submit_action(state, action, db)
		if events.is_empty():
			return
		EventBus.emit_events(events)
		var pass_events := StackResolver.pass_priority(state, db)
		EventBus.emit_events(pass_events)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


# Called by spacebar handler and also exposed so the scene can wire a button.
func retract_last_action() -> void:
	if not state or not StackResolver.can_retract(state, local_player):
		return
	var events := StackResolver.retract_last(state, local_player, db)
	EventBus.emit_events(events)
	refresh_highlights()


func pass_priority_action() -> void:
	if not state or state.priority_player != local_player:
		return
	var events := StackResolver.pass_priority(state, db)
	EventBus.emit_events(events)
	refresh_highlights()


# ── Highlight query ────────────────────────────────────────────────────────────
# Uses the same can_submit validator as the actual submission — no duplicate
# rules logic in the UI (spec §7.2).

func get_playable_card_ids() -> Array:
	if not state:
		return []

	# Pet sacrifice mode: highlight the candidate pets.
	if _in_pet_sacrifice_mode and state.pending_pet_sacrifice_player == local_player:
		var result: Array = []
		for cid: String in _pet_sacrifice_candidates:
			result.append(cid)
		return result

	# Discard mode: all local hand cards are valid discard choices.
	if _in_discard_mode and state.pending_discard_player == local_player:
		var result: Array = []
		for card in state.cards_in_zone(local_player + "_hand"):
			result.append(card.instance_id)
		return result

	if state.priority_player != local_player:
		return []

	# Targeting mode: highlight valid targets.
	if _targeting_source != "":
		match _targeting_action_type:
			"propose_combat":
				return StackResolver.get_legal_defenders(state, _targeting_source, db)
			"activate_power":
				return _get_hero_power_targets(_targeting_source)
			"activate_power_x":
				return _get_x_power_targets(_targeting_source)
			"choose_enter_play_target":
				return _get_enter_play_targets(_targeting_source)
			"play_instant":
				return _get_instant_targets(_targeting_source)
			"play_ability":
				return _get_ability_targets(_targeting_source)
			"use_ally_power":
				return _get_ally_power_targets(_targeting_source)
		return []

	var result: Array = []
	# Hand card plays.
	for card in state.cards_in_zone(local_player + "_hand"):
		var atype := _action_type_for(card.instance_id)
		if atype == "":
			continue
		# Abilities are highlighted green when playable even before a target is chosen —
		# can_submit would reject them with no target_id, so use the looser probe.
		if atype == "play_ability":
			if StackResolver.can_play_ability_no_target_check(
					state, card.instance_id, local_player, db):
				result.append(card.instance_id)
			continue
		var action := PendingAction.make(atype, local_player,
				_params_for(card.instance_id, atype))
		if StackResolver.can_submit(state, action, db):
			result.append(card.instance_id)
	# Legal attackers (non-combat action phase only — rule 601.1).
	if state.phase == "action" and state.turn_player == local_player \
			and state.pending_actions.is_empty() \
			and not state.combat_attack_window and not state.combat_defend_window \
			and not state.in_protect_point:
		result.append_array(StackResolver.get_legal_attackers(state, local_player, db))
	# Face-up quests in resource row whose cost is currently payable (simple quests).
	for card in state.cards_in_zone(local_player + "_resource_row"):
		if card.face_down:
			continue
		var def: CardDef = db.get_def(card.card_def_id) if db else null
		if not def or def.card_type != "Quest":
			continue
		var action := PendingAction.make("use_quest", local_player,
				{"quest_id": card.instance_id})
		if StackResolver.can_submit(state, action, db):
			result.append(card.instance_id)
	return result


# Returns instance_ids of face-up quests whose non-cost trigger condition is
# currently met (e.g. "killed 3 allies this game"). These light up orange —
# distinct from simple cost-only quests that go green via get_playable_card_ids.
# Returns [] until conditional quests are added to the card pool.
func get_conditional_quest_ids() -> Array:
	return []


func refresh_highlights() -> void:
	highlights_updated.emit(get_playable_card_ids(), _highlight_color)
	conditional_highlights_updated.emit(get_conditional_quest_ids())


# True if the local player has at least one legal action available right now.
# Broader than get_playable_card_ids: also counts face-down resource placement,
# which is only reachable via the context menu (not left-click).
func has_any_legal_play() -> bool:
	if not state or state.priority_player != local_player:
		return false
	if not get_playable_card_ids().is_empty():
		return true
	# Check face-down resource placement (context-menu only).
	var fd_action_template := PendingAction.make("place_resource", local_player,
		{"card_id": "", "face_up": false})
	for card in state.cards_in_zone(local_player + "_hand"):
		fd_action_template.params["card_id"] = card.instance_id
		if StackResolver.can_submit(state, fd_action_template, db):
			return true
	return false


# Returns Array of {label: String, action: PendingAction, enabled: bool}
# Works for both hand cards and in-play characters.
func get_context_actions(instance_id: String) -> Array:
	if not state or not db:
		return []
	var card := state.get_card(instance_id)
	if not card or card.controller != local_player:
		return []
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return []

	# ── Resource row cards ────────────────────────────────────────────────────
	if state.is_in_play(instance_id):
		var zone := state.zones.get(card.zone_id) as Zone
		if zone and zone.zone_type == "resource_row":
			if card.face_down:
				return []  # no actions on face-down resources
			if def.card_type == "Quest":
				var a := PendingAction.make("use_quest", local_player,
					{"quest_id": instance_id})
				return [{"label": "Complete Quest — %s" % def.card_name,
					"action": a, "enabled": StackResolver.can_submit(state, a, db)}]
			return []  # face-up non-quest resources also have no actions

	# ── In-play characters: Attack + (heroes) Hero Power ─────────────────────
	if state.is_in_play(instance_id):
		var zone := state.zones.get(card.zone_id) as Zone
		if zone and zone.zone_type in ["ally_row", "hero_row"]:
			var result: Array = []

			var legal_attackers := StackResolver.get_legal_attackers(state, local_player, db)
			var can_attack := state.priority_player == local_player \
				and instance_id in legal_attackers \
				and state.phase == "action" \
				and state.turn_player == local_player \
				and state.pending_actions.is_empty() \
				and not state.combat_attack_window and not state.combat_defend_window \
				and not state.in_protect_point
			result.append({"label": "Attack",
				"action": PendingAction.make("begin_attack_targeting",
					local_player, {"attacker_id": instance_id}),
				"enabled": can_attack})

			# Ally activated power (if the ally has one).
			if zone.zone_type == "ally_row" and card.controller == local_player:
				var ap_data := StackResolver._ally_activated_power(def)
				if ap_data != {}:
					var ap_needs_target: bool = (ap_data.get("targets", "") as String) in ["hero_or_ally"]
					var ap_enabled: bool
					if ap_needs_target:
						# Check affordability only (target chosen after targeting mode starts).
						# No turn_player restriction — ally powers work on either player's turn
						# as long as you hold priority (e.g. defending with Grimdron's power).
						ap_enabled = not card.is_exhausted and not card.just_summoned \
							and state.get_available_resources(local_player) >= int(ap_data.get("resource_cost", 0)) \
							and state.phase == "action" and state.priority_player == local_player \
							and state.pending_actions.is_empty()
					else:
						var ap_action := PendingAction.make("use_ally_power", local_player,
							{"card_id": instance_id})
						ap_enabled = StackResolver.can_submit(state, ap_action, db)
					result.append({"label": "Activate Power",
						"action": PendingAction.make("use_ally_power", local_player,
							{"card_id": instance_id, "_needs_target": ap_needs_target}),
						"enabled": ap_enabled})

			# Hero power entry (heroes only, controlled by local player).
			if zone.zone_type == "hero_row" and card.controller == local_player:
				var ps := state.players.get(local_player) as PlayerState
				if ps and ps.hero_instance_id == instance_id:
					var power_check := PendingAction.make("activate_power", local_player,
						{"hero_id": instance_id, "target_id": ""})
					var can_power := StackResolver.can_submit(state, power_check, db)
					var power_atype := "begin_power_targeting" \
						if _hero_power_needs_target(instance_id) \
						else "use_hero_power_direct"
					result.append({"label": "Use Hero Power",
						"action": PendingAction.make(power_atype, local_player,
							{"hero_id": instance_id}),
						"enabled": can_power})

			return result

	# ── Hand cards ─────────────────────────────────────────────────────────────
	var result: Array = []
	var is_resource_type := def.card_type in ["Quest", "Location"]

	if not is_resource_type:
		var play_type := _action_type_for(instance_id)
		if play_type != "" and play_type != "place_resource":
			var a := PendingAction.make(play_type, local_player, {"card_id": instance_id})
			var enabled: bool
			if play_type == "play_ability":
				# Use no-target probe so the item shows enabled before the target is chosen.
				enabled = StackResolver.can_play_ability_no_target_check(
					state, instance_id, local_player, db)
			else:
				enabled = StackResolver.can_submit(state, a, db)
			result.append({"label": "Play %s" % def.card_name,
				"action": a, "enabled": enabled})

	if is_resource_type:
		var a := PendingAction.make("place_resource", local_player,
			{"card_id": instance_id, "face_up": true})
		result.append({"label": "Place face-up as resource",
			"action": a, "enabled": StackResolver.can_submit(state, a, db)})

	var fd := PendingAction.make("place_resource", local_player,
		{"card_id": instance_id, "face_up": false})
	result.append({"label": "Place face-down as resource",
		"action": fd, "enabled": StackResolver.can_submit(state, fd, db)})

	return result


func handle_context_action(action: PendingAction) -> void:
	if not state:
		return
	match action.action_type:
		"play_ability":
			if _ability_needs_target(action.params.get("card_id", "")):
				var cid: String = action.params.get("card_id", "")
				start_targeting(cid, "play_ability", _card_dmg_type(cid), 0)
				return
		"play_instant":
			if _instant_needs_target(action.params.get("card_id", "")):
				var cid: String = action.params.get("card_id", "")
				start_targeting(cid, "play_instant", _card_dmg_type(cid), 0)
				return
		"use_ally_power":
			if action.params.get("_needs_target", false):
				var cid: String = action.params.get("card_id", "")
				var ally_card := state.get_card(cid) if state else null
				var ally_def := db.get_def(ally_card.card_def_id) as CardDef if ally_card and db else null
				var ally_ap := StackResolver._ally_activated_power(ally_def) if ally_def else {}
				var ap_dmg_type: String = (ally_ap.get("dmg_type", "") as String).to_lower() if ally_ap else ""
				if ap_dmg_type == "":
					ap_dmg_type = "heal"
				start_targeting(cid, "use_ally_power", ap_dmg_type, int(ally_ap.get("amount", 0)))
				return
		"begin_attack_targeting":
			if state.priority_player == local_player:
				start_attack_targeting(action.params.get("attacker_id", ""))
			return
		"begin_power_targeting":
			if state.priority_player == local_player:
				var hero_id: String = action.params.get("hero_id", "")
				if _hero_power_needs_x(hero_id):
					# X-select flow: emit signal so the UI shows the number input dialog.
					var hero := state.get_card(hero_id)
					var max_x := (state.get_current_hp(hero_id, db) - 1) if hero else 1
					_targeting_source = hero_id
					x_select_requested.emit(hero_id, max_x)
				else:
					start_targeting(hero_id, "activate_power",
						_hero_power_dmg_type(hero_id), _hero_power_dmg_amount(hero_id))
			return
		"use_hero_power_direct":
			if state.priority_player != local_player:
				return
			var hero_id: String = action.params.get("hero_id", "")
			var act := PendingAction.make("activate_power", local_player,
				{"hero_id": hero_id, "target_id": ""})
			var events := StackResolver.submit_action(state, act, db)
			if events.is_empty():
				return
			EventBus.emit_events(events)
			var pass_events := StackResolver.pass_priority(state, db)
			EventBus.emit_events(pass_events)
			refresh_highlights()
			return
	if state.priority_player != local_player:
		return
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	refresh_highlights()


# ── Helpers ────────────────────────────────────────────────────────────────────

# Returns all in-play cards that are valid targets for the given hero's power.
# For deal_damage_and_heal, returns damage targets (phase 1) or heal targets (phase 2).
func _get_hero_power_targets(hero_id: String) -> Array:
	if _is_damage_and_heal_power(hero_id):
		if _targeting_first_target == "":
			# Phase 1: show all valid damage targets (those that have at least one valid heal partner).
			var result: Array = []
			for pid in state.players:
				var ps := state.players.get(pid) as PlayerState
				if ps and ps.hero_instance_id != "":
					if _any_valid_heal_target(hero_id, ps.hero_instance_id) != "":
						result.append(ps.hero_instance_id)
				for card in state.cards_in_zone(pid + "_ally_row"):
					if _any_valid_heal_target(hero_id, card.instance_id) != "":
						result.append(card.instance_id)
			return result
		else:
			# Phase 2: show valid heal targets for the already-chosen damage target.
			var result: Array = []
			for pid in state.players:
				var ps := state.players.get(pid) as PlayerState
				if ps and ps.hero_instance_id != "":
					var id := ps.hero_instance_id
					if id != _targeting_first_target:
						var act := PendingAction.make("activate_power", local_player, {
							"hero_id": hero_id, "target_id": _targeting_first_target,
							"heal_target_id": id,
						})
						if StackResolver.can_submit(state, act, db):
							result.append(id)
				for card in state.cards_in_zone(pid + "_ally_row"):
					if card.instance_id != _targeting_first_target:
						var act := PendingAction.make("activate_power", local_player, {
							"hero_id": hero_id, "target_id": _targeting_first_target,
							"heal_target_id": card.instance_id,
						})
						if StackResolver.can_submit(state, act, db):
							result.append(card.instance_id)
			return result

	var result: Array = []
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("activate_power", local_player,
				{"hero_id": hero_id, "target_id": ps.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(ps.hero_instance_id)
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("activate_power", local_player,
				{"hero_id": hero_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
	return result


func _is_damage_and_heal_power(hero_id: String) -> bool:
	if not db:
		return false
	var hero := state.get_card(hero_id)
	if not hero:
		return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def:
		return false
	return StackResolver._power_effect_is(def, "deal_damage_and_heal")


# Returns the id of any valid heal target paired with dmg_target, or "" if none.
func _any_valid_heal_target(hero_id: String, dmg_target: String) -> String:
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "" and ps.hero_instance_id != dmg_target:
			var act := PendingAction.make("activate_power", local_player, {
				"hero_id": hero_id, "target_id": dmg_target,
				"heal_target_id": ps.hero_instance_id,
			})
			if StackResolver.can_submit(state, act, db):
				return ps.hero_instance_id
		for card in state.cards_in_zone(pid + "_ally_row"):
			if card.instance_id != dmg_target:
				var act := PendingAction.make("activate_power", local_player, {
					"hero_id": hero_id, "target_id": dmg_target,
					"heal_target_id": card.instance_id,
				})
				if StackResolver.can_submit(state, act, db):
					return card.instance_id
	return ""


# Returns all in-play cards that are valid targets for an enters-play effect.
func _get_enter_play_targets(source_card_id: String) -> Array:
	var result: Array = []
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("choose_enter_play_target", local_player,
				{"source_card_id": source_card_id, "target_id": ps.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(ps.hero_instance_id)
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("choose_enter_play_target", local_player,
				{"source_card_id": source_card_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
	return result


func _get_ability_targets(card_id: String) -> Array:
	var result: Array = []
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("play_ability", local_player,
				{"card_id": card_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("play_ability", local_player,
				{"card_id": card_id, "target_id": ps.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(ps.hero_instance_id)
	return result


func _get_instant_targets(card_id: String) -> Array:
	var result: Array = []
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("play_instant", local_player,
				{"card_id": card_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("play_instant", local_player,
				{"card_id": card_id, "target_id": ps.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(ps.hero_instance_id)
	return result


func _instant_needs_target(card_id: String) -> bool:
	if not db:
		return false
	var card := state.get_card(card_id)
	if not card:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return false
	return StackResolver._instant_needs_target(def)


func _hero_power_needs_target(hero_id: String) -> bool:
	if not db: return false
	var hero := state.get_card(hero_id)
	if not hero: return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return false
	for entry in def.effects.split("|"):
		var key := entry.strip_edges().split(":")[0].strip_edges()
		if key in ["deal_damage_to_target", "destroy_exhausted_ally", "deal_damage_and_heal", "deal_x_damage_to_ally", "deal_7_minus_hand_to_hero"]:
			return true
	return false


func _hero_power_dmg_type(hero_id: String) -> String:
	if not db: return ""
	var hero := state.get_card(hero_id)
	if not hero: return ""
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return ""
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		match parts[0]:
			"destroy_exhausted_ally":
				return "destroy"
			"deal_damage_to_target", "deal_damage_and_heal":
				if parts.size() > 2:
					return parts[2].to_lower()
			"deal_7_minus_hand_to_hero":
				if parts.size() > 1:
					return parts[1].to_lower()
	return ""


func _card_dmg_type(card_id: String) -> String:
	if not db: return ""
	var card := state.get_card(card_id)
	if not card: return ""
	var def := db.get_def(card.card_def_id) as CardDef
	if not def: return ""
	for entry in def.effects.split("|"):
		var key := entry.strip_edges().split(":")[0].strip_edges()
		match key:
			"destroy_target", "destroy_exhausted_ally": return "destroy"
			"deal_damage_to_target", "deal_damage_and_heal":
				var parts := entry.strip_edges().split(":")
				if parts.size() > 2: return parts[2].to_lower()
			"heal_target": return "heal"
	return ""


func _hero_power_dmg_amount(hero_id: String) -> int:
	if not db: return 0
	var hero := state.get_card(hero_id)
	if not hero: return 0
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["deal_damage_to_target", "deal_damage_and_heal"] and parts.size() > 1:
			return int(parts[1])
	return 0


func _action_type_for(instance_id: String) -> String:
	var card := state.get_card(instance_id)
	if not card:
		return ""
	if not db:
		return "play_ally"   # fallback when no db (tests without db)
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return ""
	if def.card_type in ["Quest", "Location"]:
		return "place_resource"
	if def.card_type == "Ally":
		return "play_ally"
	if def.is_instant:
		return "play_instant"
	if def.card_type == "Ability":
		return "play_ability"
	return ""   # Equipment and other unimplemented types


func _ability_needs_target(card_id: String) -> bool:
	return _instant_needs_target(card_id)


func _get_ally_power_targets(ally_id: String) -> Array:
	var result: Array = []
	if not db or not state:
		return result
	var ally := state.get_card(ally_id)
	if not ally:
		return result
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("use_ally_power", local_player,
				{"card_id": ally_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("use_ally_power", local_player,
				{"card_id": ally_id, "target_id": ps.hero_instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(ps.hero_instance_id)
	return result


# Called by the UI (playtest.gd) after the player confirms the X value in the dialog.
# Transitions from X-select state into ally targeting mode.
func confirm_x_value(x_value: int) -> void:
	if _targeting_source == "":
		return
	_targeting_x_value = x_value
	start_targeting(_targeting_source, "activate_power_x", "shadow", x_value)


# Returns ally targets valid for a deal_x_damage_to_ally power with the stored X value.
func _get_x_power_targets(hero_id: String) -> Array:
	var result: Array = []
	if not state or not db:
		return result
	var opp := ""
	for pid in state.players:
		if pid != local_player:
			opp = pid
	for card in state.cards_in_zone(opp + "_ally_row"):
		var act := PendingAction.make("activate_power", local_player,
			{"hero_id": hero_id, "target_id": card.instance_id, "x_value": _targeting_x_value})
		if StackResolver.can_submit(state, act, db):
			result.append(card.instance_id)
	return result


func _handle_x_power_targeting_click(instance_id: String) -> void:
	var legal := _get_x_power_targets(_targeting_source)
	if instance_id not in legal:
		return
	var action := PendingAction.make("activate_power", local_player, {
		"hero_id": _targeting_source,
		"target_id": instance_id,
		"x_value": _targeting_x_value,
	})
	var src := _targeting_source
	_targeting_source  = ""
	_targeting_x_value = 0
	targeting_cancelled.emit()
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		# Restore targeting in case can_submit failed.
		_targeting_source = src
		return
	EventBus.emit_events(events)
	var pass_events := StackResolver.pass_priority(state, db)
	EventBus.emit_events(pass_events)
	refresh_highlights()


func _hero_power_needs_x(hero_id: String) -> bool:
	if not db: return false
	var hero := state.get_card(hero_id)
	if not hero: return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return false
	return StackResolver._power_effect_is(def, "deal_x_damage_to_ally")


func _handle_ally_power_targeting_click(instance_id: String) -> void:
	var legal := _get_ally_power_targets(_targeting_source)
	if instance_id not in legal:
		return
	var action := PendingAction.make("use_ally_power", local_player,
		{"card_id": _targeting_source, "target_id": instance_id})
	_targeting_source = ""
	targeting_cancelled.emit()
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)


func _params_for(instance_id: String, action_type: String) -> Dictionary:
	match action_type:
		"place_resource":
			return {"card_id": instance_id, "face_up": true}
		_:
			return {"card_id": instance_id}
