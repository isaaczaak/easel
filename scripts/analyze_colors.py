#!/usr/bin/env python3
"""Tag each artwork in the manifest with its dominant colors.

Downloads a 64px thumbnail of every artwork from NGA's IIIF server, buckets
its saturated pixels by hue, and caches the result in .data/colors.json
(re-runs only fetch new artworks). Then rebuilds the manifest, which merges
the tags in as a "palette" field.

Usage: scripts/analyze_colors.py   (needs Pillow)
"""

import concurrent.futures
import io
import json
import os
import subprocess
import sys
import urllib.request

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "Resources", "manifest.json")
CACHE = os.path.join(HERE, "..", ".data", "colors.json")

# Hue ranges in degrees; red wraps around 0.
BUCKETS = [("red", 345, 15), ("orange", 15, 40), ("yellow", 40, 68),
           ("green", 68, 165), ("blue", 165, 255), ("purple", 255, 345)]
MIN_SATURATION = 0.22  # below this a pixel counts as neutral (greys, sepia)
MIN_VALUE = 0.20       # near-black pixels carry no reliable hue
MIN_COOL_SATURATION = 0.08  # pale blues/greens still read as color
MIN_COLORFUL = 0.15    # share of colorful pixels for an image to count as "in color"
MIN_SHARE = 0.15       # share of colorful weight for a hue to be tagged
MIN_BLUE_SHARE = 0.08  # a strip of sky is enough to read as blue
BROWN_SHARE = 0.45     # brown needs to dominate to be tagged
WORKERS = 12


def bucket(hue):
    for name, start, end in BUCKETS:
        if (start <= hue < end) if start < end else (hue >= start or hue < end):
            return name
    return None


def pixel_color(hue, s, v):
    """The palette bucket a pixel reads as, or None for neutral."""
    if v < MIN_VALUE:
        return None
    name = bucket(hue)
    # Cool tones are rare in varnished paintings, so even a pale sky reads as
    # blue; warm tones need real saturation to count.
    if name in ("blue", "green") and s >= MIN_COOL_SATURATION and v >= 0.3:
        return name
    if s < MIN_SATURATION:
        return None
    if name == "yellow" and hue >= 50 and v < 0.6:
        return "green"  # olive foliage under old varnish
    if name in ("orange", "yellow") and (v < 0.55 or s < 0.45):
        return "brown"  # earth, wood, varnish
    return name


def classify(image):
    pixels = list(image.convert("RGB").resize((48, 48)).convert("HSV").get_flattened_data())
    counts = {}
    for h, s, v in pixels:
        name = pixel_color(h * 360 / 255, s / 255, v / 255)
        if name:
            counts[name] = counts.get(name, 0) + 1
    colorful = sum(counts.values())
    if colorful / len(pixels) < MIN_COLORFUL:
        return ["mono"]
    shares = {name: n / colorful for name, n in counts.items()}
    # Real hues win even when brown has more pixels; brown is only tagged
    # when it dominates the picture.
    tags = [name for name, share in sorted(shares.items(), key=lambda kv: -kv[1])
            if name != "brown" and share >= (MIN_BLUE_SHARE if name == "blue" else MIN_SHARE)]
    if shares.get("brown", 0) >= BROWN_SHARE:
        tags.append("brown")
    return tags or [max(shares, key=shares.get)]


def analyze(artwork_id):
    url = f"https://api.nga.gov/iiif/{artwork_id}/full/!64,64/0/default.jpg"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return artwork_id, classify(Image.open(io.BytesIO(response.read())))
    except Exception as error:  # leave it uncached; the next run retries
        print(f"  {artwork_id}: {error}", file=sys.stderr)
        return artwork_id, None


def main():
    with open(MANIFEST, encoding="utf-8") as f:
        ids = [a["id"] for a in json.load(f)["artworks"]]
    cache = {}
    if os.path.exists(CACHE):
        with open(CACHE, encoding="utf-8") as f:
            cache = json.load(f)

    todo = [i for i in ids if i not in cache]
    print(f"{len(ids) - len(todo)} cached, analyzing {len(todo)}…")
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        for done, (artwork_id, tags) in enumerate(pool.map(analyze, todo), 1):
            if tags:
                cache[artwork_id] = tags
            if done % 500 == 0 or done == len(todo):
                with open(CACHE, "w", encoding="utf-8") as f:
                    json.dump(cache, f)
                print(f"  {done}/{len(todo)}")

    subprocess.run([sys.executable, os.path.join(HERE, "build_manifest.py")], check=True)


if __name__ == "__main__":
    main()
