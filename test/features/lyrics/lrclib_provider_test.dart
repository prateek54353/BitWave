import 'dart:convert';

import 'package:bitwave/features/lyrics/data/lrclib_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('search identifies Bitwave and prefers synchronized lyrics', () async {
    late http.Request request;
    final provider = LrclibProvider(
      client: MockClient((value) async {
        request = value;
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'trackName': 'Song',
              'artistName': 'Artist',
              'albumName': 'Album',
              'duration': 180,
              'instrumental': false,
              'plainLyrics': 'plain',
              'syncedLyrics': '[00:01.00]synced',
            },
            {
              'id': 2,
              'trackName': 'Instrumental',
              'artistName': 'Artist',
              'duration': 180,
              'instrumental': true,
              'plainLyrics': null,
              'syncedLyrics': null,
            },
          ]),
          200,
        );
      }),
    );
    addTearDown(provider.dispose);

    final matches = await provider.search(
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
    );

    expect(request.url.host, 'lrclib.net');
    expect(request.headers['user-agent'], contains('Bitwave/1.0.0'));
    expect(matches, hasLength(1));
    expect(matches.single.preferredLyrics, '[00:01.00]synced');
  });

  test('429 response exposes Retry-After guidance', () async {
    final provider = LrclibProvider(
      client: MockClient(
        (_) async => http.Response('', 429, headers: {'retry-after': '10'}),
      ),
    );
    addTearDown(provider.dispose);

    await expectLater(
      provider.search(title: 'Song', artist: 'Artist'),
      throwsA(
        isA<LrclibException>().having(
          (error) => error.message,
          'message',
          contains('10 seconds'),
        ),
      ),
    );
  });
}
