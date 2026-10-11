import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../features/library/domain/track.dart';

class LibraryDatabase {
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dir = await getApplicationSupportDirectory();
    _database = await openDatabase(
      p.join(dir.path, 'bitwave_library.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE tracks (
          id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
          artist TEXT NOT NULL, album TEXT NOT NULL, album_artist TEXT NOT NULL,
          genre TEXT NOT NULL, duration_ms INTEGER NOT NULL, format TEXT NOT NULL,
          file_size INTEGER NOT NULL, modified_ms INTEGER NOT NULL, year INTEGER,
          track_number INTEGER, sample_rate INTEGER, bitrate INTEGER,
          artwork BLOB, embedded_artwork_path TEXT, custom_artwork_path TEXT,
          provider_artwork_url TEXT, provider_artwork_id TEXT,
          artwork_aspect_ratio REAL, artwork_focus_x REAL NOT NULL DEFAULT 0,
          artwork_focus_y REAL NOT NULL DEFAULT 0, artwork_fit TEXT NOT NULL DEFAULT 'crop',
          animated_artwork INTEGER NOT NULL DEFAULT 0, artwork_poster_path TEXT,
          favorite INTEGER NOT NULL DEFAULT 0)''');
        await db.execute(
          'CREATE INDEX tracks_album ON tracks(album, album_artist)',
        );
        await db.execute('CREATE INDEX tracks_artist ON tracks(artist)');
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN embedded_artwork_path TEXT',
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN custom_artwork_path TEXT',
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN provider_artwork_url TEXT',
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN provider_artwork_id TEXT',
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN artwork_aspect_ratio REAL',
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN artwork_focus_x REAL NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN artwork_focus_y REAL NOT NULL DEFAULT 0',
          );
          await db.execute(
            "ALTER TABLE tracks ADD COLUMN artwork_fit TEXT NOT NULL DEFAULT 'crop'",
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN animated_artwork INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN artwork_poster_path TEXT',
          );
          await db.execute(
            'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        }
      },
    );
    return _database!;
  }

  Future<List<Track>> allTracks() async {
    final db = await database;
    final rows = await db.query('tracks', orderBy: 'title COLLATE NOCASE');
    return rows.map(Track.fromMap).toList(growable: false);
  }

  Future<void> upsert(Track track) async => (await database).insert(
    'tracks',
    track.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<bool> containsTrack(String id) async {
    final rows = await (await database).query(
      'tracks',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> setFavorite(Track track, bool value) async =>
      (await database).update(
        'tracks',
        {'favorite': value ? 1 : 0},
        where: 'id = ?',
        whereArgs: [track.id],
      );

  Future<int> count() async =>
      Sqflite.firstIntValue(
        await (await database).rawQuery('SELECT COUNT(*) FROM tracks'),
      ) ??
      0;

  Future<void> updateTags({
    required String id,
    required String title,
    required String artist,
    required String album,
    required String albumArtist,
    required String genre,
    required int? year,
  }) async => (await database).update(
    'tracks',
    {
      'title': title,
      'artist': artist,
      'album': album,
      'album_artist': albumArtist,
      'genre': genre,
      'year': year,
    },
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> saveArtwork({
    required List<String> trackIds,
    String? localPath,
    String? providerUrl,
    String? providerId,
    double? aspectRatio,
    double focusX = 0,
    double focusY = 0,
    String fit = 'crop',
    bool animated = false,
    String? posterPath,
  }) async {
    if (trackIds.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in trackIds) {
      batch.update(
        'tracks',
        {
          'custom_artwork_path': localPath,
          'provider_artwork_url': providerUrl,
          'provider_artwork_id': providerId,
          'artwork_aspect_ratio': aspectRatio,
          'artwork_focus_x': focusX,
          'artwork_focus_y': focusY,
          'artwork_fit': fit,
          'animated_artwork': animated ? 1 : 0,
          'artwork_poster_path': posterPath,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> resetArtwork(List<String> trackIds) async {
    if (trackIds.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in trackIds) {
      batch.update(
        'tracks',
        {
          'custom_artwork_path': null,
          'provider_artwork_url': null,
          'provider_artwork_id': null,
          'artwork_aspect_ratio': null,
          'artwork_focus_x': 0,
          'artwork_focus_y': 0,
          'artwork_fit': 'crop',
          'animated_artwork': 0,
          'artwork_poster_path': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Set<String>> artworkPathsInUse() async {
    final rows = await (await database).query(
      'tracks',
      columns: ['custom_artwork_path', 'artwork_poster_path'],
    );
    return rows
        .expand(
          (row) => [row['custom_artwork_path'], row['artwork_poster_path']],
        )
        .whereType<String>()
        .toSet();
  }

  Future<String?> getSetting(String key) async {
    final rows = await (await database).query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async =>
      (await database).insert('settings', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
}
