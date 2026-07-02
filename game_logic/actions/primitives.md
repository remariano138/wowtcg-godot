# Primitives — `game_logic/actions/primitives.gd`

These are the atomic rules functions that mutate `GameState`. Every primitive:

- Takes a `GameState` (mutated in place) plus action-specific arguments
- Returns `Array[GameEvent]` describing what changed — the caller emits them
- Never touches Godot nodes, autoloads, or the event bus
- Calls other primitives internally and folds their events in with `append_array`

---

## `move_card(state, card_id, to_zone_id)`

Moves a card from its current zone to another. **All zone changes must go through here** — never mutate `zone.card_ids` or `card.zone_id` directly.

- Handles attachment cleanup: if the card was attached to a host, removes it from that host's attachment list
- On graveyard entry: clears `is_exhausted` and `damage_taken` so the card starts fresh if it re-enters play
- Emits: `card_moved`, optionally `card_readied` (on graveyard entry)

## `move_card_silent(state, card_id, to_zone_id)`

Same zone bookkeeping as `move_card` but emits **no events**. Used at setup time (initial hand deal, hero placement) where the renderer handles visuals separately.

---

## `deal_damage(state, source_id, target_id, amount, db)`

Applies damage to an in-play card. **Does not destroy the card** — call `check_destroyed` separately after all damage has been applied.

- Excess damage beyond lethal is discarded (rule 405.3)
- Only works on cards currently in play
- Emits: `damage_dealt`, `hp_changed`

## `check_destroyed(state, card_id, source_id="", db=null)`

State-based destruction check: if the card is in play with HP ≤ 0, destroys it and moves it to the graveyard. Returns `[]` if the card is alive or not in play — safe to call unconditionally.

Heroes are a special case: their death triggers `game_over` (handled at the resolver level) and they do **not** move to the graveyard. `check_destroyed` returns `[]` for heroes — the resolver emits `game_over` directly.

- Emits: `card_destroyed`, `card_moved` (for non-heroes only)

> **Why separate?** Combat requires true simultaneity — both combatants deal damage before either fatality is checked. Keeping damage and destruction as distinct steps means `deal_damage` can be called for both sides first, then `check_destroyed` on each afterward. The stack resolver handles this sequencing.

---

## `heal(state, target_id, amount, db)`

Removes damage from an in-play card, capped at its max HP. No-op if the card is already at full health or not in play.

- Emits: `hp_changed` (only if HP actually changed)

---

## `exhaust_card(state, card_id)`

Exhausts a ready in-play card. No-op if already exhausted or not in play.

- Emits: `card_exhausted`

## `ready_card(state, card_id)`

Readies an exhausted in-play card. No-op if already ready or not in play.

- Emits: `card_readied`

---

## `destroy_card(state, card_id, source_id="")`

Destroys an in-play card without dealing damage (rule 415.9d). Use this for effects that say "destroy target ally/equipment/ability". Cards that die from damage use `deal_damage` instead.

- Emits: `card_destroyed`, `card_moved` (to graveyard)

---

## `discard_card(state, card_id)`

Discards a card from hand to its owner's graveyard (rule 415.9e). Only works on cards currently in hand.

- Briefly reveals the card to both players before it goes to the graveyard
- Emits: `card_revealed`, `card_moved`

---

## `add_buff(state, target_id, buff)`

Attaches a `Buff` object to a card's `active_buffs` list. Buffs modify derived stats (ATK, HP) and are read by `GameState.get_atk()` / `get_max_hp()`.

- Emits: `buff_added`

## `remove_buffs_from_source(state, target_id, source_id)`

Removes all buffs on a card that originated from a specific source. Used when the source leaves play (e.g. an aura-granting ally dies).

- Emits: `buff_removed` (once per buff removed)

---

## `set_counter(state, card_id, counter_name, new_value)`

Sets a named integer counter on a card. Setting to 0 removes the counter entirely. Callers are responsible for any follow-up logic (e.g. destroying a card when its quest counter reaches 0).

- Emits: `counter_changed`
