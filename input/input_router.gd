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
# Emitted after a human resolves an ongoing Totem start-of-turn target choice
# (Searing Totem) so the scene can resume driving the turn.
signal totem_target_resolved()
signal discard_mode_started(count: int)
signal discard_mode_ended()
signal control_discard_mode_started(source_id: String)
signal control_discard_mode_ended()
signal pet_sacrifice_mode_started(candidate_ids: Array)
signal pet_sacrifice_mode_ended()
signal equipment_sacrifice_mode_started(candidate_ids: Array)
signal equipment_sacrifice_mode_ended()
signal unique_sacrifice_mode_started(candidate_ids: Array)
signal unique_sacrifice_mode_ended()
# Emitted when a power requires the player to select a numeric X value before targeting.
# hero_id: the hero whose power is being used. max_x: maximum selectable value (hero HP - 1).
signal x_select_requested(hero_id: String, max_x: int)
# Emitted when a quest reward needs graveyard cards chosen before submitting.
# The UI shows a browser over candidate_ids; it must call
# confirm_graveyard_selection(ids) or cancel_graveyard_selection().
signal graveyard_select_requested(quest_id: String, candidate_ids: Array,
		min_count: int, max_count: int)
# Emitted when the player wants to browse a graveyard (view-only, no selection).
signal graveyard_examine_requested(graveyard_player: String, card_ids: Array)
# Alt+hover peek over a graveyard pile (view-only, non-modal, closes on its own).
signal graveyard_peek_requested(graveyard_player: String, card_ids: Array)
signal graveyard_peek_closed()

var state: GameState
var db
var local_player: String

# ── Targeting state ────────────────────────────────────────────────────────────
var _targeting_source:      String = ""   # instance_id of attacker / hero; "" = not targeting
var _targeting_action_type: String = ""   # "propose_combat" or "activate_power"
var _targeting_dmg_type:    String = ""   # damage type icon key (or "" for crosshair)
# Weapon chosen via a weapon's "Attack" menu: auto-struck when the attacker's
# strike point opens (rule 602.1), instead of prompting. "" = prompt as usual.
var preferred_strike_weapon: String = ""
var _in_discard_mode: bool = false        # true while player must choose cards to discard
var _in_control_discard_mode: bool = false  # true while player chooses: discard OR give control (Infernal)
var _in_pet_sacrifice_mode: bool = false  # true while player must choose a pet to sacrifice
var _in_equip_sacrifice_mode: bool = false  # true while player must choose equipment to destroy
var _equip_sacrifice_candidates: Array[String] = []
var _pet_sacrifice_candidates: Array[String] = []
var _in_unique_sacrifice_mode: bool = false  # true while player must choose a Unique duplicate to destroy
var _unique_sacrifice_candidates: Array[String] = []
# Two-phase targeting for deal_damage_and_heal: first pick is stored here, second completes the action.
var _targeting_first_target: String = ""  # "" = first pick pending; non-empty = waiting for second
# Chain Lightning: up to 3 targets picked in order (target_id, target_id_2, target_id_3).
# The player can stop after 1 or 2 picks via pass_priority_action() (Space / pass button).
var _chain_lightning_picked: Array[String] = []
# Stored X value for deal_x_damage_to_ally powers; set when player confirms the X dialog.
var _targeting_x_value: int = 0
# Quest awaiting graveyard-target selection; "" = no browser open.
var _gy_select_quest_id: String = ""
var _gy_select_hero_id: String = ""
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

	# ── Graveyard browser open: board clicks are ignored (modal owns input) ──
	if _gy_select_quest_id != "" or _gy_select_hero_id != "":
		return

	# ── Pet sacrifice mode: click sacrifices the chosen pet ──────────────────
	if _in_pet_sacrifice_mode:
		_handle_pet_sacrifice_click(instance_id)
		return

	# ── Equipment sacrifice mode: click destroys the chosen equipment ────────
	if _in_equip_sacrifice_mode:
		_handle_equip_sacrifice_click(instance_id)
		return

	# ── Unique sacrifice mode: click destroys the chosen Unique duplicate ────
	if _in_unique_sacrifice_mode:
		_handle_unique_sacrifice_click(instance_id)
		return

	# ── Discard mode: click discards the chosen hand card ─────────────────────
	if _in_discard_mode:
		_handle_discard_click(instance_id)
		return

	# ── Control-discard mode (Infernal): click a hand card to discard and keep
	# control; declining goes through decline_control_discard() (pass button) ──
	if _in_control_discard_mode:
		_handle_control_discard_click(instance_id)
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
			# Armor block (rule 304.3): left-click a ready armor while damage is
			# incoming exhausts it for its DEF — same as the context-menu entry.
			var block_action := PendingAction.make("use_armor_prevention",
				local_player, {"card_id": instance_id})
			if StackResolver.can_submit(state, block_action, db):
				var block_events := StackResolver.submit_action(state, block_action, db)
				if not block_events.is_empty():
					EventBus.emit_events(block_events)
					_pass_own_proposal(block_action)
					refresh_highlights()
				return
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
		# ── Face-up quest in resource row left-click → complete quest ───────────
		if zone and zone.zone_type == "resource_row" and not card.face_down:
			var qdef: CardDef = db.get_def(card.card_def_id) if db else null
			if qdef and qdef.card_type == "Quest" \
					and StackResolver.can_use_quest_no_target_check(
						state, instance_id, local_player, db):
				var needs_gy := not StackResolver.get_graveyard_search_requirement(qdef).is_empty()
				if needs_gy:
					start_graveyard_selection(instance_id)
					return
				var quest_action := PendingAction.make("use_quest", local_player,
					{"quest_id": instance_id})
				var quest_events := StackResolver.submit_action(state, quest_action, db)
				if not quest_events.is_empty():
					EventBus.emit_events(quest_events)
					_pass_own_proposal(quest_action)
					refresh_highlights()
			return

	# ── Hand card left-click → play / place ───────────────────────────────────
	var action_type := _action_type_for(instance_id)
	if action_type == "":
		return
	# Abilities/instants with targets: enter targeting mode rather than submitting
	# directly — targeting is cancellable (Esc) until the target click submits.
	if action_type == "play_ability" and _ability_needs_target(instance_id):
		start_targeting(instance_id, "play_ability",
			_card_dmg_type(instance_id), _card_dmg_amount(instance_id))
		return
	if action_type == "play_instant" and _instant_needs_target(instance_id):
		start_targeting(instance_id, "play_instant",
			_card_dmg_type(instance_id), _card_dmg_amount(instance_id))
		return
	var action := PendingAction.make(action_type, local_player,
			_params_for(instance_id, action_type))
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_pass_own_proposal(action)
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


