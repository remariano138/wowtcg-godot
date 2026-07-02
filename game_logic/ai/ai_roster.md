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
