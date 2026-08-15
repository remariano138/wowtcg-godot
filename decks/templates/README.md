# Deck templates

Deck **templates** are 60-card lists with **no hero** — deliberately illegal
decks (rule 100.1) meant as a starting point for building a real deck: take a
template, pick a hero, and swap the flexible slots for hero-class cards.

- **Not scanned by `DeckLibrary`.** `decks/templates/` is deliberately absent
  from `DeckLibrary.scan()`, so templates never appear in the playtest menu and
  `DeckManager.load_deck()` never sees one. That is what lets them omit the
  hero: `validate_deck` requires a hero and would reject them.
- **To use one:** copy the JSON into `decks/custom/`, give it a new `deck_id`
  (= filename stem), a `display_name`, and a `hero_card_def_id`. Then run
  `game_logic/tests/test_deck_manager.gd` — it authorizes every shipped deck,
  so faction/class/Talent/4-copy problems fail there rather than at the menu.
- **Same file format and same conventions as a real deck list**, including the
  `card_entries` ordering (Quests → Equipment → everything else; within each
  block rarity Epic → Rare → Uncommon → Common, then cheapest cost first) and
  the `_card_name` comment fields. New template files are plain UTF-8, no BOM.

## Templates

| File | Theme |
|---|---|
| `horde_exhauster.json` | Horde tempo: exhaust the opponent's board and punish exhausted characters (Bala Silentblade, Ghank, Voss Treebender). Orc/Tauren-leaning ally base. |
