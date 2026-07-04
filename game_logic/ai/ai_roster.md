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

**decide_action behaviour:**
- On its own action window, first scans for **safe kills** via
  `BaseAI.find_safe_lethals` (see `ai_functions.md`): board attackers plus
  playable Ferocity allies in hand, against all enemy board allies.
  Commits the least valuable attacker first (bait), against its most
  valuable safe target; hand Ferocity allies with a safe kill are played
  immediately so they can attack. Recomputed every priority window, so safe
  kills chain one at a time.
- No safe kill → falls back to FullRandomAI behaviour (random legal action,
  random responses).

**Value-based choices** (all via `BaseAI.sort_valuable_cards`):
- **Discard** (`choose_discard_card`): discards the LEAST valuable hand card.
- **Resource placement**: quests still go face-up first; otherwise the LEAST
  valuable hand card is placed face-down.
- **Graveyard selections** (`_choose_graveyard_targets`): picks the MOST
  valuable candidates (bring back your best / remove the enemy's best) —
  except removing your OWN cards from the game (Darrowshire-style cost),
  which takes the least valuable.

All demo decks (and the DeckManager fallback profile) now use GenericAI.
