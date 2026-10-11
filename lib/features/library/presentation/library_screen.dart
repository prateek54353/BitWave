import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../data/library_repository.dart';
import '../domain/track.dart';
import '../../player/data/bitwave_audio_handler.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../artwork/presentation/artwork_editor_sheet.dart';
import 'track_details_page.dart';

enum LibrarySection {
  library,
  albums,
  artists,
  songs,
  favorites,
  queue,
  settings,
}

enum LibraryView { songs, albums, artists, genres }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.library, required this.audio});
  final LibraryRepository library;
  final BitwaveAudioHandler audio;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Track> _tracks = [];
  LibrarySection _section = LibrarySection.library;
  LibraryView _view = LibraryView.songs;
  bool _grid = true;
  bool _searching = false;
  bool _scanning = false;
  String _query = '';
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  String _artworkStyle = 'automatic';
  bool _animatedArtworkEnabled = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final tracks = await widget.library.load();
    final style = await widget.library.database.getSetting(
      'now_playing_artwork_style',
    );
    final motion = await widget.library.database.getSetting(
      'animated_artwork_enabled',
    );
    if (mounted) {
      setState(() {
        _tracks = tracks;
        _artworkStyle = style ?? 'automatic';
        _animatedArtworkEnabled = motion != 'false';
      });
    }
    for (final queuedTrack in widget.audio.tracks) {
      final updated = tracks
          .where((track) => track.id == queuedTrack.id)
          .firstOrNull;
      if (updated != null) widget.audio.updateTrackMetadata(updated);
    }
  }

  Future<void> _openTrackDetails(Track track) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrackDetailsPage(
          track: track,
          library: widget.library,
          audio: widget.audio,
          artworkRepository: ArtworkRepository(widget.library.database),
          onUpdated: _refresh,
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _editArtwork(List<Track> tracks) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: BitwaveColors.panel,
    builder: (_) => ArtworkEditorSheet(
      tracks: tracks,
      repository: ArtworkRepository(widget.library.database),
      onSaved: _refresh,
    ),
  );

  Future<void> _import() async {
    setState(() => _scanning = true);
    try {
      final imported = await widget.library.importAudio();
      await _refresh();
      if (mounted && imported.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${imported.length} ${imported.length == 1 ? 'track' : 'tracks'} to your library',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Import failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  List<Track> get _visibleTracks {
    var tracks = _tracks;
    if (_section == LibrarySection.favorites) {
      tracks = tracks.where((t) => t.favorite).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      tracks = tracks
          .where(
            (t) => '${t.title} ${t.artist} ${t.album} ${t.genre}'
                .toLowerCase()
                .contains(q),
          )
          .toList();
    }
    return tracks;
  }

  String get _title => switch (_section) {
    LibrarySection.library => 'Your library',
    LibrarySection.albums => 'Albums',
    LibrarySection.artists => 'Artists',
    LibrarySection.songs => 'Songs',
    LibrarySection.favorites => 'Favorites',
    LibrarySection.queue => 'Queue',
    LibrarySection.settings => 'Settings',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _drawer(),
      appBar: AppBar(
        toolbarHeight: 64,
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: 'Open navigation',
            icon: const Icon(Icons.menu_rounded),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: _searching
            ? TextField(
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(fontSize: 17),
                decoration: const InputDecoration(
                  hintText: 'Search your library',
                  border: InputBorder.none,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: BitwaveColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'BITWAVE',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.2,
                    ),
                  ),
                ],
              ),
        actions: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            icon: Icon(_searching ? Icons.close : Icons.search_rounded),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _query = '';
            }),
          ),
          IconButton(
            tooltip: 'Import audio',
            onPressed: _scanning ? null : _import,
            icon: _scanning
                ? const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _section == LibrarySection.settings
          ? _settingsPage()
          : _section == LibrarySection.queue
          ? _queuePage()
          : _libraryPage(),
      bottomNavigationBar: _miniPlayer(),
    );
  }

  Widget _libraryPage() {
    final tracks = _visibleTracks;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 7, 18, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _title,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -.8,
                  ),
                ),
              ),
              if (_section != LibrarySection.favorites)
                IconButton(
                  tooltip: _grid ? 'Show list' : 'Show grid',
                  onPressed: () => setState(() => _grid = !_grid),
                  icon: Icon(
                    _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                    color: BitwaveColors.muted,
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: 'Sort library',
                icon: const Icon(
                  Icons.sort_rounded,
                  color: BitwaveColors.muted,
                ),
                onSelected: (_) => setState(
                  () => _tracks.sort(
                    (a, b) =>
                        a.title.toLowerCase().compareTo(b.title.toLowerCase()),
                  ),
                ),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'title', child: Text('Title A–Z')),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
          child: Row(
            children: [
              Text(
                '${tracks.length} ${tracks.length == 1 ? 'track' : 'tracks'}',
                style: const TextStyle(
                  color: BitwaveColors.muted,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              if (_section == LibrarySection.library)
                DropdownButton<LibraryView>(
                  value: _view,
                  underline: const SizedBox.shrink(),
                  isDense: true,
                  style: const TextStyle(
                    color: BitwaveColors.paper,
                    fontSize: 13,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: LibraryView.songs,
                      child: Text('Songs'),
                    ),
                    DropdownMenuItem(
                      value: LibraryView.albums,
                      child: Text('Albums'),
                    ),
                    DropdownMenuItem(
                      value: LibraryView.artists,
                      child: Text('Artists'),
                    ),
                    DropdownMenuItem(
                      value: LibraryView.genres,
                      child: Text('Genres'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _view = value);
                  },
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: BitwaveColors.line),
        Expanded(
          child: tracks.isEmpty
              ? _emptyLibrary()
              : _view == LibraryView.songs
              ? _songList(tracks)
              : _view == LibraryView.albums
              ? _albumBrowser(tracks)
              : _view == LibraryView.artists
              ? _artistBrowser(tracks)
              : _genreBrowser(tracks),
        ),
      ],
    );
  }

  Widget _emptyLibrary() => Center(
    child: Padding(
      padding: const EdgeInsets.all(34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: BitwaveColors.panel,
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(
              Icons.album_outlined,
              size: 32,
              color: BitwaveColors.accent,
            ),
          ),
          const SizedBox(height: 19),
          const Text(
            'A library of your own',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          const Text(
            'Import audio files from your device. Bitwave keeps a private copy and indexes their tags for offline listening.',
            textAlign: TextAlign.center,
            style: TextStyle(color: BitwaveColors.muted, height: 1.45),
          ),
          const SizedBox(height: 21),
          FilledButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.add),
            label: const Text('Import music'),
          ),
        ],
      ),
    ),
  );

  Widget _songList(List<Track> tracks) => ListView.builder(
    padding: const EdgeInsets.only(bottom: 14),
    itemCount: tracks.length,
    itemBuilder: (context, index) => _trackRow(tracks[index], index, tracks),
  );

  Widget _trackRow(
    Track track,
    int index,
    List<Track> contextTracks,
  ) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
    leading: _artwork(track, 50),
    title: Text(
      track.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        '${track.displayArtist}  ·  ${track.displayAlbum}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: BitwaveColors.muted),
      ),
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track.durationMs > 0 ? _time(track.duration) : track.format,
          style: const TextStyle(fontSize: 12, color: BitwaveColors.muted),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz, color: BitwaveColors.muted),
          onSelected: (v) async {
            if (v == 'queue') await widget.audio.addToQueue(track);
            if (v == 'next') {
              await widget.audio.addToQueue(track, playNext: true);
            }
            if (v == 'tags') await _openTrackDetails(track);
            if (v == 'artwork') await _editArtwork([track]);
            if (v == 'favorite') {
              await widget.library.database.setFavorite(track, !track.favorite);
              await _refresh();
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'queue', child: Text('Add to queue')),
            const PopupMenuItem(value: 'next', child: Text('Play next')),
            const PopupMenuItem(value: 'tags', child: Text('View / edit tags')),
            const PopupMenuItem(value: 'artwork', child: Text('Edit artwork')),
            PopupMenuItem(
              value: 'favorite',
              child: Text(
                track.favorite ? 'Remove favorite' : 'Add to favorites',
              ),
            ),
          ],
        ),
      ],
    ),
    onTap: () => widget.audio.playTracks(contextTracks, initialIndex: index),
  );

  Widget _albumBrowser(List<Track> tracks) {
    final albums = <String, List<Track>>{};
    for (final track in tracks) {
      albums
          .putIfAbsent(
            '${track.displayAlbum}\u0000${track.albumArtist.isEmpty ? track.displayArtist : track.albumArtist}',
            () => [],
          )
          .add(track);
    }
    final entries = albums.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    if (!_grid) {
      return ListView.builder(
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final t = e.value.first;
          return ListTile(
            leading: _artwork(t, 52),
            title: Text(t.displayAlbum),
            subtitle: Text(
              '${t.albumArtist.isEmpty ? t.displayArtist : t.albumArtist}  ·  ${e.value.length} tracks',
              style: const TextStyle(color: BitwaveColors.muted, fontSize: 12),
            ),
            onTap: () => _openAlbum(e.value),
          );
        },
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(19, 15, 19, 22),
      itemCount: entries.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: .76,
        crossAxisSpacing: 14,
        mainAxisSpacing: 18,
      ),
      itemBuilder: (_, i) {
        final e = entries[i];
        final t = e.value.first;
        return InkWell(
          onTap: () => _openAlbum(e.value),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Center(child: _artwork(t, 158, radius: 7))),
              const SizedBox(height: 9),
              Text(
                t.displayAlbum,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                t.albumArtist.isEmpty ? t.displayArtist : t.albumArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: BitwaveColors.muted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _artistBrowser(List<Track> tracks) {
    final artists = <String, List<Track>>{};
    for (final track in tracks) {
      artists.putIfAbsent(track.displayArtist, () => []).add(track);
    }
    final names = artists.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ListView.builder(
      itemCount: names.length,
      itemBuilder: (_, i) {
        final name = names[i];
        final items = artists[name]!;
        return ListTile(
          leading: _artwork(items.first, 48, radius: 24),
          title: Text(name),
          subtitle: Text(
            '${items.length} tracks',
            style: const TextStyle(color: BitwaveColors.muted),
          ),
          onTap: () => _showTrackSheet(name, items),
        );
      },
    );
  }

  Widget _genreBrowser(List<Track> tracks) {
    final genres = <String, List<Track>>{};
    for (final t in tracks) {
      genres
          .putIfAbsent(t.genre.isEmpty ? 'Uncategorized' : t.genre, () => [])
          .add(t);
    }
    final names = genres.keys.toList()..sort();
    return ListView.builder(
      itemCount: names.length,
      itemBuilder: (_, i) => ListTile(
        leading: const Icon(Icons.graphic_eq, color: BitwaveColors.accent),
        title: Text(names[i]),
        subtitle: Text(
          '${genres[names[i]]!.length} tracks',
          style: const TextStyle(color: BitwaveColors.muted),
        ),
        onTap: () => _showTrackSheet(names[i], genres[names[i]]!),
      ),
    );
  }

  void _openAlbum(List<Track> tracks) =>
      _showTrackSheet(tracks.first.displayAlbum, tracks);
  void _showTrackSheet(String title, List<Track> tracks) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: BitwaveColors.panel,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .78,
            child: Column(
              children: [
                const SizedBox(height: 9),
                Container(
                  width: 34,
                  height: 4,
                  decoration: BoxDecoration(
                    color: BitwaveColors.muted.withValues(alpha: .5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 18, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit album artwork',
                        onPressed: () => _editArtwork(tracks),
                        icon: const Icon(Icons.image_outlined),
                      ),
                      IconButton(
                        onPressed: () => widget.audio.playTracks(tracks),
                        icon: const Icon(
                          Icons.play_circle_fill,
                          color: BitwaveColors.accent,
                          size: 34,
                        ),
                      ),
                      IconButton(
                        onPressed: () =>
                            widget.audio.playTracks(List.of(tracks)..shuffle()),
                        icon: const Icon(Icons.shuffle_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (_, i) => _trackRow(tracks[i], i, tracks),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _drawer() => Drawer(
    backgroundColor: BitwaveColors.panel,
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(23, 26, 20, 21),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: BitwaveColors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Text(
                      'BITWAVE',
                      style: TextStyle(
                        letterSpacing: 2.3,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 17),
                Text(
                  '${_tracks.length} tracks  ·  ${_albumCount()} albums',
                  style: const TextStyle(
                    color: BitwaveColors.muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: BitwaveColors.line),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _navItem(
                  LibrarySection.library,
                  Icons.home_outlined,
                  'Library',
                ),
                _navItem(LibrarySection.albums, Icons.album_outlined, 'Albums'),
                _navItem(
                  LibrarySection.artists,
                  Icons.person_outline_rounded,
                  'Artists',
                ),
                _navItem(
                  LibrarySection.songs,
                  Icons.music_note_outlined,
                  'Songs',
                ),
                _navItem(
                  LibrarySection.favorites,
                  Icons.favorite_border_rounded,
                  'Favorites',
                ),
                _navItem(
                  LibrarySection.queue,
                  Icons.queue_music_rounded,
                  'Queue',
                ),
                _navItem(
                  LibrarySection.settings,
                  Icons.tune_rounded,
                  'Settings',
                ),
              ],
            ),
          ),
          StreamBuilder<MediaItem?>(
            stream: widget.audio.mediaItem,
            builder: (_, snap) {
              final item = snap.data;
              if (item == null) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(
                  Icons.graphic_eq,
                  color: BitwaveColors.accent,
                ),
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.artist ?? '',
                  style: const TextStyle(color: BitwaveColors.muted),
                ),
                trailing: IconButton(
                  onPressed: widget.audio.playbackState.value.playing
                      ? widget.audio.pause
                      : widget.audio.play,
                  icon: Icon(
                    widget.audio.playbackState.value.playing
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _openPlayer();
                },
              );
            },
          ),
          const SizedBox(height: 10),
        ],
      ),
    ),
  );

  Widget _navItem(
    LibrarySection section,
    IconData icon,
    String text,
  ) => ListTile(
    selected: _section == section,
    selectedTileColor: BitwaveColors.elevated,
    leading: Icon(
      icon,
      color: _section == section ? BitwaveColors.accent : BitwaveColors.muted,
    ),
    title: Text(
      text,
      style: TextStyle(
        color: _section == section ? BitwaveColors.paper : BitwaveColors.muted,
        fontSize: 14,
      ),
    ),
    onTap: () {
      setState(() {
        _section = section;
        if (section == LibrarySection.albums) _view = LibraryView.albums;
        if (section == LibrarySection.artists) _view = LibraryView.artists;
        if (section == LibrarySection.songs ||
            section == LibrarySection.favorites) {
          _view = LibraryView.songs;
        }
      });
      Navigator.pop(context);
    },
  );

  Widget _miniPlayer() => StreamBuilder<MediaItem?>(
    stream: widget.audio.mediaItem,
    builder: (context, snap) {
      final item = snap.data;
      if (item == null) return const SizedBox.shrink();
      return Material(
        color: BitwaveColors.panel,
        child: InkWell(
          onTap: _openPlayer,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<Duration>(
                  stream: widget.audio.player.positionStream,
                  builder: (_, pos) {
                    final duration = item.duration ?? Duration.zero;
                    final value = duration.inMilliseconds == 0
                        ? 0.0
                        : (pos.data?.inMilliseconds ?? 0) /
                              duration.inMilliseconds;
                    return LinearProgressIndicator(
                      value: value.clamp(0, 1),
                      minHeight: 2,
                      backgroundColor: BitwaveColors.line,
                      color: BitwaveColors.accent,
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 13, 8),
                  child: Row(
                    children: [
                      _artwork(_trackById(item.id), 40, radius: 5),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              item.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: BitwaveColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: widget.audio.skipToPrevious,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      StreamBuilder<bool>(
                        stream: widget.audio.player.playingStream,
                        initialData: widget.audio.player.playing,
                        builder: (_, p) => IconButton(
                          onPressed: p.data == true
                              ? widget.audio.pause
                              : widget.audio.play,
                          icon: Icon(
                            p.data == true
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 28,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: widget.audio.skipToNext,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _queuePage() => StreamBuilder<List<MediaItem>>(
    stream: widget.audio.queue,
    initialData: widget.audio.queue.valueOrNull ?? const [],
    builder: (context, queueSnapshot) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 19, 15),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Up next  ·  ${queueSnapshot.data?.length ?? 0}',
                  style: const TextStyle(fontSize: 24),
                ),
              ),
              TextButton(
                onPressed: () async {
                  final current = widget.audio.player.currentIndex ?? 0;
                  final keep = widget.audio.tracks.isEmpty
                      ? null
                      : widget.audio.tracks[current.clamp(
                          0,
                          widget.audio.tracks.length - 1,
                        )];
                  if (keep != null) await widget.audio.playTracks([keep]);
                },
                child: const Text('Keep current'),
              ),
              IconButton(
                tooltip: 'Clear queue',
                onPressed: widget.audio.tracks.isEmpty
                    ? null
                    : () async {
                        final clear = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Clear the queue?'),
                            content: const Text(
                              'Playback will stop and every queued track will be removed.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Clear'),
                              ),
                            ],
                          ),
                        );
                        if (clear == true) await widget.audio.clearQueue();
                      },
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: BitwaveColors.muted,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: BitwaveColors.line),
        Expanded(
          child: widget.audio.tracks.isEmpty
              ? const Center(
                  child: Text(
                    'Your queue is empty',
                    style: TextStyle(color: BitwaveColors.muted),
                  ),
                )
              : ReorderableListView.builder(
                  itemCount: widget.audio.tracks.length,
                  onReorderItem: widget.audio.moveQueueItem,
                  itemBuilder: (_, i) {
                    final t = widget.audio.tracks[i];
                    return ListTile(
                      key: ValueKey(t.id),
                      leading: _artwork(t, 44),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        t.displayArtist,
                        style: const TextStyle(
                          color: BitwaveColors.muted,
                          fontSize: 12,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.close,
                          color: BitwaveColors.muted,
                        ),
                        onPressed: () => widget.audio.removeFromQueue(i),
                      ),
                      onTap: () => widget.audio.skipToQueueItem(i),
                    );
                  },
                ),
        ),
      ],
    ),
  );

  Widget _settingsPage() => ListView(
    padding: const EdgeInsets.fromLTRB(22, 15, 22, 28),
    children: [
      _settingHeading('LIBRARY'),
      _settingRow(
        Icons.library_music_outlined,
        'Local music',
        '${_tracks.length} tracks',
        onTap: _import,
      ),
      _settingRow(
        Icons.add_circle_outline,
        'Import audio files',
        'Choose files from this device',
        onTap: _import,
      ),
      _settingHeading('ARTWORK PROVIDERS'),
      _settingRow(
        Icons.music_note_rounded,
        'Apple Music',
        'Catalog search and manual artwork selection',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AppleMusicArtworkSettingsPage(
              database: widget.library.database,
            ),
          ),
        ),
      ),
      _settingHeading('APPEARANCE · NOW PLAYING'),
      _settingRow(
        Icons.crop_portrait_rounded,
        'Artwork style',
        _artworkStyleLabel(_artworkStyle),
        onTap: _chooseArtworkStyle,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(
          Icons.motion_photos_on_outlined,
          color: BitwaveColors.muted,
        ),
        title: const Text('Animated artwork'),
        subtitle: const Text(
          'Play imported motion covers in the full player',
          style: TextStyle(color: BitwaveColors.muted, fontSize: 12),
        ),
        value: _animatedArtworkEnabled,
        onChanged: (value) async {
          await widget.library.database.setSetting(
            'animated_artwork_enabled',
            '$value',
          );
          if (mounted) setState(() => _animatedArtworkEnabled = value);
        },
      ),
      _settingHeading('PLAYBACK'),
      _settingRow(
        Icons.timer_outlined,
        'Sleep timer',
        _sleepDeadline == null
            ? 'Off'
            : 'Stops at ${TimeOfDay.fromDateTime(_sleepDeadline!).format(context)}',
        onTap: _chooseSleepTimer,
      ),
      _settingHeading('AUDIO'),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.equalizer_rounded, color: BitwaveColors.muted),
        title: Text('Equalizer'),
        subtitle: Text(
          'Processing controls are not available in the current playback backend',
          style: TextStyle(color: BitwaveColors.muted, fontSize: 12),
        ),
      ),
      _settingHeading('ABOUT'),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.graphic_eq_rounded, color: BitwaveColors.accent),
        title: Text('Bitwave'),
        subtitle: Text(
          'Offline-first listening  ·  Version 1.0.0',
          style: TextStyle(color: BitwaveColors.muted, fontSize: 12),
        ),
      ),
    ],
  );

  Widget _settingHeading(String label) => Padding(
    padding: const EdgeInsets.only(top: 27, bottom: 7),
    child: Text(
      label,
      style: const TextStyle(
        color: BitwaveColors.accent,
        fontWeight: FontWeight.w700,
        fontSize: 11,
        letterSpacing: 1.6,
      ),
    ),
  );
  Widget _settingRow(
    IconData icon,
    String title,
    String value, {
    VoidCallback? onTap,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: BitwaveColors.muted),
    title: Text(title),
    subtitle: Text(
      value,
      style: const TextStyle(color: BitwaveColors.muted, fontSize: 12),
    ),
    trailing: const Icon(
      Icons.chevron_right_rounded,
      color: BitwaveColors.muted,
    ),
    onTap: onTap,
  );

  String _artworkStyleLabel(String value) => switch (value) {
    'square' => 'Square',
    'portrait' => 'Portrait',
    'original' => 'Original aspect ratio',
    _ => 'Automatic',
  };

  Future<void> _chooseArtworkStyle() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BitwaveColors.panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Now Playing artwork')),
            for (final entry in const {
              'automatic': 'Automatic',
              'square': 'Square',
              'portrait': 'Portrait',
              'original': 'Original aspect ratio',
            }.entries)
              ListTile(
                title: Text(entry.value),
                trailing: _artworkStyle == entry.key
                    ? const Icon(Icons.check, color: BitwaveColors.accent)
                    : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (value == null) return;
    await widget.library.database.setSetting(
      'now_playing_artwork_style',
      value,
    );
    if (mounted) setState(() => _artworkStyle = value);
  }

  Future<void> _chooseSleepTimer() async {
    final minutes = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: BitwaveColors.panel,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Stop playback after',
                style: TextStyle(fontSize: 19),
              ),
            ),
            ...[15, 30, 45, 60].map(
              (m) => ListTile(
                title: Text('$m minutes'),
                onTap: () => Navigator.pop(context, m),
              ),
            ),
            if (_sleepDeadline != null)
              ListTile(
                title: const Text('Cancel timer'),
                onTap: () => Navigator.pop(context, 0),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (minutes == null) return;
    _sleepTimer?.cancel();
    if (minutes == 0) {
      setState(() => _sleepDeadline = null);
      return;
    }
    final deadline = DateTime.now().add(Duration(minutes: minutes));
    _sleepTimer = Timer(Duration(minutes: minutes), widget.audio.pause);
    setState(() => _sleepDeadline = deadline);
  }

  void _openPlayer() => Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) => _NowPlayingScreen(
        audio: widget.audio,
        artworkStyle: _artworkStyle,
        animatedArtworkEnabled: _animatedArtworkEnabled,
        onOpenDetails: _openTrackDetails,
      ),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, .04), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: FadeTransition(opacity: animation, child: child),
      ),
    ),
  );

  Widget _artwork(Track? track, double size, {double radius = 8}) {
    Widget child;
    if (track?.artworkPath != null) {
      child = Image.file(
        File(track!.artworkPath!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => _fallbackArt(size),
      );
    } else if (track?.providerArtworkUrl != null) {
      child = Image.network(
        track!.providerArtworkUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => track.embeddedArtworkPath == null
            ? _fallbackArt(size)
            : Image.file(
                File(track.embeddedArtworkPath!),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallbackArt(size),
              ),
      );
    } else if (track?.artwork != null) {
      child = Image.memory(
        track!.artwork!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _fallbackArt(size),
      );
    } else {
      child = _fallbackArt(size);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  Widget _fallbackArt(double size) => Container(
    color: const Color(0xFF1B2022),
    child: Center(
      child: Icon(
        Icons.graphic_eq_rounded,
        size: size.isInfinite ? 30 : size * .38,
        color: BitwaveColors.accent,
      ),
    ),
  );
  Track? _trackById(String id) {
    for (final t in _tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  int _albumCount() =>
      _tracks.map((t) => '${t.album}|${t.albumArtist}').toSet().length;
  static String _time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _NowPlayingScreen extends StatefulWidget {
  const _NowPlayingScreen({
    required this.audio,
    required this.artworkStyle,
    required this.animatedArtworkEnabled,
    required this.onOpenDetails,
  });

  final BitwaveAudioHandler audio;
  final String artworkStyle;
  final bool animatedArtworkEnabled;
  final ValueChanged<Track> onOpenDetails;

  @override
  State<_NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<_NowPlayingScreen> {
  bool _immersiveArtwork = false;

  double _aspectRatio(Track? track) => switch (widget.artworkStyle) {
    'square' => 1,
    'portrait' => .75,
    'original' => track?.artworkAspectRatio?.clamp(.4, 2.5) ?? 1,
    _ => track?.artworkAspectRatio?.clamp(.5625, 1.5) ?? 1,
  };

  @override
  Widget build(BuildContext context) => StreamBuilder<MediaItem?>(
    stream: widget.audio.mediaItem,
    builder: (context, snapshot) {
      final item = snapshot.data;
      if (item == null) return const SizedBox.shrink();
      final track = widget.audio.tracks
          .where((t) => t.id == item.id)
          .firstOrNull;
      final ratio = _aspectRatio(track);

      return Scaffold(
        backgroundColor: const Color(0xFF100D0C),
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (track != null)
              _artworkBackdrop(track, immersive: _immersiveArtwork),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xD0180B06),
                    Color(0x8829160E),
                    Color(0xC51B100B),
                    Color(0xF2100D0C),
                  ],
                  stops: [0, .44, .73, 1],
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final artHeight = math.min(
                    constraints.maxWidth / ratio,
                    constraints.maxHeight * .48,
                  );
                  final artWidth = artHeight * ratio;
                  return Column(
                    children: [
                      SizedBox(
                        height: constraints.maxHeight < 700
                            ? constraints.maxHeight * .06
                            : constraints.maxHeight * .10,
                      ),
                      Center(
                        child: SizedBox(
                          width: artWidth,
                          height: artHeight,
                          child: track == null
                              ? const _ArtworkPlaceholder()
                              : GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => widget.audio.player.playing
                                      ? widget.audio.pause()
                                      : widget.audio.play(),
                                  onDoubleTap: () => setState(
                                    () =>
                                        _immersiveArtwork = !_immersiveArtwork,
                                  ),
                                  onHorizontalDragEnd: (details) {
                                    final velocity =
                                        details.primaryVelocity ?? 0;
                                    if (velocity < -250) {
                                      widget.audio.skipToNext();
                                    }
                                    if (velocity > 250) {
                                      Navigator.of(context).maybePop();
                                    }
                                  },
                                  child: _immersiveArtwork
                                      ? const SizedBox.expand()
                                      : _NowPlayingArtwork(
                                          key: ValueKey(track.id),
                                          track: track,
                                          animated:
                                              widget.animatedArtworkEnabled &&
                                              !MediaQuery.disableAnimationsOf(
                                                context,
                                              ),
                                        ),
                                ),
                        ),
                      ),
                      SizedBox(height: constraints.maxHeight * .09),
                      if (track?.lyrics?.trim().isNotEmpty == true)
                        _PlayerLyricLabel(
                          lyrics: track!.lyrics!,
                          positionStream: widget.audio.player.positionStream,
                        )
                      else
                        const SizedBox(height: 24),
                      const SizedBox(height: 8),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(32, 0, 25, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: track == null
                                    ? null
                                    : () => widget.onOpenDetails(track),
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 27,
                                          height: 1.08,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -.8,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        [
                                          track?.displayArtist ??
                                              item.artist ??
                                              'Unknown artist',
                                          if ((track?.displayAlbum ?? '')
                                              .isNotEmpty)
                                            track!.displayAlbum,
                                          if (track?.year != null)
                                            '${track!.year}',
                                        ].join('  ·  '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      StreamBuilder<Duration>(
                        stream: widget.audio.player.positionStream,
                        builder: (context, positionSnapshot) {
                          final duration = item.duration ?? Duration.zero;
                          final position =
                              positionSnapshot.data ?? Duration.zero;
                          final max = duration.inMilliseconds.toDouble();
                          final value = max <= 0
                              ? 0.0
                              : position.inMilliseconds
                                    .clamp(0, duration.inMilliseconds)
                                    .toDouble();
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 27),
                            child: Column(
                              children: [
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2.5,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 3.2,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14,
                                    ),
                                  ),
                                  child: Slider(
                                    value: value,
                                    max: max <= 0 ? 1 : max,
                                    onChanged: max <= 0
                                        ? null
                                        : (next) => widget.audio.seek(
                                            Duration(
                                              milliseconds: next.round(),
                                            ),
                                          ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        _format(position),
                                        style: const TextStyle(
                                          color: Color(0xFFC4BFBD),
                                          fontSize: 12,
                                        ),
                                      ),
                                      Text(
                                        _format(duration),
                                        style: const TextStyle(
                                          color: Color(0xFFC4BFBD),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      _OutputDeviceLabel(
                        formatInfo:
                            '${track?.format ?? 'Audio'}${track?.bitrateKbps == null ? '' : '  ·  ${track!.bitrateKbps} kbps'}',
                      ),
                      const SizedBox(height: 4),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _artworkBackdrop(Track track, {required bool immersive}) {
    final path = track.customArtworkPath != null
        ? (track.animatedArtwork
              ? track.artworkPosterPath ?? track.customArtworkPath
              : track.customArtworkPath)
        : track.embeddedArtworkPath;
    Widget image;
    if (track.providerArtworkUrl != null && track.customArtworkPath == null) {
      image = Image.network(
        track.providerArtworkUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _ArtworkPlaceholder(),
      );
    } else if (path != null) {
      image = Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _ArtworkPlaceholder(),
      );
    } else if (track.artwork != null) {
      image = Image.memory(track.artwork!, fit: BoxFit.cover);
    } else {
      image = const _ArtworkPlaceholder();
    }
    if (immersive) {
      return SizedBox.expand(child: image);
    }
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
      child: Transform.scale(scale: 1.25, child: image),
    );
  }

  static String _format(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF201713),
    child: Center(
      child: Icon(
        Icons.graphic_eq_rounded,
        size: 90,
        color: BitwaveColors.accent,
      ),
    ),
  );
}

class _PlayerLyricLabel extends StatelessWidget {
  const _PlayerLyricLabel({required this.lyrics, required this.positionStream});

  final String lyrics;
  final Stream<Duration> positionStream;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: positionStream,
    builder: (context, snapshot) {
      final position = snapshot.data ?? Duration.zero;
      final lines = <({Duration? at, String text})>[];
      for (final raw in lyrics.split(RegExp(r'\r?\n'))) {
        if (RegExp(
          r'^\s*\[(?:ar|ti|al|by|offset|re|ve|length|la|tool):',
          caseSensitive: false,
        ).hasMatch(raw)) {
          continue;
        }
        final matches = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]')
            .allMatches(raw)
            .toList(growable: false);
        final text = raw
            .replaceAll(RegExp(r'\[\d{1,2}:\d{2}(?:\.\d{1,3})?\]'), '')
            .trim();
        if (text.isEmpty) continue;
        if (matches.isEmpty) {
          lines.add((at: null, text: text));
        } else {
          for (final match in matches) {
            final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
            final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
            final fraction = (match.group(3) ?? '').padRight(3, '0');
            final millis = int.tryParse(fraction) ?? 0;
            lines.add((
              at: Duration(
                minutes: minutes,
                seconds: seconds,
                milliseconds: millis,
              ),
              text: text,
            ));
          }
        }
      }
      if (lines.isEmpty) return const SizedBox(height: 24);
      final timed = lines.where((line) => line.at != null).toList();
      timed.sort((a, b) => a.at!.compareTo(b.at!));
      final current = timed.isEmpty
          ? lines.take(2).map((line) => line.text).join('\n')
          : (timed.lastWhere(
              (line) => line.at! <= position,
              orElse: () => timed.first,
            )).text;
      return SizedBox(
        height: 48,
        child: Center(
          child: Text(
            current,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              height: 1.2,
              fontWeight: FontWeight.w600,
              letterSpacing: -.2,
            ),
          ),
        ),
      );
    },
  );
}

class _OutputDeviceLabel extends StatefulWidget {
  const _OutputDeviceLabel({required this.formatInfo});

  final String formatInfo;

  @override
  State<_OutputDeviceLabel> createState() => _OutputDeviceLabelState();
}

class _OutputDeviceLabelState extends State<_OutputDeviceLabel> {
  StreamSubscription<Set<AudioDevice>>? _subscription;
  String _name = 'Audio output';

  @override
  void initState() {
    super.initState();
    _watchDevices();
  }

  Future<void> _watchDevices() async {
    try {
      final session = await AudioSession.instance;
      _subscription = session.devicesStream.listen(_update);
    } catch (_) {
      // The playback surface remains useful if a platform cannot enumerate routes.
    }
  }

  void _update(Set<AudioDevice> devices) {
    final outputs = devices.where((device) => device.isOutput).toList();
    outputs.sort(
      (a, b) => _routePriority(a.name).compareTo(_routePriority(b.name)),
    );
    final routeName = outputs.isEmpty || outputs.first.name.trim().isEmpty
        ? 'Audio output'
        : outputs.first.name.trim();
    if (mounted && routeName != _name) setState(() => _name = routeName);
  }

  int _routePriority(String name) {
    final normalized = name.toLowerCase();
    if (normalized.contains('speaker') || normalized.contains('built-in')) {
      return 1;
    }
    if (normalized.contains('headphone') ||
        normalized.contains('headset') ||
        normalized.contains('bluetooth') ||
        normalized.contains('airplay') ||
        normalized.contains('usb')) {
      return 0;
    }
    return 2;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.headphones_rounded,
          size: 20,
          color: Color(0xFFC4BFBD),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Text(
            _name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFD2CDCA),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Container(width: 1, height: 14, color: const Color(0xFF514C49)),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            widget.formatInfo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFC4BFBD),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );
}

class _NowPlayingArtwork extends StatefulWidget {
  const _NowPlayingArtwork({
    super.key,
    required this.track,
    required this.animated,
  });
  final Track track;
  final bool animated;

  @override
  State<_NowPlayingArtwork> createState() => _NowPlayingArtworkState();
}

class _NowPlayingArtworkState extends State<_NowPlayingArtwork> {
  VideoPlayerController? _controller;
  bool _videoFailed = false;

  @override
  void initState() {
    super.initState();
    _startVideoIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _NowPlayingArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.track.motionArtworkUrl != widget.track.motionArtworkUrl ||
        oldWidget.track.customArtworkPath != widget.track.customArtworkPath ||
        oldWidget.animated != widget.animated) {
      _disposeVideo();
      _videoFailed = false;
      _startVideoIfNeeded();
    }
  }

  Future<void> _startVideoIfNeeded() async {
    final path = widget.track.motionArtworkPath;
    final motionUrl = widget.track.motionArtworkUrl;
    if (!widget.animated || (path == null && motionUrl == null)) {
      return;
    }
    final controller = motionUrl != null
        ? VideoPlayerController.networkUrl(
            Uri.parse(motionUrl),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          )
        : VideoPlayerController.file(
            File(path!),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted || !widget.animated || _controller != controller) return;
      await controller.play();
      if (mounted) setState(() {});
    } catch (_) {
      await controller.dispose();
      if (identical(_controller, controller)) _controller = null;
      if (mounted) setState(() => _videoFailed = true);
    }
  }

  Future<void> _disposeVideo() async {
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }

  @override
  void dispose() {
    _disposeVideo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final motionPath = widget.track.motionArtworkPath;
    if (widget.animated &&
        controller != null &&
        controller.value.isInitialized) {
      return FittedBox(
        fit: _fit,
        alignment: _alignment,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      );
    }
    if (widget.animated &&
        !_videoFailed &&
        motionPath != null &&
        const {'.gif', '.webp'}.contains(
          motionPath.toLowerCase().substring(motionPath.lastIndexOf('.')),
        )) {
      return TickerMode(
        enabled: widget.animated,
        child: Image.file(
          File(motionPath),
          fit: _fit,
          alignment: _alignment,
          errorBuilder: (_, _, _) => _poster(context),
        ),
      );
    }
    return _poster(context);
  }

  BoxFit get _fit =>
      widget.track.artworkFit == 'fit' ? BoxFit.contain : BoxFit.cover;
  Alignment get _alignment =>
      Alignment(widget.track.artworkFocusX, widget.track.artworkFocusY);

  Widget _poster(BuildContext context) {
    final track = widget.track;
    if (track.customArtworkPath != null) {
      final path = track.animatedArtwork
          ? track.artworkPosterPath ?? track.customArtworkPath!
          : track.customArtworkPath!;
      return Image.file(
        File(path),
        fit: _fit,
        alignment: _alignment,
        errorBuilder: (_, _, _) => _fallback(),
      );
    }
    if (track.providerArtworkUrl != null) {
      return Image.network(
        track.providerArtworkUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _localOrFallback(),
      );
    }
    if (track.embeddedArtworkPath != null) {
      return Image.file(
        File(track.embeddedArtworkPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(),
      );
    }
    if (track.artwork != null) {
      return Image.memory(track.artwork!, fit: BoxFit.cover);
    }
    return _fallback();
  }

  Widget _localOrFallback() {
    final path = widget.track.embeddedArtworkPath;
    return path == null
        ? _fallback()
        : Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _fallback(),
          );
  }

  Widget _fallback() => const ColoredBox(
    color: BitwaveColors.panel,
    child: Center(
      child: Icon(
        Icons.graphic_eq_rounded,
        size: 95,
        color: BitwaveColors.accent,
      ),
    ),
  );
}
