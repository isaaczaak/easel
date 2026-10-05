#!/usr/bin/env python3
"""Build the wallpaper manifest from the National Gallery of Art open data.

Downloads objects.csv and published_images.csv from
github.com/NationalGalleryOfArt/opendata, keeps open-access, primary-view,
landscape images that are large enough for a desktop, and writes a compact
JSON manifest the app reads.

Usage: scripts/build_manifest.py [--data-dir DIR] [--out PATH]
"""

import argparse
import collections
import csv
import json
import os
import sys
import urllib.request

DATA_URL = "https://raw.githubusercontent.com/NationalGalleryOfArt/opendata/main/data/"
IIIF_PREFIX = "https://api.nga.gov/iiif/"

MIN_ASPECT = 1.2  # width / height; screens are ~1.6, the app crops the rest
MIN_WIDTH = 2000  # px; anything smaller looks soft on a Retina display
# Classifications the app can show (ArtKind in Artwork.swift).
KINDS = {"painting", "drawing", "print", "photograph", "sculpture"}

DEFAULT_OUT = os.path.join(
    os.path.dirname(__file__), "..", "Resources", "manifest.json"
)


def fetch(data_dir, name):
    path = os.path.join(data_dir, name)
    if not os.path.exists(path):
        print(f"downloading {name}…", file=sys.stderr)
        urllib.request.urlretrieve(DATA_URL + name, path)
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", default=os.path.join(os.path.dirname(__file__), "..", ".data"))
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()

    os.makedirs(args.data_dir, exist_ok=True)
    csv.field_size_limit(sys.maxsize)

    objects = {}
    with open(fetch(args.data_dir, "objects.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            objects[row["objectid"]] = row

    artworks = []
    seen_objects = set()
    with open(fetch(args.data_dir, "published_images.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["openaccess"] != "1" or row["viewtype"] != "primary":
                continue
            if row["iiifurl"] != IIIF_PREFIX + row["uuid"]:
                continue  # app builds the URL from the uuid; skip anything unusual
            try:
                width, height = int(row["width"]), int(row["height"])
            except ValueError:
                continue
            if height == 0 or width / height < MIN_ASPECT or width < MIN_WIDTH:
                continue

            obj = objects.get(row["depictstmsobjectid"])
            if obj is None or obj["objectid"] in seen_objects:
                continue
            if obj["visualbrowserclassification"].strip() not in KINDS:
                continue
            seen_objects.add(obj["objectid"])

            artworks.append({
                "id": row["uuid"],
                "w": width,
                "h": height,
                "oid": int(obj["objectid"]),
                "title": obj["title"].strip(),
                "artist": obj["attribution"].strip(),
                "date": obj["displaydate"].strip(),
                "kind": obj["visualbrowserclassification"].strip(),
            })

    # Dominant-color tags from scripts/analyze_colors.py, when available.
    colors_path = os.path.join(args.data_dir, "colors.json")
    if os.path.exists(colors_path):
        with open(colors_path, encoding="utf-8") as f:
            colors = json.load(f)
        for artwork in artworks:
            if artwork["id"] in colors:
                artwork["palette"] = colors[artwork["id"]]

    artworks.sort(key=lambda a: a["oid"])
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "artworks": artworks}, f, ensure_ascii=False, separators=(",", ":"))

    counts = collections.Counter(a["kind"] for a in artworks)
    size_kb = os.path.getsize(args.out) // 1024
    print(f"wrote {len(artworks)} artworks ({size_kb} KB) to {os.path.relpath(args.out)}")
    for kind, n in counts.most_common():
        print(f"  {kind:<20} {n}")
    palettes = collections.Counter(tag for a in artworks for tag in a.get("palette", []))
    if palettes:
        print("palette tags: " + ", ".join(f"{tag} {n}" for tag, n in palettes.most_common()))


if __name__ == "__main__":
    main()
