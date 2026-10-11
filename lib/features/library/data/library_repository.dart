import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/library_database.dart';
import '../domain/track.dart';

class LibraryRepository {
  LibraryRepository(this.database);
  final LibraryDatabase database;
  static const _extensions = [
    'mp3',
    'm4a',
    'aac',
    'flac',
    'wav',
    'ogg',
    'opus',
    'aiff',
    'ape',
  ];

  Future<List<Track>> load() => database.allTracks();

  Future<List<Track>> importAudio() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _extensions,
    );
    if (result.isEmpty) return const [];
    return _importPaths([
      for (final picked in result)
        if (picked.path != null) (picked.path!, picked.name),
    ]);
  }

  Future<List<Track>> importAudioFolder() async {
    final paths = <String>[];
    if (Platform.isIOS) {
      final result = await const MethodChannel('org.bitwave.dev/folder_import')
          .invokeMapMethod<String, dynamic>('pickAndStageFolder');
      if (result?['error'] is String) {
        throw StateError(result!['error'] as String);
      }
      paths.addAll(
        (result?['files'] as List?)?.whereType<String>() ?? const [],
      );
    } else {
      final directoryPath = await FilePicker.getDirectoryPath();
      if (directoryPath == null) return const [];
      final directory = Directory(directoryPath);
      if (!await directory.exists()) return const [];
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is File &&
            _extensions.contains(
              p.extension(entry.path).replaceFirst('.', '').toLowerCase(),
            )) {
          paths.add(entry.path);
        }
      }
    }
    return _importPaths([
      for (final source in paths) (source, p.basename(source)),
    ], removeSources: Platform.isIOS);
  }

  Future<List<Track>> _importPaths(
    List<(String path, String name)> sources, {
    bool removeSources = false,
  }) async {
    if (sources.isEmpty) return const [];
    final support = await getApplicationSupportDirectory();
    final musicDir = Directory(p.join(support.path, 'Music'));
    await musicDir.create(recursive: true);
    final imported = <Track>[];
    for (final (sourcePath, name) in sources) {
      final source = File(sourcePath);
      try {
        final destination = p.join(
          musicDir.path,
          'import-${DateTime.now().microsecondsSinceEpoch}-${name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}',
        );
        final file = File(destination);
        await source.copy(destination);
        if (removeSources) await source.delete();
        final hash = await sha256.bind(file.openRead()).first;
        final stableId = hash.toString();
        if (await database.containsTrack(stableId)) {
          await file.delete();
          continue;
        }
        AudioMetadata? meta;
        try {
          meta = readMetadata(file, getImage: true);
        } catch (_) {
          /* Untagged files remain playable. */
        }
        final stat = await file.stat();
        final embeddedPicture = meta?.pictures
            .where((p) => p.bytes.isNotEmpty)
            .firstOrNull;
        final embedded = embeddedPicture?.bytes;
        String? embeddedPath;
        if (embedded != null) {
          final ext = embeddedPicture!.mimetype.split('/').last.toLowerCase();
          final safeExt = RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext)
              ? ext
              : 'jpg';
          embeddedPath = p.join(
            support.path,
            'Artwork',
            'embedded-$stableId.$safeExt',
          );
          final artFile = File(embeddedPath);
          await artFile.parent.create(recursive: true);
          await artFile.writeAsBytes(embedded, flush: true);
        }
        final track = Track(
          id: stableId,
          path: file.path,
          title: _nonEmpty(meta?.title) ?? p.basenameWithoutExtension(name),
          artist: _nonEmpty(meta?.artist) ?? '',
          album: _nonEmpty(meta?.album) ?? '',
          albumArtist: _nonEmpty(meta?.albumArtist) ?? '',
          genre: meta?.genres.join(', ') ?? '',
          durationMs: meta?.duration?.inMilliseconds ?? 0,
          format: p.extension(name).replaceFirst('.', '').toUpperCase(),
          fileSize: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
          year: meta?.year?.year,
          trackNumber: meta?.trackNumber,
          sampleRate: meta?.sampleRate,
          bitrate: meta?.bitrate,
          artwork: embedded,
          embeddedArtworkPath: embeddedPath,
          lyrics: _nonEmpty(meta?.lyrics),
        );
        await database.upsert(track);
        imported.add(track);
      } catch (_) {
        // One malformed or inaccessible selection must not abort the rest.
        if (removeSources) {
          try {
            if (await source.exists()) await source.delete();
          } catch (_) {}
        }
      }
    }
    return imported;
  }

  static String? _nonEmpty(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : null;
}
