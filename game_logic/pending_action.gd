class_name PendingAction
extends Resource

# A proposed-but-not-yet-resolved action on the chain (rule 409/410).
# Created by submit_action callers (human input or AI) and held in
# GameState.pending_actions until the chain resolves it.
#
# action_type strings (add as resolvers are implemented):
#   "play_ally"      — play an ally card from hand to ally row
#   "play_instant"   — play an instant ability (can be played any priority window)
#   "activate_power" — activate a card's active power
#
# params keys vary by action_type — see StackResolver.can_submit / _resolve.

var action_type: String
var source_player: String
var params: Dictionary = {}


static func make(p_type: String, p_player: String,
		p_params: Dictionary = {}) -> PendingAction:
	var a := PendingAction.new()
	a.action_type   = p_type
	a.source_player = p_player
	a.params        = p_params
	return a


func to_dict() -> Dictionary:
	return {
		"action_type":   action_type,
		"source_player": source_player,
		"params":        params.duplicate(),
	}

static func from_dict(d: Dictionary) -> PendingAction:
	return PendingAction.make(
		d.get("action_type",   ""),
		d.get("source_player", ""),
		d.get("params",        {}),
	)
