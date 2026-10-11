# Bitwave

Bitwave is an offline-first local audio library and player built with Flutter.

## Current foundation

- Import audio files through the operating system picker. Imported files are copied into app-private storage so the library does not depend on a temporary picker URL.
- Read common title, artist, album, genre, year, duration, track-number, bitrate, sample-rate, and embedded-cover tags. Malformed tags fall back to the filename while keeping the audio file importable.
- Keep track metadata and favorites in a versioned SQLite database.
- Browse songs, albums, artists, and genres; search the indexed library; switch album presentation between grid and list.
- Play local files through `just_audio`, with an `audio_service` queue, seek, previous/next, shuffle, repeat, mini-player, full player, and Android/iOS media-session configuration.
- Configure a sleep timer that pauses active playback.
- Assign per-track or album-level image and motion artwork as private Bitwave overrides. Crop framing and aspect ratio are persisted without writing to audio tags.
- Open a track tag viewer/editor from track menus or by tapping the title and artist in Now Playing. Edits are stored in Bitwave's database; audio files are not modified.
- Search the Apple Music public catalog with a user-supplied developer token, inspect candidate releases, and select a static artwork URL manually. Local covers remain available offline.
- Play imported MP4/MOV motion artwork silently in the full player, or animated GIF/WebP in the player when the platform decoder supports it. System media surfaces receive a static poster.

## Build and checks

```powershell
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter build apk --debug
```

Android application ID: `org.bitwave.dev`.

On iOS, file import is user mediated through the document picker. The project enables the audio background mode. Compile, sign, and test it on macOS with Xcode before release. The current playback engine delegates decoding to the platform; verify each desired format on the actual Android and iOS versions being supported.

See [docs/artwork-system.md](docs/artwork-system.md) for artwork storage, Apple Music authorization notes, and platform status.

## Not yet available

The equalizer is not active because the selected backend does not provide a shared, cross-platform ten-band DSP. Synchronized lyric display, crossfade, ReplayGain, unrestricted media scanning, network sources, embedded-file tag writing, playlist editing, and backup are not implemented. Tag edits currently apply to Bitwave's local library index. No sample tracks or counts are bundled.
