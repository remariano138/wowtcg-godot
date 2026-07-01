# Autoload singleton — registered as "EventBus" in project settings.
# The only place in the project that owns the game_event signal.
#
# Rules functions never call this directly — they return Array[GameEvent]
# and the stack resolver (Phase 4) calls emit_events(). See CLAUDE.md.
extends Node

signal game_event(event: GameEvent)


func emit_events(events: Array) -> void:
	for e in events:
		game_event.emit(e)
