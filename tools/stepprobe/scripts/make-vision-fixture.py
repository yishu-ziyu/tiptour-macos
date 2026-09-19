#!/usr/bin/env python3
"""Generate the ground-truth fixture used by the vision coordinate test.

Writes a real screenshot overlaid with high-contrast markers at known,
deliberately awkward positions (off-centre, three very different sizes) and
prints the ground truth in the `name=x1,y1,x2,y2` form `stepprobe vision` accepts.

Capturing a fresh screenshot each run matters: a stale fixture stops measuring
the resolutions and content that actually appear on this display.
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path("/tmp/stepprobe-fixture.png")
SHOT = Path("/tmp/stepprobe-screen.png")

# name, x, y, size — kept small/large/off-centre so a single scale factor
# cannot accidentally make every prediction look right.
MARKERS = [
    ("A", 300, 180, 90),
    ("B", 2100, 1500, 140),
    ("C", 2900, 300, 60),
]


def main() -> int:
    subprocess.run(["screencapture", "-x", str(SHOT)], check=True)
    image = Image.open(SHOT).convert("RGB")
    width, height = image.size
    print(f"# source screenshot: {width}x{height}")

    draw = ImageDraw.Draw(image)
    truth = []
    for name, x, y, size in MARKERS:
        if x + size > width or y + size > height:
            print(f"# skipping {name}: outside {width}x{height}", file=sys.stderr)
            continue
        draw.rectangle([x, y, x + size, y + size], fill=(255, 0, 255), outline=(0, 0, 0), width=6)
        draw.rectangle(
            [x + size // 2 - 8, y + size // 2 - 8, x + size // 2 + 8, y + size // 2 + 8],
            fill=(0, 0, 0),
        )
        truth.append(f"{name}={x},{y},{x + size},{y + size}")

    image.save(OUT)
    print(f"# fixture written: {OUT}")
    print("# run:")
    print("swift run --package-path tools/stepprobe stepprobe vision \\")
    print(f"  --image {OUT} \\")
    for entry in truth:
        print(f"  --truth {entry} \\")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
