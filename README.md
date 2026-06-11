# Apple media player

A macOS/iOS/tvOS media player for cached, looping playlist playback with optional subtitles, MQTT status publishing, and local multi-device sync.

<img src="screenshot.png" width="100%" />

## Source

Ported from the Python/VLC media player: https://github.com/ACMILabs/media-player

## Test Flight

Apple Test Flight: https://testflight.apple.com/join/jJNvBDMx

## Settings

Open settings by tapping/clicking the playback surface. On macOS, `Command-,` also opens settings.

Playlist settings:

- `Playlist ID`: the numeric playlist identifier fetched from the configured API.
- `API endpoint base`: the API root used to fetch playlists. The default is `https://xos.acmi.net.au/api/`.
- `Mute playback`: mutes or unmutes the AV player.

The player fetches playlists from:

```text
{API endpoint base}/playlists/{Playlist ID}/
```

The endpoint base may include or omit the trailing slash. For example, both of these are valid:

```text
https://xos.acmi.net.au/api/
https://xos.acmi.net.au/api
```

## Playlist API format

The player expects a JSON response with a top-level `playlist_labels` array. Each item represents one playable media item.

Required fields:

- `playlist_labels`: array of playlist item objects.
- `playlist_labels[].resource`: absolute URL for the video/media file to cache and play.

Optional fields:

- `playlist_labels[].subtitles`: absolute URL for an `.srt` subtitle file. Subtitles are downloaded, cached, and displayed when subtitle display is enabled.
- `playlist_labels[].label.id`: numeric label ID. This is not required for playback, but is included in MQTT status messages as `label_id` when present.

Example:

```json
{
  "playlist_labels": [
    {
      "label": {
        "id": 123
      },
      "resource": "https://example.org/media/video-001.mp4",
      "subtitles": "https://example.org/media/video-001.srt"
    },
    {
      "label": {
        "id": 124
      },
      "resource": "https://example.org/media/video-002.mp4",
      "subtitles": null
    }
  ]
}
```

The player downloads each `resource` and `subtitles` URL into its local cache. If the API cannot be reached later, the player falls back to the cached playlist and cached media for the same playlist ID.

### Local example API

This repository includes a minimal local playlist API example in [`api/`](api/). It serves a sample playlist JSON response, MP4, SRT, and VTT file for development:

```sh
python3 api/serve.py
```

Then set:

```text
Playlist ID: 1
API endpoint base: http://127.0.0.1:8000/
```

The same example playlist can also be loaded from S3 with:

```text
Playlist ID: 1
API endpoint base: https://acmi-public-api.s3.ap-southeast-2.amazonaws.com/media-player/
```

## MQTT status publishing

The app can publish player status to an MQTT broker. Configure it in `Settings > Message Broker`.

Settings:

- `Enable broker publishing`: connects to the broker and starts publishing.
- `Broker URL`: `mqtt://user:pass@host:1883` or `mqtts://user:pass@host:8883`.
- `Client ID`: unique MQTT client ID for this player.
- `Media Player ID`: topic suffix used in `mediaplayer.{id}`.
- `Post interval`: status publish interval in seconds.

Topic:

```text
mediaplayer.{Media Player ID}
```

QoS is `1`. Messages are not retained.

Lifecycle payload published when broker publishing starts:

```json
{
  "datetime": "2026-05-26T04:30:00Z",
  "event": "player_started",
  "playlist_id": 1,
  "media_player_id": 42
}
```

Playback status payload published on each interval:

```json
{
  "datetime": "2026-05-26T04:30:00Z",
  "playlist_id": 1,
  "media_player_id": 42,
  "label_id": 123,
  "playlist_position": 0,
  "playback_position": 0.375,
  "dropped_audio_frames": 0,
  "dropped_video_frames": 0,
  "duration": 120000,
  "player_volume": null,
  "system_volume": null,
  "current_item": "video-001.mp4"
}
```

MQTT field notes:

- `datetime`: ISO-8601 timestamp at publish time.
- `playlist_id`: current playlist ID as an integer. Defaults to `1` if the setting is not numeric.
- `media_player_id`: configured media player ID as an integer. Defaults to `1` if the setting is not numeric.
- `label_id`: `playlist_labels[index].label.id`, or `null` if unavailable.
- `playlist_position`: zero-based index of the currently playing playlist item, or `-1` if unknown.
- `playback_position`: current position as a fraction from `0.0` to `1.0`.
- `dropped_audio_frames`: currently always `0`.
- `dropped_video_frames`: currently always `0`.
- `duration`: current item duration in milliseconds, or `0` if unavailable.
- `player_volume`: currently `null`.
- `system_volume`: currently `null`.
- `current_item`: local filename of the current media item.

### RabbitMQ MQTT setup

RabbitMQ can be used as the MQTT broker. With the RabbitMQ MQTT plugin, publishes to `mediaplayer.{id}` map to the `amq.topic` exchange with routing key `mediaplayer.{id}`.

Minimal local setup:

```sh
rabbitmq-plugins enable rabbitmq_mqtt rabbitmq_management
rabbitmqctl add_user player secret
rabbitmqctl set_permissions -p / player ".*" ".*" ".*"
```

Then configure the player:

```text
mqtt://player:secret@broker-hostname-or-ip:1883
```

To consume the status stream from AMQP, bind a queue to exchange `amq.topic` with one of these routing keys:

```text
mediaplayer.*
mediaplayer.42
```

For TLS, configure RabbitMQ MQTT TLS and use an `mqtts://...:8883` broker URL.

## Local multi-device sync

Local sync uses UDP on the configured port. One player acts as the sync server and broadcasts the current playlist index and playback position to clients. Clients seek when they drift beyond the configured threshold.

Requirements:

- All players should use the same playlist ID and API endpoint.
- All players should have the same media available from the playlist URLs.
- Devices must be on the same network and able to reach the sync server over UDP.
- Clients currently expect the server field to be an IPv4 address, such as `192.168.1.20`.

Server setup:

1. Open settings on the device that should lead playback.
2. Enable `This device is the sync server`.
3. Set the sync port. The default is `10000`.
4. Save and reload.

Client setup:

1. Open settings on each follower device.
2. Leave `This device is the sync server` off.
3. Enter the server device IPv4 address in `Server hostname/IP`.
4. Use the same port as the server.
5. Save and reload.

Sync tuning:

- `Drift threshold`: clients ignore drift at or below this many milliseconds.
- `Sync latency`: extra milliseconds added to the server position when a client seeks.
- `Ignore threshold remaining`: clients avoid seeking when too little time remains in the current item.

The sync payload is internal UDP text in this format:

```text
{playlist_position},{position_milliseconds}
```

Example:

```text
3,45120
```
