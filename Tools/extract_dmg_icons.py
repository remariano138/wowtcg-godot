"""
Extracts the 8 damage type icons from dmgtypes_raw.png,
removes the tan background, and saves individual PNGs.
"""
from PIL import Image, ImageDraw
import numpy as np
from pathlib import Path

SRC  = Path(r"D:\WowTCG_Godot\assets\icons\dmgtypes_raw.png")
DEST = Path(r"D:\WowTCG_Godot\assets\dmg_icons")
DEST.mkdir(parents=True, exist_ok=True)

NAMES = ["arcane", "fire", "frost", "holy", "melee", "nature", "ranged", "shadow"]

img = Image.open(SRC).convert("RGBA")
w, h = img.size  # 484 x 83

# Each icon occupies roughly 1/8 of the width
slot_w = w / 8

# Icons sit below the text labels — estimate icon region as bottom ~65% of height
icon_top    = int(h * 0.30)
icon_bottom = h
icon_size   = 60  # output size

# Sample background colour from top-left corner (pure tan area)
bg_sample = np.array(img)[2:6, 2:6, :3].reshape(-1, 3).mean(axis=0)
BG = bg_sample  # ~[185, 155, 115] ish

TOLERANCE = 55  # how similar to bg to consider transparent

for i, name in enumerate(NAMES):
    x0 = int(i * slot_w)
    x1 = int((i + 1) * slot_w)
    # Center the crop
    cx = (x0 + x1) // 2
    half = (x1 - x0) // 2
    crop_box = (cx - half, icon_top, cx + half, icon_bottom)
    crop = img.crop(crop_box).convert("RGBA")

    # Remove background: pixels close to bg colour become transparent
    data = np.array(crop, dtype=float)
    rgb  = data[:, :, :3]
    diff = np.abs(rgb - BG).max(axis=2)
    mask = diff < TOLERANCE  # True = background
    data[:, :, 3] = np.where(mask, 0, data[:, :, 3])
    result = Image.fromarray(data.astype(np.uint8), "RGBA")

    # Resize to a clean square
    result = result.resize((icon_size, icon_size), Image.LANCZOS)
    out_path = DEST / f"{name}.png"
    result.save(out_path)
    print(f"  {name:10} -> {out_path.name}")

print(f"\nDone. Icons saved to {DEST}")
