"""
Fills the 'subtype' column in cards.csv.

Current logic (Azeroth set only):
  - Allies in the class range whose tags contain no known race word → subtype = "Pet"
  - All other cards → blank for now

WARNING: This heuristic relies on two assumptions that may not hold for future expansions:
  1. Class-specific allies (pets, demons) are grouped in the same collector ranges as abilities.
     Future expansions may not follow this structure.
  2. Race detection uses a fixed list of Azeroth-era races.
     Future expansions may introduce new races (Draenei, Worgen, Goblin, Pandaren, etc.)
     that must be added to KNOWN_RACES before running this script on those sets.
  → When adding a new expansion: review its structure manually before running.
"""

import csv
import re
from pathlib import Path

ROOT      = Path(__file__).parent.parent
CARDS_CSV = ROOT / "data" / "cards.csv"

# Races present in the Azeroth base set
# NOTE: expand this list when adding new expansions
KNOWN_RACES = {
    "Human", "Orc", "Troll", "Tauren", "Dwarf",
    "Gnome", "Elf", "Undead", "Blood", "Night",
}

# Class-section collector ranges per expansion (same as DeckManager.gd — keep in sync)
# NOTE: when adding expansions, add their ranges here AND in DeckManager.gd
CLASS_RANGES = {
    "azeroth": [(17, 31), (32, 46), (47, 61), (62, 75),
                (76, 90), (91, 105), (106, 119), (120, 134), (135, 149)],
}

def in_class_range(expansion: str, collector: int) -> bool:
    for start, end in CLASS_RANGES.get(expansion, []):
        if start <= collector <= end:
            return True
    return False

def tags_contain_race(tags: str) -> bool:
    words = {w.strip() for w in tags.replace(",", " ").split() if w.strip()}
    return bool(words & KNOWN_RACES)

def get_subtype(row: dict) -> str:
    if row["type"] != "Ally":
        return ""
    expansion = row.get("expansion", "").strip()
    collector = int(row["collector_number"])
    if not in_class_range(expansion, collector):
        return ""  # faction ally — no subtype yet
    if tags_contain_race(row.get("tags", "")):
        return ""  # race-class ally in class range (edge case, shouldn't exist in Azeroth)
    return "Pet"

rows = []
with open(CARDS_CSV, encoding="utf-8") as f:
    reader = csv.DictReader(f)
    fieldnames = list(reader.fieldnames)
    if "subtype" not in fieldnames:
        idx = fieldnames.index("class") + 1
        fieldnames.insert(idx, "subtype")
    for row in reader:
        row.setdefault("subtype", "")
        if not row["subtype"]:  # don't overwrite manually set values
            row["subtype"] = get_subtype(row)
        rows.append(row)

with open(CARDS_CSV, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

pets = [r for r in rows if r["subtype"] == "Pet"]
print(f"Pets found: {len(pets)}")
for p in pets:
    print(f"  [{p['expansion']}-{p['collector_number']}] {p['name']} ({p['tags']}) — class: {p['class']}")
