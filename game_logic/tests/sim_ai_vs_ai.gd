extends SceneTree

# Headless AI-vs-AI stall reproducer.
# Drives two GenericAI players through full games via the engine, mirroring the
# playtest scene's decision loop (mandatory choices + submit/pass + advance).
# Detects deadlocks: if many decision ticks pass with no zone/turn progress, it
# dumps the state so we can see what the AI is stuck on.

const MAX_TICKS_PER_GAME := 6000
const STALL_LIMIT := 200   # ticks with no observable progress -> deadlock

func _init() -> void:
	var db := CardDatabase.new()
	db.load_all()

	var deck_ids := DeckManager.get_available_decks().all()
	var games := 0
	var stalls := 0

	for gi in 40:
		var d1: String = deck_ids[randi() % deck_ids.size()]
		var d2: String = deck_ids[randi() % deck_ids.size()]
		var result := _run_game(db, d1, d2)
		games += 1
		if result != "":
			stalls += 1
			print("STALL in game %d  (%s vs %s):" % [gi, d1, d2])
			print(result)
			print("──────────────────────────────────────────")
			if stalls >= 3:
				break

	print("\n=== Ran %d games, %d stalls ===" % [games, stalls])
	quit(1 if stalls > 0 else 0)


func _run_game(db: CardDatabase, deck_id1: String, deck_id2: String) -> String:
	var deck1 := DeckManager.get_runtime_deck(deck_id1)
	var deck2 := DeckManager.get_runtime_deck(deck_id2)
	if deck1 == null or deck2 == null:
		return ""

	var gm := GameManager.new()
	gm.setup(db)
	gm.add_player("p1", GameManager.AI, deck1)
	gm.add_player("p2", GameManager.AI, deck2)
	var state := gm.build_state()

	var ais := {"p1": GenericAI.new(), "p2": GenericAI.new()}

	var game_over := [false]
	TurnManager.start_game(state, "p1", db)

	var last_sig := _progress_sig(state)
	var since_progress := 0

	for tick in MAX_TICKS_PER_GAME:
		if game_over[0]:
			return ""

		# Mandatory: mulligan phase — both AIs keep.
		if not state.mulligan_decided.get("p1", false) or not state.mulligan_decided.get("p2", false):
			for pid in ["p1", "p2"]:
				if not state.mulligan_decided.get(pid, false):
					TurnManager.commit_mulligan(state, pid,
							(ais[pid] as BaseAI).wants_mulligan(state, db, pid), db)
			continue

		# Mandatory: enter-play target. Only announce a target when one isn't
		# already on the chain (the chain drains via normal alternating passes).
		if not state.pending_enter_play_effect.is_empty() and not _choose_on_chain(state):
			_resolve_enter_play(state, db)
			since_progress += 1
			if since_progress > STALL_LIMIT:
				return "DEADLOCK on pending_enter_play_effect\n" + _dump(state, db)
			continue
		if state.pending_discard_count > 0:
			var did: String = (ais[state.pending_discard_player] as BaseAI).choose_discard_card(
					state, db, state.pending_discard_player)
			if did == "":
				return "DEADLOCK: discard required but AI returned no card\n" + _dump(state, db)
			StackResolver.choose_discard(state, did, db)
			continue
		if state.pending_control_discard_player != "":
			# Infernal: discard the least valuable card; decline (give control)
			# only when the hand is empty.
			var cdp := state.pending_control_discard_player
			var cd_id: String = (ais[cdp] as BaseAI).choose_discard_card(state, db, cdp) \
					if not state.cards_in_zone(cdp + "_hand").is_empty() else ""
			if cd_id != "":
				StackResolver.choose_control_discard(state, cd_id, db)
			else:
				StackResolver.decline_control_discard(state, db)
			continue
		if state.pending_pet_sacrifice_player != "":
			# Sacrifice the first candidate (keep-best logic lives in the scene).
			var sac := state.cards_in_zone(state.pending_pet_sacrifice_player + "_ally_row")
			var done := false
			for c in sac:
				var d := db.get_def(c.card_def_id) as CardDef
				if d and d.card_subtype == "Pet":
					StackResolver.choose_pet_sacrifice(state, c.instance_id, db)
					done = true
					break
			if not done:
				return "DEADLOCK: pet sacrifice required, no pet found\n" + _dump(state, db)
			continue
		if state.in_protect_point:
			var dp := _other(state.combat_attacker, state)
			var prot: String = (ais[dp] as BaseAI).choose_protector(state, db, dp)
			StackResolver.choose_protector(state, prot, db)
			continue
		if state.pending_strike_player != "":
			var sp := state.pending_strike_player
			var weapon: String = (ais[sp] as BaseAI).choose_strike_weapon(state, db, sp)
			StackResolver.choose_strike(state, weapon, db)
			continue
		if state.pending_death_target_player != "":
			var dtp := state.pending_death_target_player
			var dt: String = (ais[dtp] as BaseAI).choose_death_target(state, db, dtp)
			StackResolver.choose_death_target(state, dt, db)
			continue
		if state.pending_prevention_player != "":
			var pvp := state.pending_prevention_player
			var armor: String = (ais[pvp] as BaseAI).choose_prevention(state, db, pvp)
			var pv_events := StackResolver.choose_prevention(state, armor, db)
			for e in pv_events:
				if e.event_type == "game_over":
					game_over[0] = true
			continue

		# Normal priority decision.
		var pid: String = state.priority_player
		var ai := ais[pid] as BaseAI
		var action := ai.decide_action(state, db, pid)
		var events: Array[GameEvent]
		if action != null:
			events = StackResolver.submit_action(state, action, db)
		else:
			events = StackResolver.pass_priority(state, db)
		for e in events:
			if e.event_type == "game_over":
				game_over[0] = true
			elif e.event_type == "priority_window_closed":
				var adv := TurnManager.advance_phase(state, db)
				for ae in adv:
					if ae.event_type == "game_over":
						game_over[0] = true

		# Progress detection.
		var sig := _progress_sig(state)
		if sig == last_sig:
			since_progress += 1
			if since_progress > STALL_LIMIT:
				return "DEADLOCK: %d ticks without progress\n" % since_progress + _dump(state, db)
		else:
			last_sig = sig
			since_progress = 0

	return "DEADLOCK: hit MAX_TICKS_PER_GAME without game_over\n" + _dump(state, db)


