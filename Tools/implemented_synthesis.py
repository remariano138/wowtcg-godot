"""
implemented_synthesis.py
Run from the repo root: python tools/implemented_synthesis.py

Prints a synthesis of all *implemented* cards in data/cards.csv.
A card is "implemented" when engine_status == "implemented".
"""

import csv
import sys
import io
from pathlib import Path
from collections import defaultdict

# Force UTF-8 output so box-drawing chars render on any terminal.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

CSV_PATH = Path(__file__).parent.parent / "data" / "cards.csv"

RARITIES = ["Common", "Uncommon", "Rare", "Epic"]
ALIGNMENTS = ["Alliance", "Horde", "Neutral"]  # Neutral = no alignment field


def rarity_key(r: str) -> int:
    return RARITIES.index(r) if r in RARITIES else 99


def load_implemented(path: Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return [r for r in rows if r.get("engine_status", "").strip() == "implemented"]


def alignment_label(row: dict) -> str:
    a = row.get("alignment", "").strip()
    return a if a else "Neutral"


def section(title: str) -> None:
    print(f"\n{'━' * 52}")
    print(f"  {title}")
    print(f"{'━' * 52}")


def rarity_breakdown(cards: list[dict], indent: int = 4) -> None:
    by_rarity: dict[str, int] = defaultdict(int)
    for c in cards:
        by_rarity[c.get("rarity", "?").strip()] += 1
    pad = " " * indent
    for r in sorted(by_rarity, key=rarity_key):
        print(f"{pad}{r:<12} {by_rarity[r]}")


def alignment_rarity_breakdown(cards: list[dict], alignments: list[str]) -> None:
    # alignment -> rarity -> count
    data: dict[str, dict[str, int]] = {a: defaultdict(int) for a in alignments}
    for c in cards:
        al = alignment_label(c)
        r  = c.get("rarity", "?").strip()
        if al in data:
            data[al][r] += 1

    rarities_seen = sorted(
        {c.get("rarity", "?").strip() for c in cards}, key=rarity_key
    )

    # header
    al_cols = [a for a in alignments if sum(data[a].values()) > 0]
    col_w = 12
    header = "    " + "".join(f"{a:<{col_w}}" for a in al_cols)
    print(header)
    print("    " + "-" * (col_w * len(al_cols)))
    for r in rarities_seen:
        row = f"    {r:<12}" + "".join(
            f"{data[a].get(r, 0):<{col_w}}" for a in al_cols
        )
        print(row)
    # totals
    total_row = "    " + f"{'TOTAL':<12}" + "".join(
        f"{sum(data[a].values()):<{col_w}}" for a in al_cols
    )
    print("    " + "-" * (col_w * len(al_cols)))
    print(total_row)


def main() -> None:
    if not CSV_PATH.exists():
        print(f"ERROR: {CSV_PATH} not found", file=sys.stderr)
        sys.exit(1)

    impl = load_implemented(CSV_PATH)
    total = len(impl)

    by_type: dict[str, list[dict]] = defaultdict(list)
    for c in impl:
        by_type[c.get("type", "?").strip()].append(c)

    print(f"\n{'═' * 52}")
    print(f"  WoW TCG — Implemented card synthesis")
    print(f"  Total implemented: {total}")
    print(f"{'═' * 52}")

    # ── Heroes ────────────────────────────────────────────────────────────────
    heroes = by_type.get("Hero", [])
    section(f"HEROES  ({len(heroes)} total)")
    alliance_heroes = [h for h in heroes if alignment_label(h) == "Alliance"]
    horde_heroes    = [h for h in heroes if alignment_label(h) == "Horde"]
    print(f"    Alliance : {len(alliance_heroes)}")
    for h in sorted(alliance_heroes, key=lambda x: x["name"]):
        print(f"        {h['name']}")
    print(f"    Horde    : {len(horde_heroes)}")
    for h in sorted(horde_heroes, key=lambda x: x["name"]):
        print(f"        {h['name']}")

    # ── Allies ────────────────────────────────────────────────────────────────
    allies = by_type.get("Ally", [])
    section(f"ALLIES  ({len(allies)} total)")
    print("  By rarity:")
    rarity_breakdown(allies)
    print("  By alignment × rarity:")
    alignment_rarity_breakdown(allies, ["Alliance", "Horde", "Neutral"])

    # ── Abilities ─────────────────────────────────────────────────────────────
    abilities = by_type.get("Ability", []) + by_type.get("Instant", [])
    section(f"ABILITIES  ({len(abilities)} total)")
    if abilities:
        print("  By rarity:")
        rarity_breakdown(abilities)
    else:
        print("    (none)")

    # ── Equipment ─────────────────────────────────────────────────────────────
    equipment = by_type.get("Equipment", []) + by_type.get("Weapon", []) + by_type.get("Armor", [])
    section(f"EQUIPMENT  ({len(equipment)} total)")
    if equipment:
        print("  By rarity:")
        rarity_breakdown(equipment)
    else:
        print("    (none)")

    # ── Quests & Locations ────────────────────────────────────────────────────
    quests = by_type.get("Quest", []) + by_type.get("Location", [])
    section(f"QUESTS / LOCATIONS  ({len(quests)} total)")
    if quests:
        print("  By rarity:")
        rarity_breakdown(quests)
        print("  By type:")
        for t in ["Quest", "Location"]:
            subset = by_type.get(t, [])
            if subset:
                print(f"    {t}: {len(subset)}")
    else:
        print("    (none)")

    # ── Other types (catch-all) ───────────────────────────────────────────────
    known = {"Hero", "Ally", "Ability", "Instant", "Equipment", "Weapon", "Armor", "Quest", "Location"}
    others = {t: cards for t, cards in by_type.items() if t not in known}
    if others:
        section("OTHER TYPES")
        for t, cards in sorted(others.items()):
            print(f"    {t}: {len(cards)}")


if __name__ == "__main__":
    main()
