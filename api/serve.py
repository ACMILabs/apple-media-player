#!/usr/bin/env python3
"""Serve the minimal local playlist API for development."""

from __future__ import annotations

import argparse
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


API_ROOT = Path(__file__).resolve().parent


class PlaylistAPIHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(API_ROOT), **kwargs)

    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/playlists/1/":
            self._send_playlist()
            return
        if path == "/":
            self._send_json(
                {
                    "message": "Local playlist API",
                    "playlist": "/playlists/1/",
                }
            )
            return
        super().do_GET()

    def _send_playlist(self) -> None:
        playlist_path = API_ROOT / "playlists" / "1" / "playlist.json"
        playlist = json.loads(playlist_path.read_text(encoding="utf-8"))
        base_url = f"http://{self.headers.get('Host', '127.0.0.1:8000')}"

        for item in playlist["playlist_labels"]:
            item["resource"] = f"{base_url}/media/sample.mp4"
            item["subtitles"] = f"{base_url}/subtitles/sample.srt"

        self._send_json(playlist)

    def _send_json(self, payload: object) -> None:
        data = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8000, type=int)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), PlaylistAPIHandler)
    print(f"Serving local playlist API at http://{args.host}:{args.port}/")
    print(f"Playlist endpoint: http://{args.host}:{args.port}/playlists/1/")
    server.serve_forever()


if __name__ == "__main__":
    main()
