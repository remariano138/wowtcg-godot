# Autoload singleton — registered as "EventBus" in project settings.
# The only place in the project that owns the game_event signal.
#
# Rules functions never call this directly — they return Array[GameEvent]
# and the stack resolver (Phase 4) calls emit_events(). See CLAUDE.md.
extends Node

signal game_event(event: GameEvent)


func emit_events(events: Array) -> void:
	# Pace the simulation so a human can register what just happened — one pause
	# per resolved action (not per individual event), taking the longest pause
	# any single event in this batch calls for. See game_logic/timing.gd.
	var pause := 0.0
	for e in events:
		game_event.emit(e)
		if e.event_type == "card_destroyed":
			pause = max(pause, GameTiming.death_animation())
		elif e.event_type == "card_moved" and e.payload.get("to", "") == "chain":
			pause = max(pause, GameTiming.chain_pause())
		elif e.event_type == "damage_dealt":
			pause = max(pause, GameTiming.damage_pause())
	if pause > 0.0:
		await get_tree().create_timer(pause).timeout