# A cheap signature of "did anything meaningful change".
func _progress_sig(state: GameState) -> String:
	var parts: Array = [state.turn_number, state.phase]
	for pid in ["p1", "p2"]:
		for z in ["_hand", "_ally_row", "_resource_row", "_graveyard", "_rfg", "_deck"]:
			parts.append(state.zones[pid + z].card_ids.size())
		var ps := state.players.get(pid) as PlayerState
		if ps and ps.hero_instance_id != "":
			parts.append(state.get_card(ps.hero_instance_id).damage_taken)
	return ",".join(parts.map(func(x): return str(x)))


func _choose_on_chain(state: GameState) -> bool:
	for a in state.pending_actions:
		if (a as PendingAction).action_type == "choose_enter_play_target":
			return true
	return false


func _resolve_enter_play(state: GameState, db) -> void:
	var card_id: String = state.pending_enter_play_effect.get("card_id", "")
	var amount: int = state.pending_enter_play_effect.get("amount", 0)
	var card := state.get_card(card_id)
	if not card:
		state.pending_enter_play_effect = {}
		return
	var ctrl := card.controller
	var opp := _other(ctrl, state)
	var targets: Array[String] = []
	var ps_opp := state.players.get(opp) as PlayerState
	if ps_opp and ps_opp.hero_instance_id != "":
		var a := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": card_id, "target_id": ps_opp.hero_instance_id})
		if StackResolver.can_submit(state, a, db):
			targets.append(ps_opp.hero_instance_id)
	for ally in state.cards_in_zone(opp + "_ally_row"):
		var a := PendingAction.make("choose_enter_play_target", ctrl,
				{"source_card_id": card_id, "target_id": ally.instance_id})
		if StackResolver.can_submit(state, a, db):
			targets.append(ally.instance_id)
	if targets.is_empty():
		# Optional effect (Ghank) with no OPPOSING target — decline, never self-harm.
		if state.pending_enter_play_effect.get("optional", false):
			StackResolver.decline_enter_play_effect(state)
		return   # <-- reproduces the scene's stall path (no fizzle)
	var tid: String = targets[randi() % targets.size()]
	# Announce the target; the chain resolves via the normal alternating passes.
	StackResolver.submit_action(state, PendingAction.make("choose_enter_play_target", ctrl,
			{"source_card_id": card_id, "target_id": tid}), db)


func _other(pid: String, state: GameState) -> String:
	for p in state.players:
		if p != pid:
			return p
	return pid


func _dump(state: GameState, db) -> String:
	var s := "  turn=%d phase=%s priority=%s turn_player=%s\n" % [
		state.turn_number, state.phase, state.priority_player, state.turn_player]
	s += "  combat_atk_win=%s def_win=%s protect=%s chain=%d enter_play=%s discard=%d pet=%s\n" % [
		state.combat_attack_window, state.combat_defend_window, state.in_protect_point,
		state.pending_actions.size(), str(state.pending_enter_play_effect),
		state.pending_discard_count, state.pending_pet_sacrifice_player]
	for pid in ["p1", "p2"]:
		s += "  %s hand=%d ally=%d res=%d\n" % [pid,
			state.zones[pid + "_hand"].card_ids.size(),
			state.zones[pid + "_ally_row"].card_ids.size(),
			state.zones[pid + "_resource_row"].card_ids.size()]
	# What does the priority AI want to do right now?
	var pid2: String = state.priority_player
	var ai := GenericAI.new()
	var act := ai.decide_action(state, db, pid2)
	s += "  %s GenericAI.decide_action -> %s\n" % [pid2,
		("null (pass)" if act == null else act.action_type + " " + str(act.params))]
	return s
