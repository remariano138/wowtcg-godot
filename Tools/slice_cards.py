import json
import re
import csv
from pathlib import Path
from PIL import Image

# ── Paths ────────────────────────────────────────────────────────────────────
ROOT        = Path(__file__).parent.parent
JSON_PATH   = ROOT / "Tools" / "PNJfromTTSmod" / "2236124562.json"
IMAGES_DIR  = Path(r"C:\Users\remim\OneDrive\Documents\My Games\Tabletop Simulator\Mods\Images")
OUTPUT_DIR  = ROOT / "assets" / "cards"
TOOLS_DIR   = Path(__file__).parent

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# ── Helpers ──────────────────────────────────────────────────────────────────

def url_to_ugc_id(url: str) -> str | None:
    """Extract the numeric ugc ID from a Steam CDN URL — stable across CDN mirrors."""
    m = re.search(r"/ugc/(\d+)/", url)
    return m.group(1) if m else None

def sanitize_name(name: str) -> str:
    """Lowercase, replace spaces and punctuation with underscores."""
    name = name.lower().strip()
    name = re.sub(r"[^a-z0-9]+", "_", name)
    return name.strip("_")

def find_local_atlas(url: str, images_dir: Path) -> Path | None:
    ugc_id = url_to_ugc_id(url)
    if not ugc_id:
        return None
    for f in images_dir.iterdir():
        if ugc_id in f.name:
            return f
    return None

def collect_cards(data: dict) -> list[dict]:
    """Recursively walk the TTS JSON and collect every card object."""
    cards = []
    if isinstance(data, dict):
        if "CardID" in data and "Nickname" in data and "CustomDeck" in data:
            nickname = data["Nickname"].strip()
            card_id  = data["CardID"]
            deck_entry = next(iter(data["CustomDeck"].values()))  # always one entry per card
            cards.append({
                "nickname":   nickname,
                "card_id":    card_id,
                "face_url":   deck_entry["FaceURL"],
                "num_width":  deck_entry["NumWidth"],
                "num_height": deck_entry["NumHeight"],
            })
        for value in data.values():
            cards.extend(collect_cards(value))
    elif isinstance(data, list):
        for item in data:
            cards.extend(collect_cards(item))
    return cards

# ── Load JSON ────────────────────────────────────────────────────────────────
print("Loading JSON…")
with open(JSON_PATH, encoding="utf-8") as f:
    data = json.load(f)

print("Collecting card objects…")
all_cards = collect_cards(data)
print(f"  Found {len(all_cards)} card objects total")

# ── Build atlas cache (url -> local path or None) ────────────────────────────
print("Resolving atlases…")
atlas_cache: dict[str, Path | None] = {}
for card in all_cards:
    url = card["face_url"]
    if url not in atlas_cache:
        atlas_cache[url] = find_local_atlas(url, IMAGES_DIR)

missing_urls = [u for u, p in atlas_cache.items() if p is None]
found_urls   = [u for u, p in atlas_cache.items() if p is not None]
print(f"  Atlases found: {len(found_urls)}  |  Missing: {len(missing_urls)}")

(TOOLS_DIR / "missing_atlases.txt").write_text(
    "\n".join(missing_urls) + "\n" if missing_urls else "",
    encoding="utf-8"
)

# ── Slice cards ──────────────────────────────────────────────────────────────
print("Slicing cards…")
seen_names: dict[str, str] = {}   # sanitized_name -> image_path
skipped_missing  = 0
skipped_duplicate = 0
total = len(all_cards)

for i, card in enumerate(all_cards):
    nickname = card["nickname"]
    if not nickname:
        continue

    safe_name = sanitize_name(nickname)

    if safe_name in seen_names:
        skipped_duplicate += 1
        continue

    local_atlas = atlas_cache.get(card["face_url"])
    if local_atlas is None:
        skipped_missing += 1
        continue

    num_w  = card["num_width"]
    num_h  = card["num_height"]
    pos    = card["card_id"] % 100
    row    = pos // num_w
    col    = pos % num_w

    atlas  = Image.open(local_atlas)
    cell_w = atlas.width  // num_w
    cell_h = atlas.height // num_h

    left   = col * cell_w
    top    = row * cell_h
    right  = left + cell_w
    bottom = top  + cell_h

    if right > atlas.width or bottom > atlas.height:
        print(f"  [WARN] Out-of-bounds crop for '{nickname}' (CardID={card['card_id']}, "
              f"pos={pos}, row={row}, col={col}) — skipping")
        continue

    crop = atlas.crop((left, top, right, bottom))
    crop = crop.resize((500, 700), Image.LANCZOS)
    out_path = OUTPUT_DIR / f"{safe_name}.png"
    crop.save(out_path)

    seen_names[safe_name] = str(out_path.relative_to(ROOT))
    done = len(seen_names)
    print(f"  [{done:>4}/{total}] {nickname}", flush=True)

# ── Write CSV ────────────────────────────────────────────────────────────────
csv_path = ROOT / "tools" / "cards_master.csv"
with open(csv_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["name", "image_path"])
    for name, path in sorted(seen_names.items()):
        writer.writerow([name, path])

# ── Summary ──────────────────────────────────────────────────────────────────
print()
print("-" * 50)
print(f"Unique cards processed:        {len(seen_names)}")
print(f"Atlases missing locally:       {len(missing_urls)}")
print(f"Cards skipped (no atlas):      {skipped_missing}")
print(f"Cards skipped (duplicate):     {skipped_duplicate}")
print(f"Output:  {OUTPUT_DIR}")
print(f"CSV:     {csv_path}")
if missing_urls:
    print(f"Missing: {TOOLS_DIR / 'missing_atlases.txt'}")
