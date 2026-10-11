import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/artwork_asset.dart';

class AppleMusicArtworkProvider {
  AppleMusicArtworkProvider({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;

  Future<List<AppleArtworkMatch>> search({
    required String term,
    required String developerToken,
    String storefront = 'us',
  }) async {
    final uri = Uri.https(
      'api.music.apple.com',
      '/v1/catalog/$storefront/search',
      {'term': term, 'types': 'albums,songs', 'limit': '25'},
    );
    final response = await _client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer $developerToken',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const AppleMusicProviderException(
        'The Apple Music developer token was rejected. Check that it is current.',
      );
    }
    if (response.statusCode == 429) {
      throw const AppleMusicProviderException(
        'Apple Music has temporarily rate-limited this search. Try again later.',
      );
    }
    if (response.statusCode != 200) {
      throw AppleMusicProviderException(
        'Apple Music search failed (${response.statusCode}).',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final results = json['results'] as Map<String, dynamic>? ?? {};
    final matches = <AppleArtworkMatch>[];
    for (final type in ['albums', 'songs']) {
      final collection = results[type] as Map<String, dynamic>?;
      for (final item in collection?['data'] as List<dynamic>? ?? const []) {
        final match = AppleArtworkMatch.fromJson(item as Map<String, dynamic>);
        if (match.artworkUrl.isNotEmpty) matches.add(match);
      }
    }
    return matches;
  }

  void dispose() => _client.close();
}

class AppleMusicProviderException implements Exception {
  const AppleMusicProviderException(this.message);
  final String message;
  @override
  String toString() => message;
}
