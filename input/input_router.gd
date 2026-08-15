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
# Modal spell (rule 707.1c — "Choose one:", Natural Selection): the player must
# pick a mode before targeting. The scene shows one button per label and calls
# choose_modal_mode(index); Esc / cancel_modal_choice aborts (the scene removes
# its buttons on modal_choice_cancelled — also fired when a mode is chosen).
signal modal_choice_opened(card_id: String, mode_labels: Array)
signal modal_choice_cancelled()
# Emitted after a human resolves an ongoing Totem start-of-turn target choice
# (Searing Totem) so the scene can resume driving the turn.
signal trigger_target_resolved()
# Emitted after a human resolves a death-triggered "destroy target ally" choice
# (Boneshanks) so the scene can resume driving the turn.
signal death_target_resolved()
signal discard_mode_started(count: int)
signal discard_mode_ended()
signal control_discard_mode_started(source_id: String)
signal control_discard_mode_ended()
signal resource_place_mode_started(source_id: String)
signal resource_place_mode_ended()
signal pet_sacrifice_mode_started(candidate_ids: Array)
signal pet_sacrifice_mode_ended()
signal equipment_sacrifice_mode_started(candidate_ids: Array)
signal equipment_sacrifice_mode_ended()
signal unique_sacrifice_mode_started(candidate_ids: Array)
signal unique_sacrifice_mode_ended()
signal form_sacrifice_mode_started(candidate_ids: Array)
signal form_sacrifice_mode_ended()
# Quest reward choice sub-picks (Hidden Enemies / A New Plague / Thwarting
# Kolkar Aggression). Emitted after a human resolves one so the scene can
# resume driving the turn (further pendings re-open their own modes first).
signal quest_flow_resolved()
signal plague_destroy_mode_started(candidate_ids: Array)
signal plague_destroy_mode_ended()
signal quest_facedown_mode_started(candidate_ids: Array)
signal quest_facedown_mode_ended()
# Emitted when a power requires the player to select a numeric X value before targeting.
# hero_id: the hero whose power is being used. max_x: maximum selectable value (hero HP - 1).
signal x_select_requested(hero_id: String, max_x: int)
# Emitted when a quest reward needs graveyard cards chosen before submitting.
# The UI shows a browser over candidate_ids; it must call
# confirm_graveyard_selection(ids) or cancel_graveyard_selection().
signal graveyard_select_requested(quest_id: String, candidate_ids: Array,
		min_count: int, max_count: int)
# Emitted when a quest's completion COST needs allies chosen for exhaustion
# (The Love Potion). The UI shows a popup over candidate_ids; nothing is paid or
# submitted until it calls confirm_ally_exhaust_selection(ids) — or
# cancel_ally_exhaust_selection(), which leaves the game state untouched.
signal ally_exhaust_select_requested(quest_id: String, candidate_ids: Array,
		count: int)
# Emitted when the player wants to browse a graveyard (view-only, no selection).
signal graveyard_examine_requested(graveyard_player: String, card_ids: Array)
# Alt+hover peek over a graveyard pile (view-only, non-modal, closes on its own).
signal graveyard_peek_requested(graveyard_player: String, card_ids: Array)
signal graveyard_peek_closed()
# Emitted when a card's muted flag flips (context-menu Mute/Unmute) so the
# renderer can show/hide the 🔇 badge.
signal card_mute_changed(instance_id: String, muted: bool)

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
var _in_resource_place_mode: bool = false  # true while player chooses a hand card to bury as a resource (Nightbloom)
var _in_pet_sacrifice_mode: bool = false  # true while player must choose a pet to sacrifice
var _in_equip_sacrifice_mode: bool = false  # true while player must choose equipment to destroy
var _equip_sacrifice_candidates: Array[String] = []
var _pet_sacrifice_candidates: Array[String] = []
var _in_unique_sacrifice_mode: bool = false  # true while player must choose a Unique duplicate to destroy
var _unique_sacrifice_candidates: Array[String] = []
var _in_form_sacrifice_mode: bool = false  # true while player must choose a Form to destroy (414.3b)
var _form_sacrifice_candidates: Array[String] = []
# A New Plague: player must destroy an ally in their own party (mandatory, red).
var _in_plague_destroy_mode: bool = false
var _plague_destroy_candidates: Array[String] = []
# Thwarting Kolkar Aggression: player must turn one of their face-up quests
# face down (mandatory, red).
var _in_quest_facedown_mode: bool = false
var _quest_facedown_candidates: Array[String] = []
# Two-phase targeting for deal_damage_and_heal: first pick is stored here, second completes the action.
var _targeting_first_target: String = ""  # "" = first pick pending; non-empty = waiting for second
# Chain Lightning: up to 3 targets picked in order (target_id, target_id_2, target_id_3).
# The player can stop after 1 or 2 picks via pass_priority_action() (Space / pass button).
var _chain_lightning_picked: Array[String] = []
# Lightning Storm: one entry per point of the announced X, in click order —
# repeats allowed (the same ally may be clicked several times). See
# _handle_divided_click.
var _divided_picked: Array[String] = []
# Stored X value for deal_x_damage_to_ally powers; set when player confirms the X dialog.
var _targeting_x_value: int = 0
# Modal spell (707.1c): card awaiting its mode choice ("" = none), and the mode
# index riding on the current targeting flow (-1 = not a modal play).
var _modal_pending_card: String = ""
var _targeting_mode: int = -1
# Quest awaiting graveyard-target selection; "" = no browser open.
var _gy_select_quest_id: String = ""
var _gy_select_hero_id: String = ""
# Quest awaiting its "exhaust N allies" cost selection; "" = no popup open.
var _ally_exhaust_quest_id: String = ""
# Ally/equipment power awaiting a graveyard-card target (Ophelia Barrows).
var _gy_select_ally_id: String = ""
# Hand Ability awaiting a graveyard-ally target (Ancestral Spirit reanimate).
var _gy_select_ability_id: String = ""
# Color used for card highlights; changes per mode (green = play, red = mandatory choice).
var _highlight_color: Color = Color(0.2, 1.0, 0.3)
# Muted cards (instance_id → true): a human convenience flag toggled via the
# context menu. A muted card stays fully playable, but is IGNORED by the
# auto-pass probes (`has_any_legal_play(true)`), so it alone never holds a
# priority window open — Turbo/ambush skip the window as if the card weren't
# there. Muting a quest/power the player never intends to play at instant
# speed (e.g. an always-completable quest) removes the constant "Skip" clicks.
# Session-level UI state, shared by both hotseat seats; cleared on a new game.
var muted_ids: Dictionary = {}


func setup(p_state: GameState, p_db, p_player: String) -> void:
	state        = p_state
	db           = p_db
	local_player = p_player


# Highlight color override — the playtest ambush mode paints the off-screen
# player's playable instants yellow. Mandatory modes (discard/sacrifice) still
# set their own red and reset to green when they end.
func set_highlight_color(color: Color) -> void:
	_highlight_color = color


# ── Input handling ─────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not state:
		return
	if event.is_action_pressed("ui_accept"):   # Spacebar or Enter
		pass_priority_action()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"): # Escape
		if _modal_pending_card != "":
			cancel_modal_choice()
		elif _targeting_action_type == "choose_quest_ferocity":
			pass   # mandatory quest-reward pick — Esc must not strand the choice
		elif _targeting_source != "":
			cancel_targeting()
		else:
			retract_last_action()
		get_viewport().set_input_as_handled()


# Called by BoardRenderer when a card visual is clicked.
func handle_card_click(instance_id: String) -> void:
	if not state:
		return

	# ── Modal mode choice open: clicking elsewhere abandons it, click proceeds ──
	if _modal_pending_card != "":
		cancel_modal_choice()

	# ── Graveyard browser open: board clicks are ignored (modal owns input) ──
	if _gy_select_quest_id != "" or _gy_select_hero_id != "" or _gy_select_ability_id != "":
		return

	# ── Ally-exhaust cost popup open: the scene owns those clicks (selection
	# toggling), so the router must not also act on them. ────────────────────
	if _ally_exhaust_quest_id != "":
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

	# ── Form sacrifice mode: click destroys the chosen Form (shapeshift) ─────
	if _in_form_sacrifice_mode:
		_handle_form_sacrifice_click(instance_id)
		return

	# ── A New Plague: click destroys the chosen own ally ─────────────────────
	if _in_plague_destroy_mode:
		_handle_plague_destroy_click(instance_id)
		return

	# ── Kolkar: click turns the chosen own quest face down ───────────────────
	if _in_quest_facedown_mode:
		_handle_quest_facedown_click(instance_id)
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

	# ── Resource-place mode (Nightbloom): click a hand card to bury it as a
	# face-down exhausted resource; declining goes through the pass button ──
	if _in_resource_place_mode:
		_handle_resource_place_click(instance_id)
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
				# "Exhaust N allies" completion cost (The Love Potion): pick the
				# allies first. Nothing is paid until the popup confirms.
				if StackResolver.get_quest_ally_exhaust_requirement(qdef) > 0:
					start_ally_exhaust_selection(instance_id)
					return
				var quest_action := PendingAction.make("use_quest", local_player,
					{"quest_id": instance_id})
				var quest_events := StackResolver.submit_action(state, quest_action, db)
				if not quest_events.is_empty():
					EventBus.emit_events(quest_events)
					_pass_own_proposal(quest_action)
					refresh_highlights()
			return
		# Any other in-play zone (e.g. an attachment in the "attached" zone) has
		# no click action — falling through would re-enter the play-from-hand
		# targeting flow for a card already in play.
		return

	# ── Hand card left-click → play / place ───────────────────────────────────
	var action_type := _action_type_for(instance_id)
	if action_type == "":
		return
	# A left-click is only a shortcut for the card's usual context-menu entry, so
	# the pre-submission flows live in ONE place both paths call.
	if _begin_play_from_hand(instance_id, action_type):
		return
	var action := PendingAction.make(action_type, local_player,
			_params_for(instance_id, action_type))
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_pass_own_proposal(action)
	refresh_highlights()


