import 'dart:convert';

import 'package:bitwave/features/artwork/data/apple_music_motion_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'search returns square and tall HLS variants for explicit review',
    () async {
      late Uri requestedUri;
      final provider = AppleMusicMotionProvider(
        client: MockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            jsonEncode({
              'url': 'https://cdn.example/square.m3u8',
              'url_tall': 'https://cdn.example/tall.m3u8',
              'artist': 'Artist',
              'album': 'Album',
              'isCached': true,
            }),
            200,
          );
        }),
      );
      addTearDown(provider.dispose);

      final result = await provider.search(
        artist: 'Artist',
        album: 'Album',
        title: 'Track',
      );

      expect(requestedUri.host, 'artwork.m8tec.top');
      expect(requestedUri.queryParameters['artist'], 'Artist');
      expect(requestedUri.queryParameters['album'], 'Album');
      expect(result?.squareUrl, 'https://cdn.example/square.m3u8');
      expect(result?.tallUrl, 'https://cdn.example/tall.m3u8');
    },
  );

  test('404 means no motion cover and rate limits are surfaced', () async {
    final missing = AppleMusicMotionProvider(
      client: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(missing.dispose);
    expect(await missing.search(artist: 'Unknown', album: 'Unknown'), isNull);

    final limited = AppleMusicMotionProvider(
      client: MockClient((_) async => http.Response('', 429)),
    );
    addTearDown(limited.dispose);
    await expectLater(
      limited.search(artist: 'Artist', album: 'Album'),
      throwsA(isA<AppleMusicMotionException>()),
    );
  });
}
