#!/usr/bin/env python3
"""Build the wallpaper manifest from the National Gallery of Art open data.

Downloads objects.csv, published_images.csv and related tables from
github.com/NationalGalleryOfArt/opendata, keeps open-access, primary-view
images that are large enough for a desktop, and writes a compact JSON
manifest the app reads. Landscape images fill the screen; the app shows
portrait and square ones whole, on a gallery wall.

Usage: scripts/build_manifest.py [--data-dir DIR] [--out PATH]
"""

import argparse
import collections
import csv
import json
import os
import sys
import urllib.request
import uuid

DATA_URL = "https://raw.githubusercontent.com/NationalGalleryOfArt/opendata/main/data/"
IIIF_PREFIX = "https://api.nga.gov/iiif/"

MIN_SIZE = 2000  # px on the long side; anything smaller looks soft on a Retina display
NUDITY_THRESHOLD = 0.5  # CLIP score from scripts/detect_nudity.py
# Works with nudity that neither NGA's tags nor CLIP catch, by object id.
NUDE_BY_HAND = {
    46471,  # Watson and the Shark, John Singleton Copley
}
# Art movements the app can filter by (ArtMovement in Artwork.swift): NGA's
# "Style" terms, leaving out furniture and regional styles.
MOVEMENTS = {"Renaissance", "Baroque", "Rococo", "Neoclassic", "Romantic", "Realist",
             "Impressionist", "Post-Impressionist", "Naive"}
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
                uuid.UUID(row["uuid"])  # also used as a file name
            except ValueError:
                continue
            try:
                width, height = int(row["width"]), int(row["height"])
            except ValueError:
                continue
            if height == 0 or max(width, height) < MIN_SIZE:
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

    # Nudity: NGA's own keywords, plus CLIP scores (which catch the paintings
    # NGA didn't tag). Only flagged artworks carry the field.
    nude_objects = set()
    movements = collections.defaultdict(list)
    with open(fetch(args.data_dir, "objects_terms.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            term = row["term"].lower()
            if row["termtype"] in ("Keyword", "Theme") and ("nude" in term or "naked" in term):
                nude_objects.add(int(row["objectid"]))
            if row["termtype"] == "Style" and row["term"] in MOVEMENTS:
                movements[int(row["objectid"])].append(row["term"])
    scores = {}
    nudity_path = os.path.join(args.data_dir, "nudity.json")
    if os.path.exists(nudity_path):
        with open(nudity_path, encoding="utf-8") as f:
            scores = json.load(f)
    for artwork in artworks:
        if (artwork["oid"] in nude_objects or artwork["oid"] in NUDE_BY_HAND
                or scores.get(artwork["id"], 0) >= NUDITY_THRESHOLD):
            artwork["nude"] = True
        if artwork["oid"] in movements:
            artwork["movements"] = sorted(set(movements[artwork["oid"]]))

    # Label details for the info card: medium, and the lead artist's
    # nationality and life dates ("American, 1796 - 1872"). Only non-empty
    # values are written, to keep the manifest small.
    bios = {}
    with open(fetch(args.data_dir, "constituents.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            bios[row["constituentid"]] = row["displaydate"].strip()
    lead_artist = {}
    with open(fetch(args.data_dir, "objects_constituents.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["roletype"] != "artist":
                continue
            order = int(row["displayorder"] or 99)
            current = lead_artist.get(row["objectid"])
            if current is None or order < current[0]:
                lead_artist[row["objectid"]] = (order, row["constituentid"])
    for artwork in artworks:
        oid = str(artwork["oid"])
        medium = objects[oid]["medium"].strip()
        if medium:
            artwork["medium"] = medium
        lead = lead_artist.get(oid)
        bio = bios.get(lead[1], "") if lead else ""
        if bio and bio != artwork["artist"]:
            artwork["bio"] = bio

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
    tagged = collections.Counter(m for a in artworks for m in a.get("movements", []))
    print("movements: " + ", ".join(f"{m} {n}" for m, n in tagged.most_common()))
    nude = collections.Counter(a["kind"] for a in artworks if a.get("nude"))
    print(f"flagged nude: {sum(nude.values())} (" + ", ".join(f"{k} {n}" for k, n in nude.most_common()) + ")")


if __name__ == "__main__":
    main()
