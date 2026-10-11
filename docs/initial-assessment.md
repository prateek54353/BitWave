# Bitwave initial assessment

## Repository and toolchain

- The workspace initially contained only `screenshots/` (11 JPEG captures) and `decompiled_ipa/`; it had no Flutter project, README, or Git metadata.
- Flutter 3.47.4 stable and Dart 3.13.3 are installed. Android SDK 37, Java 25, and accepted Android licenses are available. Windows desktop compilation is unavailable because Visual Studio is not installed. iOS compilation/signing requires macOS and Xcode.
- The generated Flutter project is named `bitwave`. Android and iOS bundle identifiers are configured as `org.bitwave.dev`.

## Supplied evidence

- Screenshots directly show an artwork-forward now-playing view, album detail rows, album tiles and list choices, a library drawer with library counts, a ten-band equalizer panel, playback settings, local library/server settings, and a queue-oriented drawer toolbar.
- The screenshot set also includes a lock-screen playback view. One screenshot is a lyric view. Their content is reference material only; no reference artwork or songs are included in the app.
- The extracted iOS app is a full app bundle with a 19.5 MB arm64 Mach-O executable, `Info.plist`, `Assets.car`, fonts with OFL license files, tutorial images/videos, widgets, and embedded frameworks. It is not source code.
- Verified executable strings include `PlayerEngine`, `DriftLibraryHubView`, `DriftNowPlayingView`, `AVPlaybackBackend`, `SFBPlaybackBackend`, `AVAudioUnitEQ`, `SFBReplayGain`, `LyricsProvider`, `SMB`, `WebDAV`, and `crossfade`. Framework names include FLAC, mpg123, LAME, Opus, Vorbis, WavPack, Musepack, True Audio, and libsndfile. These are clues, not proof that each format or feature worked in all contexts.
- The plist declares iOS 17 minimum, audio/processing background modes, Bonjour service types for SMB/WebDAV/import, and a Spotify URL query scheme. The captured screenshots imply iOS-style permissions and screens; they do not establish the source-discovery implementation or full settings behavior.

## Initial feature matrix

| Capability | Evidence | Current implementation | Remaining verification |
|---|---|---|---|
| Offline library, songs/albums/artists/genres | Screenshot and app strings | SQLite track index; selected-file import; embedded tags/art; song, album, artist, genre browsers | Device permission/import flows; large library performance |
| Playback, queue, system controls | Player and lock-screen screenshots; audio framework strings | just_audio + audio_service handler; play/pause/seek/skip/repeat/shuffle and reorder/remove/add queue | Audible Android device test; notification/headphone/background test |
| Favorites | Drawer screenshot | Persistent favorite field and toggle | UI verification on device |
| Artwork overrides, portrait presentation, Apple Music lookup, and tags page | Follow-up screenshots and feature request | Local custom artwork/portrait crop overrides, static catalog URL selection, imported motion covers, local tag viewer/editor | Device-specific decoder, provider-token, and system media-surface verification |
| Equalizer | Ten-band screenshot and AVAudioUnitEQ string | Not enabled; visible limitation text only | DSP/backend selection and actual audio tests |
| Lyrics, crossfade, ReplayGain, network shares | Screenshots, plist, and strings | Not implemented | Licensing, protocol/backend selection, native validation |
| iOS support | Full extracted iOS app bundle and plist | Flutter iOS project includes audio background mode and document import path | macOS/Xcode compilation, signing, background and media-control tests |

## Architecture and implementation sequence

1. Configure Bitwave identity and a reusable dark theme.
2. Build the offline foundation: app-private imported files, metadata extraction, and versioned SQLite index.
3. Connect browsing, favorites, queue, and playback state to a shared just_audio/audio_service handler.
4. Verify formatting, static analysis, Android build, and available tests; document all device and iOS checks that cannot be performed here.
5. Add advanced processing, lyric synchronization, and remote sources only after the playback path is verified on devices.

## Package choices

- `just_audio` handles local audio file playback, seek, playlist sources, repeat, shuffle, and decoder errors using each platform's supported native decoder.
- `audio_service` exposes playback state, queue, lock-screen/notification controls, and media buttons on Android and iOS.
- `audio_session` configures music playback and interruption behavior.
- `file_picker` gives users an explicit, sandbox-compatible way to choose local audio files; import copies them to app-private storage rather than claiming unrestricted iOS filesystem access.
- `audio_metadata_reader` is a pure Dart metadata reader covering common ID3, Vorbis, MP4, WAV, AIFF, and APE tag containers.
- `sqflite` and `path_provider` store a versioned local index and imported content in app-owned storage.
- `video_player` renders user-imported motion artwork independently from the audio handler; `video_thumbnail` provides a static fallback poster. A local compatibility copy patches the latter's obsolete Android Gradle configuration.
- `http` performs direct public Apple Music catalog searches, and `flutter_secure_storage` stores the user-provided developer token. Selected catalog art is referenced by URL and is not downloaded to Bitwave's offline artwork store.

Package compatibility and APIs were checked on pub.dev on 11 October 2026. Actual codec support remains platform and OS dependent and has not been device-tested yet.
