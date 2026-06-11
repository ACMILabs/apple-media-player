# Local example API

Run the minimal playlist API from the repository root:

```sh
python3 api/serve.py
```

Then configure the player with:

```text
Playlist ID: 1
API endpoint base: http://127.0.0.1:8000/
```

Available example files:

- `GET /playlists/1/`
- `GET /media/sample.mp4`
- `GET /subtitles/sample.srt`
- `GET /subtitles/sample.vtt`
