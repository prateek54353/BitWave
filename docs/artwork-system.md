# Bitwave artwork system

## Implemented

- Each indexed track stores separate embedded art, a custom local override, an optional Apple Music catalog identity and URL, aspect ratio, crop focus, fit mode, animation flag, and generated poster path.
- Imported images are copied into Bitwave's private `Artwork` directory. The original file is retained; crop framing is stored as presentation metadata. Supported crop ratios are 1:1, 3:4, 4:5, 9:16, and original. Fit shows the full image, Fill crops around center, and Crop allows the user to reposition the crop.
- Imported MP4/MOV motion art is checked for supported extension, size (40 MB maximum), duration (0.5–20 seconds), dimensions (maximum 4096 pixels per side), and poster generation. The full player loops the video silently in an independent video controller, releases that controller when its track changes or the sheet closes, and honors the global animation switch and system reduced-motion preference. GIF and animated WebP rendering is delegated to Flutter's image decoder and may depend on the device decoder.
- The standard artwork path and generated motion poster are used for Android notification/lock-screen media metadata and the `audio_service` Now Playing item. Audio playback itself remains handled by `just_audio`.
- Replacing or resetting a custom override removes its old files only when no indexed track references them. Embedded art and source audio are retained.
- Tag edits from the track detail page update the local SQLite index only. Writing tags back into an audio file is not implemented.

## Apple Music catalog

The optional provider uses Apple's public catalog search endpoint and developer-token authorization. Apple documents catalog search and artwork URL templates with requested width and height placeholders. Bitwave requires the user to provide a signed developer token, stores it with platform secure storage, and stores the storefront separately. Catalog search does not require an Apple Music subscriber token. Results are always selected manually; there is no title-only automatic assignment. See [Apple Music API search](https://developer.apple.com/documentation/applemusicapi/search), [developer-token overview](https://developer.apple.com/documentation/applemusicapi), and [artwork URL fields](https://developer.apple.com/documentation/applemusicapi/artwork).

Bitwave retains the selected artwork URL and identifier and displays the result with its corresponding local track. It does not download the image into the offline artwork directory. Apple API access and any artwork display or reuse must remain within the Apple Music API and applicable content terms. A URL selection is not an ownership or redistribution license. Offline playback always falls back to user-imported or embedded local art. The catalog search response used by Bitwave exposes still artwork; it does not supply a motion-artwork asset, so Apple Music motion-artwork discovery is unavailable here.

Apple developer-token creation requires an Apple Developer Program team and a signed token. Bitwave does not generate or refresh the token. The user must provide a valid token and replace it when it expires. Search requires network access and will report authorization and rate-limit errors.

## Platform status and limits

| Capability | Android | iOS |
|---|---|---|
| Static lock-screen artwork | Implemented through the `audio_service` media item; local covers and poster frames are static files. Real-device verification remains outstanding. | Configured through `audio_service` / Now Playing metadata. Real-device verification remains outstanding. |
| Animated lock-screen artwork | Not implemented. Standard media notification metadata receives a static image. | Not integrated or verified. Current public MediaPlayer documentation describes `MPMediaItemAnimatedArtwork`, which accepts a local video asset and preview image for system views. Bitwave currently sends static metadata through `audio_service`; using the newer animated API would require a Swift-side adapter, availability checks, macOS/Xcode builds, and supported-device tests. See [Providing animated artwork for media items](https://developer.apple.com/documentation/mediaplayer/providing-animated-artwork-for-media-items) and [MPMediaItemAnimatedArtwork](https://developer.apple.com/documentation/mediaplayer/mpmediaitemanimatedartwork). |
| In-app video motion cover | MP4/MOV via `video_player`; actual codecs depend on Android OS/device decoder. | MP4/MOV via `video_player`; actual codecs depend on iOS. Compilation and device testing require macOS/Xcode. |

## Build compatibility note

The upstream `video_thumbnail 0.5.6` Android Gradle script still references `jcenter()` and pins Android Gradle Plugin 4.1. The project uses a narrow local copy at `packages/video_thumbnail` with the obsolete Gradle bootstrap removed and the Android namespace/compile SDK aligned to this app. Its source license is retained. The Dart/native thumbnail implementation is otherwise unchanged. Review this override when upgrading Android Gradle or replacing the thumbnail package.

## Not implemented

- Embedded tag writing, automatic catalog match acceptance, Apple Music image downloads, provider caching, and catalog motion-art discovery.
- Native animated lock-screen artwork. Although Apple's current public MediaPlayer API documents an animated-artwork type, this app has no native Swift bridge for it and that feature is not verified. Android animation on notification/lock-screen surfaces is also not claimed.
- Other background styles such as artwork blur, derived-color rendering, or full-screen artwork beyond the current image-led player.
- Automated memory/performance tests on low-memory physical devices, end-to-end provider calls with a production developer token, and real hardware playback/background testing.
