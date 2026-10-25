import 'dart:typed_data';

class Track {
  const Track({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.format,
    required this.fileSize,
    required this.modifiedMs,
    this.addedMs,
    this.albumArtist = '',
    this.genre = '',
    this.year,
    this.trackNumber,
    this.discNumber,
    this.sampleRate,
    this.bitrate,
    this.artwork,
    this.embeddedArtworkPath,
    this.customArtworkPath,
    this.providerArtworkUrl,
    this.providerArtworkId,
    this.artworkAspectRatio,
    this.artworkFocusX = 0,
    this.artworkFocusY = 0,
    this.artworkFit = 'crop',
    this.animatedArtwork = false,
    this.artworkPosterPath,
    this.favorite = false,
    this.lyrics,
    this.motionArtworkUrl,
    this.playCount,
    this.lastPlayedMs,
  });

  final String id, path, title, artist, album, format;
  final String albumArtist, genre;
  final int durationMs, fileSize, modifiedMs;
  final int? addedMs;
  final int? year, trackNumber, discNumber, sampleRate, bitrate;
  final Uint8List? artwork;
  final String? embeddedArtworkPath;
  final String? customArtworkPath;
  final String? providerArtworkUrl;
  final String? providerArtworkId;
  final double? artworkAspectRatio;
  final double artworkFocusX, artworkFocusY;
  final String artworkFit;
  final bool animatedArtwork;
  final String? artworkPosterPath;
  final bool favorite;
  final String? lyrics;
  final String? motionArtworkUrl;
  final int? playCount;
  final int? lastPlayedMs;

  Duration get duration => Duration(milliseconds: durationMs);
  int? get bitrateKbps => bitrate == null
      ? null
      : bitrate! >= 10000
      ? (bitrate! / 1000).round()
      : bitrate;
  String get displayArtist => artist.isEmpty ? 'Unknown artist' : artist;
  String get displayAlbum => album.isEmpty ? 'Unknown album' : album;
  DateTime? get lastPlayed => lastPlayedMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastPlayedMs!);
  String? get artworkPath {
    if (customArtworkPath != null) {
      return animatedArtwork ? artworkPosterPath : customArtworkPath;
    }
    if (providerArtworkUrl != null) return null;
    return embeddedArtworkPath;
  }

  String? get motionArtworkPath => animatedArtwork ? customArtworkPath : null;
  String? get lockScreenArtworkPath => artworkPath;
  String? get artworkUrl => providerArtworkUrl;

  Map<String, Object?> toMap() => {
    'id': id,
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'album_artist': albumArtist,
    'genre': genre,
    'duration_ms': durationMs,
    'format': format,
    'file_size': fileSize,
    'modified_ms': modifiedMs,
    'added_ms': addedMs,
    'year': year,
    'track_number': trackNumber,
    'disc_number': discNumber,
    'sample_rate': sampleRate,
    'bitrate': bitrate,
    'artwork': artwork,
    'embedded_artwork_path': embeddedArtworkPath,
    'custom_artwork_path': customArtworkPath,
    'provider_artwork_url': providerArtworkUrl,
    'provider_artwork_id': providerArtworkId,
    'artwork_aspect_ratio': artworkAspectRatio,
    'artwork_focus_x': artworkFocusX,
    'artwork_focus_y': artworkFocusY,
    'artwork_fit': artworkFit,
    'animated_artwork': animatedArtwork ? 1 : 0,
    'artwork_poster_path': artworkPosterPath,
    'favorite': favorite ? 1 : 0,
    'lyrics': lyrics,
    'motion_artwork_url': motionArtworkUrl,
  };

  factory Track.fromMap(Map<String, Object?> m) => Track(
    id: m['id'] as String,
    path: m['path'] as String,
    title: m['title'] as String,
    artist: m['artist'] as String,
    album: m['album'] as String,
    albumArtist: m['album_artist'] as String? ?? '',
    genre: m['genre'] as String? ?? '',
    durationMs: m['duration_ms'] as int,
    format: m['format'] as String,
    fileSize: m['file_size'] as int,
    modifiedMs: m['modified_ms'] as int,
    addedMs: m['added_ms'] as int?,
    year: m['year'] as int?,
    trackNumber: m['track_number'] as int?,
    discNumber: m['disc_number'] as int?,
    sampleRate: m['sample_rate'] as int?,
    bitrate: m['bitrate'] as int?,
    artwork: m['artwork'] as Uint8List?,
    embeddedArtworkPath: m['embedded_artwork_path'] as String?,
    customArtworkPath: m['custom_artwork_path'] as String?,
    providerArtworkUrl: m['provider_artwork_url'] as String?,
    providerArtworkId: m['provider_artwork_id'] as String?,
    artworkAspectRatio: (m['artwork_aspect_ratio'] as num?)?.toDouble(),
    artworkFocusX: (m['artwork_focus_x'] as num?)?.toDouble() ?? 0,
    artworkFocusY: (m['artwork_focus_y'] as num?)?.toDouble() ?? 0,
    artworkFit: m['artwork_fit'] as String? ?? 'crop',
    animatedArtwork: (m['animated_artwork'] as int? ?? 0) == 1,
    artworkPosterPath: m['artwork_poster_path'] as String?,
    favorite: (m['favorite'] as int? ?? 0) == 1,
    lyrics: m['lyrics'] as String?,
    motionArtworkUrl: m['motion_artwork_url'] as String?,
  );
}
