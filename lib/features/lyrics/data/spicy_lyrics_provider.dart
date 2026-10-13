import 'dart:convert';

import 'package:http/http.dart' as http;

class SpicyLyricsResult {
  const SpicyLyricsResult({
    required this.trackId,
    required this.source,
    required this.syncType,
    required this.lines,
    this.uploader,
    this.maker,
  });

  final String trackId;
  final String source;
  final String syncType;
  final List<SpicyLyricsLine> lines;
  final SpicyLyricsContributor? uploader;
  final SpicyLyricsContributor? maker;

  String encode() =>
      'BITWAVE_SPICY_LYRICS:${jsonEncode({'trackId': trackId, 'source': source, 'syncType': syncType, 'lines': lines.map((line) => line.toJson()).toList(), 'uploader': uploader?.toJson(), 'maker': maker?.toJson()})}';

  factory SpicyLyricsResult.fromJson(String serialized) {
    const prefix = 'BITWAVE_SPICY_LYRICS:';
    final decoded = jsonDecode(serialized.substring(prefix.length));
    final map = decoded as Map<String, dynamic>;
    return SpicyLyricsResult(
      trackId: map['trackId'] as String? ?? '',
      source: map['source'] as String? ?? 'unknown',
      syncType: map['syncType'] as String? ?? 'Static',
      lines: (map['lines'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SpicyLyricsLine.fromJson)
          .toList(growable: false),
      uploader: map['uploader'] is Map<String, dynamic>
          ? SpicyLyricsContributor.fromJson(
              map['uploader'] as Map<String, dynamic>,
            )
          : null,
      maker: map['maker'] is Map<String, dynamic>
          ? SpicyLyricsContributor.fromJson(
              map['maker'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}

class SpicyLyricsLine {
  const SpicyLyricsLine({
    required this.start,
    required this.end,
    required this.words,
  });

  final Duration start;
  final Duration end;
  final List<SpicyLyricsWord> words;

  factory SpicyLyricsLine.fromJson(Map<String, dynamic> map) => SpicyLyricsLine(
    start: Duration(milliseconds: (map['startMs'] as num).round()),
    end: Duration(milliseconds: (map['endMs'] as num).round()),
    words: (map['words'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SpicyLyricsWord.fromJson)
        .toList(growable: false),
  );

  Map<String, Object> toJson() => {
    'startMs': start.inMilliseconds,
    'endMs': end.inMilliseconds,
    'words': words.map((word) => word.toJson()).toList(),
  };
}

class SpicyLyricsWord {
  const SpicyLyricsWord(this.text, this.start, this.end, this.partOfWord);

  final String text;
  final Duration start;
  final Duration end;
  final bool partOfWord;

  factory SpicyLyricsWord.fromJson(Map<String, dynamic> map) => SpicyLyricsWord(
    map['text'] as String? ?? '',
    Duration(milliseconds: (map['startMs'] as num).round()),
    Duration(milliseconds: (map['endMs'] as num).round()),
    map['partOfWord'] as bool? ?? false,
  );

  Map<String, Object> toJson() => {
    'text': text,
    'startMs': start.inMilliseconds,
    'endMs': end.inMilliseconds,
    'partOfWord': partOfWord,
  };
}

class SpicyLyricsContributor {
  const SpicyLyricsContributor(this.name, this.url);
  final String name;
  final String? url;

  factory SpicyLyricsContributor.fromJson(Map<String, dynamic> map) =>
      SpicyLyricsContributor(
        map['username'] as String? ?? '',
        map['url'] as String?,
      );

  Map<String, Object?> toJson() => {'username': name, 'url': url};
}

class SpicyLyricsProvider {
  SpicyLyricsProvider({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;

  Future<SpicyLyricsResult> fetch({
    required String spotifyTrackId,
    required String apiKey,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(spotifyTrackId)) {
      throw const SpicyLyricsException(
        'Enter a valid 22-character Spotify track ID or link.',
      );
    }
    final response = await _client
        .get(
          Uri.https('api.spicylyrics.org', '/v1/lyrics/$spotifyTrackId'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) {
      throw const SpicyLyricsException(
        'No Spicy Lyrics match was found for this Spotify track.',
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const SpicyLyricsException(
        'Spicy Lyrics rejected the API key. Check it in Settings.',
      );
    }
    if (response.statusCode == 429) {
      throw const SpicyLyricsException(
        'Spicy Lyrics rate limit reached. Try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw SpicyLyricsException(
        'Spicy Lyrics request failed (${response.statusCode}).',
      );
    }
    final envelope = jsonDecode(response.body) as Map<String, dynamic>;
    final body = envelope['Body'] as Map<String, dynamic>?;
    if (body == null) {
      throw const SpicyLyricsException('Spicy Lyrics returned no lyric data.');
    }

    final lines = <SpicyLyricsLine>[];
    for (final content in body['Content'] as List<dynamic>? ?? const []) {
      if (content is! Map<String, dynamic>) continue;
      final lead = content['Lead'];
      if (lead is! Map<String, dynamic>) continue;
      final words = <SpicyLyricsWord>[];
      for (final syllable in lead['Syllables'] as List<dynamic>? ?? const []) {
        if (syllable is! Map<String, dynamic>) continue;
        final text = syllable['Text'] as String? ?? '';
        final start = syllable['StartTime'];
        final end = syllable['EndTime'];
        if (text.isEmpty || start is! num || end is! num) continue;
        words.add(
          SpicyLyricsWord(
            text,
            Duration(milliseconds: (start * 1000).round()),
            Duration(milliseconds: (end * 1000).round()),
            syllable['IsPartOfWord'] as bool? ?? false,
          ),
        );
      }
      if (words.isEmpty) continue;
      words.sort((a, b) => a.start.compareTo(b.start));
      lines.add(
        SpicyLyricsLine(
          start: words.first.start,
          end: words.last.end,
          words: words,
        ),
      );
    }
    lines.sort((a, b) => a.start.compareTo(b.start));
    if (lines.isEmpty) {
      throw const SpicyLyricsException('This result has no word-level timing.');
    }

    final attribution = body['UploadAttribution'] as Map<String, dynamic>?;
    return SpicyLyricsResult(
      trackId: spotifyTrackId,
      source: body['source'] as String? ?? 'unknown',
      syncType: body['Type'] as String? ?? 'Syllable',
      lines: lines,
      uploader: attribution?['Uploader'] is Map<String, dynamic>
          ? SpicyLyricsContributor.fromJson(
              attribution!['Uploader'] as Map<String, dynamic>,
            )
          : null,
      maker: attribution?['Maker'] is Map<String, dynamic>
          ? SpicyLyricsContributor.fromJson(
              attribution!['Maker'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  void dispose() => _client.close();
}

class SpicyLyricsException implements Exception {
  const SpicyLyricsException(this.message);
  final String message;
  @override
  String toString() => message;
}
