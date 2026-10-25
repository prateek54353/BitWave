import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/services.dart';

import '../../../core/database/library_database.dart';
import '../../library/domain/track.dart';
import '../../lastfm/data/lastfm_scrobbler.dart';

class BitwaveAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: true,
    maxSkipsOnError: 3,
  );
  final LastFmScrobbler lastFm;
  List<Track> _tracks = [];
  AudioPlayer get player => _player;
  List<Track> get tracks => List.unmodifiable(_tracks);

  BitwaveAudioHandler({LibraryDatabase? db})
    : lastFm = LastFmScrobbler(db: db) {
    unawaited(lastFm.initialize());
    _player.playbackEventStream.listen((_) => _publishState());
    _player.currentIndexStream.listen((index) {
      if (index != null && index < _tracks.length) {
        final track = _tracks[index];
        mediaItem.add(_item(track));
        lastFm.onTrackChanged(track);
      } else if (index == null) {
        lastFm.onTrackChanged(null);
      }
      _publishState();
    });
    _player.playingStream.listen(lastFm.onPlaybackState);
    _player.positionStream.listen(lastFm.onPosition);
    _player.durationStream.listen((_) => _publishState());
    _player.shuffleModeEnabledStream.listen((_) => _publishState());
    _player.loopModeStream.listen((_) => _publishState());
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed &&
          _player.loopMode == LoopMode.one) {
        lastFm.onPosition(Duration.zero);
      }
      _publishState();
    });
  }

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
    final localPath = track.artworkPath;
    if (localPath != null) return Uri.file(localPath);
    return track.providerArtworkUrl == null
        ? null
        : Uri.tryParse(track.providerArtworkUrl!);
  }

  Future<String?> playTracks(List<Track> tracks, {int initialIndex = 0}) async {
    if (tracks.isEmpty) return null;
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
    final validTracks = <Track>[];
    final validItems = <MediaItem>[];
    for (final track in tracks) {
      if (await File(track.path).exists()) {
        validTracks.add(track);
        validItems.add(_item(track));
      }
    }
    if (validTracks.isEmpty) {
      return 'No playable files found';
    }
    _tracks = validTracks;
    queue.add(validItems);
    try {
      await _player.setAudioSources(
        validItems
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
      return 'Could not play track: $error';
    }
    return null;
  }

  Future<String?> addToQueue(Track track, {bool playNext = false}) async {
    if (!await File(track.path).exists()) {
      return 'File not found: ${track.title}';
    }
    int insertion;
    if (playNext) {
      if (_player.shuffleModeEnabled) {
        // When shuffle is enabled, insert at currentIndex+1 in the shuffled order
        final currentIndex = _player.currentIndex ?? -1;
        insertion = currentIndex + 1;
      } else {
        insertion = (_player.currentIndex ?? -1) + 1;
      }
    } else {
      insertion = _tracks.length;
    }
    final index = insertion.clamp(0, _tracks.length);
    _tracks.insert(index, track);
    try {
      await _player.insertAudioSource(
        index,
        AudioSource.file(track.path, tag: _item(track)),
      );
    } catch (error) {
      _tracks.removeAt(index);
      return 'Could not add track: $error';
    }
    queue.add(_tracks.map(_item).toList(growable: false));
    _publishState();
    return null;
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

  Future<void> keepOnlyCurrent() async {
    final currentIndex = _player.currentIndex;
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= _tracks.length) {
      return;
    }
    final toRemove = <int>[];
    for (var i = 0; i < _tracks.length; i++) {
      if (i != currentIndex) toRemove.add(i);
    }
    toRemove.sort((a, b) => b.compareTo(a));
    for (final index in toRemove) {
      await _player.removeAudioSourceAt(index);
      _tracks.removeAt(index);
    }
    queue.add(_tracks.map(_item).toList(growable: false));
    _publishState();
  }

  void updateTrackMetadata(Track track) {
    final index = _tracks.indexWhere((item) => item.id == track.id);
    if (index < 0) return;
    _tracks[index] = track;
    queue.add(_tracks.map(_item).toList(growable: false));
    if (_player.currentIndex == index) {
      mediaItem.add(_item(track));
    }
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
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipToNext() => _player.seekToNext();
  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();
  @override
  Future<void> skipToQueueItem(int index) =>
      _player.seek(Duration.zero, index: index);
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _player.setShuffleModeEnabled(
      shuffleMode == AudioServiceShuffleMode.all,
    );
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final loopMode = switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all => LoopMode.all,
      AudioServiceRepeatMode.none => LoopMode.off,
      AudioServiceRepeatMode.group => LoopMode.all,
    };
    await _player.setLoopMode(loopMode);
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
  }

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
