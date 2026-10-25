import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LrcRedMatch {
  const LrcRedMatch({
    required this.isrc,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.syncType,
    required this.lines,
  });

  final String isrc;
  final String title;
  final String artist;
  final String album;
  final double duration;
  final String syncType;
  final int lines;

  factory LrcRedMatch.fromJson(Map<String, dynamic> json) => LrcRedMatch(
    isrc: json['isrc'] as String? ?? '',
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    album: json['album'] as String? ?? '',
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    syncType: json['sync'] as String? ?? 'line',
    lines: json['lines'] as int? ?? 0,
  );
}

class LrcRedProvider {
  LrcRedProvider({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Directory> _getLyricsCacheDir() async {
    final support = await getApplicationSupportDirectory();
    final lyricsDir = Directory(p.join(support.path, 'Lyrics'));
    await lyricsDir.create(recursive: true);
    return lyricsDir;
  }

  Future<File?> _loadCachedLrc(String isrc) async {
    try {
      final lyricsDir = await _getLyricsCacheDir();
      final lrcFile = File(p.join(lyricsDir.path, 'lrc_red_$isrc.lrc'));
      if (await lrcFile.exists()) {
        return lrcFile;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveLrc(String isrc, String lyrics) async {
    try {
      final lyricsDir = await _getLyricsCacheDir();
      final lrcFile = File(p.join(lyricsDir.path, 'lrc_red_$isrc.lrc'));
      await lrcFile.writeAsString(lyrics, flush: true);
    } catch (_) {}
  }

  Future<List<LrcRedMatch>> search({
    required String title,
    required String artist,
    String? album,
    bool useCache = true,
  }) async {
    final query = [title, artist].where((s) => s.trim().isNotEmpty).join(' ');
    final uri = Uri.https('lrc.red', '/search.json', {
      'q': query.trim(),
    });

    final response = await _client
        .get(
          uri,
          headers: {
            'User-Agent':
                'Bitwave/1.0.0 (https://github.com/prateek54353/BitWave; devin@devin.ai)',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode == 404) return const [];
    if (response.statusCode == 429) {
      throw const LrcRedException(
        'lrc.red rate limit reached. Try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw LrcRedException(
        'lrc.red search failed (${response.statusCode}).',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final hits = json['hits'] as List<dynamic>? ?? const [];
    
    return hits
        .whereType<Map<String, dynamic>>()
        .map(LrcRedMatch.fromJson)
        .toList(growable: false);
  }

  Future<String?> fetchLrc(String isrc, {bool useCache = true}) async {
    if (useCache) {
      final cachedFile = await _loadCachedLrc(isrc);
      if (cachedFile != null) {
        try {
          final cachedLyrics = await cachedFile.readAsString();
          if (cachedLyrics.trim().isNotEmpty) {
            return cachedLyrics;
          }
        } catch (_) {}
      }
    }

    final uri = Uri.https('lrc.red', '/s/$isrc.lrc');
    final response = await _client
        .get(
          uri,
          headers: {
            'User-Agent':
                'Bitwave/1.0.0 (https://github.com/prateek54353/BitWave; devin@devin.ai)',
            'Accept': 'text/plain',
          },
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode == 404) return null;
    if (response.statusCode == 429) {
      throw const LrcRedException(
        'lrc.red rate limit reached. Try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw LrcRedException(
        'lrc.red lyrics fetch failed (${response.statusCode}).',
      );
    }

    final lyrics = response.body;
    if (lyrics.trim().isNotEmpty) {
      await _saveLrc(isrc, lyrics);
    }
    return lyrics;
  }

  void dispose() => _client.close();
}

class LrcRedException implements Exception {
  const LrcRedException(this.message);
  final String message;
  @override
  String toString() => message;
}
