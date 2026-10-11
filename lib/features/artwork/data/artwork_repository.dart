import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../../core/database/library_database.dart';
import '../../library/domain/track.dart';
import '../domain/artwork_asset.dart';

class ArtworkRepository {
  ArtworkRepository(this.database);
  final LibraryDatabase database;

  Future<ArtworkAsset?> importStillImage() async {
    final picks = await FilePicker.pickFiles(type: FileType.image);
    if (picks.isEmpty || picks.first.path == null) return null;
    final source = File(picks.first.path!);
    final stat = await source.stat();
    if (stat.size <= 0 || stat.size > 40 * 1024 * 1024) {
      throw const ArtworkImportException('Choose an image smaller than 40 MB.');
    }
    final bytes = await source.readAsBytes();
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 1200,
        targetHeight: 1600,
      );
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      final height = frame.image.height;
      if (width < 1 || height < 1) {
        throw const ArtworkImportException('This image could not be decoded.');
      }
      final directory = await _artworkDirectory();
      final hash = sha256.convert(bytes).toString();
      final ext = p.extension(source.path).toLowerCase();
      final stored = await _copyOnce(source, directory, '$hash$ext');
      final animated = codec.frameCount > 1;
      final posterPath = animated
          ? await _writePoster(frame.image, directory, '$hash-poster.png')
          : null;
      frame.image.dispose();
      return ArtworkAsset(
        path: stored,
        aspectRatio: width / height,
        animated: animated,
        posterPath: posterPath,
      );
    } finally {
      codec?.dispose();
    }
  }

  Future<ArtworkAsset?> importMotionArtwork() async {
    final picks = await FilePicker.pickFiles(type: FileType.video);
    if (picks.isEmpty || picks.first.path == null) return null;
    final source = File(picks.first.path!);
    final ext = p.extension(source.path).toLowerCase();
    if (!const {'.mp4', '.mov'}.contains(ext)) {
      throw const ArtworkImportException(
        'Motion artwork currently accepts MP4 and MOV files.',
      );
    }
    final stat = await source.stat();
    if (stat.size <= 0 || stat.size > 40 * 1024 * 1024) {
      throw const ArtworkImportException(
        'Choose a motion cover smaller than 40 MB.',
      );
    }
    final directory = await _artworkDirectory();
    final tempName = 'motion-${DateTime.now().microsecondsSinceEpoch}$ext';
    final target = File(p.join(directory.path, tempName));
    await source.copy(target.path);
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(
        target,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await controller.initialize().timeout(const Duration(seconds: 12));
      final duration = controller.value.duration;
      final size = controller.value.size;
      if (duration < const Duration(milliseconds: 500) ||
          duration > const Duration(seconds: 20)) {
        throw const ArtworkImportException(
          'Motion covers must be 0.5–20 seconds long.',
        );
      }
      if (size.width < 1 ||
          size.height < 1 ||
          size.width > 4096 ||
          size.height > 4096) {
        throw const ArtworkImportException(
          'Motion cover dimensions must be 1–4096 pixels per side.',
        );
      }
      final poster = await VideoThumbnail.thumbnailFile(
        video: target.path,
        thumbnailPath: p.join(directory.path, '$tempName-poster.jpg'),
        imageFormat: ImageFormat.JPEG,
        maxWidth: 1400,
        timeMs: 0,
        quality: 90,
      );
      if (poster == null) {
        throw const ArtworkImportException(
          'Bitwave could not create a poster frame for this video.',
        );
      }
      return ArtworkAsset(
        path: target.path,
        aspectRatio: size.width / size.height,
        animated: true,
        posterPath: poster,
      );
    } catch (error) {
      if (await target.exists()) await target.delete();
      rethrow;
    } finally {
      await controller?.dispose();
    }
  }

  Future<void> assign({
    required List<Track> tracks,
    required ArtworkAsset asset,
    required double? cropRatio,
    required double focusX,
    required double focusY,
    required String fit,
  }) async {
    final oldPaths = tracks
        .expand((track) => [track.customArtworkPath, track.artworkPosterPath])
        .whereType<String>()
        .toSet();
    await database.saveArtwork(
      trackIds: tracks.map((t) => t.id).toList(growable: false),
      localPath: asset.path,
      aspectRatio: cropRatio ?? asset.aspectRatio,
      focusX: focusX,
      focusY: focusY,
      fit: fit,
      animated: asset.animated,
      posterPath: asset.posterPath,
    );
    await _deleteUnused(oldPaths);
  }

  Future<void> assignAppleMatch(
    List<Track> tracks,
    AppleArtworkMatch match,
    int width,
    int height,
  ) async {
    final oldPaths = tracks
        .expand((track) => [track.customArtworkPath, track.artworkPosterPath])
        .whereType<String>()
        .toSet();
    await database.saveArtwork(
      trackIds: tracks.map((t) => t.id).toList(growable: false),
      providerUrl: match.artworkAt(width, height),
      providerId: '${match.type}:${match.id}',
    );
    await _deleteUnused(oldPaths);
  }

  Future<void> reset(List<Track> tracks) async {
    final oldPaths = tracks
        .expand((track) => [track.customArtworkPath, track.artworkPosterPath])
        .whereType<String>()
        .toSet();
    await database.resetArtwork(
      tracks.map((t) => t.id).toList(growable: false),
    );
    await _deleteUnused(oldPaths);
  }

  Future<void> _deleteUnused(Set<String> candidates) async {
    if (candidates.isEmpty) return;
    final inUse = await database.artworkPathsInUse();
    for (final path in candidates.difference(inUse)) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<Directory> _artworkDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'Artwork'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> _copyOnce(
    File source,
    Directory directory,
    String name,
  ) async {
    final target = File(p.join(directory.path, name));
    if (!await target.exists()) await source.copy(target.path);
    return target.path;
  }

  Future<String> _writePoster(
    ui.Image image,
    Directory directory,
    String name,
  ) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw const ArtworkImportException(
        'A static preview could not be created.',
      );
    }
    final file = File(p.join(directory.path, name));
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }
}

class ArtworkImportException implements Exception {
  const ArtworkImportException(this.message);
  final String message;
  @override
  String toString() => message;
}
