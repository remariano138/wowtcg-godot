# Project context

This is a digital implementation of a simplified WoW TCG ruleset.
Always check `References/wow_rules.txt` before implementing any
keyword or card effect — do not rely on general CCG knowledge (Magic,
Hearthstone) since WoW TCG has its own specific rulings.

Card data lives in : `data/cards.csv`
Engine logic lives in : `scenes/boards/SandboxTable.gd` (base), `scenes/boards/DuelTable.gd` (rule overrides)

## Implementing a card — required steps

1. Find the card in `data/cards.csv` (grep by name).
2. Read the card image (path is the last column of the CSV row) to get the exact card text.
3. Confirm the card text with the user before writing any code.
4. Check `References/wow_rules.txt` for any keywords or mechanics on the card.
5. Update `data/cards.csv`: fill `power_text`, set `data_status=verified`, clear `engine_status`, add the effects recipe.
6. Implement any new engine actions needed in `SandboxTable.gd`.
7. Update `logic/BasicAI_behavior.txt` if the card introduces new AI heuristics.

## Architecture (game_logic/ rebuild)

The new engine lives in `game_logic/`. Key invariants — violating these is a bug:

- **Rules functions never touch the bus.** They return `Array[GameEvent]`. The caller
  (ultimately the stack resolver) emits. If you find a rules function calling
  `EventBus.emit_*` directly, that's wrong.
- **Rules functions never read Godot nodes.** No `get_tree()`, no autoloads, no scene
  references inside `game_logic/`. Pass `db` as a parameter when def lookups are needed.
- **Zone moves go through `GameLogic.move_card()` only.** Never mutate `zone.card_ids`
  or `card.zone_id` directly — zone-change triggers need one choke point.
- **Derived stats are never cached on CardInstance.** Call `state.get_atk(id, db)` etc.
  Caching derived values causes stale-read bugs (we had this with ATK modifiers).
- **Fold inner events:** when a rules function calls another rules function internally,
  fold the returned events in with `events.append_array(inner_call(...))`.

## Card uniqueness

WoW TCG allies are NOT unique by default. Multiple copies of the same ally
(including heroes, unless stated) can coexist in play. Do not assume a card
is unique unless its text explicitly says so or it is a Pet (Pet uniqueness
is enforced separately). Up to 4 copies of a non-unique card may appear in a deck.