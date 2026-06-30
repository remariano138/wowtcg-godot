class_name BasicAI
extends RefCounted

# Reference to SandboxTable — set before calling run_turn()
var sandbox: Node

const ACTION_DELAY = 0.6  # seconds between AI actions for readability

func run_turn(player: String) -> void:
	var tree = sandbox.get_tree()

	# ── 1. Place one random hand card as a face-down resource ────────────────
	await tree.create_timer(ACTION_DELAY).timeout
	if sandbox._game_over: return
	var hand = sandbox.game_manager.hand.filter(func(c): return c.card_owner == player)
	if not hand.is_empty():
		hand.shuffle()
		var res_card = hand[0]
		res_card.set_face_down(true)
		var res_row = sandbox.resource_row if player == "player_1" else sandbox.opp_resource_row
		sandbox.move_card(res_card, res_row)
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
				sandbox._play_card(card)
				played = true
				break  # re-evaluate hand after each play

	# ── 3. Attack with every ready ally ───────────────────────────────────────
	var attacked = true
	while attacked:
		attacked = false
		var ally_row = sandbox.ally_row if player == "player_1" else sandbox.opp_ally_row
		var ready_allies = ally_row.get_children().filter(
			func(c): return c.has_method("exhaust") and not c.exhausted and not c.just_summoned)
		if ready_allies.is_empty():
			break
		# Find all valid targets
		var targets = sandbox.game_manager.board.filter(
			func(c): return sandbox._is_valid_target(c, player))
		# Also include the opponent hero
		var opp_hero = sandbox._p2_hero if player == "player_1" else sandbox._p1_hero
		if is_instance_valid(opp_hero):
			targets.append(opp_hero)
		if targets.is_empty():
			break
		targets.shuffle()
		var attacker = ready_allies[0]
		var defender = targets[0]
		await tree.create_timer(ACTION_DELAY).timeout
		if sandbox._game_over: return
		await sandbox._resolve_combat(attacker, defender)
		if sandbox._game_over: return
		attacked = true

	# ── 4. End turn ────────────────────────────────────────────────────────────
	await tree.create_timer(ACTION_DELAY).timeout
	if sandbox._game_over: return
	sandbox._on_end_turn_pressed()
