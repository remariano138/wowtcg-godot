extends RefCounted

# Reference to SandboxTable — set before calling run_turn()
var sandbox: Node

const ACTION_DELAY = 0.6  # seconds between AI actions for readability

# Picks an X value when paying a variable cost, given the maximum legal X the
# player can currently afford. Always spends the max — more value (bigger heal/
# damage/etc.) is strictly better with no other tradeoff currently modeled.
# Rough "how expensive is this power" estimate — used only to prioritise which
# power to activate first when several are affordable. Sums resource/flip cost
# tokens; "X" is estimated at cost_base (the minimum). Self-damage not counted.
static func estimate_power_cost(card: Control, recipe: Dictionary) -> int:
	var total = 0
	for token in recipe.get("cost", "").split(","):
		token = token.strip_edges()
		if token.begins_with("resources"):
			var parts = token.split(":")
			var spec = parts[1] if parts.size() > 1 else "0"
			total += card.cost_base if spec == "X" else int(spec)
		elif token.begins_with("flip") and card.card_type == "Hero":
			total += card.cost_base if card.cost_x else card.cost
	return total

static func choose_x_value(max_x: int) -> int:
	return max_x

# Picks which card to destroy out of a uniqueness-violation candidate pool
# (e.g. too many Pets in play). Tie-break order: lowest current HP (cull the
# weakened one), then cheapest cost (keep the more powerful one), then random.
static func choose_discard(candidates: Array) -> Control:
	var min_hp = candidates[0].current_health
	for c in candidates:
		min_hp = min(min_hp, c.current_health)
	var lowest_hp = candidates.filter(func(c): return c.current_health == min_hp)

	var min_cost = lowest_hp[0].cost
	for c in lowest_hp:
		min_cost = min(min_cost, c.cost)
	var cheapest = lowest_hp.filter(func(c): return c.cost == min_cost)

	return cheapest[randi() % cheapest.size()]


