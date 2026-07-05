# Project context

This is a digital implementation of a simplified WoW TCG ruleset.
Always check `References/wow_rules.txt` before implementing any
keyword or card effect — do not rely on general CCG knowledge (Magic,
Hearthstone) since WoW TCG has its own specific rulings.

Card data lives in: `data/cards.csv`
Active playtest scene: `renderer/tests/playtest.gd` (human vs AI, full UI)
Engine lives in: `game_logic/` — see Architecture section below.

---

## Implementing a card — required steps

1. Find the card in `data/cards.csv` (grep by name). Read the card image to get exact card text. If `image_path` is blank but the image file exists under `assets/cards/`, fill in `image_path` now.
2. **Confirm the card text with the user before writing any code.** Also check `References/wow_rules.txt` for any keywords or mechanics.
3. Implement: engine actions in `game_logic/stack_resolver.gd`, AI heuristics in `game_logic/ai/base_ai.gd` if needed.
4. Write headless test scenarios in `game_logic/tests/test_scenarios.gd` covering the new mechanic. User runs these to verify correctness before finalizing.
5. Update `data/cards.csv`: set `data_status=verified`, `engine_status=implemented`, fill `power_text` and `effects` recipe. Do this last, after tests pass.
6. **Ask the user whether the newly implemented card should be added to any deck(s)** in `decks/recommended_ai/*.json`. Do not add it unprompted.

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
| `heal_x_from_target:DMG_TYPE` | Hero power: pay X resources → heal X from target hero or ally (Boris) |
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
- **Combat instants (held cards / ambush):** `BaseAI.COMBAT_INSTANT_TAGS` tags cards (by `card_def_id`) the AI must HOLD — `get_legal_actions` never blind-plays them; `combat_instant_action()` plays them only when the AI is **being attacked**, during attack/defend windows (see `ai_functions.md` for the exact math). Quick Strike (`azeroth_165`) is tagged `combat_instant_dmg`. The AI announces `target_id = state.combat_attacker` at submission. All AI classes inherit the behavior (BaseAI.decide_action; FullRandomAI checks it before random play).
- **Targeted instants announce their target at play time** (`_instant_needs_target` covers `destroy_target` AND `deal_damage_to_target`) — humans get the standard cancellable (Esc) targeting flow via `start_targeting`, highlighted with the looser `can_play_instant_no_target_check` probe. There is no deferred target pick for instants.

---

## Deck system (spec §9 — implemented)

Deck lists live as JSON files on disk, NOT in playtest.gd. Playtest only picks deck ids.

- `decks/base/`, `decks/recommended_ai/`, `decks/custom/` — one JSON per deck (`deck_id` = filename stem).
  - `recommended_ai/` (6 decks): simple-heuristic-friendly decks AI plays reasonably well — Ta'zo, Grennan, Omedus, Timmo, Moonshadow, Boris.
  - `base/` (2 decks): Dizdemona and Radak — both Warlock pet-sacrifice decks (Grimdron/Sarmoth) that need situational judgment (which pet to sacrifice, when) beyond what FullRandomAI/BaseAI handle well, so they're excluded from the "Recommended for AI" category. Still human-playable, and still findable under "All decks" — can be slotted onto an AI player from there if wanted, just expect weaker AI performance. `recommended_ai_id` is still set (`ai_generic`), since that remains the correct AI to use if one is forced onto the deck.
- `ai_profiles/*.json` — `AIProfile` (`ai_id`, `ai_class`: "base"|"fullrandom"|"generic", `strategy_data`). All 8 demo decks specify `ai_generic` (GenericAI — see `game_logic/ai/ai_roster.md` and `ai_functions.md`).
- Classes: `DeckDefinition`/`DeckCardEntry` (game_logic/deck_definition.gd, deck_card_entry.gd), `DeckLibrary`/`DeckLibraryIndex` (scan/categorize, ids only), `DeckManager` (single entry point: `get_available_decks()`, `load_deck()`, `validate_deck()` [hero + ≥60 cards], `get_runtime_deck()` → `Deck`, `load_ai_profile()`, `make_ai_for_deck()`).
- **Nothing except DeckManager reads deck files or calls DeckLibrary.** Playtest menu has a category dropdown per player ("All decks" vs "Recommended for AI") that filters the deck dropdown via `get_available_decks()`; "Recommended AI" player type uses `make_ai_for_deck()`. An "Avoid mirror matches" checkbox (default on) excludes the other player's fixed deck from a random pick, or refuses to start on a fixed mirror.
- Tests: `game_logic/tests/test_deck_manager.gd`.

