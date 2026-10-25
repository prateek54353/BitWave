import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../features/library/domain/track.dart';
import '../../features/playlists/domain/playlist.dart';

class LibraryDatabase {
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final dir = await getApplicationSupportDirectory();
    _database = await openDatabase(
      p.join(dir.path, 'bitwave_library.db'),
      version: 11,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE tracks (
          id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
          artist TEXT NOT NULL, album TEXT NOT NULL, album_artist TEXT NOT NULL,
          genre TEXT NOT NULL, duration_ms INTEGER NOT NULL, format TEXT NOT NULL,
          file_size INTEGER NOT NULL, modified_ms INTEGER NOT NULL, added_ms INTEGER,
          year INTEGER,
          track_number INTEGER, disc_number INTEGER, sample_rate INTEGER, bitrate INTEGER,
          artwork BLOB, embedded_artwork_path TEXT, custom_artwork_path TEXT,
          provider_artwork_url TEXT, provider_artwork_id TEXT,
          artwork_aspect_ratio REAL, artwork_focus_x REAL NOT NULL DEFAULT 0,
          artwork_focus_y REAL NOT NULL DEFAULT 0, artwork_fit TEXT NOT NULL DEFAULT 'crop',
          animated_artwork INTEGER NOT NULL DEFAULT 0, artwork_poster_path TEXT,
          favorite INTEGER NOT NULL DEFAULT 0, lyrics TEXT,
          motion_artwork_url TEXT)''');
        await db.execute(
          'CREATE INDEX tracks_album ON tracks(album, album_artist)',
        );
        await db.execute('CREATE INDEX tracks_artist ON tracks(artist)');
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await _createPlaylistTables(db);
        await _createPlaysTable(db);
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
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE tracks ADD COLUMN lyrics TEXT');
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE tracks ADD COLUMN motion_artwork_url TEXT',
          );
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE tracks ADD COLUMN disc_number INTEGER');
        }
        if (oldVersion < 6) await _createPlaylistTables(db);
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE tracks ADD COLUMN spicy_track_id TEXT');
        }
        if (oldVersion < 8) {
          // Leave spicy_track_id column unused to avoid ALTER TABLE DROP COLUMN
          // which requires SQLite 3.35+
        }
        if (oldVersion < 9) {
          await db.execute('ALTER TABLE tracks ADD COLUMN added_ms INTEGER');
        }
        if (oldVersion < 10) {
          await db.execute('ALTER TABLE playlists ADD COLUMN image_path TEXT');
        }
        if (oldVersion < 11) {
          await _createPlaysTable(db);
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

  Future<List<Track>> allTracksWithPlayStats() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT t.*,
             (SELECT COUNT(*) FROM plays p WHERE p.track_id = t.id) AS play_count,
             (SELECT MAX(p.played_ms) FROM plays p WHERE p.track_id = t.id) AS last_played_ms
      FROM tracks t
      ORDER BY t.title COLLATE NOCASE
    ''');
    return rows
        .map((row) {
          final track = Track.fromMap(row);
          return Track(
            id: track.id,
            path: track.path,
            title: track.title,
            artist: track.artist,
            album: track.album,
            durationMs: track.durationMs,
            format: track.format,
            fileSize: track.fileSize,
            modifiedMs: track.modifiedMs,
            addedMs: track.addedMs,
            albumArtist: track.albumArtist,
            genre: track.genre,
            year: track.year,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            sampleRate: track.sampleRate,
            bitrate: track.bitrate,
            artwork: track.artwork,
            embeddedArtworkPath: track.embeddedArtworkPath,
            customArtworkPath: track.customArtworkPath,
            providerArtworkUrl: track.providerArtworkUrl,
            providerArtworkId: track.providerArtworkId,
            artworkAspectRatio: track.artworkAspectRatio,
            artworkFocusX: track.artworkFocusX,
            artworkFocusY: track.artworkFocusY,
            artworkFit: track.artworkFit,
            animatedArtwork: track.animatedArtwork,
            artworkPosterPath: track.artworkPosterPath,
            favorite: track.favorite,
            lyrics: track.lyrics,
            motionArtworkUrl: track.motionArtworkUrl,
            playCount: (row['play_count'] as int?) ?? 0,
            lastPlayedMs: row['last_played_ms'] as int?,
          );
        })
        .toList(growable: false);
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

