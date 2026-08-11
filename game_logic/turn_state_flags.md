# Turn-scoped state: the flag registry

Every piece of per-turn state the engine carries, why it exists, and — for the
ones that cost something to maintain — what would let us stop maintaining them.

The reason this file exists: **turn-history flags are written by code that has no
idea the reading card exists.** `GameLogic.deal_damage` doesn't know about Thysta
Spiritlasher; it just records that damage happened. That decoupling is what makes
them correct, and also what makes them easy to accumulate one at a time without
anyone noticing the set is growing. Listing them here is the prerequisite for
ever consolidating them.

---

## Category A — turn-history flags

**The ones that matter for consolidation.** Written by an unrelated subsystem
when some event happens, read later by one card's condition. They record
something about *what happened this turn* that is not otherwise recoverable from
board state.

| Flag | Lives on | Written | Read by | Card |
|---|---|---|---|---|
| `hero_damaged_by_ally_this_turn` | `PlayerState` | `GameLogic.deal_damage` — target is a player's hero, source is an ally_row card of another controller | `StackResolver.can_submit` (`quest_requires_hero_damaged_by_ally`) | Torek's Assault (`azeroth_345`) |
| `damage_dealt_this_turn` | `GameState` | `GameLogic.deal_damage` — any damage that lands | `TurnManager._apply_each_turn_end_effects` | Thysta Spiritlasher (`dark_portal_236`) |

Both are reset in `TurnManager._enter_ready`.

### Why these can't be computed on demand

They are **retroactive**: the reading card can arrive *after* the event it asks
about. A Thysta played on turn 6 must still see damage dealt earlier on turn 6,
and damage that killed an ally leaves no trace anywhere — the ally is in a
graveyard with its damage reset (400.6a). There is nothing to reconstruct from.
This is the property that separates Category A from everything below, and the
reason the write can't be conditional on the reader being present.

### The consolidation that's already visible

These two are **not independent** — they are written in the same block of
`deal_damage`, from the same event, and Torek's is a strict refinement of
Thysta's: "damage was dealt" *plus* "the target was a hero" *plus* "the source
was an opposing ally". A single structured record of the turn's damage would
subsume both:

```
# sketch, not implemented
state.turn_damage_log: Array[{source, target, target_is_hero, source_zone, controller_delta, amount}]
```

Thysta becomes `log.is_empty()`; Torek becomes a filtered scan. Any future card
along the lines of "if you dealt damage to three different characters this turn"
or "if your hero took no damage this turn" then costs zero new flags.

**Worth doing when a third such card lands, not before.** Two entries don't pay
for the indirection, and the log form is strictly more expensive per damage event
than a bool write (an allocation instead of an assignment) — see the deck-gate
note below for when that starts to matter.

---

## Category B — once-per-turn action gates

The card's own action is the thing being recorded, so these are self-evident at
the read site and carry no hidden coupling. Not consolidation candidates.

| Flag | Lives on | Meaning |
|---|---|---|
| `resource_placed_this_turn` | `PlayerState` | One resource per turn (turn player only) |
| `used_this_turn` | `CardInstance` | Once-per-turn gate for non-exhaust powers (Deacon Johanna) |
| `attacked_this_turn` (counter) | `CardInstance` | "attacks for the first time each turn" (Windseer Tarus, Windfury Totem) |
| `windfury_struck_this_turn` (counter) | `CardInstance` | "strike with attached weapon for the first time each turn" (Windfury Weapon) |

`has_used_hero_power` looks like this group but is **not** reset — flipping a hero
is permanent.

---

## Category C — expiring grants

Written by the granting card itself and read as a modifier. These are buffs that
happen to live on `PlayerState` rather than on a `CardInstance`, usually because
they must also apply to cards that enter play later in the turn. Cleared at turn
start for the same reason `CardInstance.decrement_turn_buffs` sweeps at end of
turn. Not consolidation candidates — they're already the consolidated form.

| Field | Lives on | Card |
|---|---|---|
| `party_atk_buffs_this_turn` | `PlayerState` | Rayder, For the Horde! |
| `melee_strike_discount` | `PlayerState` | Gorebelly |
| `ranged_weapon_atk_bonus` | `PlayerState` | Elendril |
| `rapid_fire_ready_cost` | `PlayerState` | Rapid Fire |
| `damage_prevention` | `PlayerState` | Armor pool (safety clear — scoped to its combat) |
| `gouge_skip_ready` (counter) | `CardInstance` | Gouge, Iceblade Hacker — consumed at the ready step rather than cleared |

---

## Adding a Category A flag

1. Declare it on `GameState` (game-global) or `PlayerState` (per-player), with a
   comment naming the card and stating *when* it is written relative to
   prevention.
2. Write it in the relevant primitive — for damage, `GameLogic.deal_damage`
   **after** `prevent`, so damage absorbed in full doesn't count (717.2b).
   `put_damage` (405.3 self-damage costs) is a separate primitive and should not
   set damage flags.
3. Reset it in `TurnManager._enter_ready`.
4. Serialize it in `GameState.to_dict` / `from_dict` if it spans a whole turn.
5. Add a row to the Category A table above.
