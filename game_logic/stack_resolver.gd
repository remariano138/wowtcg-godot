class_name StackResolver
extends RefCounted

# Priority and chain (interrupt stack) management — rule 410.
#
# Entry points (called by both Human input and AI — same API for both):
#   submit_action(state, action, db) — propose an action; pushes to chain if legal
#   pass_priority(state, db)         — pass; resolves top of chain when all pass
#
# Architecture invariants (same as GameLogic primitives):
#   - Never touches Godot nodes or the event bus
#   - Returns Array[GameEvent]; caller emits
#   - All state mutations go through GameLogic primitives where possible
#
# Rule 410 summary implemented here:
#   - Proposer KEEPS priority after adding to chain (410.1).
#   - All players pass in succession → topmost link resolves → turn player
#     gets priority in a new window (410.4a).
#   - Chain empty + all pass → window closes, phase advances (410.4b).
#   - PPP (pre-priority processing, 410.5-410.6) is stubbed — will be
#     filled in when we implement fatal-damage destruction, uniqueness
#     checks, etc.


# ── Entry points ───────────────────────────────────────────────────────────────

static func submit_action(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	if not can_submit(state, action, db):
		return []

	var events: Array[GameEvent] = []

	# Rule 409.1 / 412.1a: card moves from hand to chain on submission.
	# Resource costs are paid at submission time (before chain), not at resolution.
	match action.action_type:
		"play_ally", "play_instant", "play_ability", "play_equipment":
			var card_id: String = action.params.get("card_id", "")
			if card_id != "":
				events.append_array(GameLogic.move_card(state, card_id, "chain"))
				# Nature's Swiftness: "you pay (5) less to play your next card this
				# turn." The discount is read by _pay_cost's get_play_cost below,
				# then consumed here, because the play cost is paid on chain entry
				# (412.2). Stashing the spent amount on the action lets retract_last
				# put it back (and recompute the refund at the discounted cost); a
				# card that RESOLVES — or fizzles — keeps it spent: it was played.
				var ncd_ps := state.players.get(action.source_player) as PlayerState
				var ncd_spent: int = ncd_ps.next_card_cost_mod if ncd_ps else 0
				events.append_array(_pay_cost(state, card_id, action.source_player, db,
					int(action.params.get("x_value", 0))))
				if ncd_spent != 0 and ncd_ps:
					ncd_ps.next_card_cost_mod = 0
					action.params["_next_card_cost_mod"] = ncd_spent
					events.append(GameEvent.next_card_discount_spent(
						action.source_player, card_id, ncd_spent))
				# Sever the Cord: "As an additional cost to play [this], destroy an
				# ally in your party." Paid HERE, on chain entry (412.2) — not at
				# resolution like the activated-power sacrifice_ally cost. The
				# opponent may still answer the link (bounce or kill the target),
				# and the sacrifice has been spent for nothing; that asymmetry is
				# the card. Because a destroyed ally can't be un-destroyed, the
				# announcement is marked non-retractable (see can_retract).
				var sac_def := db.get_def(state.get_card(card_id).card_def_id) as CardDef if db else null
				if sac_def and play_cost_sacrifices_ally(sac_def):
					var sac_id: String = action.params.get("sacrifice_id", "")
					if sac_id != "" and state.is_in_play(sac_id):
						events.append_array(
							_destroy_card_trigger(state, sac_id, card_id, db))
					action.params["_cost_paid_irreversibly"] = true
				# Stat tracking: a card was played from hand (excludes resources,
				# which are a separate branch below). See StatTracker.
				events.append(GameEvent.card_played(action.source_player, card_id))
		"place_resource":
			var card_id: String = action.params.get("card_id", "")
			if card_id != "":
				events.append_array(GameLogic.move_card(state, card_id, "chain"))
			var ps := state.players.get(action.source_player) as PlayerState
			if ps:
				ps.resource_placed_this_turn = true
		"use_quest":
			# Pay the quest's resource cost from the player's resource row.
			# The quest itself does NOT exhaust — it flips face-down on resolution.
			var quest_id: String = action.params.get("quest_id", "")
			if quest_id != "" and db:
				var q_card := state.get_card(quest_id)
				if q_card:
					var def := db.get_def(q_card.card_def_id) as CardDef
					if def:
						events.append_array(_pay_resources(state, action.source_player, max(def.cost, 0) as int))
						# Rule 412.2: the "exhaust N allies" extra cost (The Love
						# Potion) is paid on chain entry too, so the same allies
						# can't pay for two announcements at once. Refunded by
						# retract_last if the completion is taken back.
						if get_quest_ally_exhaust_requirement(def) > 0:
							for aid in action.params.get("ally_ids", []):
								events.append_array(GameLogic.exhaust_card(state, str(aid)))
		"use_ally_power":
			# Pay the ally power's resource cost at submission time, same as play_ally.
			var ap_card_id: String = action.params.get("card_id", "")
			if ap_card_id != "" and db:
				var ap_card := state.get_card(ap_card_id)
				var ap_def  := db.get_def(ap_card.card_def_id) as CardDef if ap_card else null
				var ap_data := _ally_activated_power(ap_def) if ap_def else {}
				var ap_cost := power_resource_cost(ap_data,
					int(action.params.get("x_value", 0)))
				if ap_cost > 0:
					events.append_array(_pay_resources(state, action.source_player, ap_cost))
				# Rule 412.2: the [Activate] tap symbol, the once-per-turn mark and
				# the "exhaust your hero" extra cost are paid HERE, on chain entry —
				# not at resolution. Deferring them left the source and the hero
				# READY while the power sat on the chain, so a second copy of the
				# same power (or Rod of the Ogre Magi + The Hammer of Grace off one
				# hero) validated and both resolved off a single exhaust.
				events.append_array(_pay_activate_costs(state, ap_card_id,
					action.source_player, ap_data))
		"activate_power":
			# Pay the hero power's resource cost; mark power as used.
			var hero_id: String = action.params.get("hero_id", "")
			if hero_id != "" and db:
				var h_card := state.get_card(hero_id)
				if h_card:
					var def := db.get_def(h_card.card_def_id) as CardDef
					if def and def.cost > 0:
						events.append_array(_pay_resources(state, action.source_player, def.cost))
					elif def and _power_effect_is(def, "heal_x_from_target"):
						var x_val: int = action.params.get("x_value", 0)
						if x_val > 0:
							events.append_array(_pay_resources(state, action.source_player, x_val))
					elif def and _power_effect_is(def, "radak_pet_sacrifice"):
						# Pay X resources and destroy the chosen Pet as costs.
						var pet_id: String = action.params.get("pet_id", "")
						var x_val: int = action.params.get("x_value", 0)
						if x_val > 0:
							events.append_array(_pay_resources(state, action.source_player, x_val))
						if pet_id != "" and state.is_in_play(pet_id):
							events.append_array(_destroy_card_trigger(state, pet_id, hero_id, db))
			var ps := state.players.get(action.source_player) as PlayerState
			if ps:
				ps.has_used_hero_power = true
			events.append(GameEvent.hero_power_used(action.source_player, hero_id))
		"choose_enter_play_target":
			# Rule 501.1 / 410: the enter-play trigger's target is chosen AS it goes
			# on the chain; a real priority window then opens so the opponent can
			# respond (e.g. sacrifice the targeted ally to its own power before Ghank
			# destroys it). Capture the effect onto the chain link and CLEAR the
			# pending marker NOW — leaving it set would make can_submit's guard
			# (see below) block every response, collapsing the window (the bug this
			# fixes; identical in spirit to the old Searing Totem no-window issue).
			# _resolve_choose_enter_play_target reads the effect from here, not state.
			action.params["_effect_dict"] = state.pending_enter_play_effect.duplicate()
			state.pending_enter_play_effect = {}

	state.pending_actions.push_back(action)
	state.consecutive_passes = 0
	# Rule 410.1: proposer keeps priority (NOT flipped to opponent).

	var proposed_payload := {
		"action_type": action.action_type,
		"player":      action.source_player,
		"card_id":     action.params.get("card_id", ""),
		"face_up":     action.params.get("face_up", true),
		"attacker_id": action.params.get("attacker_id", ""),
		"defender_id": action.params.get("defender_id", ""),
	}
	events.append(GameEvent.make("action_proposed", proposed_payload))
	return events


static func pass_priority(state: GameState, db = null) -> Array[GameEvent]:
	# A pending discard-or-give-control choice (Infernal) must be resolved via
	# choose_control_discard / decline_control_discard before priority can move.
	if state.pending_control_discard_player != "":
		return []
	# A pending reveal-and-pick choice is mandatory — resolve it via
	# choose_reveal_pick() before priority can move.
	if state.pending_reveal_pick_player != "":
		return []
	# A pending strike decision (602.1 / 602.3) must be resolved via
	# choose_strike() before priority can move.
	if state.pending_strike_player != "":
		return []
	# A pending ready-on-attack decision (Windseer Tarus) must be resolved via
	# choose_ready_on_attack() before priority can move.
	if state.pending_ready_player != "":
		return []
	# A pending ready-on-strike decision (Windfury Weapon) must be resolved via
	# choose_ready_on_strike() before priority can move.
	if state.pending_strike_ready_player != "":
		return []
	# A pending attack-exhaust decision (Chops / Voss Treebender) must be resolved
	# via choose_attack_exhaust() before priority can move.
	if state.pending_attack_exhaust_player != "":
		return []
	# A pending Green Whelp Armor bounce decision must be resolved via
	# choose_whelp_bounce() before priority can move.
	if state.pending_whelp_bounce_player != "":
		return []
	# A pending Form pay-return decision must be resolved via
	# choose_form_return() before priority can move.
	if state.pending_form_return_player != "":
		return []
	# A pending Totem start-of-turn target choice (Searing Totem) must be resolved
	# via choose_totem_target() before priority can move.
	if state.pending_totem_target_player != "":
		return []
	# A pending death-triggered target choice (Boneshanks) must be resolved via
	# choose_death_target() before priority can move.
	if state.pending_death_target_player != "":
		return []
	# A pending Operation Recombobulation fetch must be resolved (or declined) via
	# choose_recombobulation() before priority can move.
	if state.pending_recomb_player != "":
		return []
	# A pending armor-prevention decision (717.2c) must be resolved via
	# choose_prevention() before priority can move.
	if state.pending_prevention_player != "":
		return []
	# A pending quest reward choice (Hidden Enemies etc.) or one of its
	# sub-choices must be resolved via the choose_quest_* calls first.
	if _quest_choice_pending(state):
		return []
	state.consecutive_passes += 1
	var events: Array[GameEvent] = []

	# All players passed in succession.
	if state.consecutive_passes >= 2:
		if state.pending_actions.is_empty():
			# Safety: can't close the window while an enters-play effect needs a target.
			if not state.pending_enter_play_effect.is_empty():
				state.consecutive_passes = 0
				state.priority_player    = _pending_effect_controller(state)
				return []   # stall — scene must handle enter_play_target_required
			# Rule 602.1/602.3: combat window transitions take priority over phase advance.
			state.consecutive_passes = 0
			state.priority_player    = state.turn_player
			if state.combat_attack_window:
				state.combat_attack_window = false
				events.append_array(_close_attack_window(state, db))
				return events
			if state.combat_defend_window:
				state.combat_defend_window = false
				# Rule 717.2c: as the combat damage packets would land, each hero's
				# controller may exhaust DEF armor first. The conclusion runs from
				# choose_prevention once every armor decision is made.
				var prevention := _combat_prevention_offers(state, db)
				if not prevention.is_empty():
					events.append_array(_open_prevention(state, prevention, "combat"))
					return events
				events.append_array(_do_combat_conclusion(state, db))
				return events
			# Rule 410.4b: chain empty → window closes, phase advances.
			_clear_damage_prevention(state)   # window over — unspent block expires
			events.append(GameEvent.make("priority_window_closed", {
				"phase": state.phase,
			}))
			return events

		# Rule 410.4a: topmost link resolves; turn player gets priority.
		# Damage inside the resolution goes through the packet pipeline
		# (defer_packets) — a preventable hero packet opens the prevention
		# point mid-resolution and the packets land from choose_prevention.
		var top: PendingAction = state.pending_actions.pop_back()
		state.consecutive_passes = 0
		# PPP stub: in a future phase, run pre-priority checks (410.5) here
		# before the turn player gets priority post-resolution.
		events.append_array(_resolve(state, top, db))
		state.priority_player = state.turn_player
		# A pending enters-play target choice is a MANDATORY choice belonging to
		# the effect's controller — hand priority there so the choice can be
		# submitted (can_submit blocks everything else anyway). Matters when the
		# effect's controller is NOT the turn player (e.g. a combat instant like
		# Quick Strike played by the defending player during a combat window).
		if not state.pending_enter_play_effect.is_empty():
			state.priority_player = _pending_effect_controller(state)
		return events

	# Not yet all passed — pass priority clockwise (2-player: flip).
	state.priority_player = _other_player(state, state.priority_player)
	events.append(GameEvent.make("priority_passed", {
		"player": state.priority_player,
	}))
	return events


# ── Validation ─────────────────────────────────────────────────────────────────

static func can_submit(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Must be the acting player's priority.
	if action.source_player != state.priority_player:
		return false

	# Pending enters-play target choice blocks everything except resolving it.
	if not state.pending_enter_play_effect.is_empty() \
			and action.action_type != "choose_enter_play_target":
		return false

	# Pet uniqueness violation blocks everything until resolved via choose_pet_sacrifice().
	if state.pending_pet_sacrifice_player != "":
		return false

	# Equipment slot uniqueness violation blocks everything until resolved via
	# choose_equipment_sacrifice().
	if state.pending_equip_sacrifice_player != "":
		return false

	# Name-based (Unique tag) uniqueness violation blocks everything until resolved
	# via choose_unique_sacrifice().
	if state.pending_unique_sacrifice_player != "":
		return false

	# Form (1) tag-count uniqueness violation blocks everything until resolved via
	# choose_form_sacrifice().
	if state.pending_form_sacrifice_player != "":
		return false

	# Form pay-return choice blocks everything until resolved via choose_form_return().
	if state.pending_form_return_player != "":
		return false

	# Infernal-style discard-or-give-control choice blocks everything until
	# resolved via choose_control_discard() / decline_control_discard().
	if state.pending_control_discard_player != "":
		return false

	# Reveal-and-pick quest reward blocks everything until resolved via
	# choose_reveal_pick().
	if state.pending_reveal_pick_player != "":
		return false

	# Strike point (602.1 / 602.3) blocks everything until resolved via choose_strike().
	if state.pending_strike_player != "":
		return false

	# Ready-on-attack point (Windseer Tarus) blocks everything until resolved via
	# choose_ready_on_attack().
	if state.pending_ready_player != "":
		return false

	# Ready-on-strike point (Windfury Weapon) blocks everything until resolved via
	# choose_ready_on_strike().
	if state.pending_strike_ready_player != "":
		return false

	# Attack-exhaust point (Chops / Voss Treebender) blocks everything until
	# resolved via choose_attack_exhaust().
	if state.pending_attack_exhaust_player != "":
		return false

	# Green Whelp Armor bounce point blocks everything until resolved via
	# choose_whelp_bounce().
	if state.pending_whelp_bounce_player != "":
		return false

	# Ongoing Totem start-of-turn target choice blocks everything until resolved
	# via choose_totem_target().
	if state.pending_totem_target_player != "":
		return false

	# Death-triggered target choice (Boneshanks) blocks everything until resolved
	# via choose_death_target().
	if state.pending_death_target_player != "":
		return false

	# Operation Recombobulation's optional graveyard fetch blocks everything until
	# resolved (or declined) via choose_recombobulation().
	if state.pending_recomb_player != "":
		return false

	# Armor prevention point (717.2c) blocks everything until resolved via
	# choose_prevention().
	if state.pending_prevention_player != "":
		return false

	# Quest reward choice (Hidden Enemies etc.) and its sub-choices block
	# everything until resolved via the choose_quest_* calls.
	if _quest_choice_pending(state):
		return false

	match action.action_type:
		"play_ally":
			return _can_play_non_instant(state, action, db)
		"play_equipment":
			return _can_play_equipment(state, action, db)
		"play_ability":
			return _can_play_ability(state, action, db)
		"play_instant":
			return _can_play_instant(state, action, db)
		"place_resource":
			return _can_place_resource(state, action, db)
		"propose_combat":
			return _can_propose_combat(state, action, db)
		"use_quest":
			return _can_use_quest(state, action, db)
		"activate_power":
			return _can_activate_power(state, action, db)
		"use_ally_power":
			return _can_use_ally_power(state, action, db)
		"choose_enter_play_target":
			return _can_choose_enter_play_target(state, action, db)

	return false   # unknown action type


static func _can_play_non_instant(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Card must actually be an Ally — Abilities and Instants have their own action types.
	var def: CardDef = null
	if db:
		def = db.get_def(card.card_def_id) as CardDef
		if def and def.card_type != "Ally":
			return false
	# Instant Ally (e.g. Tristan Rapidstrike): the Instant tag overrides non-instant
	# timing (rule 409.1) — playable any time its controller has priority, including
	# combat windows, the opponent's turn, and in response to a non-empty chain.
	# It still resolves as a normal ally (enters the ally_row with summoning sickness,
	# which does NOT prevent protecting — 601.2a restricts attackers only).
	if def == null or not def.is_instant:
		# Rule 502.1 / 1199: non-instants require the NON-COMBAT action phase — illegal
		# during attack or defend windows even though phase == "action" and chain is empty.
		if state.phase != "action":
			return false
		if state.combat_attack_window or state.combat_defend_window:
			return false
		if state.turn_player != action.source_player:
			return false
		if not state.pending_actions.is_empty():
			return false
	# Rule 412.2: player must be able to afford the cost.
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(action.source_player):
		return false
	return true


# Equipment (armor/item/weapon) — same action-phase timing as an ally, but the
# card type must be Equipment and it enters the hero row (rule 304.1 / 303.1).
static func _can_play_equipment(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Rule 502.1 / 1199: only the non-combat action phase, chain empty, your turn.
	if state.phase != "action":
		return false
	if state.combat_attack_window or state.combat_defend_window:
		return false
	if state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.card_type != "Equipment":
			return false
	# Rule 412.2: player must be able to afford the cost.
	if db and state.get_play_cost(card_id, db) > state.get_available_resources(action.source_player):
		return false
	return true


static func _can_play_instant(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Instants can be played any time you have priority (409.1 / 410.2).
	if db and not _can_afford_play(state, action, card_id, db):
		return false
	# Validate target for targeted effects.
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		# Modal (707.1c): the chosen mode must be announced with the play.
		if def and is_modal_def(def) and selected_mode(def, action) == "":
			return false
		# Sever the Cord: the sacrificed ally is announced with the play (412.2).
		if def and not _play_cost_sacrifice_ok(state, def, action):
			return false
		if def and is_modal_def(def):
			# Mode-aware targeting: ONLY the chosen mode's requirement applies,
			# so Escape Artist's interrupt half announces a chain link while its
			# remove-attackers half announces nothing at all.
			return _modal_target_ok(state, def, action, card_id, db)
		if def and _has_effect_flag_prefix(def, "multi_shot"):
			if not _can_play_multi_shot(state, action, db): return false
		elif def and is_divided_damage_def(def):
			# Lightning Storm: X ally picks (repeats allowed) announced as target_ids.
			if not _can_play_divided_damage(state, action, db): return false
		elif def and is_atk_swing_def(def):
			# Ravenous Bite: two mandatory ally targets announced with the play.
			if not _can_play_atk_swing(state, action, db): return false
		elif def and is_damage_and_heal_def(def):
			# Shock and Soothe: two mandatory, DISTINCT hero-or-ally targets.
			if not _can_play_damage_and_heal(state, action, db): return false
		elif def and _instant_needs_target(def):
			var target_id: String = action.params.get("target_id", "")
			if not _is_legal_target(state, target_id, db):
				return false
			if _instant_targets_protecting_ally_only(def):
				if not _is_protecting_ally(state, target_id, db):
					return false
			elif _instant_targets_ally_only(def):
				var t_zone := state.zones.get(state.get_card(target_id).zone_id) as Zone
				if not t_zone or t_zone.zone_type != "ally_row":
					return false
				# Fall Back: "from your party" — friendly allies only.
				if _instant_targets_friendly_ally_only(def) \
						and state.get_card(target_id).controller != action.source_player:
					return false
				# Coup de Grâce: target ally must be exhausted.
				if _destroy_requires_exhausted(def) \
						and not state.get_card(target_id).is_exhausted:
					return false
				# Trophy Kill / Prey on the Weak: printed-cost band.
				if not _destroy_cost_band_ok(state, def, target_id, db):
					return false
			elif _attach_targets_hero_only(def):
				if not _is_hero(state, target_id):
					return false
			elif _attach_targets_weapon_only(def):
				if not _is_melee_weapon(state, target_id, db) \
						or state.get_card(target_id).controller != action.source_player:
					return false
			elif destroy_target_kind(def) == "ability":
				# Purge: friendly-attached abilities are excluded (see
				# _is_destroyable_ability).
				if not _is_destroyable_ability(state, def, target_id,
						action.source_player, db):
					return false
			elif destroy_target_kind(def) == "equipment":
				if not _is_in_play_equipment(state, target_id, db):
					return false
	return true


# Non-instant ability (e.g. Vanquish): action-phase timing like an ally, effect+graveyard
# resolution like an instant.
static func _can_play_ability(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card: return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand": return false
	if card.controller != action.source_player: return false
	# Instant Ability (e.g. Searing Totem): the Instant tag overrides non-instant
	# timing (rule 409.1) — playable any time its controller has priority. A
	# non-instant Ability keeps action-phase / turn-player / empty-chain timing.
	var play_def := db.get_def(card.card_def_id) as CardDef if db else null
	if play_def == null or not play_def.is_instant:
		if state.phase != "action": return false
		if state.combat_attack_window or state.combat_defend_window: return false
		if state.turn_player != action.source_player: return false
		if not state.pending_actions.is_empty(): return false
	if db and not _can_afford_play(state, action, card_id, db):
		return false
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		# Modal (707.1c): the chosen mode must be announced with the play.
		if def and is_modal_def(def) and selected_mode(def, action) == "":
			return false
		# Sever the Cord: the sacrificed ally is announced with the play (412.2).
		# (Here for the sorcery-speed twin of the instant path above; a future
		# non-instant card with the same cost gets it for free.)
		if def and not _play_cost_sacrifice_ok(state, def, action):
			return false
		# Graveyard-reanimate ability (Ancestral Spirit): the target is an ally
		# CARD in the caster's graveyard, announced with the play — cost gated
		# against the caster's resources (dynamic max_cost). Validate it's still
		# a legal candidate (or, for the highlight probe, that any exists).
		if def and _ability_reanimates_from_graveyard(def):
			var rz_req := get_graveyard_search_requirement(def)
			var rz_cands := get_graveyard_search_candidates(
					state, action.source_player, rz_req, db)
			if rz_cands.is_empty():
				return false
			if action.params.get("_skip_target_check", false):
				return true
			return action.params.get("target_id", "") in rz_cands
		# Graveyard-exile ability (Cannibalize): "Remove any number of ally
		# cards in graveyards from the game." ANY NUMBER includes zero, so
		# unlike the reanimate branch an empty candidate pool does NOT make the
		# card unplayable — it just removes nothing and heals nothing. The
		# chosen cards ride the play as `target_ids` (multi-select) and are
		# validated against the current candidate pool.
		if def and _ability_removes_from_graveyard(def):
			if action.params.get("_skip_target_check", false):
				return true
			var rr_req := get_graveyard_search_requirement(def)
			var rr_cands := get_graveyard_search_candidates(
					state, action.source_player, rr_req, db)
			var rr_picks: Array = action.params.get("target_ids", [])
			if rr_picks.size() < int(rr_req.get("min_count", 0)) \
					or rr_picks.size() > int(rr_req.get("max_count", 0)):
				return false
			var rr_seen := {}
			for rr_id in rr_picks:
				if rr_seen.has(rr_id) or not (rr_id in rr_cands):
					return false
				rr_seen[rr_id] = true
			return true
		# Mode-aware targeting (see the instant path / _modal_target_ok).
		if def and is_modal_def(def):
			return _modal_target_ok(state, def, action, card_id, db)
		if def and _has_effect_flag_prefix(def, "chain_lightning"):
			if not _can_play_chain_lightning(state, action, db): return false
		elif def and is_divided_damage_def(def):
			# Lightning Storm: X ally picks (repeats allowed) announced as target_ids.
			if not _can_play_divided_damage(state, action, db): return false
		elif def and is_atk_swing_def(def):
			# Ravenous Bite: two mandatory ally targets announced with the play.
			if not _can_play_atk_swing(state, action, db): return false
		elif def and is_damage_and_heal_def(def):
			# Shock and Soothe: two mandatory, DISTINCT hero-or-ally targets.
			if not _can_play_damage_and_heal(state, action, db): return false
		elif def and _instant_needs_target(def):
			var target_id: String = action.params.get("target_id", "")
			if not _is_legal_target(state, target_id, db): return false
			if _instant_targets_protecting_ally_only(def):
				if not _is_protecting_ally(state, target_id, db): return false
			elif _instant_targets_ally_only(def):
				var t_card := state.get_card(target_id)
				if t_card:
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "ally_row": return false
					# Fall Back: "from your party" — friendly allies only.
					if _instant_targets_friendly_ally_only(def) \
							and t_card.controller != action.source_player:
						return false
					# Coup de Grâce: target ally must be exhausted.
					if _destroy_requires_exhausted(def) and not t_card.is_exhausted:
						return false
					# Trophy Kill / Prey on the Weak: printed-cost band.
					if not _destroy_cost_band_ok(state, def, target_id, db):
						return false
			elif _attach_targets_hero_only(def):
				if not _is_hero(state, target_id): return false
			elif _attach_targets_weapon_only(def):
				if not _is_melee_weapon(state, target_id, db) \
						or state.get_card(target_id).controller != action.source_player:
					return false
			elif destroy_target_kind(def) == "ability":
				if not _is_destroyable_ability(state, def, target_id,
						action.source_player, db): return false
			elif destroy_target_kind(def) == "equipment":
				if not _is_in_play_equipment(state, target_id, db): return false
	return true


# Timing-only check (no target required). Used by the renderer to decide whether to
# highlight the card green in hand before the player has chosen a target.
static func can_play_ability_no_target_check(state: GameState,
		card_id: String, player_id: String, db) -> bool:
	var card := state.get_card(card_id)
	if not card: return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand": return false
	if card.controller != player_id: return false
	# Instant Ability: priority-only timing (mirrors _can_play_ability above).
	var play_def := db.get_def(card.card_def_id) as CardDef if db else null
	if play_def == null or not play_def.is_instant:
		if state.phase != "action": return false
		if state.combat_attack_window or state.combat_defend_window: return false
		if state.turn_player != player_id: return false
		if not state.pending_actions.is_empty(): return false
	else:
		if state.priority_player != player_id: return false
	# X-cost cards probe at the minimum announceable X (1).
	var probe_x := 1 if play_def and play_def.cost_x else 0
	if db and state.get_play_cost(card_id, db, probe_x) > state.get_available_resources(player_id):
		return false
	if db and play_def and not _targeted_play_has_legal_target(state, play_def, db, player_id):
		return false
	return true


# Timing-only check (no target required) for targeted instants (Quick Strike).
# Used by the renderer to highlight the card green in hand before the player
# has chosen a target. Instant timing: any priority window, no phase/turn gate.
static func can_play_instant_no_target_check(state: GameState,
		card_id: String, player_id: String, db) -> bool:
	if state.priority_player != player_id: return false
	if not state.pending_enter_play_effect.is_empty(): return false
	if state.pending_pet_sacrifice_player != "": return false
	if state.pending_equip_sacrifice_player != "": return false
	if state.pending_unique_sacrifice_player != "": return false
	if state.pending_form_sacrifice_player != "": return false
	if state.pending_form_return_player != "": return false
	var card := state.get_card(card_id)
	if not card: return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand": return false
	if card.controller != player_id: return false
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		# X-cost cards probe at the minimum announceable X (1).
		var probe_x := 1 if def and def.cost_x else 0
		if state.get_play_cost(card_id, db, probe_x) > state.get_available_resources(player_id):
			return false
		if def and not _targeted_play_has_legal_target(state, def, db, player_id):
			return false
	return true


# Cost affordability for a play_* submission (rule 412.2). X-cost cards
# (CardDef.cost_x — Aimed Shot "1+X") must announce "x_value" >= 1 with the
# play; the total cost is cost_base + X.
static func _can_afford_play(state: GameState, action: PendingAction,
		card_id: String, db) -> bool:
	var card := state.get_card(card_id)
	var def := db.get_def(card.card_def_id) as CardDef if card else null
	var x := int(action.params.get("x_value", 0))
	if def and def.cost_x and x < 1:
		return false
	return state.get_play_cost(card_id, db, x) \
			<= state.get_available_resources(action.source_player)


# A card that targets can't be announced without at least one legal target
# (rule 706.2) — so the highlight probes must go dark when none exists.
# First to Fall (`destroy_target:protecting_ally`): only the current
# combat_protector qualifies, and only if it's an ally. Ally-only targets
# (Exhaustion, Vanquish): some ally must be in play and targetable.
# Hero-or-ally targets always have a target (heroes are always in play).
static func _targeted_play_has_legal_target(state: GameState, def: CardDef, db,
		player_id := "") -> bool:
	# Ancestral Spirit: needs at least one affordable ally card in the caster's
	# graveyard (dynamic cost cap). player_id is the caster when known.
	if _ability_reanimates_from_graveyard(def):
		var scan_pid := player_id if player_id != "" else state.turn_player
		var req := get_graveyard_search_requirement(def)
		return not get_graveyard_search_candidates(state, scan_pid, req, db).is_empty()
	# Sever the Cord: an additional cost that can't be paid makes the card
	# unplayable (412.2) — it goes dark with no ally in the caster's party.
	if play_cost_sacrifices_ally(def):
		var sac_pid := player_id if player_id != "" else state.turn_player
		if get_play_sacrifice_candidates(state, sac_pid).is_empty():
			return false
	# Modal (707.1c): the card is playable while ANY of its modes can be legally
	# chosen. A mode that announces no target always can (Escape Artist's
	# remove-attackers half), so the card never goes dark for want of a chain
	# link to interrupt — playing it into an empty chain is legal and simply
	# does nothing, exactly as the printed text allows.
	if is_modal_def(def) and has_targetless_mode(def):
		return true
	if not _instant_needs_target(def):
		return true
	# Shock and Soothe: needs TWO distinct legal hero-or-ally targets.
	if is_damage_and_heal_def(def):
		return _has_two_legal_hero_or_ally_targets(state, db)
	if _instant_targets_protecting_ally_only(def):
		return _is_protecting_ally(state, state.combat_protector, db) \
				and _is_legal_target(state, state.combat_protector, db)
	if _instant_targets_ally_only(def):
		# Fall Back (friendly-only) with a known caster: only their party counts.
		var scan := ["p1", "p2"]
		if _instant_targets_friendly_ally_only(def) and player_id != "":
			scan = [player_id]
		var need_exhausted := _destroy_requires_exhausted(def)
		for pid in scan:
			var zone := state.zones.get(pid + "_ally_row") as Zone
			if zone:
				for cid in zone.card_ids:
					if not _is_legal_target(state, cid, db):
						continue
					# Coup de Grâce: only exhausted allies qualify.
					if need_exhausted and not state.get_card(cid).is_exhausted:
						continue
					# Trophy Kill / Prey on the Weak go dark when no ally in play
					# falls inside the printed-cost band.
					if not _destroy_cost_band_ok(state, def, cid, db):
						continue
					return true
		return false
	# Windfury Weapon: at least one Melee weapon the caster controls must exist.
	if _attach_targets_weapon_only(def):
		var wscan := ["p1", "p2"] if player_id == "" else [player_id]
		for pid in wscan:
			for card in state.cards_in_zone(pid + "_hero_row"):
				if _is_melee_weapon(state, card.instance_id, db):
					return true
		return false
	# Burn Away / Shattering Blow: some in-play ability / equipment card must
	# be a legal target.
	if destroy_target_kind(def) in ["ability", "equipment"]:
		var d_kind := destroy_target_kind(def)
		for cid in get_destroy_kind_candidates(state, db, d_kind):
			if not _is_legal_target(state, cid, db):
				continue
			# Purge goes dark when every in-play ability is attached to one of
			# the caster's own characters.
			if d_kind == "ability" \
					and not _is_destroyable_ability(state, def, cid, player_id, db):
				continue
			return true
		return false
	return true


# Ancestral Spirit: a hand Ability whose target is an ally card in the caster's
# graveyard (a `graveyard_to_play` requirement segment). Distinct from the same
# segment on a Quest reward (Finkle Einhorn) — a Quest never routes through the
# ability play path, so this only ever fires for reanimate abilities.
static func _ability_reanimates_from_graveyard(def: CardDef) -> bool:
	if not def or def.effects == "":
		return false
	var req := get_graveyard_search_requirement(def)
	return req.get("dest", "") == "play"


# Cannibalize: a hand Ability that exiles cards OUT of graveyards (a
# `graveyard_to_rfg` requirement segment). The same segment also appears on
# activated powers (Ophelia Barrows) and quest rewards, neither of which routes
# through the ability play path — but an `activated_power` segment is checked
# for explicitly so a future ally with both can't be mistaken for a hand spell.
static func _ability_removes_from_graveyard(def: CardDef) -> bool:
	if not def or def.effects == "":
		return false
	if _has_effect_flag_prefix(def, "activated_power"):
		return false
	return get_graveyard_search_requirement(def).get("dest", "") == "rfg"


# Cannibalize: "…heals 2 damage from itself for each card removed."
# 0 when the card has no such rider.
static func rfg_heal_per_card(def: CardDef) -> int:
	if not def or def.effects == "":
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() >= 2 and parts[0].strip_edges() == "rfg_heal_per_card":
			return int(parts[1])
	return 0


static func _instant_needs_target(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["destroy_target", "deal_damage_to_target", "exhaust_target",
				"return_to_hand", "attach", "atk_swing", "deal_damage_and_heal",
				"grant_keyword_target", "divided_damage"]:
			return true
		# Modal (707.1c): targeted when any mode's inner effect targets.
		if parts[0] == "mode" and parts.size() > 1 \
				and parts[1] in MODE_TARGETED_EFFECTS:
			return true
	return false


# ── Modal links (rule 707.1c — "Choose one:") ──────────────────────────────────
# Each `mode:` effects segment wraps ONE standard effect segment, e.g. Natural
# Selection: `mode:deal_damage_to_target:3:nature|mode:heal_target:3`. The
# chosen mode is announced at play time on the action (params.mode, an index
# into modal_modes), like a target — validation and resolution then see ONLY
# the chosen mode's inner effect, so the engine receives "deal 3" OR "heal 3",
# never the choice itself.
#
# Targeting is MODE-AWARE (Escape Artist): what the play must announce is read
# off the CHOSEN mode, not off the def, so one card can mix a targeted mode with
# a targetless one ("interrupt target ability card…" / "…remove all attackers
# from combat"). MODE_TARGETED_EFFECTS is the registry — a mode whose inner
# effect isn't listed announces no target at all. The hero-or-ally kinds are
# validated by the shared _instant_needs_target path; `interrupt_ability` has its
# own pool (see get_interrupt_candidates), which is what mode_target_kind is for.
static func modal_modes(def: CardDef) -> Array:
	var modes: Array = []
	if not def:
		return modes
	for seg in def.effects.split("|"):
		var s := seg.strip_edges()
		if s.begins_with("mode:"):
			modes.append(s.substr(5))
	return modes


static func is_modal_def(def: CardDef) -> bool:
	return not modal_modes(def).is_empty()


# The inner effect segment picked by the action's `mode` param; "" when the
# def isn't modal or the index is missing/out of range.
static func selected_mode(def: CardDef, action: PendingAction) -> String:
	var modes := modal_modes(def)
	var idx := int(action.params.get("mode", -1))
	if idx >= 0 and idx < modes.size():
		return modes[idx]
	return ""


# Inner effects of a `mode:` segment that announce a target with the play.
# Anything else is a targetless mode (Escape Artist's remove_attackers half).
const MODE_TARGETED_EFFECTS: Array = ["destroy_target", "deal_damage_to_target",
	"exhaust_target", "heal_target", "interrupt_ability"]


# The target KIND a single mode's inner effect announces: "" for a targetless
# mode, "interrupt_ability" for Escape Artist's counterspell half, and
# "hero_or_ally" for the shipped damage/heal/destroy/exhaust modes (whose
# validation is the generic _instant_needs_target path).
static func mode_target_kind(mode_effect: String) -> String:
	var head := mode_effect.split(":")[0].strip_edges()
	if head == "interrupt_ability":
		return "interrupt_ability"
	if head in MODE_TARGETED_EFFECTS:
		return "hero_or_ally"
	return ""


# Target validation for a modal play (both the instant and the sorcery-speed
# path). The chosen mode must be announced (707.1c), and only THAT mode's target
# requirement is checked — a targetless mode needs nothing, an interrupt mode
# needs a legal chain link, everything else the shipped hero-or-ally check.
# Also answers the highlight probes, which pass `_skip_target_check` because
# they run before any mode has been picked.
static func _modal_target_ok(state: GameState, def: CardDef,
		action: PendingAction, card_id: String, db) -> bool:
	if action.params.get("_skip_target_check", false):
		return true
	var mode := selected_mode(def, action)
	if mode == "":
		return false
	match mode_target_kind(mode):
		"interrupt_ability":
			return _is_interrupt_target(state, db, action.source_player,
					action.params.get("target_id", ""), card_id)
		"hero_or_ally":
			return _is_legal_target(state, action.params.get("target_id", ""), db)
	return true   # targetless mode (Escape Artist's remove_attackers half)


# Does this def have a mode that can be chosen without announcing a target?
# Such a mode is always legally choosable (707.1c), which is what keeps Escape
# Artist playable — and highlighted — with nothing on the chain to interrupt.
static func has_targetless_mode(def: CardDef) -> bool:
	for mode in modal_modes(def):
		if mode_target_kind(mode) == "":
			return true
	return false


# ── Interrupting links (rule 711 — Escape Artist) ─────────────────────────────
# "Interrupt target ability card that's targeting your hero." The target is a
# LINK on the chain, not a card in play, so it gets its own pool rather than
# going through _is_legal_target (which asks about in-play characters).
#
# 711.3: a card can be targeted for interruption only while it's ON the chain,
# and only if it got there by being PLAYED — a card *placed* on the chain (412.1,
# a resource) can't be. That falls out of requiring a backing pending_action of
# a play_* type: place_resource is excluded by construction.
static func get_interrupt_candidates(state: GameState, db,
		player_id: String) -> Array:
	var result: Array = []
	if not db:
		return result
	var ps := state.players.get(player_id) as PlayerState
	var hero_id: String = ps.hero_instance_id if ps else ""
	if hero_id == "":
		return result
	for link in state.pending_actions:
		var pa := link as PendingAction
		if not (pa.action_type in ["play_instant", "play_ability"]):
			continue
		var cid: String = pa.params.get("card_id", "")
		if cid == "":
			continue
		var card := state.get_card(cid)
		if not card:
			continue
		var zone := state.zones.get(card.zone_id) as Zone
		if not zone or zone.zone_type != "chain":
			continue
		# "ability card" — a type line of "Ability" or "Instant Ability" (the
		# Instant prefix is stripped into is_instant), so an Instant Ally on the
		# chain is not a candidate.
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.card_type != "Ability":
			continue
		if not _link_targets_hero(pa, hero_id):
			continue
		result.append(cid)
	return result


# Does this link announce `hero_id` in any of its target slots? Every announced
# target rides the params, so one scan covers single-target spells, the
# multi-slot ones (Multi-Shot, Ravenous Bite, Shock and Soothe) and the
# id-list ones (Chain Lightning, Lightning Storm).
static func _link_targets_hero(pa: PendingAction, hero_id: String) -> bool:
	for key in ["target_id", "target_id_2", "target_id_3", "heal_target_id"]:
		if str(pa.params.get(key, "")) == hero_id:
			return true
	for tid in pa.params.get("target_ids", []):
		if str(tid) == hero_id:
			return true
	return false


# The one predicate behind submission, the highlight probe and the resolution
# re-check (711/706): is `target_id` a link `player_id` may interrupt right now?
# `source_card_id` is the interrupting card, excluded because a link can't
# interrupt itself (711.2).
static func _is_interrupt_target(state: GameState, db, player_id: String,
		target_id: String, source_card_id: String) -> bool:
	if target_id == "" or target_id == source_card_id:
		return false
	return target_id in get_interrupt_candidates(state, db, player_id)


# Interrupt the link backed by `card_id` (rule 711.1): it leaves the chain
# without resolving and, being a card, goes to its OWNER's graveyard. 711.2 —
# the whole text is interrupted (nothing it announced happens) and costs already
# paid are not refunded, which is why nothing here touches resources or undoes
# an announcement cost. Priority afterwards is handled by the caller's normal
# post-resolution path (pass_priority hands it to the turn player).
static func _interrupt_link(state: GameState, card_id: String,
		source_card_id: String, db = null) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var idx := -1
	for i in state.pending_actions.size():
		var pa := state.pending_actions[i] as PendingAction
		if str(pa.params.get("card_id", "")) == card_id:
			idx = i
			break
	if idx < 0:
		return events
	var link := state.pending_actions[idx] as PendingAction
	state.pending_actions.remove_at(idx)
	events.append(GameEvent.link_interrupted(card_id, source_card_id,
			link.source_player))
	var card := state.get_card(card_id)
	if card:
		events.append_array(GameLogic.move_card(state, card_id,
				card.owner + "_graveyard"))
	return events


static func _instant_targets_ally_only(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["destroy_target", "exhaust_target", "return_to_hand", "attach",
				"grant_keyword_target"] \
				and parts.size() > 1 and parts[1] in ["ally", "friendly_ally", "exhausted_ally"]:
			return true
		# Ravenous Bite: BOTH announced targets are allies (parts[1..] are the
		# signed amounts, not a target kind).
		if parts[0] == "atk_swing":
			return true
		# Lightning Storm: every announced target is an ally (parts[1] is the
		# literal "X" damage pool, not a target kind).
		if parts[0] == "divided_damage":
			return true
	return false


# ── Ravenous Bite (azeroth_44) — `atk_swing:A1:A2` ────────────────────────────
# "Target ally has +3 ATK this turn. Target ally has -3 ATK this turn." Two
# INDEPENDENT ally targets announced in order with the play (target_id gets A1,
# target_id_2 gets A2). Not modal and not Chain Lightning's "up to N" list:
# both picks are mandatory, both must be legal (706 — Untargetable allies are
# excluded from BOTH slots, unlike Multi-Shot), and the same ally may be picked
# twice (the two grants then cancel out on the board, which is legal and
# occasionally forced when only one ally is in play).
static func atk_swing_amounts(def: CardDef) -> Array:
	var amounts: Array = []
	if not def:
		return amounts
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "atk_swing":
			for i in range(1, parts.size()):
				amounts.append(int(parts[i]))
			break
	return amounts


static func is_atk_swing_def(def: CardDef) -> bool:
	return def != null and _has_effect_flag_prefix(def, "atk_swing")


# Both announced targets must be legal allies (706). Used at submission; each
# target is re-checked independently at resolution.
static func _can_play_atk_swing(state: GameState, action: PendingAction, db) -> bool:
	for key in ["target_id", "target_id_2"]:
		var tid: String = action.params.get(key, "")
		if not _is_legal_target(state, tid, db) or not _is_ally(state, tid):
			return false
	return true


# ── Shock and Soothe (dark_portal_100) — `deal_damage_and_heal` as a hand card ─
# "Your hero deals 3 nature damage to target hero or ally and heals 3 damage
# from ANOTHER target hero or ally." Same effect key as the Grennan hero power /
# Hierophant Caydiem ally power (params: target_id = damage, heal_target_id =
# heal), now reachable from the play_instant / play_ability paths. Both slots are
# real targets (706 — Untargetable blocks either), they must be DISTINCT
# ("another"), and each is re-checked independently at resolution, so killing or
# bouncing one in response fizzles only that half.
static func is_damage_and_heal_def(def: CardDef) -> bool:
	return def != null and _has_effect_flag_prefix(def, "deal_damage_and_heal")


static func _can_play_damage_and_heal(state: GameState, action: PendingAction, db) -> bool:
	var dmg_id:  String = action.params.get("target_id", "")
	var heal_id: String = action.params.get("heal_target_id", "")
	if dmg_id == heal_id:
		return false
	for tid in [dmg_id, heal_id]:
		if not _is_legal_target(state, tid, db) or not _is_hero_or_ally(state, tid, db):
			return false
	return true


# ── Lightning Storm (dark_portal_98) — `divided_damage:X:TYPE:ally` ───────────
# "Your hero deals X nature damage divided as you choose to any number of
# target allies." (cost "2+X", so the announced X is BOTH the price and the
# damage pool — see _can_afford_play / GameState.get_play_cost, which already
# apply Elemental Focus' discount to `cost_base + X`, so a discount lets the
# player announce a bigger X for the same resources.)
#
# The division is announced as `target_ids`: a list of exactly X ally ids in
# pick order, WITH repeats allowed — one entry per point of damage, which is
# what makes "divided as you choose" a plain click sequence (X clicks) instead
# of a bespoke allocation widget. Every entry is a real target (706 —
# Untargetable allies are excluded, unlike Multi-Shot's select-don't-target
# exception), and the pool is allies only: heroes are never legal.
#
# At resolution the picks are tallied per ally and each distinct target takes
# ONE packet of its total, in first-pick order (see the `divided_damage` branch
# of _resolve_play_instant) — so replacement effects and per-damage riders see
# one 3-damage hit rather than three 1-damage hits.
static func is_divided_damage_def(def: CardDef) -> bool:
	return def != null and _has_effect_flag_prefix(def, "divided_damage")


static func divided_damage_type(def: CardDef) -> String:
	if not def:
		return ""
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "divided_damage" and parts.size() > 2:
			return parts[2].to_lower().strip_edges()
	return ""


# Announced picks must all be legal allies, and there must be exactly X of them
# (every point of the pool is spent — the card divides X, it doesn't waste it).
# `_divided_probe` relaxes ONLY the count, for the UI/AI to test one click at a
# time while the list is still being built; a real submission never carries it.
static func _can_play_divided_damage(state: GameState, action: PendingAction, db) -> bool:
	var x := int(action.params.get("x_value", 0))
	if x < 1:
		return false
	var picks: Array = action.params.get("target_ids", [])
	if picks.is_empty() or picks.size() > x:
		return false
	if picks.size() != x and not bool(action.params.get("_divided_probe", false)):
		return false
	for tid in picks:
		if not _is_legal_target(state, tid, db) or not _is_ally(state, tid):
			return false
	return true


# Two distinct legal hero-or-ally targets must exist for the card to be
# announceable (706.2) — drives the hand highlight probe. Two heroes are always
# in play, so this only goes dark in exotic Untargetable states.
static func _has_two_legal_hero_or_ally_targets(state: GameState, db) -> bool:
	var seen := 0
	for pid in ["p1", "p2"]:
		for card: CardInstance in state.cards_in_play(pid):
			if _is_hero_or_ally(state, card.instance_id, db) \
					and _is_legal_target(state, card.instance_id, db):
				seen += 1
				if seen >= 2:
					return true
	return false


# Coup de Grâce (`destroy_target:exhausted_ally`): "Destroy target exhausted
# ally." A subset of the ally-only restriction — the target ally must also be
# exhausted. Checked at submission and re-checked at resolution (706).
static func _destroy_requires_exhausted(def: CardDef) -> bool:
	return destroy_target_kind(def) == "exhausted_ally"


static func _is_exhausted_ally(state: GameState, target_id: String, db) -> bool:
	var card := state.get_card(target_id)
	return card != null and card.is_exhausted \
			and _is_ally(state, target_id) \
			and _is_legal_target(state, target_id, db)


# Whether ANY legal exhausted-ally target exists on the board (either party).
# Backs the no-target probes for Coup de Grâce and for Lhurg Venomblade's
# `exhausted_ally` power target kind, so neither lights up with nothing to kill.
static func _any_exhausted_ally(state: GameState, db) -> bool:
	for pid: String in state.players:
		for ally: CardInstance in state.cards_in_zone(pid + "_ally_row"):
			if _is_exhausted_ally(state, ally.instance_id, db):
				return true
	return false


# ── Sacrifice-an-ally play cost (Sever the Cord) ──────────────────────────────
#
# "As an additional cost to play Sever the Cord, destroy an ally in your party."
# The activated-power `sacrifice_ally` EXTRACOST pays at RESOLUTION (a source
# killed in response no-ops the cost); this is the HAND-CARD form and pays at
# ANNOUNCEMENT (rule 412.2, like The Love Potion's exhaust_allies) — which is
# the whole point of the card: bounce or kill the target in response and the
# sacrifice has still been spent, for nothing.
#
# The sacrifice rides the play as `sacrifice_id` (its own pick, never target_id
# — the effect targets a different ally). Announcing the sacrifice as the
# destroy target too is LEGAL, since targets are chosen before costs are paid;
# it simply fizzles at resolution (706).
static func play_cost_sacrifices_ally(def: CardDef) -> bool:
	return def != null and _has_effect_flag_prefix(def, "play_cost_sacrifice_ally")


# Allies in `player_id`'s party that may pay the cost — any ally_row card,
# ready or exhausted, totems included (305.3a: a Totem is an ally).
static func get_play_sacrifice_candidates(state: GameState, player_id: String) -> Array:
	var result: Array = []
	for ally: CardInstance in state.cards_in_zone(player_id + "_ally_row"):
		result.append(ally.instance_id)
	return result


# Submission gate: the announced sacrifice must be one of them. The highlight
# probe (`_skip_target_check`) only asks that SOME ally could pay.
static func _play_cost_sacrifice_ok(state: GameState, def: CardDef,
		action: PendingAction) -> bool:
	if not play_cost_sacrifices_ally(def):
		return true
	var cands := get_play_sacrifice_candidates(state, action.source_player)
	if action.params.get("_skip_target_check", false):
		return not cands.is_empty()
	return action.params.get("sacrifice_id", "") in cands


# ── Cost-banded destroy (Trophy Kill / Prey on the Weak) ──────────────────────
# `target_cost_min:N` / `target_cost_max:N` are RIDERS on an existing
# `destroy_target:ally` segment, not a new target kind — the target is an
# ordinary ally in every other respect, so all the ally-only machinery
# (targeting, friendly-only, the router's can_submit-filtered target list)
# applies unchanged:
#   Trophy Kill      (dark_portal_40, 3): destroy_target:ally|target_cost_min:4
#   Prey on the Weak (dark_portal_85, 2): destroy_target:ally|target_cost_max:4
# Both bands are INCLUSIVE ("4 or more" / "4 or less"), so a cost-4 ally is a
# legal target for either card. Enforced at submission, in the highlight probe
# (the card goes dark when no ally is in the band) and re-checked at resolution
# (706 / glossary 4217 — a target that left play fizzles the destroy).
static func destroy_cost_band(def: CardDef) -> Dictionary:
	var band := {}
	if not def or def.effects == "":
		return band
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() > 1 and parts[0] in ["target_cost_min", "target_cost_max"]:
			band[parts[0].substr(12)] = int(parts[1])
	return band


# The cost a cost band is measured against is the target's PRINTED cost (the
# number in the card's corner), not `get_play_cost` — an in-play ally was paid
# for long ago, and cost-modifying effects apply to cards being PLAYED. For a
# hypothetical "1+X" ally the fixed part is the printed number.
static func printed_cost(def: CardDef) -> int:
	if not def:
		return 0
	if def.cost_x:
		return def.cost_base
	return max(def.cost, 0)


static func _destroy_cost_band_ok(state: GameState, def: CardDef,
		target_id: String, db) -> bool:
	var band := destroy_cost_band(def)
	if band.is_empty():
		return true
	var card := state.get_card(target_id)
	if not card or db == null:
		return false
	var t_def := db.get_def(card.card_def_id) as CardDef
	var cost := printed_cost(t_def)
	if band.has("min") and cost < int(band["min"]):
		return false
	if band.has("max") and cost > int(band["max"]):
		return false
	return true


# Fall Back (`return_to_hand:friendly_ally`), Into the Fray
# (`grant_keyword_target:friendly_ally:ferocity`): "…target ally in your party."
# A subset of the ally-only restriction — the target ally must also be
# controlled by the caster.
static func _instant_targets_friendly_ally_only(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] in ["destroy_target", "exhaust_target", "return_to_hand", "attach",
				"grant_keyword_target"] \
				and parts.size() > 1 and parts[1] == "friendly_ally":
			return true
	return false


# Arcane Intellect: `attach:hero` — the attachment may only target a hero.
static func _attach_targets_hero_only(def: CardDef) -> bool:
	var parts := attach_parts(def)
	return parts.size() > 1 and parts[1] == "hero"


# Windfury Weapon: `attach:melee_weapon` — "Attach to one of your Melee weapons."
# The attachment may only target a Melee weapon (equipment in a hero row).
static func _attach_targets_weapon_only(def: CardDef) -> bool:
	var parts := attach_parts(def)
	return parts.size() > 1 and parts[1] == "melee_weapon"


# True if target_id is an in-play Melee weapon (Equipment with a weapon segment
# and dmg_type "Melee"). Used by Windfury Weapon's attach target check.
static func _is_melee_weapon(state: GameState, target_id: String, db) -> bool:
	if not db or not state.is_in_play(target_id):
		return false
	var card := state.get_card(target_id)
	if not card:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.card_type != "Equipment":
		return false
	if _weapon_info(def).is_empty():
		return false
	return def.dmg_type.to_lower() == "melee"


# Rule 400: an attachment carries an `attach:TARGETS[:exhaust_it]` segment
# ("Attach to target <TARGETS>"). Returns the parsed segment, or an empty
# array for non-attachments.
static func attach_parts(def: CardDef) -> PackedStringArray:
	if not def:
		return PackedStringArray()
	for seg in def.effects.split("|"):
		var p := seg.strip_edges().split(":")
		if p[0] == "attach":
			return p
	return PackedStringArray()


static func is_attachment_def(def: CardDef) -> bool:
	return attach_parts(def).size() > 0


# First to Fall: "Destroy target protecting ally." (`destroy_target:protecting_ally`).
# The only legal target is the single ally currently protecting this combat —
# `state.combat_protector` — so the card is only playable in a defend window where
# an opponent has protected with an ally (never the attack window, where no one is
# protecting yet). A protecting HERO (Draconian Deflector) is not a legal target.
static func _instant_targets_protecting_ally_only(def: CardDef) -> bool:
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "destroy_target" \
				and parts.size() > 1 and parts[1] == "protecting_ally":
			return true
	return false


static func _is_protecting_ally(state: GameState, target_id: String, db = null) -> bool:
	return target_id != "" and target_id == state.combat_protector \
			and state.is_in_play(target_id) and _is_ally(state, target_id)


# Burn Away ("Destroy target ability.") / Shattering Blow ("Destroy target
# equipment."): `destroy_target:ability` / `destroy_target:equipment`. Returns
# the destroy_target kind of a def ("ally", "ability", "equipment",
# "protecting_ally") or "" for non-destroy defs. Shared by the router and AI.
static func destroy_target_kind(def: CardDef) -> String:
	if not def:
		return ""
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0] == "destroy_target" and parts.size() > 1:
			return parts[1]
	return ""


# ── Shred Soul (dark_portal_114) — `rfg_instead` ──────────────────────────────
# "Remove target ally from the game." A RIDER on a `destroy_target:ally`
# segment, not a target kind of its own: the announce, the 706 re-check, the
# highlight probe, the router's target list and the AI's threat/worth math are
# all exactly Vanquish's, so the whole path is inherited and only the final
# removal differs. What differs is the DESTINATION — the ally goes to its
# owner's RFG zone (415.7a) instead of the graveyard, and it is NOT destroyed:
# no `card_destroyed`, so `on_destroyed` triggers (Boneshanks) never fire and
# "when an ally is destroyed" watchers see nothing, and no graveyard card is
# left for recursion (Ophelia, Augustus, Cannibalize) to find.
static func _destroy_removes_from_game(def: CardDef) -> bool:
	return def != null and _has_effect_flag(def, "rfg_instead")


# An in-play ability CARD (rule 300.1): an ongoing ability in a hero row, a
# Totem in an ally row, or an attachment in the "attached" zone. A face-down
# resource is a resource, not an ability — resource_row never qualifies.
static func _is_in_play_ability(state: GameState, target_id: String, db) -> bool:
	if not db:
		return false
	var card := state.get_card(target_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or not (zone.zone_type in ["hero_row", "ally_row", "attached"]):
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	return def != null and def.card_type == "Ability"


# Purge ("Destroy target ability unless it's attached to a friendly hero or
# ally."): an `except_friendly_attached` flag riding a `destroy_target:ability`
# segment. Narrows Burn Away's target pool — the caster's OWN characters'
# attachments are off-limits, which notably means Purge can't strip an
# opponent's Entangling Roots off your own ally.
static func _destroy_excludes_friendly_attached(def: CardDef) -> bool:
	return _has_effect_flag(def, "except_friendly_attached")


# Whether an in-play ability is an attachment whose HOST is a hero or ally
# controlled by player_id. "Friendly" is judged on the HOST's controller, not
# the attachment's — an opponent's Entangling Roots on your ally is friendly-
# attached (and so protected from your Purge). An attachment on a weapon
# (Windfury Weapon) is not on a hero or ally, so it stays targetable.
static func _is_friendly_attached_ability(state: GameState, target_id: String,
		player_id: String, db) -> bool:
	var card := state.get_card(target_id)
	if not card or card.attached_to == "":
		return false
	var host := state.get_card(card.attached_to)
	if not host or host.controller != player_id:
		return false
	return _is_hero_or_ally(state, host.instance_id, db)


# Full `destroy_target:ability` target check for a given caster: an in-play
# ability card, minus Purge's friendly-attachment exclusion. player_id "" skips
# the exclusion (caster-agnostic probes).
static func _is_destroyable_ability(state: GameState, def: CardDef,
		target_id: String, player_id: String, db) -> bool:
	if not _is_in_play_ability(state, target_id, db):
		return false
	if player_id != "" and _destroy_excludes_friendly_attached(def) \
			and _is_friendly_attached_ability(state, target_id, player_id, db):
		return false
	return true


# An in-play equipment card (armor or weapon — equipment only lives in the
# hero row, rule 304.1).
static func _is_in_play_equipment(state: GameState, target_id: String, db) -> bool:
	if not db:
		return false
	var card := state.get_card(target_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hero_row":
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	return def != null and def.card_type == "Equipment"


# All in-play cards that match a destroy_target kind of "ability" or
# "equipment" (both players). Candidates only — callers still filter through
# can_submit / _is_legal_target (706 Untargetable).
static func get_destroy_kind_candidates(state: GameState, db, kind: String) -> Array:
	var result: Array = []
	var zone_ids: Array = ["p1_hero_row", "p2_hero_row"]
	if kind == "ability":
		zone_ids += ["p1_ally_row", "p2_ally_row", "attached"]
	for zone_id in zone_ids:
		for card in state.cards_in_zone(zone_id):
			var matches := _is_in_play_ability(state, card.instance_id, db) \
					if kind == "ability" \
					else _is_in_play_equipment(state, card.instance_id, db)
			if matches:
				result.append(card.instance_id)
	return result


# Whether an in-play card is a legal "hero or ally" target: a hero (card_type
# "Hero") or an ally-row card. Excludes equipment (also hero_row) and
# resources/graveyard/etc.
static func _is_hero_or_ally(state: GameState, target_id: String, db) -> bool:
	if not state.is_in_play(target_id):
		return false
	if _is_ally(state, target_id):
		return true
	if db:
		var card := state.get_card(target_id)
		var def := db.get_def(card.card_def_id) as CardDef if card else null
		if def and def.card_type == "Hero":
			return true
	return false


# Whether a card can be chosen as (or remain) a link target (rule 706): it must
# be in play and — unless the caller opts out — must not have the Untargetable
# keyword (glossary ~4215: "This card can't be targeted", in play only).
# allow_untargetable is for card-specific slots that select rather than target
# (e.g. Chain Lightning's 2nd/3rd targets). Combat is NOT targeting (601.2b)
# and non-targeted effects (AoE) never go through this check.
static func _is_legal_target(state: GameState, target_id: String, db,
		allow_untargetable := false) -> bool:
	if target_id == "" or not state.is_in_play(target_id):
		return false
	if not allow_untargetable:
		var card := state.get_card(target_id)
		if card and _has_keyword(card, "untargetable", db, state):
			return false
	return true


# Chain Lightning (azeroth_106): up to 3 announced targets, in printed order.
# target_id (mandatory), target_id_2 / target_id_3 (optional "may" targets).
static func _chain_lightning_targets(action: PendingAction) -> Array[String]:
	var result: Array[String] = []
	var t1: String = action.params.get("target_id", "")
	var t2: String = action.params.get("target_id_2", "")
	var t3: String = action.params.get("target_id_3", "")
	if t1 != "":
		result.append(t1)
	if t2 != "":
		result.append(t2)
	if t3 != "":
		result.append(t3)
	return result


# Validates a Chain Lightning target announcement (card-specific — see CLAUDE.md).
# 1st target: must be a legal hero-or-ally target and may NOT be Untargetable
# (card-specific override of the normal Untargetable rule). 2nd/3rd targets:
# must be a legal hero-or-ally target, distinct from all previously chosen
# targets for this cast, but MAY be Untargetable. target_id_3 requires
# target_id_2 to also be set (can't skip "another" in the printed order).
static func _can_play_chain_lightning(state: GameState, action: PendingAction, db) -> bool:
	var target_id:   String = action.params.get("target_id",   "")
	var target_id_2: String = action.params.get("target_id_2", "")
	var target_id_3: String = action.params.get("target_id_3", "")
	if target_id == "":
		return false
	if not _is_hero_or_ally(state, target_id, db):
		return false
	if not _is_legal_target(state, target_id, db):
		return false
	if target_id_3 != "" and target_id_2 == "":
		return false
	if target_id_2 != "":
		if target_id_2 == target_id:
			return false
		if not _is_hero_or_ally(state, target_id_2, db):
			return false
		# allow_untargetable: this slot selects rather than targets
		# (card-specific exception — see comment above).
		if not _is_legal_target(state, target_id_2, db, true):
			return false
	if target_id_3 != "":
		if target_id_3 == target_id or target_id_3 == target_id_2:
			return false
		if not _is_hero_or_ally(state, target_id_3, db):
			return false
		# allow_untargetable: this slot selects rather than targets
		# (card-specific exception — see comment above).
		if not _is_legal_target(state, target_id_3, db, true):
			return false
	return true


# Validates a Multi-Shot announcement (azeroth_41 — see CLAUDE.md). "Your hero
# deals N ranged damage to each of up to three target heroes and/or allies."
# Up to 3 distinct hero-or-ally targets in announce order (target_id mandatory;
# target_id_2/_3 optional, _3 requires _2). Unlike Chain Lightning, ALL three
# slots select rather than target — every slot MAY be Untargetable
# (allow_untargetable, card-specific 706 exception).
static func _can_play_multi_shot(state: GameState, action: PendingAction, db) -> bool:
	var t1: String = action.params.get("target_id",   "")
	var t2: String = action.params.get("target_id_2", "")
	var t3: String = action.params.get("target_id_3", "")
	if t1 == "":
		return false
	if not _is_hero_or_ally(state, t1, db):
		return false
	if not _is_legal_target(state, t1, db, true):
		return false
	if t3 != "" and t2 == "":
		return false
	if t2 != "":
		if t2 == t1:
			return false
		if not _is_hero_or_ally(state, t2, db):
			return false
		if not _is_legal_target(state, t2, db, true):
			return false
	if t3 != "":
		if t3 == t1 or t3 == t2:
			return false
		if not _is_hero_or_ally(state, t3, db):
			return false
		if not _is_legal_target(state, t3, db, true):
			return false
	return true


static func _can_place_resource(state: GameState, action: PendingAction,
		db = null) -> bool:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return false
	if card.controller != action.source_player:
		return false
	# Rule 412.1a: turn player's NON-COMBAT action phase only, chain empty.
	if state.phase != "action":
		return false
	if state.combat_attack_window or state.combat_defend_window:
		return false
	if state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	# Rule 412.1: once per turn.
	var ps := state.players.get(action.source_player) as PlayerState
	if ps and ps.resource_placed_this_turn:
		return false
	# Face-up placement (quests/locations only — rule 412.1b).
	var face_up: bool = action.params.get("face_up", false)
	if face_up and db:
		var def: CardDef = db.get_def(card.card_def_id)
		if def and def.card_type != "Quest" and def.card_type != "Location":
			return false
	return true


# ── Resolution ─────────────────────────────────────────────────────────────────

static func _resolve(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	match action.action_type:
		"play_ally":
			return _resolve_play_ally(state, action, db)
		"play_equipment":
			return _resolve_play_equipment(state, action, db)
		"play_ability":
			if db and _is_ongoing_ability(state, action.params.get("card_id", ""), db):
				return _resolve_play_ongoing_ability(state, action, db)
			return _resolve_play_instant(state, action, db)   # non-ongoing: apply effect → graveyard
		"play_instant":
			return _resolve_play_instant(state, action, db)
		"place_resource":
			return _resolve_place_resource(state, action)
		"propose_combat":
			return _resolve_propose_combat(state, action, db)
		"use_quest":
			return _resolve_use_quest(state, action, db)
		"activate_power":
			return _resolve_activate_power(state, action, db)
		"use_ally_power":
			return _resolve_use_ally_power(state, action, db)
		"choose_enter_play_target":
			return _resolve_choose_enter_play_target(state, action, db)
		"resolve_totem_trigger":
			return _resolve_totem_trigger(state, action, db)

	# Unknown action type — should not happen if can_submit gate is correct.
	return [GameEvent.make("action_fizzled", {
		"action_type": action.action_type,
		"reason":      "unknown_action_type",
	})]


static func _resolve_play_ally(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)

	# Re-validate: card must still be in the chain zone.
	# If it was interrupted/removed, it fizzles and goes to graveyard (rule 711.1).
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "play_ally", "reason": "card_not_found",
		})]
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "chain":
		var fizzle_events: Array[GameEvent] = []
		fizzle_events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_ally", "reason": "card_left_chain",
		}))
		if zone and zone.zone_type != "graveyard":
			fizzle_events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
		return fizzle_events

	return _bring_ally_into_play(state, card_id, db)


# Create an ally token and put it into play under `controller` (Mya's Mechanical
# Dragonling, Tooga's Quest's Tooga). Non-targeted and mandatory, so it fires
# inline — no choice, nothing to put on the chain.
#
# The token goes in through _bring_ally_into_play like any other ally, so it
# gets summoning sickness, its own on_enter triggers, Watcher Mal'wi-style
# reactions, and the Pet/Unique uniqueness checks (Tooga is Unique — a second
# copy triggers the normal sacrifice choice).
static func _put_token_into_play(state: GameState, controller: String,
		token_def_id: String, count: int, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	for _i in max(count, 1):
		var tid := GameLogic.create_token(state, controller, token_def_id, db)
		if tid == "":
			continue
		events.append(GameEvent.make("token_created", {
			"card": tid, "def": token_def_id, "player": controller,
		}))
		events.append_array(_bring_ally_into_play(state, tid, db))
	return events


# "When an opposing ally enters play, …" watchers. Any in-play card an OPPONENT
# of the entering ally controls with one of these flags reacts here:
#
#   damage_opposing_ally_on_enter:AMOUNT:DMG_TYPE — Watcher Mal'wi (ping it)
#   exhaust_opposing_ally_on_enter                — Stone Guard Rashun
#
# Resolved immediately, not via the chain — see data/rules_deviations.md
# "Watcher Mal'wi".
#
# Rule 305.3a: "Totems are ability allies and count as both in all zones" — so a
# Totem entering play IS an ally entering play and must trigger these. A Totem
# does NOT come through _bring_ally_into_play (it resolves via
# _resolve_play_ongoing_ability straight into the ally_row), which is why this
# lives in its own function called from BOTH entry paths. Tokens need no special
# handling — _put_token_into_play brings them in through _bring_ally_into_play
# like any other ally.
static func fire_opposing_ally_enter_watchers(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var card := state.get_card(card_id)
	if not card or not db:
		return events

	for other_pid in state.players:
		if other_pid == card.controller:
			continue
		for watcher in state.cards_in_play(other_pid):
			var wdef := db.get_def(watcher.card_def_id) as CardDef
			if not wdef or wdef.effects == "":
				continue
			for seg in wdef.effects.split("|"):
				var wp := seg.strip_edges().split(":")
				match wp[0].strip_edges():
					"damage_opposing_ally_on_enter":
						if not state.is_in_play(card_id):
							break   # entering ally already destroyed by an earlier watcher
						# wp[2] is the damage type (ranged) — flavor only; deal_damage
						# doesn't track a combat/effect damage type. Packet pipeline
						# (the target is always an ally, so no prevention point opens,
						# but the invariant holds: effects never deal directly).
						var amt := int(wp[1]) if wp.size() > 1 else 1
						events.append_array(defer_packets(state, db, [{
							"source": watcher.instance_id, "target": card_id,
							"amount": amt,
						}]))
					"exhaust_opposing_ally_on_enter":
						# Stone Guard Rashun: "When an opposing ally enters play,
						# exhaust it." Mandatory, no cost, no choice, no target —
						# fires inline. exhaust_card no-ops if an earlier watcher
						# already killed the entering ally or exhausted it, so
						# stacked copies are harmless.
						if not state.is_in_play(card_id):
							break
						events.append_array(GameLogic.exhaust_card(state, card_id))
	return events


# Move an ally into its controller's ally_row and fire its enter-play effects.
# Shared by normal play (_resolve_play_ally) and effects that put an ally into
# play from elsewhere (e.g. Finkle Einhorn's graveyard reward) — the on_enter
# triggers fire identically regardless of where the ally came from.
static func _bring_ally_into_play(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if not card:
		return []

	var events: Array[GameEvent] = []
	var target_zone_id: String = card.controller + "_ally_row"
	events.append_array(GameLogic.move_card(state, card_id, target_zone_id))
	card.just_summoned = true

	# Check for on_enter triggered effects.
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and def.effects != "":
			for entry in def.effects.split("|"):
				var parts := entry.strip_edges().split(":")
				if parts.is_empty() or parts[0].strip_edges() != "on_enter":
					continue
				var effect_key := parts[1].strip_edges() if parts.size() > 1 else ""
				match effect_key:
					"draw":
						var n := int(parts[2]) if parts.size() > 2 else 1
						for _i in n:
							events.append_array(_draw_one(state, card.controller))
					"create_token":
						# Mya, Dragonling Wrangler: "When Mya enters play, put a
						# Mechanical Dragonling ally token with 1 ATK and 1 health
						# into play." No target, no choice — fires inline.
						var token_def_id := parts[2].strip_edges() if parts.size() > 2 else ""
						var token_n := int(parts[3]) if parts.size() > 3 else 1
						if token_def_id != "":
							events.append_array(_put_token_into_play(
								state, card.controller, token_def_id, token_n, db))
					"discard_opponent":
						var n := int(parts[2]) if parts.size() > 2 else 1
						var opp := _other_player(state, card.controller)
						var opp_hand := state.cards_in_zone(opp + "_hand")
						if not opp_hand.is_empty():
							state.pending_discard_player = opp
							state.pending_discard_count  = n
							events.append(GameEvent.discard_choice_opened(opp, n, "card_effect"))
					"heal_party":
						# Stylean Silversteel: "When [this] enters play, she heals
						# N damage from each hero and ally in your party." Non-
						# targeted — the entering card is already in the ally_row,
						# so it's included. Fires inline (no choice, no chain).
						var heal_n := int(parts[2]) if parts.size() > 2 else 0
						for party_ally in state.cards_in_zone(card.controller + "_ally_row"):
							events.append_array(GameLogic.heal(state, party_ally.instance_id, heal_n, db, card_id))
						var party_hero2 := state.get_hero(card.controller)
						if party_hero2:
							events.append_array(GameLogic.heal(state, party_hero2.instance_id, heal_n, db, card_id))
					"deal_damage_to_target":
						var amount := int(parts[2]) if parts.size() > 2 else 0
						var dmg_type := parts[3].to_lower().strip_edges() if parts.size() > 3 else ""
						state.pending_enter_play_effect = {
							"card_id": card_id,
							"effect": "deal_damage_to_target:%d:%s" % [amount, dmg_type],
							"dmg_type": dmg_type,
							"amount": amount,
						}
						events.append(GameEvent.enter_play_target_required(
							card_id, dmg_type, amount))
					"destroy_exhausted_damaged_ally":
						# Ghank: "When [this] enters play, you may destroy target
						# exhausted ally with damage on it." Optional — the choice
						# only opens when a legal target exists (no target → the
						# trigger silently doesn't fire).
						if not get_enter_play_destroy_targets(state, db).is_empty():
							state.pending_enter_play_effect = {
								"card_id": card_id,
								"effect": "destroy_exhausted_damaged_ally",
								"dmg_type": "destroy",
								"amount": 0,
								"optional": true,
							}
							events.append(GameEvent.enter_play_target_required(
								card_id, "destroy", 0))
					"destroy_armor":
						# Hur Shieldsmasher: "When [this] enters play, you may
						# destroy target armor." Optional, same pattern as Ghank.
						if not get_enter_play_equipment_targets(state, db, false).is_empty():
							state.pending_enter_play_effect = {
								"card_id": card_id,
								"effect": "destroy_armor",
								"dmg_type": "destroy",
								"amount": 0,
								"optional": true,
							}
							events.append(GameEvent.enter_play_target_required(
								card_id, "destroy", 0))
					"destroy_armor_or_weapon":
						# Zygore Bladebreaker: "When [this] enters play, you may
						# destroy target armor or weapon." Optional; any equipment.
						if not get_enter_play_equipment_targets(state, db, true).is_empty():
							state.pending_enter_play_effect = {
								"card_id": card_id,
								"effect": "destroy_armor_or_weapon",
								"dmg_type": "destroy",
								"amount": 0,
								"optional": true,
							}
							events.append(GameEvent.enter_play_target_required(
								card_id, "destroy", 0))
					"destroy_ability":
						# Sister Rot: "When [this] enters play, you may destroy
						# target ability." Optional; Burn Away's pool (ongoing
						# abilities, totems, attachments — either party).
						if not get_enter_play_ability_targets(state, db).is_empty():
							state.pending_enter_play_effect = {
								"card_id": card_id,
								"effect": "destroy_ability",
								"dmg_type": "destroy",
								"amount": 0,
								"optional": true,
							}
							events.append(GameEvent.enter_play_target_required(
								card_id, "destroy", 0))
					"return_to_hand_ally":
						# Karkas Deathhowl: "When [this] enters play, you may put
						# target ally into its owner's hand." Optional; any in-play
						# ally either party — the SOURCE included, since she is in
						# play by the time her own trigger fires and the printed
						# text says simply "target ally".
						if not get_death_target_targets(state, db).is_empty():
							state.pending_enter_play_effect = {
								"card_id": card_id,
								"effect": "return_to_hand_ally",
								"dmg_type": "bounce",
								"amount": 0,
								"optional": true,
							}
							events.append(GameEvent.enter_play_target_required(
								card_id, "bounce", 0))
					"exhaust_ally":
						# Bhenn Checks-the-Sky: "When [this] enters play, you may
						# exhaust target ally." Optional; any in-play ally either
						# party — the SOURCE included, since she is in play by the
						# time her own trigger fires and the printed text says
						# simply "target ally" (Karkas' pool).
						if not get_death_target_targets(state, db).is_empty():
							state.pending_enter_play_effect = {
								"card_id": card_id,
								"effect": "exhaust_ally",
								"dmg_type": "exhaust",
								"amount": 0,
								"optional": true,
							}
							events.append(GameEvent.enter_play_target_required(
								card_id, "exhaust", 0))

	events.append_array(fire_opposing_ally_enter_watchers(state, card_id, db))

	# Check pet uniqueness (414.3b) — must happen after the card is in play.
	events.append_array(_check_pet_uniqueness(state, card_id, db))
	# Check name-based (Unique tag) uniqueness (414.3a) — Lady Jaina Proudmoore.
	events.append_array(_check_unique_uniqueness(state, card_id, db))

	return events


static func _resolve_play_equipment(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "play_equipment", "reason": "card_not_found",
		})]
	# Re-validate: card must still be on the chain (711.1); otherwise it fizzles.
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "chain":
		var fizzle_events: Array[GameEvent] = []
		fizzle_events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_equipment", "reason": "card_left_chain",
		}))
		if zone and zone.zone_type != "graveyard":
			fizzle_events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
		return fizzle_events

	var events: Array[GameEvent] = []
	# Rule 304.1 / 303.1: equipment enters play in its controller's hero row.
	events.append_array(GameLogic.move_card(state, card_id, card.controller + "_hero_row"))

	# Check equipment slot uniqueness (414.3) — must happen after it's in play.
	events.append_array(_check_equipment_uniqueness(state, card_id, db))
	# Check name-based (Unique tag) uniqueness (414.3a) — e.g. a Unique weapon.
	events.append_array(_check_unique_uniqueness(state, card_id, db))

	return events


# Rule 305.2a: an ability is ongoing if the bold word "Ongoing" appears in its
# text box. We tag that in the effects string with a leading "ongoing" segment.
static func _is_ongoing_ability(state: GameState, card_id: String, db) -> bool:
	var card := state.get_card(card_id)
	if not card:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return false
	return is_ongoing_def(def)


# Static def-only variant of _is_ongoing_ability — used by the renderer / AI
# action-type dispatch, which have a CardDef but no live card_id.
static func is_ongoing_def(def: CardDef) -> bool:
	if not def:
		return false
	for seg in def.effects.split("|"):
		if seg.strip_edges() == "ongoing":
			return true
	return false


# ── Forms (rule 414.3b tag-count uniqueness + glossary Bear/Cat Form) ─────────
#
# A Form is an ongoing Ability with a `form:N` effects segment (the "Form (N)"
# type-line tag — all current Forms are Form (1)). A player may control at most
# N in-play cards with the tag; violations mirror the Pet/Unique sacrifice flow.
# Druid Feral Forms also carry `form_break:TAG` — "Destroy this card when you
# strike with a weapon or play a non-TAG ability." (Bear/Cat form: TAG = Feral;
# a future Moonkin Form would use form_break:Balance.) Shadowform's INVERTED
# condition — "when you play a Holy ability" — is `form_break_on:Holy`: it
# breaks on a MATCHING tag instead of a non-matching one, and only on ability
# plays (its printed text doesn't mention weapon strikes). Travel Form would
# carry `form:1` alone.
# The form's own contribution (Bear form's `hero_has_protector`, Cat form's
# `hero_atk_while_attacking:1`) is a separate live-read segment.

# `form:N` → N; -1 when the def carries no Form tag.
# Type-line slot tags with tag-count uniqueness (rule 414.3b): Form (N) on the
# Druid forms, Aspect (N) on the Hunter aspects. Each tag is its OWN slot — a
# player may control one Form and one Aspect at the same time — so every check
# below is keyed on the tag, never on "is it a slot card at all".
const SLOT_TAGS := ["form", "aspect"]


# The entering card's slot tag ("form"/"aspect") and capacity, or {} when the
# card carries no slot tag at all.
static func slot_tag_spec(def: CardDef) -> Dictionary:
	if not def:
		return {}
	for seg in def.effects.split("|"):
		var p := seg.strip_edges().split(":")
		if p[0] in SLOT_TAGS:
			return {"tag": p[0], "count": int(p[1]) if p.size() > 1 else 1}
	return {}


# Capacity for a specific slot tag, or -1 when the def doesn't carry that tag.
static func slot_count_for(def: CardDef, tag: String) -> int:
	var spec := slot_tag_spec(def)
	if spec.is_empty() or spec["tag"] != tag:
		return -1
	return int(spec["count"])


static func form_slot_count(def: CardDef) -> int:
	return slot_count_for(def, "form")


static func is_form_def(def: CardDef) -> bool:
	return form_slot_count(def) >= 0


# `form_break:TAG` → TAG; "" when the def has no break condition (Travel Form).
static func form_break_tag(def: CardDef) -> String:
	if not def:
		return ""
	for seg in def.effects.split("|"):
		var p := seg.strip_edges().split(":")
		if p[0] == "form_break" and p.size() > 1:
			return p[1].strip_edges()
	return ""


# `form_break_on:TAG` → TAG; "" when the def has no inverted break condition.
# The mirror of form_break_tag: Bear/Cat Form break on a NON-matching ability,
# Shadowform breaks on a MATCHING one ("when you play a Holy ability"). A def
# carries at most one of the two; form_break_on wins where both appear.
static func form_break_on_tag(def: CardDef) -> String:
	if not def:
		return ""
	for seg in def.effects.split("|"):
		var p := seg.strip_edges().split(":")
		if p[0] == "form_break_on" and p.size() > 1:
			return p[1].strip_edges()
	return ""


# Rule 305.3: a Totem is an ability ally that enters the ally_row, can't be
# proposed as an attacker, and can be attacked/targeted like an ally. We tag it
# with a "totem[:element]" segment in the effects string.
static func is_totem_def(def: CardDef) -> bool:
	if not def:
		return false
	for seg in def.effects.split("|"):
		if seg.strip_edges() == "totem" or seg.strip_edges().begins_with("totem:"):
			return true
	return false


static func _resolve_play_ongoing_ability(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "play_ability", "reason": "card_not_found",
		})]
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "chain":
		var fizzle_events: Array[GameEvent] = []
		fizzle_events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_ability", "reason": "card_left_chain",
		}))
		if zone and zone.zone_type != "graveyard":
			fizzle_events.append_array(GameLogic.move_card(state, card_id, card.owner + "_graveyard"))
		return fizzle_events

	var events: Array[GameEvent] = []
	var def := db.get_def(card.card_def_id) as CardDef if db else null
	# Forms: "Destroy this card when you … play a non-Feral ability." Checked
	# up front so every ongoing route (attachment, totem, hero-row) is covered.
	# The played card is still on the chain (not hero_row), and a played Form's
	# own tag matches its break tag anyway — it never breaks itself.
	events.append_array(_check_form_break_ability(state, card.controller, def, db))
	# Rule 400.2: a targeted attachment resolves by entering play attached to
	# its announced target.
	if def and is_attachment_def(def):
		events.append_array(_resolve_attach(state, action, card, def, db))
		return events
	# Rule 305.3: a Totem is an ability ALLY — it enters the controller's ally_row
	# (so it can be attacked/targeted like an ally), not the hero row. It carries
	# summoning sickness like any other ally (irrelevant to attacking — totems
	# can't attack — but it means it isn't ready to be tapped for anything else).
	if def and is_totem_def(def):
		events.append_array(GameLogic.move_card(state, card_id, card.controller + "_ally_row"))
		card.just_summoned = true
		# 305.3a — a Totem is an ability ally, so an opposing Totem entering play
		# triggers "when an opposing ally enters play" watchers (Watcher Mal'wi,
		# Stone Guard Rashun) exactly as an ordinary ally does.
		events.append_array(fire_opposing_ally_enter_watchers(state, card_id, db))
		return events
	# On-play effect segments resolved in printed order BEFORE the ongoing part
	# settles into play (Bash: "Exhaust target hero or ally." / Claw: "Your hero
	# deals 3 melee damage to target hero or ally." — then "Ongoing: …").
	var target_id: String = action.params.get("target_id", "")
	if def and def.effects != "":
		for entry in def.effects.split("|"):
			var parts := entry.strip_edges().split(":")
			match parts[0].strip_edges():
				"exhaust_target":
					# 706 re-check at resolution; exhaust_card no-ops when the
					# target is already exhausted. Aimed at a proposed attacker
					# on the chain, the 601.3 recheck then fizzles the proposal.
					if _exhaust_target_ok(state, parts, target_id, db):
						events.append_array(GameLogic.exhaust_card(state, target_id))
				"deal_damage_to_target":
					# Same semantics as the play_instant branch: the HERO is the
					# damage source, packets go through the prevention pipeline.
					var amount := int(parts[1]) if parts.size() > 1 else 0
					var ps := state.players.get(action.source_player) as PlayerState
					var hero_id: String = ps.hero_instance_id if ps else ""
					if hero_id != "" and amount > 0 \
							and _is_legal_target(state, target_id, db):
						events.append_array(defer_packets(state, db, [{
							"source": hero_id, "target": target_id,
							"amount": amount,
							"dmg_type": parts[2].to_lower().strip_edges() if parts.size() > 2 else "",
							"from_ability": true,
						}]))
	# Rule 305.2c: any other non-attaching ongoing ability enters play in its
	# controller's hero row and remains there (providing its continuous
	# effect) until removed from play — it does not resolve-and-graveyard
	# like a non-ongoing ability.
	events.append_array(GameLogic.move_card(state, card_id, card.controller + "_hero_row"))
	# Form (1) tag-count uniqueness (414.3b) — after the card is in play.
	events.append_array(_check_form_uniqueness(state, card_id, db))
	return events


# Resolution-side target check for exhaust_target: `exhaust_target:ally`
# (Exhaustion) accepts allies only; `exhaust_target:hero_or_ally` (Bash) also
# accepts heroes. Both re-check 706 legality.
static func _exhaust_target_ok(state: GameState, parts: PackedStringArray,
		target_id: String, db) -> bool:
	if not _is_legal_target(state, target_id, db):
		return false
	if parts.size() > 1 and parts[1] == "hero_or_ally":
		return _is_ally(state, target_id) or _is_hero(state, target_id)
	return _is_ally(state, target_id)


# The `grant_keyword_target:KIND:KEYWORD` segment split into parts, or an empty
# array when the def has none. Public accessor for the AI / UI.
static func grant_keyword_parts(def: CardDef) -> PackedStringArray:
	if not def or def.effects == "":
		return PackedStringArray()
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "grant_keyword_target":
			return parts
	return PackedStringArray()


# Resolution-side target check for `grant_keyword_target:KIND:KEYWORD`.
# `ally` (Sneak) accepts any ally either party; `friendly_ally` (Into the Fray —
# "target ally in your party") additionally requires the caster's control.
# Both re-check 706 legality.
static func _grant_keyword_target_ok(state: GameState, parts: PackedStringArray,
		target_id: String, caster: String, db) -> bool:
	if not _is_legal_target(state, target_id, db):
		return false
	if not _is_ally(state, target_id):
		return false
	if parts.size() > 1 and parts[1] == "friendly_ally":
		var t := state.get_card(target_id)
		return t != null and t.controller == caster
	return true


static func _is_hero(state: GameState, card_id: String) -> bool:
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id == card_id:
			return true
	return false


# Rule 400.2 / 707.1d: a targeted attachment enters play attached to its
# announced target. The target is re-checked at resolution (706 / glossary
# 4217): if it left play, became Untargetable, or stopped matching the attach
# description, the attachment is put into its owner's graveyard instead.
# The attached card stays in play (zone "attached", rule 400.5) providing its
# Ongoing effect until its host leaves play (GameLogic.move_card destroys it).
static func _resolve_attach(state: GameState, action: PendingAction,
		card: CardInstance, def: CardDef, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var target_id: String = action.params.get("target_id", "")
	var parts := attach_parts(def)
	var target_ok := _is_legal_target(state, target_id, db)
	if target_ok and parts.size() > 1 and parts[1] == "ally":
		target_ok = _is_ally(state, target_id)
	elif target_ok and parts.size() > 1 and parts[1] == "hero_or_ally":
		target_ok = _is_hero_or_ally(state, target_id, db)
	elif target_ok and parts.size() > 1 and parts[1] == "hero":
		# Arcane Intellect: "Attach to target hero" — heroes only.
		target_ok = _is_hero(state, target_id)
	elif target_ok and parts.size() > 1 and parts[1] == "melee_weapon":
		# Windfury Weapon: "Attach to one of your Melee weapons" — the target must
		# still be a Melee weapon controlled by the caster (400.2 re-check).
		target_ok = _is_melee_weapon(state, target_id, db) \
				and state.get_card(target_id).controller == card.controller
	if not target_ok:
		events.append(GameEvent.make("action_fizzled", {
			"action_type": "play_ability", "reason": "attach_target_gone",
		}))
		events.append_array(GameLogic.move_card(state, card.instance_id, card.owner + "_graveyard"))
		return events
	var host := state.get_card(target_id)
	# Both sides of the relationship are set BEFORE move_card — see move_card's
	# contract (attachment setup lives in the caller).
	card.attached_to = target_id
	host.attachments.append(card.instance_id)
	events.append_array(GameLogic.move_card(state, card.instance_id, "attached"))
	events.append(GameEvent.card_attached(card.instance_id, target_id))
	# "Attach to target ally and exhaust it." (Entangling Roots) — the exhaust
	# is part of the attach resolution, not a separate link.
	if "exhaust_it" in parts:
		events.append_array(GameLogic.exhaust_card(state, target_id))
	# Fireball: "Attach to target hero or ally, and your hero deals 4 fire
	# damage to it." The damage is part of the attach resolution, dealt by the
	# controller's HERO to the fresh host (packet pipeline — armor-preventable,
	# and fire-typed so World in Flames doubling applies). If it kills an ally
	# host, the attachment dies with it (400.5) inside the packet group's
	# destroy check.
	for seg in def.effects.split("|"):
		var dp := seg.strip_edges().split(":")
		if dp[0] == "attach_draw":
			# Arcane Intellect: "Attach to target hero, and its controller draws
			# a card." The draw belongs to the HOST's controller (normally the
			# caster, but the printed text follows the attached hero).
			var draw_n := int(dp[1]) if dp.size() > 1 else 1
			for _i in draw_n:
				events.append_array(_draw_one(state, host.controller))
		if dp[0] == "attach_discard_controller":
			# Shadow Word: Pain: "Attach to target hero or ally, and its
			# controller discards a card." Like attach_draw the discard follows
			# the HOST's controller, not the caster — attaching to your own
			# character makes YOU discard. Reuses the Mias pending-discard
			# machinery; no-op on an empty hand.
			var disc_n := int(dp[1]) if dp.size() > 1 else 1
			var disc_who: String = host.controller
			if disc_n > 0 and not state.cards_in_zone(disc_who + "_hand").is_empty():
				state.pending_discard_player = disc_who
				state.pending_discard_count  = disc_n
				events.append(GameEvent.discard_choice_opened(
					disc_who, disc_n, "card_effect"))
		if dp[0] == "attach_deal_damage":
			var dmg_amt := int(dp[1]) if dp.size() > 1 else 0
			var att_hero := state.get_hero(card.controller)
			if att_hero and dmg_amt > 0:
				events.append_array(defer_packets(state, db, [{
					"source": att_hero.instance_id, "target": target_id,
					"amount": dmg_amt,
					"dmg_type": dp[2].to_lower().strip_edges() if dp.size() > 2 else "",
					"from_ability": true,
				}]))
	return events


static func _resolve_play_instant(state: GameState,
		action: PendingAction, db = null) -> Array[GameEvent]:
	var card_id:   String = action.params.get("card_id",   "")
	var target_id: String = action.params.get("target_id", "")
	var events: Array[GameEvent] = []
	events.append(GameEvent.make("instant_resolved", {
		"card_id": card_id, "player": action.source_player,
	}))
	# Dispatch effects from the card definition.
	if db:
		var card := state.get_card(card_id)
		var def  := db.get_def(card.card_def_id) as CardDef if card else null
		if def and def.effects != "":
			# Modal (707.1c): resolve ONLY the chosen mode's inner segment —
			# the dispatch below never sees the modes that weren't picked.
			var entries := def.effects.split("|")
			if is_modal_def(def):
				entries = PackedStringArray([selected_mode(def, action)])
			for entry in entries:
				var parts := entry.strip_edges().split(":")
				match parts[0].strip_edges():
					"destroy_target":
						# Re-check at resolution (rule 706 / glossary 4217): the
						# effect fizzles if the target left play OR became
						# Untargetable after the announce. For "protecting_ally"
						# (First to Fall) the target must also still be the ally
						# protecting this combat (combat_protector), which is why
						# destroying it in the defend window ends the combat with no
						# damage (603.1b) rather than passing the attack through.
						var dt_ok := _is_legal_target(state, target_id, db)
						if dt_ok and parts.size() > 1:
							match parts[1]:
								"protecting_ally":
									dt_ok = _is_protecting_ally(state, target_id, db)
								"exhausted_ally":
									# Coup de Grâce: re-check ally + exhausted (706 /
									# glossary 4217) — fizzles if it left play or readied.
									dt_ok = _is_exhausted_ally(state, target_id, db)
								"ability":
									# Purge also re-checks the friendly-attachment
									# exclusion: a host that changed control (or an
									# attachment that moved) can fizzle the destroy.
									dt_ok = _is_destroyable_ability(state, def,
											target_id, action.source_player, db)
								"equipment":
									dt_ok = _is_in_play_equipment(state, target_id, db)
						# Trophy Kill / Prey on the Weak: the printed-cost band is
						# re-checked at resolution too — a target that left play and
						# came back, or one swapped out from under the announce,
						# fizzles the destroy (706 / glossary 4217).
						if dt_ok and not _destroy_cost_band_ok(state, def, target_id, db):
							dt_ok = false
						if dt_ok:
							# Shred Soul (`rfg_instead`): remove from the game
							# instead of destroying — see _destroy_removes_from_game.
							if _destroy_removes_from_game(def):
								var rfg_card := state.get_card(target_id)
								events.append_array(GameLogic.move_card(
										state, target_id, rfg_card.owner + "_rfg"))
								events.append(GameEvent.card_removed_from_game(
										target_id, rfg_card.owner))
							else:
								events.append_array(
									_destroy_card_trigger(state, target_id, card_id, db))
					"atk_swing":
						# Ravenous Bite: "Target ally has +3 ATK this turn.
						# Target ally has -3 ATK this turn." The two announced
						# targets resolve INDEPENDENTLY in printed order — each
						# is re-checked (706 / glossary 4217, plus still-an-ally)
						# on its own, so killing or bouncing one target in
						# response fizzles only that half of the card. Picking
						# the same ally for both slots nets 0, as printed.
						events.append_array(_apply_atk_swing(state, action, def, card_id, db))
					"exhaust_target":
						# "Exhaust target ally." (Exhaustion) or "Exhaust target hero
						# or ally." (hero_or_ally variant). Re-check at resolution
						# (706): fizzles if the target left play / became Untargetable.
						# exhaust_card no-ops if it's already exhausted. Played in
						# response to a combat proposal and aimed at the attacker, the
						# 601.3 recheck then fizzles the proposal (attacker not ready).
						if _exhaust_target_ok(state, parts, target_id, db):
							events.append_array(GameLogic.exhaust_card(state, target_id))
							# Gouge: "It can't ready during its controller's next
							# ready step." Flag the target — consumed at that ready
							# step (TurnManager._enter_ready). Applies even if the
							# target was already exhausted.
							if _has_effect_flag(def, "gouge_cant_ready"):
								state.get_card(target_id).counters["gouge_skip_ready"] = 1
								events.append(GameEvent.make("card_ready_locked",
										{"card_id": target_id, "source_id": card_id}))
					"grant_keyword_target":
						# "Target ally has <keyword> this turn." — Sneak
						# (elusive, any ally) / Into the Fray (ferocity, your
						# party only). Buff-granted with duration turns:1 so the
						# normal end-of-turn sweep expires it and leaving play
						# clears it; read by _has_keyword ("grant_<keyword>").
						# Re-check at resolution (706 / glossary 4217): fizzles
						# if the target left play or became Untargetable.
						if _grant_keyword_target_ok(state, parts, target_id,
								action.source_player, db):
							var gk_word := parts[2].strip_edges() if parts.size() > 2 else ""
							if gk_word != "":
								state.get_card(target_id).active_buffs.append(
									Buff.make("granted_" + gk_word, card_id,
										"grant_" + gk_word, 1, "turns", 1))
								events.append(GameEvent.keyword_granted(
									target_id, gk_word, card_id))
					"return_to_hand":
						# "Put target ally into its owner's hand." (Withdraw), or
						# "...from your party" friendly-only (Fall Back).
						# Re-check at resolution (706): fizzles if the ally left
						# play / became Untargetable. move_card destroys any
						# attachments on it (400.5) and, if it was a proposed
						# attacker/defender on the chain, the proposal's 601.3
						# recheck fizzles the combat.
						var rth_friendly_ok := parts.size() < 2 \
								or parts[1] != "friendly_ally" \
								or (state.get_card(target_id) != null \
									and state.get_card(target_id).controller \
										== state.get_card(card_id).controller)
						if _is_legal_target(state, target_id, db) \
								and _is_ally(state, target_id) and rth_friendly_ok:
							var rth_card := state.get_card(target_id)
							events.append_array(GameLogic.move_card(
								state, target_id, rth_card.owner + "_hand"))
							events.append(GameEvent.card_returned_to_hand(
								target_id, card_id))
					"heal_target":
						# "Your hero heals N damage from target hero or ally."
						# (Natural Selection heal mode). Re-check at resolution
						# (706): fizzles if the target left play / became
						# Untargetable. heal() no-ops on an undamaged target.
						var heal_amount := int(parts[1]) if parts.size() > 1 else 0
						if heal_amount > 0 and _is_legal_target(state, target_id, db):
							events.append_array(GameLogic.heal(
								state, target_id, heal_amount, db, card_id))
					"deal_damage_to_target":
						# "Your hero deals N <type> damage to target hero or ally."
						# (Quick Strike). Target is announced at play time (rule 601-style;
						# gives humans cancellable targeting). The HERO is the damage
						# source per the card text, not this ability card. If the target
						# left play before resolution, the damage fizzles (711.1) and the
						# card still goes to the graveyard below.
						# AMOUNT literal "X" (Aimed Shot, cost 1+X): the announced
						# x_value paid at submission is the damage dealt.
						var amount: int
						if parts.size() > 1 and parts[1].strip_edges() == "X":
							amount = int(action.params.get("x_value", 0))
						else:
							amount = int(parts[1]) if parts.size() > 1 else 0
						var ps := state.players.get(action.source_player) as PlayerState
						var hero_id: String = ps.hero_instance_id if ps else ""
						if hero_id != "" and amount > 0 \
								and _is_legal_target(state, target_id, db):
							# Packet pipeline (717.2c): the paired riders — drain
							# heal (Steal Essence), discard-per-damage (Mind
							# Spike/Blast), restriction riders (Frostbolt / Frost
							# Shock) — travel WITH the packet so they run after the
							# prevention point, reading the damage actually dealt.
							events.append_array(defer_packets(state, db, [{
								"source": hero_id, "target": target_id,
								"amount": amount,
								"dmg_type": parts[2].to_lower().strip_edges() if parts.size() > 2 else "",
								"drain_heal_per": _drain_heal_per_damage(def),
								"drain_heal_to": hero_id,
								"discard_per": _discard_per_damage(def),
								"riders": parts[3] if parts.size() > 3 else "",
								"from_ability": true,
							}]))
					"deal_damage_and_heal":
						# Shock and Soothe: "Your hero deals N <type> damage to
						# target hero or ally and heals M damage from another
						# target hero or ally." Recipe
						# deal_damage_and_heal:DMG:TYPE:HEAL — same key as the
						# Grennan hero power. The two announced targets resolve
						# INDEPENDENTLY, each re-checked (706 / glossary 4217),
						# so answering one of them in response fizzles only that
						# half. The heal is unconditional (not per-damage) and
						# lands inline; the damage packet goes through the
						# prevention pipeline (`from_ability` — Chromatic Cloak's
						# +1 applies, World in Flames doubles a fire version).
						var dh_dmg  := int(parts[1]) if parts.size() > 1 else 0
						var dh_heal := int(parts[3]) if parts.size() > 3 else 0
						var dh_ps := state.players.get(action.source_player) as PlayerState
						var dh_hero: String = dh_ps.hero_instance_id if dh_ps else ""
						var dh_heal_id: String = action.params.get("heal_target_id", "")
						if dh_hero != "":
							if dh_heal > 0 and _is_legal_target(state, dh_heal_id, db):
								events.append_array(GameLogic.heal(
									state, dh_heal_id, dh_heal, db, dh_hero))
							if dh_dmg > 0 and _is_legal_target(state, target_id, db):
								events.append_array(defer_packets(state, db, [{
									"source": dh_hero, "target": target_id,
									"amount": dh_dmg,
									"dmg_type": parts[2].to_lower().strip_edges() if parts.size() > 2 else "",
									"from_ability": true,
								}]))
					"chain_lightning":
						# "Your hero deals A1 <type> damage to target hero or ally. Your
						# hero may deal A2 <type> damage to another hero or ally. Your
						# hero may deal A3 <type> damage to another hero or ally."
						# (Chain Lightning). Up to 3 targets are announced at play time
						# (target_id/target_id_2/target_id_3); each wave resolves in
						# printed order, with its own destruction/game-over check before
						# the next wave — a target destroyed by an earlier wave simply
						# can't be hit again (711.1), it doesn't invalidate the cast.
						var cl_amounts: Array[int] = [
							int(parts[1]) if parts.size() > 1 else 0,
							int(parts[2]) if parts.size() > 2 else 0,
							int(parts[3]) if parts.size() > 3 else 0,
						]
						var cl_ps := state.players.get(action.source_player) as PlayerState
						var cl_hero_id: String = cl_ps.hero_instance_id if cl_ps else ""
						var cl_targets := _chain_lightning_targets(action)
						if cl_hero_id != "":
							var cl_packets: Array = []
							for i in cl_targets.size():
								var cl_target_id: String = cl_targets[i]
								var cl_amount: int = cl_amounts[i] if i < cl_amounts.size() else 0
								# Rule 706 re-check per wave. Waves 2/3 select rather
								# than target (card-specific exception), so only the
								# 1st wave also fizzles on became-Untargetable.
								if cl_amount <= 0 \
										or not _is_legal_target(state, cl_target_id, db, i > 0):
									continue
								cl_packets.append({"source": cl_hero_id,
									"target": cl_target_id, "amount": cl_amount,
									"from_ability": true})
							# Packet pipeline: waves land in printed order with their
							# own destroy check; a target killed by an earlier wave
							# is skipped at land time (711.1).
							events.append_array(defer_packets(state, db, cl_packets))
					"divided_damage":
						# "Your hero deals X nature damage divided as you choose to
						# any number of target allies." (Lightning Storm). The X
						# picks announced in `target_ids` (one per point, repeats
						# allowed) are tallied per ally and land as ONE packet each,
						# in first-pick order — so a triple-picked ally takes a
						# single 3-damage hit, and the replacement effects
						# (Chromatic Cloak, World in Flames) apply once per target
						# rather than once per point.
						# Each target is re-checked on its own (706 / glossary
						# 4217): killing or bouncing one in response fizzles only
						# that ally's share, the rest of the division still lands.
						var dd_type := parts[2].to_lower().strip_edges() if parts.size() > 2 else ""
						var dd_ps := state.players.get(action.source_player) as PlayerState
						var dd_hero: String = dd_ps.hero_instance_id if dd_ps else ""
						if dd_hero != "":
							var dd_order: Array[String] = []
							var dd_tally := {}
							for dd_tid in action.params.get("target_ids", []):
								if not dd_tally.has(dd_tid):
									dd_order.append(dd_tid)
									dd_tally[dd_tid] = 0
								dd_tally[dd_tid] += 1
							var dd_packets: Array = []
							for dd_tid in dd_order:
								if not _is_legal_target(state, dd_tid, db) \
										or not _is_ally(state, dd_tid):
									continue
								dd_packets.append({"source": dd_hero, "target": dd_tid,
									"amount": int(dd_tally[dd_tid]), "dmg_type": dd_type,
									"from_ability": true})
							events.append_array(defer_packets(state, db, dd_packets))
					"multi_shot":
						# "Your hero deals N ranged damage to each of up to three
						# target heroes and/or allies." (Multi-Shot). Recipe
						# multi_shot:N:TYPE. Up to 3 targets announced at play time
						# (target_id/_2/_3); each takes the same N damage, resolved in
						# printed order with its own destruction/game-over check (a
						# target killed by an earlier wave just can't be hit again,
						# 711.1). All slots select rather than target, so every wave
						# allows an Untargetable target (706 exception — see CLAUDE.md).
						var ms_amount := int(parts[1]) if parts.size() > 1 else 0
						var ms_ps := state.players.get(action.source_player) as PlayerState
						var ms_hero_id: String = ms_ps.hero_instance_id if ms_ps else ""
						var ms_targets := _chain_lightning_targets(action)
						if ms_hero_id != "" and ms_amount > 0:
							var ms_packets: Array = []
							for ms_target_id in ms_targets:
								if not _is_legal_target(state, ms_target_id, db, true):
									continue
								ms_packets.append({"source": ms_hero_id,
									"target": ms_target_id, "amount": ms_amount,
									"from_ability": true})
							events.append_array(defer_packets(state, db, ms_packets))
					"interrupt_ability":
						# "Interrupt target ability card that's targeting your
						# hero." (Escape Artist, rule 711.) Re-checked at
						# resolution like every other target (706 / glossary
						# 4217): the link may have been interrupted by something
						# else, or retargeted off our hero, in which case this
						# fizzles. Costs the interrupted link paid are NOT
						# refunded (711.2).
						if _is_interrupt_target(state, db, action.source_player,
								target_id, card_id):
							events.append_array(_interrupt_link(state, target_id,
									card_id, db))
						else:
							events.append(GameEvent.make("action_fizzled", {
								"card_id": card_id, "reason": "interrupt_target_gone",
							}))
					"remove_attackers":
						# "If your hero is defending, remove all attackers from combat."
						# (Blink). Condition token (parts[1]) picks WHO must be
						# defending: "hero_defending" = the caster's hero is the
						# current defender (602.3 — defending exists only after the
						# protect point, so the defend window must be open; during
						# the attack window the hero is merely a PROPOSED defender
						# and the clause is a no-op). Rule 602.4: removing the
						# attacker doesn't end the combat step immediately — the
						# window plays out, and the conclusion's 603.1b check then
						# deals no damage. The attacker stays exhausted (it
						# exhausted when the attack was proposed). Our combats are
						# 1-on-1, so "all attackers" = the single attacker.
						var ra_cond := parts[1].strip_edges() if parts.size() > 1 else "hero_defending"
						var ra_ps := state.players.get(action.source_player) as PlayerState
						var ra_hero: String = ra_ps.hero_instance_id if ra_ps else ""
						if ra_cond == "hero_defending" \
								and state.combat_defend_window \
								and state.combat_attacker != "" \
								and state.combat_defender == ra_hero:
							var removed := state.combat_attacker
							state.combat_attacker = ""
							events.append(GameEvent.attacker_removed_from_combat(
								removed, card_id))
					"exhaust_all_opposing":
						# "Exhaust all opposing heroes and allies." (War Stomp).
						# Non-targeted mass exhaust — hits Untargetable characters
						# (706 restricts targets of links only) and needs no
						# announce. exhaust_card no-ops on already-exhausted cards.
						# Played in response to an opposing combat proposal on the
						# chain, exhausting the attacker fizzles the proposal via
						# the 601.3 recheck — same interrupt as Exhaustion/Bash,
						# but board-wide. The `requires_hero_race` segment on the
						# same card is deck legality only (100.2b, DeckManager).
						var ws_opp := _other_player(state, action.source_player)
						var ws_opp_ps := state.players.get(ws_opp) as PlayerState
						if ws_opp_ps and ws_opp_ps.hero_instance_id != "":
							events.append_array(GameLogic.exhaust_card(
								state, ws_opp_ps.hero_instance_id))
						for ws_ally in state.cards_in_zone(ws_opp + "_ally_row"):
							events.append_array(GameLogic.exhaust_card(
								state, ws_ally.instance_id))
					"rapid_fire_ready_on_strike":
						# Rapid Fire: "Whenever you strike with a Ranged weapon this
						# turn, you may pay (1). If you do, ready that weapon and your
						# hero." A player-wide, this-turn grant (not an attachment like
						# Windfury Weapon), so it is tracked on PlayerState and cleared
						# at the start of every turn. Deliberately NOT once per turn —
						# "whenever" is the whole point of the card, so the strike-ready
						# point skips Windfury's once-per-turn gate on this path.
						# Forward-looking only: strikes already made this turn are past.
						var rf_cost := int(parts[1]) if parts.size() > 1 else 0
						var rf_ps := state.players.get(action.source_player) as PlayerState
						if rf_ps:
							# Cheapest grant wins if somehow granted twice.
							if rf_ps.rapid_fire_ready_cost < 0 \
									or rf_cost < rf_ps.rapid_fire_ready_cost:
								rf_ps.rapid_fire_ready_cost = rf_cost
							events.append(GameEvent.rapid_fire_gained(
								action.source_player, rf_cost))
					"next_card_cost_mod":
						# Nature's Swiftness: "You pay (5) less to play your next
						# card this turn." Recipe `next_card_cost_mod:-5`. A
						# one-shot, player-wide, this-turn grant (like Rapid Fire's
						# and Cold Blood's), so it lives on PlayerState and is
						# cleared at the start of every turn. It is read live inside
						# GameState.get_play_cost — the choke point every cost path
						# uses — and consumed by the next card that reaches the
						# chain (412.2, see submit_action). Forward-looking: cards
						# already played this turn are past. The BEST (largest)
						# discount wins if somehow granted twice; they don't stack,
						# since each grant is about "your next card".
						# "Restoration Hero Required" is the Talent-spec restriction
						# the deck authorizer enforces via rule 100.2c, not a gate
						# here.
						var ncd_amt := int(parts[1]) if parts.size() > 1 else 0
						var ncd_ps3 := state.players.get(action.source_player) as PlayerState
						if ncd_ps3 and ncd_amt != 0:
							if ncd_amt < ncd_ps3.next_card_cost_mod:
								ncd_ps3.next_card_cost_mod = ncd_amt
							events.append(GameEvent.next_card_discount_gained(
								action.source_player, ncd_amt))
					"hero_damage_destroys_ally_this_turn":
						# Cold Blood: "When your hero deals damage to an ally this
						# turn, destroy that ally." A player-wide, this-turn grant
						# (like Rapid Fire's), so it is tracked on PlayerState and
						# cleared at the start of every turn. ANY damage counts, not
						# just combat — so rather than a new hook per damage source
						# it is evaluated off the turn event log (see
						# game_logic/turn_state_flags.md), which every damage source
						# already feeds by construction. Storing the log index makes
						# the trigger forward-looking, as printed: an ally the hero
						# damaged EARLIER this turn is not retroactively doomed.
						var cb_ps := state.players.get(action.source_player) as PlayerState
						if cb_ps:
							# Earliest grant wins if somehow granted twice this turn.
							if cb_ps.cold_blood_from_index < 0:
								cb_ps.cold_blood_from_index = state.turn_events.size()
							events.append(GameEvent.make("cold_blood_gained",
								{"player_id": action.source_player, "source_id": card_id}))
					"draw":
						# "Draw a card." (Arcane Shot) — unconditional, no target needed.
						var draw_n := int(parts[1]) if parts.size() > 1 else 1
						for _i in draw_n:
							events.append_array(_draw_one(state, action.source_player))
					"graveyard_to_play":
						# Ancestral Spirit: "Put target ally card from your graveyard
						# into play if its cost <= the number of resources you have.
						# That ally enters play with damage equal to its health − 1."
						# The single target was announced at play time. Re-check at
						# resolution (rule 706-style): it must still be an ally card in
						# the caster's graveyard whose cost is within the (current)
						# resource cap, else the reanimation fizzles (711.1). Optional
						# 7th recipe field = damage-on-enter mode.
						var rz_req := get_graveyard_search_requirement(def)
						var rz_cands := get_graveyard_search_candidates(
								state, action.source_player, rz_req, db)
						if target_id in rz_cands:
							var rz_card := state.get_card(target_id)
							if rz_card:
								rz_card.controller = action.source_player
								events.append_array(
										_bring_ally_into_play(state, target_id, db))
								# "…enters play with damage on it equal to its health
								# −1." A starting condition, not dealt damage — set
								# directly (no source, no prevention, and health−1
								# never destroys it). Read max HP AFTER it's in play so
								# any live auras/buffs are included.
								if rz_req.get("damage_mode", "") == "health_minus_1" \
										and state.is_in_play(target_id):
									var rz_hp := state.get_max_hp(target_id, db)
									rz_card.damage_taken = max(rz_hp - 1, 0)
									events.append(GameEvent.make(
										"card_entered_with_damage", {
											"card_id": target_id,
											"damage": rz_card.damage_taken,
										}))
					"graveyard_to_rfg":
						# Cannibalize: "Remove any number of ally cards in
						# graveyards from the game. Your hero heals 2 damage from
						# itself for each card removed." The cards were announced
						# with the play as `target_ids`; each is re-checked here
						# (706-style) and skipped if it already left its graveyard,
						# so the heal scales with what was ACTUALLY removed — the
						# "for each card removed" rider, not the announced count.
						var gr_removed := 0
						for gr_id in action.params.get("target_ids", []):
							var gr_card := state.get_card(gr_id)
							if not gr_card:
								continue
							var gr_zone := state.zones.get(gr_card.zone_id) as Zone
							if not gr_zone or gr_zone.zone_type != "graveyard":
								continue
							events.append_array(GameLogic.move_card(
									state, gr_id, gr_card.owner + "_rfg"))
							events.append(GameEvent.card_removed_from_game(
									gr_id, action.source_player))
							gr_removed += 1
						var gr_heal := rfg_heal_per_card(def)
						if gr_removed > 0 and gr_heal > 0:
							var gr_ps := state.players.get(action.source_player) as PlayerState
							var gr_hero: String = gr_ps.hero_instance_id if gr_ps else ""
							if gr_hero != "":
								events.append_array(GameLogic.heal(state, gr_hero,
										gr_heal * gr_removed, db, card_id))
					"deal_damage_aoe_opponent":
						# "Your hero deals N <type> damage to each opposing hero and
						# ally." (Flamestrike) — no target needed, hits every
						# character the opponent controls.
						var aoe_amount := int(parts[1]) if parts.size() > 1 else 0
						var ps2 := state.players.get(action.source_player) as PlayerState
						var hero_id2: String = ps2.hero_instance_id if ps2 else ""
						var opp2 := _other_player(state, action.source_player)
						var opp_targets: Array[String] = []
						var opp_ps2 := state.players.get(opp2) as PlayerState
						if opp_ps2 and opp_ps2.hero_instance_id != "":
							opp_targets.append(opp_ps2.hero_instance_id)
						for opp_ally in state.cards_in_zone(opp2 + "_ally_row"):
							opp_targets.append(opp_ally.instance_id)
						if hero_id2 != "" and aoe_amount > 0:
							var aoe_packets: Array = []
							for t_id in opp_targets:
								aoe_packets.append({"source": hero_id2,
									"target": t_id, "amount": aoe_amount,
									"dmg_type": parts[2].to_lower().strip_edges() if parts.size() > 2 else "",
									"from_ability": true})
							events.append_array(defer_packets(state, db, aoe_packets))
	# Move used instant to its owner's graveyard (card is currently in chain zone).
	var card2 := state.get_card(card_id)
	if card2:
		events.append_array(GameLogic.move_card(state, card_id, card2.owner + "_graveyard"))
	# Forms: "Destroy this card when you … play a non-Feral ability." Every card
	# resolved here is an Ability (instant or not), so playing it may break the
	# player's in-play Form(s) — checked by tag (see _check_form_break_ability).
	if db and card2:
		var played_def := db.get_def(card2.card_def_id) as CardDef
		events.append_array(_check_form_break_ability(state, action.source_player, played_def, db))
	return events


static func _resolve_place_resource(state: GameState,
		action: PendingAction) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var face_up: bool   = action.params.get("face_up", false)
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled", {
			"action_type": "place_resource", "reason": "card_not_found",
		})]
	var events: Array[GameEvent] = []
	card.face_down = not face_up
	events.append_array(GameLogic.move_card(state, card_id, card.controller + "_resource_row"))
	events.append(GameEvent.make("resource_placed", {
		"card_id": card_id, "player": card.controller, "face_up": face_up,
	}))
	return events


# Exhaust resources to pay a card's play cost (rule 412.2).
# Auto-selects ready resources; face-up/face-down both valid.
# x = announced X for X-cost cards (0 otherwise).
static func _pay_cost(state: GameState, card_id: String,
		player_id: String, db, x: int = 0) -> Array[GameEvent]:
	if not db:
		return []
	var cost: int = state.get_play_cost(card_id, db, x)
	if cost <= 0:
		return []
	var events: Array[GameEvent] = []
	for res_card in state.cards_in_zone(player_id + "_resource_row"):
		if cost <= 0:
			break
		if not res_card.is_exhausted:
			events.append_array(GameLogic.exhaust_card(state, res_card.instance_id))
			cost -= 1
	return events


# Pay an arbitrary resource cost (used for activated powers whose cost isn't the card's play cost).
static func _pay_resource_cost(state: GameState, player_id: String,
		amount: int) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var remaining := amount
	for res_card in state.cards_in_zone(player_id + "_resource_row"):
		if remaining <= 0:
			break
		if not res_card.is_exhausted:
			events.append_array(GameLogic.exhaust_card(state, res_card.instance_id))
			remaining -= 1
	return events


# Parse the first "activated_power" segment from a CardDef's effects string.
# Returns {} if none found.
static func _ally_activated_power(def: CardDef) -> Dictionary:
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "activated_power":
			# extra_cost may itself carry a colon-separated amount (e.g.
			# "put_damage_self:1"), so rejoin everything past field 6.
			var extra_parts := parts.slice(6) if parts.size() > 6 else PackedStringArray()
			# "Chipper" Ironbane: the printed cost is X, announced with the power
			# as x_value (like Aimed Shot's X-cost play). resource_cost stays 0 —
			# call power_resource_cost(ap, x_value) rather than reading the field
			# directly, so every pay/refund/afford site agrees on the real price.
			var cost_is_x: bool = parts.size() > 1 and parts[1].strip_edges() == "X"
			return {
				"cost_x":        cost_is_x,
				"resource_cost": 0 if cost_is_x else (int(parts[1]) if parts.size() > 1 else 0),
				"effect":        parts[2] if parts.size() > 2 else "",
				"amount":        int(parts[3]) if parts.size() > 3 else 0,
				"dmg_type":      parts[4] if parts.size() > 4 else "",
				"targets":       parts[5] if parts.size() > 5 else "",
				"extra_cost":    ":".join(extra_parts) if extra_parts.size() > 0 else "",
			}
	return {}


# The resource cost an activated power actually charges. Fixed for every power
# printed so far; for an X-cost power ("Chipper" Ironbane) it's the x_value
# announced with the action. The ONE place the two cases are reconciled — pay
# (submit_action), refund (retract_last), affordability (_can_use_ally_power)
# and the UI's enable/highlight probes all go through it.
static func power_resource_cost(ap: Dictionary, x_value: int) -> int:
	if bool(ap.get("cost_x", false)):
		return max(x_value, 0)
	return int(ap.get("resource_cost", 0))


# "Chipper" Ironbane: "(X), Destroy [this] -> Destroy target ability or
# equipment with cost X." X is not a free choice — any legal announce has
# X == the target's PRINTED cost (never a modified one: an in-play card was
# paid for long ago, exactly as with Trophy Kill's cost band). So the power is
# really "pick a target you can afford, pay its cost", and the UI derives X
# from the target instead of asking for it.
static func power_cost_matches_target(ap: Dictionary, state: GameState,
		target_id: String, x_value: int, db) -> bool:
	if not bool(ap.get("cost_x", false)):
		return true
	var card := state.get_card(target_id)
	if not card or db == null:
		return false
	var t_def := db.get_def(card.card_def_id) as CardDef
	return t_def != null and x_value == printed_cost(t_def)


# Parse the "equipment:SLOT:DEF[:CAPACITY]" segment from a CardDef's effects string.
# Returns {} if the card isn't equipment (per its recipe).
static func _equipment_info(def: CardDef) -> Dictionary:
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "equipment":
			return {
				"slot": (parts[1].strip_edges() if parts.size() > 1 else "").to_lower(),
				"def":  int(parts[2]) if parts.size() > 2 else 0,
				# Rule 414.3b: the number in parentheses on the type line — how many
				# cards with that slot tag a player may control. Every armor/weapon
				# slot printed so far is "(1)", so the field is optional and defaults
				# to 1; Ramstein's Lightning Bolts is Trinket (2).
				"capacity": max(1, int(parts[3])) if parts.size() > 3 else 1,
			}
	return {}


# ── Weapons and striking (rules 303, 602.1, 602.3) ────────────────────────────
#
# Effects segment "strike_cost:STRIKE_COST" marks an Equipment card as a weapon
# (alongside its "equipment:SLOT:DEF" segment, which drives play + slot
# uniqueness). The weapon's ATK is the CSV atk column; damage type is the CSV
# dmg_type column ("Melee" gates Gorebelly's strike discount).
#
# Striking (303.2) doesn't use the chain: at exactly two moments — as the
# combat step starts for the attacking player (602.1) and as the defender
# enters combat for the defending player (602.3) — a hero's controller may
# exhaust a weapon + pay its strike cost to associate it with that hero for
# the combat. While associated, the hero gets +weapon ATK (303.2b, live in
# GameState.get_atk). Only heroes are wielders; the hero may be exhausted;
# one weapon per combat (303.2c).

# Parse the "strike_cost:STRIKE_COST" segment. Returns {} if the card isn't a weapon.
static func _weapon_info(def: CardDef) -> Dictionary:
	if not def:
		return {}
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "strike_cost":
			return {"strike_cost": int(parts[1]) if parts.size() > 1 else 0}
	return {}


# Effective strike cost for player_id (applies the pending melee discount and
# any live strike-cost auras). `db` is optional so the aura is skipped rather
# than crashing on the few probe call sites that have no database handy.
static func get_strike_cost(state: GameState, player_id: String, def: CardDef,
		db = null) -> int:
	var info := _weapon_info(def)
	if info.is_empty():
		return -1
	var cost: int = info.get("strike_cost", 0)
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.melee_strike_discount > 0 and def.dmg_type.to_lower() == "melee":
		cost = max(0, cost - ps.melee_strike_discount)
	cost += _strike_cost_aura(state, player_id, db)
	return max(0, cost)


# Margaret Fowl (dark_portal_179): "You pay 1 less to strike with weapons.
# Opponents pay 1 more to strike with weapons." (`strike_cost_mod:SELF:OPPOSING`)
# Read LIVE off every in-play card of both players — never cached, so it covers
# weapons equipped after the aura and lifts the instant the source leaves play.
# Unlike Gorebelly's melee discount this applies to ANY weapon (the card says
# "weapons") and is not consumed by striking. Stacks per copy.
static func _strike_cost_aura(state: GameState, player_id: String, db) -> int:
	if not db:
		return 0
	var total := 0
	for pid in state.players.keys():
		var is_self: bool = (pid == player_id)
		for zone_suffix in ["_ally_row", "_hero_row"]:
			for card in state.cards_in_zone(pid + zone_suffix):
				var cdef := db.get_def(card.card_def_id) as CardDef
				if not cdef:
					continue
				for segment in cdef.effects.split("|"):
					var parts := segment.split(":")
					if parts[0] != "strike_cost_mod" or parts.size() < 3:
						continue
					total += int(parts[1]) if is_self else int(parts[2])
	return total


# Weapons player_id could strike with right now for the given wielder:
# ready weapons in the hero row whose (discounted) strike cost is affordable.
# Empty if the wielder isn't that player's hero or already struck this combat
# (303.2c — one weapon per combat).
static func get_strikeable_weapons(state: GameState, player_id: String,
		wielder_id: String, db) -> Array[String]:
	var result: Array[String] = []
	if not db:
		return result
	var ps := state.players.get(player_id) as PlayerState
	# Only heroes are wielders (303.2), and only the hero's own controller strikes.
	if not ps or ps.hero_instance_id != wielder_id:
		return result
	if not (state.combat_struck_weapons.get(wielder_id, []) as Array).is_empty():
		return result
	var available := state.get_available_resources(player_id)
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if card.is_exhausted:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		var cost := get_strike_cost(state, player_id, def, db)
		if cost >= 0 and cost <= available:
			result.append(card.instance_id)
	return result


# Opens a strike point for the wielder's controller if any strike is possible.
# Returns [] (and leaves state untouched) when there's nothing to offer, so
# callers fall through to opening the attack/defend window directly.
static func _open_strike_point(state: GameState, wielder_id: String,
		side: String, db) -> Array[GameEvent]:
	var wielder := state.get_card(wielder_id)
	if not wielder:
		return []
	var weapons := get_strikeable_weapons(state, wielder.controller, wielder_id, db)
	if weapons.is_empty():
		return []
	state.pending_strike_player     = wielder.controller
	state.pending_strike_weapon_ids = weapons
	state.pending_strike_side      = side
	return [GameEvent.strike_point_opened(wielder.controller, wielder_id, weapons, side)]


# Entry point for the strike decision (NOT chain-based — called directly by the
# scene, like choose_protector). weapon_id == "" means decline to strike.
# Pays the cost (exhaust weapon + resources, 303.2), records the association,
# then opens the window the strike point was holding up.
static func choose_strike(state: GameState, weapon_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_strike_player == "":
		return []
	var player_id := state.pending_strike_player
	var side      := state.pending_strike_side
	var offered   := state.pending_strike_weapon_ids
	state.pending_strike_player     = ""
	state.pending_strike_weapon_ids = []
	state.pending_strike_side       = ""

	var events: Array[GameEvent] = []
	var wielder_id := state.combat_attacker if side == "attack" else state.combat_defender
	if weapon_id != "" and weapon_id in offered and state.is_in_play(weapon_id) \
			and state.is_in_play(wielder_id) and db:
		var weapon := state.get_card(weapon_id)
		var def := db.get_def(weapon.card_def_id) as CardDef
		var cost := get_strike_cost(state, player_id, def, db)
		if cost >= 0 and cost <= state.get_available_resources(player_id) \
				and not weapon.is_exhausted:
			var ps := state.players.get(player_id) as PlayerState
			if ps and ps.melee_strike_discount > 0 and def.dmg_type.to_lower() == "melee":
				ps.melee_strike_discount = 0   # "the next time" — consumed
			events.append_array(GameLogic.exhaust_card(state, weapon_id))
			if cost > 0:
				events.append_array(_pay_resources(state, player_id, cost))
			var struck: Array = state.combat_struck_weapons.get(wielder_id, [])
			struck.append(weapon_id)
			state.combat_struck_weapons[wielder_id] = struck
			events.append(GameEvent.weapon_struck(player_id, wielder_id, weapon_id, cost))
			# "Destroy this card when you strike with a weapon" — the striking
			# player's Forms break now (their pay-return trigger may open).
			events.append_array(_check_form_break_strike(state, player_id, db))
			# Windfury Weapon: "When you strike with attached weapon for the first
			# time each turn, you may pay 1. If you do, ready that weapon and your
			# hero." Opens a pending choice BEFORE the held window (like the
			# ready-on-attack point). Resolved via choose_ready_on_strike().
			var sr := _open_strike_ready_point(state, weapon_id, side, db)
			if not sr.is_empty():
				events.append_array(sr)
				return events

	# Open the window this strike point was holding up.
	if side == "attack":
		state.combat_attack_window = true
		events.append(GameEvent.attack_window_opened(
			state.combat_attacker, state.combat_defender))
	else:
		state.combat_defend_window = true
		events.append(GameEvent.defend_window_opened(
			state.combat_attacker, state.combat_defender))
	return events


# Opens a ready-on-strike point for the striking player. Two independent sources
# grant the same offer:
#   • Windfury Weapon — a `ready_on_strike:COST` ATTACHMENT on the struck weapon,
#     "for the first time each turn": gated by the weapon's
#     `windfury_struck_this_turn` counter, marked fired whether or not they pay.
#   • Rapid Fire — a this-turn grant on the striking PLAYER covering every Ranged
#     weapon (PlayerState.rapid_fire_ready_cost), "whenever": deliberately NOT
#     gated, so repeat strikes each get the offer. That is the card's entire
#     purpose, so it must not consume or check Windfury's counter.
# The two stay independent: a Windfury-attached Ranged weapon under Rapid Fire
# gets Windfury's (free of the gate) first offer and a Rapid Fire offer on every
# later strike. The cheaper cost is offered when both apply to the same strike.
# Only offered when the controller can afford it. Returns [] when nothing to
# offer, so choose_strike falls through to opening the combat window. Resolved
# immediately (not on the chain) — see data/rules_deviations.md "Windfury Weapon".
static func _open_strike_ready_point(state: GameState, weapon_id: String,
		side: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var weapon := state.get_card(weapon_id)
	if not weapon:
		return []
	var cost := -1
	for att_id in weapon.attachments:
		var att := state.get_card(att_id)
		if not att:
			continue
		var adef := db.get_def(att.card_def_id) as CardDef
		if not adef or adef.effects == "":
			continue
		for seg in adef.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0].strip_edges() == "ready_on_strike":
				var c := int(p[1]) if p.size() > 1 else 0
				if cost < 0 or c < cost:
					cost = c
	if cost >= 0:
		# "for the first time each turn" — the ATTACHMENT offer is once per turn
		# per weapon. Fired whether or not they pay.
		if int(weapon.counters.get("windfury_struck_this_turn", 0)) > 0:
			cost = -1
		else:
			weapon.counters["windfury_struck_this_turn"] = 1
	# Rapid Fire: any Ranged weapon this player strikes with, ungated.
	var rf_ps := state.players.get(weapon.controller) as PlayerState
	if rf_ps and rf_ps.rapid_fire_ready_cost >= 0:
		var wdef := db.get_def(weapon.card_def_id) as CardDef
		if wdef and wdef.dmg_type.to_lower() == "ranged":
			if cost < 0 or rf_ps.rapid_fire_ready_cost < cost:
				cost = rf_ps.rapid_fire_ready_cost
	if cost < 0:
		return []
	if state.get_available_resources(weapon.controller) < cost:
		return []
	state.pending_strike_ready_player    = weapon.controller
	state.pending_strike_ready_weapon_id = weapon_id
	state.pending_strike_ready_cost      = cost
	state.pending_strike_ready_side      = side
	return [GameEvent.ready_on_strike_opened(weapon.controller, weapon_id, cost)]


# Entry point for the ready-on-strike decision (NOT chain-based — called directly
# by the scene, like choose_ready_on_attack). pay == false means decline. Pays
# the cost, readies the struck weapon AND the striking hero, then opens the held
# combat window (the one choose_strike was holding up).
static func choose_ready_on_strike(state: GameState, pay: bool,
		db = null) -> Array[GameEvent]:
	if state.pending_strike_ready_player == "":
		return []
	var player_id := state.pending_strike_ready_player
	var weapon_id := state.pending_strike_ready_weapon_id
	var cost      := state.pending_strike_ready_cost
	var side      := state.pending_strike_ready_side
	state.pending_strike_ready_player    = ""
	state.pending_strike_ready_weapon_id = ""
	state.pending_strike_ready_cost      = 0
	state.pending_strike_ready_side      = ""

	var events: Array[GameEvent] = []
	if pay and state.is_in_play(weapon_id) \
			and state.get_available_resources(player_id) >= cost:
		if cost > 0:
			events.append_array(_pay_resources(state, player_id, cost))
		events.append_array(GameLogic.ready_card(state, weapon_id))
		var ps := state.players.get(player_id) as PlayerState
		if ps and ps.hero_instance_id != "" and state.is_in_play(ps.hero_instance_id):
			events.append_array(GameLogic.ready_card(state, ps.hero_instance_id))
		events.append(GameEvent.readied_on_strike(player_id, weapon_id, cost))

	# Open the combat window this strike (and its ready point) was holding up.
	if side == "attack":
		state.combat_attack_window = true
		events.append(GameEvent.attack_window_opened(
			state.combat_attacker, state.combat_defender))
	else:
		state.combat_defend_window = true
		events.append(GameEvent.defend_window_opened(
			state.combat_attacker, state.combat_defender))
	return events


# ── Armor damage prevention (rule 717.2c) ─────────────────────────────────────
#
# Each ready equipment with DEF > 0 generates an optional prevention modifier:
# when a preventable damage packet would be dealt to its controller's hero
# (heroes are the only shielders), the controller may exhaust it to reduce the
# packet by its DEF — and may keep exhausting further armor while the packet
# still has damage left. None of this uses the chain: the decision point opens
# at the moment the packet would land (combat conclusion / just before a
# hero-damaging chain link resolves) and is resolved via choose_prevention()
# (direct call, like the strike point). Excess DEF beyond the packet is wasted;
# armor can't be exhausted for future damage. No summoning-sickness check
# ("regardless of how long it's been under your control").

# Ready DEF>0 equipment in player's hero_row — the exhaustable shielder pool.
static func get_ready_def_armor(state: GameState, player_id: String,
		db) -> Array[String]:
	var ids: Array[String] = []
	if not db:
		return ids
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if card.is_exhausted:
			continue
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.card_type != "Equipment":
			continue
		if int(_equipment_info(def).get("def", 0)) > 0:
			ids.append(card.instance_id)
	return ids


# An offer dict for a packet about to hit `target_id`, or {} when the target
# isn't an in-play hero / no damage / its controller has no ready DEF armor.
static func _prevention_offer(state: GameState, db, target_id: String,
		amount: int, source_id: String, unpreventable: bool = false) -> Dictionary:
	if amount <= 0 or not state.is_in_play(target_id):
		return {}
	if unpreventable:
		return {}   # Lionheart Helm / Annihilator: never offer a point that can't help
	var card := state.get_card(target_id)
	if not card:
		return {}
	var ps := state.players.get(card.controller) as PlayerState
	if not ps or ps.hero_instance_id != target_id:
		return {}   # only heroes are shielders (717.2c)
	if get_ready_def_armor(state, card.controller, db).is_empty():
		return {}
	return {"player": card.controller, "amount": amount,
			"source": source_id, "target": target_id}


# Prevention offers for the combat packets about to land (computed when the
# defend window closes, BEFORE _do_combat_conclusion). Mirrors the conclusion's
# own damage math — get_atk both ways, Long-Range zeroing the retaliation.
static func _combat_prevention_offers(state: GameState, db) -> Array:
	var offers: Array = []
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender
	if db == null or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id):
		return offers
	var attacker := state.get_card(attacker_id)
	var atk_dmg := state.get_atk(attacker_id, db)
	var def_dmg := state.get_atk(defender_id, db)
	if _has_keyword(attacker, "long_range", db, state) \
			or _struck_weapon_grants_long_range(state, attacker_id, db):
		def_dmg = 0
	atk_dmg = _combat_replacements(state, db, attacker_id, atk_dmg)
	def_dmg = _combat_replacements(state, db, defender_id, def_dmg)
	var defender_offer := _prevention_offer(state, db, defender_id, atk_dmg, attacker_id,
		GameLogic.is_damage_unpreventable(state, db, attacker_id, true))
	if not defender_offer.is_empty():
		offers.append(defender_offer)
	var attacker_offer := _prevention_offer(state, db, attacker_id, def_dmg, defender_id,
		GameLogic.is_damage_unpreventable(state, db, defender_id, true))
	if not attacker_offer.is_empty():
		offers.append(attacker_offer)
	return offers


# ── Deferred packet groups (rule 717.2c for non-chain damage sources) ─────────
# Totem start-of-turn triggers, Infernal's end-of-turn burn, on_destroyed AoE:
# the effect hands ALL of its packets here INSTEAD of dealing them. If any
# packet would hit a hero whose controller has ready DEF armor, the prevention
# point opens first; otherwise the group lands immediately (identical to
# dealing directly). `after` names an optional follow-up hook run once the
# group has landed ("totem_next" → open the next queued totem trigger).
# `recursive_destroy` false uses the non-recursive destroy check (death-AoE
# secondary kills don't chain further on_destroyed effects).
static func defer_packets(state: GameState, db, packets: Array,
		after: String = "", recursive_destroy: bool = true) -> Array[GameEvent]:
	# World in Flames / Chromatic Cloak (717-style replacements): applied as the
	# packets enter the pipeline, so prevention offers and per-damage riders
	# (discard_per, drain heal) all see the modified amount. The flat bonuses
	# (Cloak's ability +1, Shadowform's shadow +1) apply
	# BEFORE the doubling — with both in play the controller would pick that
	# order anyway ((X+1)*2 > X*2+1); see data/rules_deviations.md
	# "Replacement-effect order".
	for p in packets:
		p["amount"] = _ability_bonus_amount(state, db, p)
		p["amount"] = _typed_damage_bonus_amount(state, db, p)
		p["amount"] = _fire_doubled_amount(state, db, p)
	state.pending_prevention_deferred.append({
		"packets": packets, "after": after,
		"recursive_destroy": recursive_destroy,
	})
	# A point (or an earlier group) already in flight — this group waits; the
	# "packets" resume in choose_prevention drains the queue.
	if state.pending_prevention_player != "" \
			or not state.pending_prevention_offers.is_empty() \
			or state.pending_prevention_resume != "" \
			or state.pending_prevention_deferred.size() > 1:
		return []
	return _open_or_apply_next_group(state, db)


# Preview-only (UI): what a hero-sourced damage packet would ACTUALLY deal right
# now, after the 717-style replacement effects defer_packets applies (Chromatic
# Cloak's ability +1, Shadowform/Aspect's typed +N, World in Flames' doubling),
# in the same fixed order. Used by the targeting cursor so the player sees the
# real number rather than the printed one; the authoritative amount is still
# computed in defer_packets at resolution.
static func preview_hero_damage_amount(state: GameState, db, player_id: String,
		amount: int, dmg_type: String, from_ability: bool) -> int:
	if amount <= 0 or db == null or state == null:
		return amount
	var ps := state.players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return amount
	var p := {
		"source": ps.hero_instance_id,
		"amount": amount,
		"dmg_type": dmg_type,
		"from_ability": from_ability,
	}
	p["amount"] = _ability_bonus_amount(state, db, p)
	p["amount"] = _typed_damage_bonus_amount(state, db, p)
	p["amount"] = _fire_doubled_amount(state, db, p)
	return int(p["amount"])


# World in Flames (azeroth_61): "Ongoing: If your hero would deal fire damage,
# it deals double that amount of damage instead." Only packets that carry a
# "dmg_type" field can qualify — packet sites whose source can be a hero pass
# their printed type along; combat damage comes through _combat_replacements,
# typed off the weapon the hero struck (303.2b). Live scan of the source hero's
# controller's in-play cards; doubling applies once per copy (two → ×4).
static func _fire_doubled_amount(state: GameState, db, p: Dictionary) -> int:
	var amount := int(p.get("amount", 0))
	if amount <= 0 or db == null \
			or str(p.get("dmg_type", "")).to_lower() != "fire":
		return amount
	var source_id := str(p.get("source", ""))
	if not _is_hero(state, source_id):
		return amount
	var controller: String = state.get_card(source_id).controller
	for card in state.cards_in_play(controller):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.effects == "":
			continue
		for seg in def.effects.split("|"):
			if seg.strip_edges() == "hero_fire_damage_doubled":
				amount *= 2
	return amount


# Shadowform (azeroth_88): "Ongoing: If your hero would deal shadow damage, it
# deals that amount of damage plus 1 instead." The damage-TYPE analogue of
# Chromatic Cloak's `from_ability` bonus, keyed on the per-packet "dmg_type"
# field the same way World in Flames' doubling is — so it covers every source
# the hero can be (abilities, hero powers, attachment burns). Combat damage has
# its own conclusion path and reaches this through _combat_replacements, which
# builds the packet from the struck weapon's type (Aspect of the Hawk + a Ranged
# weapon).
# Live scan of the source hero's controller's in-play cards; +N per copy.
static func _typed_damage_bonus_amount(state: GameState, db, p: Dictionary) -> int:
	var amount := int(p.get("amount", 0))
	var dmg_type := str(p.get("dmg_type", "")).to_lower()
	if amount <= 0 or db == null or dmg_type == "":
		return amount
	var source_id := str(p.get("source", ""))
	if not _is_hero(state, source_id):
		return amount
	var controller: String = state.get_card(source_id).controller
	for card in state.cards_in_play(controller):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.effects == "":
			continue
		for seg in def.effects.split("|"):
			var parts := seg.strip_edges().split(":")
			if parts[0].strip_edges() != "hero_damage_bonus_by_type":
				continue
			if parts.size() > 1 and parts[1].to_lower().strip_edges() == dmg_type:
				amount += int(parts[2]) if parts.size() > 2 else 1
	return amount


# Chromatic Cloak (azeroth_282): "If your hero would deal damage with an
# ability, it deals that amount of damage plus 1 instead." Only packets tagged
# `from_ability` qualify — the ability-resolution packet sites (instants,
# ongoing-ability on-play damage, attachments incl. Fireball's turn-start burn)
# set the flag; hero POWERS, ally powers, totems, and combat damage never do.
# Live scan of the source hero's controller's in-play cards; +1 per copy.
static func _ability_bonus_amount(state: GameState, db, p: Dictionary) -> int:
	var amount := int(p.get("amount", 0))
	if amount <= 0 or db == null or not p.get("from_ability", false):
		return amount
	var source_id := str(p.get("source", ""))
	if not _is_hero(state, source_id):
		return amount
	var controller: String = state.get_card(source_id).controller
	for card in state.cards_in_play(controller):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.effects == "":
			continue
		for seg in def.effects.split("|"):
			var parts := seg.strip_edges().split(":")
			if parts[0].strip_edges() == "hero_ability_damage_bonus":
				amount += int(parts[1]) if parts.size() > 1 else 1
	return amount


# Drain the deferred-group queue: groups with no preventable hero packet land
# immediately; the first group that has one opens the prevention point (the
# group stays at the front of the queue until its offers are decided).
static func _open_or_apply_next_group(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if state.pending_prevention_player != "":
		return events   # a point is already open — the queue drains after it
	while not state.pending_prevention_deferred.is_empty():
		var group: Dictionary = state.pending_prevention_deferred[0]
		var offers: Array = []
		for p in group.get("packets", []):
			var o := _prevention_offer(state, db,
				p.get("target", ""), int(p.get("amount", 0)), p.get("source", ""),
				GameLogic.is_damage_unpreventable(state, db, p.get("source", ""), false))
			if not o.is_empty():
				offers.append(o)
		if offers.is_empty():
			state.pending_prevention_deferred.pop_front()
			events.append_array(_apply_packet_group(state, db, group))
			# A destroy trigger inside the group may have deferred ANOTHER group
			# and opened its point (reentrant defer_packets) — stop draining.
			if state.pending_prevention_player != "":
				return events
			continue
		events.append_array(_open_prevention(state, offers, "packets"))
		return events
	return events


# Land every packet of a group (deal_damage consumes any prevention pool built
# at the point), run the packet's per-damage hooks, do a per-target destroy /
# game-over check, then run the group's after-hook. Excess DEF is wasted (pool
# cleared with the group).
#
# Optional per-packet hook fields (all read the damage actually DEALT — armor
# prevention and 405.3 excess-beyond-fatal both reduce it; a fully prevented
# packet ceases to exist, 717.2b, and fires none of them):
#   drain_heal_per / drain_heal_to — heal N × dealt from a card (Steal Essence)
#   discard_per — the damaged character's controller discards N × dealt
#                 (Mind Spike / Mind Blast / Dark Cleric Ismantal)
#   riders — "+"-joined restriction rider(s) placed on a SURVIVING target
#            (Frostbolt / Frost Shock; applied even at 0 dealt — the rider is a
#            separate sentence on the card, not conditioned on damage)
static func _apply_packet_group(state: GameState, db,
		group: Dictionary) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var recursive: bool = group.get("recursive_destroy", true)
	for p in group.get("packets", []):
		var target_id: String = p.get("target", "")
		var source_id: String = p.get("source", "")
		if not state.is_in_play(target_id):
			continue
		var dd_events := GameLogic.deal_damage(
			state, source_id, target_id, int(p.get("amount", 0)), db)
		events.append_array(dd_events)
		var drain_per := int(p.get("drain_heal_per", 0))
		if drain_per > 0:
			var dealt := 0
			for de in dd_events:
				if (de as GameEvent).event_type == "damage_dealt":
					dealt += int((de as GameEvent).payload.get("amount", 0))
			if dealt > 0:
				events.append_array(GameLogic.heal(
					state, str(p.get("drain_heal_to", "")), dealt * drain_per,
					db, source_id))
		events.append_array(_apply_discard_per_damage(
			state, target_id, dd_events, int(p.get("discard_per", 0))))
		var t_card := state.get_card(target_id)
		if t_card and state.is_in_play(target_id) \
				and state.get_current_hp(target_id, db) <= 0:
			var t_zone := state.zones.get(t_card.zone_id) as Zone
			if t_zone and t_zone.zone_type == "hero_row":
				events.append(GameEvent.game_over(
					_other_player(state, t_card.controller), t_card.controller))
			elif recursive:
				events.append_array(_check_destroyed_trigger(state, target_id, source_id, db))
			else:
				events.append_array(GameLogic.check_destroyed(state, target_id, source_id, db))
		elif str(p.get("riders", "")) != "" and state.is_in_play(target_id):
			events.append_array(_apply_damage_riders(
				state, target_id, source_id, str(p.get("riders", ""))))
	_clear_damage_prevention(state)   # 717.2c: excess DEF beyond the packet is wasted
	# Cold Blood: any ally this group's hero damage landed on is destroyed.
	events.append_array(_fire_cold_blood(state, db))
	# Operation Recombobulation: any opposing non-token ally that died in this
	# group (including to Cold Blood just above) offers its owner a fetch.
	events.append_array(_fire_recombobulation(state, db))
	match group.get("after", ""):
		"totem_next":
			events.append_array(_open_next_totem_trigger(state, db))
	return events


# Queue prevention offers and open the first decision point. `resume` names
# what choose_prevention continues once every offer is decided: "combat" →
# _do_combat_conclusion, "packets" → land the front deferred packet group.
static func _open_prevention(state: GameState, offers: Array,
		resume: String) -> Array[GameEvent]:
	state.pending_prevention_offers = offers
	state.pending_prevention_resume = resume
	return _next_prevention_offer(state)


static func _next_prevention_offer(state: GameState) -> Array[GameEvent]:
	if state.pending_prevention_offers.is_empty():
		return []
	var offer: Dictionary = state.pending_prevention_offers.pop_front()
	state.pending_prevention_player = offer.get("player", "")
	state.pending_prevention_amount = int(offer.get("amount", 0))
	state.pending_prevention_source = offer.get("source", "")
	state.pending_prevention_target = offer.get("target", "")
	return [GameEvent.prevention_opened(
		state.pending_prevention_player, state.pending_prevention_amount,
		state.pending_prevention_source, state.pending_prevention_target)]


# Entry point for the prevention decision (direct call, like choose_strike).
# armor_id != "": exhaust that armor, add its DEF to the controller's
# prevention pool (consumed by GameLogic.deal_damage when the packet lands),
# and — if the packet still has damage left and more ready armor exists — keep
# the point open ("you may exhaust another equipment, and so on" — 717.2c).
# armor_id == "" (or an invalid pick): take the remaining damage. Once every
# queued offer is decided, resumes what the point interrupted.
static func choose_prevention(state: GameState, armor_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_prevention_player == "":
		return []
	var player_id := state.pending_prevention_player
	var events: Array[GameEvent] = []

	if armor_id != "" and armor_id in get_ready_def_armor(state, player_id, db):
		var armor := state.get_card(armor_id)
		var a_def := db.get_def(armor.card_def_id) as CardDef
		var def_value := int(_equipment_info(a_def).get("def", 0))
		events.append_array(GameLogic.exhaust_card(state, armor_id))
		var ps := state.players.get(player_id) as PlayerState
		ps.damage_prevention += def_value
		state.pending_prevention_amount = max(
			state.pending_prevention_amount - def_value, 0)
		events.append(GameEvent.armor_prevention_used(
			player_id, armor_id, def_value, ps.damage_prevention))
		if state.pending_prevention_amount > 0 \
				and not get_ready_def_armor(state, player_id, db).is_empty():
			events.append(GameEvent.prevention_opened(
				player_id, state.pending_prevention_amount,
				state.pending_prevention_source, state.pending_prevention_target))
			return events

	# This offer is decided — next queued offer, or resume what was interrupted.
	state.pending_prevention_player = ""
	state.pending_prevention_amount = 0
	state.pending_prevention_source = ""
	state.pending_prevention_target = ""
	var next := _next_prevention_offer(state)
	if not next.is_empty():
		events.append_array(next)
		return events

	var resume := state.pending_prevention_resume
	state.pending_prevention_resume = ""
	match resume:
		"combat":
			# _do_combat_conclusion consumes the pools via deal_damage and clears
			# any leftover (excess DEF is wasted — 717.2c).
			events.append_array(_do_combat_conclusion(state, db))
		"packets":
			if not state.pending_prevention_deferred.is_empty():
				var group: Dictionary = state.pending_prevention_deferred.pop_front()
				events.append_array(_apply_packet_group(state, db, group))
			events.append_array(_open_or_apply_next_group(state, db))
	return events


# drain_heal_per_damage:N — paired with a deal_damage_to_target segment
# (Steal Essence): the casting hero heals N for each damage actually dealt.
static func _drain_heal_per_damage(def: CardDef) -> int:
	for segment in def.effects.split("|"):
		var parts := segment.strip_edges().split(":")
		if parts[0] == "drain_heal_per_damage":
			return int(parts[1]) if parts.size() > 1 else 1
	return 0


# discard_per_damage:N — paired with a deal_damage_to_target segment (Mind Spike,
# Mind Blast) or an activated_power:deal_damage_to_target power (Dark Cleric
# Ismantal): the DAMAGED character's controller discards N cards for each damage
# actually dealt. Reuses the pending-discard machinery (choose_discard).
static func _discard_per_damage(def: CardDef) -> int:
	for segment in def.effects.split("|"):
		var parts := segment.strip_edges().split(":")
		if parts[0] == "discard_per_damage":
			return int(parts[1]) if parts.size() > 1 else 1
	return 0


# Sets up a pending discard for the controller of a character that was just dealt
# `dmg_events` worth of damage. `per` cards per damage point. No-op if the
# controller's hand is empty. Returns the events to append (the choice-opened).
# AI scores these cards for the damage only, not the discard — see
# data/rules_deviations.md "Mind Spike / Mind Blast / Dark Cleric Ismantal".
static func _apply_discard_per_damage(state: GameState, target_id: String,
		dmg_events: Array, per: int) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if per <= 0:
		return events
	var dealt := 0
	for de in dmg_events:
		if (de as GameEvent).event_type == "damage_dealt":
			dealt += int((de as GameEvent).payload.get("amount", 0))
	if dealt <= 0:
		return events
	var t_card := state.get_card(target_id)
	if not t_card:
		return events
	var discarder: String = t_card.controller
	var count := dealt * per
	if state.cards_in_zone(discarder + "_hand").is_empty():
		return events
	state.pending_discard_player = discarder
	state.pending_discard_count  = count
	events.append(GameEvent.discard_choice_opened(discarder, count, "card_effect"))
	return events


static func _has_effect_flag_prefix(def: CardDef, prefix: String) -> bool:
	for segment in def.effects.split("|"):
		if segment.strip_edges().split(":")[0] == prefix:
			return true
	return false


# Leftover prevention pool expires once its packet has landed (excess DEF is
# wasted — 717.2c).
static func _clear_damage_prevention(state: GameState) -> void:
	for pid in state.players:
		var ps := state.players[pid] as PlayerState
		if ps:
			ps.damage_prevention = 0


# ── Ally activated power — validation ─────────────────────────────────────────

static func _can_use_ally_power(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Requires priority and action phase. A non-empty chain is allowed: activated ally
	# powers are instant-speed (rule 701.3) and may respond to something already on the
	# chain (e.g. Freya Lightsworn healing in response to Ta'zo's damage power). The
	# empty-chain gate applies only to "on_your_turn" (sorcery-speed) powers below.
	# No "turn_player" restriction either — ally powers without "use only on your turn"
	# work on either player's turn (e.g. Grimdron blocking in an opponent's window).
	# Powers are instant-speed (rule 701): usable in ANY priority window, not only
	# the action phase. Do NOT gate on state.phase here — that wrongly blocked
	# powers during the ready/draw/end priority windows (e.g. Kavai during the
	# opponent's ready step). The action-phase restriction belongs ONLY to
	# sorcery-speed ("on_your_turn") powers, enforced below.
	if state.priority_player != action.source_player:
		return false
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card or card.controller != action.source_player:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	# Allies use their power from the ally row; equipment (e.g. Mooncloth Robe)
	# from the hero row. Both are validated through this same path.
	if not zone or not (zone.zone_type in ["ally_row", "hero_row"]):
		return false
	if not db:
		return false
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return false
	var ap := _ally_activated_power(def)
	if ap.is_empty():
		return false
	# "Use only on your turn" (e.g. Acolyte Demia) — same convention as hero
	# powers (_power_effect_is(def, "on_your_turn")), as a standalone segment.
	# Also used for engine-only deviations where the printed text has no such
	# restriction but it's true by construction (e.g. Rayder — see
	# data/rules_deviations.md).
	if _power_effect_is(def, "on_your_turn"):
		if state.turn_player != action.source_player:
			return false
		if state.phase != "action":
			return false
		if not state.pending_actions.is_empty():
			return false
	var extra_cost_str: String = ap.get("extra_cost", "")
	var once_per_turn: bool = power_has_extra_cost(extra_cost_str, "once_per_turn")
	# put_damage_self (e.g. Acolyte Demia) has no [Activate] tap symbol either —
	# its cost is just the resource + self-damage, so it's a plain payment power
	# (701.2), not an activated power (701.3). No summoning sickness, no exhaust.
	var no_activate_symbol: bool = _power_has_no_activate_symbol(extra_cost_str)
	if once_per_turn:
		# No [Activate] tap symbol on this power (rule 701.3/3216): it isn't gated
		# by summoning sickness or the card's exhausted state, only by its own
		# printed "once per turn" text.
		if card.used_this_turn:
			return false
	elif not no_activate_symbol:
		# Rule 701.3: summoning sickness applies to activated powers for allies.
		# Equipment are not characters and never carry summoning sickness, so this
		# only ever gates allies (equipment never sets just_summoned).
		if card.just_summoned:
			return false
		if card.is_exhausted:
			return false
	var ap_x := int(action.params.get("x_value", 0))
	if state.get_available_resources(action.source_player) < power_resource_cost(ap, ap_x):
		return false
	# Extra, card-specific costs baked into the power (e.g. Mooncloth Robe also
	# exhausts your hero). If the hero can't pay, the power can't be used.
	if not _can_pay_extra_power_cost(state, action.source_player, ap.get("extra_cost", ""), db):
		return false
	# Targeted effects require a valid in-play target. `_skip_target_check` (used
	# by has_any_legal_play / highlight probes, mirroring the instant/quest
	# no-target-check helpers) validates everything EXCEPT the specific target,
	# since the target is picked interactively after the power is chosen.
	var skip_target: bool = action.params.get("_skip_target_check", false)
	var targets_kind: String = ap.get("targets", "")
	# Two-pick powers (Gertha, The Old Crone: destroy_ally; Besh'iah:
	# destroy_ability). Beyond the power's own destroy target (validated by the
	# kind-specific blocks below), the sacrifice_ally cost picks one of the source
	# player's OWN allies, named separately in sacrifice_id — Bizzik, whose
	# sacrifice IS his only target, rides target_id instead and doesn't reach this
	# branch. Required at submission; the no-target probe omits it, like the
	# destroy target itself. The gate is the COST, not the effect, so the two
	# cards share it and a future sacrifice power inherits it.
	if power_sacrifice_is_separate(ap) and not skip_target:
		var sac_id: String = action.params.get("sacrifice_id", "")
		var sac_card := state.get_card(sac_id)
		if not _is_ally(state, sac_id) or not sac_card \
				or sac_card.controller != action.source_player:
			return false
	# Graveyard-card-targeted powers (Ophelia Barrows): even the no-target probe
	# requires a legal candidate in some graveyard (per the card's paired
	# graveyard_to_rfg requirement segment); a chosen target must be one of them.
	if targets_kind == "graveyard_ally":
		var gy_req := get_graveyard_search_requirement(def)
		if gy_req.is_empty():
			return false
		var gy_cands := get_graveyard_search_candidates(state, action.source_player, gy_req, db)
		if gy_cands.is_empty():
			return false
		if skip_target:
			return true
		return action.params.get("target_id", "") in gy_cands
	# Kavai the Wanderer: "Destroy target ability or equipment." Even the
	# no-target probe requires at least one in-play candidate of either kind
	# (no false green with nothing to destroy).
	if targets_kind == "ability_or_equipment":
		var d_cands := get_destroy_kind_candidates(state, db, "ability") \
			+ get_destroy_kind_candidates(state, db, "equipment")
		if d_cands.is_empty():
			return false
		# "Chipper" Ironbane: X must equal the target's printed cost, so the
		# no-target probe needs a candidate the player can actually AFFORD —
		# otherwise he'd stay green with only an unpayable target on the board.
		if bool(ap.get("cost_x", false)):
			var avail := state.get_available_resources(action.source_player)
			var any_affordable := false
			for cid in d_cands:
				var c_card := state.get_card(cid)
				var c_def := db.get_def(c_card.card_def_id) as CardDef if c_card else null
				if c_def and printed_cost(c_def) <= avail:
					any_affordable = true
					break
			if not any_affordable:
				return false
		if skip_target:
			return true
		var d_tid: String = action.params.get("target_id", "")
		if not power_cost_matches_target(ap, state, d_tid, ap_x, db):
			return false
		return d_tid in d_cands and _is_legal_target(state, d_tid, db)
	# Lafiel ("Destroy target ability") / Moira Darkheart ("Destroy target armor
	# or weapon" — exactly the equipment pool, since every Equipment card is one
	# or the other). Same shape one kind narrower; the no-target probe still
	# requires an in-play candidate of that kind. No Purge-style friendly-
	# attachment exclusion on `ability` — neither printed text has that clause.
	if targets_kind in ["ability", "equipment"]:
		var a_cands := get_destroy_kind_candidates(state, db, targets_kind)
		if a_cands.is_empty():
			return false
		if skip_target:
			return true
		var a_tid: String = action.params.get("target_id", "")
		return a_tid in a_cands and _is_legal_target(state, a_tid, db)
	# Lhurg Venomblade ("[Activate] -> Destroy target exhausted ally"): Coup de
	# Grâce's pool as an activated-power target kind, sharing its predicate. Even
	# the no-target probe requires an exhausted ally to exist somewhere (either
	# party) — no false green with nothing to kill.
	if targets_kind == "exhausted_ally":
		if not _any_exhausted_ally(state, db):
			return false
		if skip_target:
			return true
		return _is_exhausted_ally(state, action.params.get("target_id", ""), db)
	if skip_target:
		return true
	if targets_kind in ["hero_or_ally", "ally", "friendly_ally"]:
		var target_id: String = action.params.get("target_id", "")
		if not _is_legal_target(state, target_id, db):
			return false
		# "ally" powers (Elder Moorf buff, Augustus destroy) may only target
		# allies, not heroes. "friendly_ally" (Bizzik's sacrifice cost) further
		# requires the ally be in the source player's own party.
		if targets_kind in ["ally", "friendly_ally"] and not _is_ally(state, target_id):
			return false
		if targets_kind == "friendly_ally":
			var t_card := state.get_card(target_id)
			if not t_card or t_card.controller != action.source_player:
				return false
	elif targets_kind == "hero_or_ally_two":
		# Hierophant Caydiem: damage target_id, heal a different heal_target_id
		# (rule 706.1 — "another target" can't repeat the first).
		var target_id2: String = action.params.get("target_id", "")
		var heal_target_id: String = action.params.get("heal_target_id", "")
		if not _is_legal_target(state, target_id2, db):
			return false
		if not _is_legal_target(state, heal_target_id, db):
			return false
		if heal_target_id == target_id2:
			return false
	return true


# Whether an in-play card sits in an ally row (i.e. is an ally on the board).
static func _is_ally(state: GameState, card_id: String) -> bool:
	var card := state.get_card(card_id)
	if not card:
		return false
	var zone := state.zones.get(card.zone_id) as Zone
	return zone != null and zone.zone_type == "ally_row"


# Whether a power's extra cost token can currently be paid.
static func _can_pay_extra_power_cost(state: GameState, player_id: String,
		extra_cost: String, db = null) -> bool:
	for entry in power_extra_costs(extra_cost):
		if not _can_pay_one_extra_power_cost(state, player_id, entry, db):
			return false
	return true


# One `+`-separated token of the EXTRACOST field (see power_extra_costs).
static func _can_pay_one_extra_power_cost(state: GameState, player_id: String,
		entry: String, db = null) -> bool:
	var token := entry.split(":")[0]
	match token:
		"", null:
			return true
		"exhaust_hero":
			var ps := state.players.get(player_id) as PlayerState
			var hero_id: String = ps.hero_instance_id if ps else ""
			if hero_id == "":
				return false
			var hero := state.get_card(hero_id)
			return hero != null and not hero.is_exhausted
		"put_damage_self", "activate_put_damage_self":
			# Rule 405.3: damage put on a character can't exceed its remaining
			# health, but it CAN be exactly fatal — always payable while the
			# source is in play (checked by the caller). activate_put_damage_self
			# (Kena Shadowbrand) is the same self-damage cost but keeps the
			# [Activate] tap symbol (the source also exhausts).
			return true
		"rfg_allies":
			# Augustus Corpsemonger: remove N ally cards in your graveyard from
			# the game. Payable only if the graveyard holds at least N of them.
			var need := int(entry.split(":")[1]) if entry.split(":").size() > 1 else 0
			return _count_graveyard_allies(state, player_id, db) >= need
		"sacrifice_ally":
			# Bizzik Sparkcog: destroy an ally in your party as a cost. Payable
			# while you control at least one ally (Bizzik himself qualifies).
			return not state.cards_in_zone(player_id + "_ally_row").is_empty()
		"sacrifice_self":
			# Kavai the Wanderer: destroy the power's source itself as a cost.
			# Always payable while the source is in play (checked by the caller).
			return true
	return true


# Count ally cards sitting in player_id's graveyard (Augustus Corpsemonger cost).
static func _count_graveyard_allies(state: GameState, player_id: String, db) -> int:
	var n := 0
	if not db:
		return 0
	for card in state.cards_in_zone(player_id + "_graveyard"):
		var def := db.get_def(card.card_def_id) as CardDef
		if def and def.card_type == "Ally":
			n += 1
	return n


# ── Ally activated power — resolution ─────────────────────────────────────────

static func _resolve_use_ally_power(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var card_id: String = action.params.get("card_id", "")
	var card := state.get_card(card_id)
	if not card:
		return [GameEvent.make("action_fizzled",
			{"action_type": "use_ally_power", "reason": "card_not_found"})]
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return []
	var ap := _ally_activated_power(def)
	if ap.is_empty():
		return []

	var events: Array[GameEvent] = []
	var extra_cost: String = ap.get("extra_cost", "")
	# Resource cost, the [Activate] tap symbol, the once-per-turn mark and the
	# "exhaust your hero" extra cost were ALL paid at submission time, on chain
	# entry (rule 412.2 — see _pay_activate_costs in submit_action). Only the
	# costs below are still paid here at resolution, deliberately: a sacrifice
	# whose card is killed in response no-ops while the effect still resolves.
	if power_has_extra_cost(extra_cost, "put_damage_self") \
			or power_has_extra_cost(extra_cost, "activate_put_damage_self"):
		# Rule 405.3: put (not deal) damage on the source itself (Acolyte Demia;
		# Kena Shadowbrand). Can be exactly fatal — check destruction after paying.
		var put_amount := power_extra_cost_arg(extra_cost, "put_damage_self",
			power_extra_cost_arg(extra_cost, "activate_put_damage_self", 1))
		events.append_array(GameLogic.put_damage(state, card_id, put_amount, db))
		events.append_array(_check_destroyed_trigger(state, card_id, card_id, db))
	elif power_has_extra_cost(extra_cost, "rfg_allies"):
		# Augustus Corpsemonger: remove N ally cards in your graveyard from the
		# game (rule 415.7a — owner's RFG zone). The specific cards are auto-
		# chosen in graveyard order (see data/rules_deviations.md — the player
		# doesn't pick which dead allies leave, only a cost is paid).
		var rfg_n := power_extra_cost_arg(extra_cost, "rfg_allies", 0)
		var removed := 0
		for gy_card in state.cards_in_zone(action.source_player + "_graveyard"):
			if removed >= rfg_n:
				break
			var gy_def := db.get_def(gy_card.card_def_id) as CardDef
			if gy_def and gy_def.card_type == "Ally":
				events.append_array(GameLogic.move_card(state, gy_card.instance_id, gy_card.owner + "_rfg"))
				events.append(GameEvent.card_removed_from_game(gy_card.instance_id, action.source_player))
				removed += 1
	elif power_has_extra_cost(extra_cost, "sacrifice_ally"):
		# Destroy a chosen ally in your party as a cost. Bizzik Sparkcog's
		# sacrifice IS its only target, so it rides target_id (may be Bizzik
		# himself); Gertha, The Old Crone and Besh'iah name it separately in
		# sacrifice_id because their target_id is what the EFFECT destroys — an
		# ally for Gertha, an ability for Besh'iah. Like
		# sacrifice_self, the cost is paid here at resolution — if the chosen
		# ally already left play (killed in response), the sacrifice no-ops and
		# the effect still resolves, matching "costs are paid at announcement".
		var sac_id: String = action.params.get("sacrifice_id",
			action.params.get("target_id", ""))
		if _is_ally(state, sac_id):
			events.append_array(_destroy_card_trigger(state, sac_id, card_id, db))
	elif power_has_extra_cost(extra_cost, "sacrifice_self"):
		# Kavai the Wanderer / Mana Agate: destroy the source itself as a cost.
		# The source may be an ally (Kavai) or an ongoing ability in the hero row
		# (Mana Agate) — any in-play source works. If an opponent already
		# destroyed it in response, the destroy no-ops and the effect still
		# resolves — matching the printed rules, where the cost was paid at
		# announcement.
		if state.is_in_play(card_id):
			events.append_array(_destroy_card_trigger(state, card_id, card_id, db))
	events.append(GameEvent.make("ally_power_used",
		{"ally_id": card_id, "player": action.source_player,
			"target_id": action.params.get("target_id", "")}))

	match ap.get("effect", ""):
		"draw":
			var n: int = int(ap.get("amount", 1))
			for _i in n:
				events.append_array(_draw_one(state, card.controller))
		"hand_to_deck_draw":
			# Ilandre Moonspear: "[Activate] → Put your hand on the bottom of
			# your deck, then draw that many cards." Same effect as Crown of the
			# Earth's reward mode; the count is taken from the hand at
			# resolution, so a hand emptied in response makes it a no-op.
			events.append_array(_hand_to_deck_draw(state, card.controller))
		"discard_opponent":
			# Hypnotic Blade: "Target player discards a card." The target is
			# auto-chosen as the opponent (discarding yourself is never useful in
			# a duel — see data/rules_deviations.md "Hypnotic Blade"). Reuses the
			# Mias the Putrid pending-discard machinery.
			var disc_n: int = int(ap.get("amount", 1))
			var disc_opp := _other_player(state, card.controller)
			if not state.cards_in_zone(disc_opp + "_hand").is_empty():
				state.pending_discard_player = disc_opp
				state.pending_discard_count  = disc_n
				events.append(GameEvent.discard_choice_opened(disc_opp, disc_n, "card_effect"))
		"rfg_graveyard_ally":
			# Ophelia Barrows: "Remove target ally card in any graveyard from the
			# game. If you do, [she] heals 1 damage from herself." Re-check the
			# target is still in a graveyard at resolution (fizzle otherwise); the
			# self-heal only fires when the removal actually happens ("if you do").
			var gy_tid: String = action.params.get("target_id", "")
			var gy_card := state.get_card(gy_tid)
			var gy_zone: Zone = state.zones.get(gy_card.zone_id) if gy_card else null
			if gy_card and gy_zone and gy_zone.zone_type == "graveyard":
				events.append_array(GameLogic.move_card(state, gy_tid, gy_card.owner + "_rfg"))
				events.append(GameEvent.card_removed_from_game(gy_tid, action.source_player))
				events.append_array(GameLogic.heal(
					state, card_id, int(ap.get("amount", 1)), db, card_id))
		"destroy_ally":
			# Augustus Corpsemonger: "Destroy target ally." Re-check at resolution
			# (rule 706 / glossary 4217) — fizzle if the target left play or
			# became Untargetable after the announce. Lhurg Venomblade narrows the
			# same effect with TARGETS=exhausted_ally, so the re-check tightens to
			# match: an ally that READIED in response fizzles the destroy, exactly
			# as with Coup de Grâce.
			var destroy_id: String = action.params.get("target_id", "")
			var destroy_ok := _is_legal_target(state, destroy_id, db) \
					and _is_ally(state, destroy_id)
			if destroy_ok and ap.get("targets", "") == "exhausted_ally":
				destroy_ok = _is_exhausted_ally(state, destroy_id, db)
			if destroy_ok:
				events.append_array(_destroy_card_trigger(state, destroy_id, card_id, db))
		"destroy_ability_or_equipment":
			# Kavai the Wanderer: "Destroy target ability or equipment." Re-check
			# at resolution (706) — fizzles if the target left play (e.g. an
			# attachment that died with its host, including one attached to Kavai
			# herself, destroyed by her own sacrifice cost above) or became
			# Untargetable after the announce.
			var dae_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, dae_id, db) \
					and (_is_in_play_ability(state, dae_id, db) \
						or _is_in_play_equipment(state, dae_id, db)):
				events.append_array(_destroy_card_trigger(state, dae_id, card_id, db))
		"destroy_ability":
			# Lafiel: "2, [Activate] -> Destroy target ability." Re-check at
			# resolution (706 / glossary 4217) — fizzles if the ability left
			# play (e.g. an attachment that died with its host) or became
			# Untargetable after the announce.
			var da_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, da_id, db) \
					and _is_in_play_ability(state, da_id, db):
				events.append_array(_destroy_card_trigger(state, da_id, card_id, db))
		"destroy_equipment":
			# Moira Darkheart: "1, Destroy Moira Darkheart -> Destroy target
			# armor or weapon." Re-check at resolution (706 / glossary 4217) —
			# fizzles if the equipment left play or became Untargetable after
			# the announce. Her own sacrifice cost is paid above, so a Moira
			# killed in response no-ops the cost and the destroy still resolves.
			var de_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, de_id, db) \
					and _is_in_play_equipment(state, de_id, db):
				events.append_array(_destroy_card_trigger(state, de_id, card_id, db))
		"exhaust_target":
			# Galahandra, Keeper of the Silent Grove: "1, [Activate] -> Exhaust
			# target ally." Re-check at resolution (706): fizzles if the ally
			# left play / became Untargetable. exhaust_card no-ops if already
			# exhausted. Same interrupt role as Exhaustion (azeroth_159), but
			# as a repeatable ally power instead of a one-shot instant.
			var exhaust_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, exhaust_id, db) and _is_ally(state, exhaust_id):
				events.append_array(GameLogic.exhaust_card(state, exhaust_id))
		"deal_damage_aoe":
			var amount: int = int(ap.get("amount", 0))
			var opp := _other_player(state, card.controller)
			var packets: Array = []
			var opp_ps := state.players.get(opp) as PlayerState
			if opp_ps and opp_ps.hero_instance_id != "":
				packets.append({"source": card_id,
					"target": opp_ps.hero_instance_id, "amount": amount})
			for ally in state.cards_in_zone(opp + "_ally_row"):
				packets.append({"source": card_id,
					"target": ally.instance_id, "amount": amount})
			events.append_array(defer_packets(state, db, packets))
		"deal_damage_aoe_all":
			# "Your hero deals N <type> damage to each hero and ally."
			# (Ramstein's Lightning Bolts.) Symmetric and non-targeted: it hits
			# BOTH players' heroes and every ally on the board, the controller's
			# own included — so 706 Untargetable is irrelevant (it restricts
			# targets of links). The source is the controller's HERO as printed,
			# not the item, which is what makes it inherit Lionheart Helm's
			# unpreventable aura and feed Cold Blood's "your hero deals damage to
			# an ally" trigger. Not tagged from_ability — an equipment power is
			# not an ability, so Chromatic Cloak doesn't boost it.
			var aoe_all_amount: int = int(ap.get("amount", 0))
			var aoe_ps := state.players.get(card.controller) as PlayerState
			var aoe_hero: String = aoe_ps.hero_instance_id if aoe_ps else ""
			if aoe_hero != "" and aoe_all_amount > 0:
				var aoe_all_packets: Array = []
				# Controller's side first, then the opponent's — a fixed order so
				# sequential prevention points are deterministic.
				for pid in [card.controller, _other_player(state, card.controller)]:
					var side_ps := state.players.get(pid) as PlayerState
					if side_ps and side_ps.hero_instance_id != "":
						aoe_all_packets.append({"source": aoe_hero,
							"target": side_ps.hero_instance_id,
							"amount": aoe_all_amount,
							"dmg_type": str(ap.get("dmg_type", ""))})
					for side_ally in state.cards_in_zone(pid + "_ally_row"):
						aoe_all_packets.append({"source": aoe_hero,
							"target": side_ally.instance_id,
							"amount": aoe_all_amount,
							"dmg_type": str(ap.get("dmg_type", ""))})
				events.append_array(defer_packets(state, db, aoe_all_packets))
		"deal_damage_to_target":
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			# Rule 706 re-check: fizzle if the target left play or became Untargetable.
			if _is_legal_target(state, target_id, db):
				# Packet pipeline — the paired discard_per_damage rider (Dark
				# Cleric Ismantal) travels with the packet.
				events.append_array(defer_packets(state, db, [{
					"source": card_id, "target": target_id, "amount": amount,
					"discard_per": _discard_per_damage(def),
				}]))
		"heal_target":
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, target_id, db):
				events.append_array(GameLogic.heal(state, target_id, amount, db, card_id))
		"heal_party":
			# Lady Courtney Noel: "[Activate] -> [she] heals N damage from each hero
			# and ally in your party." Non-targeted and friendly-only, so 706
			# Untargetable is irrelevant and nothing is announced; the source is the
			# power's own card. Same party sweep as Healing Stream Totem's
			# heal_party_each_turn, read live at resolution — allies that arrived
			# after the announce are healed, and the source heals itself too.
			var party_amount: int = int(ap.get("amount", 0))
			var party_pid := card.controller
			for party_ally in state.cards_in_zone(party_pid + "_ally_row"):
				events.append_array(GameLogic.heal(
					state, party_ally.instance_id, party_amount, db, card_id))
			var party_hero := state.get_hero(party_pid)
			if party_hero:
				events.append_array(GameLogic.heal(
					state, party_hero.instance_id, party_amount, db, card_id))
		"buff_atk_target":
			# Elder Moorf: "Target ally has +X ATK this turn."
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			var target := state.get_card(target_id)
			if target and _is_legal_target(state, target_id, db) \
					and _is_ally(state, target_id):
				var buff := Buff.make("moorf_atk", card_id, "atk", amount, "turns", 1)
				events.append_array(GameLogic.add_buff(state, target_id, buff))
		"party_buff_atk_attacking":
			# Rayder: "Allies in your party have +X ATK while attacking this
			# turn." Tracked player-side (not per-card) so it also covers
			# allies that enter play later this turn.
			var amount: int = int(ap.get("amount", 0))
			var ps := state.players.get(card.controller) as PlayerState
			if ps:
				ps.party_atk_buffs_this_turn.append({"amount": amount, "alignment": ""})
				events.append(GameEvent.party_atk_buff_added(card.controller, amount, ""))
		"buff_atk_target_attacking":
			# Ryn Dreamstrider: "Target hero or ally has +X ATK while attacking this turn."
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			if _is_legal_target(state, target_id, db):
				var buff := Buff.make("ryn_atk", card_id, "atk", amount,
						"turns", 1, "while_attacking")
				events.append_array(GameLogic.add_buff(state, target_id, buff))
		"deal_damage_and_heal":
			# Hierophant Caydiem: deals AMOUNT damage to target_id and heals
			# AMOUNT from a different heal_target_id. The heal is unconditional
			# (not per-damage), so it lands inline; the damage packet goes
			# through the prevention pipeline.
			var amount: int = int(ap.get("amount", 0))
			var target_id: String = action.params.get("target_id", "")
			var heal_target_id: String = action.params.get("heal_target_id", "")
			if _is_legal_target(state, heal_target_id, db):
				events.append_array(GameLogic.heal(state, heal_target_id, amount, db, card_id))
			if _is_legal_target(state, target_id, db):
				events.append_array(defer_packets(state, db, [{
					"source": card_id, "target": target_id, "amount": amount,
				}]))

	return events


# ── Combat — validation ────────────────────────────────────────────────────────

static func _can_propose_combat(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Rule 601.1: non-combat action phase only, chain empty, turn player.
	if state.phase != "action":
		return false
	if state.combat_attack_window or state.combat_defend_window or state.in_protect_point:
		return false
	if state.turn_player != action.source_player:
		return false
	if not state.pending_actions.is_empty():
		return false
	var attacker_id: String = action.params.get("attacker_id", "")
	var defender_id: String = action.params.get("defender_id", "")
	var attacker := state.get_card(attacker_id)
	var defender := state.get_card(defender_id)
	if not attacker or not defender:
		return false
	# Attacker must be controlled by the acting player.
	if attacker.controller != action.source_player:
		return false
	# Attacker must be in play (ally_row or hero_row).
	if not state.is_in_play(attacker_id):
		return false
	# Rule 601.2a: attacker must be ready.
	if attacker.is_exhausted:
		return false
	# Rule 601.2a / 302.2: ally summoning sickness (heroes immune per 301.3).
	var att_zone := state.zones.get(attacker.zone_id) as Zone
	if att_zone and att_zone.zone_type == "ally_row":
		if attacker.just_summoned and not _has_keyword(attacker, "ferocity", db, state):
			return false
		# "Opposing allies can't attack." (Lady Jaina) — locks allies only, not heroes.
		if _allies_attack_locked(state, attacker.controller, db):
			return false
	# Rule 305.3a: Totems can't be proposed as attackers.
	if db and is_totem_def(db.get_def(attacker.card_def_id) as CardDef):
		return false
	# "can't attack" allies (e.g. Guardian Steelhorn) can never propose combat.
	if _has_keyword(attacker, "cant_attack", db, state):
		return false
	# "Can't attack this turn" restriction buff (e.g. Litori Frostburn).
	if attacker.has_restriction("cannot_attack"):
		return false
	# Defender must be controlled by the opponent.
	if defender.controller == action.source_player:
		return false
	# Defender must be in play.
	if not state.is_in_play(defender_id):
		return false
	# Rule 601.2b: defender must not be Elusive.
	if _has_keyword(defender, "elusive", db, state):
		return false
	# Taunt check: if any legal defender has sarmoth_taunt, only that card is valid.
	if defender_id not in get_legal_defenders(state, attacker_id, db):
		return false
	return true


# ── Combat — query helpers (called by AI and InputRouter) ─────────────────────

# Returns instance_ids of all legal attackers the player can propose right now.
# Does NOT check phase/chain — callers apply that context.
static func get_legal_attackers(state: GameState, player_id: String, db) -> Array[String]:
	var result: Array[String] = []
	# Hero (rule 301.3: no summoning sickness; still must be ready per 601.2a).
	# Also require ATK-if-attacking > 0 OR an affordable, ready weapon to strike
	# with — a 0 ATK hero that can't strike deals no damage and exhausts for
	# nothing; treat as not a legal attacker (practical gate, not an explicit
	# rule, but avoids pointless/confusing highlights and AI plays). The
	# assume_attacking probe admits defender-independent "while attacking"
	# bonuses (Cat Form's hero_atk_while_attacking, a Ryn Dreamstrider buff) —
	# by the printed rules a 0-ATK attack proposal is legal anyway, so relaxing
	# the gate only moves us closer to the rules.
	var ps := state.players.get(player_id) as PlayerState
	if ps and ps.hero_instance_id != "":
		var hero := state.get_card(ps.hero_instance_id)
		if hero and not hero.is_exhausted \
				and (state.get_atk(hero.instance_id, db, true) > 0
					or not get_strikeable_weapons(state, player_id, hero.instance_id, db).is_empty()) \
				and not _has_keyword(hero, "cant_attack", db, state) \
				and not hero.has_restriction("cannot_attack"):
			result.append(hero.instance_id)
	# "Opposing allies can't attack." (Lady Jaina) locks ALL of this player's
	# allies — evaluated once here, applied in the ally loop below.
	var allies_locked := _allies_attack_locked(state, player_id, db)
	# Allies (rule 302.2: just_summoned unless Ferocity).
	for card in state.cards_in_zone(player_id + "_ally_row"):
		if allies_locked:
			continue
		if card.is_exhausted:
			continue
		# Rule 305.3a: Totems can't be proposed as attackers.
		if db and is_totem_def(db.get_def(card.card_def_id) as CardDef):
			continue
		if card.just_summoned and not _has_keyword(card, "ferocity", db, state):
			continue
		# "can't attack" allies (e.g. Guardian Steelhorn) are never legal attackers.
		if _has_keyword(card, "cant_attack", db, state):
			continue
		if card.has_restriction("cannot_attack"):
			continue
		result.append(card.instance_id)
	return result


# Returns instance_ids of all legal defenders the given attacker can target.
static func get_legal_defenders(state: GameState, attacker_id: String, db) -> Array[String]:
	var attacker := state.get_card(attacker_id)
	if not attacker:
		return []
	var opp := _other_player(state, attacker.controller)
	var result: Array[String] = []
	for card in state.cards_in_zone(opp + "_ally_row"):
		if not _has_keyword(card, "elusive", db, state):
			result.append(card.instance_id)
	var ps := state.players.get(opp) as PlayerState
	if ps and ps.hero_instance_id != "":
		var hero := state.get_card(ps.hero_instance_id)
		if hero and not _has_keyword(hero, "elusive", db, state):
			result.append(hero.instance_id)
	# sarmoth_taunt: if a taunt card is among the legal defenders, restrict to taunt cards only.
	if db:
		var taunt_ids: Array[String] = []
		for id in result:
			var c := state.get_card(id)
			if c and _has_effect_flag(db.get_def(c.card_def_id) as CardDef, "sarmoth_taunt"):
				taunt_ids.append(id)
		if not taunt_ids.is_empty():
			return taunt_ids
	return result


# Returns instance_ids of all characters that can protect this combat (rule 602.2).
# The defending player chooses whether to use one of these — it is NOT mandatory.
static func get_legal_protectors(state: GameState, attacker_id: String,
		defender_id: String, db) -> Array[String]:
	var defender := state.get_card(defender_id)
	if not defender:
		return []
	# Stealth (602.2a): "While an attacker has Stealth, characters can't protect."
	var attacker := state.get_card(attacker_id)
	if attacker and _has_keyword(attacker, "stealth", db, state):
		return []
	var defending_player := defender.controller
	# "Opposing heroes and allies can't protect." (Hannah the Unstoppable):
	# if the defending player's opponent controls this aura, no character the
	# defending player controls may protect — evaluated live, never cached.
	if _protect_locked(state, defending_player, db):
		return []
	var defender_zone := state.zones.get(defender.zone_id) as Zone
	var defender_is_hero := defender_zone and defender_zone.zone_type == "hero_row"
	var result: Array[String] = []
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(defending_player + zone_suffix):
			if card.instance_id == defender_id:
				continue  # 602.2b: a proposed defender can't protect itself
			if card.is_exhausted:
				continue  # must be ready (will be exhausted when it protects)
			# "Can't protect this turn" restriction buff (Frost Shock).
			if card.has_restriction("cannot_protect"):
				continue
			if _has_keyword(card, "protector", db, state):
				result.append(card.instance_id)
				continue
			# Draconian Deflector-style grant: an in-play card with
			# hero_has_protector gives its controller's HERO Protector.
			if db:
				var ps := state.players.get(defending_player) as PlayerState
				if ps and card.instance_id == ps.hero_instance_id \
						and _hero_has_protector_grant(state, defending_player, db):
					result.append(card.instance_id)
					continue
			# Old Bones-style restricted grant: "can protect your hero" — only
			# usable when the hero is the proposed defender, not for allies.
			if defender_is_hero and db:
				var cdef := db.get_def(card.card_def_id) as CardDef
				if cdef and _has_effect_flag(cdef, "protect_hero_only"):
					result.append(card.instance_id)
	return result


# "Opposing allies can't attack." (Lady Jaina Proudmoore): true when the given
# player's OPPONENT controls an in-play card carrying the opposing_allies_cant_attack
# effect flag. A continuous static effect — evaluated live, never cached — that
# stops the player's allies (not their hero) from being proposed as attackers.
static func _allies_attack_locked(state: GameState, player_id: String, db) -> bool:
	if not db:
		return false
	var opp := _other_player(state, player_id)
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(opp + zone_suffix):
			if _has_effect_flag(db.get_def(card.card_def_id) as CardDef, "opposing_allies_cant_attack"):
				return true
	return false


# "Opposing heroes and allies can't protect." (Hannah the Unstoppable): true when
# the given player's OPPONENT controls an in-play card carrying the
# opposing_cant_protect effect flag. A continuous static effect — evaluated live,
# never cached — that stops the player from protecting with any character.
static func _protect_locked(state: GameState, player_id: String, db) -> bool:
	if not db:
		return false
	var opp := _other_player(state, player_id)
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(opp + zone_suffix):
			if _has_effect_flag(db.get_def(card.card_def_id) as CardDef, "opposing_cant_protect"):
				return true
	return false


# Donna Calister (azeroth_181): "When an opposing hero or ally attacks, ready
# Donna Calister." Called as a combat step starts. Readies every exhausted
# in-play card carrying the `ready_on_opposing_attack` effect flag whose
# controller is NOT the attacking player (i.e. the attacker is "opposing" to
# them). Non-targeted, no cost — resolved immediately rather than via the chain.
static func _ready_on_opposing_attack(state: GameState, attacker_id: String,
		db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if not db:
		return events
	var attacker := state.get_card(attacker_id)
	if not attacker:
		return events
	var defender_side := _other_player(state, attacker.controller)
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for card in state.cards_in_zone(defender_side + zone_suffix):
			if _has_effect_flag(db.get_def(card.card_def_id) as CardDef, "ready_on_opposing_attack"):
				events.append_array(GameLogic.ready_card(state, card.instance_id))
	return events


# Apply a damaged-target restriction rider (Frostbolt / Frost Shock). field is a
# "+"-joined list of restriction names (e.g. "cannot_attack+cannot_protect").
# Each becomes a restriction Buff lasting until the end of this turn (turns:1),
# reusing the same machinery as Litori Frostburn's target_cant_attack flip.
# Ravenous Bite: place each announced target's signed "this turn" ATK buff.
# Duration "turns":1 rides the existing end-of-turn buff sweep (the same one
# that clears Litori's cannot_attack), so "this turn" expiry is automatic and
# times correctly when the card is cast during the opponent's turn.
static func _apply_atk_swing(state: GameState, action: PendingAction,
		def: CardDef, source_id: String, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var amounts := atk_swing_amounts(def)
	var keys := ["target_id", "target_id_2"]
	for i in amounts.size():
		if i >= keys.size():
			break
		var tid: String = action.params.get(keys[i], "")
		var amount: int = amounts[i]
		# Per-target re-check (706): this half fizzles alone if its ally left
		# play or became Untargetable after the announce.
		if not _is_legal_target(state, tid, db) or not _is_ally(state, tid):
			continue
		var target := state.get_card(tid)
		target.active_buffs.append(Buff.make(
			"ravenous_bite_atk_this_turn", source_id, "atk", amount, "turns", 1))
		events.append(GameEvent.atk_swing_applied(tid, source_id, amount))
	return events


static func _apply_damage_riders(state: GameState, target_id: String,
		source_id: String, field: String) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var target := state.get_card(target_id)
	if not target:
		return events
	for restriction in field.split("+"):
		var r := restriction.strip_edges()
		if r == "":
			continue
		target.active_buffs.append(Buff.make(
			"frost_" + r + "_this_turn", source_id, r, 1, "turns", 1))
		if r == "cannot_attack":
			events.append(GameEvent.cant_attack_applied(target_id, source_id))
		elif r == "cannot_protect":
			events.append(GameEvent.cant_protect_applied(target_id, source_id))
	return events


# "Your hero has protector" (Draconian Deflector): true when any in-play card
# in the player's hero_row carries the hero_has_protector effect flag.
static func _hero_has_protector_grant(state: GameState, player_id: String, db) -> bool:
	for card in state.cards_in_zone(player_id + "_hero_row"):
		if _has_effect_flag(db.get_def(card.card_def_id) as CardDef, "hero_has_protector"):
			return true
	return false


static func _has_effect_flag(def: CardDef, flag: String) -> bool:
	if not def:
		return false
	for segment in def.effects.split("|"):
		if segment.strip_edges() == flag:
			return true
	return false


# True if a weapon struck by wielder_id this combat carries the
# "strike_grants_long_range" effects flag (Ancient Bone Bow).
static func _struck_weapon_grants_long_range(state: GameState, wielder_id: String, db) -> bool:
	if not db or wielder_id == "":
		return false
	for weapon_id in state.combat_struck_weapons.get(wielder_id, []) as Array:
		var def := db.get_def(state.get_card(weapon_id).card_def_id) as CardDef
		if def and "strike_grants_long_range" in def.effects.split("|"):
			return true
	return false


# Combat damage TYPE for a character (rule 303.2b). A hero's combat damage takes
# the type of the weapon it struck with this combat (Blackcrow → ranged); with no
# struck weapon — and for allies, whose printed dmg_type is their own — it is the
# card's printed type. Only used to feed the typed replacement effects below.
static func _combat_damage_type(state: GameState, wielder_id: String, db) -> String:
	if not db or wielder_id == "":
		return ""
	for weapon_id in state.combat_struck_weapons.get(wielder_id, []) as Array:
		var wdef := db.get_def(state.get_card(weapon_id).card_def_id) as CardDef
		if wdef and wdef.dmg_type != "":
			return wdef.dmg_type
	var card := state.get_card(wielder_id)
	if not card:
		return ""
	var def := db.get_def(card.card_def_id) as CardDef
	return def.dmg_type if def else ""


# Aspect of the Hawk / Shadowform / World in Flames on COMBAT damage. These read
# "if your hero would deal <type> damage" with no ability or non-combat clause,
# so a hero striking a Ranged weapon under Aspect of the Hawk deals +1 — combat
# damage simply has its own path instead of defer_packets, so the replacements
# have to be applied here too. Same fixed order as defer_packets (flat typed
# bonus, then the doubling); Chromatic Cloak's `from_ability` bonus deliberately
# does NOT apply — combat damage is not dealt with an ability.
static func _combat_replacements(state: GameState, db, source_id: String,
		amount: int) -> int:
	if amount <= 0 or db == null or not _is_hero(state, source_id):
		return amount
	var p := {
		"source": source_id,
		"amount": amount,
		"dmg_type": _combat_damage_type(state, source_id, db),
	}
	p["amount"] = _typed_damage_bonus_amount(state, db, p)
	p["amount"] = _fire_doubled_amount(state, db, p)
	return int(p["amount"])


static func _has_keyword(card: CardInstance, keyword: String, db,
		state: GameState = null) -> bool:
	if keyword in card.granted_keywords:
		return true
	# Buff-granted keywords with a duration (Hidden Enemies: "Target ally has
	# ferocity this turn") — a Buff with stat "grant_<keyword>". Expires with
	# the normal end-of-turn buff sweep and clears on leaving play, which plain
	# granted_keywords (recomputed continuous grants) don't do per-turn.
	for b in card.active_buffs:
		if b.stat == "grant_" + keyword and b.amount > 0:
			return true
	# "Ongoing: All allies have <keyword>." (Lust for Battle, From the Shadows).
	# A board-wide continuous grant, so it can't live on the card the way the
	# two grants above do — it is read LIVE here, from whatever aura cards are
	# in play at this instant. That is what makes it cover BOTH parties' allies
	# and allies that entered play after the aura resolved, and makes the grant
	# lift the moment the aura leaves play. `state` is optional only because a
	# handful of def-only probes have no state to give; every gate site that
	# governs an aura-granted keyword passes it.
	if state != null and _ally_keyword_aura(state, keyword, db) \
			and _is_ally(state, card.instance_id):
		return true
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def and keyword in def.keywords:
			return true
	return false


# True when EITHER player controls an in-play card granting `keyword` to all
# allies (`all_allies_keyword:<keyword>`). "All allies" is board-wide, so unlike
# _allies_attack_locked / _protect_locked this scans both players' rows and is
# not relative to a controller — a Horde Lust for Battle gives the Alliance
# player's allies ferocity too. Evaluated live, never cached.
static func _ally_keyword_aura(state: GameState, keyword: String, db) -> bool:
	if not db or keyword == "":
		return false
	for pid in state.players:
		for zone_suffix in ["_hero_row", "_ally_row"]:
			for card in state.cards_in_zone(pid + zone_suffix):
				var def := db.get_def(card.card_def_id) as CardDef
				if not def or def.effects == "":
					continue
				for entry in def.effects.split("|"):
					var parts := entry.strip_edges().split(":")
					if parts[0].strip_edges() == "all_allies_keyword" \
							and parts.size() > 1 and parts[1].strip_edges() == keyword:
						return true
	return false


# ── Combat window helpers ──────────────────────────────────────────────────────

# Called when the Attack Window closes (both players passed, chain empty).
# Runs the protect point or opens the Defend Window.
static func _close_attack_window(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	# Rule 602.2: if either combatant left play during the window, go to conclusion.
	if not state.is_in_play(state.combat_attacker) \
			or not state.is_in_play(state.combat_defender):
		events.append_array(_do_combat_conclusion(state, db))
		return events
	# Protect point — still not using the chain (rule 602.2).
	var protectors := get_legal_protectors(state, state.combat_attacker, state.combat_defender, db)
	if not protectors.is_empty():
		state.in_protect_point = true
		events.append(GameEvent.protect_point_opened(
			state.combat_attacker, state.combat_defender, protectors))
	else:
		events.append_array(_open_defend_window(state, db))
	return events


# Opens the Defend Window (rule 602.3): the proposed defender becomes the defender
# and both players get another priority window before damage. If the defender is
# a hero whose controller can strike with a weapon, the defending strike point
# opens first (602.3 — "at this time and only at this time", no chain).
static func _open_defend_window(state: GameState, db = null) -> Array[GameEvent]:
	# If either combatant left play, skip straight to conclusion.
	if not state.is_in_play(state.combat_attacker) \
			or not state.is_in_play(state.combat_defender):
		return _do_combat_conclusion(state, db)
	var strike := _open_strike_point(state, state.combat_defender, "defend", db)
	if not strike.is_empty():
		return strike
	state.combat_defend_window = true
	return [GameEvent.defend_window_opened(state.combat_attacker, state.combat_defender)]


# ── Combat — resolution ────────────────────────────────────────────────────────

static func _resolve_propose_combat(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var attacker_id: String = action.params.get("attacker_id", "")
	var defender_id: String = action.params.get("defender_id", "")
	var attacker := state.get_card(attacker_id)
	var defender := state.get_card(defender_id)

	# Rule 601.3: recheck legality as proposal resolves.
	# If either combatant is gone or now illegal, proposal fizzles — NO exhaust.
	# A "can't attack this turn" modifier applied in response (e.g. Litori
	# Frostburn) makes the proposal illegal here — the attacker never exhausts
	# and combat never starts. Once the combat step HAS started (attack window
	# open), the same modifier is too late to stop it (602.1: the attacker is
	# already attacking; "can't attack" is not a remove-from-combat effect).
	if not attacker or not defender \
			or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id) \
			or attacker.is_exhausted \
			or _has_keyword(attacker, "cant_attack", db, state) \
			or attacker.has_restriction("cannot_attack") \
			or _has_keyword(defender, "elusive", db, state):
		return [GameEvent.make("action_fizzled", {
			"action_type": "propose_combat", "reason": "illegal_at_resolution",
		})]

	# Rule 602.1: combat step starts — attacker exhausts now, then Attack Window opens.
	var events: Array[GameEvent] = []
	state.combat_attacker = attacker_id
	state.combat_defender = defender_id
	events.append_array(GameLogic.exhaust_card(state, attacker_id))
	events.append(GameEvent.combat_started(attacker_id, defender_id))
	# Donna Calister: "When an opposing hero or ally attacks, ready Donna
	# Calister." Triggers off the attack (any attacker), for the non-attacking
	# side. Non-targeted, no cost — resolved immediately as the combat step
	# starts (before the strike point / attack window) so she's ready to
	# protect this same combat. See data/rules_deviations.md "Donna Calister".
	events.append_array(_ready_on_opposing_attack(state, attacker_id, db))
	# Berserking: "When your hero attacks, remove all berserk counters from
	# Berserking. Your hero has +1 ATK this combat for each counter you removed."
	# Fires as the combat step starts, before the strike point / attack window —
	# no cost, no choice, so it resolves inline rather than on the chain.
	events.append_array(_fire_berserking_on_attack(state, attacker_id, db))
	# Morik: "When Morik attacks, each player draws a card." Non-targeted,
	# mandatory and free, so it resolves inline as the combat step starts —
	# nothing goes on the chain. See data/rules_deviations.md "Morik".
	events.append_array(_fire_attack_draw_each_player(state, attacker_id, db))
	# Rule 602.1: the attacking player can strike with weapons now (and only
	# now), before the attack window opens. Doesn't use the chain.
	var strike := _open_strike_point(state, attacker_id, "attack", db)
	if not strike.is_empty():
		events.append_array(strike)
		return events
	# Windseer Tarus: "When [this] attacks for the first time each turn, you may
	# pay X. If you do, ready him." Opens a pending choice mirroring the strike
	# point, before the attack window (the trigger fires as the combat step starts).
	# Resolved immediately, not via the chain — see data/rules_deviations.md
	# "Windseer Tarus".
	var ready_pt := _open_ready_on_attack_point(state, attacker_id, db)
	if not ready_pt.is_empty():
		events.append_array(ready_pt)
		return events
	# Chops / Voss Treebender: "When [this] attacks, you may exhaust target hero
	# or ally." The trigger fires as the combat step starts (602.1); it resolves
	# BEFORE the attack window opens, so exhausting a ready Protector here denies
	# the protect point (602.2 requires exhausting a ready character to protect).
	# Direct-call choice, not the chain — see data/rules_deviations.md
	# "Attack-exhaust triggers".
	var exhaust_pt := _open_attack_exhaust_point(state, attacker_id, db)
	if not exhaust_pt.is_empty():
		events.append_array(exhaust_pt)
		return events
	state.combat_attack_window = true
	events.append(GameEvent.attack_window_opened(attacker_id, defender_id))
	return events


# Berserking (`berserk_counter_on_hero_damage` + `berserk_atk_on_hero_attack:N`):
# when the controller's HERO attacks, every Berserking they control dumps its
# berserk counters into a "+N ATK this combat" grant on that hero. Only the hero
# attacking triggers it — an attacking ally leaves the counters alone.
static func _fire_berserking_on_attack(state: GameState, attacker_id: String,
		db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if not db:
		return events
	var atk := state.get_card(attacker_id)
	if not atk:
		return events
	var ps := state.players.get(atk.controller) as PlayerState
	if not ps or ps.hero_instance_id != attacker_id:
		return events
	for card in state.cards_in_zone(atk.controller + "_hero_row"):
		var def := db.get_def(card.card_def_id) as CardDef
		if not def or def.effects == "":
			continue
		var per := 0
		for seg in def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0].strip_edges() == "berserk_atk_on_hero_attack":
				per = int(p[1]) if p.size() > 1 else 1
				break
		if per <= 0:
			continue
		var removed := int(card.counters.get("berserk", 0))
		if removed <= 0:
			continue
		card.counters.erase("berserk")
		events.append(GameEvent.counter_changed(card.instance_id, "berserk", removed, 0))
		state.combat_atk_bonus[attacker_id] = \
			int(state.combat_atk_bonus.get(attacker_id, 0)) + per * removed
	return events


# Morik (`on_attack_draw_each_player:N`): "When Morik attacks, each player draws
# a card." Fires only when the flagged card is ITSELF the attacker (an attacking
# hero or another ally leaves it alone). Draws go in turn order — the attacker's
# controller first, then the opponent — through GameLogic.draw_one, so the decked
# rule (410.6b) applies to this forced draw like any other.
static func _fire_attack_draw_each_player(state: GameState, attacker_id: String,
		db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if not db:
		return events
	var atk := state.get_card(attacker_id)
	if not atk:
		return events
	var def := db.get_def(atk.card_def_id) as CardDef
	if not def or def.effects == "":
		return events
	var amount := 0
	for seg in def.effects.split("|"):
		var p := seg.strip_edges().split(":")
		if p[0].strip_edges() == "on_attack_draw_each_player":
			amount = int(p[1]) if p.size() > 1 else 1
			break
	if amount <= 0:
		return events
	for pid in [atk.controller, _other_player(state, atk.controller)]:
		if pid == "":
			continue
		for _i in range(amount):
			events.append_array(_draw_one(state, pid))
	return events


# Opens a ready-on-attack point (Windseer Tarus) for the attacker's controller if
# the attacker has the `ready_on_attack:COST` flag, this is its first attack this
# turn, and the controller can afford COST. Marks the once-per-turn trigger as
# fired (whether or not the player ends up paying). Returns [] when nothing to
# offer, so the caller falls through to opening the attack window directly.
static func _open_ready_on_attack_point(state: GameState, attacker_id: String,
		db) -> Array[GameEvent]:
	if not db:
		return []
	var atk := state.get_card(attacker_id)
	if not atk:
		return []
	var def := db.get_def(atk.card_def_id) as CardDef
	var cost := -1
	if def and def.effects != "":
		for seg in def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0].strip_edges() == "ready_on_attack":
				cost = int(p[1]) if p.size() > 1 else 0
				break
	# Windfury Totem (`party_ready_on_attack:COST`): "When each hero or ally in
	# your party attacks for the first time each turn, you may pay X. If you do,
	# ready that character." A party-wide grant — falls back to the controller's
	# in-play totem when the attacker has no own `ready_on_attack` flag. Both
	# share the `attacked_this_turn` gate below, so a character covered by BOTH
	# (e.g. Windseer Tarus under a Windfury Totem) still gets only ONE ready per
	# turn — it can attack + ready once, never twice over.
	if cost < 0:
		cost = _party_ready_on_attack_cost(state, atk.controller, db)
	if cost < 0:
		return []
	# "for the first time each turn" — only offer once per turn.
	if int(atk.counters.get("attacked_this_turn", 0)) > 0:
		return []
	atk.counters["attacked_this_turn"] = 1
	if state.get_available_resources(atk.controller) < cost:
		return []
	state.pending_ready_player  = atk.controller
	state.pending_ready_card_id = attacker_id
	state.pending_ready_cost    = cost
	return [GameEvent.ready_on_attack_opened(atk.controller, attacker_id, cost)]


# Windfury Totem: the lowest `party_ready_on_attack:COST` among controller's
# in-play cards (a party-wide "ready that character on its first attack" grant),
# or -1 when the controller has none in play. Read live — the grant lifts the
# moment the totem leaves play.
static func _party_ready_on_attack_cost(state: GameState, controller: String,
		db) -> int:
	if not db:
		return -1
	var best := -1
	for card in state.cards_in_play(controller):
		var d := db.get_def(card.card_def_id) as CardDef
		if not d or d.effects == "":
			continue
		for seg in d.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0].strip_edges() == "party_ready_on_attack":
				var c := int(p[1]) if p.size() > 1 else 0
				if best < 0 or c < best:
					best = c
	return best


# Entry point for the ready-on-attack decision (NOT chain-based — called directly
# by the scene, like choose_strike). pay == false means decline. Pays the cost and
# readies the attacker (it stays the combat_attacker, so this combat proceeds; it's
# ready again afterward to attack a second time), then opens the held attack window.
static func choose_ready_on_attack(state: GameState, pay: bool,
		db = null) -> Array[GameEvent]:
	if state.pending_ready_player == "":
		return []
	var player_id := state.pending_ready_player
	var card_id   := state.pending_ready_card_id
	var cost      := state.pending_ready_cost
	state.pending_ready_player  = ""
	state.pending_ready_card_id = ""
	state.pending_ready_cost    = 0

	var events: Array[GameEvent] = []
	if pay and state.is_in_play(card_id) \
			and state.get_available_resources(player_id) >= cost:
		if cost > 0:
			events.append_array(_pay_resources(state, player_id, cost))
		events.append_array(GameLogic.ready_card(state, card_id))
		events.append(GameEvent.readied_on_attack(player_id, card_id, cost))

	# Fall through to the attack-exhaust point (a card carrying both flags),
	# then open the attack window this ready point was holding up.
	var exhaust_pt := _open_attack_exhaust_point(state, state.combat_attacker, db)
	if not exhaust_pt.is_empty():
		events.append_array(exhaust_pt)
		return events
	state.combat_attack_window = true
	events.append(GameEvent.attack_window_opened(
		state.combat_attacker, state.combat_defender))
	return events


# Opens an attack-exhaust point (Chops / Voss Treebender) for the attacker's
# controller if the attacker has the `on_attack_exhaust_target` flag. The choice
# is optional ("you may"), so it always opens when the flag is present — the
# player may decline. Returns [] when the attacker has no such power, so the
# caller falls through to opening the attack window directly.
static func _open_attack_exhaust_point(state: GameState, attacker_id: String,
		db) -> Array[GameEvent]:
	if not db:
		return []
	var atk := state.get_card(attacker_id)
	if not atk:
		return []
	var def := db.get_def(atk.card_def_id) as CardDef
	if not def or def.effects == "":
		return []
	var has_flag := false
	for seg in def.effects.split("|"):
		if seg.strip_edges().split(":")[0].strip_edges() == "on_attack_exhaust_target":
			has_flag = true
			break
	if not has_flag:
		return []
	state.pending_attack_exhaust_player    = atk.controller
	state.pending_attack_exhaust_source_id = attacker_id
	return [GameEvent.attack_exhaust_opened(atk.controller, attacker_id)]


# Entry point for the attack-exhaust decision (NOT chain-based — called directly
# by the scene, like choose_ready_on_attack). target_id == "" means decline.
# Exhausts the chosen hero or ally (706 legality re-checked; exhausting an
# already-exhausted target is a no-op), then opens the held attack window. Note
# that exhausting the proposed DEFENDER does not stop the combat — 601.3 has
# already passed and exhaustion is not a remove-from-combat effect.
static func choose_attack_exhaust(state: GameState, target_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_attack_exhaust_player == "":
		return []
	var player_id := state.pending_attack_exhaust_player
	var source_id := state.pending_attack_exhaust_source_id
	state.pending_attack_exhaust_player    = ""
	state.pending_attack_exhaust_source_id = ""

	var events: Array[GameEvent] = []
	if target_id != "" and _is_legal_target(state, target_id, db):
		events.append_array(GameLogic.exhaust_card(state, target_id))
		events.append(GameEvent.attack_exhaust_resolved(player_id, source_id, target_id))

	# Open the attack window this exhaust point was holding up.
	state.combat_attack_window = true
	events.append(GameEvent.attack_window_opened(
		state.combat_attacker, state.combat_defender))
	return events


# Legal targets for the attack-exhaust trigger: every hero and ally in play
# ("target hero or ally"), subject to standard targeting restrictions — the
# same set as a totem trigger.
static func get_attack_exhaust_targets(state: GameState, db) -> Array[String]:
	return get_totem_targets(state, db)


# Entry point for the protect-point decision (NOT chain-based — called directly
# by the scene after the defending player makes their choice).
# protector_id == "" means the defending player chose to skip protection.
static func choose_protector(state: GameState, protector_id: String,
		db = null) -> Array[GameEvent]:
	if not state.in_protect_point:
		return []
	state.in_protect_point = false

	var events: Array[GameEvent] = []
	var defender := state.get_card(state.combat_defender)
	var defending_player := defender.controller if defender else ""

	if protector_id != "" and state.is_in_play(protector_id):
		# Rule 602.2: exhaust the protector; it becomes the new defender.
		events.append_array(GameLogic.exhaust_card(state, protector_id))
		state.combat_defender = protector_id
		state.combat_protector = protector_id
		events.append(GameEvent.protect_chosen(protector_id, defending_player))
	else:
		events.append(GameEvent.protect_chosen("", defending_player))

	# Rule 602.3: protect point concludes, now open the Defend Window.
	events.append_array(_open_defend_window(state, db))
	return events


# Rule 603: simultaneous damage + PPP + win check.
static func _do_combat_conclusion(state: GameState, db = null) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var attacker_id := state.combat_attacker
	var defender_id := state.combat_defender

	var attacker := state.get_card(attacker_id) if attacker_id != "" else null
	var defender := state.get_card(defender_id) if defender_id != "" else null

	# Rule 603.1b: if either side is gone, no damage.
	if not attacker or not defender \
			or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id):
		# Announce WHY nothing happened: the combat is cancelled, not resolved.
		# The renderer uses this (and the cancelled flag below) to show a notice
		# and skip the attack animation.
		var reason := "defender_gone"
		if attacker_id == "":
			reason = "attacker_removed"   # Blink & co. cleared combat_attacker
		elif not attacker or not state.is_in_play(attacker_id):
			reason = "attacker_gone"
		state.combat_attacker = ""
		state.combat_defender = ""
		state.combat_protector = ""
		state.combat_struck_weapons.clear()   # 303.2a — associations end with the combat step
		state.combat_atk_bonus.clear()        # "this combat" grants end too (Berserking)
		events.append(GameEvent.combat_cancelled(attacker_id, defender_id, reason))
		events.append(GameEvent.combat_concluded(attacker_id, defender_id, 0, 0, true))
		_clear_damage_prevention(state)   # threat gone — unspent block expires
		return events

	# Rule 603.1: both deal damage simultaneously.
	# Capture ATK values BEFORE applying any damage to either side, and before
	# clearing combat_attacker below — "while attacking" modifiers (Zorm,
	# Rayder, For the Horde!) key off state.combat_attacker in get_atk, so it
	# must still be set while these are computed.
	var atk_dmg := state.get_atk(attacker_id, db)   # to defender
	var def_dmg := state.get_atk(defender_id, db)   # to attacker (0 for heroes, per 205.1)
	# Rule glossary "Long-Range": while attacking, defenders can't deal combat damage.
	# Ancient Bone Bow grants long-range for the combat when the wielder strikes it.
	if _has_keyword(attacker, "long_range", db, state) \
			or _struck_weapon_grants_long_range(state, attacker_id, db):
		def_dmg = 0
	# Typed replacement effects on combat damage (Aspect of the Hawk's ranged +1
	# on a struck Blackcrow, Shadowform, World in Flames). Read BEFORE the struck-
	# weapon associations are cleared below — the damage type comes from them.
	atk_dmg = _combat_replacements(state, db, attacker_id, atk_dmg)
	def_dmg = _combat_replacements(state, db, defender_id, def_dmg)
	# Annihilator: "can't be prevented" is scoped to the weapon the hero STRUCK
	# with this combat, so both sides must be read before the associations are
	# cleared below (303.2a).
	var atk_unpreventable := GameLogic.is_damage_unpreventable(state, db, attacker_id, true)
	var def_unpreventable := GameLogic.is_damage_unpreventable(state, db, defender_id, true)
	state.combat_attacker = ""
	state.combat_defender = ""
	state.combat_protector = ""
	state.combat_struck_weapons.clear()   # 303.2a — associations end with the combat step
	state.combat_atk_bonus.clear()        # "this combat" grants end too (Berserking)
	events.append(GameEvent.combat_concluded(attacker_id, defender_id, atk_dmg, def_dmg))

	# Trigger key facts, captured BEFORE damage lands (a combatant's zone / role
	# may change once damage is applied).
	var attacker_was_ally := _is_ally(state, attacker_id)
	var defender_was_ally := _is_ally(state, defender_id)
	var defender_ps := state.players.get(defender.controller) as PlayerState
	var defender_is_hero := defender_ps != null \
			and defender_ps.hero_instance_id == defender_id
	# Brigg: "…deals combat damage to an ally WITH DAMAGE ON IT". The condition
	# describes the ally as the damage is dealt, i.e. damage it already carried —
	# Brigg's own combat damage does not qualify it. That has to be sampled here,
	# before the packets land, or every ally Brigg hits would trivially satisfy it
	# and the clause would mean nothing. See data/rules_deviations.md "Brigg".
	var attacker_was_damaged := attacker.damage_taken > 0
	var defender_was_damaged := defender.damage_taken > 0

	# Apply both damage packets first (deal_damage no longer auto-destroys),
	# then check fatalities on both after — true simultaneity.
	# combat_attack marks the attacker→defender packet — Brother Rhone's shield
	# only stops damage from ATTACKING allies, never a defender's retaliation.
	var atk_events := GameLogic.deal_damage(state, attacker_id, defender_id, atk_dmg, db,
		{"unpreventable": atk_unpreventable, "combat_attack": true})
	events.append_array(atk_events)
	var def_events := GameLogic.deal_damage(state, defender_id, attacker_id, def_dmg, db,
		{"unpreventable": def_unpreventable})
	events.append_array(def_events)
	_clear_damage_prevention(state)   # combat over — unspent block expires

	# Did the attacker actually LAND combat damage on the hero? (armor DEF / block
	# may have absorbed all of it — then the trigger doesn't fire.)
	var hero_dmg_landed := 0
	for ev in atk_events:
		if ev.event_type == "damage_dealt" and ev.payload.get("target", "") == defender_id:
			hero_dmg_landed += int(ev.payload.get("amount", 0))

	# PPP: state-based destruction check after both packets have landed.
	for cid in [defender_id, attacker_id]:
		var card := state.get_card(cid)
		if not card or not state.is_in_play(cid):
			continue
		if state.get_current_hp(cid, db) > 0:
			continue
		var zone := state.zones.get(card.zone_id) as Zone
		if zone and zone.zone_type == "hero_row":
			events.append(GameEvent.game_over(
				_other_player(state, card.controller), card.controller))
		else:
			events.append_array(_check_destroyed_trigger(state, cid, attacker_id, db))

	# Green Whelp Armor (rule 305.2 triggered equipment power): when an attacking
	# ally deals combat damage to the wielder's hero, the wielder MAY pay to bounce
	# that ally to its owner's hand. Opened here at conclusion; resolved directly
	# via choose_whelp_bounce() (like the strike point). Both hero and attacker must
	# still be in play, and the wielder must be able to afford the cost.
	events.append_array(_maybe_open_whelp_bounce(
		state, attacker_id, defender_id, defender.controller if defender else "",
		attacker_was_ally, defender_is_hero, hero_dmg_landed, db))

	# Randipan / Samuel Grey (rule 703): "When [this] deals combat damage to a
	# defending hero, ..." — fires only when the attacker's combat damage
	# actually LANDED on a defending hero (armor DEF/block absorbing all of it,
	# or a protecting ally taking the hit, means no trigger). Still fires if
	# the attacker died to a defensive weapon strike — the damage was dealt.
	events.append_array(_fire_combat_damage_to_hero_triggers(
		state, attacker_id, defender.controller if defender else "",
		defender_is_hero, hero_dmg_landed, db))

	# Devilsaur Leggings (rule 305.2 triggered equipment power): "When your hero
	# deals combat damage to an ally, destroy that ally." Fires when the
	# wielder's hero dealt ≥1 combat damage to an ally this combat — as the
	# attacker hitting an ally defender, or as a protecting defender retaliating
	# onto an attacking ally. Mandatory (no cost/choice); a no-op if the ally
	# already died to the combat damage (the card matters when the ally survives).
	events.append_array(_fire_hero_combat_dmg_destroys_ally(
		state, attacker_id, defender_id, attacker_was_ally, defender_was_ally,
		atk_events, def_events, db))

	# Cold Blood ("When your hero deals damage to an ally this turn, destroy that
	# ally") — the same trigger point, but sourced from the turn event log, so it
	# covers a hero attacking an ally and a hero retaliating onto an attacking
	# ally without needing either case spelled out here. Both combat packets have
	# landed by now, so a defender that killed the hero's target still retaliated.
	events.append_array(_fire_cold_blood(state, db))

	# Iceblade Hacker (rule 305.2 triggered equipment power): "When your hero
	# deals combat damage to an ally, that ally can't ready during its
	# controller's next ready step." Same trigger point as Devilsaur Leggings,
	# but applies the gouge ready-lock instead of a destroy — so it matters
	# when the ally SURVIVES the combat damage.
	events.append_array(_fire_hero_combat_dmg_locks_ally_ready(
		state, attacker_id, defender_id, attacker_was_ally, defender_was_ally,
		atk_events, def_events, db))

	# Brigg (rule 703 triggered ally power): "When Brigg deals combat damage to
	# an ally with damage on it, destroy that ally." Devilsaur Leggings' shape
	# with the source being the ALLY itself rather than the wielder's hero, and
	# gated on damage the target already carried (sampled before the packets).
	events.append_array(_fire_combat_dmg_destroys_damaged_ally(
		state, attacker_id, defender_id, attacker_was_ally, defender_was_ally,
		attacker_was_damaged, defender_was_damaged, atk_events, def_events, db))

	return events


# on_combat_damage_destroys_damaged_ally ally flag (Brigg). See the call site in
# _do_combat_conclusion. Mirrors _fire_hero_combat_dmg_destroys_ally, with two
# differences: the flag is read off the SOURCE card's own def (it is an ally
# power, not an equipment the hero wields), and the victim must have carried
# damage BEFORE this combat's packets landed — `*_was_damaged` is sampled ahead
# of the damage for exactly that reason.
#
# Like the Devilsaur trigger this is mandatory (no cost, no choice) and is a
# no-op when the victim already died to the combat damage — the card matters
# when a damaged ally SURVIVES the hit. It fires in both combat roles, since the
# printed text says "deals combat damage", not "attacks": Brigg attacking into
# an ally defender, and Brigg as a defender retaliating onto an attacking ally.
static func _fire_combat_dmg_destroys_damaged_ally(state: GameState,
		attacker_id: String, defender_id: String,
		attacker_was_ally: bool, defender_was_ally: bool,
		attacker_was_damaged: bool, defender_was_damaged: bool,
		atk_events: Array, def_events: Array, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if db == null:
		return events
	# Source attacking → ally defender that already had damage on it.
	if defender_was_ally and defender_was_damaged \
			and _card_has_flag(state, attacker_id, "on_combat_damage_destroys_damaged_ally", db) \
			and _combat_dmg_landed(atk_events, defender_id) > 0 \
			and state.is_in_play(defender_id):
		events.append_array(_destroy_card_trigger(state, defender_id, attacker_id, db))
	# Source defending → retaliation onto an attacking ally that already had damage.
	if attacker_was_ally and attacker_was_damaged \
			and _card_has_flag(state, defender_id, "on_combat_damage_destroys_damaged_ally", db) \
			and _combat_dmg_landed(def_events, attacker_id) > 0 \
			and state.is_in_play(attacker_id):
		events.append_array(_destroy_card_trigger(state, attacker_id, defender_id, db))
	return events


# True when the card itself carries `flag` in its own def's effects recipe (an
# ally's own triggered power), as opposed to _hero_wields_flag's "a hero whose
# controller has an equipment carrying the flag".
static func _card_has_flag(state: GameState, card_id: String, flag: String,
		db) -> bool:
	if db == null:
		return false
	var card := state.get_card(card_id)
	if not card:
		return false
	return _has_effect_flag(db.get_def(card.card_def_id) as CardDef, flag)


# hero_combat_dmg_locks_ally_ready equipment flag (Iceblade Hacker). See the
# call site in _do_combat_conclusion. Mirrors _fire_hero_combat_dmg_destroys_ally
# but sets the gouge_skip_ready counter (consumed at the ally controller's next
# ready step — TurnManager._enter_ready) instead of destroying the ally.
static func _fire_hero_combat_dmg_locks_ally_ready(state: GameState,
		attacker_id: String, defender_id: String,
		attacker_was_ally: bool, defender_was_ally: bool,
		atk_events: Array, def_events: Array, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if db == null:
		return events
	# Hero as attacker → ally defender.
	if defender_was_ally \
			and _hero_wields_flag(state, attacker_id, "hero_combat_dmg_locks_ally_ready", db) \
			and _combat_dmg_landed(atk_events, defender_id) > 0 \
			and state.is_in_play(defender_id):
		state.get_card(defender_id).counters["gouge_skip_ready"] = 1
		events.append(GameEvent.make("card_ready_locked",
				{"card_id": defender_id, "source_id": attacker_id}))
	# Hero as protecting defender → retaliation onto the attacking ally.
	if attacker_was_ally \
			and _hero_wields_flag(state, defender_id, "hero_combat_dmg_locks_ally_ready", db) \
			and _combat_dmg_landed(def_events, attacker_id) > 0 \
			and state.is_in_play(attacker_id):
		state.get_card(attacker_id).counters["gouge_skip_ready"] = 1
		events.append(GameEvent.make("card_ready_locked",
				{"card_id": attacker_id, "source_id": defender_id}))
	return events


# hero_combat_dmg_destroys_ally equipment flag (Devilsaur Leggings). See the
# call site in _do_combat_conclusion.
static func _fire_hero_combat_dmg_destroys_ally(state: GameState,
		attacker_id: String, defender_id: String,
		attacker_was_ally: bool, defender_was_ally: bool,
		atk_events: Array, def_events: Array, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if db == null:
		return events
	# Hero as attacker → ally defender.
	if defender_was_ally \
			and _hero_wields_flag(state, attacker_id, "hero_combat_dmg_destroys_ally", db) \
			and _combat_dmg_landed(atk_events, defender_id) > 0 \
			and state.is_in_play(defender_id):
		events.append_array(_destroy_card_trigger(state, defender_id, attacker_id, db))
	# Hero as protecting defender → retaliation onto the attacking ally.
	if attacker_was_ally \
			and _hero_wields_flag(state, defender_id, "hero_combat_dmg_destroys_ally", db) \
			and _combat_dmg_landed(def_events, attacker_id) > 0 \
			and state.is_in_play(attacker_id):
		events.append_array(_destroy_card_trigger(state, attacker_id, defender_id, db))
	return events


# Cold Blood: "When your hero deals damage to an ally this turn, destroy that
# ally." Evaluated off the turn event log rather than hooked into each damage
# source — every damage packet in the game records a `damage_dealt` entry in
# GameLogic.deal_damage (see game_logic/turn_state_flags.md), so this one sweep
# covers combat, abilities, hero/ally powers, totems and end-of-turn burns by
# construction. Called from the two points where damage has just landed:
# _apply_packet_group (the prevention pipeline) and _do_combat_conclusion
# (beside Devilsaur Leggings' trigger, so combat's simultaneous damage has both
# hits placed before anything is destroyed).
#
# Only entries from the grant's own index on are considered, so the trigger is
# forward-looking as printed. Re-scanning already-handled entries is harmless:
# the ally is out of play by then. The destroy is mandatory (no cost, no choice,
# nothing on the chain) and applies to ANY ally the hero damages, the
# controller's own included — the card says "an ally", not "an opposing ally".
static func _fire_cold_blood(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	for pid in state.players:
		var ps := state.players[pid] as PlayerState
		if not ps or ps.cold_blood_from_index < 0 or ps.hero_instance_id == "":
			continue
		var i := ps.cold_blood_from_index
		while i < state.turn_events.size():
			var entry: Dictionary = state.turn_events[i]
			i += 1
			if entry.get("type", "") != "damage_dealt":
				continue
			if entry.get("source_id", "") != ps.hero_instance_id:
				continue
			var victim_id: String = entry.get("target_id", "")
			if not _is_ally(state, victim_id):
				continue
			events.append_array(_destroy_card_trigger(
				state, victim_id, ps.hero_instance_id, db))
	return events


# Operation Recombobulation: "When an opposing non-token ally is destroyed this
# turn, you may put an ally card from your graveyard into your hand." Read off
# the turn event log rather than hooked into each removal effect — every
# destruction in the game records an `ally_destroyed` entry where
# GameEvent.card_destroyed is built (see game_logic/turn_state_flags.md), so this
# one sweep covers combat, damage, destroy effects, sacrifice costs and
# state-based deaths by construction. Called from the three points a
# destruction can have just happened: the two resolver destroy wrappers and
# _apply_packet_group (whose non-recursive branch destroys without a wrapper).
#
# Only entries from the grant's own index on count — the trigger is
# forward-looking as printed — and the index is advanced past everything scanned,
# so each death fires the reward at most once. "Opposing" and "non-token" are
# read from the entry's frozen snapshot, not re-derived: by now the ally is in a
# graveyard (or, if it was a token, gone).
static func _fire_recombobulation(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	for pid in state.players:
		var ps := state.players[pid] as PlayerState
		if not ps or ps.recomb_from_index < 0:
			continue
		var i := ps.recomb_from_index
		while i < state.turn_events.size():
			var entry: Dictionary = state.turn_events[i]
			i += 1
			if entry.get("type", "") != "ally_destroyed":
				continue
			if not bool(entry.get("is_ally", false)):
				continue
			if bool(entry.get("is_token", false)):
				continue
			if str(entry.get("controller", "")) == pid:
				continue   # "an OPPOSING ally"
			state.pending_recomb_queue.append(pid)
		ps.recomb_from_index = state.turn_events.size()
	events.append_array(_open_next_recomb(state, db))
	return events


# Peek the front queued Recombobulation fetch and open it. Skips queued entries
# whose owner has no ally card left in his graveyard (nothing to fetch — the
# trigger simply does nothing rather than opening an empty choice).
static func _open_next_recomb(state: GameState, db) -> Array[GameEvent]:
	if state.pending_recomb_player != "":
		return []   # one at a time
	while not state.pending_recomb_queue.is_empty():
		var pid: String = state.pending_recomb_queue[0]
		var candidates := get_recomb_candidates(state, pid, db)
		if candidates.is_empty():
			state.pending_recomb_queue.pop_front()
			continue
		state.pending_recomb_player = pid
		return [GameEvent.recomb_choice_opened(pid, candidates)]
	state.pending_recomb_player = ""
	return []


# Resolve the open Recombobulation fetch: put the chosen ally card from the
# completer's own graveyard into his hand, then open the next queued fetch.
# card_id "" declines ("you MAY"). Direct call — no chain, no priority pass.
static func choose_recombobulation(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if state.pending_recomb_player == "" or state.pending_recomb_queue.is_empty():
		return []
	var pid: String = state.pending_recomb_queue.pop_front()
	state.pending_recomb_player = ""
	var events: Array[GameEvent] = []
	if card_id == "":
		events.append(GameEvent.recomb_declined(pid))
	elif card_id in get_recomb_candidates(state, pid, db):
		# Re-checked against the live candidate list: the card must still be an
		# ally card in this player's graveyard.
		events.append_array(GameLogic.move_card(state, card_id, pid + "_hand"))
		events.append(GameEvent.card_returned_from_graveyard(card_id, pid))
	events.append_array(_open_next_recomb(state, db))
	return events


# Ally cards in this player's OWN graveyard — the fetch pool ("an ally card from
# YOUR graveyard"). Card type, not zone: a Totem card in the graveyard is an
# Ability, and an ally token never reaches a graveyard at all.
static func get_recomb_candidates(state: GameState, player_id: String, db) -> Array[String]:
	var result: Array[String] = []
	if db == null:
		return result
	for card in state.cards_in_zone(player_id + "_graveyard"):
		var cdef := db.get_def(card.card_def_id) as CardDef
		if cdef and cdef.card_type == "Ally":
			result.append(card.instance_id)
	return result


# Total combat damage from a deal_damage event list that landed on target_id.
static func _combat_dmg_landed(dmg_events: Array, target_id: String) -> int:
	var total := 0
	for ev in dmg_events:
		if (ev as GameEvent).event_type == "damage_dealt" \
				and (ev as GameEvent).payload.get("target", "") == target_id:
			total += int((ev as GameEvent).payload.get("amount", 0))
	return total


# True when card_id is a hero AND its controller has an in-play equipment
# carrying `flag` in its hero_row (a triggered/ongoing equipment power, no
# ready/exhaust requirement).
static func _hero_wields_flag(state: GameState, card_id: String,
		flag: String, db) -> bool:
	if db == null:
		return false
	var card := state.get_card(card_id)
	if not card:
		return false
	var ps := state.players.get(card.controller) as PlayerState
	if not ps or ps.hero_instance_id != card_id:
		return false
	for eq in state.cards_in_zone(card.controller + "_hero_row"):
		var edef := db.get_def(eq.card_def_id) as CardDef
		if edef and edef.card_type == "Equipment" and _has_effect_flag_prefix(edef, flag):
			return true
	return false


# on_combat_damage_to_hero:EFFECT[:N] triggered powers, checked at combat
# conclusion. EFFECT `draw` draws N for the attacker's controller (Randipan);
# `discard_controller` makes the damaged hero's controller discard N via the
# standard pending-discard machinery (Samuel Grey) — no-op on an empty hand.
static func _fire_combat_damage_to_hero_triggers(state: GameState,
		attacker_id: String, hero_controller: String,
		defender_is_hero: bool, hero_dmg_landed: int, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if not defender_is_hero or hero_dmg_landed <= 0 or db == null:
		return events
	var attacker := state.get_card(attacker_id)
	if not attacker:
		return events
	var def := db.get_def(attacker.card_def_id) as CardDef
	if not def or def.effects == "":
		return events
	for segment in def.effects.split("|"):
		var parts := segment.strip_edges().split(":")
		if parts[0] != "on_combat_damage_to_hero":
			continue
		var effect := parts[1].strip_edges() if parts.size() > 1 else ""
		var n := int(parts[2]) if parts.size() > 2 else 1
		match effect:
			"draw":
				for _i in n:
					events.append_array(_draw_one(state, attacker.controller))
			"discard_controller":
				if hero_controller != "" \
						and not state.cards_in_zone(hero_controller + "_hand").is_empty():
					state.pending_discard_player = hero_controller
					state.pending_discard_count  = n
					events.append(GameEvent.discard_choice_opened(
						hero_controller, n, "card_effect"))
	return events


# Opens the Green Whelp Armor bounce point if all conditions hold. Returns the
# whelp_bounce_opened event (or []). See _do_combat_conclusion.
static func _maybe_open_whelp_bounce(state: GameState, attacker_id: String,
		defender_id: String, hero_controller: String, attacker_was_ally: bool,
		defender_is_hero: bool, hero_dmg_landed: int, db) -> Array[GameEvent]:
	if not attacker_was_ally or not defender_is_hero or hero_dmg_landed <= 0:
		return []
	if hero_controller == "" or not state.is_in_play(attacker_id) \
			or not state.is_in_play(defender_id):
		return []
	# Wielder must control an in-play Green Whelp Armor in their hero_row.
	var has_armor := false
	for card in state.cards_in_zone(hero_controller + "_hero_row"):
		if _has_effect_flag_prefix(db.get_def(card.card_def_id) as CardDef, "whelp_bounce"):
			has_armor = true
			break
	if not has_armor:
		return []
	var cost := 2
	if state.get_available_resources(hero_controller) < cost:
		return []
	state.pending_whelp_bounce_player  = hero_controller
	state.pending_whelp_bounce_ally_id = attacker_id
	state.pending_whelp_bounce_cost    = cost
	return [GameEvent.whelp_bounce_opened(hero_controller, attacker_id, cost)]


# Entry point for the Green Whelp Armor bounce decision (NOT chain-based — called
# directly by the scene, like choose_strike). pay == false means decline. If paid,
# spends the resources and moves the attacking ally to its owner's hand.
static func choose_whelp_bounce(state: GameState, pay: bool,
		db = null) -> Array[GameEvent]:
	if state.pending_whelp_bounce_player == "":
		return []
	var player_id := state.pending_whelp_bounce_player
	var ally_id   := state.pending_whelp_bounce_ally_id
	var cost      := state.pending_whelp_bounce_cost
	state.pending_whelp_bounce_player  = ""
	state.pending_whelp_bounce_ally_id = ""
	state.pending_whelp_bounce_cost    = 0

	var events: Array[GameEvent] = []
	if pay and state.is_in_play(ally_id) \
			and state.get_available_resources(player_id) >= cost:
		events.append_array(_pay_resources(state, player_id, cost))
		var ally := state.get_card(ally_id)
		var owner := ally.owner if ally else ""
		events.append_array(GameLogic.move_card(state, ally_id, owner + "_hand"))
		events.append(GameEvent.whelp_bounce_resolved(player_id, ally_id))
	return events


# ── Graveyard search (generic query API) ──────────────────────────────────────
#
# Effects segments: graveyard_to_hand:TYPE:MIN:MAX:OWNER[:MAX_COST]
#                    graveyard_to_rfg:TYPE:MIN:MAX:OWNER[:MAX_COST]
#   TYPE     — card_type filter ("Ally", "Ability", …) or "any"
#   MIN/MAX  — how many cards must/may be chosen (min=max for exact counts)
#   OWNER    — whose graveyard(s): "own", "opponent", or "both"
#   MAX_COST — optional printed-cost ceiling (omit or -1 for no limit)
# _to_hand returns the chosen cards to the controller's hand;
# _to_rfg removes them from the game (rule 415.7 — owner's RFG zone).

# Parse the graveyard-search requirement off a card def. {} if the def has none.
static func get_graveyard_search_requirement(def: CardDef) -> Dictionary:
	if not def or def.effects == "":
		return {}
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		var key := parts[0].strip_edges()
		if parts.size() >= 5 and (key == "graveyard_to_hand" or key == "graveyard_to_rfg" \
				or key == "graveyard_to_play"):
			var dest := "hand"
			if key == "graveyard_to_rfg":
				dest = "rfg"
			elif key == "graveyard_to_play":
				dest = "play"
			# MAX_COST may be the literal token "resources" (Ancestral Spirit:
			# "cost less than or equal to the number of resources you have") — a
			# dynamic cap resolved against the searching player's total resource
			# count at candidate time, not a fixed number. An optional 7th field
			# is a damage-on-enter mode for `graveyard_to_play` (Ancestral Spirit:
			# "health_minus_1" — enters with damage = its health − 1).
			var cost_field := parts[5].strip_edges() if parts.size() >= 6 else ""
			var dyn_cost := cost_field == "resources"
			return {
				"card_type":    parts[1].strip_edges(),
				"min_count":    int(parts[2]),
				"max_count":    int(parts[3]),
				"owner":        parts[4].strip_edges(),
				"max_cost":     -1 if (dyn_cost or cost_field == "") else int(cost_field),
				"max_cost_dynamic": dyn_cost,
				"damage_mode":  parts[6].strip_edges() if parts.size() >= 7 else "",
				"dest":         dest,
				"source":       "graveyard",
			}
		# Deck search (The Missing Diplomat): deck_to_hand:TYPE:MIN:MAX[:MAX_COST].
		# Always searches the completer's own deck; the deck is shuffled afterward
		# (rule 413.2). MIN 0 means the reward may find nothing (rule 413.3) — the
		# quest still completes, it just does nothing.
		if parts.size() >= 4 and key == "deck_to_hand":
			return {
				"card_type": parts[1].strip_edges(),
				"min_count": int(parts[2]),
				"max_count": int(parts[3]),
				"owner":     "own",
				"max_cost":  int(parts[4]) if parts.size() >= 5 else -1,
				"dest":      "hand",
				"source":    "deck",
			}
	return {}


# Minimum ally-row party size required to complete a quest (e.g. The Defias
# Brotherhood: "require_ally_count:4"). Returns 0 if the quest has no such gate.
static func get_quest_ally_count_requirement(def: CardDef) -> int:
	if not def or def.effects == "":
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() >= 2 and parts[0].strip_edges() == "require_ally_count":
			return int(parts[1])
	return 0


# Extra completion COST paid in exhausted allies (The Love Potion: "Exhaust two
# allies in your party and pay (1) to complete this quest"). Returns 0 when the
# quest has no such cost. The allies are announced WITH the completion (like the
# graveyard-target rewards) and exhausted on chain entry — rule 412.2, same
# timing as an [Activate] tap.
static func get_quest_ally_exhaust_requirement(def: CardDef) -> int:
	if not def or def.effects == "":
		return 0
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() >= 2 and parts[0].strip_edges() == "exhaust_allies":
			return int(parts[1])
	return 0


# Allies that could pay an "exhaust N allies" quest cost: every READY card in the
# player's ally row (totems included — they are allies in the party).
static func get_quest_exhaust_candidates(state: GameState,
		player_id: String) -> Array[String]:
	var result: Array[String] = []
	for card in state.cards_in_zone(player_id + "_ally_row"):
		if not card.is_exhausted:
			result.append(card.instance_id)
	return result


# Torek's Assault-style condition: an opposing hero must have been dealt
# damage this turn by an ally in the quest controller's party.
static func quest_requires_hero_damaged_by_ally(def: CardDef) -> bool:
	if not def or def.effects == "":
		return false
	for entry in def.effects.split("|"):
		if entry.strip_edges() == "require_hero_damaged_by_ally":
			return true
	return false


# Engine-only restriction (NOT in the printed rules — see data/rules_deviations.md):
# some quests are only ever useful on the controller's own turn (e.g. For the
# Horde!, whose reward only affects attacking allies). Restricting completion
# to the turn player also lets the AI skip evaluating them off-turn.
static func quest_requires_turn_player(def: CardDef) -> bool:
	if not def or def.effects == "":
		return false
	for entry in def.effects.split("|"):
		if entry.strip_edges() == "require_turn_player":
			return true
	return false


# All graveyard cards matching a requirement, from player_id's point of view.
static func get_graveyard_search_candidates(state: GameState, player_id: String,
		req: Dictionary, db) -> Array[String]:
	var result: Array[String] = []
	if req.is_empty() or not db:
		return result
	# Deck-search rewards (The Missing Diplomat) look through the completer's own
	# deck rather than a graveyard. Same type/cost filtering below.
	var zone_suffix := "_graveyard"
	if req.get("source", "graveyard") == "deck":
		zone_suffix = "_deck"
	var owner: String = req.get("owner", "own")
	var gy_players: Array[String] = []
	if owner == "own" or owner == "both":
		gy_players.append(player_id)
	if owner == "opponent" or owner == "both":
		gy_players.append(_other_player(state, player_id))
	var type_filter: String = req.get("card_type", "any")
	var max_cost: int = req.get("max_cost", -1)
	# Dynamic cost cap (Ancestral Spirit): "cost <= the number of resources you
	# have" — the searching player's total resource count (rule wording counts
	# resources controlled, exhausted or not).
	if req.get("max_cost_dynamic", false):
		max_cost = state.get_total_resources(player_id)
	for gy_player in gy_players:
		for card in state.cards_in_zone(gy_player + zone_suffix):
			var def := db.get_def(card.card_def_id) as CardDef
			if not def:
				continue
			if type_filter != "any" and type_filter != "" \
					and def.card_type != type_filter and def.card_subtype != type_filter:
				continue
			if max_cost >= 0 and def.cost > max_cost:
				continue
			result.append(card.instance_id)
	return result


# Probe: could this quest be completed if valid graveyard targets were supplied?
# Used by UI highlights and AI before the player has chosen targets.
static func can_use_quest_no_target_check(state: GameState, quest_id: String,
		player_id: String, db) -> bool:
	var probe := PendingAction.make("use_quest", player_id,
			{"quest_id": quest_id, "_skip_target_check": true})
	return can_submit(state, probe, db)


# ── Quest completion ───────────────────────────────────────────────────────────

static func _can_use_quest(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Quest completion is an activated power — usable any time player has priority.
	if action.source_player != state.priority_player:
		return false
	var quest_id: String = action.params.get("quest_id", "")
	var card := state.get_card(quest_id)
	if not card or card.controller != action.source_player:
		return false
	# Must be a face-up (not yet completed) quest in the resource row.
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "resource_row":
		return false
	if card.face_down:
		return false
	# Can't chain this quest's completion with itself while it's already pending.
	for pending in state.pending_actions:
		var p_action := pending as PendingAction
		if p_action and p_action.action_type == "use_quest" \
				and p_action.params.get("quest_id", "") == quest_id:
			return false
	if not db:
		return true
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.card_type != "Quest":
		return false
	# Check additional resource cost (e.g. "Pay 1" on A Donation of Wool).
	var resource_cost: int = max(def.cost, 0)
	if resource_cost > state.get_available_resources(action.source_player):
		return false
	# Extra cost in exhausted allies (The Love Potion). The allies are announced
	# with the completion and must all be ready allies in the completer's party.
	var exhaust_req := get_quest_ally_exhaust_requirement(def)
	if exhaust_req > 0:
		var exhaust_candidates := get_quest_exhaust_candidates(state, action.source_player)
		if exhaust_candidates.size() < exhaust_req:
			return false
		if not action.params.get("_skip_target_check", false):
			var ally_ids: Array = action.params.get("ally_ids", [])
			if ally_ids.size() != exhaust_req:
				return false
			for aid in ally_ids:
				if aid not in exhaust_candidates or ally_ids.count(aid) > 1:
					return false
	# Party-size gating condition (e.g. The Defias Brotherhood: 4+ allies).
	var ally_req := get_quest_ally_count_requirement(def)
	if ally_req > 0 \
			and state.cards_in_zone(action.source_player + "_ally_row").size() < ally_req:
		return false
	# Torek's Assault-style condition: opposing hero damaged by our ally this
	# turn. Read from the turn event log (see game_logic/turn_state_flags.md);
	# the snapshot fields answer "was the source OUR ally at the moment the
	# damage landed", which stays true even if that ally has since died or
	# changed control.
	if quest_requires_hero_damaged_by_ally(def):
		var found := false
		for e in state.turn_events_of("damage_dealt"):
			if e.get("target_is_hero", false) \
					and e.get("source_is_ally", false) \
					and e.get("source_controller", "") == action.source_player \
					and e.get("target_controller", "") != action.source_player:
				found = true
				break
		if not found:
			return false
	# Engine-only deviation — see data/rules_deviations.md.
	if quest_requires_turn_player(def) and state.turn_player != action.source_player:
		return false
	# Graveyard-target rewards: targets are announced with the completion (rule 601-style
	# targeting) and must be legal now. Blocked entirely when too few candidates exist.
	var gy_req := get_graveyard_search_requirement(def)
	if not gy_req.is_empty():
		var candidates := get_graveyard_search_candidates(state, action.source_player, gy_req, db)
		if candidates.size() < int(gy_req.get("min_count", 1)):
			return false
		if action.params.get("_skip_target_check", false):
			return true
		var targets: Array = action.params.get("target_ids", [])
		if targets.size() < int(gy_req.get("min_count", 1)) \
				or targets.size() > int(gy_req.get("max_count", 1)):
			return false
		for tid in targets:
			if tid not in candidates or targets.count(tid) > 1:
				return false
	return true


static func _resolve_use_quest(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var quest_id: String = action.params.get("quest_id", "")
	var card := state.get_card(quest_id)
	if not card or card.face_down:
		return [GameEvent.make("action_fizzled", {
			"action_type": "use_quest", "reason": "quest_already_used",
		})]

	var events: Array[GameEvent] = []

	# Flip the quest face-down — it becomes a blank resource (no longer completable).
	card.face_down = true
	events.append(GameEvent.make("quest_completed", {
		"quest_id": quest_id,
		"player":   action.source_player,
	}))

	# Apply effects from the CardDef's effects string.
	if db:
		var def := db.get_def(card.card_def_id) as CardDef
		if def:
			# "Choose one … you may choose both" quests (qmode: segments) open a
			# mandatory reward choice instead of applying segments directly.
			if is_choice_quest_def(def):
				events.append_array(_open_quest_choice(
						state, action.source_player, quest_id, def, db))
			else:
				events.append_array(_apply_quest_reward(state, action.source_player, def.effects, db,
						action.params.get("target_ids", [])))

	return events


# Parse and execute a quest reward string. Format: "key:value" entries, pipe-separated.
# Effects that require player input (discard_from_hand) set pending state and emit
# a choice event; the caller must handle that event before continuing.
static func _apply_quest_reward(state: GameState, player_id: String,
		effects_str: String, db, target_ids: Array = []) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	if effects_str == "":
		return events
	for entry in effects_str.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() < 2:
			continue
		match parts[0].strip_edges():
			"party_buff_atk_attacking":
				# For the Horde!: "Horde allies in your party have +X ATK
				# while attacking this turn." Tracked player-side (not
				# per-card) so it also covers Horde allies that enter play
				# later this turn.
				var amount := int(parts[1])
				var ps := state.players.get(player_id) as PlayerState
				if ps:
					ps.party_atk_buffs_this_turn.append({"amount": amount, "alignment": "Horde"})
					events.append(GameEvent.party_atk_buff_added(player_id, amount, "Horde"))
			"draw":
				var n := int(parts[1])
				for _i in n:
					events.append_array(_draw_one(state, player_id))
			"create_token":
				# Tooga's Quest: "Reward: Put a unique Turtle ally token named
				# Tooga with 1 ATK and 1 health into play." The delayed half of
				# the reward ("at the start of your next turn, remove Tooga from
				# the game — if you do, draw two cards") rides on the TOKEN as a
				# rfg_self_next_turn segment, so it simply doesn't happen if the
				# token is gone by then. See TurnManager._apply_start_of_turn_effects.
				var q_token_id := parts[1].strip_edges()
				var q_token_n := int(parts[2]) if parts.size() > 2 else 1
				if q_token_id != "":
					events.append_array(_put_token_into_play(
						state, player_id, q_token_id, q_token_n, db))
			"recursion_on_opposing_ally_death":
				# Operation Recombobulation (dark_portal_292): "Reward: When an
				# opposing non-token ally is destroyed this turn, you may put an ally
				# card from your graveyard into your hand." Cold Blood's grant shape —
				# store the turn-event-log index the reward became active at, so the
				# trigger is forward-looking as printed and every death this turn is
				# then read off the log's `ally_destroyed` entries
				# (see game_logic/turn_state_flags.md). Re-completing sets the index
				# only if not already active, so a second quest can't rewind past
				# deaths the first one already handled.
				var rc_ps := state.players.get(player_id) as PlayerState
				if rc_ps and rc_ps.recomb_from_index < 0:
					rc_ps.recomb_from_index = state.turn_events.size()
			"discard_from_hand":
				var n := int(parts[1])
				state.pending_discard_player = player_id
				state.pending_discard_count  = n
				events.append(GameEvent.discard_choice_opened(player_id, n))
			"graveyard_to_hand":
				# Targets were validated at announcement; re-check they are still
				# in a graveyard at resolution (fizzle per-card otherwise).
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "graveyard":
						continue
					events.append_array(GameLogic.move_card(state, tid, player_id + "_hand"))
					events.append(GameEvent.card_returned_from_graveyard(tid, player_id))
			"graveyard_to_play":
				# Finkle Einhorn: put a chosen ally from graveyard directly into
				# play. Re-check each target is still in a graveyard, set its
				# controller to the completer, then bring it into play so its
				# enter-play triggers fire exactly as if played from hand.
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "graveyard":
						continue
					t_card.controller = player_id
					events.append_array(_bring_ally_into_play(state, tid, db))
			"graveyard_to_rfg":
				# Same re-check as graveyard_to_hand; cards go to their owner's
				# RFG zone (rule 415.7a) instead of the hand.
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "graveyard":
						continue
					events.append_array(GameLogic.move_card(state, tid, t_card.owner + "_rfg"))
					events.append(GameEvent.card_removed_from_game(tid, player_id))
			"reveal_pick":
				# Big Game Hunter / Kibler's Exotic Pets / Zapped Giants: reveal the
				# top N cards; the controller puts a revealed card of the required
				# type into hand and the rest go to the bottom of the deck. The pick
				# is a mandatory post-resolution choice (choose_reveal_pick) when at
				# least one matching card is revealed.
				var want_type := parts[1].strip_edges()
				var reveal_n := int(parts[2]) if parts.size() > 2 else 1
				# Optional trailing flags, order-independent:
				#   "opponent" — the OTHER player makes the pick (The Princess
				#                Trapped); default is the controller.
				#   "to_top"   — the picked card goes back on TOP of the deck instead
				#                of into hand (It's a Secret to Everybody).
				#   "private"  — a "look at", not a reveal: only the chooser sees the
				#                cards (It's a Secret to Everybody).
				var chooser := player_id
				var to_top := false
				var is_private := false
				for i in range(3, parts.size()):
					match parts[i].strip_edges():
						"opponent":
							chooser = "p2" if player_id == "p1" else "p1"
						"to_top":
							to_top = true
						"private":
							is_private = true
				events.append_array(_reveal_pick(state, player_id, want_type, reveal_n,
						db, chooser, to_top, is_private))
			"deck_to_hand":
				# The Missing Diplomat: search your deck, reveal the chosen ally,
				# put it into your hand. Re-check each target is still in the
				# player's deck at resolution (fizzle per-card otherwise). Rule
				# 413.2/415.3b: the owner shuffles the deck after the search — do
				# so even if no card was found (the deck was still searched).
				for tid in target_ids:
					var t_card := state.get_card(tid)
					if not t_card:
						continue
					var t_zone := state.zones.get(t_card.zone_id) as Zone
					if not t_zone or t_zone.zone_type != "deck":
						continue
					events.append(GameEvent.card_revealed_from_deck(tid, player_id))
					events.append_array(GameLogic.move_card(state, tid, player_id + "_hand"))
				# The deck is always searched when this reward runs, even if the
				# player found nothing to take.
				var deck_zone := state.zones.get(player_id + "_deck") as Zone
				if deck_zone:
					deck_zone.card_ids.shuffle()
					events.append(GameEvent.make("deck_shuffled", {"player": player_id}))
	return events


# Reveal the top N cards of the player's deck for a "reveal_pick" quest reward.
# Cards stay physically at the top of the deck; if any match `want_type`, set the
# pending choice and emit reveal_pick_opened (the scene resolves it via
# choose_reveal_pick). If none match, all revealed cards go straight to the
# bottom of the deck with no choice.
# `chooser` is who makes the pick — the owner unless the card says otherwise
# (The Princess Trapped: "Target opponent chooses one"). `want_type` "Any"
# makes every revealed card selectable.
static func _reveal_pick(state: GameState, player_id: String, want_type: String,
		n: int, db, chooser: String = "", to_top: bool = false,
		is_private: bool = false) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var deck := state.zones.get(player_id + "_deck") as Zone
	if not deck or deck.card_ids.is_empty():
		events.append(GameEvent.make("deck_empty", {"player": player_id}))
		return events
	var count: int = min(n, deck.card_ids.size())
	var revealed: Array[String] = []
	for i in count:
		revealed.append(deck.card_ids[i])
	var selectable: Array[String] = []
	for cid in revealed:
		events.append(GameEvent.card_revealed_from_deck(cid, player_id))
		var c := state.get_card(cid)
		var d := db.get_def(c.card_def_id) as CardDef if c and db else null
		if want_type == "Any" or (d and d.card_type == want_type):
			selectable.append(cid)
	# Always open the choice — even when nothing matches, the controller still
	# gets to SEE the revealed cards before they go to the bottom of the deck
	# (they acknowledge with an empty pick via choose_reveal_pick). selectable
	# may be empty; the resolver then sends every revealed card to the bottom.
	state.pending_reveal_pick_player = player_id
	state.pending_reveal_pick_chooser = chooser if chooser != "" else player_id
	state.pending_reveal_pick_ids = selectable
	state.pending_reveal_pick_all = revealed
	state.pending_reveal_pick_to_top = to_top
	state.pending_reveal_pick_private = is_private
	events.append(GameEvent.reveal_pick_opened(player_id, selectable, revealed,
			want_type, state.pending_reveal_pick_chooser, to_top, is_private))
	return events


# Entry point: the controller has chosen which revealed card to keep. The picked
# card goes to hand; every other revealed card goes to the bottom of the deck in
# revealed order. Called directly by the scene (not via submit_action), like
# choose_pet_sacrifice. card_id must be one of the selectable (matching) cards,
# OR "" when nothing matched (pending_reveal_pick_ids empty) — the player merely
# acknowledges and every revealed card goes to the bottom.
static func choose_reveal_pick(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_reveal_pick_player == "":
		return []
	var no_pick := state.pending_reveal_pick_ids.is_empty()
	if no_pick:
		if card_id != "":
			return []   # nothing was selectable — only the empty acknowledgement is valid
	elif card_id not in state.pending_reveal_pick_ids:
		return []   # must pick a card of the required type
	var player_id := state.pending_reveal_pick_player
	var revealed := state.pending_reveal_pick_all.duplicate()
	var to_top := state.pending_reveal_pick_to_top
	# Clear pending state up front so subsequent moves can't re-enter this path.
	state.pending_reveal_pick_player = ""
	state.pending_reveal_pick_chooser = ""
	state.pending_reveal_pick_ids = []
	state.pending_reveal_pick_all = []
	state.pending_reveal_pick_to_top = false
	state.pending_reveal_pick_private = false

	var events: Array[GameEvent] = []
	if not no_pick:
		# to_top (It's a Secret to Everybody): the picked card simply STAYS where
		# it is — the revealed cards never left the top of the deck, so once the
		# others are pushed to the bottom below it is back on top by itself.
		if not to_top:
			events.append_array(GameLogic.move_card(state, card_id, player_id + "_hand"))
		events.append(GameEvent.make("reveal_pick_resolved", {
			"player": player_id, "card_id": card_id, "to_top": to_top,
		}))
	for cid: String in revealed:
		if cid == card_id:
			continue
		events.append_array(GameLogic.move_card(state, cid, player_id + "_deck"))
	return events


# ── Quest reward choice ("Choose one … you may choose both") ──────────────────
# Hidden Enemies / A New Plague / Thwarting Kolkar Aggression / Crown of the
# Earth. Recipe: two `qmode:EFFECT[:ARGS]` segments (printed order) plus a
# `qchoice_both_race:RACE` segment — when the completer's HERO has that race
# (substring of the hero def's tags, same match as requires_hero_race) AND both
# modes are currently available, the completer may choose both, in either
# order. The pick and every sub-choice are direct calls (NOT the chain), like
# the reveal pick; can_submit / pass_priority hard-block while pending.

static func _quest_choice_pending(state: GameState) -> bool:
	return state.pending_quest_choice_player != "" \
		or state.pending_quest_ferocity_player != "" \
		or state.pending_plague_destroy_player != "" \
		or state.pending_quest_facedown_player != ""


# Inner mode strings ("draw:1", "ally_ferocity_this_turn", …) in printed order.
static func get_quest_reward_modes(def: CardDef) -> Array[String]:
	var modes: Array[String] = []
	if not def or def.effects == "":
		return modes
	for entry in def.effects.split("|"):
		var seg := entry.strip_edges()
		if seg.begins_with("qmode:"):
			modes.append(seg.trim_prefix("qmode:"))
	return modes


static func is_choice_quest_def(def: CardDef) -> bool:
	return not get_quest_reward_modes(def).is_empty()


# The `qchoice_both_race:RACE` segment's race, or "" when absent.
static func quest_choice_both_race(def: CardDef) -> String:
	if not def or def.effects == "":
		return ""
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts[0].strip_edges() == "qchoice_both_race" and parts.size() > 1:
			return parts[1].strip_edges()
	return ""


# Does the player's HERO have the given race? The race lives in the hero def's
# tags column ("Orc Shaman", "Night Elf Priest") — substring match, same as the
# deck authorizer's requires_hero_race check (covers multi-word races).
static func hero_has_race(state: GameState, player_id: String, race: String,
		db) -> bool:
	if race == "" or not db:
		return false
	var hero := state.get_hero(player_id)
	if not hero:
		return false
	var def := db.get_def(hero.card_def_id) as CardDef
	return def != null and race in def.tags


# Can this reward mode currently do anything / be legally chosen? Modes that
# need a target or a condition are unavailable (greyed out) when it can't be
# met — a deviation from "choose and fizzle", see data/rules_deviations.md
# "Quest reward choices".
static func quest_mode_available(state: GameState, player_id: String,
		mode: String, db) -> bool:
	var key := mode.split(":")[0].strip_edges()
	match key:
		"ally_ferocity_this_turn":
			return not get_quest_ferocity_targets(state, db).is_empty()
		"each_player_destroys_ally":
			# "If an ally is in your party" — the completer must have one.
			return not state.cards_in_zone(player_id + "_ally_row").is_empty()
		"opponent_quest_face_down":
			return not _face_up_quests(state, _other_player(state, player_id), db).is_empty()
		_:
			# draw / hand_to_deck_draw — always available.
			return true


# Legal targets for Hidden Enemies' ferocity grant: any in-play ally, either
# party (the printed text says just "target ally"), 706 Untargetable respected.
static func get_quest_ferocity_targets(state: GameState, db) -> Array[String]:
	var targets: Array[String] = []
	for pid in state.players:
		for card in state.cards_in_zone(pid + "_ally_row"):
			if _is_legal_target(state, card.instance_id, db):
				targets.append(card.instance_id)
	return targets


# A player's face-up Quest cards in their resource row (Kolkar candidates).
static func _face_up_quests(state: GameState, player_id: String,
		db) -> Array[String]:
	var result: Array[String] = []
	for card in state.cards_in_zone(player_id + "_resource_row"):
		if card.face_down:
			continue
		var def := db.get_def(card.card_def_id) as CardDef if db else null
		if def and def.card_type == "Quest":
			result.append(card.instance_id)
	return result


# Open the reward choice as the quest resolves. Every qmode quest carries a
# draw mode, so at least one mode is always available.
static func _open_quest_choice(state: GameState, player_id: String,
		quest_id: String, def: CardDef, db) -> Array[GameEvent]:
	var modes: Array = []
	var available_count := 0
	for mode in get_quest_reward_modes(def):
		var avail := quest_mode_available(state, player_id, mode, db)
		modes.append({"mode": mode, "available": avail})
		if avail:
			available_count += 1
	var can_both := available_count >= 2 \
		and hero_has_race(state, player_id, quest_choice_both_race(def), db)
	state.pending_quest_choice_player   = player_id
	state.pending_quest_choice_quest    = quest_id
	state.pending_quest_choice_modes    = modes
	state.pending_quest_choice_can_both = can_both
	return [GameEvent.quest_choice_opened(player_id, quest_id, modes, can_both)]


# Entry point: the completer picked their reward mode(s), in resolution order.
# chosen = 1 mode string, or 2 distinct ones when can_both. Direct call.
static func choose_quest_modes(state: GameState, chosen: Array,
		db) -> Array[GameEvent]:
	if state.pending_quest_choice_player == "":
		return []
	if chosen.is_empty() or chosen.size() > 2:
		return []
	if chosen.size() == 2 and (not state.pending_quest_choice_can_both
			or chosen[0] == chosen[1]):
		return []
	for m in chosen:
		var found := false
		for entry in state.pending_quest_choice_modes:
			if entry.get("mode", "") == m and entry.get("available", false):
				found = true
				break
		if not found:
			return []
	var player_id := state.pending_quest_choice_player
	var quest_id  := state.pending_quest_choice_quest
	state.pending_quest_choice_player   = ""
	state.pending_quest_choice_quest    = ""
	state.pending_quest_choice_modes    = []
	state.pending_quest_choice_can_both = false
	for m in chosen:
		state.quest_mode_queue.append(
			{"player": player_id, "quest_id": quest_id, "mode": m})
	return _run_quest_mode_queue(state, db)


# "Put your hand on the bottom of your deck, then draw that many cards."
# Shared by Crown of the Earth's quest reward mode and Ilandre Moonspear's
# [Activate] power. Bottom in current hand order (move_card appends to the
# deck's end = bottom), then draw the same count — the draws happen AFTER the
# hand is gone, so an empty hand is a legal no-op and a short deck can deck the
# player (410.6b, via _draw_one).
static func _hand_to_deck_draw(state: GameState, player_id: String) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var hand_ids: Array[String] = []
	for c in state.cards_in_zone(player_id + "_hand"):
		hand_ids.append(c.instance_id)
	for cid in hand_ids:
		events.append_array(GameLogic.move_card(state, cid, player_id + "_deck"))
	events.append(GameEvent.hand_returned_to_deck(player_id, hand_ids.size()))
	for _i in hand_ids.size():
		events.append_array(_draw_one(state, player_id))
	return events


# Run queued reward modes front-first until the queue is empty or a mode opens
# a sub-choice (the choose_* resolver for that sub-choice re-enters here).
static func _run_quest_mode_queue(state: GameState, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	while not state.quest_mode_queue.is_empty():
		var entry: Dictionary = state.quest_mode_queue.pop_front()
		var player_id: String = entry.get("player", "")
		var quest_id: String  = entry.get("quest_id", "")
		var mode: String      = entry.get("mode", "")
		var parts := mode.split(":")
		match parts[0].strip_edges():
			"draw":
				var n := int(parts[1]) if parts.size() > 1 else 1
				for _i in n:
					events.append_array(_draw_one(state, player_id))
			"hand_to_deck_draw":
				events.append_array(_hand_to_deck_draw(state, player_id))
			"ally_ferocity_this_turn":
				# Re-check at run time (the board may have changed while an
				# earlier mode resolved) — no legal ally left, the mode fizzles.
				if get_quest_ferocity_targets(state, db).is_empty():
					continue
				state.pending_quest_ferocity_player = player_id
				state.pending_quest_ferocity_source = quest_id
				events.append(GameEvent.quest_ferocity_target_required(quest_id, player_id))
				return events
			"each_player_destroys_ally":
				# "If an ally is in your party" — re-check the completer's
				# condition at run time; without it the whole mode no-ops.
				if state.cards_in_zone(player_id + "_ally_row").is_empty():
					continue
				# Every player with an ally sacrifices one of their own; the
				# completer picks first, then the opponent.
				state.pending_plague_destroy_queue.clear()
				var opp := _other_player(state, player_id)
				for pid in [player_id, opp]:
					if not state.cards_in_zone(pid + "_ally_row").is_empty():
						state.pending_plague_destroy_queue.append(pid)
				state.pending_plague_destroy_player = state.pending_plague_destroy_queue[0]
				state.pending_plague_destroy_source = quest_id
				events.append(GameEvent.plague_destroy_required(
						state.pending_plague_destroy_player, quest_id))
				return events
			"opponent_quest_face_down":
				# "Target player" is auto-chosen as the opponent (see
				# data/rules_deviations.md "Thwarting Kolkar Aggression"); the
				# TARGET player picks which of their face-up quests flips.
				var t_player := _other_player(state, player_id)
				var candidates := _face_up_quests(state, t_player, db)
				if candidates.is_empty():
					continue   # nothing to flip — the mode fizzles
				state.pending_quest_facedown_player = t_player
				state.pending_quest_facedown_ids    = candidates
				events.append(GameEvent.quest_facedown_required(t_player, candidates))
				return events
	return events


# Entry point: Hidden Enemies — the completer picked the ally that gains
# ferocity this turn. Buff-based grant so it expires with the end-of-turn
# sweep (and on leaving play); read by _has_keyword ("grant_ferocity").
static func choose_quest_ferocity_target(state: GameState, target_id: String,
		db) -> Array[GameEvent]:
	if state.pending_quest_ferocity_player == "":
		return []
	if target_id not in get_quest_ferocity_targets(state, db):
		return []
	var source_id := state.pending_quest_ferocity_source
	state.pending_quest_ferocity_player = ""
	state.pending_quest_ferocity_source = ""
	var card := state.get_card(target_id)
	card.active_buffs.append(
		Buff.make("quest_ferocity", source_id, "grant_ferocity", 1, "turns", 1))
	var events: Array[GameEvent] = [GameEvent.ferocity_granted(target_id, source_id)]
	events.append_array(_run_quest_mode_queue(state, db))
	return events


# Entry point: A New Plague — the pending player picked the ally in their own
# party to destroy. Advances to the next queued player, then the mode queue.
static func choose_plague_destroy(state: GameState, ally_id: String,
		db) -> Array[GameEvent]:
	if state.pending_plague_destroy_player == "":
		return []
	var player_id := state.pending_plague_destroy_player
	var card := state.get_card(ally_id)
	if not card or card.zone_id != player_id + "_ally_row":
		return []
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(
			state, ally_id, state.pending_plague_destroy_source, db))
	state.pending_plague_destroy_queue.pop_front()
	# Next player with an ally still in party picks theirs (a chained death
	# trigger may have emptied their board in the meantime — then skip).
	while not state.pending_plague_destroy_queue.is_empty():
		var next_pid: String = state.pending_plague_destroy_queue[0]
		if state.cards_in_zone(next_pid + "_ally_row").is_empty():
			state.pending_plague_destroy_queue.pop_front()
			continue
		state.pending_plague_destroy_player = next_pid
		events.append(GameEvent.plague_destroy_required(
				next_pid, state.pending_plague_destroy_source))
		return events
	state.pending_plague_destroy_player = ""
	state.pending_plague_destroy_source = ""
	events.append_array(_run_quest_mode_queue(state, db))
	return events


# Entry point: Thwarting Kolkar Aggression — the TARGET player picked which of
# their face-up quests turns face down (no completion, no reward — the quest
# simply becomes the same spent face-down resource a completed quest is).
static func choose_quest_facedown(state: GameState, quest_id: String,
		db) -> Array[GameEvent]:
	if state.pending_quest_facedown_player == "":
		return []
	if quest_id not in state.pending_quest_facedown_ids:
		return []
	var player_id := state.pending_quest_facedown_player
	state.pending_quest_facedown_player = ""
	state.pending_quest_facedown_ids    = []
	var card := state.get_card(quest_id)
	card.face_down = true
	var events: Array[GameEvent] = [
		GameEvent.quest_turned_face_down(quest_id, player_id)]
	events.append_array(_run_quest_mode_queue(state, db))
	return events


# Entry point: player (or AI) has chosen a card to discard.
static func choose_discard(state: GameState, card_id: String,
		_db = null) -> Array[GameEvent]:
	if state.pending_discard_count <= 0 or state.pending_discard_player == "":
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return []
	if card.controller != state.pending_discard_player:
		return []

	var events: Array[GameEvent] = []
	events.append_array(GameLogic.discard_card(state, card_id))
	state.pending_discard_count -= 1
	if state.pending_discard_count <= 0:
		state.pending_discard_player = ""
		state.pending_discard_count  = 0
	else:
		# More discards still needed — reopen choice.
		events.append(GameEvent.discard_choice_opened(
			state.pending_discard_player, state.pending_discard_count))
	return events


# ── Discard-or-give-control choice (Infernal) ─────────────────────────────────
# "At the start of your turn, discard a card, or target opponent gains control
# of [this]." Called directly by the scene (not via submit_action), like
# choose_pet_sacrifice — but unlike a mandatory discard, the player may decline.

# Player chose to discard a hand card and keep control of the source.
static func choose_control_discard(state: GameState, card_id: String,
		_db = null) -> Array[GameEvent]:
	if state.pending_control_discard_player == "" \
			or state.pending_control_discard_ids.is_empty():
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_control_discard_player:
		return []
	var zone := state.zones.get(card.zone_id) as Zone
	if not zone or zone.zone_type != "hand":
		return []

	var events: Array[GameEvent] = []
	events.append_array(GameLogic.discard_card(state, card_id))
	state.pending_control_discard_ids.pop_front()
	_advance_control_discard_queue(state, events)
	return events


# Player declined to discard — the opponent gains control of the source
# (rule 401.3: the new controller moves it to his ally row). just_summoned is
# set because an ally can't attack or use powers unless it has been under its
# controller's control continuously since the start of their turn.
static func decline_control_discard(state: GameState,
		db = null) -> Array[GameEvent]:
	if state.pending_control_discard_player == "" \
			or state.pending_control_discard_ids.is_empty():
		return []
	var events: Array[GameEvent] = []
	var source_id: String = state.pending_control_discard_ids.pop_front()
	var source := state.get_card(source_id)
	if source and state.is_in_play(source_id):
		var old_ctrl := source.controller
		var new_ctrl := _other_player(state, old_ctrl)
		source.controller = new_ctrl
		source.just_summoned = true
		events.append_array(GameLogic.move_card(state, source_id, new_ctrl + "_ally_row"))
		events.append(GameEvent.control_changed(source_id, old_ctrl, new_ctrl))
		# The source may be a Pet (Infernal is) — new controller's pet capacity
		# can now be violated exactly as if a second pet entered play.
		events.append_array(_check_pet_uniqueness(state, source_id, db))
	_advance_control_discard_queue(state, events)
	return events


static func _advance_control_discard_queue(state: GameState,
		events: Array[GameEvent]) -> void:
	if state.pending_control_discard_ids.is_empty():
		state.pending_control_discard_player = ""
	else:
		events.append(GameEvent.control_discard_choice_opened(
			state.pending_control_discard_player,
			state.pending_control_discard_ids[0]))


static func choose_pet_sacrifice(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_pet_sacrifice_player == "":
		return []
	if card_id not in state.pending_pet_sacrifice_ids:
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_pet_sacrifice_player:
		return []
	return _resolve_choose_pet_sacrifice(state,
		PendingAction.make("choose_pet_sacrifice", state.pending_pet_sacrifice_player,
			{"card_id": card_id}),
		db)


static func _draw_one(state: GameState, player_id: String) -> Array[GameEvent]:
	# Decked rule (410.6b/102.1a) lives in the primitive — see GameLogic.draw_one.
	return GameLogic.draw_one(state, player_id)


# Exhaust N ready resources for a player (generic cost payment without a card reference).
static func _pay_resources(state: GameState, player_id: String,
		cost: int) -> Array[GameEvent]:
	if cost <= 0:
		return []
	var events: Array[GameEvent] = []
	for res_card in state.cards_in_zone(player_id + "_resource_row"):
		if cost <= 0:
			break
		if not res_card.is_exhausted:
			events.append_array(GameLogic.exhaust_card(state, res_card.instance_id))
			cost -= 1
	return events


# ── Activated-power extra costs ───────────────────────────────────────────────
#
# The EXTRACOST field is a `+`-joined list of tokens, each of which may carry its
# own `:`-separated argument ("put_damage_self:1"). Independent axes compose:
# WHAT the power costs beyond resources (sacrifice_ally, exhaust_hero, …) is one
# token, and whether the printed cost carries an [Activate] tap symbol is
# another (no_activate). Besh'iah is `sacrifice_ally+no_activate` — Gertha's
# cost with the tap symbol dropped. Always ask through these helpers rather than
# comparing the raw field, or a card with two tokens matches neither.

static func power_extra_costs(extra_cost: String) -> PackedStringArray:
	if extra_cost == "":
		return PackedStringArray()
	return extra_cost.split("+", false)


# Whether the power carries `token`, with or without a `:`-argument.
static func power_has_extra_cost(extra_cost: String, token: String) -> bool:
	for t in power_extra_costs(extra_cost):
		if t == token or t.begins_with(token + ":"):
			return true
	return false


# The `:`-argument of `token` ("put_damage_self:1" → 1), or `fallback`.
static func power_extra_cost_arg(extra_cost: String, token: String, fallback: int) -> int:
	for t in power_extra_costs(extra_cost):
		if t.begins_with(token + ":"):
			return int(t.split(":")[1])
	return fallback


# Whether an activated power's extra cost means the printed cost carries NO
# [Activate] tap symbol — the source neither exhausts nor cares about being
# exhausted (Acolyte Demia's put_damage_self, Hierophant Caydiem's no_activate,
# Kavai / Mana Agate's sacrifice_self). Note activate_put_damage_self (Kena
# Shadowbrand) is deliberately NOT in this set: it KEEPS the tap symbol.
static func _power_has_no_activate_symbol(extra_cost: String) -> bool:
	return power_has_extra_cost(extra_cost, "put_damage_self") \
		or power_has_extra_cost(extra_cost, "no_activate") \
		or power_has_extra_cost(extra_cost, "sacrifice_self")


# Whether the sacrifice_ally cost is picked SEPARATELY from the power's own
# target, i.e. the power needs a `sacrifice_id` param on top of `target_id`.
# Bizzik Sparkcog's sacrifice IS his only target (targets=friendly_ally), so it
# rides target_id; Gertha (targets=ally) and Besh'iah (targets=ability) each
# destroy something else with the effect, so the sacrifice is its own pick.
static func power_sacrifice_is_separate(ap: Dictionary) -> bool:
	return power_has_extra_cost(ap.get("extra_cost", ""), "sacrifice_ally") \
		and ap.get("targets", "") != "friendly_ally"


# Pay an activated power's exhaust-style costs (rule 412.2 — paid on chain entry,
# alongside the resource cost, NOT at resolution): the [Activate] tap symbol on
# the source, the once-per-turn mark, and the "exhaust your hero" extra cost.
# `_can_use_ally_power` has already verified all of these are payable.
# The remaining extra costs (put_damage_self, sacrifice_ally, sacrifice_self,
# rfg_allies) stay at resolution — see _resolve_use_ally_power, where a source
# killed in response no-ops the cost but still resolves the effect.
static func _pay_activate_costs(state: GameState, card_id: String,
		player_id: String, ap: Dictionary) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var extra_cost: String = ap.get("extra_cost", "")
	var card := state.get_card(card_id)
	if power_has_extra_cost(extra_cost, "once_per_turn"):
		if card:
			card.used_this_turn = true
	elif not _power_has_no_activate_symbol(extra_cost):
		events.append_array(GameLogic.exhaust_card(state, card_id))
	if power_has_extra_cost(extra_cost, "exhaust_hero"):
		var ps := state.players.get(player_id) as PlayerState
		var hero_id: String = ps.hero_instance_id if ps else ""
		if hero_id != "":
			events.append_array(GameLogic.exhaust_card(state, hero_id))
	return events


# Undo _pay_activate_costs when the power is retracted off the chain. Safe to
# ready unconditionally: submission validated that the source (and the hero, for
# exhaust_hero) were READY, so those exhausts were ours to undo.
static func _refund_activate_costs(state: GameState, card_id: String,
		player_id: String, ap: Dictionary) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	var extra_cost: String = ap.get("extra_cost", "")
	var card := state.get_card(card_id)
	if power_has_extra_cost(extra_cost, "once_per_turn"):
		if card:
			card.used_this_turn = false
	elif not _power_has_no_activate_symbol(extra_cost):
		events.append_array(GameLogic.ready_card(state, card_id))
	if power_has_extra_cost(extra_cost, "exhaust_hero"):
		var ps := state.players.get(player_id) as PlayerState
		var hero_id: String = ps.hero_instance_id if ps else ""
		if hero_id != "":
			events.append_array(GameLogic.ready_card(state, hero_id))
	return events


# ── Retract ────────────────────────────────────────────────────────────────────

# Cancel the last chain entry — only legal while the proposer still has priority
# and has not yet passed (consecutive_passes == 0).  Returns [] if not retractable.
static func can_retract(state: GameState, player_id: String) -> bool:
	if state.pending_actions.is_empty():
		return false
	if state.priority_player != player_id:
		return false
	if state.consecutive_passes != 0:
		return false
	var top: PendingAction = state.pending_actions.back()
	if top.source_player != player_id:
		return false
	# An additional cost paid in destroyed permanents (Sever the Cord's
	# sacrifice) can't be refunded, so the announcement can't be taken back.
	return not top.params.get("_cost_paid_irreversibly", false)


static func retract_last(state: GameState, player_id: String,
		db = null) -> Array[GameEvent]:
	if not can_retract(state, player_id):
		return []

	var top: PendingAction = state.pending_actions.pop_back()
	var events: Array[GameEvent] = []

	# Move card back from chain zone to player's hand. ONLY for actions that put a
	# card on the chain from hand — use_ally_power also carries a "card_id" param,
	# but that's the in-play SOURCE of the power (an ally or equipment), which must
	# stay on the board.
	var card_id: String = top.params.get("card_id", "") \
		if top.action_type in ["play_ally", "play_instant", "play_ability",
			"play_equipment", "place_resource"] else ""
	if card_id != "":
		events.append_array(GameLogic.move_card(state, card_id, player_id + "_hand"))

	# Refund resources exhausted at submission time (rule 412.2 costs are paid on
	# chain entry, so retraction must undo them — mirrors _pay_cost exactly).
	if top.action_type == "use_ally_power" and db:
		var ap_card_id2: String = top.params.get("card_id", "")
		if ap_card_id2 != "":
			var ap_card2 := state.get_card(ap_card_id2)
			var ap_def2  := db.get_def(ap_card2.card_def_id) as CardDef if ap_card2 else null
			var ap_data2 := _ally_activated_power(ap_def2) if ap_def2 else {}
			var ap_cost2 := power_resource_cost(ap_data2,
				int(top.params.get("x_value", 0)))
			for res_card in state.cards_in_zone(player_id + "_resource_row"):
				if ap_cost2 <= 0:
					break
				if res_card.is_exhausted:
					events.append_array(GameLogic.ready_card(state, res_card.instance_id))
					ap_cost2 -= 1
			# Also undo the exhaust-style costs paid on chain entry.
			events.append_array(_refund_activate_costs(state, ap_card_id2,
				player_id, ap_data2))
	# Nature's Swiftness' one-shot discount was consumed on chain entry — put it
	# back BEFORE the refund below recomputes the cost, so we refund exactly the
	# resources that were exhausted (the discounted cost), not the printed one.
	var ncd_back: int = int(top.params.get("_next_card_cost_mod", 0))
	if ncd_back != 0:
		var ncd_ps2 := state.players.get(player_id) as PlayerState
		if ncd_ps2:
			ncd_ps2.next_card_cost_mod = ncd_back
	if top.action_type in ["play_ally", "play_instant", "play_ability"] and db and card_id != "":
		var cost: int = state.get_play_cost(card_id, db, int(top.params.get("x_value", 0)))
		for res_card in state.cards_in_zone(player_id + "_resource_row"):
			if cost <= 0:
				break
			if res_card.is_exhausted:
				events.append_array(GameLogic.ready_card(state, res_card.instance_id))
				cost -= 1

	# Quest completion: undo the resource cost and the "exhaust N allies" extra
	# cost (The Love Potion), both paid on chain entry.
	if top.action_type == "use_quest" and db:
		var q_card2 := state.get_card(top.params.get("quest_id", ""))
		var q_def2  := db.get_def(q_card2.card_def_id) as CardDef if q_card2 else null
		if q_def2:
			var q_cost: int = max(q_def2.cost, 0)
			for res_card in state.cards_in_zone(player_id + "_resource_row"):
				if q_cost <= 0:
					break
				if res_card.is_exhausted:
					events.append_array(GameLogic.ready_card(state, res_card.instance_id))
					q_cost -= 1
			if get_quest_ally_exhaust_requirement(q_def2) > 0:
				for aid in top.params.get("ally_ids", []):
					events.append_array(GameLogic.ready_card(state, str(aid)))

	# Undo resource_placed_this_turn flag if a place_resource was retracted.
	if top.action_type == "place_resource":
		var ps := state.players.get(player_id) as PlayerState
		if ps:
			ps.resource_placed_this_turn = false

	events.append(GameEvent.make("action_retracted", {
		"action_type": top.action_type,
		"player":      player_id,
	}))
	return events


# ── Hero power ─────────────────────────────────────────────────────────────────

static func _can_activate_power(state: GameState, action: PendingAction,
		db = null) -> bool:
	# Hero powers are instants by default (rule 701.3) — usable any time player has
	# priority, INCLUDING in response to something already on the chain (so a player
	# can react to e.g. Ta'zo's damage power). Powers with "on_your_turn" in effects
	# are sorcery-speed: they also require turn player + action phase + empty chain
	# (that empty-chain gate is applied in the "on_your_turn" block below).
	if state.priority_player != action.source_player:
		return false
	var ps := state.players.get(action.source_player) as PlayerState
	if not ps or ps.has_used_hero_power:
		return false
	# Hero must be alive (in hero_row).
	var hero_id: String = action.params.get("hero_id", "")
	var hero := state.get_card(hero_id)
	if not hero or not state.is_in_play(hero_id):
		return false
	if not db:
		return true
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def or def.card_type != "Hero":
		return false
	# "on_your_turn" in effects = "Use only on your turn": action phase, turn player, chain empty.
	if _power_effect_is(def, "on_your_turn"):
		if state.phase != "action" or state.turn_player != action.source_player:
			return false
		if not state.pending_actions.is_empty():
			return false
	# Must be able to afford the cost.
	var cost: int = max(def.cost, 0)
	if cost > state.get_available_resources(action.source_player):
		return false
	# If this power targets something, the target must be valid.
	var target_id: String = action.params.get("target_id", "")
	var is_gy_power := _power_effect_is(def, "graveyard_to_hand")
	if target_id != "" and not is_gy_power:
		if not _is_legal_target(state, target_id, db):
			return false
	if is_gy_power:
		var gy_req := get_graveyard_search_requirement(def)
		if gy_req.is_empty():
			return false
		var gy_candidates := get_graveyard_search_candidates(state, action.source_player, gy_req, db)
		if gy_candidates.size() < int(gy_req.get("min_count", 1)):
			return false
		if target_id != "" and target_id not in gy_candidates:
			return false
	if _power_effect_is(def, "deal_damage_and_heal"):
		# target_id = damage target, heal_target_id = heal target; both must be in play and different.
		if target_id != "":
			var heal_target_id: String = action.params.get("heal_target_id", "")
			# Heals are targeted too ("target hero or ally") — Untargetable blocks them.
			if not _is_legal_target(state, heal_target_id, db):
				return false
			if heal_target_id == target_id:
				return false
	# destroy_exhausted_ally: target must be an exhausted ally (not a hero).
	if _power_effect_is(def, "destroy_exhausted_ally"):
		if target_id == "":
			# Pre-targeting probe: pass if any exhausted enemy ally exists.
			var opp3 := "p2" if action.source_player == "p1" else "p1"
			var has_exhausted_ally := false
			for tc: CardInstance in state.cards_in_play(opp3):
				var tz := state.zones.get(tc.zone_id) as Zone
				if tz and tz.zone_type == "ally_row" and tc.is_exhausted:
					has_exhausted_ally = true
					break
			if not has_exhausted_ally:
				return false
		else:
			var t_card := state.get_card(target_id)
			if not t_card or not t_card.is_exhausted:
				return false
			var t_zone := state.zones.get(t_card.zone_id) as Zone
			if not t_zone or t_zone.zone_type != "ally_row":
				return false
	# deal_7_minus_hand_to_hero: target must be a hero (in hero_row).
	if _power_effect_is(def, "deal_7_minus_hand_to_hero"):
		if target_id == "":
			# Pre-targeting probe: pass if there's at least one enemy hero alive.
			var opp2 := "p2" if action.source_player == "p1" else "p1"
			var ps2 := state.players.get(opp2) as PlayerState
			if not ps2 or ps2.hero_instance_id == "" or not state.is_in_play(ps2.hero_instance_id):
				return false
		else:
			var t_card2 := state.get_card(target_id)
			if not t_card2:
				return false
			var t_zone2 := state.zones.get(t_card2.zone_id) as Zone
			if not t_zone2 or t_zone2.zone_type != "hero_row":
				return false
	# deal_x_damage_to_ally: target must be an ally, x_value >= 1, hero must survive the self-damage.
	if _power_effect_is(def, "deal_x_damage_to_ally"):
		if target_id == "":
			# Pre-targeting probe (context menu): check hero can survive x=1 and a valid target exists.
			if state.get_current_hp(hero_id, db) <= 1:
				return false
			var opp := "p2" if action.source_player == "p1" else "p1"
			var has_target := false
			for tc: CardInstance in state.cards_in_play(opp):
				var tz := state.zones.get(tc.zone_id) as Zone
				if tz and tz.zone_type == "ally_row":
					has_target = true
					break
			if not has_target:
				return false
		else:
			var t_card := state.get_card(target_id)
			if not t_card:
				return false
			var t_zone := state.zones.get(t_card.zone_id) as Zone
			if not t_zone or t_zone.zone_type != "ally_row":
				return false
			var x_value: int = action.params.get("x_value", 0)
			if x_value < 1:
				return false
			if x_value >= state.get_current_hp(hero_id, db):
				return false
	if _power_effect_is(def, "heal_x_from_target"):
		if target_id == "":
			# Pre-targeting probe: need at least 1 resource and a valid target in play.
			if state.get_available_resources(action.source_player) < 1:
				return false
		else:
			if not state.is_in_play(target_id):
				return false
			var x_value: int = action.params.get("x_value", 0)
			if x_value < 1:
				return false
			if x_value > state.get_available_resources(action.source_player):
				return false
	if _power_effect_is(def, "radak_pet_sacrifice"):
		var pet_id: String = action.params.get("pet_id", "")
		if pet_id == "" and target_id == "":
			# Pre-targeting probe: need at least one Pet whose cost we can afford.
			var affordable_pet := false
			var avail := state.get_available_resources(action.source_player)
			for c in state.cards_in_zone(action.source_player + "_ally_row"):
				var d := db.get_def(c.card_def_id) as CardDef
				if d and d.card_subtype == "Pet" and d.cost >= 1 and d.cost <= avail:
					affordable_pet = true
					break
			if not affordable_pet:
				return false
		elif pet_id != "" and target_id == "":
			# Phase 1→2 probe: pet must be owned, in play, and its cost must be affordable.
			if not state.is_in_play(pet_id):
				return false
			var pet_card := state.get_card(pet_id)
			if not pet_card or pet_card.controller != action.source_player:
				return false
			var pet_def := db.get_def(pet_card.card_def_id) as CardDef
			if not pet_def or pet_def.card_subtype != "Pet":
				return false
			if pet_def.cost < 1 or pet_def.cost > state.get_available_resources(action.source_player):
				return false
		else:
			# Full action: validate pet, resource cost, and damage target.
			if not state.is_in_play(pet_id) or not state.is_in_play(target_id):
				return false
			var pet_card2 := state.get_card(pet_id)
			if not pet_card2 or pet_card2.controller != action.source_player:
				return false
			var pet_def2 := db.get_def(pet_card2.card_def_id) as CardDef
			if not pet_def2 or pet_def2.card_subtype != "Pet":
				return false
			var x_value: int = action.params.get("x_value", 0)
			if x_value < 1 or x_value != pet_def2.cost:
				return false
			if x_value > state.get_available_resources(action.source_player):
				return false
	return true


static func _power_effect_is(def: CardDef, effect_key: String) -> bool:
	for entry in def.effects.split("|"):
		if entry.strip_edges().split(":")[0].strip_edges() == effect_key:
			return true
	return false


static func _resolve_activate_power(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var hero_id:   String = action.params.get("hero_id",   "")
	var target_id: String = action.params.get("target_id", "")
	var hero := state.get_card(hero_id)
	if not hero or not db:
		return []
	var def := db.get_def(hero.card_def_id) as CardDef
	if not def:
		return []

	var events: Array[GameEvent] = []
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.is_empty() or parts[0] == "":
			continue
		match parts[0].strip_edges():
			"deal_damage_to_target":
				# Format: deal_damage_to_target:AMOUNT:DMG_TYPE
				# Rule 706 re-check: fizzle if the target left play or became Untargetable.
				if not _is_legal_target(state, target_id, db):
					continue
				var amount := int(parts[1]) if parts.size() > 1 else 0
				events.append_array(defer_packets(state, db, [{
					"source": hero_id, "target": target_id, "amount": amount,
					"dmg_type": parts[2].to_lower().strip_edges() if parts.size() > 2 else "",
				}]))
			"deal_7_minus_hand_to_hero":
				# Format: deal_7_minus_hand_to_hero:DMG_TYPE
				# Damage = max(7 - hand size of target hero's controller, 0).
				if _is_legal_target(state, target_id, db):
					var t_card := state.get_card(target_id)
					var hand_size := state.cards_in_zone(t_card.controller + "_hand").size()
					var amount2: int = max(7 - hand_size, 0)
					if amount2 > 0:
						events.append_array(defer_packets(state, db, [{
							"source": hero_id, "target": target_id, "amount": amount2,
							# The printed type must travel with the packet — it is
							# what Shadowform / World in Flames key off.
							"dmg_type": parts[1].to_lower().strip_edges() if parts.size() > 1 else "",
						}]))
			"deal_x_damage_to_ally":
				# Format: deal_x_damage_to_ally:DMG_TYPE
				# x_value is chosen by the player; paid as self-damage before the
				# effect resolves. Both packets are DEALT (not put), so both go
				# through the prevention pipeline — the self-damage on the own
				# hero is preventable with own DEF armor (717.2c).
				var x_value: int = action.params.get("x_value", 0)
				if x_value >= 1 and _is_legal_target(state, target_id, db):
					# Only the OUTGOING packet carries the printed damage type:
					# the self-damage is the power's cost ("put X damage on her"),
					# not shadow damage the hero deals, so Shadowform must not
					# inflate what Dizdemona pays.
					events.append_array(defer_packets(state, db, [
						{"source": hero_id, "target": hero_id, "amount": x_value},
						{"source": hero_id, "target": target_id, "amount": x_value,
							"dmg_type": parts[1].to_lower().strip_edges() if parts.size() > 1 else ""},
					]))
			"target_cant_attack":
				# Litori Frostburn: "Target hero or ally can't attack this turn."
				# Rule 706 re-check: fizzle if the target left play or became Untargetable.
				# Does NOT remove an existing attacker from combat (602.4) — its bite
				# is via the 601.3 legality recheck when played in response to a
				# combat proposal still on the chain.
				if _is_legal_target(state, target_id, db):
					var ca_card := state.get_card(target_id)
					ca_card.active_buffs.append(Buff.make(
						"cant_attack_this_turn", hero_id, "cannot_attack", 1, "turns", 1))
					events.append(GameEvent.cant_attack_applied(target_id, hero_id))
			"heal_x_from_target":
				# X resources are already paid at submission. Heal X from target.
				var x_value: int = action.params.get("x_value", 0)
				if x_value >= 1 and _is_legal_target(state, target_id, db):
					events.append_array(GameLogic.heal(state, target_id, x_value, db, hero_id))
			"graveyard_to_hand":
				# Format: graveyard_to_hand:TYPE:MIN:MAX:OWNER[:MAX_COST] (hero-power use).
				# Re-check the target is still in a graveyard at resolution.
				if target_id != "":
					var gy_card := state.get_card(target_id)
					if gy_card:
						var gy_zone := state.zones.get(gy_card.zone_id) as Zone
						if gy_zone and gy_zone.zone_type == "graveyard":
							events.append_array(GameLogic.move_card(state, target_id, action.source_player + "_hand"))
							events.append(GameEvent.card_returned_from_graveyard(target_id, action.source_player))
			"radak_pet_sacrifice":
				# Pet already destroyed at submission. Deal x_value shadow damage to target.
				var x_value: int = action.params.get("x_value", 0)
				if x_value >= 1 and _is_legal_target(state, target_id, db):
					events.append_array(defer_packets(state, db, [{
						"source": hero_id, "target": target_id, "amount": x_value,
						"dmg_type": parts[1].to_lower().strip_edges() if parts.size() > 1 else "",
					}]))
			"melee_strike_discount":
				# Gorebelly: "You pay (3) less the next time you strike with a
				# Melee weapon this turn." Consumed by the next melee strike;
				# cleared at the start of every turn.
				var disc_amount := int(parts[1]) if parts.size() > 1 else 0
				var disc_ps := state.players.get(action.source_player) as PlayerState
				if disc_ps and disc_amount > 0:
					disc_ps.melee_strike_discount += disc_amount
					events.append(GameEvent.strike_discount_gained(
						action.source_player, disc_amount))
			"ranged_weapon_atk_bonus":
				# Elendril: "Your Ranged weapons have +3 ATK this turn." Player-
				# tracked (PlayerState.ranged_weapon_atk_bonus), applied in
				# GameState.get_atk; cleared at the start of every turn.
				var rw_amount := int(parts[1]) if parts.size() > 1 else 0
				var rw_ps := state.players.get(action.source_player) as PlayerState
				if rw_ps and rw_amount != 0:
					rw_ps.ranged_weapon_atk_bonus += rw_amount
					events.append(GameEvent.ranged_weapon_bonus_gained(
						action.source_player, rw_amount))
			"shuffle_hand_draw":
				events.append_array(
					GameLogic.shuffle_hand_into_deck_and_draw(state, action.source_player))
			"destroy_exhausted_ally":
				if _is_legal_target(state, target_id, db):
					events.append_array(_destroy_card_trigger(state, target_id, hero_id, db))
			"deal_damage_and_heal":
				# Format: deal_damage_and_heal:DMG_AMOUNT:DMG_TYPE:HEAL_AMOUNT
				# The heal is unconditional (not per-damage), so it lands
				# inline; the damage packet goes through the prevention pipeline.
				var dmg_amount  := int(parts[1]) if parts.size() > 1 else 0
				var heal_amount := int(parts[3]) if parts.size() > 3 else 0
				var heal_target_id: String = action.params.get("heal_target_id", "")
				if _is_legal_target(state, heal_target_id, db):
					events.append_array(GameLogic.heal(state, heal_target_id, heal_amount, db, hero_id))
				if _is_legal_target(state, target_id, db):
					events.append_array(defer_packets(state, db, [{
						"source": hero_id, "target": target_id, "amount": dmg_amount,
						"dmg_type": parts[2].to_lower().strip_edges() if parts.size() > 2 else "",
					}]))
	return events


# ── Enters-play targeted effect ────────────────────────────────────────────────

static func _can_choose_enter_play_target(state: GameState, action: PendingAction,
		db = null) -> bool:
	if state.pending_enter_play_effect.is_empty():
		return false
	var source_id: String = action.params.get("source_card_id", "")
	if source_id != state.pending_enter_play_effect.get("card_id", ""):
		return false
	var source_card := state.get_card(source_id)
	if not source_card or source_card.controller != action.source_player:
		return false
	# Only one choose_enter_play_target can be on the chain at a time.
	for a in state.pending_actions:
		if (a as PendingAction).action_type == "choose_enter_play_target":
			return false
	var target_id: String = action.params.get("target_id", "")
	if not _is_legal_target(state, target_id, db):
		return false
	# Effect-specific target restriction (Ghank): only an exhausted ally with
	# damage on it is a legal target.
	if String(state.pending_enter_play_effect.get("effect", "")) == "destroy_exhausted_damaged_ally" \
			and target_id not in get_enter_play_destroy_targets(state, db):
		return false
	if String(state.pending_enter_play_effect.get("effect", "")) == "destroy_armor" \
			and target_id not in get_enter_play_equipment_targets(state, db, false):
		return false
	if String(state.pending_enter_play_effect.get("effect", "")) == "destroy_armor_or_weapon" \
			and target_id not in get_enter_play_equipment_targets(state, db, true):
		return false
	if String(state.pending_enter_play_effect.get("effect", "")) == "destroy_ability" \
			and target_id not in get_enter_play_ability_targets(state, db):
		return false
	# Karkas Deathhowl / Bhenn Checks-the-Sky: any in-play ally, the source included.
	if String(state.pending_enter_play_effect.get("effect", "")) in \
			["return_to_hand_ally", "exhaust_ally"] \
			and target_id not in get_death_target_targets(state, db):
		return false
	return true


# Legal targets for Ghank's enter-play trigger: any in-play ally (either party)
# that is BOTH exhausted and has at least 1 damage on it, subject to the
# standard targeting restrictions (untargetable).
static func get_enter_play_destroy_targets(state: GameState, db) -> Array[String]:
	var result: Array[String] = []
	for pid in state.players:
		for ally in state.cards_in_zone(pid + "_ally_row"):
			if ally.is_exhausted and ally.damage_taken > 0 \
					and _is_legal_target(state, ally.instance_id, db):
				result.append(ally.instance_id)
	return result


# Legal targets for Hur Shieldsmasher / Zygore Bladebreaker's enter-play
# triggers: in-play equipment (either party), subject to the standard
# targeting restrictions (untargetable). include_weapons false → armor only
# (Hur); true → any equipment, armor or weapon (Zygore).
static func get_enter_play_equipment_targets(state: GameState, db,
		include_weapons: bool) -> Array[String]:
	var result: Array[String] = []
	for eq_id in get_destroy_kind_candidates(state, db, "equipment"):
		if not _is_legal_target(state, eq_id, db):
			continue
		if not include_weapons:
			var card := state.get_card(eq_id)
			var def := db.get_def(card.card_def_id) as CardDef if card else null
			if not _weapon_info(def).is_empty():
				continue
		result.append(eq_id)
	return result


# Legal targets for Sister Rot's enter-play trigger: in-play ability cards
# (either party) — Burn Away's pool (ongoing abilities in a hero row, totems in
# an ally row, attachments), subject to the standard targeting restrictions.
static func get_enter_play_ability_targets(state: GameState, db) -> Array[String]:
	var result: Array[String] = []
	for ab_id in get_destroy_kind_candidates(state, db, "ability"):
		if _is_legal_target(state, ab_id, db):
			result.append(ab_id)
	return result


# Decline an OPTIONAL pending enters-play effect ("you may ..." — Ghank).
# Direct call from the scene (Esc / AI decline) — mandatory effects (Taz'dingo)
# can't be declined and are left untouched.
static func decline_enter_play_effect(state: GameState) -> Array[GameEvent]:
	if state.pending_enter_play_effect.is_empty() \
			or not state.pending_enter_play_effect.get("optional", false):
		return []
	var card_id: String = state.pending_enter_play_effect.get("card_id", "")
	state.pending_enter_play_effect = {}
	return [GameEvent.make("enter_play_effect_declined", {"card_id": card_id})]


static func _resolve_choose_enter_play_target(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var source_id: String = action.params.get("source_card_id", "")
	var target_id: String = action.params.get("target_id", "")
	# The effect was captured onto the chain link at submission (submit_action),
	# where pending_enter_play_effect was cleared so the priority window is real.
	var effect_dict: Dictionary = action.params.get("_effect_dict", {})

	var events: Array[GameEvent] = []
	var effect_str: String = effect_dict.get("effect", "")
	var parts := effect_str.split(":")
	if parts.is_empty():
		return events
	match parts[0]:
		"deal_damage_to_target":
			# Rule 706 re-check: fizzle if the target left play or became Untargetable.
			if not _is_legal_target(state, target_id, db):
				return events
			var amount := int(parts[1]) if parts.size() > 1 else 0
			events.append_array(defer_packets(state, db, [{
				"source": source_id, "target": target_id, "amount": amount,
			}]))
		"destroy_exhausted_damaged_ally":
			# Ghank — 706 re-check: fizzle unless the target is STILL an
			# exhausted, damaged, targetable ally at resolution.
			var tgt := state.get_card(target_id)
			if _is_legal_target(state, target_id, db) and _is_ally(state, target_id) \
					and tgt and tgt.is_exhausted and tgt.damage_taken > 0:
				events.append_array(_destroy_card_trigger(state, target_id, source_id, db))
		"destroy_armor":
			# Hur Shieldsmasher — 706 re-check: fizzle unless still legal armor.
			if target_id in get_enter_play_equipment_targets(state, db, false):
				events.append_array(_destroy_card_trigger(state, target_id, source_id, db))
		"destroy_armor_or_weapon":
			# Zygore Bladebreaker — 706 re-check: fizzle unless still legal equipment.
			if target_id in get_enter_play_equipment_targets(state, db, true):
				events.append_array(_destroy_card_trigger(state, target_id, source_id, db))
		"destroy_ability":
			# Sister Rot — 706 re-check: fizzle unless still a legal in-play ability.
			if target_id in get_enter_play_ability_targets(state, db):
				events.append_array(_destroy_card_trigger(state, target_id, source_id, db))
		"return_to_hand_ally":
			# Karkas Deathhowl — 706 re-check: fizzle unless the target is still a
			# legal in-play ally. move_card resets damage/exhaust/buffs (400.6a),
			# destroys its attachments (400.5) and fizzles a combat proposal it was
			# part of (601.3); a token ceases to exist instead of reaching a hand.
			if target_id in get_death_target_targets(state, db):
				var rth := state.get_card(target_id)
				events.append_array(GameLogic.move_card(
					state, target_id, rth.owner + "_hand"))
				events.append(GameEvent.card_returned_to_hand(target_id, source_id))
		"exhaust_ally":
			# Bhenn Checks-the-Sky — 706 re-check: fizzle unless the target is
			# still a legal in-play ally. exhaust_card no-ops on an already-
			# exhausted ally. Aimed at an attacking ally while its combat
			# proposal is still on the chain, this fizzles the proposal at the
			# 601.3 recheck — Exhaustion's interrupt on an Instant Ally body.
			if target_id in get_death_target_targets(state, db):
				events.append_array(GameLogic.exhaust_card(state, target_id))
	return events


# ── Ongoing Totem "start of each turn" targeted damage (Searing Totem) ──────────
# Rule 501.1a / 410: the triggered ability is put on the CHAIN during the ready
# step with its target chosen up front, and a priority window opens before it
# resolves — so either player may respond with an instant (heal the target, use
# its activated power) before the damage lands. The target choice itself is still
# a direct-call mandatory point (choose_totem_target); once picked, the trigger
# becomes a `resolve_totem_trigger` chain link that the normal pass/resolve
# machinery drains. See _resolve_totem_trigger.

# Peek the front pending totem trigger, skipping any whose source left play
# (711.1), and mark its controller as the player who must pick a target. Returns
# the totem_target_required event, or [] (and clears the pending marker) when the
# queue is empty. Called by turn-start collection and after each resolution.
static func _open_next_totem_trigger(state: GameState, db) -> Array[GameEvent]:
	while not state.pending_ongoing_triggers.is_empty():
		var trigger: Dictionary = state.pending_ongoing_triggers[0]
		var source_id: String = trigger.get("card_id", "")
		var source := state.get_card(source_id)
		if not source or not state.is_in_play(source_id):
			state.pending_ongoing_triggers.pop_front()
			continue
		state.pending_totem_target_player = source.controller
		return [GameEvent.totem_target_required(
			source_id, source.controller,
			trigger.get("dmg_type", ""), int(trigger.get("amount", 0)))]
	state.pending_totem_target_player = ""
	return []


# Announce the active totem trigger's target: put the trigger on the chain as a
# `resolve_totem_trigger` link (target baked in) and open a priority window. The
# turn player gets priority first (rule 410). target_id must be a legal hero or
# ally in play — 706 is re-checked here (at announcement) and again at resolution
# (709.2a) so a target that leaves play / becomes Untargetable in the window
# fizzles. Direct call for the CHOICE; the damage itself resolves off the chain.
static func choose_totem_target(state: GameState, target_id: String, db) -> Array[GameEvent]:
	if state.pending_totem_target_player == "" or state.pending_ongoing_triggers.is_empty():
		return []
	var trigger: Dictionary = state.pending_ongoing_triggers.pop_front()
	state.pending_totem_target_player = ""
	var source_id: String = trigger.get("card_id", "")
	var amount := int(trigger.get("amount", 0))
	var source := state.get_card(source_id)
	var events: Array[GameEvent] = []
	# 706 re-check at announcement: the source must still be in play and the
	# target legal. If so, the trigger goes on the chain and a window opens.
	if source and state.is_in_play(source_id) and amount > 0 \
			and _is_legal_target(state, target_id, db):
		var link := PendingAction.make("resolve_totem_trigger", source.controller, {
			"card_id":  source_id,
			"target_id": target_id,
			"amount":   amount,
		})
		state.pending_actions.push_back(link)
		state.consecutive_passes = 0
		state.priority_player    = state.turn_player   # rule 410: turn player first
		events.append(GameEvent.make("action_proposed", {
			"action_type": "resolve_totem_trigger",
			"player":      source.controller,
			"card_id":     source_id,
		}))
		return events
	# Fizzled at announcement — open the next queued totem trigger, if any.
	events.append_array(_open_next_totem_trigger(state, db))
	return events


# Resolve a totem trigger's damage after its priority window closed. Re-checks the
# TARGET at resolution (709.2a — it may have left play or become Untargetable in
# the window), then hands the packet to the prevention machinery (717.2c — an
# armored hero target gets the point first). The "totem_next" after-hook opens the
# next queued trigger once the packet lands.
#
# The SOURCE is deliberately NOT re-checked: once the trigger is announced onto
# the chain it is independent of the totem that produced it (711.1 only gates
# announcement, in _open_next_totem_trigger), so destroying Searing Totem in the
# response window is too late — the ping still resolves. deal_damage and the
# prevention offer only use source_id for reporting, so a graveyard source is safe.
static func _resolve_totem_trigger(state: GameState, action: PendingAction,
		db = null) -> Array[GameEvent]:
	var source_id: String = action.params.get("card_id", "")
	var target_id: String = action.params.get("target_id", "")
	var amount := int(action.params.get("amount", 0))
	var events: Array[GameEvent] = []
	if state.is_in_play(target_id) and amount > 0 \
			and _is_legal_target(state, target_id, db):
		events.append_array(defer_packets(state, db,
			[{"source": source_id, "target": target_id, "amount": amount}],
			"totem_next"))
		return events
	# Fizzled (source/target gone or now Untargetable) — still open the next
	# queued totem trigger so the chain of start-of-turn triggers drains.
	events.append(GameEvent.make("action_fizzled", {
		"action_type": "resolve_totem_trigger", "reason": "target_gone",
	}))
	events.append_array(_open_next_totem_trigger(state, db))
	return events


# Legal targets for a totem trigger: every hero and ally in play (rule: "target
# hero or ally"), subject to the standard targeting restrictions (untargetable).
static func get_totem_targets(state: GameState, db) -> Array[String]:
	var result: Array[String] = []
	for pid in state.players:
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "" and _is_legal_target(state, ps.hero_instance_id, db):
			result.append(ps.hero_instance_id)
		for ally in state.cards_in_zone(pid + "_ally_row"):
			if _is_legal_target(state, ally.instance_id, db):
				result.append(ally.instance_id)
	return result


# ── Helpers ────────────────────────────────────────────────────────────────────

static func _other_player(state: GameState, player_id: String) -> String:
	for pid in state.players:
		if pid != player_id:
			return pid
	return player_id


# Controller of the source card of the pending enters-play effect.
# Falls back to the turn player if the source card can't be resolved.
static func _pending_effect_controller(state: GameState) -> String:
	var src := state.get_card(state.pending_enter_play_effect.get("card_id", ""))
	return src.controller if src else state.turn_player


# Fire any "on_destroyed" effects declared in the card's effects string.
# Called AFTER the card has already moved to the graveyard (rule 703.3c).
# Format: on_destroyed:deal_damage_aoe:AMOUNT:DMG_TYPE:opposing
static func _fire_on_destroyed(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.effects == "":
		return []

	var events: Array[GameEvent] = []
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] != "on_destroyed":
			continue
		if parts.size() < 2:
			continue
		match parts[1]:
			"deal_damage_aoe":
				# on_destroyed:deal_damage_aoe:AMOUNT:DMG_TYPE:opposing
				# Packets go through the prevention machinery (717.2c) — the
				# opposing hero's controller may exhaust DEF armor first.
				# recursive_destroy=false: no recursive on_destroyed for AoE
				# secondary kills.
				var amount := int(parts[2]) if parts.size() > 2 else 1
				var opp    := _other_player(state, card.controller)
				var packets: Array = []
				var opp_ps := state.players.get(opp) as PlayerState
				if opp_ps and opp_ps.hero_instance_id != "":
					packets.append({"source": card_id,
						"target": opp_ps.hero_instance_id, "amount": amount})
				for ally in state.cards_in_zone(opp + "_ally_row"):
					packets.append({"source": card_id,
						"target": ally.instance_id, "amount": amount})
				events.append_array(defer_packets(state, db, packets, "", false))
			"destroy_target":
				# on_destroyed:destroy_target:ally (Boneshanks: "When [this] is
				# destroyed, destroy target ally."). Mandatory targeted death
				# trigger: queue it and open the choice for the destroyed card's
				# controller (a direct-call choice, like a totem trigger — NOT the
				# chain). If no ally is in play there is no legal target, so the
				# trigger does nothing. The chosen ally is destroyed in
				# choose_death_target(); chained deaths queue behind it.
				if not get_death_target_targets(state, db).is_empty():
					state.pending_death_triggers.append({
						"card_id": card_id, "controller": card.controller})
					events.append_array(_open_next_death_trigger(state, db))
			"pay_return_hand":
				# on_destroyed:pay_return_hand:COST (Bear Form / Cat Form): the
				# controller may pay COST to return the destroyed card from the
				# graveyard to hand. Opens a direct-call choice point
				# (choose_form_return) — skipped when unaffordable or another
				# return choice is already open (can't happen with Form (1)
				# uniqueness, but guard anyway).
				var return_cost := int(parts[2]) if parts.size() > 2 else 2
				if state.pending_form_return_player == "" \
						and state.get_available_resources(card.controller) >= return_cost:
					state.pending_form_return_player  = card.controller
					state.pending_form_return_card_id = card_id
					state.pending_form_return_cost    = return_cost
					events.append(GameEvent.form_return_opened(
						card.controller, card_id, return_cost))
	return events


# Peek the front queued death trigger and mark its controller as the player who
# must pick a target ally. Returns the death_target_required event, or [] (and
# clears the marker) when the queue is empty or no legal target remains.
static func _open_next_death_trigger(state: GameState, db) -> Array[GameEvent]:
	# Only open one at a time; a choice is already active.
	if state.pending_death_target_player != "":
		return []
	while not state.pending_death_triggers.is_empty():
		if get_death_target_targets(state, db).is_empty():
			# No legal ally left to destroy — the remaining triggers fizzle.
			state.pending_death_triggers.clear()
			break
		var trigger: Dictionary = state.pending_death_triggers[0]
		state.pending_death_target_player = trigger.get("controller", "")
		return [GameEvent.death_target_required(
			trigger.get("card_id", ""), trigger.get("controller", ""))]
	state.pending_death_target_player = ""
	return []


# Resolve the active death trigger (Boneshanks): destroy the chosen ally, then
# open the next queued trigger (if any). target_id must be a legal ally in play.
# Direct call — no chain, no priority pass. A chained death (destroying another
# Boneshanks) queues behind this one.
static func choose_death_target(state: GameState, target_id: String, db) -> Array[GameEvent]:
	if state.pending_death_target_player == "" or state.pending_death_triggers.is_empty():
		return []
	var trigger: Dictionary = state.pending_death_triggers.pop_front()
	var source_id: String = trigger.get("card_id", "")
	state.pending_death_target_player = ""
	var events: Array[GameEvent] = []
	# 706 re-check: the target must still be a legal ally in play.
	if _is_legal_target(state, target_id, db) and _is_ally(state, target_id):
		events.append_array(_destroy_card_trigger(state, target_id, source_id, db))
	# Open the next queued death trigger, if any (may have been added by the
	# destruction above).
	events.append_array(_open_next_death_trigger(state, db))
	return events


# Legal targets for a death-triggered "destroy target ally" effect: every ally
# in play (either party), subject to the standard targeting restrictions.
static func get_death_target_targets(state: GameState, db) -> Array[String]:
	var result: Array[String] = []
	for pid in state.players:
		for ally in state.cards_in_zone(pid + "_ally_row"):
			if _is_legal_target(state, ally.instance_id, db):
				result.append(ally.instance_id)
	return result


# Wrapper: check_destroyed + on_destroyed trigger if the card actually died.
static func _check_destroyed_trigger(state: GameState, card_id: String,
		source_id: String, db) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	var controller := card.controller if card else ""
	var events := GameLogic.check_destroyed(state, card_id, source_id, db)
	for e in events:
		if e.event_type == "card_destroyed" and e.payload.get("card", "") == card_id:
			events.append_array(_fire_on_destroyed(state, card_id, db))
			if controller != "":
				events.append_array(_check_aura_loss_deaths(state, controller, card_id, db))
			break
	events.append_array(_fire_recombobulation(state, db))
	return events


# When a card leaves play, any max-health aura it granted (party_health_aura,
# pet_atk_health_aura, ...) disappears immediately. Allies that were only
# alive because of that bonus must die now (rule 118.4/704 state-based death),
# not survive until the next damage event. Re-checks the departed card's own
# controller's board for anyone now at 0 or fewer effective health.
static func _check_aura_loss_deaths(state: GameState, controller: String,
		source_id: String, db) -> Array[GameEvent]:
	var events: Array[GameEvent] = []
	for card in state.cards_in_zone(controller + "_ally_row"):
		if state.get_current_hp(card.instance_id, db) <= 0:
			events.append_array(_check_destroyed_trigger(state, card.instance_id, source_id, db))
	return events


# Wrapper: destroy_card always fires on_destroyed (explicit removal effect).
# Heroes are a special case — an explicit destroy effect on a hero ends the game
# (that hero's controller loses) and the hero does NOT move to the graveyard.
static func _destroy_card_trigger(state: GameState, card_id: String,
		source_id: String, db) -> Array[GameEvent]:
	var card := state.get_card(card_id)
	if card and state.is_in_play(card_id) and db:
		var cdef := db.get_def(card.card_def_id) as CardDef
		if cdef and cdef.card_type == "Hero":
			var loser := card.controller
			var winner := "p2" if loser == "p1" else "p1"
			return [GameEvent.game_over(winner, loser)]
	var controller := card.controller if card else ""
	var events := GameLogic.destroy_card(state, card_id, source_id)
	if not events.is_empty():
		events.append_array(_fire_on_destroyed(state, card_id, db))
		if controller != "":
			events.append_array(_check_aura_loss_deaths(state, controller, card_id, db))
	events.append_array(_fire_recombobulation(state, db))
	return events


# ── Pet uniqueness (rule 414.3b) ──────────────────────────────────────────────

static func _check_pet_uniqueness(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or def.card_subtype != "Pet":
		return []
	# Gather all pets in controller's ally_row (only ally_row counts — 414.1).
	var pet_ids: Array[String] = []
	for c in state.cards_in_zone(card.controller + "_ally_row"):
		var d := db.get_def(c.card_def_id) as CardDef
		if d and d.card_subtype == "Pet":
			pet_ids.append(c.instance_id)
	var ps := state.players.get(card.controller) as PlayerState
	var capacity: int = ps.pet_capacity if ps else 1
	if pet_ids.size() <= capacity:
		return []
	# Violation: player must sacrifice until at most pet_capacity pets remain.
	state.pending_pet_sacrifice_player = card.controller
	state.pending_pet_sacrifice_ids.assign(pet_ids)
	var typed_ids: Array[String] = []
	typed_ids.assign(pet_ids)
	return [GameEvent.pet_sacrifice_required(card.controller, typed_ids)]


static func _can_choose_pet_sacrifice(state: GameState, action: PendingAction) -> bool:
	if state.pending_pet_sacrifice_player == "":
		return false
	if action.source_player != state.pending_pet_sacrifice_player:
		return false
	var chosen: String = action.params.get("card_id", "")
	return chosen in state.pending_pet_sacrifice_ids


static func _resolve_choose_pet_sacrifice(state: GameState, action: PendingAction,
		db) -> Array[GameEvent]:
	var chosen: String = action.params.get("card_id", "")
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(state, chosen, chosen, db))
	state.pending_pet_sacrifice_ids.erase(chosen)
	# Re-check: still a violation if more pets remain than capacity allows.
	var ps2 := state.players.get(state.pending_pet_sacrifice_player) as PlayerState
	var capacity2: int = ps2.pet_capacity if ps2 else 1
	var surviving_pets: Array[String] = []
	for cid in state.pending_pet_sacrifice_ids:
		if state.is_in_play(cid):
			surviving_pets.append(cid)
	if surviving_pets.size() <= capacity2:
		state.pending_pet_sacrifice_player = ""
		state.pending_pet_sacrifice_ids.clear()
	else:
		state.pending_pet_sacrifice_ids.assign(surviving_pets)
		var typed_ids: Array[String] = []
		typed_ids.assign(surviving_pets)
		events.append(GameEvent.pet_sacrifice_required(
			state.pending_pet_sacrifice_player, typed_ids))
	return events


# ── Equipment slot uniqueness (rule 414.3) ────────────────────────────────────
# Only one equipment may occupy a given slot (Chest, Back, Neck, …). When a
# second same-slot equipment enters play, the controller must destroy equipment
# until only one remains — mirrors the Pet uniqueness immediate-choice flow.

static func _check_equipment_uniqueness(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def:
		return []
	var info := _equipment_info(def)
	var slot: String = info.get("slot", "")
	if slot == "":
		return []
	# Gather all equipment in the controller's hero row that conflicts with this
	# card: same slot (414.3), or Two-Handed vs Off-Hand (414.3c — a Two-Handed
	# weapon carries the `two_handed` effects flag and occupies both hands, so it
	# can't coexist with an off_hand-slot equipment).
	var two_handed := _has_effect_flag(def, "two_handed")
	var same_slot_ids: Array[String] = []
	for c in state.cards_in_zone(card.controller + "_hero_row"):
		var d := db.get_def(c.card_def_id) as CardDef
		if not d or d.card_type != "Equipment":
			continue
		var d_slot: String = _equipment_info(d).get("slot", "")
		if d_slot == slot \
				or (two_handed and d_slot == "off_hand") \
				or (slot == "off_hand" and _has_effect_flag(d, "two_handed")):
			same_slot_ids.append(c.instance_id)
	# 414.3b: the slot's capacity, not a flat 1 — Trinket (2) allows two. Taken as
	# the STRICTEST capacity in the conflicting set, so the Two-Handed/Off-Hand
	# cross-conflicts folded in above (414.3c, always capacity 1) still violate
	# on the second card the way they always did.
	if same_slot_ids.size() <= _equipment_slot_capacity(state, same_slot_ids, db):
		return []
	state.pending_equip_sacrifice_player = card.controller
	state.pending_equip_sacrifice_ids.assign(same_slot_ids)
	var typed_ids: Array[String] = []
	typed_ids.assign(same_slot_ids)
	return [GameEvent.equipment_sacrifice_required(card.controller, typed_ids)]


# How many of a conflicting equipment set a player may control (rule 414.3b) —
# the strictest `equipment:SLOT:DEF:CAPACITY` capacity among them, so a set mixing
# a Two-Handed weapon with an Off-Hand equipment (414.3c) stays at 1. Falls back
# to 1 without a database, which is the pre-Trinket behaviour.
static func _equipment_slot_capacity(state: GameState, ids: Array, db) -> int:
	if db == null:
		return 1
	var capacity := -1
	for cid in ids:
		var c := state.get_card(cid)
		if not c:
			continue
		var d := db.get_def(c.card_def_id) as CardDef
		if not d:
			continue
		var cap := int(_equipment_info(d).get("capacity", 1))
		if capacity < 0 or cap < capacity:
			capacity = cap
	return capacity if capacity > 0 else 1


# Called directly by the scene (not via submit_action), like choose_pet_sacrifice.
static func choose_equipment_sacrifice(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_equip_sacrifice_player == "":
		return []
	if card_id not in state.pending_equip_sacrifice_ids:
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_equip_sacrifice_player:
		return []
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(state, card_id, card_id, db))
	state.pending_equip_sacrifice_ids.erase(card_id)
	# Re-check: still a violation if more than one same-slot equipment remains.
	var surviving: Array[String] = []
	for cid in state.pending_equip_sacrifice_ids:
		if state.is_in_play(cid):
			surviving.append(cid)
	if surviving.size() <= _equipment_slot_capacity(state, surviving, db):
		state.pending_equip_sacrifice_player = ""
		state.pending_equip_sacrifice_ids.clear()
	else:
		state.pending_equip_sacrifice_ids.assign(surviving)
		var typed_ids: Array[String] = []
		typed_ids.assign(surviving)
		events.append(GameEvent.equipment_sacrifice_required(
			state.pending_equip_sacrifice_player, typed_ids))
	return events


# ── Name-based uniqueness (rule 414.3a — the "Unique" tag) ────────────────────
# A player may not control two or more in-play cards that share a name and both
# carry the Unique tag (keywords column "Unique"). On violation the controller
# must destroy duplicates until only one same-named copy remains. Mirrors the Pet
# / Equipment uniqueness immediate-choice flow (non-interruptible; resolved via
# choose_unique_sacrifice(), a direct call — never through the chain).

static func _check_unique_uniqueness(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	if not def or "unique" not in def.keywords or def.card_name == "":
		return []
	# Gather every same-named Unique card this player controls in play. Unique
	# characters/equipment live in the ally_row or hero_row (414.1 — "in play").
	var dup_ids: Array[String] = []
	for zone_suffix in ["_ally_row", "_hero_row"]:
		for c in state.cards_in_zone(card.controller + zone_suffix):
			var d := db.get_def(c.card_def_id) as CardDef
			if d and "unique" in d.keywords and d.card_name == def.card_name:
				dup_ids.append(c.instance_id)
	if dup_ids.size() <= 1:
		return []
	state.pending_unique_sacrifice_player = card.controller
	state.pending_unique_sacrifice_ids.assign(dup_ids)
	var typed_ids: Array[String] = []
	typed_ids.assign(dup_ids)
	return [GameEvent.unique_sacrifice_required(card.controller, typed_ids)]


# Called directly by the scene (not via submit_action), like choose_pet_sacrifice.
# card_id must be one of the same-named Unique cards in the violation set.
static func choose_unique_sacrifice(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_unique_sacrifice_player == "":
		return []
	if card_id not in state.pending_unique_sacrifice_ids:
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_unique_sacrifice_player:
		return []
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(state, card_id, card_id, db))
	state.pending_unique_sacrifice_ids.erase(card_id)
	# Re-check: still a violation if more than one same-named copy remains in play.
	var surviving: Array[String] = []
	for cid in state.pending_unique_sacrifice_ids:
		if state.is_in_play(cid):
			surviving.append(cid)
	if surviving.size() <= 1:
		state.pending_unique_sacrifice_player = ""
		state.pending_unique_sacrifice_ids.clear()
	else:
		state.pending_unique_sacrifice_ids.assign(surviving)
		var typed_ids: Array[String] = []
		typed_ids.assign(surviving)
		events.append(GameEvent.unique_sacrifice_required(
			state.pending_unique_sacrifice_player, typed_ids))
	return events


# ── Slot-tag uniqueness: Form (N) / Aspect (N) (rule 414.3b) ──────────────────
# A player may control at most N cards carrying a given type-line slot tag —
# Form (1) on the Druid forms, Aspect (1) on the Hunter aspects. The tags are
# INDEPENDENT slots (one Form and one Aspect may coexist), so the count below
# only ever looks at cards sharing the entering card's own tag.
# When a second card of that tag enters, the controller must destroy them until
# N remain — normally keeping the new one (playing Cat Form while in Bear Form
# is how you shapeshift). Mirrors the Pet/Unique immediate-choice flow: resolved
# via choose_form_sacrifice() (direct call, tag-agnostic — the candidate id list
# fully describes the choice), can_submit hard-blocks while pending. Destroyed
# cards fire their on_destroyed pay-return trigger normally.

static func _check_form_uniqueness(state: GameState, card_id: String, db) -> Array[GameEvent]:
	if not db:
		return []
	var card := state.get_card(card_id)
	if not card:
		return []
	var def := db.get_def(card.card_def_id) as CardDef
	var spec := slot_tag_spec(def)
	if spec.is_empty():
		return []
	var tag: String = spec["tag"]
	var capacity: int = int(spec["count"])
	# Forms/Aspects are ongoing abilities living in the hero row (305.2c).
	var form_ids: Array[String] = []
	for c in state.cards_in_zone(card.controller + "_hero_row"):
		if slot_count_for(db.get_def(c.card_def_id) as CardDef, tag) >= 0:
			form_ids.append(c.instance_id)
	if form_ids.size() <= capacity:
		return []
	state.pending_form_sacrifice_player = card.controller
	state.pending_form_sacrifice_ids.assign(form_ids)
	var typed_ids: Array[String] = []
	typed_ids.assign(form_ids)
	return [GameEvent.form_sacrifice_required(card.controller, typed_ids, card_id)]


# Called directly by the scene (not via submit_action), like choose_pet_sacrifice.
static func choose_form_sacrifice(state: GameState, card_id: String,
		db = null) -> Array[GameEvent]:
	if state.pending_form_sacrifice_player == "":
		return []
	if card_id not in state.pending_form_sacrifice_ids:
		return []
	var card := state.get_card(card_id)
	if not card or card.controller != state.pending_form_sacrifice_player:
		return []
	var player := state.pending_form_sacrifice_player
	var events: Array[GameEvent] = []
	events.append_array(_destroy_card_trigger(state, card_id, card_id, db))
	state.pending_form_sacrifice_ids.erase(card_id)
	# Re-check: still a violation while more than one of them remains in play.
	# Both shipped slot tags are capacity 1 (Form (1), Aspect (1)); a capacity-2
	# tag would need the capacity carried on the pending state.
	var surviving: Array[String] = []
	for cid in state.pending_form_sacrifice_ids:
		if state.is_in_play(cid):
			surviving.append(cid)
	if surviving.size() <= 1:
		state.pending_form_sacrifice_player = ""
		state.pending_form_sacrifice_ids.clear()
	else:
		state.pending_form_sacrifice_ids.assign(surviving)
		var typed_ids: Array[String] = []
		typed_ids.assign(surviving)
		events.append(GameEvent.form_sacrifice_required(player, typed_ids, ""))
	return events


# ── Form break condition (glossary Bear Form / Cat Form) ──────────────────────
# "Destroy this card when you strike with a weapon or play a non-<TAG> ability."
# Checked when `player` resolves an Ability play (_resolve_play_instant /
# _resolve_play_ongoing_ability) and when they strike with a weapon
# (choose_strike). Fires at RESOLUTION time, not at announce — see
# data/rules_deviations.md "Form break timing". Destroys EVERY in-play Form of
# that player whose break tag doesn't match (414.2-style, no chain); the
# destruction fires the Form's own pay-return death trigger.

static func _check_form_break_ability(state: GameState, player_id: String,
		played_def: CardDef, db) -> Array[GameEvent]:
	if not db or not played_def or played_def.card_type != "Ability":
		return []
	var events: Array[GameEvent] = []
	for c in state.cards_in_zone(player_id + "_hero_row"):
		var f_def := db.get_def(c.card_def_id) as CardDef
		# Shadowform's INVERTED condition (`form_break_on:TAG`): destroyed when
		# you play an ability that DOES carry the tag ("when you play a Holy
		# ability"), rather than one that doesn't. Its printed text names only
		# ability plays, so unlike the Feral forms it survives weapon strikes —
		# _check_form_break_strike deliberately ignores it.
		var on_tag := form_break_on_tag(f_def)
		if on_tag != "":
			if on_tag in played_def.tags:
				events.append(GameEvent.form_broken(c.instance_id, player_id,
						"%s_ability" % on_tag.to_lower()))
				events.append_array(_destroy_card_trigger(state, c.instance_id, c.instance_id, db))
			continue
		var tag := form_break_tag(f_def)
		if tag == "" or tag in played_def.tags:
			continue   # not a breakable Form / the played ability matches (Feral)
		events.append(GameEvent.form_broken(c.instance_id, player_id, "non_%s_ability" % tag.to_lower()))
		events.append_array(_destroy_card_trigger(state, c.instance_id, c.instance_id, db))
	return events


static func _check_form_break_strike(state: GameState, player_id: String,
		db) -> Array[GameEvent]:
	if not db:
		return []
	var events: Array[GameEvent] = []
	for c in state.cards_in_zone(player_id + "_hero_row"):
		var f_def := db.get_def(c.card_def_id) as CardDef
		if form_break_tag(f_def) == "":
			continue
		events.append(GameEvent.form_broken(c.instance_id, player_id, "weapon_strike"))
		events.append_array(_destroy_card_trigger(state, c.instance_id, c.instance_id, db))
	return events


# ── Form pay-return death trigger ─────────────────────────────────────────────
# Bear Form / Cat Form: "When [this] is destroyed, you may pay (2). If you do,
# put it into your hand." Opened from _fire_on_destroyed only when the
# controller can afford the cost; resolved via choose_form_return() (direct
# call, like choose_whelp_bounce; can_submit/pass_priority hard-block while
# pending). v1 returns the card immediately on payment instead of at the next
# end of turn — see data/rules_deviations.md "Form return timing".
static func choose_form_return(state: GameState, pay: bool,
		db = null) -> Array[GameEvent]:
	if state.pending_form_return_player == "":
		return []
	var player_id := state.pending_form_return_player
	var card_id   := state.pending_form_return_card_id
	var cost      := state.pending_form_return_cost
	state.pending_form_return_player  = ""
	state.pending_form_return_card_id = ""
	state.pending_form_return_cost    = 0

	var events: Array[GameEvent] = []
	var card := state.get_card(card_id)
	var in_graveyard := false
	if card:
		var zone := state.zones.get(card.zone_id) as Zone
		in_graveyard = zone != null and zone.zone_type == "graveyard"
	if pay and in_graveyard \
			and state.get_available_resources(player_id) >= cost:
		events.append_array(_pay_resource_cost(state, player_id, cost))
		events.append_array(GameLogic.move_card(state, card_id, card.owner + "_hand"))
		events.append(GameEvent.form_return_resolved(player_id, card_id, true))
	else:
		events.append(GameEvent.form_return_resolved(player_id, card_id, false))
	return events