  Future<Track?> trackAtPath(String path) async {
    final rows = await (await database).query(
      'tracks',
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  Future<void> deleteTracks(Iterable<String> ids) async {
    final db = await database;
    final batch = db.batch();
    for (final id in ids) {
      batch.delete('playlist_tracks', where: 'track_id = ?', whereArgs: [id]);
      batch.delete('tracks', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
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

  Future<void> updateLyrics({
    required String id,
    required String? lyrics,
  }) async => (await database).update(
    'tracks',
    {'lyrics': lyrics},
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
          'motion_artwork_url': null,
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
          'motion_artwork_url': null,
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

  static Future<void> _createPlaylistTables(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS playlists (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL COLLATE NOCASE UNIQUE,
      created_ms INTEGER NOT NULL,
      image_path TEXT
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS playlist_tracks (
      playlist_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      position INTEGER NOT NULL,
      PRIMARY KEY (playlist_id, track_id),
      FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
    )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS playlist_tracks_order ON playlist_tracks(playlist_id, position)',
    );
  }

  static Future<void> _createPlaysTable(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS plays (
      id TEXT PRIMARY KEY,
      track_id TEXT NOT NULL,
      played_ms INTEGER NOT NULL,
      listened_ms INTEGER NOT NULL,
      title TEXT NOT NULL,
      artist TEXT NOT NULL,
      album TEXT NOT NULL,
      album_artist TEXT NOT NULL
    )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS plays_track ON plays(track_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS plays_played ON plays(played_ms)',
    );
  }

  Future<List<Playlist>> playlists() async {
    final rows = await (await database).rawQuery('''
      SELECT p.id, p.name, p.created_ms, COUNT(pt.track_id) AS track_count
      FROM playlists p LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
      GROUP BY p.id ORDER BY p.name COLLATE NOCASE
    ''');
    return rows.map(Playlist.fromMap).toList(growable: false);
  }

  Future<String> createPlaylist(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) throw ArgumentError.value(name, 'name');
    final db = await database;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await db.insert('playlists', {
      'id': id,
      'name': normalized,
      'created_ms': DateTime.now().millisecondsSinceEpoch,
    });
    return id;
  }

  Future<void> renamePlaylist(String id, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    await (await database).update(
      'playlists',
      {'name': normalized},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setPlaylistImage(String id, String? imagePath) async {
    await (await database).update(
      'playlists',
      {'image_path': imagePath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePlaylist(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'playlist_tracks',
        where: 'playlist_id = ?',
        whereArgs: [id],
      );
      await txn.delete('playlists', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Track>> playlistTracks(String playlistId) async {
    final rows = await (await database).rawQuery(
      '''SELECT t.* FROM playlist_tracks pt
         JOIN tracks t ON t.id = pt.track_id
         WHERE pt.playlist_id = ? ORDER BY pt.position''',
      [playlistId],
    );
    return rows.map(Track.fromMap).toList(growable: false);
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
    final db = await database;
    final position =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_tracks WHERE playlist_id = ?',
            [playlistId],
          ),
        ) ??
        0;
    await db.insert('playlist_tracks', {
      'playlist_id': playlistId,
      'track_id': trackId,
      'position': position,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeTrackFromPlaylist(
    String playlistId,
    String trackId,
  ) async {
    final db = await database;
    await db.delete(
      'playlist_tracks',
      where: 'playlist_id = ? AND track_id = ?',
      whereArgs: [playlistId, trackId],
    );
    await _normalizePlaylistPositions(db, playlistId);
  }

  Future<void> movePlaylistTrack(String playlistId, int from, int to) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'playlist_tracks',
        columns: ['track_id'],
        where: 'playlist_id = ?',
        whereArgs: [playlistId],
        orderBy: 'position',
      );
      if (from < 0 || from >= rows.length || to < 0 || to >= rows.length) {
        return;
      }
      final ids = rows.map((row) => row['track_id'] as String).toList();
      final item = ids.removeAt(from);
      ids.insert(to, item);
      for (var index = 0; index < ids.length; index++) {
        await txn.update(
          'playlist_tracks',
          {'position': index},
          where: 'playlist_id = ? AND track_id = ?',
          whereArgs: [playlistId, ids[index]],
        );
      }
    });
  }

  Future<void> _normalizePlaylistPositions(
    DatabaseExecutor db,
    String playlistId,
  ) async {
    final rows = await db.query(
      'playlist_tracks',
      columns: ['track_id'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position',
    );
    for (var index = 0; index < rows.length; index++) {
      await db.update(
        'playlist_tracks',
        {'position': index},
        where: 'playlist_id = ? AND track_id = ?',
        whereArgs: [playlistId, rows[index]['track_id']],
      );
    }
  }

  Future<void> recordPlay({
    required String trackId,
    required int playedMs,
    required int listenedMs,
    required String title,
    required String artist,
    required String album,
    required String albumArtist,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    await (await database).insert('plays', {
      'id': id,
      'track_id': trackId,
      'played_ms': playedMs,
      'listened_ms': listenedMs,
      'title': title,
      'artist': artist,
      'album': album,
      'album_artist': albumArtist,
    });
  }

  Future<int> getPlayCount(String trackId) async {
    final result = Sqflite.firstIntValue(
      await (await database).rawQuery(
        'SELECT COUNT(*) FROM plays WHERE track_id = ?',
        [trackId],
      ),
    );
    return result ?? 0;
  }

  Future<int?> getLastPlayed(String trackId) async {
    final rows = await (await database).query(
      'plays',
      columns: ['played_ms'],
      where: 'track_id = ?',
      whereArgs: [trackId],
      orderBy: 'played_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['played_ms'] as int?;
  }
}
