# Bitwave

Bitwave is an offline-first local audio library and player built with Flutter.

## Current foundation

- Import audio files or an entire music folder through the operating system picker. Imported files are copied into app-private storage so the library does not depend on temporary picker URLs. iOS folder import uses a security-scoped document picker and stages supported audio before copying it into Bitwave.
- On iOS, expose `Files → On My iPhone → Bitwave → Local Files` as a managed local-music folder. Bitwave watches it while active, rescans when returning to the foreground, indexes updated metadata, and removes missing files from the library index without deleting user files.
- Read common title, artist, album, genre, year, duration, track-number, bitrate, sample-rate, and embedded-cover tags. Malformed tags fall back to the filename while keeping the audio file importable.
- Read embedded unsynchronized and timestamped LRC lyrics into the library. Timestamped lyrics follow playback in Now Playing; ordinary lyrics show a short excerpt.
- Search LRCLIB from track details, review exact metadata matches, and save selected lyrics in the local library for offline use. Requests identify Bitwave and honor LRCLIB's `Retry-After` response.
- Keep track metadata and favorites in a versioned SQLite database.
- Browse songs, albums, artists, and genres; search the indexed library; switch album presentation between grid and list.
- Play local files through `just_audio`, with an `audio_service` queue, seek, previous/next, shuffle, repeat, mini-player, full player, and Android/iOS media-session configuration.
- Configure a sleep timer that pauses active playback.
- Assign per-track or album-level image and motion artwork as private Bitwave overrides. Crop framing and aspect ratio are persisted without writing to audio tags.
- Open a track tag viewer/editor from track menus or by tapping the title and artist in Now Playing. Edits are stored in Bitwave's database; audio files are not modified.
- Search the Apple Music public catalog with a user-supplied developer token, inspect candidate releases, and select a static artwork URL manually. Local covers remain available offline.
- Search the m8tec community motion-artwork service from Edit Artwork. A match must be reviewed and selected; square or tall HLS artwork streams while online, with the local cover kept as the poster fallback. This service describes its Apple Music retrieval as web scraping and uses non-public Apple endpoints; it is unofficial, subject to change, and has not been cleared by Apple for production use.
- Play imported MP4/MOV motion artwork silently in the full player, or animated GIF/WebP in the player when the platform decoder supports it. iOS 26+ can receive imported square or 3:4 local MP4/MOV artwork through Apple's public animated Now Playing API; other iOS versions and unsupported aspect ratios use the static poster. Remote HLS provider clips remain in-app because the system API requires a local video URL.

## Build and checks

```powershell
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

Android application ID: `org.bitwave.dev`.

On iOS, file and folder import are user mediated through the document picker. The app's Documents directory is exposed in Files; tracks placed under `Local Files` remain in place and are synchronized while Bitwave is active and on foreground resume. iOS suspends background apps, so rescanning cannot be guaranteed while the app is suspended. The project enables the audio background mode. Compile, sign, and test it on macOS with Xcode before release. The current playback engine delegates decoding to the platform; verify each desired format on the actual Android and iOS versions being supported.

On Android 13 and later, Bitwave requests notification permission when playback starts. Playback continues if permission is declined, but Android hides the notification from the shade. The media session supplies title, artist, static artwork, and transport controls. iOS lock-screen metadata uses `audio_service`; imported animated artwork uses a small native MediaPlayer bridge on iOS 26+ and still requires physical-device verification.

Release signing is deliberately separate from debug signing. Set `BITWAVE_STORE_FILE`, `BITWAVE_STORE_PASSWORD`, `BITWAVE_KEY_ALIAS`, and `BITWAVE_KEY_PASSWORD` in the release environment, then build with `flutter build appbundle --release`. Without these values Gradle can produce an unsigned bundle for build validation, but it cannot be uploaded to Google Play. Never commit a keystore or signing secrets.

See [docs/artwork-system.md](docs/artwork-system.md) for artwork storage and provider status, and [docs/reference-findings.md](docs/reference-findings.md) for bounded observations from the supplied decompiler export.

## Not yet available

The equalizer is not active because the selected backend does not provide a shared, cross-platform ten-band DSP. Crossfade, ReplayGain, unrestricted media scanning, network sources, embedded-file tag writing, playlist editing, and backup are not implemented. Tag and lyric edits currently apply to Bitwave's local library index. No sample tracks or counts are bundled. Store listing, privacy disclosures, production signing, iOS build/sign/device validation, lyrics-content rights review, and final supported-device playback checks remain release work.
