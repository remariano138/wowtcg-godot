# AI helper functions (game_logic/ai/)

Reusable targeting/evaluation primitives for AI players. Any new AI helper
that is meant to be shared across call sites should be documented here.

---

## `BaseAI.find_lethal(state, db, player_id, damage) -> Array[String]`

*Static — callable without a BaseAI instance (e.g. from playtest.gd).*

Returns the list of **opposing in-play characters** that would die to
`damage` points of damage, i.e. `current HP <= damage`.

**Hero shortcut:** if the opposing **hero** is lethal, the function returns
**only** `[hero_instance_id]` — regardless of how many allies are also
lethal. Killing the hero wins the game, so the AI should never "do something
stupid" like killing an ally instead. Callers can rely on this: a returned
list containing the hero always has size 1.

Other properties:

- `damage <= 0` returns `[]`.
- Only characters controlled by `player_id`'s opponent are considered
  (the AI never self-targets for damage).
- Order: hero (alone) or allies in `ally_row` order.
- Does **not** check submission legality — callers must still filter with
  `StackResolver.can_submit` (e.g. Elusive-style restrictions on the
  specific effect).

**Call sites:**

| Where | Use |
|---|---|
| `base_ai.gd` → `_best_damage_target` | Priority 0: lethal-on-hero shortcut for the heuristics built on it (Radak sacrifice, damage+heal powers). |
| `base_ai.gd` → `_get_hero_power_actions` (generic single-target branch) | Damage powers like Ta'zo's `deal_damage_to_target`: when any legal target is lethal, ONLY lethal-target actions are returned — so even FullRandomAI picks a kill (the hero alone if the hero is lethal). |
| `base_ai.gd` → `_get_ally_power_actions` | Targeted ally powers (Grimdron): lethal candidates are tried first, then most-damaged order. |
| `renderer/tests/playtest.gd` → `_handle_enter_play_target` | AI choice for enter-play targeted damage (Taz'dingo-style): picks among lethal targets first, random legal target otherwise. |

---

## `BaseAI.sort_valuable_cards(state, db, card_ids, bonus = {}) -> Array[String]`
## `BaseAI.card_value_score(state, db, cid) -> float`

*Static — callable without a BaseAI instance.*

Sorts a list of card **instance ids** from most valuable to least. Returns a
new array; the input is not mutated. Intended as a generic building block —
e.g. fed the output of `find_lethal`, or a graveyard list.

The primary criterion is the numeric **`card_value_score`**:

```
score = cost + rarity + 0.2 * (ATK + HP)
rarity: Common 1, Uncommon 2, Rare 3, Epic 4 (unknown/blank = 1)
```

Non-allies contribute no ATK/HP term (so a hero's 30 HP doesn't dominate,
and an ally outscores an equal-cost spell). The optional `bonus` argument is
a `{card_id: float}` map of situational score adjustments — callers can say
"in this context, these specific cards are worth +1" without touching the
base formula.

Remaining score ties break lexicographically:

1. **Ally before non-ally** (allies are easier for the AI to play).
2. **Protector** first, then **HP**, then **Ferocity** (can strike
   immediately if reanimated), then **Elusive**, then **ATK**.
3. **Random** — remaining ties are shuffled.

HP and ATK are resolved **per card**: current values
(`get_current_hp`/`get_atk`, buffs and damage included) when the card is in
play — killing a 3-HP-left target beats killing a 1-HP-left one — printed
values when it isn't (graveyard, hand). Mixed-zone lists are handled
correctly. Rarity, cost, and keywords always come from the CardDef.

**Call sites:** `FullRandomAI.rank_lethal_targets` (below);
`GenericAI.choose_discard_card` (least valuable = last entry),
`GenericAI._decide_resource_placement` (least valuable face-down),
`GenericAI._choose_graveyard_targets` (most valuable, least for own-RFG
costs), `GenericAI._safe_lethal_action` (attacker/target ranking).
Deck-specific AIs are free to use a better heuristic instead.

### Related instance hooks on BaseAI

- **`choose_discard_card(state, db, player_id) -> String`** — one card id per
  call when the player must discard; the scene (playtest.gd) invokes it for
  AI players. Base: lowest-cost non-quest/location. GenericAI: least valuable.
- **`_choose_graveyard_targets(state, db, player_id, gy_req, candidates)`** —
  targets for graveyard-reward quests. Base: highest-cost to hand /
  lowest-cost to own RFG. GenericAI: value-sorted as above.

---

## `BaseAI.find_safe_lethals(state, db, attackers, defenders) -> Array`

*Static — callable without a BaseAI instance.*

Cross-checks two lists of character instance ids and returns every
`[attacker_id, defender_id]` pair where the attacker **kills and survives**:

- attacker current ATK **>=** defender current HP, **and**
- attacker current HP **>** defender current ATK.

Pure math — it does NOT check combat legality (Elusive defenders, Sarmoth
taunt, exhaustion, summoning sickness). Callers must validate the chosen
pair with `StackResolver.can_submit` / `get_legal_defenders` and fall
through to the next pair on failure. Current values work for hand cards too
(they resolve to printed stats + any buffs), which is what allows Ferocity
allies in hand to be scanned as potential attackers.

**Call sites:**

| Where | Use |
|---|---|
| `generic_ai.gd` → `_safe_lethal_action` | list 1 = legal board attackers + playable Ferocity allies in hand; list 2 = enemy board allies. Attackers ranked by `sort_valuable_cards`, committed least-valuable-first (bait removal with the cheap attacker; valuable pieces — later, heroes — go in last). The chosen attacker kills its most valuable safe target. Re-runs every priority window. |

---

## `BaseAI.combat_trade_value(state, db, c1, c2) -> String`

*Static — callable without a BaseAI instance.*

Classifies a would-be combat from **c1's** point of view, pure ATK/HP math
(symmetric damage, no Ranged/Long-Range or legality check — same contract as
`find_safe_lethals`). `c1 kills c2 = c1.atk >= c2.hp`; `c1 survives =
c1.hp > c2.atk`. Returns one of:

- `"safe_lethal"` — c2 dies, c1 survives
- `"both"` — both die
- `"suicide"` — only c1 dies
- `"no_one"` — neither dies (this is also what attacking a 0-retaliation hero
  returns, which is why hero attacks are a *separate* acceptance rule, not a
  trade outcome)

`c1_is_attacker` (default `true`) marks which side is the attacker, so "while
attacking" bonuses (Zorm / Rayder / For the Horde!) are forecast onto the right
side only — exactly one side attacks, and the defender never gets them. This
matters during **planning** (before `propose_combat`), where `combat_attacker`
is unset so plain `get_atk` would omit the bonus and the AI would under-rate its
own attackers. On offense `c1` is our attacker (default). For a Protector, `c1`
is our defending protector and `c2` the incoming attacker → pass
`c1_is_attacker=false`. `find_safe_lethals` applies the same forecast to its
attacker side.

Otherwise ownership-agnostic.

**Call sites:** `GenericAI._trade_action` (accepts `"both"` only, on offense);
`GenericAI.choose_protector` (used only in the "proposed defender survives,
neither dies" branch, to protect solely with a `safe_lethal` protector — see
ai_roster.md for the full proposed-fight decision).

---

## `GenericAI.decide_action` pipeline *(no random fallback)*

GenericAI is fully deterministic — it does **not** fall through to
FullRandomAI. `decide_action` returns ONE action per priority call; the engine
resolves it and calls again, so a turn plays out step by step. Order:

1. `combat_instant_action` — inherited defensive plays, legal even on the
   opponent's turn. (Armor prevention is no longer a priority-window action:
   the scene/sim calls `BaseAI.choose_prevention` at the 717.2c prevention
   point instead.)