func run_turn(player: String) -> void:
	var tree = sandbox.get_tree()

	# ── 1. Place one hand card as a face-down resource ────────────────────────
	# Never spends a Protector or a Pet this way — both are too valuable to bury
	# face-down (Protectors are the deck's defensive core; Pets aren't always
	# Protectors but are usually otherwise valuable allies). If every remaining
	# card in hand is one of those, skip placing a resource this turn entirely
	# rather than burning a card worth keeping.
	await tree.create_timer(ACTION_DELAY).timeout
	if sandbox._game_over: return
	var hand = sandbox.game_manager.hand.filter(func(c): return c.card_owner == player)
	var resource_candidates = hand.filter(
		func(c): return not c.has_keyword("protector") and not ("Pet" in c.card_subtype))
	if hand.size() > 1 and not resource_candidates.is_empty():
		resource_candidates.shuffle()
		var res_card = resource_candidates[0]
		res_card.set_face_down(true)
		var res_row = sandbox.resource_row if player == "player_1" else sandbox.opp_resource_row
		sandbox.move_card(res_card, res_row)
		sandbox._resource_placed_this_turn[player] = true
		await tree.create_timer(ACTION_DELAY).timeout
		if sandbox._game_over: return

	# ── 2. Play most expensive affordable ally ────────────────────────────────
	var played = true
	while played:
		played = false
		hand = sandbox.game_manager.hand.filter(
			func(c): return c.card_owner == player and c.card_type == "Ally")
		if hand.is_empty():
			break
		hand.sort_custom(func(a, b): return a.cost > b.cost)  # most expensive first
		var available = sandbox.game_manager.player1_resources \
			if player == "player_1" else sandbox.game_manager.player2_resources
		for card in hand:
			if card.cost >= 0 and card.cost <= available:
				await tree.create_timer(ACTION_DELAY).timeout
				if sandbox._game_over: return
				await sandbox._play_card(card)
				if sandbox._game_over: return
				played = true
				break  # re-evaluate hand after each play

	# ── 2.5. Activate any affordable powers, most expensive first ────────────
	# Re-evaluates from scratch each loop, since activating one power (spending
	# resources, exhausting a card) can change what's still affordable/legal.
	# `_attempted_fizzle` guards against retrying a power that ran but found no
	# legal target/sacrifice and refunded its cost (committed == false) — without
	# this, such a power would stay "usable" forever and loop infinitely.
	var attempted_fizzle: Dictionary = {}
	var activated = true
	while activated:
		activated = false
		if sandbox._game_over: return
		var power_candidates: Array = []
		for c in sandbox.game_manager.board:
			if c.card_owner == player and not attempted_fizzle.get(c, false) \
					and sandbox._has_activate_power(c) and sandbox.can_use_power_reason(c) == "":
				power_candidates.append(c)
		var hero = sandbox._p1_hero if player == "player_1" else sandbox._p2_hero
		if is_instance_valid(hero) and not attempted_fizzle.get(hero, false) \
				and sandbox._has_activate_power(hero) and sandbox.can_use_power_reason(hero) == "":
			power_candidates.append(hero)
		if power_candidates.is_empty():
			break

		var best_cost = -1
		var costs: Dictionary = {}
		for c in power_candidates:
			var cost_est = estimate_power_cost(c, sandbox._get_activate_recipe(c))
			costs[c] = cost_est
			best_cost = max(best_cost, cost_est)
		var best = power_candidates.filter(func(c): return costs[c] == best_cost)
		var chosen = best[randi() % best.size()]

		await tree.create_timer(ACTION_DELAY).timeout
		if sandbox._game_over: return
		var committed = await sandbox._activate_power(chosen)
		if sandbox._game_over: return
		if not committed:
			attempted_fizzle[chosen] = true
		activated = true

	# ── 3. Attack with every ready ally ───────────────────────────────────────
	var attacked = true
	while attacked:
		attacked = false
		var ally_row = sandbox.ally_row if player == "player_1" else sandbox.opp_ally_row
		var ready_allies = ally_row.get_children().filter(
			func(c): return c.has_method("exhaust") and not c.exhausted and c.atk > 0 and sandbox.can_propose_attacker(c))
		if ready_allies.is_empty():
			break
		# Raw opposing pool (legality is attacker-dependent — e.g. Sarmoth's "can
		# attack only this" restricts some attackers but not others — so legality
		# is checked per-attacker below rather than precomputed once for everyone).
		var opp_row = sandbox.opp_ally_row if player == "player_1" else sandbox.ally_row
		var raw_targets: Array = opp_row.get_children().filter(func(c): return c.card_type == "Ally")
		var opp_hero = sandbox._p2_hero if player == "player_1" else sandbox._p1_hero
		if is_instance_valid(opp_hero):
			raw_targets.append(opp_hero)
		if raw_targets.is_empty():
			break

		# Step 3a — Lethal check: if the sum of all ready attackers that can
		# legally target the enemy hero reaches or exceeds the hero's current HP,
		# commit them all to the face immediately (highest ATK first to secure
		# lethal as early as possible). The game_over guard after each combat
		# handles the hero dying mid-sequence.
		if is_instance_valid(opp_hero):
			var hero_attackers = ready_allies.filter(func(a): return sandbox._is_valid_target(opp_hero, a))
			var total_dmg = 0
			for a in hero_attackers:
				total_dmg += a.atk + sandbox._get_combat_atk_bonus(a, opp_hero)
			if total_dmg >= opp_hero.current_health:
				hero_attackers.sort_custom(func(a, b):
					return (a.atk + sandbox._get_combat_atk_bonus(a, opp_hero)) > \
					       (b.atk + sandbox._get_combat_atk_bonus(b, opp_hero)))
				for a in hero_attackers:
					await tree.create_timer(ACTION_DELAY).timeout
					if sandbox._game_over: return
					await sandbox._resolve_combat(a, opp_hero)
					if sandbox._game_over: return
				attacked = true
				continue

		# Step 3c — Safe-kill: an attacker that defeats its target without dying
		# itself. Among all such options, use the attacker with the most current HP.
		var attacker: Control = null
		var defender: Control = null
		var best_attacker_hp = -1
		for a in ready_allies:
			var legal_targets = raw_targets.filter(func(t): return sandbox._is_valid_target(t, a))
			for t in legal_targets:
				var kills    = a.atk >= t.current_health
				var survives = a.current_health > t.atk
				if kills and survives and a.current_health > best_attacker_hp:
					best_attacker_hp = a.current_health
					attacker = a
					defender = t

		if not attacker:
			var fallback_attackers = ready_allies.filter(
				func(a): return not raw_targets.filter(func(t): return sandbox._is_valid_target(t, a)).is_empty())
			if fallback_attackers.is_empty():
				break
			fallback_attackers.shuffle()
			attacker = fallback_attackers[0]
			var legal_targets = raw_targets.filter(func(t): return sandbox._is_valid_target(t, attacker))
			legal_targets.shuffle()
			defender = legal_targets[0]

		await tree.create_timer(ACTION_DELAY).timeout
		if sandbox._game_over: return
		await sandbox._resolve_combat(attacker, defender)
		if sandbox._game_over: return
		attacked = true

	# ── 4. End turn ────────────────────────────────────────────────────────────
	await tree.create_timer(ACTION_DELAY).timeout
	if sandbox._game_over: return
	sandbox._on_end_turn_pressed()
