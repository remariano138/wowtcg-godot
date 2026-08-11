# Turn-scoped state: flags and the turn event log

Every piece of per-turn state the engine carries, why it exists, and how
turn-*history* conditions are answered.

---

## Category A — turn-history conditions → `GameState.turn_events`

Cards whose condition asks about *what happened this turn* rather than about
current board state. These used to be one ad-hoc boolean per card
(`damage_dealt_this_turn`, `hero_damaged_by_ally_this_turn`); they are now all
answered from a single structured record, **the turn event log**:

```
GameState.turn_events: Array[Dictionary]   # cleared at every turn start, serialized
GameState.record(type, data)               # the ONE append helper
GameState.has_turn_event(type) / turn_events_of(type)
```

### Rules of the log

1. **Primitives append, at the moment the fact becomes true** — co-located with
   the matching `GameEvent` construction (e.g. `deal_damage` records
   `damage_dealt` exactly where it builds the event), NOT at event-bus emission.
   Rules functions return events and the caller emits, so a condition read
   mid-resolution would miss bus-level entries from its own chain.
2. **Entries snapshot facts at write time.** Payload ids are references — by
   read time the source may be in a graveyard (zone lookup fails) or under new
   control (Infernal). A condition like Torek's "by an ally in your party" must
   be judged at the moment the damage landed, so the entry carries
   `source_is_ally` / `source_controller` as booleans and strings frozen then.
   Test `sc26c-d2` pins this (the ally dies; the quest stays completable).
3. **Recorded unconditionally, in every game.** Turn-history conditions are
   retroactive: a Thysta entering play mid-turn must see damage dealt *before*
   she arrived, and damage that killed an ally leaves no board trace to
   reconstruct. This is the property that separates Category A from the
   categories below, and why recording can't be gated on the reader being in
   play. (Gating on *deck membership* — scan both deck lists + `tokens.csv` at
   setup for recipes that read the log — WOULD be sound, since decks are fixed
   at game start; it's not done because the current per-damage cost is one
   small dictionary append. Revisit if the log grows high-frequency entry
   types.)
4. **Cleared in `TurnManager._enter_ready`** — "this turn" simply means "in the
   log" — and serialized in `GameState.to_dict`/`from_dict` (bounded: one turn's
   worth).
5. **Only record what a rules condition reads.** The display log
   (playtest.gd `_log_event`) is a separate, renderer-side formatting of bus
   events; migrating it to read `turn_events` (with user filters) is a planned
   follow-up, at which point more entry types get recorded. Until a consumer
   exists, an entry type is dead weight in every serialization.
6. **Entry payload keys are a rules contract.** Renaming a key silently breaks
   a card condition, not just a log line. Document every type here.

### Recorded entry types

| Type | Written in | Snapshot fields | Read by |
|---|---|---|---|
| `damage_dealt` | `GameLogic.deal_damage` — AFTER prevention (717.2b: fully absorbed damage was never dealt) and AFTER the 405.3 excess guard (a packet at an already-0-HP target places nothing) | `source_id`, `target_id`, `amount`, `source_controller`, `target_controller`, `source_is_ally`, `target_is_hero` | Thysta Spiritlasher (`dark_portal_236`): any entry this turn → she stays silent (`TurnManager._apply_each_turn_end_effects`). Torek's Assault (`azeroth_345`): entry with `target_is_hero` ∧ `source_is_ally` ∧ `source_controller` = completer ∧ `target_controller` ≠ completer (`StackResolver.can_submit` quest gate). Cold Blood (`azeroth_92`): entry with `source_id` = the granting player's hero ∧ target still an ally in play → destroy it (`StackResolver._fire_cold_blood`) |

`put_damage` (405.3 self-damage costs) deliberately does not record — self-costs
are not "damage dealt", the same call made for Berserking's counters.

### Adding a turn-history condition

1. Check the table above — an existing entry type may already carry what the
   condition needs. That is the point of the log: Torek's condition is a
   filtered scan of the same entries Thysta counts.
2. If a new type (or new snapshot field) is needed: record it in the relevant
   primitive, co-located with the matching `GameEvent` construction; snapshot
   any fact the condition judges (rule 2 above); add it to the table.
3. Read via `has_turn_event` / `turn_events_of` at the condition site. Never
   re-derive a snapshot fact from an id at read time.
4. Do NOT add a per-card boolean flag for turn history — that is the pattern
   this log replaced.

---

## Category B — once-per-turn action gates

The card's own action is the thing being recorded, so these are self-evident at
the read site and carry no hidden coupling. Not log candidates.

| Flag | Lives on | Meaning |
|---|---|---|
| `resource_placed_this_turn` | `PlayerState` | One resource per turn (turn player only) |
| `used_this_turn` | `CardInstance` | Once-per-turn gate for non-exhaust powers (Deacon Johanna) |
| `attacked_this_turn` (counter) | `CardInstance` | "attacks for the first time each turn" (Windseer Tarus, Windfury Totem) |
| `windfury_struck_this_turn` (counter) | `CardInstance` | "strike with attached weapon for the first time each turn" (Windfury Weapon) |

`has_used_hero_power` looks like this group but is **not** reset — flipping a
hero is permanent.

---

## Category C — expiring grants

Written by the granting card itself and read as a modifier; cleared at turn
start for the same reason `CardInstance.decrement_turn_buffs` sweeps at end of
turn. Not log candidates — they're state, not history.

| Field | Lives on | Card |
|---|---|---|
| `party_atk_buffs_this_turn` | `PlayerState` | Rayder, For the Horde! |
| `melee_strike_discount` | `PlayerState` | Gorebelly |
| `ranged_weapon_atk_bonus` | `PlayerState` | Elendril |
| `rapid_fire_ready_cost` | `PlayerState` | Rapid Fire |
| `cold_blood_from_index` | `PlayerState` | Cold Blood — an INDEX into `turn_events` (Category A is where the effect's facts live); makes the trigger forward-looking |
| `damage_prevention` | `PlayerState` | Armor pool (safety clear — scoped to its combat) |
| `gouge_skip_ready` (counter) | `CardInstance` | Gouge, Iceblade Hacker — consumed at the ready step rather than cleared |
