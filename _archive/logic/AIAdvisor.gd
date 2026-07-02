class_name AIAdvisor
extends RefCounted

# Shared power-advisory utilities for all AI implementations.
#
# Any AI can call these to understand what a power does and how much value it
# has given the current board state. The advisor returns facts and estimates;
# it never makes decisions. Each AI applies its own heuristic to the results
# (e.g. BasicAI uses a greedy "most cost first" filter; a future conservative
# AI might only activate a heal when its hero is below 50% HP).

# ── Action metadata ───────────────────────────────────────────────────────────
# Maps each recipe action name to a broad category. Any AI can use this to
# branch on what a power does without re-parsing the recipe itself.
# Category meanings:
#   "heal"             — restores HP to one or more friendly characters
#   "damage"           — deals damage to one or more characters
#   "draw"             — draws cards for the activating player
#   "discard_opponent" — forces the opponent to discard
#   "ready"            — readies an exhausted card
#   "sacrifice"        — destroys a friendly card as a cost for an effect
#                        (the effect itself may be in another category — these
#                        are combination powers; treat the category as the cost
#                        side for value estimation)
# Unknown/unlisted actions fall back to "unknown" — advisors return a small
# positive value so new cards are tried rather than silently skipped.
const ACTION_META: Dictionary = {
	"heal_target":                   {"category": "heal"},
	"heal_self":                     {"category": "heal"},
	"heal_all_own_party":            {"category": "heal"},
	"deal_damage":                   {"category": "damage"},
	"sacrifice_deal_damage":         {"category": "damage"},
	"deal_damage_self_cost":         {"category": "damage"},
	"destroy_target":                {"category": "damage"},
	"draw_card":                     {"category": "draw"},
	"sacrifice_draw_card":           {"category": "draw"},
	"target_player_discards":        {"category": "discard_opponent"},
	"defender_controller_discards":  {"category": "discard_opponent"},
	"ready_self":                    {"category": "ready"},
}

# Returns the category string for a recipe's action, or "unknown" if not listed.
static func action_category(recipe: Dictionary) -> String:
	return ACTION_META.get(recipe.get("action", ""), {}).get("category", "unknown")

# ── Value estimation ──────────────────────────────────────────────────────────
# Returns an integer "how useful is activating this power RIGHT NOW" score.
#   0  — no value; skip (e.g. healing when nobody is damaged).
#   >0 — some value; magnitude roughly reflects how much benefit to expect.
#
# These numbers are intentionally simple and comparable across categories
# so any AI can use them as a raw filter (>0 = worth trying) or as part of
# a more nuanced priority calculation.
static func estimate_power_value(card: Control, recipe: Dictionary, sandbox: Node) -> int:
	match action_category(recipe):
		"heal":
			# Value = max damage on any healable target on the activating side.
			# 0 if everyone is at full HP — no point spending resources on a no-op.
			var candidates = sandbox._heroes_and_allies_scoped(recipe.get("target_scope", "any"))
			var own = candidates.filter(func(c): return c.card_owner == card.card_owner)
			var pool = own if not own.is_empty() else candidates
			var max_dmg = 0
			for c in pool:
				max_dmg = max(max_dmg, c.damage_taken)
			return max_dmg

		"damage":
			# Value = number of legal targets on the opposing side.
			# 0 only if the opponent has zero characters in play (very rare).
			var opp_row = sandbox.opp_ally_row if card.card_owner == "player_1" \
				else sandbox.ally_row
			var count = opp_row.get_children().filter(
				func(c): return c.card_type == "Ally" and not c.face_down).size()
			var opp_hero = sandbox._p2_hero if card.card_owner == "player_1" \
				else sandbox._p1_hero
			if is_instance_valid(opp_hero):
				count += 1
			return count

		"draw":
			# Drawing is almost always good — value is constant 1.
			return 1

		"discard_opponent":
			# Value = opponent's current hand size. 0 if their hand is empty.
			var opponent = "player_2" if card.card_owner == "player_1" else "player_1"
			return sandbox.game_manager.hand.filter(
				func(c): return c.card_owner == opponent).size()

		"ready":
			# Value = 1 if this card is actually exhausted (readying a ready card
			# does nothing); 0 otherwise.
			return 1 if card.exhausted else 0

		_:
			# Unknown action — be optimistic: let the power try and rely on the
			# fizzle-and-refund system to handle genuine no-ops at runtime.
			return 1

# ── Cost estimation ───────────────────────────────────────────────────────────
# Rough "how expensive is this power" estimate — used to prioritise which power
# to activate first when several are available and affordable. Sums resource and
# flip-token costs; "X" specs are estimated at cost_base (the minimum), since
# the real X isn't chosen until payment time. Self-damage costs don't count as
# a resource expenditure.
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