2. (own action window only, else `null` — no random responses)
3. `_hero_lethal_action` — win now.
4. `_safe_lethal_action` — kill an ally and survive.
5. `_trade_action` — a `"both"` trade, but only **value-even-or-up**
   (`_card_value_key(attacker) <= _card_value_key(target)`); never trades a
   bomb for a chump. Picks the most valuable target, gives up the least
   valuable attacker. Enemy allies only (hero handled below).
6. `_develop_action` — best board-improving non-combat play: reuses
   `get_reasonable_actions` (which already gates powers/removal/draw/resource) minus
   every `propose_combat`, ranked by `_DEVELOP_RANK` then card value.
7. `_hero_chip_action` — poke the enemy hero with leftover ready attackers
   (ATK > 0 only). Holds **Protectors** back to defend unless the enemy hero is
   at/under `HERO_ALL_OUT_HP` (10), then goes all out. Chips least-valuable
   attacker first.
8. `null` — end the turn.

**Termination:** every action consumes a finite per-turn resource (attacker
readiness, a hand card, resources, the once-per-turn resource flag) and never
restores one, so the option set strictly shrinks to step 8 — no infinite loop.
Combat is re-checked from the top after each develop, so a freshly played
Ferocity attacker or buff can open a new fight on the next call.

---

