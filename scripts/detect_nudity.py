#!/usr/bin/env python3
"""Score each artwork in the manifest for nudity with CLIP.

NGA's keywords tag nudity in drawings and prints but miss most paintings, and
photo-trained nudity detectors don't recognise painted figures. CLIP does:
each 384px thumbnail is compared against "nude" and "clothed/other"
descriptions, and the probability of the nude group is cached in
.data/nudity.json (re-runs only score new artworks). build_manifest.py then
flags an artwork as nude if NGA tagged it or its score is >= 0.5.

Setup (once):  python3 -m venv .data/venv
               .data/venv/bin/pip install torch open_clip_torch pillow
Usage:         .data/venv/bin/python scripts/detect_nudity.py
"""

import concurrent.futures
import io
import json
import os
import subprocess
import sys
import urllib.request

import open_clip
import torch
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "Resources", "manifest.json")
CACHE = os.path.join(HERE, "..", ".data", "nudity.json")

NUDE = [
    "a painting of a nude person", "a drawing of a naked figure", "an artwork of a nude woman",
    "an artwork of a nude man", "a nude sculpture", "a print of naked bodies",
]
OTHER = [
    "a painting of clothed people", "a landscape painting", "a still life",
    "a portrait of a person in clothes", "an architectural drawing", "a photograph of a street",
    "a drawing of animals", "a seascape", "a religious painting of clothed figures",
    "an ornament design", "a sculpture of a clothed figure",
]
DOWNLOAD_WORKERS = 12


def fetch(artwork_id):
    url = f"https://api.nga.gov/iiif/{artwork_id}/full/!384,384/0/default.jpg"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return artwork_id, Image.open(io.BytesIO(response.read())).convert("RGB")
    except Exception as error:  # left unscored; the next run retries
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
    print(f"{len(ids) - len(todo)} cached, scoring {len(todo)}…")

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model, _, preprocess = open_clip.create_model_and_transforms("ViT-B-32", pretrained="openai", device=device)
    tokenizer = open_clip.get_tokenizer("ViT-B-32")
    with torch.no_grad():
        text = model.encode_text(tokenizer(NUDE + OTHER).to(device))
        text /= text.norm(dim=-1, keepdim=True)

        with concurrent.futures.ThreadPoolExecutor(DOWNLOAD_WORKERS) as pool:
            for done, (artwork_id, image) in enumerate(pool.map(fetch, todo), 1):
                if image is not None:
                    features = model.encode_image(preprocess(image).unsqueeze(0).to(device))
                    features /= features.norm(dim=-1, keepdim=True)
                    probs = (100 * features @ text.T).softmax(dim=-1)[0]
                    cache[artwork_id] = round(probs[:len(NUDE)].sum().item(), 3)
                if done % 500 == 0 or done == len(todo):
                    with open(CACHE, "w", encoding="utf-8") as f:
                        json.dump(cache, f)
                    print(f"  {done}/{len(todo)}")

    subprocess.run([sys.executable, os.path.join(HERE, "build_manifest.py")], check=True)


if __name__ == "__main__":
    main()
