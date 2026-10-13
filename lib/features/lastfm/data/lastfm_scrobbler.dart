import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../library/domain/track.dart';

/// Last.fm native-app authentication and scrobbling integration.
///
/// The API credentials are intentionally embedded at the user's request. A
/// distributed mobile binary can be inspected, so these are not confidential.
class LastFmScrobbler {
  static const _apiKey = 'c533badbe30753eabcf3322d09949eaa';
  static const _sharedSecret = 'abdbbdd811c17d98fb2678f00bd41571';
  static final _endpoint = Uri.https('ws.audioscrobbler.com', '/2.0/');
  static const _storage = FlutterSecureStorage();

  static const _sessionKeyName = 'lastfm.session_key';
  static const _usernameName = 'lastfm.username';
  static const _enabledName = 'lastfm.enabled';
  static const _tokenName = 'lastfm.auth_token';

  final http.Client _client;
  LastFmScrobbler({http.Client? client}) : _client = client ?? http.Client();

  String? _sessionKey;
  String? _username;
  bool _enabled = false;
  Future<void>? _initialization;
  Track? _track;
  bool _playing = false;
  Duration? _lastPosition;
  Duration _heard = Duration.zero;
  DateTime? _startedAt;
  bool _sentForCurrentTrack = false;

  Future<void> initialize() => _initialization ??= _loadStored();

  Future<void> _loadStored() async {
    _sessionKey = await _storage.read(key: _sessionKeyName);
    _username = await _storage.read(key: _usernameName);
    _enabled = await _storage.read(key: _enabledName) == 'true';
  }

  bool get connected => _sessionKey?.isNotEmpty == true;
  bool get enabled => _enabled;
  String? get username => _username;

  Future<Uri> beginAuthorization() async {
    await initialize();
    final response = await _request({'method': 'auth.getToken'});
    final token = response['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const LastFmException(
        'Last.fm did not return an authorization token.',
      );
    }
    await _storage.write(key: _tokenName, value: token);
    return Uri.https('www.last.fm', '/api/auth/', {
      'api_key': _apiKey,
      'token': token,
    });
  }

  Future<String> completeAuthorization() async {
    await initialize();
    final token = await _storage.read(key: _tokenName);
    if (token == null || token.isEmpty) {
      throw const LastFmException('Start the Last.fm authorization first.');
    }
    final response = await _request({
      'method': 'auth.getSession',
      'token': token,
    });
    final session = response['session'];
    if (session is! Map<String, dynamic>) {
      throw const LastFmException('Last.fm returned an invalid session.');
    }
    final key = session['key'] as String?;
    final name = session['name'] as String?;
    if (key == null || key.isEmpty || name == null || name.isEmpty) {
      throw const LastFmException(
        'Last.fm returned incomplete account details.',
      );
    }
    _sessionKey = key;
    _username = name;
    await _storage.write(key: _sessionKeyName, value: key);
    await _storage.write(key: _usernameName, value: name);
    await _storage.delete(key: _tokenName);
    await setEnabled(true);
    return name;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value && connected;
    await _storage.write(key: _enabledName, value: '$_enabled');
  }

  Future<void> disconnect() async {
    _enabled = false;
    _sessionKey = null;
    _username = null;
    await _storage.delete(key: _sessionKeyName);
    await _storage.delete(key: _usernameName);
    await _storage.delete(key: _enabledName);
    await _storage.delete(key: _tokenName);
  }

  void onTrackChanged(Track? track) {
    if (_track?.id == track?.id) return;
    _track = track;
    _heard = Duration.zero;
    _lastPosition = null;
    _startedAt = DateTime.now();
    _sentForCurrentTrack = false;
    if (track != null && _playing) unawaited(_updateNowPlaying(track));
  }

  void onPlaybackState(bool playing) {
    final becamePlaying = playing && !_playing;
    _playing = playing;
    if (becamePlaying && _track != null) {
      _startedAt ??= DateTime.now();
      unawaited(_updateNowPlaying(_track!));
    }
  }

  void onPosition(Duration position) {
    final previous = _lastPosition;
    _lastPosition = position;
    final track = _track;
    if (!_playing ||
        track == null ||
        _sentForCurrentTrack ||
        previous == null) {
      return;
    }
    final delta = position - previous;
    // Count only natural playback progression, excluding seeks and buffering jumps.
    if (delta > Duration.zero && delta <= const Duration(seconds: 3)) {
      _heard += delta;
    }
    final duration = track.duration;
    if (duration <= const Duration(seconds: 30)) return;
    final threshold = duration ~/ 2 < const Duration(minutes: 4)
        ? duration ~/ 2
        : const Duration(minutes: 4);
    if (_heard >= threshold) {
      _sentForCurrentTrack = true;
      unawaited(
        _scrobble(
          track,
          (_startedAt ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
        ),
      );
    }
  }

  Future<void> _updateNowPlaying(Track track) async {
    await initialize();
    if (!connected || !_enabled) return;
    try {
      await _request({
        'method': 'track.updateNowPlaying',
        'sk': _sessionKey!,
        'artist': track.displayArtist,
        'track': track.title,
        'album': track.displayAlbum,
        'duration': '${track.duration.inSeconds}',
      });
    } catch (_) {
      // Scrobbling is best effort and must never interfere with local playback.
    }
  }

  Future<void> _scrobble(Track track, int timestamp) async {
    await initialize();
    if (!connected || !_enabled) return;
    try {
      await _request({
        'method': 'track.scrobble',
        'sk': _sessionKey!,
        'artist': track.displayArtist,
        'track': track.title,
        'album': track.displayAlbum,
        'duration': '${track.duration.inSeconds}',
        'timestamp': '$timestamp',
      });
    } catch (_) {
      // Network errors are intentionally isolated from playback.
    }
  }

  Future<Map<String, dynamic>> _request(Map<String, String> parameters) async {
    final signed = <String, String>{...parameters, 'api_key': _apiKey};
    signed['api_sig'] = _signature(signed);
    signed['format'] = 'json';
    final response = await _client
        .post(_endpoint, body: signed)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw LastFmException('Last.fm request failed (${response.statusCode}).');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const LastFmException('Last.fm returned an invalid response.');
    }
    if (decoded['error'] != null) {
      final message = decoded['message'] is String
          ? decoded['message'] as String
          : 'The request was rejected.';
      throw LastFmException(message);
    }
    return decoded;
  }

  String _signature(Map<String, String> parameters) {
    final keys = parameters.keys.toList()..sort();
    final canonical = StringBuffer();
    for (final key in keys) {
      if (key == 'format' || key == 'callback' || key == 'api_sig') continue;
      canonical
        ..write(key)
        ..write(parameters[key]);
    }
    canonical.write(_sharedSecret);
    return md5.convert(utf8.encode(canonical.toString())).toString();
  }
}

class LastFmException implements Exception {
  final String message;
  const LastFmException(this.message);
  @override
  String toString() => message;
}