# ── Control-discard mode (Infernal: discard a card OR give up control) ────────

func start_control_discard_mode(source_id: String) -> void:
	_in_control_discard_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)  # red — pending choice blocks all other play
	refresh_highlights()
	control_discard_mode_started.emit(source_id)


func _handle_control_discard_click(instance_id: String) -> void:
	var card := state.get_card(instance_id)
	if not card or card.controller != local_player:
		return
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return
	var events := StackResolver.choose_control_discard(state, instance_id, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_end_control_discard_mode_if_done()


# Player declined the discard: opponent gains control of the source card.
func decline_control_discard() -> void:
	if not _in_control_discard_mode:
		return
	var events := StackResolver.decline_control_discard(state, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_end_control_discard_mode_if_done()


func _end_control_discard_mode_if_done() -> void:
	# Stay in the mode if another source's choice is still queued.
	if state.pending_control_discard_player != local_player:
		_in_control_discard_mode = false
		_highlight_color = Color(0.2, 1.0, 0.3)
		control_discard_mode_ended.emit()
	refresh_highlights()


# ── Graveyard selection (quest rewards that target graveyard cards) ───────────

# Open the browser for a quest whose reward needs graveyard targets.
func start_graveyard_selection(quest_id: String) -> void:
	if not state or state.priority_player != local_player:
		return
	var card := state.get_card(quest_id)
	var def := db.get_def(card.card_def_id) as CardDef if card and db else null
	var req := StackResolver.get_graveyard_search_requirement(def)
	if req.is_empty():
		return
	var candidates := StackResolver.get_graveyard_search_candidates(
			state, local_player, req, db)
	# Optional-target rewards (The Missing Diplomat, min 0) with nothing to find:
	# complete the quest immediately with no targets — the reward just fizzles.
	# No browser is opened for an empty candidate list.
	if candidates.is_empty() and int(req.get("min_count", 1)) == 0:
		var complete := PendingAction.make("use_quest", local_player,
				{"quest_id": quest_id})
		var complete_events := StackResolver.submit_action(state, complete, db)
		if not complete_events.is_empty():
			EventBus.emit_events(complete_events)
			_pass_own_proposal(complete)
			refresh_highlights()
		return
	if candidates.size() < int(req.get("min_count", 1)):
		return
	_gy_select_quest_id = quest_id
	graveyard_select_requested.emit(quest_id, candidates,
			int(req.get("min_count", 1)), int(req.get("max_count", 1)))


# Open the browser for a hero power whose effect needs a graveyard target
# (e.g. Sen'zir Beastwalker: "Put a Pet card from your graveyard into your hand").
func start_hero_graveyard_selection(hero_id: String) -> void:
	if not state or state.priority_player != local_player:
		return
	var hero := state.get_card(hero_id)
	var def := db.get_def(hero.card_def_id) as CardDef if hero and db else null
	var req := StackResolver.get_graveyard_search_requirement(def)
	if req.is_empty():
		return
	var candidates := StackResolver.get_graveyard_search_candidates(
			state, local_player, req, db)
	if candidates.size() < int(req.get("min_count", 1)):
		return
	_gy_select_hero_id = hero_id
	graveyard_select_requested.emit(hero_id, candidates,
			int(req.get("min_count", 1)), int(req.get("max_count", 1)))


# UI confirmed a selection: submit the quest completion (or hero power) with
# the announced targets.
func confirm_graveyard_selection(selected_ids: Array) -> void:
	if _gy_select_quest_id != "":
		var quest_id := _gy_select_quest_id
		_gy_select_quest_id = ""
		var action := PendingAction.make("use_quest", local_player,
				{"quest_id": quest_id, "target_ids": selected_ids})
		var events := StackResolver.submit_action(state, action, db)
		if events.is_empty():
			refresh_highlights()
			return
		EventBus.emit_events(events)
		refresh_highlights()
		return
	if _gy_select_hero_id != "":
		var hero_id := _gy_select_hero_id
		_gy_select_hero_id = ""
		var target_id: String = selected_ids[0] if not selected_ids.is_empty() else ""
		var action := PendingAction.make("activate_power", local_player,
				{"hero_id": hero_id, "target_id": target_id})
		var events := StackResolver.submit_action(state, action, db)
		if events.is_empty():
			refresh_highlights()
			return
		EventBus.emit_events(events)
		_pass_own_proposal(action)
		refresh_highlights()
		return


func cancel_graveyard_selection() -> void:
	_gy_select_quest_id = ""
	_gy_select_hero_id = ""
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


# ── Equipment sacrifice mode ────────────────────────────────────────────────────

func start_equipment_sacrifice_mode(candidate_ids: Array) -> void:
	_in_equip_sacrifice_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)  # red — mandatory equipment sacrifice
	_equip_sacrifice_candidates.clear()
	for cid in candidate_ids:
		_equip_sacrifice_candidates.append(cid as String)
	refresh_highlights()
	equipment_sacrifice_mode_started.emit(candidate_ids)


func _handle_equip_sacrifice_click(instance_id: String) -> void:
	if instance_id not in _equip_sacrifice_candidates:
		return
	var events := StackResolver.choose_equipment_sacrifice(state, instance_id, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	if state.pending_equip_sacrifice_player == "":
		_in_equip_sacrifice_mode = false
		_highlight_color = Color(0.2, 1.0, 0.3)
		_equip_sacrifice_candidates.clear()
		equipment_sacrifice_mode_ended.emit()
	else:
		_equip_sacrifice_candidates.clear()
		for cid: String in state.pending_equip_sacrifice_ids:
			_equip_sacrifice_candidates.append(cid)
	refresh_highlights()


func start_unique_sacrifice_mode(candidate_ids: Array) -> void:
	_in_unique_sacrifice_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)  # red — mandatory Unique-duplicate sacrifice
	_unique_sacrifice_candidates.clear()
	for cid in candidate_ids:
		_unique_sacrifice_candidates.append(cid as String)
	refresh_highlights()
	unique_sacrifice_mode_started.emit(candidate_ids)


func _handle_unique_sacrifice_click(instance_id: String) -> void:
	if instance_id not in _unique_sacrifice_candidates:
		return
	var events := StackResolver.choose_unique_sacrifice(state, instance_id, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	if state.pending_unique_sacrifice_player == "":
		_in_unique_sacrifice_mode = false
		_highlight_color = Color(0.2, 1.0, 0.3)
		_unique_sacrifice_candidates.clear()
		unique_sacrifice_mode_ended.emit()
	else:
		_unique_sacrifice_candidates.clear()
		for cid: String in state.pending_unique_sacrifice_ids:
			_unique_sacrifice_candidates.append(cid)
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
	preferred_strike_weapon = ""   # default: prompt at the strike point (weapon menu overrides after)
	var dmg_type   := ""   # default → crosshair; set only when card has an explicit dmg_type
	var dmg_amount := 0
	if db:
		var card := state.get_card(attacker_id)
		if card:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and def.dmg_type != "":
				dmg_type = def.dmg_type.to_lower()
	if state:
		# Preview the ATK this attacker will actually deal once combat is
		# proposed (rule 601 — it isn't "attacking" yet during target
		# selection, so plain get_atk would omit "while attacking" bonuses
		# like Zorm / Rayder / For the Horde! here).
		dmg_amount = state.get_atk_if_attacking(attacker_id, db)
	start_targeting(attacker_id, "propose_combat", dmg_type, dmg_amount)


# Convenience wrapper for enters-play targeted effects (e.g. Taz'dingo).
func start_enter_play_targeting(card_id: String, dmg_type: String, dmg_amount: int) -> void:
	start_targeting(card_id, "choose_enter_play_target", dmg_type, dmg_amount)


# Convenience wrapper for an ongoing Totem start-of-turn target choice (Searing Totem).
func start_totem_targeting(card_id: String, dmg_type: String, dmg_amount: int) -> void:
	start_targeting(card_id, "choose_totem_target", dmg_type, dmg_amount)


# Abort targeting — called by Escape key or scene logic.
func cancel_targeting() -> void:
	_targeting_source       = ""
	_targeting_action_type  = ""
	_targeting_dmg_type     = ""
	preferred_strike_weapon = ""
	_targeting_first_target = ""
	_targeting_x_value      = 0
	_chain_lightning_picked = []
	refresh_highlights()
	targeting_cancelled.emit()


func _handle_targeting_click(instance_id: String) -> void:
	match _targeting_action_type:
		"propose_combat":            _handle_combat_targeting_click(instance_id)
		"activate_power":            _handle_power_targeting_click(instance_id)
		"activate_power_x":          _handle_x_power_targeting_click(instance_id)
		"choose_enter_play_target":  _handle_enter_play_targeting_click(instance_id)
		"choose_totem_target":       _handle_totem_targeting_click(instance_id)
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
		_pass_own_proposal(action)
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
		_pass_own_proposal(action)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


func _handle_totem_targeting_click(instance_id: String) -> void:
	# Ongoing Totem start-of-turn damage (Searing Totem). Mandatory, direct-call
	# resolution (no chain) — like the strike / reveal choices.
	if instance_id in StackResolver.get_totem_targets(state, db):
		var events := StackResolver.choose_totem_target(state, instance_id, db)
		cancel_targeting()
		EventBus.emit_events(events)
		# The scene resumes driving the turn (and handles any next queued totem).
		totem_target_resolved.emit()


func _handle_ability_targeting_click(instance_id: String) -> void:
	# Chain Lightning: up to 3 targets, one click per wave — see
	# _handle_chain_lightning_click / _submit_chain_lightning below.
	if _is_chain_lightning(_targeting_source):
		_handle_chain_lightning_click(instance_id)
		return
	var action := PendingAction.make("play_ability", local_player, {
		"card_id": _targeting_source, "target_id": instance_id,
	})
	if StackResolver.can_submit(state, action, db):
		_targeting_source = ""
		targeting_cancelled.emit()
		var events := StackResolver.submit_action(state, action, db)
		if not events.is_empty():
			EventBus.emit_events(events)
			_pass_own_proposal(action)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


# ── Chain Lightning (azeroth_106) — up to 3 announced targets ─────────────────
#
# 1st target: mandatory. 2nd/3rd: optional "may" targets — the player stops
# early by pressing Space / the pass button (pass_priority_action() checks
# _chain_lightning_picked and submits instead of passing, mirroring the
# "Sacrifice a pet [Space]" pass-button-repurposing pattern). Clicking the
# source card again before any target is picked cancels, same as other
# targeting modes.

func _is_chain_lightning(card_id: String) -> bool:
	if not db or card_id == "":
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return def != null and StackResolver._has_effect_flag_prefix(def, "chain_lightning")


func _chain_lightning_params(extra_target_id: String = "") -> Dictionary:
	var params := {"card_id": _targeting_source}
	var keys := ["target_id", "target_id_2", "target_id_3"]
	for i in _chain_lightning_picked.size():
		params[keys[i]] = _chain_lightning_picked[i]
	if extra_target_id != "" and _chain_lightning_picked.size() < 3:
		params[keys[_chain_lightning_picked.size()]] = extra_target_id
	return params


func _handle_chain_lightning_click(instance_id: String) -> void:
	if instance_id == _targeting_source:
		if _chain_lightning_picked.is_empty():
			cancel_targeting()
		else:
			# Clicking the source again after the mandatory 1st target skips
			# any remaining optional targets, same as pressing Space.
			_submit_chain_lightning()
		return
	if _chain_lightning_picked.size() >= 3 or instance_id in _chain_lightning_picked:
		return
	var probe := PendingAction.make("play_ability", local_player,
		_chain_lightning_params(instance_id))
	if not StackResolver.can_submit(state, probe, db):
		return
	_chain_lightning_picked.append(instance_id)
	if _chain_lightning_picked.size() >= 3:
		_submit_chain_lightning()
	else:
		# Re-emit to refresh the cursor/status text and re-highlight remaining targets.
		# Chain Lightning's amount steps down per target (3/2/1) — show the next one.
		var next_amount := _chain_lightning_amount_for(_targeting_source, _chain_lightning_picked.size())
		targeting_started.emit(_targeting_source, _targeting_dmg_type, next_amount)
		refresh_highlights()


func _submit_chain_lightning() -> void:
	var action := PendingAction.make("play_ability", local_player,
		_chain_lightning_params())
	_targeting_source       = ""
	_chain_lightning_picked = []
	targeting_cancelled.emit()
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_pass_own_proposal(action)
	refresh_highlights()


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
		_pass_own_proposal(action)
		refresh_highlights()
	elif instance_id == _targeting_source:
		cancel_targeting()


func _handle_power_targeting_click(instance_id: String) -> void:
	# Two-phase for radak_pet_sacrifice: first click = Pet to sacrifice, second = damage target.
	if _is_radak_power(_targeting_source):
		if _targeting_first_target == "":
			# Phase 1: validate as an owned Pet via can_submit probe.
			var probe := PendingAction.make("activate_power", local_player, {
				"hero_id": _targeting_source, "pet_id": instance_id, "target_id": "",
			})
			if StackResolver.can_submit(state, probe, db):
				_targeting_first_target = instance_id
				targeting_started.emit(_targeting_source, "shadow", 0)   # re-emit: now in phase 2, shadow damage
				refresh_highlights()
			elif instance_id == _targeting_source:
				cancel_targeting()
		else:
			# Phase 2: instance_id is the damage target.
			var pet_card := state.get_card(_targeting_first_target)
			var pet_def: CardDef = db.get_def(pet_card.card_def_id) if pet_card and db else null
			var x_val: int = pet_def.cost if pet_def else 0
			var action := PendingAction.make("activate_power", local_player, {
				"hero_id":  _targeting_source,
				"pet_id":   _targeting_first_target,
				"target_id": instance_id,
				"x_value":  x_val,
			})
			if StackResolver.can_submit(state, action, db):
				_targeting_source       = ""
				_targeting_first_target = ""
				targeting_cancelled.emit()
				var events := StackResolver.submit_action(state, action, db)
				if events.is_empty():
					return
				EventBus.emit_events(events)
				_pass_own_proposal(action)
				refresh_highlights()
			elif instance_id == _targeting_first_target:
				# Clicked the Pet again — go back to phase 1.
				_targeting_first_target = ""
				targeting_started.emit(_targeting_source, _targeting_dmg_type, 0)
				refresh_highlights()
		return

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
				_pass_own_proposal(action)
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
		_pass_own_proposal(action)
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


# Convenience auto-pass on the player's own proposal (rule 410.1: proposer keeps
# priority, but responding to your own action is rare, so the UI passes for them).
# Guarded: the playtest's synchronous drain may have already passed/resolved the
# proposal during EventBus.emit_events (turbo mode) — in that case the chain top
# is no longer our action and passing again would burn a fresh priority window.
func _pass_own_proposal(action: PendingAction) -> void:
	if not state or state.priority_player != local_player:
		return
	if state.pending_actions.is_empty() or state.pending_actions.back() != action:
		return
	var pass_events := StackResolver.pass_priority(state, db)
	EventBus.emit_events(pass_events)


func is_awaiting_chain_lightning_optional_target() -> bool:
	return _targeting_source != "" and not _chain_lightning_picked.is_empty()


func pass_priority_action() -> void:
	if not state or state.priority_player != local_player:
		return
	# Chain Lightning: Space / the pass button stops taking optional "may"
	# targets early and submits with whatever has been picked so far (1 or 2
	# targets), instead of passing priority. Only meaningful once at least the
	# mandatory 1st target has been chosen.
	if _targeting_source != "" and not _chain_lightning_picked.is_empty():
		_submit_chain_lightning()
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
		var sacrifice_ids: Array = []
		for cid: String in _pet_sacrifice_candidates:
			sacrifice_ids.append(cid)
		return sacrifice_ids

	# Equipment sacrifice mode: highlight the candidate equipment.
	if _in_equip_sacrifice_mode and state.pending_equip_sacrifice_player == local_player:
		var equip_ids: Array = []
		for cid: String in _equip_sacrifice_candidates:
			equip_ids.append(cid)
		return equip_ids

	# Unique sacrifice mode: highlight the same-named Unique duplicates.
	if _in_unique_sacrifice_mode and state.pending_unique_sacrifice_player == local_player:
		var unique_ids: Array = []
		for cid: String in _unique_sacrifice_candidates:
			unique_ids.append(cid)
		return unique_ids

	# Control-discard mode (Infernal): all local hand cards are valid discard
	# choices (declining goes through the pass button, not a card click).
	if _in_control_discard_mode and state.pending_control_discard_player == local_player:
		var cd_ids: Array = []
		for card in state.cards_in_zone(local_player + "_hand"):
			cd_ids.append(card.instance_id)
		return cd_ids

	# Discard mode: all local hand cards are valid discard choices.
	if _in_discard_mode and state.pending_discard_player == local_player:
		var discard_ids: Array = []
		for card in state.cards_in_zone(local_player + "_hand"):
			discard_ids.append(card.instance_id)
		return discard_ids

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
			"choose_totem_target":
				return StackResolver.get_totem_targets(state, db)
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
		# Targeted instants (Quick Strike): same looser probe, instant timing.
		if atype == "play_instant" and _instant_needs_target(card.instance_id):
			if StackResolver.can_play_instant_no_target_check(
					state, card.instance_id, local_player, db):
				result.append(card.instance_id)
			continue
		var hand_action := PendingAction.make(atype, local_player,
				_params_for(card.instance_id, atype))
		if StackResolver.can_submit(state, hand_action, db):
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
		# No-target probe: graveyard-target quests light up before targets are chosen.
		if StackResolver.can_use_quest_no_target_check(state, card.instance_id, local_player, db):
			result.append(card.instance_id)
	# In-play cards with a usable activated power (allies in ally row, equipment in
	# hero row) and hero powers. Light up green like attackers/quests, mirroring the
	# enabled logic in get_context_actions. Legal on either player's turn (rule 701.2).
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(local_player + zone_suffix):
			if card.controller != local_player:
				continue
			var def: CardDef = db.get_def(card.card_def_id) if db else null
			if not def:
				continue
			# Hero power (hero in the hero row).
			var ps := state.players.get(local_player) as PlayerState
			if zone_suffix == "_hero_row" and ps and ps.hero_instance_id == card.instance_id:
				var power_check := PendingAction.make("activate_power", local_player,
					{"hero_id": card.instance_id, "target_id": ""})
				if StackResolver.can_submit(state, power_check, db):
					result.append(card.instance_id)
				continue
			# Armor block (rule 304.3): green when exhaust-to-prevent is legal.
			var block_action := PendingAction.make("use_armor_prevention",
				local_player, {"card_id": card.instance_id})
			if StackResolver.can_submit(state, block_action, db):
				result.append(card.instance_id)
				continue
			# Activated power (ally / equipment).
			var ap_data := StackResolver._ally_activated_power(def)
			if ap_data == {}:
				continue
			var ap_needs_target: bool = (ap_data.get("targets", "") as String) in ["hero_or_ally", "ally", "hero_or_ally_two"]
			if ap_needs_target:
				# Affordability only — target chosen after targeting mode starts.
				var ap_extra_cost: String = ap_data.get("extra_cost", "")
				var ap_once_per_turn: bool = ap_extra_cost == "once_per_turn"
				var ap_no_activate_symbol: bool = ap_extra_cost.begins_with("put_damage_self") \
					or ap_extra_cost == "no_activate"
				var ap_ready_ok: bool
				if ap_once_per_turn:
					ap_ready_ok = not card.used_this_turn
				elif ap_no_activate_symbol:
					ap_ready_ok = true
				else:
					ap_ready_ok = not card.is_exhausted and not card.just_summoned
				if ap_ready_ok \
						and state.get_available_resources(local_player) >= int(ap_data.get("resource_cost", 0)) \
						and state.phase == "action" and state.priority_player == local_player \
						and (state.pending_actions.is_empty() \
							or not StackResolver._power_effect_is(def, "on_your_turn")):
					result.append(card.instance_id)
			else:
				var ap_action := PendingAction.make("use_ally_power", local_player,
					{"card_id": card.instance_id})
				if StackResolver.can_submit(state, ap_action, db):
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
	# Check activated powers — allies (ally row) and equipment (hero row).
	# Legal on either player's turn (rule 701.2).
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(local_player + zone_suffix):
			# `_skip_target_check`: a targeted power (e.g. Elder Moorf) is a legal
			# play even before a target is picked — validate everything but the
			# target, mirroring get_playable_card_ids' inline check and the
			# instant/quest no-target-check probes.
			var ap_action := PendingAction.make("use_ally_power", local_player,
				{"card_id": card.instance_id, "_skip_target_check": true})
			if StackResolver.can_submit(state, ap_action, db):
				return true
	return false


# Returns Array of {label: String, action: PendingAction, enabled: bool}
# Works for both hand cards and in-play characters.
func get_context_actions(instance_id: String) -> Array:
	if not state or not db:
		return []
	var card := state.get_card(instance_id)
	if not card:
		return []

	# ── Graveyard cards: examine (view-only) — works on EITHER player's pile ──
	var card_zone := state.zones.get(card.zone_id) as Zone
	if card_zone and card_zone.zone_type == "graveyard":
		var gy_owner := "p1" if card.zone_id.begins_with("p1") else "p2"
		return [{"label": "Examine Graveyard",
			"action": PendingAction.make("examine_graveyard", local_player,
				{"graveyard_player": gy_owner}),
			"enabled": true}]

	if card.controller != local_player:
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
				var needs_gy := not StackResolver.get_graveyard_search_requirement(def).is_empty()
				var a := PendingAction.make("use_quest", local_player,
					{"quest_id": instance_id, "_needs_gy_targets": needs_gy})
				return [{"label": "Complete Quest — %s" % def.card_name,
					"action": a, "enabled": StackResolver.can_use_quest_no_target_check(
						state, instance_id, local_player, db)}]
			return []  # face-up non-quest resources also have no actions

	# ── In-play characters: Attack + (heroes) Hero Power ─────────────────────
	if state.is_in_play(instance_id):
		var zone := state.zones.get(card.zone_id) as Zone
		if zone and zone.zone_type in ["ally_row", "hero_row"]:
			var char_actions: Array = []

			# For a weapon, "Attack" means strike with the hero wielding it —
			# right-clicking the weapon is a shortcut for attacking with the hero
			# (rule 303); the strike point then offers this weapon. Any other
			# character attacks as itself.
			var attacker_id := instance_id
			var preferred_weapon := ""
			if zone.zone_type == "hero_row" and card.controller == local_player \
					and not StackResolver._weapon_info(def).is_empty():
				var ps_w := state.players.get(local_player) as PlayerState
				if ps_w and ps_w.hero_instance_id != "":
					attacker_id = ps_w.hero_instance_id
					preferred_weapon = instance_id   # auto-strike with this weapon

			var legal_attackers := StackResolver.get_legal_attackers(state, local_player, db)
			var can_attack := state.priority_player == local_player \
				and attacker_id in legal_attackers \
				and state.phase == "action" \
				and state.turn_player == local_player \
				and state.pending_actions.is_empty() \
				and not state.combat_attack_window and not state.combat_defend_window \
				and not state.in_protect_point
			char_actions.append({"label": "Attack",
				"action": PendingAction.make("begin_attack_targeting",
					local_player, {"attacker_id": attacker_id,
						"preferred_weapon_id": preferred_weapon}),
				"enabled": can_attack})

			# Activated power (allies in the ally row; equipment in the hero row).
			if zone.zone_type in ["ally_row", "hero_row"] and card.controller == local_player:
				var ap_data := StackResolver._ally_activated_power(def)
				if ap_data != {}:
					var ap_needs_target: bool = (ap_data.get("targets", "") as String) in ["hero_or_ally", "ally", "friendly_ally", "hero_or_ally_two"]
					var ap_enabled: bool
					if ap_needs_target:
						# Check affordability only (target chosen after targeting mode starts).
						# No turn_player restriction — ally powers work on either player's turn
						# as long as you hold priority (e.g. defending with Grimdron's power).
						var ap_extra_cost: String = ap_data.get("extra_cost", "")
						var ap_once_per_turn: bool = ap_extra_cost == "once_per_turn"
						var ap_no_activate_symbol: bool = ap_extra_cost.begins_with("put_damage_self") \
							or ap_extra_cost == "no_activate"
						var ap_ready_ok: bool
						if ap_once_per_turn:
							ap_ready_ok = not card.used_this_turn
						elif ap_no_activate_symbol:
							ap_ready_ok = true
						else:
							ap_ready_ok = not card.is_exhausted and not card.just_summoned
						ap_enabled = ap_ready_ok \
							and state.get_available_resources(local_player) >= int(ap_data.get("resource_cost", 0)) \
							and StackResolver._can_pay_extra_power_cost(state, local_player, ap_extra_cost, db) \
							and state.phase == "action" and state.priority_player == local_player \
							and (state.pending_actions.is_empty() \
								or not StackResolver._power_effect_is(def, "on_your_turn"))
					else:
						var ap_action := PendingAction.make("use_ally_power", local_player,
							{"card_id": instance_id})
						ap_enabled = StackResolver.can_submit(state, ap_action, db)
					char_actions.append({"label": "Activate Power",
						"action": PendingAction.make("use_ally_power", local_player,
							{"card_id": instance_id, "_needs_target": ap_needs_target}),
						"enabled": ap_enabled})

			# Armor block (rule 304.3): equipment with DEF > 0 in the hero row.
			if zone.zone_type == "hero_row" and def.card_type == "Equipment":
				var eq_def := int(StackResolver._equipment_info(def).get("def", 0))
				if eq_def > 0:
					var block_a := PendingAction.make("use_armor_prevention",
						local_player, {"card_id": instance_id})
					char_actions.append({
						"label": "Exhaust to prevent %d damage" % eq_def,
						"action": block_a,
						"enabled": StackResolver.can_submit(state, block_a, db)})

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
					char_actions.append({"label": "Use Hero Power",
						"action": PendingAction.make(power_atype, local_player,
							{"hero_id": instance_id}),
						"enabled": can_power})

			return char_actions

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
			elif play_type == "play_instant" and _instant_needs_target(instance_id):
				enabled = StackResolver.can_play_instant_no_target_check(
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
				start_targeting(cid, "play_ability",
					_card_dmg_type(cid), _card_dmg_amount(cid))
				return
		"play_instant":
			if _instant_needs_target(action.params.get("card_id", "")):
				var cid: String = action.params.get("card_id", "")
				start_targeting(cid, "play_instant",
					_card_dmg_type(cid), _card_dmg_amount(cid))
				return
		"examine_graveyard":
			var gy_player: String = action.params.get("graveyard_player", "")
			var ids: Array = []
			for c in state.cards_in_zone(gy_player + "_graveyard"):
				ids.append(c.instance_id)
			graveyard_examine_requested.emit(gy_player, ids)
			return
		"use_quest":
			if action.params.get("_needs_gy_targets", false):
				start_graveyard_selection(action.params.get("quest_id", ""))
				return
		"use_ally_power":
			if action.params.get("_needs_target", false):
				var cid: String = action.params.get("card_id", "")
				var ally_card := state.get_card(cid) if state else null
				var ally_def := db.get_def(ally_card.card_def_id) as CardDef if ally_card and db else null
				var ally_ap := StackResolver._ally_activated_power(ally_def) if ally_def else {}
				var ap_dmg_type: String
				if ally_ap and (ally_ap.get("effect", "") as String) in ["heal_target", "heal_x_from_target"]:
					ap_dmg_type = "heal"
				else:
					ap_dmg_type = (ally_ap.get("dmg_type", "") as String).to_lower() if ally_ap else ""
					if ap_dmg_type == "":
						ap_dmg_type = "heal"
				start_targeting(cid, "use_ally_power", ap_dmg_type, int(ally_ap.get("amount", 0)))
				return
		"begin_attack_targeting":
			if state.priority_player == local_player:
				start_attack_targeting(action.params.get("attacker_id", ""))
				# Remember the weapon (if any) to auto-strike at the strike point.
				# Set AFTER start_attack_targeting, which resets it to "".
				preferred_strike_weapon = action.params.get("preferred_weapon_id", "")
			return
		"begin_power_targeting":
			if state.priority_player == local_player:
				var hero_id: String = action.params.get("hero_id", "")
				if _hero_power_needs_gy_target(hero_id):
					start_hero_graveyard_selection(hero_id)
				elif _hero_power_needs_x(hero_id):
					# X-select flow: emit signal so the UI shows the number input dialog.
					var hero := state.get_card(hero_id)
					var max_x := state.get_available_resources(local_player) \
						if _is_heal_x_power(hero_id) \
						else (state.get_current_hp(hero_id, db) - 1) if hero else 1
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
			var direct_power_events := StackResolver.submit_action(state, act, db)
			if direct_power_events.is_empty():
				return
			EventBus.emit_events(direct_power_events)
			_pass_own_proposal(act)
			refresh_highlights()
			return
	if state.priority_player != local_player:
		return
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	refresh_highlights()


# Alt+hover peek over a graveyard pile — same data as examine_graveyard, but
# driven by BoardRenderer's hover tracking rather than a click, and closed via
# close_graveyard_peek() the instant Alt is released or the hover ends.
func request_graveyard_peek(gy_player: String) -> void:
	if not state:
		return
	var ids: Array = []
	for c in state.cards_in_zone(gy_player + "_graveyard"):
		ids.append(c.instance_id)
	graveyard_peek_requested.emit(gy_player, ids)


func close_graveyard_peek() -> void:
	graveyard_peek_closed.emit()


# ── Helpers ────────────────────────────────────────────────────────────────────

# Returns all in-play cards that are valid targets for the given hero's power.
# For deal_damage_and_heal, returns damage targets (phase 1) or heal targets (phase 2).
func _get_hero_power_targets(hero_id: String) -> Array:
	if _is_radak_power(hero_id):
		if _targeting_first_target == "":
			# Phase 1: show owned Pets in ally_row.
			var pet_targets: Array = []
			for card in state.cards_in_zone(local_player + "_ally_row"):
				var probe := PendingAction.make("activate_power", local_player, {
					"hero_id": hero_id, "pet_id": card.instance_id, "target_id": "",
				})
				if StackResolver.can_submit(state, probe, db):
					pet_targets.append(card.instance_id)
			return pet_targets
		else:
			# Phase 2: show all in-play heroes and allies as damage targets.
			var dmg_targets: Array = []
			var pet_card := state.get_card(_targeting_first_target)
			var pet_def: CardDef = db.get_def(pet_card.card_def_id) if pet_card and db else null
			var x_val: int = pet_def.cost if pet_def else 0
			for pid in state.players:
				var ps2 := state.players.get(pid) as PlayerState
				if ps2 and ps2.hero_instance_id != "":
					var act := PendingAction.make("activate_power", local_player, {
						"hero_id": hero_id, "pet_id": _targeting_first_target,
						"target_id": ps2.hero_instance_id, "x_value": x_val,
					})
					if StackResolver.can_submit(state, act, db):
						dmg_targets.append(ps2.hero_instance_id)
				for card in state.cards_in_zone(pid + "_ally_row"):
					if card.instance_id == _targeting_first_target:
						continue
					var act := PendingAction.make("activate_power", local_player, {
						"hero_id": hero_id, "pet_id": _targeting_first_target,
						"target_id": card.instance_id, "x_value": x_val,
					})
					if StackResolver.can_submit(state, act, db):
						dmg_targets.append(card.instance_id)
			return dmg_targets

	if _is_damage_and_heal_power(hero_id):
		if _targeting_first_target == "":
			# Phase 1: show all valid damage targets (those that have at least one valid heal partner).
			var valid_dmg_targets: Array = []
			for pid in state.players:
				var ps := state.players.get(pid) as PlayerState
				if ps and ps.hero_instance_id != "":
					if _any_valid_heal_target(hero_id, ps.hero_instance_id) != "":
						valid_dmg_targets.append(ps.hero_instance_id)
				for card in state.cards_in_zone(pid + "_ally_row"):
					if _any_valid_heal_target(hero_id, card.instance_id) != "":
						valid_dmg_targets.append(card.instance_id)
			return valid_dmg_targets
		else:
			# Phase 2: show valid heal targets for the already-chosen damage target.
			var heal_targets: Array = []
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
							heal_targets.append(id)
				for card in state.cards_in_zone(pid + "_ally_row"):
					if card.instance_id != _targeting_first_target:
						var act := PendingAction.make("activate_power", local_player, {
							"hero_id": hero_id, "target_id": _targeting_first_target,
							"heal_target_id": card.instance_id,
						})
						if StackResolver.can_submit(state, act, db):
							heal_targets.append(card.instance_id)
			return heal_targets

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
	if _is_chain_lightning(card_id):
		return _get_chain_lightning_targets(card_id)
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


# Remaining legal candidates for the current Chain Lightning wave, given
# targets already picked this cast (_chain_lightning_picked). can_submit
# (via StackResolver._can_play_chain_lightning) naturally excludes Untargetable
# candidates on the 1st wave only, and excludes already-picked candidates.
func _get_chain_lightning_targets(card_id: String) -> Array:
	var result: Array = []
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var probe := PendingAction.make("play_ability", local_player,
				_chain_lightning_params(card.instance_id))
			if StackResolver.can_submit(state, probe, db):
				result.append(card.instance_id)
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var probe := PendingAction.make("play_ability", local_player,
				_chain_lightning_params(ps.hero_instance_id))
			if StackResolver.can_submit(state, probe, db):
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
		if key in ["deal_damage_to_target", "destroy_exhausted_ally", "deal_damage_and_heal", "deal_x_damage_to_ally", "deal_7_minus_hand_to_hero", "heal_x_from_target", "radak_pet_sacrifice", "graveyard_to_hand", "target_cant_attack"]:
			return true
	return false


func _hero_power_needs_gy_target(hero_id: String) -> bool:
	if not db: return false
	var hero := state.get_card(hero_id)
	if not hero: return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return false
	return StackResolver._power_effect_is(def, "graveyard_to_hand")


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
			"heal_x_from_target":
				return "heal"
			"radak_pet_sacrifice":
				return "destroy"  # phase 1 = sacrifice (skull); phase 2 re-emits shadow
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
			"chain_lightning":
				var parts := entry.strip_edges().split(":")
				if parts.size() > 4: return parts[4].to_lower()
			"heal_target": return "heal"
	return ""


# Chain Lightning's per-target amount (recipe: chain_lightning:3:2:1:TYPE).
# picked_count is how many targets have already been chosen (0 = first target).
func _chain_lightning_amount_for(card_id: String, picked_count: int) -> int:
	if not db: return 0
	var card := state.get_card(card_id)
	if not card: return 0
	var def := db.get_def(card.card_def_id) as CardDef
	if not def: return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "chain_lightning" and parts.size() > 1 + picked_count:
			return int(parts[1 + picked_count])
	return 0


# Damage amount shown on the targeting cursor for damage effects
# (deal_damage_to_target:N:TYPE). 0 when the card deals no direct damage.
func _card_dmg_amount(card_id: String) -> int:
	if not db: return 0
	var card := state.get_card(card_id)
	if not card: return 0
	var def := db.get_def(card.card_def_id) as CardDef
	if not def: return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		match parts[0].strip_edges():
			"deal_damage_to_target":
				if parts.size() > 1: return int(parts[1])
			"chain_lightning":
				if parts.size() > 1: return int(parts[1])
	return 0


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
	if def.card_type == "Equipment":
		return "play_equipment"
	# Ongoing Ability that enters play (e.g. Searing Totem, an Instant Ability)
	# routes to play_ability even when Instant — see base_ai._action_type_for.
	if def.card_type == "Ability" and StackResolver.is_ongoing_def(def):
		return "play_ability"
	if def.is_instant:
		return "play_instant"
	if def.card_type == "Ability":
		return "play_ability"
	return ""   # other unimplemented types


func _ability_needs_target(card_id: String) -> bool:
	if _is_chain_lightning(card_id):
		return true
	return _instant_needs_target(card_id)


func _get_ally_power_targets(ally_id: String) -> Array:
	var result: Array = []
	if not db or not state:
		return result
	var ally := state.get_card(ally_id)
	if not ally:
		return result
	if _is_ally_damage_and_heal_power(ally_id):
		if _targeting_first_target == "":
			# Phase 1: show all valid damage targets (those with a valid heal partner).
			for pid in state.players:
				for card in state.cards_in_zone(pid + "_ally_row"):
					if _any_valid_ally_heal_target(ally_id, card.instance_id) != "":
						result.append(card.instance_id)
				var ps := state.players.get(pid) as PlayerState
				if ps and ps.hero_instance_id != "" \
						and _any_valid_ally_heal_target(ally_id, ps.hero_instance_id) != "":
					result.append(ps.hero_instance_id)
		else:
			# Phase 2: valid heal targets for the already-chosen damage target.
			for pid in state.players:
				for card in state.cards_in_zone(pid + "_ally_row"):
					if card.instance_id == _targeting_first_target:
						continue
					var act := PendingAction.make("use_ally_power", local_player, {
						"card_id": ally_id, "target_id": _targeting_first_target,
						"heal_target_id": card.instance_id,
					})
					if StackResolver.can_submit(state, act, db):
						result.append(card.instance_id)
				var ps := state.players.get(pid) as PlayerState
				if ps and ps.hero_instance_id != "" and ps.hero_instance_id != _targeting_first_target:
					var act := PendingAction.make("use_ally_power", local_player, {
						"card_id": ally_id, "target_id": _targeting_first_target,
						"heal_target_id": ps.hero_instance_id,
					})
					if StackResolver.can_submit(state, act, db):
						result.append(ps.hero_instance_id)
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


func _is_ally_damage_and_heal_power(ally_id: String) -> bool:
	if not db or not state:
		return false
	var ally := state.get_card(ally_id)
	if not ally:
		return false
	var def := db.get_def(ally.card_def_id) as CardDef
	if not def:
		return false
	var ap := StackResolver._ally_activated_power(def)
	return (ap.get("effect", "") as String) == "deal_damage_and_heal"


# Returns the id of any valid heal target paired with dmg_target, or "" if none.
func _any_valid_ally_heal_target(ally_id: String, dmg_target: String) -> String:
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			if card.instance_id == dmg_target:
				continue
			var act := PendingAction.make("use_ally_power", local_player, {
				"card_id": ally_id, "target_id": dmg_target,
				"heal_target_id": card.instance_id,
			})
			if StackResolver.can_submit(state, act, db):
				return card.instance_id
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "" and ps.hero_instance_id != dmg_target:
			var act := PendingAction.make("use_ally_power", local_player, {
				"card_id": ally_id, "target_id": dmg_target,
				"heal_target_id": ps.hero_instance_id,
			})
			if StackResolver.can_submit(state, act, db):
				return ps.hero_instance_id
	return ""


# Called by the UI (playtest.gd) after the player confirms the X value in the dialog.
# Transitions from X-select state into ally targeting mode.
func confirm_x_value(x_value: int) -> void:
	if _targeting_source == "":
		return
	_targeting_x_value = x_value
	var dmg_type := "heal" if _is_heal_x_power(_targeting_source) else "shadow"
	start_targeting(_targeting_source, "activate_power_x", dmg_type, x_value)


# Returns valid targets for an X-value hero power (damage or heal).
func _get_x_power_targets(hero_id: String) -> Array:
	var result: Array = []
	if not state or not db:
		return result
	if _is_heal_x_power(hero_id):
		# Heal X: all in-play heroes and allies are valid targets.
		for pid in state.players:
			var ps2 := state.players.get(pid) as PlayerState
			if ps2 and ps2.hero_instance_id != "":
				var act := PendingAction.make("activate_power", local_player,
					{"hero_id": hero_id, "target_id": ps2.hero_instance_id, "x_value": _targeting_x_value})
				if StackResolver.can_submit(state, act, db):
					result.append(ps2.hero_instance_id)
			for card in state.cards_in_zone(pid + "_ally_row"):
				var act := PendingAction.make("activate_power", local_player,
					{"hero_id": hero_id, "target_id": card.instance_id, "x_value": _targeting_x_value})
				if StackResolver.can_submit(state, act, db):
					result.append(card.instance_id)
		return result
	# Damage X: enemy allies only.
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
	_pass_own_proposal(action)
	refresh_highlights()


func _hero_power_needs_x(hero_id: String) -> bool:
	if not db: return false
	var hero := state.get_card(hero_id)
	if not hero: return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return false
	return StackResolver._power_effect_is(def, "deal_x_damage_to_ally") \
		or StackResolver._power_effect_is(def, "heal_x_from_target")


func _is_heal_x_power(hero_id: String) -> bool:
	if not db: return false
	var hero := state.get_card(hero_id)
	if not hero: return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return false
	return StackResolver._power_effect_is(def, "heal_x_from_target")


func _is_radak_power(hero_id: String) -> bool:
	if not db: return false
	var hero := state.get_card(hero_id)
	if not hero: return false
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return false
	return StackResolver._power_effect_is(def, "radak_pet_sacrifice")


func _handle_ally_power_targeting_click(instance_id: String) -> void:
	if _is_ally_damage_and_heal_power(_targeting_source):
		var legal := _get_ally_power_targets(_targeting_source)
		if _targeting_first_target == "":
			# Phase 1: instance_id is the damage target.
			if instance_id in legal:
				_targeting_first_target = instance_id
				targeting_started.emit(_targeting_source, "heal", 0)
				refresh_highlights()
			elif instance_id == _targeting_source:
				cancel_targeting()
			return
		else:
			# Phase 2: instance_id is the heal target.
			if instance_id == _targeting_first_target:
				# Clicked the damage target again — go back to phase 1.
				_targeting_first_target = ""
				targeting_started.emit(_targeting_source, _targeting_dmg_type, 0)
				refresh_highlights()
				return
			if instance_id not in legal:
				return
			var action := PendingAction.make("use_ally_power", local_player, {
				"card_id": _targeting_source,
				"target_id": _targeting_first_target,
				"heal_target_id": instance_id,
			})
			_targeting_source       = ""
			_targeting_first_target = ""
			targeting_cancelled.emit()
			var events := StackResolver.submit_action(state, action, db)
			if events.is_empty():
				return
			EventBus.emit_events(events)
			return
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
