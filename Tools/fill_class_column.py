"""
Fills the 'class' column in cards.csv.

Rules:
- Heroes/Allies: class = last word of tags if it's a known WoW class
- Hunter pets (Raptor, Bear, Wolf, Cat, Chimaera) → Hunter
- Warlock demons (any tag containing 'Demon') → Warlock
- Abilities: use per-expansion collector number ranges
- Neutral abilities (no alignment, outside class ranges) → blank
"""

import csv
import re
from pathlib import Path

ROOT      = Path(__file__).parent.parent
CARDS_CSV = ROOT / "data" / "cards.csv"

WOW_CLASSES = {
    "Druid", "Hunter", "Mage", "Paladin",
    "Priest", "Rogue", "Shaman", "Warlock", "Warrior"
}

# Ranges cover ALL card types within that collector band (abilities, pets, class allies)
# Fall back to tag parsing only for cards outside these ranges (heroes, faction allies)
CLASS_RANGES = {
    "azeroth": [
        (17,  31,  "Druid"),
        (32,  46,  "Hunter"),
        (47,  61,  "Mage"),
        (62,  75,  "Paladin"),
        (76,  90,  "Priest"),
        (91,  105, "Rogue"),
        (106, 119, "Shaman"),
        (120, 134, "Warlock"),
        (135, 149, "Warrior"),
    ]
}

def get_class(row: dict) -> str:
    card_type = row["type"]
    expansion = row.get("expansion", "").strip()
    collector = int(row["collector_number"])

    if card_type == "Ability":
        # Abilities always use ranges (includes class-specific pets in same range band)
        for start, end, cls in CLASS_RANGES.get(expansion, []):
            if start <= collector <= end:
                return cls
        return ""  # neutral ability, no class

    if card_type == "Ally":
        # Class-section allies (pets etc.) use ranges
        for start, end, cls in CLASS_RANGES.get(expansion, []):
            if start <= collector <= end:
                return cls
        # Faction allies (outside ranges) carry their class in tags: "Race Class" → last word
        tags  = row.get("tags", "").strip()
        words = [w.strip() for w in tags.replace(",", " ").split() if w.strip()]
        last  = words[-1] if words else ""
        return last if last in WOW_CLASSES else ""

    if card_type == "Hero":
        # Heroes always use tags: "Race Class" → last word
        tags  = row.get("tags", "").strip()
        words = [w.strip() for w in tags.replace(",", " ").split() if w.strip()]
        last  = words[-1] if words else ""
        return last if last in WOW_CLASSES else ""

    return ""  # Weapon, Armor, Item, Quest, Location


rows = []
with open(CARDS_CSV, encoding="utf-8") as f:
    reader = csv.DictReader(f)
    fieldnames = list(reader.fieldnames)
    if "class" not in fieldnames:
        # Insert after 'alignment'
        idx = fieldnames.index("alignment") + 1
        fieldnames.insert(idx, "class")
    for row in reader:
        row["class"] = get_class(row)
        rows.append(row)

with open(CARDS_CSV, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

# Quick sanity check
from collections import Counter
classes = Counter(r["class"] for r in rows if r["class"])
print("Class distribution:")
for cls, count in sorted(classes.items()):
    print(f"  {cls:12} {count}")
print(f"\nBlank (neutral/other): {sum(1 for r in rows if not r['class'])}")
print(f"Total rows: {len(rows)}")
