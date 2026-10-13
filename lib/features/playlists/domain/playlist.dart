class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.createdMs,
    required this.trackCount,
  });

  final String id;
  final String name;
  final int createdMs;
  final int trackCount;

  factory Playlist.fromMap(Map<String, Object?> map) => Playlist(
    id: map['id'] as String,
    name: map['name'] as String,
    createdMs: map['created_ms'] as int,
    trackCount: (map['track_count'] as int?) ?? 0,
  );
}
