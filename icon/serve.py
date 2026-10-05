#!/usr/bin/env python3
"""Serves the repo for icon/index.html and saves rendered PNGs it POSTs to
/save?name=<name> into icon/out/. Run from anywhere: icon/serve.py"""
import http.server
import os
import re
import urllib.parse

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "icon", "out")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        name = urllib.parse.parse_qs(url.query).get("name", ["icon"])[0]
        if url.path != "/save" or not re.fullmatch(r"[\w-]+", name):
            self.send_error(400)
            return
        data = self.rfile.read(int(self.headers["Content-Length"]))
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, f"{name}.png"), "wb") as f:
            f.write(data)
        self.send_response(204)
        self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
