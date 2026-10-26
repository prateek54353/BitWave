import 'dart:io';
import 'dart:convert';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/library_database.dart';
import '../domain/track.dart';
import 'audio_format_parser.dart';

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

  Future<Directory> iosLocalFilesDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(documents.path, 'Local Files'));
    await folder.create(recursive: true);
    return folder;
  }

  /// Synchronizes the user-visible iOS Files folder with the local index.
  /// File contents stay in Documents so Files and Bitwave share the same copy.
  Future<int> syncIOSLocalFiles({String? changedPath}) async {
    if (!Platform.isIOS) return 0;
    final folder = await iosLocalFilesDirectory();
    final root = p.normalize(folder.absolute.path);
    final changedPathKey = changedPath == null
        ? null
        : p.normalize(p.absolute(changedPath));
    final indexed = await database.allTracks();
    final indexedInFolder = indexed
        .where((track) => p.isWithin(root, p.normalize(track.path)))
        .toList(growable: false);
    final knownByPath = {
      for (final track in indexedInFolder) track.path: track,
    };
    final activePaths = <String>{};
    final changedFiles = <(String, String)>[];

    final files = <File>[];
    await for (final entity in folder.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File ||
          !_extensions.contains(
            p.extension(entity.path).replaceFirst('.', '').toLowerCase(),
          )) {
        continue;
      }
      files.add(entity);
    }

    // Directory enumeration is cheap; serial stat calls dominate startup for
    // folders with many songs. Bound concurrent metadata checks to avoid IO spikes.
    const batchSize = 48;
    for (var offset = 0; offset < files.length; offset += batchSize) {
      final batch = files.skip(offset).take(batchSize);
      await Future.wait(
        batch.map((entity) async {
          final path = p.normalize(entity.absolute.path);
          activePaths.add(path);
          final stat = await entity.stat();
          final old = knownByPath[path];
          if (old == null ||
              path == changedPathKey ||
              old.fileSize != stat.size ||
              old.modifiedMs != stat.modified.millisecondsSinceEpoch) {
            changedFiles.add((path, p.basename(path)));
          }
        }),
      );
    }

    if (changedFiles.isNotEmpty) {
      await _importPaths(
        changedFiles,
        copyIntoLibrary: false,
        pathBasedIds: true,
      );
    }
    final removed = indexedInFolder
        .where((track) => !activePaths.contains(p.normalize(track.path)))
        .map((track) => track.id)
        .toList(growable: false);
    if (removed.isNotEmpty) await database.deleteTracks(removed);
    return changedFiles.length + removed.length;
  }

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
    bool copyIntoLibrary = true,
    bool pathBasedIds = false,
  }) async {
    if (sources.isEmpty) return const [];
    final support = await getApplicationSupportDirectory();
    final musicDir = Directory(p.join(support.path, 'Music'));
    await musicDir.create(recursive: true);
    final imported = <Track>[];
    for (final (sourcePath, name) in sources) {
      final source = File(sourcePath);
      try {
        final existing = pathBasedIds
            ? await database.trackAtPath(source.absolute.path)
            : null;
        final destination = copyIntoLibrary
            ? p.join(
                musicDir.path,
                'import-${DateTime.now().microsecondsSinceEpoch}-${name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}',
              )
            : source.path;
        final file = copyIntoLibrary ? File(destination) : source;
        if (copyIntoLibrary) await source.copy(destination);
        if (removeSources) await source.delete();
        final stableId = pathBasedIds
            ? sha256
                  .convert(utf8.encode(p.normalize(source.absolute.path)))
                  .toString()
            : (await sha256.bind(file.openRead()).first).toString();
        if (!pathBasedIds && await database.containsTrack(stableId)) {
          await file.delete();
          continue;
        }
        AudioMetadata? meta;
        try {
          meta = readMetadata(file, getImage: true);
        } catch (_) {
          /* Untagged files remain playable. */
        }
        final formatInfo = AudioFormatParser.parseFile(file);
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
        } else {
          // A rescan may fail to re-extract a picture after an app update.
          // Keep the previous file when it is still present rather than
          // clearing the artwork reference during the metadata refresh.
          final previousPath = existing?.embeddedArtworkPath;
          if (previousPath != null && await File(previousPath).exists()) {
            embeddedPath = previousPath;
          }
        }
        final track = Track(
          id: stableId,
          path: file.path,
          title: _nonEmpty(meta?.title) ?? p.basenameWithoutExtension(name),
          artist: _nonEmpty(meta?.artist) ?? existing?.artist ?? '',
          album: _nonEmpty(meta?.album) ?? existing?.album ?? '',
          albumArtist: _nonEmpty(meta?.albumArtist) ?? existing?.albumArtist ?? '',
          genre: meta?.genres.isNotEmpty == true
              ? meta!.genres.join(', ')
              : existing?.genre ?? '',
          durationMs: meta?.duration?.inMilliseconds ?? existing?.durationMs ?? 0,
          format: p.extension(name).replaceFirst('.', '').toUpperCase(),
          fileSize: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
          year: meta?.year?.year ?? existing?.year,
          trackNumber: meta?.trackNumber ?? existing?.trackNumber,
          discNumber: meta?.discNumber ?? existing?.discNumber,
          sampleRate: meta?.sampleRate ?? existing?.sampleRate,
          bitrate: meta?.bitrate ?? existing?.bitrate,
          artwork: embedded ?? existing?.artwork,
          embeddedArtworkPath: embeddedPath,
          favorite: existing?.favorite ?? false,
          customArtworkPath: existing?.customArtworkPath,
          providerArtworkUrl: existing?.providerArtworkUrl,
          providerArtworkId: existing?.providerArtworkId,
          artworkAspectRatio: existing?.artworkAspectRatio,
          artworkFocusX: existing?.artworkFocusX ?? 0,
          artworkFocusY: existing?.artworkFocusY ?? 0,
          artworkFit: existing?.artworkFit ?? 'crop',
          animatedArtwork: existing?.animatedArtwork ?? false,
          artworkPosterPath: existing?.artworkPosterPath,
          lyrics: _nonEmpty(meta?.lyrics) ?? existing?.lyrics,
          motionArtworkUrl: existing?.motionArtworkUrl,
          bitDepth: formatInfo.bitDepth ?? existing?.bitDepth,
          channels: formatInfo.channels ?? existing?.channels,
          codec: formatInfo.codec ?? existing?.codec,
          isLossless: formatInfo.isLossless || (existing?.isLossless ?? false),
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
