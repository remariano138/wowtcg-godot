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

var state: GameState
var db
var local_player: String


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
		retract_last_action()
		get_viewport().set_input_as_handled()


# Called by BoardRenderer when a card visual is clicked.
func handle_card_click(instance_id: String) -> void:
	if not state or state.priority_player != local_player:
		return
	var card := state.get_card(instance_id)
	if not card or card.controller != local_player:
		return

	var action_type := _action_type_for(instance_id)
	if action_type == "":
		return
	var action := PendingAction.make(action_type, local_player,
			_params_for(instance_id, action_type))
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return   # rejected by validator
	EventBus.emit_events(events)
	refresh_highlights()


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
	if not state or state.priority_player != local_player:
		return []
	var result: Array = []
	for card in state.cards_in_zone(local_player + "_hand"):
		var atype := _action_type_for(card.instance_id)
		if atype == "":
			continue
		var action := PendingAction.make(atype, local_player,
				_params_for(card.instance_id, atype))
		if StackResolver.can_submit(state, action, db):
			result.append(card.instance_id)
	return result


func refresh_highlights() -> void:
	highlights_updated.emit(get_playable_card_ids())


# Returns Array of {label: String, action: PendingAction, enabled: bool}
# for all possible actions on a card in the local player's hand.
func get_context_actions(instance_id: String) -> Array:
	if not state or not db:
		return []
	var card := state.get_card(instance_id)
	if not card or card.controller != local_player:
		return []
	var def: CardDef = db.get_def(card.card_def_id)
	if not def:
		return []

	var result: Array = []
	var is_resource_type := def.card_type in ["Quest", "Location"]

	# Play action — not available for Quest/Location (rule 306.1)
	if not is_resource_type:
		var play_type := "play_instant" if def.is_instant else "play_ally"
		var a := PendingAction.make(play_type, local_player, {"card_id": instance_id})
		result.append({"label": "Play %s" % def.card_name,
			"action": a, "enabled": StackResolver.can_submit(state, a, db)})

	# Place face-up — Quest/Location only
	if is_resource_type:
		var a := PendingAction.make("place_resource", local_player,
			{"card_id": instance_id, "face_up": true})
		result.append({"label": "Place face-up as resource",
			"action": a, "enabled": StackResolver.can_submit(state, a, db)})

	# Place face-down — any card
	var a := PendingAction.make("place_resource", local_player,
		{"card_id": instance_id, "face_up": false})
	result.append({"label": "Place face-down as resource",
		"action": a, "enabled": StackResolver.can_submit(state, a, db)})

	return result


func handle_context_action(action: PendingAction) -> void:
	if not state or state.priority_player != local_player:
		return
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	refresh_highlights()


# ── Helpers ────────────────────────────────────────────────────────────────────

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
