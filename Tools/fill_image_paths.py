"""
For every row in data/cards.csv with an empty image_path, looks up a matching
entry in tools/cards_master.csv by sanitized name and fills it in.
Run this after adding new cards to the database.
"""

import csv
import re
from pathlib import Path

ROOT       = Path(__file__).parent.parent
CARDS_CSV  = ROOT / "data" / "cards.csv"
MASTER_CSV = Path(__file__).parent / "cards_master.csv"


def sanitize(name: str) -> str:
    name = name.lower().strip()
    name = name.replace("'", "").replace("'", "")  # strip apostrophes before replacing separators
    return re.sub(r"[^a-z0-9]+", "_", name).strip("_")


# Load master lookup: sanitized_name -> image_path
master: dict[str, str] = {}
with open(MASTER_CSV, encoding="utf-8") as f:
    for row in csv.DictReader(f):
        master[row["name"]] = row["image_path"]

# Manual aliases: TTS mod misspellings -> correct card name key
ALIASES = {
    "nerra_lifeboon": "nerra_lifeboom",
    "valthak_spiritdrinker": "valthak_spiritdinker",
    "stronghold_gauntlets": "stronghold_guantlets",
    "raul_fingers_maldren": "raul_finger_maldren",
    "wristguards_of_the_true_flight": "wristguards_of_true_flight",
    "operation_recombobulation": "opertation_recombobulation",
}
for correct, tts in ALIASES.items():
    if tts in master:
        master[correct] = master[tts]

# Process cards.csv
rows = []
with open(CARDS_CSV, encoding="utf-8") as f:
    reader = csv.DictReader(f)
    fieldnames = reader.fieldnames
    for row in reader:
        if not row["image_path"]:
            key = sanitize(row["name"])
            if key in master:
                row["image_path"] = master[key]
                print(f"  Filled: {row['name']}  ->  {master[key]}")
            else:
                print(f"  No match: {row['name']}")
        rows.append(row)

with open(CARDS_CSV, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

print(f"\nDone. {CARDS_CSV} updated.")