Demo decks (all 60 cards): Dizdemona (azeroth_2, base), Ta'zo (azeroth_15, recommended_ai), Grennan (azeroth_10, recommended_ai), Boris (azeroth_1, recommended_ai), Omedus (azeroth_12, recommended_ai), Radak (azeroth_13, base), Timmo (azeroth_7, recommended_ai), Moonshadow (azeroth_6, recommended_ai).

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
- **Hero powers**: Ta'zo flip (deal_damage_to_target:3:fire), Dizdemona (deal_x_damage_to_ally), Omedus (deal_damage_aoe), Grennan (heal), Boris Brightbeard (heal_x_from_target — pay X resources, heal X from any hero or ally), Radak Doombringer (radak_pet_sacrifice — flip: sacrifice Pet with cost X, deal X shadow dmg to target)
- **Quest cards** — basic cost-based quest completion

### Playtested heroes (confirmed working)
Dizdemona, Ta'zo, Grennan, Boris Brightbeard, Omedus, Sarmoth (ally), Radak Doombringer

---

## Combat window rules (enforced in multiple layers)

Rule 601.1 (combat only during non-combat action phase) and rule 502.1/1199 (non-instants same) are enforced in three layers:

1. **`stack_resolver.gd` — submission guard** (`_can_propose_combat`, `_can_play_non_instant`, `_can_play_ability`, `_can_place_resource`): all check `not (combat_attack_window or combat_defend_window or in_protect_point)` and `pending_actions.is_empty()`.
2. **`input_router.gd` — highlight guard** (`get_playable_card_ids`, `can_attack` in context menu): same flags, so allies don't stay green during combat windows.
3. **`input_router.gd` — direct click guard** (`handle_card_click`, in-play ally/hero branch): `can_propose` check before calling `get_legal_attackers`, prevents entering targeting animation when `pending_actions` non-empty or combat window is open.

**Attack animation** (`_animate_attack` in `board_renderer.gd`) fires on `combat_concluded` (not `combat_started`) so the lunge plays toward the actual defender after any protector swap, not the proposed defender before the protect point.

**Window-opened events must drain (playtest.gd):** both `attack_window_opened` and `defend_window_opened` handlers call `_drain_passes()`. When the *human's* pass is the one that resolves the pending action, `pass_priority` returns only the resolution events (no `priority_passed`), so nothing else re-drives the AI — priority sits on the AI forever and the game stalls. `_drain_passes()` is re-entrancy-guarded (`_draining`), so calling it from a handler fired mid-drain is safe. Any new event that hands priority to a potentially-AI player needs the same treatment.

---

## Display / layout

- Viewport: **1920×1080**, `stretch/mode=canvas_items`, `stretch/aspect=expand` (fills 16:9 window, no grey bars).
- All card spawn positions and deck back sprites are derived from `_renderer.zone_anchors` — **never hardcode a spawn Vector2**. `_spawn_zone_nodes(zone_id, color)` reads the anchor automatically. The deck back sprite loop does the same via `_renderer.zone_anchors.get("p1_deck"/"p2_deck")`.
- At startup, `_spawn_zone_nodes` is called for every visible zone: hero_row, hand, ally_row, resource_row, graveyard, chain (deck excluded — back sprite only).
- UI bar occupies y=960..1080. Board occupies y=0..950. `CENTER_X = 960`.
- Pass button shows **"Sacrifice a pet [Space]"** (disabled, no color change) when `pending_pet_sacrifice_player == "p1"`.

---

## Known open issues / next work

- **Grimdron hero-targeting bug (unconfirmed):** User reported Grimdron's power couldn't target opponent's hero when no enemy allies were in play. All code paths appear correct — hero IS included in `_get_ally_power_targets`. Suspected cause: visual (hero not highlighted?) or runtime state issue. Needs more investigation with actual play. Suggested: add temp `print("ally_power_targets:", result)` in `_get_ally_power_targets` to confirm.
- **Sarmoth** playtested and working. Watch for edge cases with taunt + Elusive attackers.
- **Combat window AI:** the non-turn AI now plays tagged **combat instants** (Quick Strike) during attack/defend windows via `BaseAI.combat_instant_action` — see AI conventions above. It still never uses ally activated powers (e.g. Grimdron) to counter-attack during enemy combats. Future: extend the window logic to defensive ally-power plays.
- **Next cards to implement:** Check `data/cards.csv` for candidates.
- **`logic/BasicAI_behavior.txt` is legacy** and may be stale — actual AI is fully in `game_logic/ai/base_ai.gd`.
