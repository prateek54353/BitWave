import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/services.dart';

import '../../library/domain/track.dart';

class BitwaveAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  BitwaveAudioHandler() {
    _player.playbackEventStream.listen((_) => _publishState());
    _player.currentIndexStream.listen((index) {
      if (index != null && index < _tracks.length) {
        final track = _tracks[index];
        mediaItem.add(_item(track));
        _publishIosAnimatedArtwork(track);
      }
      _publishState();
    });
    _player.durationStream.listen((_) => _publishState());
    _player.shuffleModeEnabledStream.listen((_) => _publishState());
    _player.loopModeStream.listen((_) => _publishState());
  }

  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: true,
    maxSkipsOnError: 3,
  );
  static const MethodChannel _iosArtworkChannel = MethodChannel(
    'org.bitwave.dev/now_playing_artwork',
  );
  List<Track> _tracks = [];
  AudioPlayer get player => _player;
  List<Track> get tracks => List.unmodifiable(_tracks);

  static MediaItem _item(Track track) => MediaItem(
    id: track.id,
    title: track.title,
    artist: track.displayArtist,
    album: track.displayAlbum,
    duration: track.duration,
    artUri: _artUri(track),
    extras: {'path': track.path},
  );

  static Uri? _artUri(Track track) {
    // Motion art is rendered only in Bitwave; expose its generated still frame
    // to Android and iOS system media surfaces.
    final localPath = track.customArtworkPath != null
        ? track.animatedArtwork
              ? track.artworkPosterPath ?? track.embeddedArtworkPath
              : track.customArtworkPath
        : track.embeddedArtworkPath;
    if (localPath != null) return Uri.file(localPath);
    return track.providerArtworkUrl == null
        ? null
        : Uri.tryParse(track.providerArtworkUrl!);
  }

  Future<void> playTracks(List<Track> tracks, {int initialIndex = 0}) async {
    if (tracks.isEmpty) return;
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('org.bitwave.dev/notifications')
            .invokeMethod<bool>('requestPermission');
      } on PlatformException {
        // Audio playback remains available when notification permission is denied.
      } on MissingPluginException {
        // Notification permission is managed by the host platform.
      }
    }
    _tracks = List.of(tracks);
    final items = _tracks.map(_item).toList(growable: false);
    queue.add(items);
    try {
      await _player.setAudioSources(
        items
            .asMap()
            .entries
            .map(
              (entry) =>
                  AudioSource.file(_tracks[entry.key].path, tag: entry.value),
            )
            .toList(growable: false),
        initialIndex: initialIndex.clamp(0, _tracks.length - 1),
      );
      await _player.play();
    } catch (error) {
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: 'This file could not be played: $error',
        ),
      );
      rethrow;
    }
  }

  Future<void> addToQueue(Track track, {bool playNext = false}) async {
    final insertion = playNext
        ? (_player.currentIndex ?? -1) + 1
        : _tracks.length;
    final index = insertion.clamp(0, _tracks.length);
    _tracks.insert(index, track);
    await _player.insertAudioSource(
      index,
      AudioSource.file(track.path, tag: _item(track)),
    );
    queue.add(_tracks.map(_item).toList(growable: false));
    _publishState();
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    _tracks.removeAt(index);
    await _player.removeAudioSourceAt(index);
    queue.add(_tracks.map(_item).toList(growable: false));
    _publishState();
  }

  Future<void> moveQueueItem(int from, int to) async {
    if (from < 0 || from >= _tracks.length || to < 0 || to >= _tracks.length) {
      return;
    }
    final item = _tracks.removeAt(from);
    _tracks.insert(to, item);
    await _player.moveAudioSource(from, to);
    queue.add(_tracks.map(_item).toList(growable: false));
    _publishState();
  }

  Future<void> clearQueue() async {
    await _player.stop();
    await _player.clearAudioSources();
    _tracks = [];
    queue.add(const []);
    mediaItem.add(null);
    _publishState();
  }

  void updateTrackMetadata(Track track) {
    final index = _tracks.indexWhere((item) => item.id == track.id);
    if (index < 0) return;
    _tracks[index] = track;
    queue.add(_tracks.map(_item).toList(growable: false));
    if (_player.currentIndex == index) {
      mediaItem.add(_item(track));
      _publishIosAnimatedArtwork(track);
    }
  }

  void _publishIosAnimatedArtwork(Track track) {
    if (!Platform.isIOS) return;
    final videoPath = track.motionArtworkPath;
    final videoUrl = track.motionArtworkUrl;
    final posterPath = track.artworkPosterPath;
    final extension = videoPath?.toLowerCase().split('.').last;
    final localVideoSupported =
        videoPath != null && const {'mp4', 'mov', 'm4v'}.contains(extension);
    if (!localVideoSupported && videoUrl == null) {
      _iosArtworkChannel
          .invokeMethod<void>('clearAnimatedArtwork')
          .catchError((Object _) {});
      return;
    }
    final previewPath =
        posterPath ?? track.embeddedArtworkPath ?? track.customArtworkPath;
    _iosArtworkChannel
        .invokeMethod<void>('setAnimatedArtwork', {
          'artworkId':
              '${track.id}:${track.modifiedMs}:${videoUrl ?? videoPath}',
          if (localVideoSupported) 'videoPath': videoPath,
          if (!localVideoSupported) 'videoUrl': videoUrl,
          if (previewPath != null) 'posterPath': previewPath,
          if (track.providerArtworkUrl != null)
            'posterUrl': track.providerArtworkUrl,
          'aspectRatio': track.artworkAspectRatio ?? 1.0,
        })
        .catchError((Object _) {
          // Older iOS releases keep the static poster and normal playback controls.
        });
  }

  Future<void> toggleShuffle() async =>
      _player.setShuffleModeEnabled(!_player.shuffleModeEnabled);

  Future<void> cycleRepeat() async {
    final next = switch (_player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _player.setLoopMode(next);
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipToNext() => _player.seekToNext();
  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();
  @override
  Future<void> skipToQueueItem(int index) =>
      _player.seek(Duration.zero, index: index);

  void _publishState() {
    final event = _player.playbackEvent;
    final playing = _player.playing;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {MediaAction.seek},
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: event.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
        repeatMode: switch (_player.loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: _player.shuffleModeEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }
}
