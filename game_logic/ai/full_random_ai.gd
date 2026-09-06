class_name FullRandomAI
extends BaseAI

# Picks a random legal action each time it has priority.
# No heuristics — pure chaos. Functional but terrible strategist.
# Useful as a stress-test: will reach edge cases a heuristic AI never would.
#
# Response rule: plays at most one card per opponent action.
# Can respond multiple times in a game, but never chains responses back-to-back.

var _responded: bool = false


# Pick a random Protector or skip ("") with equal probability per slot.
# With 3 legal protectors the pool is [p1, p2, p3, ""] → 1/4 chance to skip.
func choose_protector(state: GameState, db, _player_id: String) -> String:
	var pool: Array = StackResolver.get_legal_protectors(
		state, state.combat_attacker, state.combat_defender, db)
	pool.append("")   # skip option
	return pool[randi() % pool.size()]


# Lethal pools (find_lethal) are ranked by card value: FullRandomAI always
# kills the most valuable target. See game_logic/ai/ai_functions.md.
func rank_lethal_targets(state: GameState, db,
		lethal: Array[String]) -> Array[String]:
	return BaseAI.sort_valuable_cards(state, db, lethal)


func decide_action(state: GameState, db, player_id: String) -> PendingAction:
	# Don't act during ready or draw phases — pass and let the phase advance.
	if state.phase in ["ready", "draw"]:
		return null
	# Combat-instant ambush (BaseAI) — deterministic, never left to the dice.
	var ambush := combat_instant_action(state, db, player_id)
	if ambush != null:
		return ambush
	# Instant protector flash-in (BaseAI) — deterministic too.
	var flash := instant_protector_action(state, db, player_id)
	if flash != null:
		return flash
	# Dragonkin Menace (BaseAI) — ready a spent protector while attacked.
	var ready_quest := ready_protector_quest_action(state, db, player_id)
	if ready_quest != null:
		return ready_quest
	var thangal := thangal_ready_action(state, db, player_id)
	if thangal != null:
		return thangal
	var warrax := warrax_protector_action(state, db, player_id)
	if warrax != null:
		return warrax
	# Escape Artist (BaseAI) — deterministic too.
	var escape := escape_artist_action(state, db, player_id)
	if escape != null:
		return escape
	var counter := counterspell_action(state, db, player_id)
	if counter != null:
		return counter
	# Brain Freeze — nullify a draw link the opponent has already paid for.
	var freeze_draws := brain_freeze_action(state, db, player_id)
	if freeze_draws != null:
		return freeze_draws
	# Hero disable flip (BaseAI, e.g. Litori Frostburn) — deterministic too.
	# Wing Clip: the same interrupt point as Litori's freeze, on a 1-cost
	# hand card, and narrowed to proposals aimed at our own HERO.
	var clip := wing_clip_action(state, db, player_id)
	if clip != null:
		return clip
	var freeze := hero_disable_action(state, db, player_id)
	if freeze != null:
		return freeze
	# Destroy the opponent's protecting ally (BaseAI, First to Fall) — deterministic.
	var kill_protector := destroy_protector_action(state, db, player_id)
	if kill_protector != null:
		return kill_protector
	# Sneak elusive-save (BaseAI) — deterministic, never left to the dice.
	var sneak := elusive_save_action(state, db, player_id)
	if sneak != null:
		return sneak
	var wrath := bestial_wrath_action(state, db, player_id)
	if wrath != null:
		return wrath
	# Mortal Strike (BaseAI) — lethal on their hero, or a hard counter to a heal on it.
	var mortal := mortal_strike_action(state, db, player_id)
	if mortal != null:
		return mortal
	# Katsin Bloodoath (BaseAI) — shield an ally that would die in this combat.
	# Avanthera — pull her out of a combat she would not survive.
	var avanthera := avanthera_escape_action(state, db, player_id)
	if avanthera != null:
		return avanthera
	# Ghost Wolf — cancel an ally attack our hero is defending against.
	var ghost_wolf := ghost_wolf_action(state, db, player_id)
	if ghost_wolf != null:
		return ghost_wolf
	# Waylay — with a stealthed hero it KILLS the attacking ally, which the
	# shared combat_instant_exhaust path would misprice as a mere freeze.
	var waylay := waylay_action(state, db, player_id)
	if waylay != null:
		return waylay
	var katsin := katsin_shield_action(state, db, player_id)
	if katsin != null:
		return katsin
	# Soul Link (BaseAI) — move incoming hero damage onto the party.
	var soul_link := soul_link_action(state, db, player_id)
	if soul_link != null:
		return soul_link
	# Graccus — the game's one flip, spent on damage already on its way.
	# Holy Shield — ward our hero against one attacker, and reflect it back.
	var holy := holy_shield_action(state, db, player_id)
	if holy != null:
		return holy
	var graccus := graccus_shield_action(state, db, player_id)
	if graccus != null:
		return graccus
	var korthas := korthas_shield_action(state, db, player_id)
	if korthas != null:
		return korthas
	# Withdraw save-bounce (BaseAI) — deterministic, never left to the dice.
	var save := save_bounce_action(state, db, player_id)
	if save != null:
		return save
	# Doomed self-sacrifice cash-in (BaseAI, Kavai the Wanderer) — deterministic.
	var cash_in := doomed_sacrifice_action(state, db, player_id)
	if cash_in != null:
		return cash_in
	# Blink dodge (BaseAI) — deterministic, never left to the dice.
	var dodge := evasion_action(state, db, player_id)
	if dodge != null:
		return dodge
	# Ravenous Bite ATK swing (BaseAI) — only when it flips the open combat.
	var swing := atk_swing_action(state, db, player_id)
	if swing != null:
		return swing
	# Bear Form flash-in (BaseAI) — deterministic, never left to the dice.
	var shift := bear_form_action(state, db, player_id)
	if shift != null:
		return shift
	# Outrider Zarg (BaseAI) — he dies at end of turn unless he dealt damage, so
	# the attack is deterministic too rather than left to the dice.
	var use_it := use_it_or_lose_it_attack_action(state, db, player_id)
	if use_it != null:
		return use_it
	# Off-turn, everything below is a blind random play out of our own hand and
	# board — the deterministic defensive hooks above are the only things worth
	# doing in an opponent's window. GenericAI gates the same way (see the
	# "our own action window only" guard in its decide_action).
	#
	# This gate is also what lets a card whose effect only bites on its
	# controller's turn stay LEGAL off-turn as the printed rules require: For the
	# Horde!, Rayder and Ryn Dreamstrider used to carry `require_turn_player`
	# purely so the AI wouldn't waste them off-turn, which was a rules deviation.
	# They now carry `mute_when:opponent_turn` instead, and this gate is the AI
	# half of that swap.
	if state.turn_player != player_id:
		_responded = false
		# Rule 600.2 still applies: the engine refuses our pass while one of our
		# characters must attack and is able to.
		return forced_attack_action(state, db, player_id)

	var legal := get_reasonable_actions(state, db, player_id)
	if legal.is_empty():
		_responded = false
		# Rule 600.2: the engine refuses our pass while one of our characters must
		# attack and is able to — make that attack instead of stalling on it.
		return forced_attack_action(state, db, player_id)

	# Chain empty = own turn to act: always play something (passing wastes resources).
	if state.pending_actions.is_empty():
		_responded = false
		return legal[randi() % legal.size()]

	# Already played one response this window — pass now and reset.
	if _responded:
		_responded = false
		return null

	# Responding: pass is one option among the legal plays.
	# 1 legal action → 50% pass; 3 legal actions → 25% pass; etc.
	var pool: Array = legal.duplicate()
	pool.append(null)
	var choice: PendingAction = pool[randi() % pool.size()]
	_responded = (choice != null)
	return choice
