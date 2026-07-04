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

## `BaseAI.sort_valuable_cards(state, db, card_ids) -> Array[String]`

*Static — callable without a BaseAI instance.*

Sorts a list of card **instance ids** from most valuable to least, using a
simple printed-stats heuristic (no board-state awareness). Returns a new
array; the input is not mutated. Intended as a generic building block —
e.g. fed the output of `find_lethal`, or a graveyard list.

Sort order (lexicographic, each level breaks ties of the previous):

1. **Rarity** — Epic > Rare > Uncommon > Common (unknown/blank = Common).
2. **Cost** — higher first (a 4-cost spell beats a 1-cost ally).
3. **Ally before non-ally** — at equal rarity+cost, allies win (they're
   easier for the AI to play). Non-allies only rank higher via cost/rarity.
4. **Protector** first, then **HP**, then **Ferocity** (can strike
   immediately if reanimated), then **Elusive**, then **ATK**.
5. **Random** — remaining ties are shuffled.

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
