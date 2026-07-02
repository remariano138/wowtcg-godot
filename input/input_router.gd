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

signal highlights_updated(playable_ids: Array)
signal conditional_highlights_updated(orange_ids: Array)
# dmg_type: "fire", "melee", etc.  "" = unspecified (show crosshair)
# dmg_amount: damage shown on the cursor overlay; 0 = don't show
signal targeting_started(source_id: String, dmg_type: String, dmg_amount: int)
signal targeting_cancelled()
signal discard_mode_started(count: int)
signal discard_mode_ended()

var state: GameState
var db
var local_player: String

# ── Targeting state ────────────────────────────────────────────────────────────
var _targeting_source:      String = ""   # instance_id of attacker / hero; "" = not targeting
var _targeting_action_type: String = ""   # "propose_combat" or "activate_power"
var _targeting_dmg_type:    String = ""   # damage type icon key (or "" for crosshair)
var _in_discard_mode: bool = false        # true while player must choose cards to discard


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
			var legal := StackResolver.get_legal_attackers(state, local_player, db)
			if instance_id in legal:
				start_attack_targeting(instance_id)
			return

	# ── Hand card left-click → play / place ───────────────────────────────────
	var action_type := _action_type_for(instance_id)
	if action_type == "":
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
		discard_mode_ended.emit()
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
	_targeting_source      = ""
	_targeting_action_type = ""
	_targeting_dmg_type    = ""
	refresh_highlights()
	targeting_cancelled.emit()


func _handle_targeting_click(instance_id: String) -> void:
	match _targeting_action_type:
		"propose_combat":            _handle_combat_targeting_click(instance_id)
		"activate_power":            _handle_power_targeting_click(instance_id)
		"choose_enter_play_target":  _handle_enter_play_targeting_click(instance_id)


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
			"choose_enter_play_target":
				return _get_enter_play_targets(_targeting_source)
		return []

	var result: Array = []
	# Hand card plays.
	for card in state.cards_in_zone(local_player + "_hand"):
		var atype := _action_type_for(card.instance_id)
		if atype == "":
			continue
		var action := PendingAction.make(atype, local_player,
				_params_for(card.instance_id, atype))
		if StackResolver.can_submit(state, action, db):
			result.append(card.instance_id)
	# Legal attackers (in action phase with empty chain).
	if state.phase == "action" and state.turn_player == local_player \
			and state.pending_actions.is_empty():
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
	highlights_updated.emit(get_playable_card_ids())
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

	# ── Face-up quests in resource row: Complete option ───────────────────────
	if state.is_in_play(instance_id):
		var zone := state.zones.get(card.zone_id) as Zone
		if zone and zone.zone_type == "resource_row" and not card.face_down:
			if def.card_type == "Quest":
				var a := PendingAction.make("use_quest", local_player,
					{"quest_id": instance_id})
				return [{"label": "Complete Quest — %s" % def.card_name,
					"action": a, "enabled": StackResolver.can_submit(state, a, db)}]

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
				and state.pending_actions.is_empty()
			result.append({"label": "Attack",
				"action": PendingAction.make("begin_attack_targeting",
					local_player, {"attacker_id": instance_id}),
				"enabled": can_attack})

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
		var play_type := "play_instant" if def.is_instant else "play_ally"
		var a := PendingAction.make(play_type, local_player, {"card_id": instance_id})
		result.append({"label": "Play %s" % def.card_name,
			"action": a, "enabled": StackResolver.can_submit(state, a, db)})

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
		"begin_attack_targeting":
			if state.priority_player == local_player:
				start_attack_targeting(action.params.get("attacker_id", ""))
			return
		"begin_power_targeting":
			if state.priority_player == local_player:
				var hero_id: String = action.params.get("hero_id", "")
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
func _get_hero_power_targets(hero_id: String) -> Array:
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


func _hero_power_needs_target(hero_id: String) -> bool:
	if not db: return false
	var hero := state.get_card(hero_id)
	if not hero: return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return false
	for entry in def.effects.split("|"):
		if entry.strip_edges().begins_with("deal_damage_to_target"):
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
		if parts[0] == "deal_damage_to_target" and parts.size() > 2:
			return parts[2].to_lower()
	return ""


func _hero_power_dmg_amount(hero_id: String) -> int:
	if not db: return 0
	var hero := state.get_card(hero_id)
	if not hero: return 0
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "deal_damage_to_target" and parts.size() > 1:
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
		return "place_resource"   # left-click default: place face-up
	return "play_instant" if def.is_instant else "play_ally"


func _params_for(instance_id: String, action_type: String) -> Dictionary:
	match action_type:
		"place_resource":
			return {"card_id": instance_id, "face_up": true}
		_:
			return {"card_id": instance_id}