# Opens whatever pre-submission flow a hand card needs before it can be played:
# the X dialog, a modal "Choose one", the graveyard browser, or targeting mode
# (single or two-phase). Returns true when one was opened — the caller must NOT
# submit; the flow submits when the player finishes it (and Esc cancels).
#
# Left-clicking a card is only a UI shortcut for its context-menu "Play" entry,
# so BOTH paths go through here — a flow added for one is a flow for the other.
func _begin_play_from_hand(instance_id: String, action_type: String) -> bool:
	if not (action_type in ["play_ability", "play_instant"]):
		return false
	var needs_target := _ability_needs_target(instance_id) \
		if action_type == "play_ability" else _instant_needs_target(instance_id)
	# X-cost cards (Aimed Shot, "1+X"; Lightning Storm's divided pool): pick X
	# first (same dialog as Boris's pay-X hero power), then confirm_x_value
	# re-enters the targeting flow with the X riding on the submission.
	if _card_cost_x(instance_id) and needs_target:
		_targeting_source = instance_id
		x_select_requested.emit(instance_id, _max_affordable_x(instance_id))
		return true
	# Ancestral Spirit: the target is an ally card in your graveyard — open the
	# graveyard browser instead of board targeting.
	if action_type == "play_ability" and _ability_uses_graveyard_browser(instance_id):
		start_ability_graveyard_selection(instance_id)
		return true
	if not needs_target:
		return false
	# Modal spell (707.1c): pick the mode first, then target.
	if action_type == "play_instant" and _is_modal(instance_id):
		_open_modal_choice(instance_id)
		return true
	# Ravenous Bite: sequential picks, the +ATK ally first.
	if action_type == "play_instant" and _is_atk_swing(instance_id):
		_targeting_first_target = ""
		start_targeting(instance_id, "play_instant", "atk_up", 0)
		return true
	# Skewer: the ally that will deal the damage is CHOSEN first (your party
	# only), the ally it hits second.
	if _is_ally_atk_damage(instance_id):
		_targeting_first_target = ""
		start_targeting(instance_id, action_type, "skewer_source", 0)
		return true
	# Sever the Cord (and its sorcery-speed twin): the sacrificed ally is picked
	# first, the destroy target second.
	if _is_play_cost_sacrifice(instance_id):
		_targeting_first_target = ""
		start_targeting(instance_id, action_type, "sacrifice", 0)
		return true
	# Shock and Soothe: sequential picks, the damage target first.
	if action_type == "play_instant" and _is_instant_damage_and_heal(instance_id):
		_targeting_first_target = ""
	start_targeting(instance_id, action_type,
		_card_dmg_type(instance_id), _card_dmg_amount(instance_id))
	return true


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


# ── Resource-place mode (Nightbloom: put a hand card into your resource row) ──
#
# Optional, unlike the mandatory discard — so the highlight stays GREEN and the
# pass button offers the decline. Everything else is blocked by the engine while
# the choice is pending, exactly as for the control discard.

func start_resource_place_mode(source_id: String) -> void:
	_in_resource_place_mode = true
	refresh_highlights()
	resource_place_mode_started.emit(source_id)


