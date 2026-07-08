# AI Roster — `game_logic/ai/`

All AI classes extend `BaseAI` and implement the same interface as the human
input path — they call `StackResolver` entry points, never touch GameState
directly.

---

## BaseAI — `base_ai.gd`

Abstract base class. Not used directly in game — subclass and override
`decide_action()`.

Provides two shared utilities available to all subclasses:

- **`get_legal_actions(state, db, player_id)`** — returns every `PendingAction`
  the player can legally submit right now (hand plays + combat proposals).
  Filters out 0-ATK attackers (exhausting a character for zero damage is never
  correct; advanced subclasses may override this for tactical edge cases).

- **`choose_protector(state, db, player_id) → String`** — called by the scene
  after a `protect_point_opened` event. Returns an `instance_id` to protect
  with, or `""` to skip. Base behaviour: always skip.

---

## FullRandomAI — `full_random_ai.gd`

Picks a random legal action every time it has priority. No heuristics — pure
chaos. Useful as a stress-test opponent because it reaches edge cases a
heuristic AI never would.

**decide_action behaviour:**
- Passes immediately during ready/draw phases.
- On its own turn (chain empty): always plays something, chosen at random.
- When responding to an opponent action: includes `null` (pass) as one option
  alongside legal plays, so it responds randomly rather than always reacting.
  Plays at most one response per opponent action, then passes.

**choose_protector behaviour:**
- Builds the pool of legal protectors and appends `""` (skip) as one extra
  option. Picks uniformly at random — with 3 legal protectors there is a 1/4
  chance to just not protect at all.

---

## GenericAI — `generic_ai.gd`

Deck-agnostic heuristic AI, one notch above FullRandomAI. Profile:
`ai_profiles/ai_generic.json` (`ai_class: "generic"`).

**decide_action behaviour** — a fully deterministic priority pipeline with
**no random fallback** (see `ai_functions.md` → "GenericAI.decide_action
pipeline"). Per priority call it returns the single best action in order:
hero-lethal → safe-lethal → good trade (`both`, value-even-or-up) → develop
(board-improving non-combat play) → hero-chip (Protectors held unless the
enemy hero is ≤ 10 HP) → `null` (end turn). The engine re-invokes it after
each resolution, so a turn plays out one step at a time and combat is
re-checked after every develop. Termination is guaranteed: every action
consumes a finite per-turn resource, so the option set strictly shrinks.
Outside its own action window it makes only the inherited deterministic
defensive plays (armor block, combat-instant ambush) and otherwise passes —
no random responses.

**choose_protector behaviour:** decided from the **proposed fight** (incoming
attacker vs. the character it declared against), not the protector alone:
- Proposed defender **survives**: if the attacker would die to it → don't
  protect (free kill, let it happen); otherwise protect only with a protector
  that would **kill the attacker and live** (`safe_lethal`), else take the hit.
- Proposed defender **dies**: the **hero** → always interpose the cheapest body
  (losing it loses the game); an **ally** → interpose only a protector worth
  **less** than that ally (spend cheap fodder to save something better, never
  the reverse).

Within a chosen bucket the least valuable eligible protector is used; never
protects vs. a 0-ATK attacker. "While attacking" bonuses land on the attacker
via `get_atk(..., true)` / `combat_trade_value`.

**Value-based choices** (all via `BaseAI.sort_valuable_cards`):
- **Discard** (`choose_discard_card`): discards the LEAST valuable hand card.
- **Resource placement**: quests still go face-up first; otherwise the LEAST
  valuable hand card is placed face-down.
- **Graveyard selections** (`_choose_graveyard_targets`): picks the MOST
  valuable candidates (bring back your best / remove the enemy's best) —
  except removing your OWN cards from the game (Darrowshire-style cost),
  which takes the least valuable.

All demo decks (and the DeckManager fallback profile) now use GenericAI.
