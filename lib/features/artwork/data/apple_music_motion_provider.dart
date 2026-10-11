import 'dart:convert';

import 'package:http/http.dart' as http;

class AppleMusicMotionMatch {
  const AppleMusicMotionMatch({
    required this.artist,
    required this.album,
    this.squareUrl,
    this.tallUrl,
  });

  final String artist;
  final String album;
  final String? squareUrl;
  final String? tallUrl;

  factory AppleMusicMotionMatch.fromJson(Map<String, dynamic> json) =>
      AppleMusicMotionMatch(
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        squareUrl: json['url'] as String?,
        tallUrl: json['url_tall'] as String?,
      );
}

class AppleMusicMotionProvider {
  AppleMusicMotionProvider({http.Client? client})
    : _client = client ?? http.Client();

  static final Uri _baseUri = Uri.https('artwork.m8tec.top');
  final http.Client _client;

  Future<AppleMusicMotionMatch?> search({
    required String artist,
    required String album,
    String? title,
  }) async {
    final uri = _baseUri.replace(
      path: '/api/v1/artwork/search',
      queryParameters: {
        'artist': artist,
        'album': album,
        if (title?.trim().isNotEmpty == true) 'title': title!.trim(),
      },
    );
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode == 404) return null;
    if (response.statusCode == 429) {
      throw const AppleMusicMotionException(
        'The motion artwork service is rate-limited. Try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw AppleMusicMotionException(
        'Motion artwork search failed (${response.statusCode}).',
      );
    }
    final result = AppleMusicMotionMatch.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    if ((result.squareUrl ?? result.tallUrl) == null) return null;
    return result;
  }

  void dispose() => _client.close();
}

class AppleMusicMotionException implements Exception {
  const AppleMusicMotionException(this.message);
  final String message;
  @override
  String toString() => message;
}
