# Project context

This is a digital implementation of a simplified WoW TCG ruleset.
Always check `References/wow_rules.txt` before implementing any
keyword or card effect — do not rely on general CCG knowledge (Magic,
Hearthstone) since WoW TCG has its own specific rulings.

Card data lives in: `data/cards.csv`
Active playtest scene: `renderer/tests/playtest.gd` (human vs AI, full UI)
Engine lives in: `game_logic/` — see Architecture section below.
The old `scenes/boards/SandboxTable.gd` / `DuelTable.gd` are legacy, ignore them.

---

## Implementing a card — required steps

1. Find the card in `data/cards.csv` (grep by name). Read the card image to get exact card text.
2. **Confirm the card text with the user before writing any code.** Also check `References/wow_rules.txt` for any keywords or mechanics.
3. Implement: engine actions in `game_logic/stack_resolver.gd`, AI heuristics in `game_logic/ai/base_ai.gd` if needed, add to relevant deck in `renderer/tests/playtest.gd`.
4. Write headless test scenarios in `game_logic/tests/test_scenarios.gd` covering the new mechanic. User runs these to verify correctness before finalizing.
5. Update `data/cards.csv`: set `data_status=verified`, `engine_status=implemented`, fill `power_text` and `effects` recipe. Do this last, after tests pass.

---

## Architecture (game_logic/)

### Core invariants — violating these is a bug:

- **Rules functions never touch the bus.** They return `Array[GameEvent]`. The caller emits.
- **Rules functions never read Godot nodes.** No `get_tree()`, no autoloads, no scene refs. Pass `db` when def lookups are needed.
- **Zone moves go through `GameLogic.move_card()` only.** Never mutate `zone.card_ids` or `card.zone_id` directly.
- **Derived stats are never cached on CardInstance.** Call `state.get_atk(id, db)` etc. Caching causes stale-read bugs.
- **Fold inner events:** `events.append_array(inner_call(...))`.

### Key files:

| File | Role |
|---|---|
| `game_logic/state/game_state.gd` | Single source of truth. All mutable game data. |
| `game_logic/state/player_state.gd` | Per-player flags (resources, pet_capacity, hero_instance_id…) |
| `game_logic/state/card_instance.gd` | Runtime card state (zone, damage, keywords, buffs…) |
| `game_logic/stack_resolver.gd` | ALL rules validation (`can_submit`) and resolution (`_resolve_*`). Priority/chain logic. |
| `game_logic/turn_manager.gd` | Phase advancement, turn start (ready all, clear summoning sickness). |
| `game_logic/game_logic.gd` | Low-level helpers: `move_card`, `deal_damage`, `exhaust_card`, `heal`. |
| `game_logic/events/game_event.gd` | Event constructors. Add typed constructors for every new event. |
| `game_logic/ai/base_ai.gd` | AI action selection — `get_all_legal_actions` → scored → best chosen. |
| `renderer/board_renderer.gd` | Visual layer: card nodes, highlights, animations. No rules logic. |
| `renderer/tests/playtest.gd` | The running playtest scene. Wires everything together. AI + human. |
| `input/input_router.gd` | Human input → PendingAction. The only place that calls `submit_action` for humans. |

### Priority / chain flow (rule 410):

```
submit_action(state, action, db) → pushes to pending_actions, proposer keeps priority
pass_priority(state, db)         → consecutive_passes++; at 2: resolve top OR close window
```

**When both players pass with chain empty:**
- If `combat_attack_window` → `_close_attack_window` (protect point → defend window)
- If `combat_defend_window` → `_do_combat_conclusion` (damage)
- If `pending_enter_play_effect` non-empty → stall (scene must handle)
- Otherwise → emit `priority_window_closed` → `TurnManager` advances phase

### Mandatory immediate-resolution choices (bypass pending_actions):

Some choices must resolve without going through the stack:
- `StackResolver.choose_discard(state, card_id, db)` — pending discard
- `StackResolver.choose_pet_sacrifice(state, card_id, db)` — pet uniqueness violation

These are called directly (not via `submit_action`). The blocking guard in `can_submit` prevents anything else while they're pending.

### Combat step flow (rule 602):

```
propose_combat resolves →
  attacker exhausts + combat_started event
  combat_attack_window = true → attack_window_opened event
    [both players get priority — can use instants, ally powers, etc.]
  both pass → _close_attack_window →
    protect point (if protectors exist) OR
    combat_defend_window = true → defend_window_opened event
      [both players get priority again]
    both pass → _do_combat_conclusion → damage → combat_concluded
```

**Ally activated powers** (e.g. Grimdron) are legal during attack/defend windows even for the non-turn player — `_can_use_ally_power` only requires `priority_player == source_player` (no `turn_player` restriction), because "use only on your turn" is an explicit card-text restriction, not the default.

---

## Card data format (data/cards.csv columns)

```
set_id, card_num, name, cost, card_type, faction, class_restriction, card_subtype,
subtype_detail, printed_atk, dmg_type, printed_health, rarity, keywords,
power_text, data_status, engine_status, effects, image_path
```

**`effects` string** — pipe-separated segments, each colon-separated:

| Segment | Meaning |
|---|---|
| `activated_power:COST:EFFECT:AMOUNT:DMG_TYPE:TARGETS` | Ally activated power |
| `on_enter:EFFECT:AMOUNT:DMG_TYPE` | Enter-play triggered effect |
| `destroy_target:ally` | Destroy a target ally (Vanquish-style) |
| `sarmoth_taunt` | Opposing characters that can attack this must attack only this |
| `elusive` | (keyword in keywords col, not effects) — can't be chosen as defender |
| `protector` | (keyword) — can intercept attacks |
| `ferocity` | (keyword) — no summoning sickness |
| `stealth` | (keyword) — can only attack heroes |
| `ranged` | (keyword) — long-range, defender can't deal combat damage back |