func _handle_resource_place_click(instance_id: String) -> void:
	var card := state.get_card(instance_id)
	if not card or card.controller != local_player:
		return
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return
	var events := StackResolver.choose_hand_resource(state, instance_id, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_end_resource_place_mode()


# Player declined the optional placement ("You MAY put a card...").
func decline_hand_resource() -> void:
	if not _in_resource_place_mode:
		return
	var events := StackResolver.decline_hand_resource(state, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_end_resource_place_mode()


func _end_resource_place_mode() -> void:
	_in_resource_place_mode = false
	resource_place_mode_ended.emit()
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


# Open the browser for an ally/equipment activated power whose effect targets a
# graveyard card (Ophelia Barrows: "Remove target ally card in any graveyard
# from the game"). Candidates come from the card's graveyard_to_rfg segment.
func start_ally_graveyard_selection(card_id: String) -> void:
	var card := state.get_card(card_id)
	if not card or not db:
		return
	var def := db.get_def(card.card_def_id) as CardDef
	var req := StackResolver.get_graveyard_search_requirement(def) if def else {}
	if req.is_empty():
		return
	var candidates := StackResolver.get_graveyard_search_candidates(
			state, local_player, req, db)
	if candidates.size() < int(req.get("min_count", 1)):
		return
	_gy_select_ally_id = card_id
	graveyard_select_requested.emit(card_id, candidates,
			int(req.get("min_count", 1)), int(req.get("max_count", 1)))


# A hand Ability whose target(s) live in a graveyard rather than on the board:
# Ancestral Spirit (reanimate one ally, `target_id`) or Cannibalize (exile any
# number of ally cards from BOTH graveyards, `target_ids`). Opens the same
# browser as the ally/quest graveyard searches; the confirm submits play_ability.
func start_ability_graveyard_selection(card_id: String) -> void:
	var card := state.get_card(card_id)
	if not card or not db:
		return
	var def := db.get_def(card.card_def_id) as CardDef
	var req := StackResolver.get_graveyard_search_requirement(def) if def else {}
	if req.is_empty():
		return
	var candidates := StackResolver.get_graveyard_search_candidates(
			state, local_player, req, db)
	# Cannibalize removes "any number" (min 0), so an empty pool is NOT a reason
	# to refuse: the browser still opens so the player can see there is nothing
	# to exile and either back out or confirm an empty selection.
	if candidates.size() < int(req.get("min_count", 1)):
		return
	_gy_select_ability_id = card_id
	graveyard_select_requested.emit(card_id, candidates,
			int(req.get("min_count", 1)), int(req.get("max_count", 1)))


# Detect a hand Ability whose targets are graveyard CARDS — reanimate
# (Ancestral Spirit, dest "play"), exile (Cannibalize, dest "rfg") or fetch to
# hand (Call the Spirit, dest "hand"). All open the graveyard browser instead
# of board targeting.
func _ability_uses_graveyard_browser(card_id: String) -> bool:
	return _ability_graveyard_dest(card_id) != ""


func _ability_graveyard_dest(card_id: String) -> String:
	if not db:
		return ""
	var card := state.get_card(card_id)
	if not card:
		return ""
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return ""
	var dest: String = StackResolver.get_graveyard_search_requirement(def).get("dest", "")
	# "hand" = Call the Spirit's fetch; like the reanimate it announces a single
	# card as `target_id`, so only the "rfg" branch below needs to differ.
	return dest if dest in ["play", "rfg", "hand"] else ""


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
	if _gy_select_ability_id != "":
		var ability_id := _gy_select_ability_id
		_gy_select_ability_id = ""
		# Exile abilities (Cannibalize) announce EVERY chosen card as
		# `target_ids`; single-card abilities (Ancestral Spirit's reanimate,
		# Call the Spirit's fetch) announce the chosen card as `target_id`.
		var rz_params := {"card_id": ability_id}
		if _ability_graveyard_dest(ability_id) == "rfg":
			rz_params["target_ids"] = selected_ids.duplicate()
		else:
			rz_params["target_id"] = selected_ids[0] if not selected_ids.is_empty() else ""
		var rz_action := PendingAction.make("play_ability", local_player, rz_params)
		var rz_events := StackResolver.submit_action(state, rz_action, db)
		if rz_events.is_empty():
			refresh_highlights()
			return
		EventBus.emit_events(rz_events)
		_pass_own_proposal(rz_action)
		refresh_highlights()
		return
	if _gy_select_ally_id != "":
		var ally_id := _gy_select_ally_id
		_gy_select_ally_id = ""
		var ap_target: String = selected_ids[0] if not selected_ids.is_empty() else ""
		var ap_action := PendingAction.make("use_ally_power", local_player,
				{"card_id": ally_id, "target_id": ap_target})
		var ap_events := StackResolver.submit_action(state, ap_action, db)
		if ap_events.is_empty():
			refresh_highlights()
			return
		EventBus.emit_events(ap_events)
		_pass_own_proposal(ap_action)
		refresh_highlights()
		return


func cancel_graveyard_selection() -> void:
	_gy_select_quest_id = ""
	_gy_select_hero_id = ""
	_gy_select_ally_id = ""
	_gy_select_ability_id = ""
	refresh_highlights()


# ── Quest "exhaust N allies" cost selection (The Love Potion) ──────────────────
# A pre-submission picker, not an engine choice point: the allies are chosen and
# CONFIRMED before use_quest is ever submitted, so cancelling leaves the game
# state byte-identical (no resource spent, no ally exhausted).

func start_ally_exhaust_selection(quest_id: String) -> void:
	var card := state.get_card(quest_id)
	if not card or not db:
		return
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return
	var count := StackResolver.get_quest_ally_exhaust_requirement(def)
	if count <= 0:
		return
	var candidates := StackResolver.get_quest_exhaust_candidates(state, local_player)
	if candidates.size() < count:
		return
	_ally_exhaust_quest_id = quest_id
	ally_exhaust_select_requested.emit(quest_id, candidates, count)


func confirm_ally_exhaust_selection(selected_ids: Array) -> void:
	if _ally_exhaust_quest_id == "":
		return
	var quest_id := _ally_exhaust_quest_id
	_ally_exhaust_quest_id = ""
	var action := PendingAction.make("use_quest", local_player,
			{"quest_id": quest_id, "ally_ids": selected_ids})
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		refresh_highlights()
		return
	EventBus.emit_events(events)
	_pass_own_proposal(action)
	refresh_highlights()


func cancel_ally_exhaust_selection() -> void:
	_ally_exhaust_quest_id = ""
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


# ── Form sacrifice mode (rule 414.3b — Form (1) tag) ──────────────────────────
# Mirrors the Unique-duplicate sacrifice mode: red highlight on the in-play
# Forms, click one to destroy it (normally the OLD form — shapeshifting).

func start_form_sacrifice_mode(candidate_ids: Array) -> void:
	_in_form_sacrifice_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)  # red — mandatory Form sacrifice
	_form_sacrifice_candidates.clear()
	for cid in candidate_ids:
		_form_sacrifice_candidates.append(cid as String)
	refresh_highlights()
	form_sacrifice_mode_started.emit(candidate_ids)


func _handle_form_sacrifice_click(instance_id: String) -> void:
	if instance_id not in _form_sacrifice_candidates:
		return
	var events := StackResolver.choose_form_sacrifice(state, instance_id, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	if state.pending_form_sacrifice_player == "":
		_in_form_sacrifice_mode = false
		_highlight_color = Color(0.2, 1.0, 0.3)
		_form_sacrifice_candidates.clear()
		form_sacrifice_mode_ended.emit()
	else:
		_form_sacrifice_candidates.clear()
		for cid: String in state.pending_form_sacrifice_ids:
			_form_sacrifice_candidates.append(cid)
	refresh_highlights()


# ── Targeting ──────────────────────────────────────────────────────────────────

# General entry point.  action_type is "propose_combat" or "activate_power".
# dmg_type is the icon key ("fire", "melee", …) or "" for a crosshair cursor.
func start_targeting(source_id: String, action_type: String,
		dmg_type: String, dmg_amount: int = 0) -> void:
	_targeting_source      = source_id
	_targeting_action_type = action_type
	_targeting_dmg_type    = dmg_type
	# Lightning Storm's click list belongs to one cast — a fresh targeting flow
	# always starts from zero points assigned.
	_divided_picked        = []
	refresh_highlights()
	targeting_started.emit(source_id, dmg_type, dmg_amount)


# Convenience wrapper: look up the attacker's dmg_type / ATK and enter combat targeting.
# `weapon_id` is set when the player launched the attack off a specific weapon
# ("Attack" on the weapon's context menu) — the strike is then a foregone
# conclusion, so the cursor previews the post-strike numbers instead of the bare
# hero's.
func start_attack_targeting(attacker_id: String, weapon_id: String = "") -> void:
	var dmg_type   := ""   # default → crosshair; set only when card has an explicit dmg_type
	var dmg_amount := 0
	if db:
		var card := state.get_card(attacker_id)
		if card:
			var def := db.get_def(card.card_def_id) as CardDef
			if def and def.dmg_type != "":
				dmg_type = def.dmg_type.to_lower()
		# The weapon's damage type is the one that will be dealt (303.2b), so it
		# also picks the cursor icon — a hero has no printed type of its own.
		var weapon: CardInstance = state.get_card(weapon_id) if weapon_id != "" else null
		if weapon:
			var wdef := db.get_def(weapon.card_def_id) as CardDef
			if wdef and wdef.dmg_type != "":
				dmg_type = wdef.dmg_type.to_lower()
	if state:
		# Preview the ATK this attacker will actually deal once combat is
		# proposed (rule 601 — it isn't "attacking" yet during target
		# selection, so plain get_atk would omit "while attacking" bonuses
		# like Zorm / Rayder / For the Horde! here), including the weapon it is
		# about to strike with and the typed replacement effects that weapon
		# turns on (Aspect of the Hawk's ranged +1). ATK auras — Hootie's -1,
		# Ryn's +2 — are already inside get_atk, netted before its 0 floor.
		dmg_amount = state.get_atk_if_attacking(attacker_id, db, weapon_id)
		dmg_amount = StackResolver.preview_combat_damage_amount(
			state, db, attacker_id, dmg_amount, weapon_id)
	# Set AFTER the reset in start_targeting so the strike point can auto-strike it.
	start_targeting(attacker_id, "propose_combat", dmg_type, dmg_amount)
	preferred_strike_weapon = weapon_id


# Convenience wrapper for enters-play targeted effects (e.g. Taz'dingo).
func start_enter_play_targeting(card_id: String, dmg_type: String, dmg_amount: int) -> void:
	start_targeting(card_id, "choose_enter_play_target", dmg_type, dmg_amount)


# Convenience wrapper for an ongoing Totem start-of-turn target choice (Searing Totem).
func start_trigger_targeting(card_id: String, dmg_type: String, dmg_amount: int) -> void:
	start_targeting(card_id, "choose_trigger_target", dmg_type, dmg_amount)


# Convenience wrapper for a death-triggered targeted choice — Boneshanks
# ("destroy target ally") or Vexra Darkfall ("target hero"). The pool comes from
# the queued trigger itself (get_active_death_target_targets), so one flow covers
# both and any future death trigger with its own pool.
func start_death_target_targeting(card_id: String) -> void:
	start_targeting(card_id, "choose_death_target", "", 0)


# Convenience wrapper for Hidden Enemies' "target ally has ferocity this turn"
# reward pick. Mandatory — Esc is absorbed while this targeting is active.
func start_quest_ferocity_targeting(quest_id: String) -> void:
	start_targeting(quest_id, "choose_quest_ferocity", "", 0)


# Convenience wrapper for Dragonkin Menace's "ready a hero or ally in your party"
# reward pick. Mandatory — Esc is absorbed while this targeting is active. The
# pool is a CHOICE rather than a target, so Untargetable characters are offered.
func start_quest_ready_targeting(quest_id: String) -> void:
	start_targeting(quest_id, "choose_quest_ready", "", 0)


# A New Plague: mandatory "destroy an ally in your party" pick (red highlights,
# like the pet sacrifice).
func start_plague_destroy_mode(candidate_ids: Array) -> void:
	_in_plague_destroy_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)
	_plague_destroy_candidates.clear()
	for cid in candidate_ids:
		_plague_destroy_candidates.append(cid as String)
	refresh_highlights()
	plague_destroy_mode_started.emit(candidate_ids)


func _handle_plague_destroy_click(instance_id: String) -> void:
	if instance_id not in _plague_destroy_candidates:
		return
	var events := StackResolver.choose_plague_destroy(state, instance_id, db)
	if events.is_empty():
		return
	_in_plague_destroy_mode = false
	_highlight_color = Color(0.2, 1.0, 0.3)
	_plague_destroy_candidates.clear()
	plague_destroy_mode_ended.emit()
	EventBus.emit_events(events)
	refresh_highlights()
	quest_flow_resolved.emit()


# Thwarting Kolkar Aggression: mandatory "turn one of your quests face down"
# pick (red highlights over the player's own face-up quests).
func start_quest_facedown_mode(candidate_ids: Array) -> void:
	_in_quest_facedown_mode = true
	_highlight_color = Color(1.0, 0.25, 0.25)
	_quest_facedown_candidates.clear()
	for cid in candidate_ids:
		_quest_facedown_candidates.append(cid as String)
	refresh_highlights()
	quest_facedown_mode_started.emit(candidate_ids)


func _handle_quest_facedown_click(instance_id: String) -> void:
	if instance_id not in _quest_facedown_candidates:
		return
	var events := StackResolver.choose_quest_facedown(state, instance_id, db)
	if events.is_empty():
		return
	_in_quest_facedown_mode = false
	_highlight_color = Color(0.2, 1.0, 0.3)
	_quest_facedown_candidates.clear()
	quest_facedown_mode_ended.emit()
	EventBus.emit_events(events)
	refresh_highlights()
	quest_flow_resolved.emit()


# Convenience wrapper for the attack-exhaust trigger (Chops / Voss Treebender):
# "When [this] attacks, you may exhaust target hero or ally." Optional — Esc
# cancels, which the scene resolves as a decline.
func start_attack_exhaust_targeting(card_id: String) -> void:
	start_targeting(card_id, "choose_attack_exhaust", "", 0)


func targeting_action_type() -> String:
	return _targeting_action_type


# True when the targeting flow currently open CANNOT be backed out of — the
# effect is mandatory, so Esc / right-click only restarts the same pick (see
# playtest `_on_targeting_cancelled`). The prompt says "[mandatory]" instead of
# offering a cancel that doesn't exist.
func targeting_is_mandatory() -> bool:
	match _targeting_action_type:
		"choose_trigger_target", "choose_death_target", "choose_quest_ferocity":
			return true
		"choose_enter_play_target":
			# Optional enter-play triggers (Ghank, Karkas, Sister Rot, Bhenn) can
			# be declined; Taz'dingo's "deals damage to target" cannot.
			return state != null and not state.pending_enter_play_effect.is_empty() \
				and not state.pending_enter_play_effect.get("optional", false)
	return false


# Abort targeting — called by Escape key or scene logic.
func cancel_targeting() -> void:
	_targeting_source       = ""
	_targeting_action_type  = ""
	_targeting_dmg_type     = ""
	preferred_strike_weapon = ""
	_targeting_first_target = ""
	_targeting_x_value      = 0
	_targeting_mode         = -1
	_chain_lightning_picked = []
	_divided_picked         = []
	refresh_highlights()
	targeting_cancelled.emit()


# ── Modal spells (rule 707.1c — "Choose one:", Natural Selection) ───────────────
# The mode is picked BEFORE targeting: clicking the card emits
# modal_choice_opened; the scene shows one button per mode label and calls
# choose_modal_mode(index), which enters the normal instant targeting flow with
# the chosen mode index riding on the submission (params.mode).

func _is_modal(card_id: String) -> bool:
	if not db:
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return def != null and StackResolver.is_modal_def(def)


func _open_modal_choice(card_id: String) -> void:
	_modal_pending_card = card_id
	var def := db.get_def(state.get_card(card_id).card_def_id) as CardDef
	var labels: Array = []
	for mode in StackResolver.modal_modes(def):
		labels.append(_modal_mode_label(mode))
	modal_choice_opened.emit(card_id, labels)


func _modal_mode_label(mode_effect: String) -> String:
	var parts := mode_effect.split(":")
	match parts[0]:
		"deal_damage_to_target":
			if parts.size() > 2:
				return "Deal %s %s damage" % [parts[1], parts[2]]
		"heal_target":
			if parts.size() > 1:
				return "Heal %s damage" % parts[1]
		"interrupt_ability":
			return "Interrupt an ability targeting your hero"
		"remove_attackers":
			return "Remove all attackers from combat"
	return mode_effect


func choose_modal_mode(mode_index: int) -> void:
	var card_id := _modal_pending_card
	_modal_pending_card = ""
	modal_choice_cancelled.emit()   # the scene removes its buttons either way
	if card_id == "" or not _is_modal(card_id):
		return
	var def := db.get_def(state.get_card(card_id).card_def_id) as CardDef
	var modes := StackResolver.modal_modes(def)
	if mode_index < 0 or mode_index >= modes.size():
		return
	_targeting_mode = mode_index
	# Mode-aware targeting (Escape Artist): a mode that announces no target
	# ("…remove all attackers from combat") has nothing to point at, so the mode
	# button IS the submission — entering targeting mode would strand the player
	# with no legal click.
	if StackResolver.mode_target_kind(modes[mode_index]) == "":
		var act := PendingAction.make(_action_type_for(card_id), local_player,
			{"card_id": card_id, "mode": mode_index})
		_targeting_mode = -1
		var events := StackResolver.submit_action(state, act, db)
		if events.is_empty():
			return
		EventBus.emit_events(events)
		_pass_own_proposal(act)
		refresh_highlights()
		return
	var parts := (modes[mode_index] as String).split(":")
	var dmg_type := ""
	var amount := 0
	match parts[0]:
		"deal_damage_to_target":
			dmg_type = parts[2].to_lower() if parts.size() > 2 else ""
			amount   = _preview_dmg(int(parts[1]) if parts.size() > 1 else 0, dmg_type, true)
		"heal_target":
			dmg_type = "heal"
			amount   = int(parts[1]) if parts.size() > 1 else 0
	start_targeting(card_id, "play_instant", dmg_type, amount)


# Is the active targeting flow a modal interrupt mode (Escape Artist)? The mode
# index rides _targeting_mode, so this is the one thing that distinguishes a
# chain-link pick from an ordinary hero-or-ally pick.
func _is_interrupt_mode() -> bool:
	if _targeting_mode < 0 or _targeting_source == "" or not db:
		return false
	var card := state.get_card(_targeting_source)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return false
	var modes := StackResolver.modal_modes(def)
	if _targeting_mode >= modes.size():
		return false
	return StackResolver.mode_target_kind(modes[_targeting_mode]) == "interrupt_ability"


func cancel_modal_choice() -> void:
	_modal_pending_card = ""
	modal_choice_cancelled.emit()


func _handle_targeting_click(instance_id: String) -> void:
	match _targeting_action_type:
		"propose_combat":            _handle_combat_targeting_click(instance_id)
		"activate_power":            _handle_power_targeting_click(instance_id)
		"activate_power_x":          _handle_x_power_targeting_click(instance_id)
		"choose_enter_play_target":  _handle_enter_play_targeting_click(instance_id)
		"choose_trigger_target":       _handle_trigger_targeting_click(instance_id)
		"choose_death_target":       _handle_death_target_targeting_click(instance_id)
		"choose_quest_ferocity":     _handle_quest_ferocity_targeting_click(instance_id)
		"choose_quest_ready":        _handle_quest_ready_targeting_click(instance_id)
		"choose_attack_exhaust":     _handle_attack_exhaust_targeting_click(instance_id)
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


func _handle_trigger_targeting_click(instance_id: String) -> void:
	# Ongoing Totem start-of-turn damage (Searing Totem). The TARGET choice is a
	# mandatory direct-call point; choose_trigger_target then puts the trigger on the
	# chain and opens a priority window (the emitted action_proposed drives the
	# scene's _drain_passes) before the damage resolves (rule 501.1a / 410).
	if instance_id in StackResolver.get_turn_start_trigger_targets(state, db):
		var events := StackResolver.choose_trigger_target(state, instance_id, db)
		cancel_targeting()
		EventBus.emit_events(events)
		# The scene resumes driving the turn (and handles any next queued totem).
		trigger_target_resolved.emit()


func _handle_death_target_targeting_click(instance_id: String) -> void:
	# Boneshanks death trigger. Mandatory, direct-call resolution (no chain) —
	# like the totem choice. Resolving may open the next queued death trigger.
	if instance_id in StackResolver.get_active_death_target_targets(state, db):
		var events := StackResolver.choose_death_target(state, instance_id, db)
		cancel_targeting()
		EventBus.emit_events(events)
		death_target_resolved.emit()


func _handle_quest_ferocity_targeting_click(instance_id: String) -> void:
	# Hidden Enemies reward pick. Mandatory, direct-call resolution (no chain).
	if instance_id in StackResolver.get_quest_ferocity_targets(state, db):
		var events := StackResolver.choose_quest_ferocity_target(state, instance_id, db)
		cancel_targeting()
		EventBus.emit_events(events)
		quest_flow_resolved.emit()


func _handle_quest_ready_targeting_click(instance_id: String) -> void:
	# Dragonkin Menace reward pick. Mandatory, direct-call resolution (no chain).
	if instance_id in StackResolver.get_quest_ready_candidates(state, state.pending_quest_ready_player):
		var events := StackResolver.choose_quest_ready_target(state, instance_id, db)
		cancel_targeting()
		EventBus.emit_events(events)
		quest_flow_resolved.emit()


func _handle_attack_exhaust_targeting_click(instance_id: String) -> void:
	# Chops / Voss Treebender attack-exhaust trigger. Optional, direct-call
	# resolution (no chain) — like the ready-on-attack point. Resolving opens
	# the held attack window, whose scene handler drains passes.
	if instance_id in StackResolver.get_attack_exhaust_targets(state, db):
		var events := StackResolver.choose_attack_exhaust(state, instance_id, db)
		cancel_targeting()
		EventBus.emit_events(events)


func _handle_ability_targeting_click(instance_id: String) -> void:
	# Chain Lightning: up to 3 targets, one click per wave — see
	# _handle_chain_lightning_click / _submit_chain_lightning below.
	if _is_multi_target(_targeting_source):
		_handle_chain_lightning_click(instance_id)
		return
	# Lightning Storm: one click per point of X (see _handle_divided_click).
	if _is_divided_damage(_targeting_source):
		_handle_divided_click(instance_id)
		return
	var action := PendingAction.make("play_ability", local_player,
		_instant_params(_targeting_source, instance_id))
	if StackResolver.can_submit(state, action, db):
		_targeting_source = ""
		_targeting_x_value = 0
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

# True for any multi-target announced-in-order spell: Chain Lightning
# (play_ability) and Multi-Shot (play_instant). Both drive the same picking
# flow below; the action_type is looked up per card via _action_type_for.
func _is_multi_target(card_id: String) -> bool:
	if not db or card_id == "":
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	if not def:
		return false
	return StackResolver._has_effect_flag_prefix(def, "chain_lightning") \
		or StackResolver._has_effect_flag_prefix(def, "multi_shot")


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
	var probe := PendingAction.make(_action_type_for(_targeting_source), local_player,
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
	var action := PendingAction.make(_action_type_for(_targeting_source), local_player,
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


# ── Lightning Storm (dark_portal_98) — X clicks, one per point of damage ──────
#
# The X is picked first (the shared X-select dialog, since the card costs
# "2+X"), then the player clicks an ally once per point: X clicks total, the
# SAME ally may be clicked repeatedly, and the status line counts "N / X
# target". Nothing is submitted until the last point is assigned — Esc (or
# clicking the spell) cancels the whole cast, since no cost has been paid yet.

func _is_divided_damage(card_id: String) -> bool:
	if not db or card_id == "":
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return StackResolver.is_divided_damage_def(def)


# [points assigned so far, total X] for the current divided-damage cast, so the
# scene can render the "N / X target" prompt. [0, 0] when none is in progress.
func divided_progress() -> Array:
	if _targeting_source == "" or not _is_divided_damage(_targeting_source):
		return [0, 0]
	return [_divided_picked.size(), _targeting_x_value]


# Probe/submission params. `_divided_probe` relaxes the "exactly X picks" rule
# in StackResolver._can_play_divided_damage so a partial list can be tested one
# click at a time; it is never set on the real submission.
func _divided_params(extra_target_id: String = "", probe := false) -> Dictionary:
	var picks: Array[String] = _divided_picked.duplicate()
	if extra_target_id != "":
		picks.append(extra_target_id)
	var params := {
		"card_id":   _targeting_source,
		"x_value":   _targeting_x_value,
		"target_ids": picks,
	}
	if probe:
		params["_divided_probe"] = true
	return params


func _handle_divided_click(instance_id: String) -> void:
	if instance_id == _targeting_source:
		cancel_targeting()
		return
	if _divided_picked.size() >= _targeting_x_value:
		return
	var probe := PendingAction.make(_action_type_for(_targeting_source), local_player,
		_divided_params(instance_id, true))
	if not StackResolver.can_submit(state, probe, db):
		return
	_divided_picked.append(instance_id)
	if _divided_picked.size() >= _targeting_x_value:
		_submit_divided()
		return
	# Re-emit to refresh the "N / X target" prompt and the cursor's remaining
	# point count; every legal ally stays legal (repeats are allowed).
	targeting_started.emit(_targeting_source, _targeting_dmg_type,
		_targeting_x_value - _divided_picked.size())
	refresh_highlights()


func _submit_divided() -> void:
	var action := PendingAction.make(_action_type_for(_targeting_source), local_player,
		_divided_params())
	_targeting_source  = ""
	_divided_picked    = []
	_targeting_x_value = 0
	targeting_cancelled.emit()
	var events := StackResolver.submit_action(state, action, db)
	if events.is_empty():
		return
	EventBus.emit_events(events)
	_pass_own_proposal(action)
	refresh_highlights()


func _handle_instant_targeting_click(instance_id: String) -> void:
	if _is_multi_target(_targeting_source):
		_handle_chain_lightning_click(instance_id)
		return
	if _is_divided_damage(_targeting_source):
		_handle_divided_click(instance_id)
		return
	# Ravenous Bite: phase 1 picks the +ATK ally, phase 2 the -ATK ally.
	if _is_atk_swing(_targeting_source) and _targeting_first_target == "":
		if instance_id == _targeting_source:
			cancel_targeting()
			return
		var probe := PendingAction.make("play_instant", local_player,
			_instant_params(_targeting_source, instance_id))
		if not StackResolver.can_submit(state, probe, db):
			return
		_targeting_first_target = instance_id
		# Re-emit so the prompt switches to the -ATK half and the remaining
		# legal allies re-highlight (the same ally stays legal — it may be
		# named twice, netting 0).
		targeting_started.emit(_targeting_source, "atk_down", 0)
		refresh_highlights()
		return
	# Skewer: phase 1 CHOOSES the source ally (own party only), phase 2 targets
	# the ally it damages. Phase 2's cursor shows that ally's live ATK, which is
	# the damage it will deal (read again at resolution).
	if _is_ally_atk_damage(_targeting_source) and _targeting_first_target == "":
		if instance_id == _targeting_source:
			cancel_targeting()
			return
		var sk_probe := PendingAction.make(_action_type_for(_targeting_source),
			local_player, _instant_params(_targeting_source, instance_id))
		if not StackResolver.can_submit(state, sk_probe, db):
			return
		_targeting_first_target = instance_id
		targeting_started.emit(_targeting_source,
			_skewer_source_dmg_type(instance_id), state.get_atk(instance_id, db))
		refresh_highlights()
		return
	# Sever the Cord: phase 1 picks the ally sacrificed as an additional cost
	# (own party only), phase 2 the destroy target.
	if _is_play_cost_sacrifice(_targeting_source) and _targeting_first_target == "":
		if instance_id == _targeting_source:
			cancel_targeting()
			return
		var sac_probe := PendingAction.make(_action_type_for(_targeting_source),
			local_player, _instant_params(_targeting_source, instance_id))
		if not StackResolver.can_submit(state, sac_probe, db):
			return
		_targeting_first_target = instance_id
		# Re-emit so the prompt switches to the destroy half and the legal
		# targets (either party) re-highlight.
		targeting_started.emit(_targeting_source, "destroy", 0)
		refresh_highlights()
		return
	# Shock and Soothe: phase 1 picks the damage target, phase 2 the heal target.
	if _is_instant_damage_and_heal(_targeting_source) and _targeting_first_target == "":
		if instance_id == _targeting_source:
			cancel_targeting()
			return
		var dh_probe := PendingAction.make("play_instant", local_player,
			_instant_params(_targeting_source, instance_id))
		if not StackResolver.can_submit(state, dh_probe, db):
			return
		_targeting_first_target = instance_id
		# Re-emit so the prompt switches to the heal half and the remaining legal
		# characters re-highlight (the damage target itself drops out — "another").
		targeting_started.emit(_targeting_source, "heal", 0)
		refresh_highlights()
		return
	var action := PendingAction.make("play_instant", local_player,
		_instant_params(_targeting_source, instance_id))
	if StackResolver.can_submit(state, action, db):
		_targeting_source = ""
		_targeting_mode   = -1
		_targeting_x_value = 0
		_targeting_first_target = ""
		targeting_cancelled.emit()
		var events := StackResolver.submit_action(state, action, db)
		if events.is_empty():
			return
		EventBus.emit_events(events)
		_pass_own_proposal(action)
		refresh_highlights()
	elif instance_id == _targeting_source:
		# Ravenous Bite phase 2: clicking the spell again steps back to the
		# +ATK pick instead of cancelling the whole cast.
		if _is_atk_swing(_targeting_source) and _targeting_first_target != "":
			_targeting_first_target = ""
			targeting_started.emit(_targeting_source, "atk_up", 0)
			refresh_highlights()
			return
		# Skewer phase 2: clicking the spell again steps back to the source
		# pick. Nothing has been announced yet, so this is free.
		if _is_ally_atk_damage(_targeting_source) and _targeting_first_target != "":
			_targeting_first_target = ""
			targeting_started.emit(_targeting_source, "skewer_source", 0)
			refresh_highlights()
			return
		# Sever the Cord phase 2: clicking the spell again steps back to the
		# sacrifice pick instead of cancelling the whole cast. Nothing has been
		# paid yet — the sacrifice is destroyed only on submission.
		if _is_play_cost_sacrifice(_targeting_source) and _targeting_first_target != "":
			_targeting_first_target = ""
			targeting_started.emit(_targeting_source, "sacrifice", 0)
			refresh_highlights()
			return
		# Shock and Soothe phase 2: same step-back to the damage pick.
		if _is_instant_damage_and_heal(_targeting_source) and _targeting_first_target != "":
			_targeting_first_target = ""
			targeting_started.emit(_targeting_source,
				_card_dmg_type(_targeting_source), _card_dmg_amount(_targeting_source))
			refresh_highlights()
			return
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
	# The auto-pass belongs to the PROPOSER. Emitting the submission's events may
	# have re-pointed this router at the OTHER seat (hotseat: the ambush stop for
	# the off-screen responder fires inside the emit, e.g. right after a combat
	# proposal so Litori's freeze / Exhaustion can still fizzle it) — passing then
	# would spend the responder's priority and resolve the proposal unanswered.
	if action.source_player != local_player:
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

	# Form sacrifice mode: highlight the in-play Forms.
	if _in_form_sacrifice_mode and state.pending_form_sacrifice_player == local_player:
		var form_ids: Array = []
		for cid: String in _form_sacrifice_candidates:
			form_ids.append(cid)
		return form_ids

	# A New Plague: highlight the player's own allies (mandatory sacrifice).
	if _in_plague_destroy_mode and state.pending_plague_destroy_player == local_player:
		var plague_ids: Array = []
		for cid: String in _plague_destroy_candidates:
			plague_ids.append(cid)
		return plague_ids

	# Kolkar: highlight the player's own face-up quests (mandatory flip).
	if _in_quest_facedown_mode and state.pending_quest_facedown_player == local_player:
		var fd_ids: Array = []
		for cid: String in _quest_facedown_candidates:
			fd_ids.append(cid)
		return fd_ids

	# Control-discard mode (Infernal): all local hand cards are valid discard
	# choices (declining goes through the pass button, not a card click).
	if _in_control_discard_mode and state.pending_control_discard_player == local_player:
		var cd_ids: Array = []
		for card in state.cards_in_zone(local_player + "_hand"):
			cd_ids.append(card.instance_id)
		return cd_ids

	# Resource-place mode (Nightbloom): any local hand card may be buried
	# (declining goes through the pass button, not a card click).
	if _in_resource_place_mode and state.pending_resource_place_player == local_player:
		var rp_ids: Array = []
		for card in state.cards_in_zone(local_player + "_hand"):
			rp_ids.append(card.instance_id)
		return rp_ids

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
			"choose_trigger_target":
				return StackResolver.get_turn_start_trigger_targets(state, db)
			"choose_death_target":
				return StackResolver.get_active_death_target_targets(state, db)
			"choose_quest_ferocity":
				return StackResolver.get_quest_ferocity_targets(state, db)
			"choose_quest_ready":
				return StackResolver.get_quest_ready_candidates(state, state.pending_quest_ready_player)
			"choose_attack_exhaust":
				return StackResolver.get_attack_exhaust_targets(state, db)
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
			# Activated power (ally / equipment).
			var ap_data := StackResolver._ally_activated_power(def)
			if ap_data == {}:
				continue
			var ap_needs_target: bool = (ap_data.get("targets", "") as String) in ["hero_or_ally", "ally", "hero_or_ally_two"]
			if ap_needs_target:
				# Affordability only — target chosen after targeting mode starts.
				var ap_extra_cost: String = ap_data.get("extra_cost", "")
				var ap_once_per_turn: bool = StackResolver.power_has_extra_cost(ap_extra_cost, "once_per_turn")
				var ap_no_activate_symbol: bool = StackResolver._power_has_no_activate_symbol(ap_extra_cost)
				var ap_ready_ok: bool
				if ap_once_per_turn:
					ap_ready_ok = not card.used_this_turn
				elif ap_no_activate_symbol:
					ap_ready_ok = true
				else:
					ap_ready_ok = not card.is_exhausted and not card.just_summoned
				# Powers are instant-speed (rule 701) — legal in any priority window.
				# "Use only on your turn" (701.1) narrows the turn and nothing else.
				if ap_ready_ok \
						and state.get_available_resources(local_player) >= int(ap_data.get("resource_cost", 0)) \
						and state.priority_player == local_player \
						and (not StackResolver.requires_turn_player(def) \
							or state.turn_player == local_player):
					result.append(card.instance_id)
			else:
				# graveyard_ally powers (Ophelia Barrows) pick their target in the
				# browser afterward, ability_or_equipment (Kavai) in targeting mode —
				# the skip-target probe still verifies a candidate exists, so no
				# false green with nothing to target.
				var ap_action := PendingAction.make("use_ally_power", local_player,
					{"card_id": card.instance_id,
						"_skip_target_check": (ap_data.get("targets", "") as String) in ["graveyard_ally", "ability_or_equipment", "ability", "equipment", "exhausted_ally"]})
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
# `exclude_muted`: auto-pass probes (Turbo layer 3, hotseat ambush stop) pass
# true so muted cards don't hold priority windows open; UI callers (pass button
# label) pass false — a muted card is still a real legal play.
func has_any_legal_play(exclude_muted: bool = false) -> bool:
	if not state or state.priority_player != local_player:
		return false
	for pid: String in get_playable_card_ids():
		if not (exclude_muted and muted_ids.has(pid)):
			return true
	# Check face-down resource placement (context-menu only).
	var fd_action_template := PendingAction.make("place_resource", local_player,
		{"card_id": "", "face_up": false})
	for card in state.cards_in_zone(local_player + "_hand"):
		if exclude_muted and muted_ids.has(card.instance_id):
			continue
		fd_action_template.params["card_id"] = card.instance_id
		if StackResolver.can_submit(state, fd_action_template, db):
			return true
	# Check activated powers — allies (ally row) and equipment (hero row).
	# Legal on either player's turn (rule 701.2).
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(local_player + zone_suffix):
			if exclude_muted and muted_ids.has(card.instance_id):
				continue
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
					{"quest_id": instance_id, "_needs_gy_targets": needs_gy,
					"_needs_ally_exhaust":
						StackResolver.get_quest_ally_exhaust_requirement(def) > 0})
				return [{"label": "Complete Quest — %s" % def.card_name,
					"action": a, "enabled": StackResolver.can_use_quest_no_target_check(
						state, instance_id, local_player, db)},
					_mute_entry(instance_id)]
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
					var ap_kind: String = ap_data.get("targets", "") as String
					var ap_needs_target: bool = ap_kind in ["hero_or_ally", "ally", "friendly_ally", "hero_or_ally_two", "ability_or_equipment", "ability", "equipment", "exhausted_ally"]
					var ap_needs_gy_target: bool = ap_kind == "graveyard_ally"
					var ap_enabled: bool
					if ap_needs_gy_target or ap_kind in ["ability_or_equipment", "ability", "equipment", "exhausted_ally"]:
						# Target picked afterward (graveyard browser / targeting mode) —
						# the skip-target probe checks everything else, including that
						# a candidate exists at all.
						ap_enabled = StackResolver.can_submit(state,
							PendingAction.make("use_ally_power", local_player,
								{"card_id": instance_id, "_skip_target_check": true}), db)
					elif ap_needs_target:
						# Check affordability only (target chosen after targeting mode starts).
						# No turn_player restriction — ally powers work on either player's turn
						# as long as you hold priority (e.g. defending with Grimdron's power).
						var ap_extra_cost: String = ap_data.get("extra_cost", "")
						var ap_once_per_turn: bool = StackResolver.power_has_extra_cost(ap_extra_cost, "once_per_turn")
						var ap_no_activate_symbol: bool = StackResolver._power_has_no_activate_symbol(ap_extra_cost)
						var ap_ready_ok: bool
						if ap_once_per_turn:
							ap_ready_ok = not card.used_this_turn
						elif ap_no_activate_symbol:
							ap_ready_ok = true
						else:
							ap_ready_ok = not card.is_exhausted and not card.just_summoned
						# Powers are instant-speed (rule 701) — legal in any priority
						# window. "Use only on your turn" (701.1) narrows the turn and
						# nothing else.
						ap_enabled = ap_ready_ok \
							and state.get_available_resources(local_player) >= int(ap_data.get("resource_cost", 0)) \
							and StackResolver._can_pay_extra_power_cost(state, local_player, ap_extra_cost, db) \
							and state.priority_player == local_player \
							and (not StackResolver.requires_turn_player(def) \
								or state.turn_player == local_player)
					else:
						var ap_action := PendingAction.make("use_ally_power", local_player,
							{"card_id": instance_id})
						ap_enabled = StackResolver.can_submit(state, ap_action, db)
					char_actions.append({"label": "Activate Power",
						"action": PendingAction.make("use_ally_power", local_player,
							{"card_id": instance_id, "_needs_target": ap_needs_target,
								"_needs_gy_target": ap_needs_gy_target}),
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
					char_actions.append({"label": "Use Hero Power",
						"action": PendingAction.make(power_atype, local_player,
							{"hero_id": instance_id}),
						"enabled": can_power})

			char_actions.append(_mute_entry(instance_id))
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

	result.append(_mute_entry(instance_id))
	return result


# Context-menu Mute/Unmute toggle — see `muted_ids`. Always enabled: muting is
# pure UI state, legal on any of the local player's cards at any time.
func _mute_entry(instance_id: String) -> Dictionary:
	var label := "Unmute (respond in priority windows)" \
		if muted_ids.has(instance_id) \
		else "Mute (don't hold priority windows)"
	return {"label": label,
		"action": PendingAction.make("toggle_mute", local_player,
			{"card_id": instance_id}),
		"enabled": true}


func handle_context_action(action: PendingAction) -> void:
	if not state:
		return
	match action.action_type:
		"toggle_mute":
			var mute_id: String = action.params.get("card_id", "")
			if muted_ids.has(mute_id):
				muted_ids.erase(mute_id)
			else:
				muted_ids[mute_id] = true
			card_mute_changed.emit(mute_id, muted_ids.has(mute_id))
			return
		"play_ability", "play_instant":
			# Same pre-submission flows as a left-click (X dialog, modal choice,
			# graveyard browser, one- or two-phase targeting) — the menu entry and
			# the click shortcut must play the card the same way.
			if _begin_play_from_hand(action.params.get("card_id", ""), action.action_type):
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
			# "Exhaust N allies" completion cost (The Love Potion): the context-menu
			# entry opens the ally picker, same as a left-click. Nothing is paid
			# until the popup confirms, so cancelling is still free — but a human
			# expects "Complete Quest" to take them to the choice, not to fail.
			if action.params.get("_needs_ally_exhaust", false):
				start_ally_exhaust_selection(action.params.get("quest_id", ""))
				return
		"use_ally_power":
			if action.params.get("_needs_gy_target", false):
				start_ally_graveyard_selection(action.params.get("card_id", ""))
				return
			if action.params.get("_needs_target", false):
				var cid: String = action.params.get("card_id", "")
				var ally_card := state.get_card(cid) if state else null
				var ally_def := db.get_def(ally_card.card_def_id) as CardDef if ally_card and db else null
				var ally_ap := StackResolver._ally_activated_power(ally_def) if ally_def else {}
				var ap_dmg_type: String
				# Two-pick sacrifice powers (Gertha, Besh'iah) open on phase 1, the
				# ally to SACRIFICE — a different question from what the effect
				# destroys, so it gets its own cursor and prompt.
				if StackResolver.power_sacrifice_is_separate(ally_ap):
					ap_dmg_type = "sacrifice"
				elif ally_ap and (ally_ap.get("effect", "") as String) in ["heal_target", "heal_x_from_target"]:
					ap_dmg_type = "heal"
				elif ally_ap and (ally_ap.get("effect", "") as String).begins_with("destroy"):
					ap_dmg_type = "destroy"   # Kavai — same cursor as Vanquish/Burn Away
				else:
					ap_dmg_type = (ally_ap.get("dmg_type", "") as String).to_lower() if ally_ap else ""
					# A damage power whose recipe prints no damage type (Rod of the
					# Ogre Magi: "deals 1 damage to target hero or ally") is still
					# DAMAGE — default to melee so the cursor/prompt read as damage
					# rather than falling through to the heal wording.
					if ap_dmg_type == "":
						ap_dmg_type = "melee"
				start_targeting(cid, "use_ally_power", ap_dmg_type, int(ally_ap.get("amount", 0)))
				return
		"begin_attack_targeting":
			if state.priority_player == local_player:
				# The weapon (if any) is auto-struck at the strike point, and the
				# cursor previews the damage including it.
				start_attack_targeting(action.params.get("attacker_id", ""),
					action.params.get("preferred_weapon_id", ""))
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
	# Hur Shieldsmasher / Zygore Bladebreaker: target equipment (armor/weapon).
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_hero_row"):
			var eq_def := db.get_def(card.card_def_id) as CardDef if db else null
			if not eq_def or eq_def.card_type != "Equipment":
				continue
			var act := PendingAction.make("choose_enter_play_target", local_player,
				{"source_card_id": source_card_id, "target_id": card.instance_id})
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
	# Sister Rot: target in-play ability cards (ongoing abilities, totems,
	# attachments). Totems already came through the ally-row loop above, so
	# skip anything already collected.
	if db:
		for ab_id in StackResolver.get_destroy_kind_candidates(state, db, "ability"):
			if ab_id in result:
				continue
			var act := PendingAction.make("choose_enter_play_target", local_player,
				{"source_card_id": source_card_id, "target_id": ab_id})
			if StackResolver.can_submit(state, act, db):
				result.append(ab_id)
	return result


func _get_ability_targets(card_id: String) -> Array:
	if _is_multi_target(card_id):
		return _get_chain_lightning_targets(card_id)
	# Lightning Storm: every legal ally stays offered for every one of the X
	# clicks (the same ally may take several points).
	if _is_divided_damage(card_id):
		return _get_divided_targets(card_id)
	# Burn Away / Shattering Blow: targets are in-play ability / equipment
	# cards (hero rows, totems, attachments), not heroes and allies.
	var kind := _destroy_kind(card_id)
	if kind in ["ability", "equipment"]:
		return _get_destroy_kind_targets(card_id, "play_ability", kind)
	# Windfury Weapon (`attach:melee_weapon`): targets are the caster's own Melee
	# weapons in the hero row, not heroes/allies.
	var src_card := state.get_card(card_id)
	var src_def := db.get_def(src_card.card_def_id) as CardDef if src_card else null
	if src_def and StackResolver._attach_targets_weapon_only(src_def):
		var w_result: Array = []
		for card in state.cards_in_zone(local_player + "_hero_row"):
			var w_act := PendingAction.make("play_ability", local_player,
				_instant_params(card_id, card.instance_id))
			if StackResolver.can_submit(state, w_act, db):
				w_result.append(card.instance_id)
		return w_result
	var result: Array = []
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("play_ability", local_player,
				_instant_params(card_id, card.instance_id))
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("play_ability", local_player,
				_instant_params(card_id, ps.hero_instance_id))
			if StackResolver.can_submit(state, act, db):
				result.append(ps.hero_instance_id)
	return result


# Remaining legal candidates for the current Chain Lightning wave, given
# targets already picked this cast (_chain_lightning_picked). can_submit
# (via StackResolver._can_play_chain_lightning) naturally excludes Untargetable
# candidates on the 1st wave only, and excludes already-picked candidates.
func _get_chain_lightning_targets(card_id: String) -> Array:
	var result: Array = []
	var atype := _action_type_for(card_id)
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var probe := PendingAction.make(atype, local_player,
				_chain_lightning_params(card.instance_id))
			if StackResolver.can_submit(state, probe, db):
				result.append(card.instance_id)
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var probe := PendingAction.make(atype, local_player,
				_chain_lightning_params(ps.hero_instance_id))
			if StackResolver.can_submit(state, probe, db):
				result.append(ps.hero_instance_id)
	return result


# Remaining legal allies for the current Lightning Storm click. Unlike Chain
# Lightning nothing drops out as picks accumulate — repeats are the point — so
# this is just "every ally the announce would accept as the next point".
func _get_divided_targets(card_id: String) -> Array:
	var result: Array = []
	var atype := _action_type_for(card_id)
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var probe := PendingAction.make(atype, local_player,
				_divided_params(card.instance_id, true))
			if StackResolver.can_submit(state, probe, db):
				result.append(card.instance_id)
	return result


func _get_instant_targets(card_id: String) -> Array:
	# Escape Artist's interrupt mode targets a LINK on the chain, not a hero or
	# ally — the pool comes from the resolver, filtered through can_submit like
	# every other targeting mode.
	if _is_interrupt_mode():
		var i_result: Array = []
		for cid in StackResolver.get_interrupt_candidates(state, db, local_player):
			var i_act := PendingAction.make("play_instant", local_player,
				_instant_params(card_id, cid))
			if StackResolver.can_submit(state, i_act, db):
				i_result.append(cid)
		return i_result
	if _is_multi_target(card_id):
		return _get_chain_lightning_targets(card_id)
	if _is_divided_damage(card_id):
		return _get_divided_targets(card_id)
	var kind := _destroy_kind(card_id)
	if kind in ["ability", "equipment"]:
		return _get_destroy_kind_targets(card_id, "play_instant", kind)
	var result: Array = []
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var act := PendingAction.make("play_instant", local_player,
				_instant_params(card_id, card.instance_id))
			if StackResolver.can_submit(state, act, db):
				result.append(card.instance_id)
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			var act := PendingAction.make("play_instant", local_player,
				_instant_params(card_id, ps.hero_instance_id))
			if StackResolver.can_submit(state, act, db):
				result.append(ps.hero_instance_id)
	return result


# destroy_target kind of a hand card's def ("" when not a destroy spell).
func _destroy_kind(card_id: String) -> String:
	if not db:
		return ""
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return StackResolver.destroy_target_kind(def) if def else ""


# Legal targets for a destroy_target:ability / :equipment spell (Burn Away /
# Shattering Blow) — candidates from the resolver, filtered through can_submit
# like every other targeting mode.
func _get_destroy_kind_targets(card_id: String, action_type: String, kind: String) -> Array:
	var result: Array = []
	for cid in StackResolver.get_destroy_kind_candidates(state, db, kind):
		var act := PendingAction.make(action_type, local_player,
			{"card_id": card_id, "target_id": cid})
		if StackResolver.can_submit(state, act, db):
			result.append(cid)
	return result


# Params for a play_instant/play_ability probe/submission — carries the modal
# mode index (707.1c) when the current targeting flow came from a mode choice,
# and the announced X (Aimed Shot) when it came from the X-select dialog.
func _instant_params(card_id: String, target_id: String) -> Dictionary:
	var params := {"card_id": card_id, "target_id": target_id}
	# Ravenous Bite: two sequential ally picks ride one submission. During
	# phase 1 (no first pick yet) the probe fills BOTH slots with the clicked
	# ally — legal, since the card may name the same ally twice — so
	# can_submit answers "is this a legal +ATK target?" on its own.
	if _is_atk_swing(card_id):
		if _targeting_first_target == "":
			params["target_id_2"] = target_id
		else:
			params["target_id"]   = _targeting_first_target
			params["target_id_2"] = target_id
	# Shock and Soothe: two sequential picks ride one submission. During phase 1
	# (no first pick yet) the probe pairs the clicked character with SOME other
	# legal character, so can_submit answers "is this a legal damage target?" on
	# its own — the two slots must be distinct ("another"), so the clicked one
	# can't stand in for both the way Ravenous Bite's can.
	if _is_instant_damage_and_heal(card_id):
		if _targeting_first_target == "":
			params["heal_target_id"] = _any_valid_instant_heal_target(card_id, target_id)
		else:
			params["target_id"]      = _targeting_first_target
			params["heal_target_id"] = target_id
	# Sever the Cord: the sacrificed ally rides the same submission as the
	# target. During phase 1 (no pick yet) the clicked ally fills BOTH slots, so
	# can_submit answers "is this a legal sacrifice?" on its own — naming the
	# sacrifice as the target is legal (targets are chosen before costs are
	# paid), it just fizzles, so only own allies pass the probe.
	if _is_play_cost_sacrifice(card_id):
		if _targeting_first_target == "":
			params["sacrifice_id"] = target_id
		else:
			params["sacrifice_id"] = _targeting_first_target
	# Skewer: the chosen source ally rides the same submission as the target.
	# During phase 1 (no pick yet) the clicked ally fills BOTH slots, so
	# can_submit answers "is this a legal source?" on its own — an ally may be
	# told to skewer itself, so only own allies pass the probe.
	if _is_ally_atk_damage(card_id):
		if _targeting_first_target == "":
			params["source_id"] = target_id
			# The source is CHOSEN, not targeted, so an Untargetable ally of our
			# own is a legal choice — probing it against itself would wrongly
			# reject it. Pair it with some legal victim instead, so can_submit
			# answers "is this a legal source?" alone.
			params["target_id"] = _any_valid_skewer_target(card_id, target_id)
		else:
			params["source_id"] = _targeting_first_target
	if _targeting_mode >= 0:
		params["mode"] = _targeting_mode
	if _targeting_x_value > 0:
		params["x_value"] = _targeting_x_value
	return params


# True for a hand card with a "destroy an ally in your party" additional play
# cost (Sever the Cord, `play_cost_sacrifice_ally`): the sacrifice is picked
# first, the spell's own target second — the two-phase `_targeting_first_target`
# flow Ravenous Bite and Gertha's two-pick power already use.
func _is_play_cost_sacrifice(card_id: String) -> bool:
	if not db or card_id == "":
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return StackResolver.play_cost_sacrifices_ally(def)


# Some legal victim to pair with `source` while probing Skewer's phase 1 ("" if
# none — the card then has no legal play at all). Builds the params by hand to
# avoid recursing through _instant_params.
func _any_valid_skewer_target(card_id: String, source: String) -> String:
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			var probe := PendingAction.make(_action_type_for(card_id), local_player, {
				"card_id": card_id, "source_id": source,
				"target_id": card.instance_id,
			})
			if StackResolver.can_submit(state, probe, db):
				return card.instance_id
	return ""


# True for Skewer (`ally_atk_damage:ally`): "Choose an ally in your party. It
# deals damage equal to its ATK to target ally." The chosen source is picked
# first, the damaged ally second — Sever the Cord's two-phase flow, except the
# first pick is a CHOICE (not a target, so Untargetable doesn't restrict it) and
# it costs nothing, so backing out is free right up to submission.
func _is_ally_atk_damage(card_id: String) -> bool:
	if not db or card_id == "":
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return StackResolver.is_ally_atk_damage_def(def)


# The damage type Skewer's chosen source deals — always MELEE, matching the
# packet built at resolution: per 408.3a a packet takes the source character's
# printed damage type only when it is created during combat conclusion, and this
# one is created outside combat by a modifier that names no type. Drives the
# phase-2 targeting cursor icon.
func _skewer_source_dmg_type(_source_id: String) -> String:
	return "melee"


# True for a two-target damage+heal spell played from hand (Shock and Soothe,
# `deal_damage_and_heal:3:nature:3`): damage target picked first, heal target
# second, and the two must differ. Same two-phase `_targeting_first_target`
# flow as the Grennan hero power version.
func _is_instant_damage_and_heal(card_id: String) -> bool:
	if not db or card_id == "":
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return StackResolver.is_damage_and_heal_def(def)


# Some legal heal target to pair with `dmg_target` while probing phase 1 ("" if
# none — the damage target then isn't offerable). Builds the params by hand to
# avoid recursing through _instant_params.
func _any_valid_instant_heal_target(card_id: String, dmg_target: String) -> String:
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		var candidates: Array = []
		if ps and ps.hero_instance_id != "":
			candidates.append(ps.hero_instance_id)
		for card in state.cards_in_zone(pid + "_ally_row"):
			candidates.append(card.instance_id)
		for cand in candidates:
			if cand == dmg_target:
				continue
			var probe := PendingAction.make(_action_type_for(card_id), local_player, {
				"card_id": card_id, "target_id": dmg_target, "heal_target_id": cand,
			})
			if StackResolver.can_submit(state, probe, db):
				return cand
	return ""


# True for a two-target ATK-swing spell (Ravenous Bite, `atk_swing:3:-3`):
# "+3 ATK" ally picked first, "-3 ATK" ally second. Unlike Chain Lightning /
# Multi-Shot both picks are mandatory and both respect Untargetable, so this
# uses the two-phase `_targeting_first_target` flow (deal_damage_and_heal's)
# rather than the multi-target list.
func _is_atk_swing(card_id: String) -> bool:
	if not db or card_id == "":
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return StackResolver.is_atk_swing_def(def)


# Largest X the player can announce for an X-cost hand card right now. Asked of
# get_play_cost one X at a time rather than derived arithmetically, so any
# cost aura it applies is honoured exactly — Elemental Focus' "(1) less, to a
# minimum of (1)" makes Lightning Storm's total `2 + X - 1`, and the player
# should be offered the extra point of damage that discount buys, not the X
# the printed cost would allow.
func _max_affordable_x(card_id: String) -> int:
	if not state or not db:
		return 0
	var avail := state.get_available_resources(local_player)
	var best := 0
	for x in range(1, avail + 1):
		if state.get_play_cost(card_id, db, x) <= avail:
			best = x
		else:
			break
	return best


func _card_cost_x(card_id: String) -> bool:
	if not db:
		return false
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	return def != null and def.cost_x


func _instant_needs_target(card_id: String) -> bool:
	if not db:
		return false
	var card := state.get_card(card_id)
	if not card:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return false
	if _is_multi_target(card_id):
		return true
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
			"deal_damage_to_target", "deal_damage_and_heal", "attach_deal_damage":
				var parts := entry.strip_edges().split(":")
				if parts.size() > 2: return parts[2].to_lower()
			"chain_lightning":
				var parts := entry.strip_edges().split(":")
				if parts.size() > 4: return parts[4].to_lower()
			"multi_shot":
				var parts := entry.strip_edges().split(":")
				if parts.size() > 2: return parts[2].to_lower()
			# Lightning Storm (divided_damage:X:TYPE:ally) — parts[1] is the
			# literal "X", the type is the third field.
			"divided_damage":
				var parts := entry.strip_edges().split(":")
				if parts.size() > 2: return parts[2].to_lower()
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
			return _preview_dmg(int(parts[1 + picked_count]), _card_dmg_type(card_id), true)
		# Multi-Shot deals the same amount to every target (recipe multi_shot:N:TYPE).
		if parts[0].strip_edges() == "multi_shot" and parts.size() > 1:
			return _preview_dmg(int(parts[1]), _card_dmg_type(card_id), true)
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
			"deal_damage_to_target", "attach_deal_damage", "deal_damage_and_heal":
				if parts.size() > 1:
					return _preview_dmg(int(parts[1]), _card_dmg_type(card_id), true)
			"chain_lightning":
				if parts.size() > 1:
					return _preview_dmg(int(parts[1]), _card_dmg_type(card_id), true)
			"multi_shot":
				if parts.size() > 1:
					return _preview_dmg(int(parts[1]), _card_dmg_type(card_id), true)
	return 0


# The targeting cursor should show what the effect will ACTUALLY deal, not the
# printed number: hero-sourced damage passes through the 717-style replacement
# effects (Chromatic Cloak, Shadowform / Aspect of the Hawk, World in Flames) as
# it enters the packet pipeline. Mirrors StackResolver.defer_packets — see
# StackResolver.preview_hero_damage_amount.
func _preview_dmg(amount: int, dmg_type: String, from_ability: bool) -> int:
	if amount <= 0 or dmg_type in ["", "heal", "destroy"]:
		return amount
	return StackResolver.preview_hero_damage_amount(state, db, local_player,
		amount, dmg_type, from_ability)


func _hero_power_dmg_amount(hero_id: String) -> int:
	if not db: return 0
	var hero := state.get_card(hero_id)
	if not hero: return 0
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def: return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["deal_damage_to_target", "deal_damage_and_heal"] and parts.size() > 1:
			# Hero POWERS are not abilities — Chromatic Cloak doesn't apply, but
			# the typed bonuses / fire doubling do.
			return _preview_dmg(int(parts[1]), _hero_power_dmg_type(hero_id), false)
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
	if _is_multi_target(card_id):
		return true
	return _instant_needs_target(card_id)


# "Chipper" Ironbane: "(X), Destroy [this] -> Destroy target ability or
# equipment with cost X." X isn't a free choice — a legal announce always has
# X == the target's printed cost, so it's DERIVED from the click rather than
# asked for in an X dialog. Returns 0 for every fixed-cost power (the resolver
# ignores x_value there).
func _ally_power_x_for(ally_id: String, target_id: String) -> int:
	if not db or not state:
		return 0
	var ally := state.get_card(ally_id)
	var ally_def := db.get_def(ally.card_def_id) as CardDef if ally else null
	var ap := StackResolver._ally_activated_power(ally_def) if ally_def else {}
	if not bool(ap.get("cost_x", false)):
		return 0
	var t := state.get_card(target_id)
	var t_def := db.get_def(t.card_def_id) as CardDef if t else null
	return StackResolver.printed_cost(t_def) if t_def else 0


func _get_ally_power_targets(ally_id: String) -> Array:
	var result: Array = []
	if not db or not state:
		return result
	var ally := state.get_card(ally_id)
	if not ally:
		return result
	var ally_def := db.get_def(ally.card_def_id) as CardDef
	var ally_ap := StackResolver._ally_activated_power(ally_def) if ally_def else {}
	var ally_ap_kind := (ally_ap.get("targets", "") as String)
	# Two-pick sacrifice powers (Gertha, The Old Crone → destroy target ally;
	# Besh'iah → destroy target ability). Phase 1 = the ally to SACRIFICE (our own
	# party, the source itself included); phase 2 = whatever the power's own
	# effect targets, which is why it delegates by target kind rather than
	# assuming allies. Checked before the kind branches below — Besh'iah's kind is
	# "ability", and answering that first would skip her sacrifice pick entirely.
	if StackResolver.power_sacrifice_is_separate(ally_ap):
		if _targeting_first_target == "":
			for card in state.cards_in_zone(local_player + "_ally_row"):
				result.append(card.instance_id)
			return result
		return _ally_power_effect_targets(ally_id, ally_ap_kind,
			{"sacrifice_id": _targeting_first_target})
	if ally_ap_kind in ["ability_or_equipment", "ability", "equipment"]:
		return _ally_power_effect_targets(ally_id, ally_ap_kind, {})
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


# Candidates for what an activated power's EFFECT targets, by target kind.
# `extra` carries any params already chosen (a two-pick power's sacrifice_id), so
# every candidate is validated by can_submit against the real, complete
# submission — the resolver stays the single authority on legality.
func _ally_power_effect_targets(ally_id: String, kind: String, extra: Dictionary) -> Array:
	var result: Array = []
	var candidates: Array = []
	if kind in ["ability_or_equipment", "ability", "equipment"]:
		# Kavai the Wanderer targets in-play ability / equipment cards of either
		# player; Lafiel / Moira / Besh'iah narrow the same picker to one kind.
		for k in (["ability", "equipment"] if kind == "ability_or_equipment" else [kind]):
			candidates.append_array(StackResolver.get_destroy_kind_candidates(state, db, k))
	else:
		for pid in state.players:
			for card in state.cards_in_zone(pid + "_ally_row"):
				candidates.append(card.instance_id)
			if kind == "hero_or_ally":
				var ps := state.players.get(pid) as PlayerState
				if ps and ps.hero_instance_id != "":
					candidates.append(ps.hero_instance_id)
	for cid: String in candidates:
		var params := {"card_id": ally_id, "target_id": cid,
			"x_value": _ally_power_x_for(ally_id, cid)}
		params.merge(extra)
		if StackResolver.can_submit(state, PendingAction.make("use_ally_power",
				local_player, params), db):
			result.append(cid)
	return result


# Whether an activated power picks its sacrifice separately from its own target
# (Gertha, Besh'iah) — the two-phase targeting flow below.
func _is_ally_sacrifice_destroy_power(ally_id: String) -> bool:
	if not db or not state:
		return false
	var ally := state.get_card(ally_id)
	if not ally:
		return false
	var def := db.get_def(ally.card_def_id) as CardDef
	if not def:
		return false
	return StackResolver.power_sacrifice_is_separate(
		StackResolver._ally_activated_power(def))


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
	# X-cost HAND card (Aimed Shot): re-enter the normal play targeting flow —
	# the X rides on the submission via _instant_params.
	var src_card := state.get_card(_targeting_source)
	var src_zone := state.zones.get(src_card.zone_id) as Zone if src_card else null
	if src_zone and src_zone.zone_type == "hand":
		var x_dmg_type := _card_dmg_type(_targeting_source)
		# Lightning Storm divides X over several packets, so the cursor counts
		# the points still to assign (raw) rather than previewing a single
		# packet through the replacement effects.
		var x_cursor := x_value if _is_divided_damage(_targeting_source) \
			else _preview_dmg(x_value, x_dmg_type, true)
		start_targeting(_targeting_source, _action_type_for(_targeting_source),
			x_dmg_type, x_cursor)
		return
	var dmg_type := "heal" if _is_heal_x_power(_targeting_source) else "shadow"
	start_targeting(_targeting_source, "activate_power_x", dmg_type,
		_preview_dmg(x_value, dmg_type, false))


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
	if _is_ally_sacrifice_destroy_power(_targeting_source):
		var sd_legal := _get_ally_power_targets(_targeting_source)
		if _targeting_first_target == "":
			# Phase 1: instance_id is the ally to SACRIFICE (one of our own party,
			# the source herself included). Esc cancels; a non-candidate no-ops.
			if instance_id in sd_legal:
				_targeting_first_target = instance_id
				targeting_started.emit(_targeting_source, "destroy", 0)
				refresh_highlights()
			return
		# Phase 2: instance_id is what the EFFECT destroys — an ally either party
		# for Gertha, an in-play ability for Besh'iah.
		if instance_id == _targeting_first_target:
			# Clicked the sacrifice again — step back to the sacrifice pick.
			_targeting_first_target = ""
			targeting_started.emit(_targeting_source, "sacrifice", 0)
			refresh_highlights()
			return
		if instance_id not in sd_legal:
			return
		var sd_action := PendingAction.make("use_ally_power", local_player, {
			"card_id": _targeting_source,
			"sacrifice_id": _targeting_first_target,
			"target_id": instance_id,
		})
		_targeting_source       = ""
		_targeting_first_target = ""
		targeting_cancelled.emit()
		var sd_events := StackResolver.submit_action(state, sd_action, db)
		if sd_events.is_empty():
			return
		EventBus.emit_events(sd_events)
		return
	var legal := _get_ally_power_targets(_targeting_source)
	if instance_id not in legal:
		return
	var action := PendingAction.make("use_ally_power", local_player,
		{"card_id": _targeting_source, "target_id": instance_id,
			"x_value": _ally_power_x_for(_targeting_source, instance_id)})
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
