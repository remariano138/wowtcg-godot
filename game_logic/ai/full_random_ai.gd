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
func choose_protector(state: GameState, db, player_id: String) -> String:
	var pool: Array = StackResolver.get_legal_protectors(
		state, state.combat_attacker, state.combat_defender, db)
	pool.append("")   # skip option
	return pool[randi() % pool.size()]


func decide_action(state: GameState, db, player_id: String) -> PendingAction:
	# Don't act during ready or draw phases — pass and let the phase advance.
	if state.phase in ["ready", "draw"]:
		return null
	var legal := get_legal_actions(state, db, player_id)
	if legal.is_empty():
		_responded = false
		return null

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
