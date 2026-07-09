class_name GameTiming
extends RefCounted

# Central place for every "pause so a human can register what happened" delay.
# Base durations are tuned at animation_speed = 1.0; bump animation_speed to
# speed up/slow down every pause and animation uniformly (e.g. 0.0 for
# headless tests, 2.0 to slow things down for a demo).
static var animation_speed: float = 1.0

const DEATH_ANIMATION  := 1.0   # red overlay fade after a card is destroyed
const HEAL_ANIMATION   := 0.5   # green overlay fade after a card is healed
const DAMAGE_PAUSE     := 0.5   # pause after damage is dealt (once per resolved action)
const CHAIN_PAUSE      := 1.0   # pause while a played card sits on the chain
const RESOLUTION_DELAY := 0.2   # pause after combat/an AI chain play, before the next turn is scheduled

static func death_animation() -> float:
	return DEATH_ANIMATION * animation_speed

static func heal_animation() -> float:
	return HEAL_ANIMATION * animation_speed

static func damage_pause() -> float:
	return DAMAGE_PAUSE * animation_speed

static func chain_pause() -> float:
	return CHAIN_PAUSE * animation_speed

static func resolution_delay() -> float:
	return RESOLUTION_DELAY * animation_speed
