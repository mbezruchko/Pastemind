"""The DMG window's background (660 x 400 points, at 1x and 2x, as one TIFF Finder picks the right size from).
Finder draws the icons' names itself, in black over any background picture (even in dark mode), so the picture is
light: warm paper with a breath of cool light and grain, a slim ink arrow from Pastemind to Applications, the
site's marker under "Applications" (where the app goes), and one quiet line of what to do.

    .build/dmgbuild/bin/python scripts/dmg/background.py      → scripts/dmg/background.tiff
    (needs Pillow, NumPy and fontTools with Brotli in that environment; the fonts are the site's own)
"""
import io
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
W, H = 660, 400
# Where dmgbuild puts the icons' centres (settings.py has the same); Finder sets a name 83 points below its icon's
# centre, "Applications" about 74 points wide at 13 points.
APP, APPS = (190, 196), (470, 196)
LABEL_DY, APPS_LABEL_W = 83, 74
PAPER = (249, 247, 241)
INK = (36, 35, 52)
DIM = (128, 127, 146)
MARKER = (250, 228, 82)


def font(name, size, weight):
    """The site's own font (a woff2 there), at a weight of its variable axis."""
    ttf = TTFont(ROOT / "site" / "fonts" / f"{name}-latin.woff2")
    ttf.flavor = None
    data = io.BytesIO()
    ttf.save(data)
    data.seek(0)
    f = ImageFont.truetype(data, size)
    f.set_variation_by_axes([weight])
    return f


def draw(scale):
    s = scale * 4                       # drawn 4x larger again, then scaled down: smooth edges
    w, h = W * s, H * s
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = np.zeros((h, w, 3), np.float32) + PAPER
    # A breath of cool light from the top left, a warmer one low on the right.
    for cx, cy, color, strength in [(0.15, -0.1, (214, 224, 255), 0.55), (0.95, 1.1, (255, 240, 214), 0.35)]:
        d2 = ((xx / w - cx) / 0.8) ** 2 + ((yy / h - cy) / 0.8) ** 2
        k = (np.exp(-d2 * 2.2) * strength)[..., None]
        base = base * (1 - k) + np.array(color, np.float32) * k
    base += np.random.default_rng(3).normal(0, 1.4, (h, w, 1))       # grain: paper, and no banding
    img = Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))
    d = ImageDraw.Draw(img, "RGBA")

    # A slim ink arrow between the icons.
    y = APP[1] * s
    x0, x1 = (APP[0] + 84) * s, (APPS[0] - 84) * s
    width = max(1, round(1.5 * s))
    d.line((x0, y, x1, y), fill=INK + (110,), width=width)
    d.line((x1 - 8 * s, y - 6 * s, x1, y, x1 - 8 * s, y + 6 * s), fill=INK + (110,), width=width, joint="curve")

    # The marker under "Applications": the name Finder draws there sits on it.
    cx, cy, half = APPS[0] * s, (APPS[1] + LABEL_DY) * s, (APPS_LABEL_W / 2 + 6) * s
    d.rounded_rectangle((cx - half, cy - 9 * s, cx + half, cy + 10 * s), 2 * s, fill=MARKER + (255,))

    # What to do, quietly, at the bottom.
    d.text((W * s / 2, 356 * s), "Drag Pastemind into Applications, then open it from there.",
           font=font("funnel-sans", 13 * s, 430), fill=DIM + (255,), anchor="mm")
    return img.resize((W * scale, H * scale), Image.LANCZOS)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        one, two = Path(tmp) / "bg.png", Path(tmp) / "bg@2x.png"
        draw(1).save(one)
        draw(2).save(two)
        out = HERE / "background.tiff"
        subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(out)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("wrote", out)


if __name__ == "__main__":
    main()
