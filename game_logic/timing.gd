class_name GameTiming
extends RefCounted

# Central place for every "pause so a human can register what happened" delay
# AND for every card animation duration (see GameTiming.anim, used by the
# renderer instead of hardcoded tween lengths).
# Base durations are tuned at animation_speed = 1.0; move animation_speed to
# speed up/slow down every pause and animation uniformly (0.0 = instant, for
# headless tests; 2.0 = twice as slow, for a demo).
static var animation_speed: float = 1.0

# Global slowdown applied on top of animation_speed. Every printed base duration
# below — and every renderer tween routed through anim() — is multiplied by this,
# so the whole game animates at a third of its original pace at speed 1.0.
const DURATION_SCALE := 3.0

# Scale a renderer animation duration (tween length, or a timer that must stay in
# step with one). The ONE place a card animation's length is decided, so the speed
# slider moves tweens and pauses together.
static func anim(seconds: float) -> float:
	return seconds * DURATION_SCALE * animation_speed

const DEATH_ANIMATION  := 1.0   # red overlay fade after a card is destroyed
const HEAL_ANIMATION   := 0.5   # green overlay fade after a card is healed
const DAMAGE_PAUSE     := 0.5   # pause after damage is dealt (once per resolved action)
const CHAIN_PAUSE      := 1.0   # pause while a played card sits on the chain
const RESOLUTION_DELAY := 0.1   # pause after combat/an AI chain play, before the next turn is scheduled (near-instant: the UI now shows what happened, so this only has to break the call stack)

static func death_animation() -> float:
	return anim(DEATH_ANIMATION)

static func heal_animation() -> float:
	return anim(HEAL_ANIMATION)

static func damage_pause() -> float:
	return anim(DAMAGE_PAUSE)

static func chain_pause() -> float:
	return anim(CHAIN_PAUSE)

static func resolution_delay() -> float:
	return anim(RESOLUTION_DELAY)