## `rank_lethal_targets(state, db, lethal) -> Array[String]` *(instance hook)*

Called wherever a `find_lethal` pool is about to be consumed, letting each AI
subclass decide how to order the kills (or whether to bother):

- **BaseAI** — returns the pool unchanged (hero first, then ally_row order).
- **FullRandomAI** — returns `sort_valuable_cards(pool)`: always kills the
  most valuable target.

Consumers take the **front** of the returned list: the hero-power lethal
branch, the ally-power lethal branch, and `_handle_enter_play_target` in
playtest.gd all commit to `ranked[0]`.

---

**Not** routed through `find_lethal`: targeted damage instants
(`_targeted_instant_actions` still enumerates all targets), destroy effects
(lethality-by-damage doesn't apply), and Dizdemona's `deal_x_damage_to_ally`
(ally-only by card text; has its own lethal-first sort).

---

## `BaseAI.COMBAT_INSTANT_TAGS` + `combat_instant_action(state, db, player_id) -> PendingAction`

**Held cards / ambush system.** `COMBAT_INSTANT_TAGS` is a dict keyed by
`card_def_id` tagging cards the AI must **hold in hand** instead of
blind-playing on its own action window (`get_reasonable_actions` skips them).
Current tags:

- `"combat_instant_dmg"` — instant dealing targeted damage
  (`deal_damage_to_target:N:TYPE`), e.g. **Quick Strike** (`azeroth_165`,
  cost 3, 2 melee). The card's value is the *surprise* during an opponent's
  combat, not tempo damage on your own turn.

`combat_instant_action` implements when to spring the ambush. It returns a
`play_instant` action with `target_id = state.combat_attacker` announced at
submission, or `null`. Gates:

- A combat **attack or defend window** is open, chain empty, no pending
  enter-play choice.
- Only the player **being attacked** (controller of `state.combat_defender`)
  ever plays it — the attacking side never ambushes its own combat.
- **Attack window:** `attacker_hp <= dmg` **and** `attacker_cost >= card_cost`
  — kill the attacker before it even forces a protect, unless it's a cheap
  bait not worth the card.
- **Defend window:** `attacker_hp <= defender_atk + dmg` **and**
  `attacker_hp > defender_atk` **and** `attacker_cost >= card_cost` — only
  if it finishes something the defender alone wouldn't kill.

**Targeting:** announced at play time, like all targeted instants — the AI
always targets `state.combat_attacker`; humans use the standard cancellable
targeting flow (`input_router.start_targeting`).

**Call sites:**

| Where | Use |
|---|---|
| `base_ai.gd` → `decide_action` | The base AI's only proactive play — every subclass inherits the ambush. |
| `full_random_ai.gd` → `decide_action` | Checked FIRST, before any random pick — the ambush is deterministic, never left to the dice. |
| `generic_ai.gd` → `decide_action` | Also checked first (step 1 of its pipeline); GenericAI calls `combat_instant_action` directly, not via `super` — it has no random fallback. |

Tests: scenario 34 in `game_logic/tests/test_scenarios.gd`.

## `BaseAI.evasion_action(state, db, player_id) -> PendingAction`

**Blink dodge** (`azeroth_48`, tagged `"combat_instant_evasion"` — held, never
blind-played for the draw). Plays Blink during the **defend window** only (the
removal clause needs the hero to actually BE defending — 602.3; in the attack
window it would be a pure cantrip), with an empty chain, when the AI's **hero**
is `combat_defender` and the dodge is worth the card: incoming attacker ATK
(with "while attacking" bonuses) **> 3**, or the hero is **below 10 HP** (any
hit matters when low). Wired into all three AIs' `decide_action`, after
`instant_protector_action` / before `bear_form_action`. Future ally-saving
evasion cards will need a value comparison (dying ally vs the evasion card)
instead of the hero gates.

Tests: `_test_ai_blink_evasion`.

## `BaseAI.bear_form_action(state, db, player_id) -> PendingAction`

**Bear Form flash-in** (`azeroth_18`, tagged `"combat_instant_bear_form"` —
held, never blind-played). Plays Bear Form during the **attack window** of a
combat where the AI is being attacked, so its hero is a legal protector at the
following protect point (the normal `choose_protector` then decides whether the
hero actually steps in). Gates: attack window open with an empty chain, we
control the defender, the attacker's forecast ATK > 0, our hero is **ready**
(an exhausted hero can't protect), the hero is **not already in bear form**
(no in-play Form of ours carrying `hero_has_protector`), and no board
protector already answers the attack (`choose_protector == ""`). Wired into
all three AIs' `decide_action`, after `instant_protector_action`.

Related Form behaviors:

- **Bash** (`azeroth_17`) is tagged `"combat_instant_exhaust"` — same role and
  worth math as Exhaustion in `exhaust_attacker_action`, but because its
  recipe is `exhaust_target:hero_or_ally` it also answers an attacking
  **hero** (ally-only Exhaustion is skipped for hero attackers via
  `_exhausts_heroes`). Action type comes from `_action_type_for` (Bash is an
  ongoing Instant Ability → `play_ability`).
- **Claw** (`dark_portal_20`) is tagged `"combat_instant_dmg"` — standard
  ambush math in `combat_instant_action` (action type `play_ability`); the cat
  form ongoing it leaves behind is a free rider the AI doesn't model.
- **Cat Form** (`dark_portal_19`) is untagged — GenericAI plays it in its
  develop step; the hero then shows up in `get_legal_attackers` (the engine
  gate probes `get_atk(hero, db, true)`).
- **Hero-attack policy** (`get_reasonable_actions`): a HERO attack on an enemy
  **ally** is offered only when the forecast ATK kills it — a hero swinging
  into an ally it can't kill soaks retaliation for nothing. Attacks on the
  enemy hero are always offered.
- `BaseAI.choose_form_return` always pays the 2 (the engine only opens the
  choice when affordable).

Tests: the Forms block in `game_logic/tests/test_scenarios.gd`
(`_test_ai_bear_form_flash_in`, `_test_ai_bash_freezes_attacking_hero`,
`_test_ai_hero_attack_lethal_gate`, `_test_ai_claw_ambush`).

**Ravenous Bite ATK swing** (`azeroth_44`, tagged `"combat_instant_atk_swing"` —
held, never blind-played; off combat the swing expires the same turn and changes
nothing). `BaseAI.atk_swing_action`, wired into all three `decide_action`s after
`evasion_action`. Played on an open attack/defend window from EITHER side of the
combat (unlike the damage ambush, which is defender-only — a +3 pump is at its
best on our own attacker).

HARD GATE: the -3 must land on the OPPOSING character in this combat, and that
character must be an ALLY. Both halves target allies, so with no enemy ally in
the fight (an enemy HERO attacking our ally, or our ally attacking their hero)
the shrink would be forced onto our own board — a wasted card at best, and a
net-zero double-pick on the same ally at worst. There, we never play it.

With the shrink settled, we spend the card only when it FLIPS the fight:
  - saves our character that would otherwise die  (their ATK - 3 < our HP), or
  - kills theirs when ours alone wouldn't          (our ATK + 3 >= their HP)
plus the usual economy gate — the ally saved or killed must cost at least as
much as the spell.

The +3 goes on our own combatant when that's an ally. When our HERO is the one
fighting there's no legal pump target on it, so the pump is a dump onto our
highest-ATK ally (`_best_pump_ally`) and we only buy the card to stop a hit the
hero can't take (their ATK >= hero HP, and the shrink actually saves it); with
no ally of our own to receive the pump, we hold.

Not modeled: Long-Range (no retaliation), a protector swapping in later, and the
pump's value on a future attack.