**`data_status`**: `verified` = card text confirmed from image  
**`engine_status`**: `implemented` = effects string is live in engine

---

## Card uniqueness

WoW TCG allies are **NOT unique** by default. Do not assume uniqueness unless the card text says so or the card is a **Pet** (Pet uniqueness is enforced separately).

**Pet uniqueness (rule 414.3b):** A player may control at most `PlayerState.pet_capacity` pets (default 1) in their ally_row simultaneously. When a second Pet enters play, `_check_pet_uniqueness` fires immediately (non-interruptible), setting `pending_pet_sacrifice_player` and emitting `pet_sacrifice_required`. The player must call `StackResolver.choose_pet_sacrifice()` directly (not via `submit_action`).

Pet capacity is a player attribute (`PlayerState.pet_capacity`, default 1) that card effects can increase.

---

## Highlight color conventions (input_router.gd → board_renderer.gd)

- **Green** (`Color(0.2, 1.0, 0.3)`) — default, normal playable cards / targeting
- **Red** (`Color(1.0, 0.25, 0.25)`) — mandatory choice: discard (`start_discard_mode`) or pet sacrifice (`start_pet_sacrifice_mode`)

`refresh_highlights()` emits `highlights_updated(ids, color)`. The color is stored as `_highlight_color` in `InputRouter` and reset to green when the mandatory mode ends.

---

## AI conventions (game_logic/ai/base_ai.gd)

- `get_all_legal_actions` only returns actions for the **turn player** (non-turn player returns empty — AI passes during opponent's priority windows, including combat windows).
- **Targeting rules:** AI always targets **opponents only**. Never self-target for damage/destroy effects. This applies to:
  - `_targeted_instant_actions` (Vanquish, etc.) — only `opp + "_ally_row"` and opp hero
  - `_handle_enter_play_target` in `playtest.gd` — same: `opp` only
  - `_get_ally_power_actions` — already enemy-only
- `_destroy_is_worth_it(state, db, player_id, target_id, spell_cost)` — AI only plays destroy spells when target cost ≥ spell cost AND no friendly ally can solo-kill the target in combat.

---

## Decks in playtest.gd

| Constant | Hero | Notes |
|---|---|---|
| `DECK_ALLIANCE_DIZDEMONA` | Dizdemona (azeroth_2, Alliance Warlock) | Uses `dizdemona_cards`: 2× Grimdron, 2× Sarmoth, Freya Lightsworn ×2, Bloodclaw ×4, Mias ×4, Latro Abiectus ×8, Kor Cindervein ×8, Crazy Igvand ×4, Vanquish ×4 |
| `DECK_HORDE_TAZO` | Ta'zo (azeroth_15, Horde Mage) | Uses `horde_cards` incl. Taz'dingo ×4 |
| `DECK_HORDE_GRENNAN` | Grennan Stormspeaker (azeroth_10) | Uses `horde_cards` |
| `DECK_HORDE_OMEDUS` | Omedus the Punisher (azeroth_12) | Uses `omedus_cards` |
| `DECK_ALLIANCE_TIMMO` | Timmo Shadestep (azeroth_7) | Uses `alliance_cards` |
| `DECK_ALLIANCE_MOONSHADOW` | Commander Moonshadow (azeroth_6) | Uses `alliance_cards` |

---

## Currently implemented cards (engine_status = implemented)

Notable implemented mechanics:
- **Elusive** (keyword): can't be chosen as defender
- **Protector** (keyword): can intercept attacks
- **Ferocity** (keyword): no summoning sickness
- **Stealth** (keyword): can only attack heroes (Long-Range rule)
- **Ranged** (keyword): defender can't deal combat damage back (Long-Range)
- **on_enter:deal_damage_to_target** — Taz'dingo-style enter-play targeted effects
- **activated_power** — Grimdron (1 fire dmg to hero or ally, usable during combat windows)
- **sarmoth_taunt** — Sarmoth (opposing characters that can attack Sarmoth must only target Sarmoth)
- **destroy_target:ally** — Vanquish
- **Pet uniqueness** — pet_capacity enforced with immediate sacrifice choice
- **Hero powers**: Ta'zo flip (deal_damage_to_target:3:fire), Dizdemona (deal_x_damage_to_ally), Omedus (deal_damage_aoe), Grennan (heal)
- **Quest cards** — basic cost-based quest completion

---

## Known open issues / next work

- **Grimdron hero-targeting bug (unconfirmed):** User reported Grimdron's power couldn't target opponent's hero when no enemy allies were in play. All code paths appear correct — hero IS included in `_get_ally_power_targets`. Suspected cause: visual (hero not highlighted?) or runtime state issue. Needs more investigation with actual play. Suggested: add temp `print("ally_power_targets:", result)` in `_get_ally_power_targets` to confirm.
- **Sarmoth** is implemented but untested in play. Watch for edge cases with taunt + Elusive attackers (Elusive means you can't be attacked, so the question doesn't arise on the attacker side — but an Elusive attacker can still be forced to hit Sarmoth if Sarmoth is their legal defender).
- **Combat window AI:** AI currently passes during attack/defend windows (returns empty actions for non-turn player). This is acceptable but means AI never uses Grimdron to counter-attack during enemy combats. Future: extend `get_all_legal_actions` to return useful defensive plays for non-turn player during combat windows.
- **Next card to implement: Sarmoth has been added to Dizdemona's deck. Other Warlock pets (Helwen, Infernal) are `unchecked` — implement when ready.**
- **`logic/BasicAI_behavior.txt` is legacy** and may be stale — actual AI is fully in `game_logic/ai/base_ai.gd`.
