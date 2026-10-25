import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LyricsMatch {
  const LyricsMatch({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.instrumental,
    required this.plainLyrics,
    required this.syncedLyrics,
  });

  final int id;
  final String title;
  final String artist;
  final String album;
  final double durationSeconds;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  String? get preferredLyrics =>
      _nonEmpty(syncedLyrics) ?? _nonEmpty(plainLyrics);

  factory LyricsMatch.fromJson(Map<String, dynamic> json) => LyricsMatch(
    id: json['id'] as int? ?? 0,
    title: json['trackName'] as String? ?? json['name'] as String? ?? '',
    artist: json['artistName'] as String? ?? '',
    album: json['albumName'] as String? ?? '',
    durationSeconds: (json['duration'] as num?)?.toDouble() ?? 0,
    instrumental: json['instrumental'] as bool? ?? false,
    plainLyrics: json['plainLyrics'] as String?,
    syncedLyrics: json['syncedLyrics'] as String?,
  );

  static String? _nonEmpty(String? value) =>
      value?.trim().isNotEmpty == true ? value : null;
}

class LrclibProvider {
  LrclibProvider({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Directory> _getLyricsCacheDir() async {
    final support = await getApplicationSupportDirectory();
    final lyricsDir = Directory(p.join(support.path, 'Lyrics'));
    await lyricsDir.create(recursive: true);
    return lyricsDir;
  }

  String _generateCacheKey({
    required String title,
    required String artist,
    String? album,
  }) {
    final normalized = '${title.trim().toLowerCase()}-${artist.trim().toLowerCase()}';
    final albumPart = album?.trim().isNotEmpty == true ? '-${album!.trim().toLowerCase()}' : '';
    final hash = utf8.encode(normalized + albumPart);
    return crypto.sha256.convert(hash).toString().substring(0, 16);
  }

  Future<File?> _loadCachedLrc(String cacheKey) async {
    try {
      final lyricsDir = await _getLyricsCacheDir();
      final lrcFile = File(p.join(lyricsDir.path, '$cacheKey.lrc'));
      if (await lrcFile.exists()) {
        return lrcFile;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveLrc(String cacheKey, String lyrics) async {
    try {
      final lyricsDir = await _getLyricsCacheDir();
      final lrcFile = File(p.join(lyricsDir.path, '$cacheKey.lrc'));
      await lrcFile.writeAsString(lyrics, flush: true);
    } catch (_) {}
  }

  Future<List<LyricsMatch>> search({
    required String title,
    required String artist,
    String? album,
    bool useCache = true,
  }) async {
    final cacheKey = _generateCacheKey(title: title, artist: artist, album: album);
    
    if (useCache) {
      final cachedFile = await _loadCachedLrc(cacheKey);
      if (cachedFile != null) {
        try {
          final cachedLyrics = await cachedFile.readAsString();
          if (cachedLyrics.trim().isNotEmpty) {
            return [
              LyricsMatch(
                id: -1,
                title: title,
                artist: artist,
                album: album ?? '',
                durationSeconds: 0,
                instrumental: false,
                plainLyrics: cachedLyrics,
                syncedLyrics: null,
              ),
            ];
          }
        } catch (_) {}
      }
    }

    final uri = Uri.https('lrclib.net', '/api/search', {
      'track_name': title,
      'artist_name': artist,
      if (album?.trim().isNotEmpty == true) 'album_name': album!.trim(),
    });
    final response = await _client
        .get(
          uri,
          headers: {
            'User-Agent':
                'Bitwave/1.0.0 (https://github.com/prateek54353/BitWave)',
            'Lrclib-App-Id': 'Bitwave/1.0.0',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode == 404) return const [];
    if (response.statusCode == 429) {
      final retryAfter = response.headers['retry-after'];
      throw LrclibException(
        retryAfter == null
            ? 'LRCLIB is rate-limiting requests. Try again later.'
            : 'LRCLIB asks clients to wait $retryAfter seconds before retrying.',
      );
    }
    if (response.statusCode != 200) {
      throw LrclibException('LRCLIB search failed (${response.statusCode}).');
    }
    final json = jsonDecode(response.body) as List<dynamic>;
    final matches = json
        .whereType<Map<String, dynamic>>()
        .map(LyricsMatch.fromJson)
        .where((match) => !match.instrumental && match.preferredLyrics != null)
        .toList(growable: false);
    
    if (matches.isNotEmpty && matches.first.preferredLyrics != null) {
      await _saveLrc(cacheKey, matches.first.preferredLyrics!);
    }
    
    return matches;
  }

  void dispose() => _client.close();
}

class LrclibException implements Exception {
  const LrclibException(this.message);
  final String message;
  @override
  String toString() => message;
}
