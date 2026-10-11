class ArtworkAsset {
  const ArtworkAsset({
    required this.path,
    required this.aspectRatio,
    this.animated = false,
    this.posterPath,
  });

  final String path;
  final double aspectRatio;
  final bool animated;
  final String? posterPath;
}

class AppleArtworkMatch {
  const AppleArtworkMatch({
    required this.id,
    required this.type,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkUrl,
    required this.storeUrl,
    this.year,
  });

  final String id, type, title, artist, album, artworkUrl;
  final String? storeUrl;
  final int? year;

  factory AppleArtworkMatch.fromJson(Map<String, dynamic> json) {
    final attributes = json['attributes'] as Map<String, dynamic>? ?? {};
    final image = attributes['artwork'] as Map<String, dynamic>? ?? {};
    final release = attributes['releaseDate'] as String?;
    return AppleArtworkMatch(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? '',
      title:
          (attributes['name'] as String?) ??
          (attributes['albumName'] as String?) ??
          'Unknown release',
      artist: attributes['artistName'] as String? ?? '',
      album:
          attributes['albumName'] as String? ??
          attributes['name'] as String? ??
          '',
      artworkUrl: image['url'] as String? ?? '',
      storeUrl: attributes['url'] as String?,
      year: release == null ? null : int.tryParse(release.substring(0, 4)),
    );
  }

  String artworkAt(int width, int height) =>
      artworkUrl.replaceAll('{w}', '$width').replaceAll('{h}', '$height');
}
