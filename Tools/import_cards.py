"""
Converts the wowcards.info export format into cards.csv.
Input:  tools/raw_import.csv
Output: data/cards.csv
"""
import csv
import re
from pathlib import Path

ROOT       = Path(__file__).parent.parent
INPUT_PATH = Path(__file__).parent / "raw_import.csv"
OUTPUT     = ROOT / "data" / "cards.csv"

FIELDNAMES = [
    "expansion", "collector_number", "name", "cost", "type",
    "alignment", "tags", "atk", "dmg_type", "health",
    "rarity", "power_text", "image_path"
]

def parse_ally_subtype(subtype: str):
    """
    'Human Mage (1/1 Arcane)' -> tags='Human Mage', atk='1', dmg_type='Arcane', health='1'
    'Raptor (3/1 Melee)'      -> tags='Raptor',      atk='3', dmg_type='Melee',  health='1'
    """
    m = re.match(r"^(.*?)\s*\((\d+)/(\d+)\s+(\w+)\)\s*$", subtype.strip())
    if m:
        return m.group(1).strip(), m.group(2), m.group(4), m.group(3)
    return subtype.strip(), "", "", ""

rows = []
with open(INPUT_PATH, encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for raw in reader:
        card_type = raw["type"].strip()
        subtype   = raw["subtype"].strip()
        tags = atk = dmg_type = health = ""

        if card_type == "Ally":
            tags, atk, dmg_type, health = parse_ally_subtype(subtype)
        else:
            tags = subtype  # Hero race/class or Ability school

        rows.append({
            "expansion":        raw["edition"].strip(),
            "collector_number": raw["id"].strip().zfill(3),
            "name":             raw["name"].strip(),
            "cost":             raw["cost"].strip(),
            "type":             card_type,
            "alignment":        raw["faction"].strip(),
            "tags":             tags,
            "atk":              atk,
            "dmg_type":         dmg_type,
            "health":           health,
            "rarity":           raw["rarity"].strip(),
            "power_text":       "",
            "image_path":       "",
        })

rows.sort(key=lambda r: int(r["collector_number"]))

with open(OUTPUT, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
    writer.writeheader()
    writer.writerows(rows)

print(f"Written {len(rows)} cards to {OUTPUT}")
