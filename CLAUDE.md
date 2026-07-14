# Project context

This is a digital implementation of a simplified WoW TCG ruleset.
Always check the rules in `References/wow_rules.txt` before implementing any
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
| `game_logic/actions/primitives.gd` (class `GameLogic`) | Low-level helpers: `move_card`, `deal_damage`, `check_destroyed`, `exhaust_card`, `heal`. `deal_damage` only places damage; callers run `check_destroyed` as a separate step (needed for simultaneous combat damage). |
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
- `StackResolver.choose_control_discard(state, card_id, db)` / `decline_control_discard(state, db)` — Infernal's start-of-turn "discard a card, or target opponent gains control". Unlike a mandatory discard the player MAY decline: control changes (rule 401.3 — card moves to the new controller's ally_row, `just_summoned` set, pet uniqueness re-checked for the new controller). `pass_priority` is also hard-blocked while pending; in the UI the pass button becomes the decline option ("Give up control [Ctrl+Space]") and hand cards highlight red for the discard. Declining is gated behind Ctrl+Space (or the pass button / a card click) — plain Space is absorbed with a hint, so an accidental tap can't hand the card to the opponent.

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
| `activated_power:COST:EFFECT:AMOUNT:DMG_TYPE:TARGETS:EXTRACOST` | Ally/equipment activated power. `EFFECT` includes `draw`. `EXTRACOST` (optional 7th field) is a card-specific extra cost paid alongside resources+activate, e.g. `exhaust_hero` (Mooncloth Robe). `no_activate` marks a plain payment power (701.2) whose printed cost has no [Activate] tap symbol — no self-exhaust, no summoning sickness, repeatable each turn (Hierophant Caydiem: "3 →..."). `put_damage_self:N` is the same idea but the extra cost is self-damage (Acolyte Demia). `activate_put_damage_self:N` is self-damage that KEEPS the [Activate] tap symbol — the source also exhausts and has summoning sickness (Kena Shadowbrand). `rfg_allies:N` removes N ally cards from your graveyard from the game as a cost (Augustus Corpsemonger — the specific N are auto-chosen in graveyard order, see `data/rules_deviations.md`). `sacrifice_ally` destroys a chosen ally in your party as a cost; pair with `TARGETS=friendly_ally` so the target picker only offers your own allies, the sacrifice may be the source itself (Bizzik Sparkcog). `EFFECT` value `destroy_ally` destroys the (any-party) target ally — pair with `TARGETS=ally` (Augustus) |
| `equipment:SLOT:DEF` | Marks an Equipment card: `SLOT` (chest/back/neck/…) drives slot uniqueness (rule 414.3); `DEF` is defense (0 = no damage prevention). Equipment enters the hero row |
| `ongoing` | Marks an Ability as ongoing (rule 305.2a — stays in play instead of resolve-and-graveyard). Non-totem ongoing abilities enter the controller's hero_row (`_resolve_play_ongoing_ability`). `is_ongoing_def()` also routes an **Instant** Ability with this flag to `play_ability` (enters play) instead of `play_instant` in both `_action_type_for`s |
| `totem[:ELEMENT]` | Marks a Totem (rule 305.3 — Searing Totem): an ability **ally** that enters the controller's **ally_row** (not hero_row), can't be proposed as an attacker (`is_totem_def` gate in `get_legal_attackers` / `_can_propose_combat`), but can be attacked/targeted like any ally. ATK/health come from the CSV `atk`/`health` cols. Pairs with an `ongoing` segment. Play is instant-speed (type line "Instant Ability") |
| `ongoing_damage_each_turn:AMOUNT:DMG_TYPE` | Ongoing Totem power: at the start of **each** turn, the totem's controller deals AMOUNT DMG_TYPE damage to a chosen target hero or ally. Collected in `TurnManager._collect_ongoing_turn_triggers` (ready step, turn player's totems first — 501.1a); each opens a mandatory target choice resolved via `StackResolver.choose_totem_target()` (direct call, `pending_totem_target_player` hard-blocks `can_submit`/`pass_priority` — like the strike/reveal choices). Scene handles `totem_target_required`: AI auto-targets (opposing kill else opposing hero), human targets via `start_totem_targeting`. Resolves immediately, not on the chain — see `data/rules_deviations.md` "Searing Totem" |
| `on_enter:EFFECT:AMOUNT:DMG_TYPE` | Enter-play triggered effect |
| `destroy_target:ally` | Destroy a target ally (Vanquish-style) |
| `exhaust_target:ally` | Exhaust a target ally (Exhaustion, `azeroth_159`, Instant Ability). Ally-only (`_instant_targets_ally_only`), instant speed; resolution re-checks 706 + `_is_ally`, then `GameLogic.exhaust_card` (no-op if already exhausted). Aimed at a proposed attacker while its combat proposal is on the chain, the 601.3 recheck (`attacker.is_exhausted`) fizzles the proposal — same interrupt path as Litori's `target_cant_attack`; too late once the attack window opens. AI: tagged `combat_instant_exhaust` in `BaseAI.COMBAT_INSTANT_TAGS` (held, never blind-played); `BaseAI.exhaust_attacker_action` answers an opposing propose_combat aimed at our side with Litori's worth math (attacker must be an **ally**, answer must be affordable), wired into both `decide_action`s after `hero_disable_action` |
| `sarmoth_taunt` | Opposing characters that can attack this must attack only this |
| `heal_x_from_target:DMG_TYPE` | Hero power: pay X resources → heal X from target hero or ally (Boris) |
| `reveal_pick:CARD_TYPE:N` | Quest reward: reveal the top N cards; put a revealed card of `CARD_TYPE` (`Equipment`/`Ally`/`Ability`; matches the parsed `CardDef.card_type`, so `Instant Ally`→`Ally`) into hand, rest to the bottom of the deck in revealed order. If at least one matches, sets `pending_reveal_pick_*` and emits `reveal_pick_opened`; the scene resolves it via `StackResolver.choose_reveal_pick()` (direct call, not the stack — like pet sacrifice; `can_submit`/`pass_priority` hard-block while pending). The choice ALWAYS opens (even with no match) so the player sees the revealed cards; the browser shows every revealed card graveyard-style, non-matching ones tinted red and non-selectable, a matching card MUST be picked before OK, and if none match the player clicks OK (empty pick — `choose_reveal_pick(state, "")`) to send all revealed cards to the bottom. Big Game Hunter (Equipment:4), Kibler's Exotic Pets (Ally:3), Zapped Giants (Ability:3) |
| `turn_start_discard_or_give_control` | At the start of your turn: discard a card, or the opponent gains control of this (Infernal). Fires in `TurnManager._apply_start_of_turn_effects`; resolves via `choose_control_discard` / `decline_control_discard` |
| `end_of_turn_damage_opposing:AMOUNT:DMG_TYPE` | At the end of your turn, this deals AMOUNT damage to each opposing hero and ally (Infernal). Fires in `TurnManager._apply_end_of_turn_effects` |
| `target_cant_attack` | Hero flip power (Litori Frostburn): target hero or ally can't attack this turn (`cannot_attack` restriction Buff, duration "turns":1, cleared by the end-of-turn buff sweep). Instant speed. Key timing (601.3 vs 602.1/602.4): played in RESPONSE to a combat proposal still on the chain, the proposal's legality recheck interrupts it — combat never starts and the attacker never exhausts. Played during an attack/defend window it's too late — "can't attack" is not a remove-from-combat effect; the current combat proceeds. AI: never blind-played; `BaseAI.hero_disable_action` answers an opposing propose_combat on the chain (hero defender taking lethal/≥4, or an ally cost ≥2 dying in a bad trade), holding it if a combat-instant kill is available |
| `deal_damage_to_target:AMOUNT:DMG_TYPE[:RESTRICTION]` | "Your hero deals AMOUNT damage to target hero or ally" (Quick Strike / Fire Blast). Optional 4th field: a `+`-joined restriction rider applied to a **surviving** target — `cannot_attack` (Frostbolt), `cannot_attack+cannot_protect` (Frost Shock). `_apply_damage_riders` places a restriction Buff (duration "turns":1, swept end of turn), reusing Litori's `cannot_attack` machinery; `cannot_protect` is enforced in `get_legal_protectors`. AI ignores the rider (still tagged `combat_instant_dmg`) — see `data/rules_deviations.md` |
| `drain_heal_per_damage:N` | Pairs with a `deal_damage_to_target` segment (Steal Essence `azeroth_134`): after the instant's damage resolves, the casting hero heals N for each damage actually DEALT — armor prevention and 405.3 excess-beyond-fatal both reduce the heal (read from the `damage_dealt` events just produced). No-op on an undamaged hero. All existing `deal_damage_to_target` wiring (targeting, `_incoming_hero_damage`, AI damage math) applies unchanged. AI: tagged `combat_instant_dmg` (played for the damage; the drain heal is not modeled) |
| `multi_shot:AMOUNT:DMG_TYPE` | "Your hero deals AMOUNT damage to each of up to three target heroes and/or allies" (Multi-Shot, `azeroth_41`, Instant Ability). Up to 3 distinct hero-or-ally targets announced in order at play time (`target_id`/`target_id_2`/`target_id_3`; `_2` optional, `_3` requires `_2`), each takes the same AMOUNT — the hero is the damage source. Resolves each wave in printed order with its own destroy/game-over check (711.1). Validated by `_can_play_multi_shot` (in the `play_instant` path). Unlike Chain Lightning, **ALL three slots select rather than target** — every slot MAY pick an Untargetable character (706 exception). Reuses the Chain Lightning multi-target UI machinery (`_is_multi_target` in `input_router.gd`, action-type-aware). AI: `BaseAI._multi_shot_action` picks up to 3 enemy targets (killable allies first, then high-HP soak, then hero; opponents only) |
| `atk_vs_exhausted_defender:N` | Continuous self-modifier (Bala Silentblade `azeroth_226`): "+N ATK while attacking an exhausted hero or ally." Evaluated live in `GameState.get_atk` section (2) — on only while this card IS `combat_attacker` and the current `combat_defender` is exhausted, re-read at every call (a defender exhausted or readied mid-combat flips the bonus immediately; pairs with `on_attack_exhaust_target` to exhaust your own defender before the attack window). Never cached. Limits: the attack-cursor preview (`get_atk_if_attacking`) can't show it (no defender chosen yet), and the AI does not model the bonus when forecasting attacks (it still deals the boosted damage at conclusion) |
| `on_attack_exhaust_target` | Triggered attack power (Chops `dark_portal_32`, Voss Treebender `azeroth_266`): "When [this] attacks, you may exhaust target hero or ally." Fires as the combat step starts (602.1), AFTER the strike/ready-on-attack points and BEFORE the attack window — exhausting a ready Protector denies the protect point (602.2, the trigger's whole purpose); exhausting the proposed defender does NOT cancel the combat (601.3 already passed). Direct-call choice (`pending_attack_exhaust_*`, `StackResolver.choose_attack_exhaust(state, target_id, db)`, `""` = decline; `can_submit`/`pass_priority` hard-block while pending) — not on the chain, see `data/rules_deviations.md` "Attack-exhaust triggers". Targets = `get_attack_exhaust_targets` (any hero/ally, 706 untargetable respected). Human: targeting mode via `start_attack_exhaust_targeting`, Esc = decline (`_on_targeting_cancelled`). AI: `BaseAI.choose_attack_exhaust` exhausts the most dangerous ready legal protector (prefers one whose retaliation kills the attacker, else highest ATK), declines otherwise |
| `attach:TARGETS[:exhaust_it]` | Marks an ongoing Ability as an **attachment** (rule 400 — "Attach to target TARGETS"). Always paired with an `ongoing` segment. Targeted at play time like any targeted ability (`_instant_needs_target`/`_instant_targets_ally_only` cover `attach`; standard Esc-cancellable targeting flow, 706 Untargetable respected). Resolution (`_resolve_attach` in `_resolve_play_ongoing_ability`): re-checks the target (706/400.2 — if it left play or became Untargetable, the attachment goes to its owner's graveyard, `action_fizzled` reason `attach_target_gone`), then the card enters play in the shared `"attached"` zone with `CardInstance.attached_to` = host and its id in the host's `attachments` (both set BEFORE `move_card` per its contract), emits `card_attached`. Optional `exhaust_it` rider (Entangling Roots: "…and exhaust it") exhausts the host as part of the resolution. **Host leaves play → attachment destroyed by the game** (400.5/410.6c) — handled generically in `GameLogic.move_card` (any move of a host to a non-play zone destroys its attachments; moves within play, e.g. control change, keep them attached). Renderer: attachment tucks behind its host (`_attachment_hosts`, `ATTACH_PEEK` offset toward the opponent side, host z-bumped) and follows it on relayout; self-healed in `reconcile_from_state`. AI: `BaseAI._attach_actions` — buff attachments (`attached_buff`) go on the AI's own highest-ATK ally, debuff attachments on the opposing highest-ATK ally with cost ≥ spell cost (one action generated, the best target) |
| `attached_buff:ATK:HP` | Ongoing attachment stat grant (Mark of the Wild): "Attached ally has +ATK ATK and +HP health." Read live from the host's `attachments` list in `GameState.get_atk` (1b) and `get_max_hp` (`_attachment_stat_mods`) — never cached; ends the moment the attachment leaves play |
| `attached_cannot_ready` | Ongoing attachment restriction (Entangling Roots): "Attached ally can't ready during its controller's ready step." Live check in `TurnManager._enter_ready` (`_ready_blocked`) — the host skips the ready step (summoning sickness still clears); explicit ready effects (e.g. `ready_self_at_turn_end`) are NOT blocked |
| `opposing_allies_cant_attack` | Static aura (Lady Jaina Proudmoore): while a card with this flag is in play, that player's OPPONENT can't propose any of its **allies** as attackers (hero unaffected). Evaluated live via `_allies_attack_locked` in `get_legal_attackers` + `_can_propose_combat` — never cached. AI does not model the lock |
| `opposing_cant_protect` | Static aura (Hannah the Unstoppable): while a card with this flag is in play, that player's OPPONENT has NO legal protectors — neither Protector allies nor hero grants. Evaluated live via `_protect_locked` at the top of `get_legal_protectors` (returns `[]`) — never cached; the protect point simply never opens. AI does not model the lock |
| `hero_has_protector` | "Your hero has protector" (Draconian Deflector): while a card with this flag is in a player's hero_row, that player's ready hero is a legal protector (`get_legal_protectors`; 602.2b still applies — it can't protect itself). A hero that protects becomes the defender, so the 602.3 defend strike point fires for it — protecting heroes can retaliate with a weapon strike. `GameState.combat_protector` tracks who protected this combat (cleared at conclusion). AI: GenericAI protects with the hero only when no ally protector steps in, the hero stays above `HERO_ALL_OUT_HP` after the hit, and either the retaliation strike kills the attacker or a dying ally is worth the face damage (cost ≥ incoming ATK); BaseAI's highest-HP pick excludes the hero unless it's the only protector. `choose_strike_weapon` ALWAYS strikes while the hero is protecting (the opponent is attacking around the hero — likely the weapon's only use this turn); the Long-Range exception still holds (the strike would deal nothing) |
| `whelp_bounce` | Triggered equipment power (Green Whelp Armor): when an **attacking ally** deals combat damage that actually LANDS on the wielder's hero, the wielder MAY pay 2 to return that ally to its owner's hand. First *triggered* (not `[Activate]`/passive) equipment power. Detected at the end of `_do_combat_conclusion` (`_maybe_open_whelp_bounce`): attacker was an ally, defender was the wielder's hero, ≥1 damage landed (armor DEF/block absorbing all → no trigger), both still in play, wielder can afford 2. Opens a direct-call choice point (`pending_whelp_bounce_*`, `whelp_bounce_opened`) resolved via `StackResolver.choose_whelp_bounce(state, pay, db)` — like the strike point; `can_submit`/`pass_priority` hard-block while pending. Fires once per combat (single-attacker combat model). AI: `BaseAI.choose_whelp_bounce` bounces allies with cost ≥ 2. Scene: `_handle_whelp_bounce` (AI auto-resolves; any human — including the off-screen hotseat player, the choice is board-public — gets inline pay/decline buttons like the ready-on-attack point) |
| `weapon:STRIKE_COST` | Marks an Equipment card as a weapon (rule 303) — always paired with an `equipment:SLOT:DEF` segment (slot e.g. `melee_weapon` for uniqueness, DEF 0). ATK comes from the CSV `atk` column, damage type from `dmg_type` ("Melee" gates the strike discount). See "Weapons & striking" section |
| `melee_strike_discount:N` | Hero flip power (Gorebelly): pay N less the next time you strike with a Melee weapon this turn (`PlayerState.melee_strike_discount`; consumed by the next melee strike, cleared at every turn start) |
| `two_handed` | Marks a weapon as Two-Handed (rule 414.3c): violates uniqueness with any `off_hand`-slot equipment, checked both ways in `_check_equipment_uniqueness` (same sacrifice choice as a slot conflict). Rod of the Ogre Magi |
| `power_weapon` | AI-only flag for "power weapons" — weapons whose value is their activated power, not the strike (Rod of the Ogre Magi, later Hypnotic Blade). The engine still offers the strike normally (a human may strike); the AI never strikes with one (`choose_strike_weapon` filters them out) and excludes it from `forecast_atk` (so it never proposes a hero attack on its account). Pair with an `activated_power` segment the AI already plays |
| `elusive` | (keyword in keywords col, not effects) — can't be chosen as defender |
| `protector` | (keyword) — can intercept attacks |
| `ferocity` | (keyword) — no summoning sickness |
| `stealth` | (keyword) — can only attack heroes |
| `ranged` | (keyword) — long-range, defender can't deal combat damage back |
| `untargetable` | (keyword) — can't be chosen as a target of links (`_is_legal_target` in stack_resolver.gd, checked at submission AND resolution); combat/AoE unaffected. Chain Lightning's 2nd/3rd targets — and ALL three of Multi-Shot's targets — are a card-specific exception (allow flag) |

**`data_status`**: `verified` = card text confirmed from image  
**`engine_status`**: `implemented` = effects string is live in engine

**CSV field quoting:** always quote `power_text` and `card_subtype` values to safely handle special characters (commas, quotes, line breaks). Use standard CSV quoting: wrap the field in double quotes and escape internal quotes as `""`. For example:
```
azeroth_56, Frostbolt, "Instant Ability — Frost", "Deal 3 frost damage to target hero or ally. That hero or ally can't attack this turn."
```

**Engine behavior that deviates from the printed rules/card text** (e.g. a
timing restriction not in the printed text but true by construction of the
duel format) must be tracked in `data/rules_deviations.md`, with a code
comment at the enforcement site pointing back to it. Don't hardcode a
card-specific check in `stack_resolver.gd` for this — add a data-driven
effects flag instead (see `require_turn_player` for the pattern).

---

## Card uniqueness

WoW TCG allies are **NOT unique** by default. Do not assume uniqueness unless the card text says so or the card is a **Pet** (Pet uniqueness is enforced separately).

**Pet uniqueness (rule 414.3b):** A player may control at most `PlayerState.pet_capacity` pets (default 1) in their ally_row simultaneously. When a second Pet enters play, `_check_pet_uniqueness` fires immediately (non-interruptible), setting `pending_pet_sacrifice_player` and emitting `pet_sacrifice_required`. The player must call `StackResolver.choose_pet_sacrifice()` directly (not via `submit_action`).

Pet capacity is a player attribute (`PlayerState.pet_capacity`, default 1) that card effects can increase.

**Name-based uniqueness (rule 414.3a — the "Unique" tag):** cards whose `keywords` column contains `Unique` (parsed to `"unique"`). A player may not control two or more in-play cards that share a name and both carry Unique (Lady Jaina Proudmoore). `_check_unique_uniqueness` fires after a card enters play (called from `_resolve_play_ally` and `_resolve_play_equipment`); on violation it sets `pending_unique_sacrifice_player`/`_ids` and emits `unique_sacrifice_required`. Resolve via `StackResolver.choose_unique_sacrifice()` (direct call, not the chain — same pattern as pet/equipment sacrifice; `can_submit` hard-blocks while pending). UI mirrors the equipment-sacrifice mode (red highlight, pass button shows "Destroy a duplicate"); AI keeps the first copy.

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
  - `recommended_ai/` (6 decks): simple-heuristic-friendly decks AI plays reasonably well — Ta'zo, Grennan, Omedus, Timmo, Boris, Sen'zir.
  - `base/` (3 decks): Dizdemona, Radak, Moonshadow — decks that need situational judgment beyond what FullRandomAI/BaseAI handle well, excluded from "Recommended for AI". Still human-playable and findable under "All decks" — can be slotted onto an AI player, just expect weaker AI performance. `recommended_ai_id` is still set (`ai_generic`), the correct AI to use if one is forced onto the deck.
- `ai_profiles/*.json` — `AIProfile` (`ai_id`, `ai_class`: "base"|"fullrandom"|"generic", `strategy_data`). All 8 demo decks specify `ai_generic` (GenericAI — see `game_logic/ai/ai_roster.md` and `ai_functions.md`).
- Classes: `DeckDefinition`/`DeckCardEntry` (game_logic/deck_definition.gd, deck_card_entry.gd), `DeckLibrary`/`DeckLibraryIndex` (scan/categorize, ids only), `DeckManager` (single entry point: `get_available_decks()`, `load_deck()`, `validate_deck()` [hero + ≥60 cards], `get_runtime_deck()` → `Deck`, `load_ai_profile()`, `make_ai_for_deck()`).
- **Nothing except DeckManager reads deck files or calls DeckLibrary.** Playtest menu has a category dropdown per player ("All decks" vs "Recommended for AI") that filters the deck dropdown via `get_available_decks()`; "Recommended AI" player type uses `make_ai_for_deck()`. An "Avoid mirror matches" checkbox (default on) excludes the other player's fixed deck from a random pick, or refuses to start on a fixed mirror.
- Tests: `game_logic/tests/test_deck_manager.gd`.

Demo decks (all 60 cards): Dizdemona (azeroth_2, base), Ta'zo (azeroth_15, recommended_ai), Grennan (azeroth_10, recommended_ai), Boris (azeroth_1, recommended_ai), Omedus (azeroth_12, recommended_ai), Radak (azeroth_13, base), Timmo (azeroth_7, recommended_ai), Moonshadow (azeroth_6, base), Sen'zir (azeroth_14, recommended_ai).

---

## Currently implemented cards (engine_status = implemented)

Notable implemented mechanics:
- **Elusive** (keyword): can't be chosen as defender
- **Protector** (keyword): can intercept attacks
- **Ferocity** (keyword): no summoning sickness
- **Stealth** (keyword): can only attack heroes (Long-Range rule)
- **Ranged** (keyword): defender can't deal combat damage back (Long-Range)
- **Untargetable** (keyword): can't be chosen as a target of links (rule 706); combat and non-targeted effects (AoE) unaffected. A target that becomes Untargetable after the announce fizzles at resolution (glossary 4217)
- **on_enter:deal_damage_to_target** — Taz'dingo-style enter-play targeted effects
- **activated_power** — Grimdron (1 fire dmg to hero or ally, usable during combat windows)
- **sarmoth_taunt** — Sarmoth (opposing characters that can attack Sarmoth must only target Sarmoth)
- **destroy_target:ally** — Vanquish
- **Pet uniqueness** — pet_capacity enforced with immediate sacrifice choice
- **Infernal** (azeroth_127) — start-of-turn "discard or give control" choice (declinable, unlike a forced discard) + end-of-turn 1 fire to each opposing hero and ally
- **Equipment** — Mooncloth Robe (first equipment). Plays via `play_equipment` into the hero row; `activated_power` with `draw` effect + `exhaust_hero` extra cost. Slot uniqueness (rule 414.3) enforced with an immediate destroy choice mirroring Pet uniqueness (`pending_equip_sacrifice_*`, `choose_equipment_sacrifice`, `equipment_sacrifice_required`). See "Equipment" section below.
- **Green Whelp Armor** (azeroth_291) — first *triggered* equipment power: when an attacking ally deals combat damage to your hero, you may pay 2 to bounce it to its owner's hand (`whelp_bounce`; `_maybe_open_whelp_bounce` at combat conclusion → direct-call `choose_whelp_bounce`)
- **Litori Frostburn** (azeroth_5) — `target_cant_attack` flip: cancels an enemy combat proposal on the chain via the 601.3 recheck (attacker doesn't exhaust); too late once the attack window is open. First "instant save that doesn't kill the attacker" AI behavior (`BaseAI.hero_disable_action`)
- **Hero powers**: Ta'zo flip (deal_damage_to_target:3:fire), Dizdemona (deal_x_damage_to_ally), Omedus (deal_damage_aoe), Grennan (heal), Boris Brightbeard (heal_x_from_target — pay X resources, heal X from any hero or ally), Radak Doombringer (radak_pet_sacrifice — flip: sacrifice Pet with cost X, deal X shadow dmg to target)
- **Quest cards** — basic cost-based quest completion
- **Reveal-and-pick quests** — Big Game Hunter (`azeroth_348`, Equipment:4), Kibler's Exotic Pets (`azeroth_355`, Ally:3), Zapped Giants (`azeroth_361`, Ability:3): reveal top N, keep one revealed card of a type, rest to bottom (`reveal_pick` recipe; human picks via the reveal browser, AI keeps highest-cost via `_pick_ai_reveal`)
- **Totem** (rule 305.3) — Searing Totem (`azeroth_116`, Instant Ability—Elemental, Fire Totem, 0/1). Ability ally that enters the ally_row, can't attack, can be attacked/targeted like an ally. Ongoing power deals 1 fire damage to a chosen hero/ally at the start of each turn (`totem:fire` + `ongoing_damage_each_turn:1:fire`; direct-call `choose_totem_target`). First card of the general Totem framework.
- **Long-Range** (keyword) — Tanwa the Marksman (dark_portal_235, 4/3). While a Long-Range character is attacking, the defender deals no combat damage back (`_do_combat_conclusion` zeroes `def_dmg` when the attacker has `long_range`; has no effect when the character is defending instead).
- **Weapons & striking** — Krol Blade (azeroth_331, first weapon) + Gorebelly (azeroth_9, melee strike discount flip). See "Weapons & striking" section
- **Frostbolt / Frost Shock** (`azeroth_56`, 3 frost; `azeroth_109`, 2 frost) — Instant Abilities that deal frost damage to a target hero/ally, then apply a "can't attack" (Frostbolt) or "can't attack or protect" (Frost Shock) restriction to a surviving target (`deal_damage_to_target` 4th field → `_apply_damage_riders`). Tagged `combat_instant_dmg` like Quick Strike; AI plays them for the damage only.
- **Steal Essence** (`azeroth_134`, 2, Instant Ability — Affliction, Warlock) — "Your hero deals 2 shadow damage to target hero or ally and heals 1 damage from itself for each damage dealt" (`deal_damage_to_target:2:shadow|drain_heal_per_damage:1`). First drain effect — see the `drain_heal_per_damage` effects-table row. Tagged `combat_instant_dmg`; AI plays it for the damage, drain not modeled.
- **Multi-Shot** (`azeroth_41`, 5, Instant Ability — Marksmanship) — "Your hero deals 2 ranged damage to each of up to three target heroes and/or allies" (`multi_shot:2:ranged`). Second multi-target announced-in-order spell after Chain Lightning; reuses its target-picking UI/AI machinery (`_is_multi_target`), but is instant-speed, deals a flat amount to every target, and lets **all three** slots select Untargetable characters.
- **Exhaustion** (`azeroth_159`, 2, Instant Ability) — "Exhaust target ally" (`exhaust_target:ally`). A held combat instant the AI plays on an opposing **ally** attacker while its combat proposal is on the chain; exhausting it fizzles the proposal (601.3), the same interrupt/AI role as Litori's freeze but as an affordable hand card. Ally-only targeting; too late once the attack window opens. See the `exhaust_target` effects-table row.
- **Lady Jaina Proudmoore** (`azeroth_195`, 7/4 Ally, Unique) — "Opposing allies can't attack." Live static aura (`opposing_allies_cant_attack`) + first card exercising **name-based Unique uniqueness** (rule 414.3a — see Card uniqueness).
- **Bala Silentblade** (`azeroth_226`, 3-cost 1/4 Horde Orc Rogue) — "+3 ATK while attacking an exhausted hero or ally." Live conditional self-modifier (`atk_vs_exhausted_defender:3`), natural partner of the Chops/Voss attack-exhaust trigger. See the effects-table row.
- **Chops** (`dark_portal_32`, 3-cost 3/4 Boar, Pet) / **Voss Treebender** (`azeroth_266`, 1-cost 2/1 Horde Tauren Druid) — "When [this] attacks, you may exhaust target hero or ally." First attack-triggered targeted power (`on_attack_exhaust_target`): resolves before the attack window, so it can exhaust a ready Protector and deny the protect point. See the effects-table row.
- **Attachments** (rule 400) — general framework: `attach:TARGETS[:exhaust_it]` + host-side ongoing segments; shared `"attached"` zone; host leaving play destroys attachments (see the effects-table rows). First cards: **Entangling Roots** (`azeroth_20`, 2, Ability — Balance, Druid): attach to target ally and exhaust it; attached ally can't ready during its controller's ready step (`attach:ally:exhaust_it|attached_cannot_ready`). **Mark of the Wild** (`azeroth_24`, 2, Instant Ability — Restoration, Druid): attach to target ally; +2 ATK / +2 health (`attach:ally|attached_buff:2:2`).
- **Hannah the Unstoppable** (`azeroth_187`, 3/3 Ally) — "Opposing heroes and allies can't protect." Live static aura (`opposing_cant_protect`): while an opponent controls Hannah, that player has no legal protectors (`_protect_locked` short-circuits `get_legal_protectors`). Mirror of Jaina's aura, locking *protecting* instead of *attacking*.
- **Instant Ally** — Tristan Rapidstrike (azeroth_221, 3/3 Protector). The Instant tag (CSV `type` = "Instant Ally" → `CardDef.is_instant`) makes `play_ally` instant-speed in `_can_play_non_instant`: playable any time with priority (combat windows, opponent's turn, non-empty chain — rule 409.1). Resolves as a normal ally (summoning sickness, which does NOT block protecting — 601.2a restricts attackers only). AI: tagged `combat_instant_protector` in `BaseAI.COMBAT_INSTANT_TAGS` (held, never blind-played); `instant_protector_action` flashes it in during the ATTACK window only (never defend — the protect point is past) when being attacked, no board protector answers, and the protector decision tree would pick it (safe kill-and-survive block, or any block to save the hero); the normal `choose_protector` then uses it at the protect point.
- **Ally activated powers with sacrifice-style costs** — Kena Shadowbrand (`azeroth_190`, 1/3): `[Activate]`, put 1 damage on herself → draw (`activate_put_damage_self:1`; keeps the tap/exhaust, may be self-lethal per 405.3; AI won't draw her to death). Bizzik Sparkcog (`azeroth_178`, 2/4): `[Activate]`, destroy an ally in your party → draw (`sacrifice_ally` cost + `friendly_ally` target picker; AI only sacrifices an already-damaged ally). Augustus Corpsemonger (`azeroth_177`, 3/4): `[Activate]`, remove three ally cards in your graveyard from the game → destroy target ally (`destroy_ally` effect + `rfg_allies:3` cost; the 3 exiled cards are auto-chosen — see `data/rules_deviations.md`; AI destroys enemy allies worth killing via `_destroy_is_worth_it`).
- **Rod of the Ogre Magi** (`azeroth_332`, 4, Two-Handed Weapon—Staff, Melee (1), 1 ATK) — first "power weapon": `[Activate]`, exhaust your hero → deal 1 damage to target hero or ally (`activated_power:...:exhaust_hero`, same path as Mooncloth Robe + Grimdron). Carries `two_handed` (first 414.3c Two-Handed↔Off-Hand uniqueness card) and the `power_weapon` AI flag (AI uses the ping, never strikes with it) — see both effects-table rows.
- **Hypnotic Blade** (`azeroth_327`, 2, Weapon—Dagger, Melee (1), 1 ATK) — power weapon #2: `3, [Activate]`, exhaust your hero → target player discards a card, use only on your turn (`activated_power:3:discard_opponent:1:::exhaust_hero` + standalone `on_your_turn` segment). The activated-power `discard_opponent` effect reuses Mias the Putrid's pending-discard machinery; "target player" is auto-chosen as the opponent — see `data/rules_deviations.md`. AI uses it whenever the opponent holds cards. In hotseat, the off-screen player's forced discard runs in **discard peek mode** (see Hotseat section).

### Playtested heroes (confirmed working)
Alliance : Boris, Dizdemona, Moonshadow
Horde : Ta'zo, Grennan, Boris Brightbeard, Omedus, Radak Doombringer

---

## Equipment (rules 300.1, 303/304, 414.3)

Equipment implemented: **Mooncloth Robe** (`azeroth_298`, Armor—Cloth, Chest, DEF 0), **Pads of the Dread Wolf** (`dark_portal_260`, Armor—Leather, Feet, DEF 1 — first card with functional DEF), **Golem Skull Helm** (`azeroth_290`, Armor—Plate, Head, DEF 3, vanilla blocker), **Draconian Deflector** (`azeroth_285`, Armor—Shield, Off-Hand, DEF 4, "Your hero has protector" — see `hero_has_protector` in the effects table), and **Green Whelp Armor** (`azeroth_291`, Armor—Leather, Chest, DEF 1, first *triggered* equipment power — see `whelp_bounce` in the effects table).

- **Play flow:** `play_equipment` action (mirrors `play_ally`'s action-phase timing) → `_resolve_play_equipment` moves the card to the controller's `hero_row` (rule 304.1). Card type is `Equipment`; the recipe carries an `equipment:SLOT:DEF` segment.
- **Activated powers reuse the ally-power path** (`use_ally_power` / `_can_use_ally_power` / `_resolve_use_ally_power`), now generalized to accept a source in `ally_row` OR `hero_row`. Equipment has no summoning sickness. A power's optional 7th recipe field is an `EXTRACOST` token; `exhaust_hero` (Mooncloth Robe) requires a ready hero at validation and exhausts it at resolution alongside the activate (exhaust-self). New `draw` effect draws `AMOUNT` cards.
- **Slot uniqueness (414.3):** at most one equipment per slot. `_check_equipment_uniqueness` fires after an equipment enters play; a second same-slot equipment sets `pending_equip_sacrifice_player`/`_ids` and emits `equipment_sacrifice_required`. Resolve via `StackResolver.choose_equipment_sacrifice()` (called directly, not through the stack — same pattern as pet sacrifice). `can_submit` blocks everything else while pending. Note: with only one Chest card in the pool this can't yet trigger in a real game — it's covered by a headless test.
- **UI:** `input_router` `_action_type_for` maps Equipment → `play_equipment`; the context-menu "Activate Power" entry now covers hero_row equipment; equipment-sacrifice mode mirrors pet-sacrifice mode (red highlight, `start_equipment_sacrifice_mode`). `playtest.gd` handles `equipment_sacrifice_required` (AI keeps highest-cost) and the pass button shows "Destroy equipment". Hero_row rendering already spreads non-hero cards, so equipment displays with no renderer changes.
- **AI:** BaseAI now generates `play_equipment` (via `_action_type_for`) and equipment activated powers (`_get_ally_power_actions` scans hero_row too). The `draw` power is skipped when the hand is already full. This is simple-heuristic level (FullRandomAI picks among legal actions; GenericAI still prioritizes safe kills first) — the AI plays the robe and may draw with it, but doesn't reason about hero-exhaust tempo. Covered by `_test_ai_plays_equipment`.
- Tests: `_test_mooncloth_robe_power`, `_test_mooncloth_robe_hero_exhausted`, `_test_equipment_slot_uniqueness` in `test_scenarios.gd`.

### Armor damage prevention (rule 304.3) — "block"

Block is committed BEFORE damage resolves (declared-pool model), not as an interrupt:

- **Action `use_armor_prevention`** (`{card_id}`): exhaust a ready armor with DEF > 0 (hero_row, no summoning sickness). Exhaust happens at **submission** (cost); resolution adds DEF to `PlayerState.damage_prevention` ("current block") and emits `armor_prevention_used`.
- **Legality** (`_can_use_armor_prevention`): priority + damage actually incoming — a combat window / protect point is open OR the chain is non-empty (responding to a damage effect like Quick Strike). Armor prevents effect damage too, including enter-play targeted damage (Taz'dingo): a `choose_enter_play_target` link on the chain aimed at our hero counts as incoming (`has_incoming_hero_damage` + the AI's `_incoming_hero_damage`), and the `pending_enter_play_effect` blanket guard in `can_submit` exempts `use_armor_prevention` once the choice is announced on the chain (`_enter_play_choice_on_chain`). Test: `_test_pads_block_enter_play_damage`.
- **Consumption:** `GameLogic.deal_damage` — if the target is the controller's **hero** (allies are never protected), the pool absorbs first (`damage_prevented` event), remainder is placed.
- **Expiry:** `_clear_damage_prevention` at combat conclusion (both branches), at `priority_window_closed`, and at turn start (`_enter_ready`) — unspent block never carries over.
- **AI heuristic** (`BaseAI.armor_prevention_action`, runs before combat-instant ambush in all AIs): `incoming = damage aimed at our hero − current pool` (combat: attacker ATK when our hero is `combat_defender`; chain: opposing damage actions targeting our hero). Exhaust the highest-DEF ready armor for which `incoming >= DEF − 1` (avoids wasting big armor on chip damage); one armor per priority pass, re-evaluated each time (6 incoming vs DEF 3 + DEF 1 → uses both).
- **UI:** armor highlights green when block is legal; left-click submits the block directly; context menu shows "Exhaust to prevent N damage".
- Tests: `_test_pads_block_combat`, `_test_pads_block_instant`, `_test_pads_overblock_expires`, `_test_ai_armor_block_heuristic`.

### Weapons & striking (rules 303, 602.1, 602.3) — hero combat

First cards: **Krol Blade** (`azeroth_331`, Weapon—Sword, Melee 1H, 3 ATK, strike cost 1, vanilla) and **Gorebelly** (`azeroth_9`, Horde Warrior hero, 30 HP, flip: pay 1 → next melee strike this turn costs 3 less).

- **Recipe:** `equipment:melee_weapon:0|weapon:STRIKE_COST`. Weapons play via the normal `play_equipment` path into the hero row; slot uniqueness reuses `_check_equipment_uniqueness`.
- **Strike points (don't use the chain):** striking is legal at exactly two moments — as the combat step starts, for the **attacking** player (602.1: in `_resolve_propose_combat`, after the attacker exhausts, BEFORE the attack window opens) and as the defender enters combat, for the **defending** player (602.3: in `_open_defend_window`, after the protect point, BEFORE the defend window). If the wielder is a hero whose controller has a ready, affordable weapon (`get_strikeable_weapons`), `pending_strike_player/_weapon_ids/_side` are set and `strike_point_opened` fires; `can_submit`/`pass_priority` hard-block while pending. The scene resolves via `StackResolver.choose_strike(state, weapon_id, db)` (direct call, like `choose_protector`; `""` = decline). The strike exhausts the weapon + pays strike cost (`weapon_struck` event), then the held window opens.
- **Strike modifier (303.2b):** `GameState.combat_struck_weapons` (wielder → weapon ids) feeds `get_atk` live (+weapon ATK, never cached); cleared in `_do_combat_conclusion` (303.2a). Only heroes are wielders; the hero may be exhausted; one weapon per combat (303.2c). A defending hero that strikes deals combat damage back (Long-Range attackers still zero it).
- **Legal attackers:** the `get_legal_attackers` 0-ATK hero gate now also admits a hero with an affordable strikeable weapon — so a hero is an available attacker only when the strike is actually payable (opponent resources are public, so AI forecasting works both ways).
- **Gorebelly flip** (`melee_strike_discount:3`): sets `PlayerState.melee_strike_discount`; `get_strike_cost` applies it to Melee weapons; consumed by the next melee strike, cleared at every turn start. AI only flips when net save > 0 and the discounted strike is payable (`_strike_discount_worth_it`) — never with Krol Blade (strike 1).
- **AI** (`BaseAI.choose_strike_weapon`, called by the scene/sim on `strike_point_opened`): attacking → always strike with the highest-ATK offered weapon; defending → strike when the counter-damage kills the attacker OR the attacker is the opponent's LAST legal attacker (nothing left to save it for), hold otherwise; never strike defensively vs Long-Range. `BaseAI.forecast_atk` (get_atk + best strikeable weapon) feeds attack proposals, `combat_trade_value`, and `find_safe_lethals` on both sides.
- **UI (playtest.gd):** strike point mirrors the protect point — inline buttons over the pass bar ("WeaponName (+ATK, cost)" / "Don't strike"), weapon highlighted and clickable; `_drain_passes`/`_schedule_next_turn` stall while `pending_strike_player`/`_in_strike_mode`.
- Tests: `_test_weapon_attack_strike`, `_test_weapon_defend_strike`, `_test_strike_gates_and_gorebelly_discount`, `_test_ai_strike_decisions`.

---

## Hotseat / Duel Table (playtest.gd)

Two humans on one screen: menu Player 2 type "Human (hotseat)" (both human ⇒ `_hotseat`).
`_local_player` is the seat the screen belongs to — hand visibility (`BoardRenderer.set_perspective`
+ `refresh_hand_visibility`) and input (`InputRouter.setup`) follow it; every formerly
p1-hardcoded UI/turbo/wrap-up check in playtest.gd now uses `_local_player` (so a single
human can also sit in the p2 seat vs an AI).

- **Rotating camera (TTS-style):** the board is world-space seen through `_camera`
  (Camera2D, `ignore_rotation = false`); ALL UI lives in the `_hud` CanvasLayer (layer 10)
  and never rotates. `_orient_camera(pid, animate)` turns the view 180° about
  `BOARD_PIVOT` (960,475) for the p2 seat (rotated camera pos = `2*PIVOT − (960,540)`).
  Called from `_begin_handoff` (animated, while the overlay is up), `_set_local_player`,
  and game setup (a single human seated at p2 vs AI gets the flipped view all game).
  `BoardRenderer.view_rotation_degrees` mirrors the camera so transient world overlays
  (targeting cursor, floating damage/heal numbers) counter-rotate and drift up-screen;
  the Alt+hover inspector lives in its own CanvasLayer (15). **Mouse → world must be
  camera-aware:** `CardNode` uses `get_global_mouse_position()`, `BoardRenderer` (extends
  Node, not CanvasItem) uses `_world_mouse()`; never use the raw viewport mouse position
  for world positions. New UI elements go in `_hud` (`_add_label(..., hud=true)`), new
  board elements in the scene root.
- **Handoff timing:** in hotseat the handoff fires at the START of the outgoing player's
  end phase (`phase_changed` → "end"), so the incoming player gets the wrap-up priority
  window (instants with leftover resources) plus their ready/draw on their own screen.
  `_stop_for_end_window` (set on confirm) keeps Turbo from auto-passing that window;
  cleared on their pass or the next phase change. If the outgoing player is over max
  hand size (wrap-up discard needs THEIR hand, rule 503.2a), the end-phase handoff is
  skipped and the `turn_changed` handoff below covers the switch instead. Ctrl+Enter
  is an alias for Ctrl+Space (wrap up / end turn).
- **Handoff:** on `turn_changed` to the other human, `_begin_handoff` hides BOTH hands
  (perspective sentinel `"__handoff__"` matches neither hand zone), sets `_handoff_pending`
  (blocks `_try_pass`, `_schedule_next_turn`, `_drain_passes`, `_maybe_turbo_pass`,
  `_do_ai_turn`, `_do_turbo_pass`, all key input; `CardNode.input_blocked` blocks clicks)
  and shows a fullscreen confirm overlay. Confirming runs `_set_local_player` then resumes.
- **Mulligan:** humans decide sequentially, each behind their own handoff
  (`_mulligan_queue` / `_advance_mulligan_queue`; `_mulligan_current` owns the panel).
- **Combat stance (per-player, set while seated; toggle next to Speed Mode):**
  `"passive"` — the off-screen player's priority windows auto-pass, driven by
  the same paths that drive AI (`_do_ai_turn` null-AI branch, `_drain_passes` hotseat
  branch). `"ambush"` (default) — a window STOPS when the off-screen player has a legal instant
  response (`_offscreen_has_play` probes the router with `local_player` swapped):
  `_enter_ambush_mode` points the InputRouter at them (rules make only instant-speed
  plays legal off-turn) with YELLOW highlights (`AMBUSH_HIGHLIGHT`), while the renderer
  perspective stays with the seat — their hand stays face-down, a playable card's front
  shows only while hovered (`_on_card_hover_scene`). The stop covers combat windows AND
  the CHAIN-response point right after a combat proposal (before the attack window) —
  where Litori's freeze / Exhaustion can still fizzle the proposal via the 601.3 recheck.
  Critical guard: the ambush stop re-points the router at the responder DURING the
  submission's own event emission, so `InputRouter._pass_own_proposal` also checks
  `action.source_player != local_player` — without it the proposer's auto-pass fires
  through the re-pointed router, spends the responder's priority, and resolves the
  proposal unanswered. The top-right **Skip button**
  (visible only during the stop) passes for them without revealing anything. Windows
  with no legal response still auto-skip. Mode exits when priority leaves the ambusher
  (`_refresh_ui` guard) or on Skip; `_drain_passes`/`_schedule_next_turn` freeze while
  `_in_ambush_mode`. `_stance` survives rematches.
- **Discard peek mode:** when the OFF-SCREEN human owes a mandatory discard (Mias
  the Putrid / Hypnotic Blade), `_handle_discard_choice` calls
  `_enter_discard_peek_mode(player)` before `start_discard_mode`: the router is
  pointed at the discarding player (their hand highlights red and clicks discard
  for them) while the renderer perspective stays with the seat — their hand stays
  face-down, the hovered card alone shows its front (same peek as ambush mode,
  social contract). `_try_pass` is hard-blocked while peeking (the seated player's
  Space must not act through the re-pointed router); `_drain_passes` /
  `_schedule_next_turn` / `_maybe_turbo_pass` already stall on
  `pending_discard_count`. Exits via `_on_discard_mode_ended` → `_exit_discard_peek_mode`
  (router back to `_local_player`, hand visibility re-hidden).
- **Hand hover magnify:** the local player's own hand cards scale ×1.2 (`HOVER_MAGNIFY`
  on top of `HAND_CARD_SCALE`) + z-bump while hovered; hover/unhover signals are wired
  in `_spawn_card_node`.
  Protect / strike / ready points are board-public and still stop for the choice inline.
  Known v1 limits: a totem trigger owned by the off-screen player is resolved on the
  shared screen (social contract).
- `_played_this_action_phase` is a per-player Dictionary (was `_p1_played_this_action_phase`).

---

## Card muting (auto-pass convenience — InputRouter.muted_ids)

Any of the local player's cards can be **muted** via the right-click context menu
("Mute (don't hold priority windows)" / "Unmute"). Muting is pure UI state
(`InputRouter.muted_ids`, instance_id-keyed, cleared on a new game, shared by both
hotseat seats) — the card stays fully playable and keeps its green highlight, but
`has_any_legal_play(true)` (the `exclude_muted` variant used by Turbo layer 3 in
`_drain_passes` and the hotseat ambush stop `_offscreen_has_play`) ignores it, so a
muted card alone never holds a priority window open. Use case: an always-completable
cost-only quest or a power the player never intends to fire at instant speed otherwise
forces a "Skip" click at every window. The player can still play a muted card during
standard windows, or in any priority window another (unmuted) card keeps open.
`toggle_mute` is a context-menu pseudo-action handled in `handle_context_action`
(never submitted to the engine); `card_mute_changed` drives a 🔇 badge on the
CardNode (`set_muted`). The pass-button label (`_update_pass_btn`) still counts muted
cards as legal plays. Muting follows the instance across zones (mute a quest in hand,
it stays muted in the resource row).

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
- **Symmetric board (all modes, incl. vs AI):** each player's hero/deck/graveyard column
  sits on THEIR right-hand side — P1 at screen-right (deck x=1820, grave x=1640,
  hero_card (1820,620)), P2 at screen-left (deck x=100, grave x=280, hero_card (100,280)).
  The game log is a HUD overlay on the left gutter (covers P2's column), hidden by
  default — L toggles it.
- **Card facing (all modes):** cards in `p2_*` zones render rotated 180° (facing P2,
  TTS-style). `CardNode.facing_degrees` is the base every rotation write composes with:
  exhaust = facing+90, ready/settle = facing. Facing is set from the zone prefix in
  `place_card_in_zone`, `_animate_move` (side change = control change), and
  `reconcile_from_state` (`BoardRenderer._facing_for_zone`). Never write a card's
  `rotation_degrees` with a bare 0/90 — always compose with `facing_degrees`.
  The hero HP bar follows the same facing: P2's bar is rotated 180° about its own
  center (`_ensure_hero_bar`), so its label/fill read upright for P2.
- Pass button shows **"Sacrifice a pet [Space]"** (disabled, no color change) when `pending_pet_sacrifice_player == "p1"`.

---

## Known open issues / next work

- **Combat window AI:** the non-turn AI now plays tagged **combat instants** (Quick Strike) during attack/defend windows via `BaseAI.combat_instant_action` — see AI conventions above. It still never uses ally activated powers (e.g. Grimdron) to counter-attack during enemy combats. Future: extend the window logic to defensive ally-power plays.
- **Next cards to implement:** Check `data/cards.csv` for candidates.
- **`logic/BasicAI_behavior.txt` is legacy** and may be stale — actual AI is fully in `game_logic/ai/base_ai.gd`.
