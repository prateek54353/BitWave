import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../data/library_repository.dart';
import '../domain/track.dart';
import '../../player/data/bitwave_audio_handler.dart';
import '../../player/presentation/equalizer_page.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../artwork/presentation/artwork_editor_sheet.dart';
import '../../lyrics/presentation/word_synced_lyrics.dart';
import '../../lastfm/presentation/lastfm_settings_page.dart';
import '../../playlists/domain/playlist.dart';
import 'track_details_page.dart';

enum LibrarySection {
  library,
  recentlyAdded,
  albums,
  artists,
  songs,
  genres,
  folders,
  favorites,
  playlists,
  queue,
  settings,
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.library, required this.audio});
  final LibraryRepository library;
  final BitwaveAudioHandler audio;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final PageController _canvasController = PageController(initialPage: 1);
  final PageController _deckController = PageController();
  final ScrollController _categoryController = ScrollController();
  StreamSubscription<FileSystemEvent>? _iosFolderSubscription;
  int _activeCategoryIndex = 0;
  int _activeDeckItemIndex = 0;
  double _paneDragStartPage = 1;
  double _paneDragDelta = 0;
  List<Track> _tracks = [];
  LibrarySection _section = LibrarySection.library;
  bool _grid = true;
  bool _searching = false;
  bool _scanning = false;
  bool _libraryReady = false;
  String? _libraryLoadError;
  String _query = '';
  String? _selectedArtist;
  String? _selectedFolderPath;
  String? _selectedGenre;
  String? _selectedPlaylistId;
  List<Playlist> _playlists = [];
  List<Track> _selectedPlaylistTracks = [];
  List<Track>? _albumDetailTracks;
  Timer? _sleepTimer;
  Timer? _iosFolderRescanTimer;
  bool _syncingIOSFolder = false;
  bool _iosFolderRescanPending = false;
  DateTime? _sleepDeadline;
  String _artworkStyle = 'automatic';
  int _libraryBytes = 0;
  int _filesChangedThisWeek = 0;
  Map<String, List<Track>> _albumIndex = {};
  Map<String, List<Track>> _artistIndex = {};
  List<Track> _recentDeckItems = const [];
  List<Track> _albumDeckItems = const [];
  List<Track> _artistDeckItems = const [];
  List<Track> _songDeckItems = const [];
  List<Track> _genreDeckItems = const [];
  List<Track> _folderDeckItems = const [];
  Set<String> _genreKeys = const {};
  Set<String> _folderKeys = const {};
  Map<String, Track> _tracksById = const {};
  bool _lyricsSharingEnabled = false;
  String _albumSort = 'title_asc';
  Set<String> _pinnedAlbumKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _categoryController.addListener(_onCategoryRibbonScroll);
    unawaited(_refresh());
    _startIOSFolderMonitoring();
    _loadLyricsSharingSetting();
    _loadEqualizerSettings();
    _loadAlbumPreferences();
  }

  Future<void> _loadLyricsSharingSetting() async {
    final enabled = await widget.library.database.getLyricsSharingEnabled();
    if (mounted) setState(() => _lyricsSharingEnabled = enabled);
  }


  Future<void> _loadAlbumPreferences() async {
    final sort = await widget.library.database.getSetting('album_sort');
    final pinnedJson = await widget.library.database.getSetting('pinned_album_keys');
    Set<String> pinned = <String>{};
    if (pinnedJson != null) {
      try { pinned = (jsonDecode(pinnedJson) as List).whereType<String>().toSet(); } catch (_) { pinned = <String>{}; }
    }
    if (!mounted) return;
    setState(() {
      if (const {'title_asc', 'title_desc', 'year_asc', 'year_desc'}.contains(sort)) _albumSort = sort!;
      _pinnedAlbumKeys = pinned;
    });
  }

  Future<void> _setAlbumSort(String value) async {
    setState(() => _albumSort = value);
    await widget.library.database.setSetting('album_sort', value);
  }

  Future<void> _toggleAlbumPin(String key) async {
    setState(() { if (!_pinnedAlbumKeys.add(key)) _pinnedAlbumKeys.remove(key); });
    await widget.library.database.setSetting('pinned_album_keys', jsonEncode(_pinnedAlbumKeys.toList()..sort()));
  }

  Future<void> _loadEqualizerSettings() async {
    final enabled = await widget.library.database.getEqualizerEnabled();
    final bandsStr = await widget.library.database.getEqualizerBands();
    if (enabled && bandsStr != null) {
      final bandValues = bandsStr
          .split(',')
          .map((e) => double.tryParse(e) ?? 0.0)
          .toList();
      if (bandValues.length == 10) {
        await widget.audio.equalizer.setEnabled(true);
        await widget.audio.equalizer.setBands(bandValues);
      }
    }
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _iosFolderRescanTimer?.cancel();
    _iosFolderSubscription?.cancel();
    _canvasController.dispose();
    _deckController.dispose();
    _categoryController
      ..removeListener(_onCategoryRibbonScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _startIOSFolderMonitoring() async {
    if (!Platform.isIOS) return;
    try {
      final folder = await widget.library.iosLocalFilesDirectory();
      _iosFolderSubscription = folder
          .watch(events: FileSystemEvent.all, recursive: true)
          .listen(
            (event) {
              _iosFolderRescanTimer?.cancel();
              _iosFolderRescanTimer = Timer(
                const Duration(milliseconds: 700),
                () => _syncIOSLocalFolder(
                  changedPath: event.type == FileSystemEvent.modify
                      ? event.path
                      : null,
                ),
              );
            },
            onError: (Object error) =>
                debugPrint('Bitwave local folder watcher unavailable: $error'),
          );
    } catch (error) {
      debugPrint('Bitwave local folder setup failed: $error');
    }
  }

  Future<void> _syncIOSLocalFolder({String? changedPath}) async {
    if (!Platform.isIOS) return;
    if (_syncingIOSFolder) {
      _iosFolderRescanPending = true;
      return;
    }
    _syncingIOSFolder = true;
    try {
      var nextChangedPath = changedPath;
      do {
        _iosFolderRescanPending = false;
        final changes = await widget.library.syncIOSLocalFiles(
          changedPath: nextChangedPath,
        );
        if (changes > 0 && mounted) await _refresh();
        nextChangedPath = null;
      } while (_iosFolderRescanPending && mounted);
    } catch (error) {
      debugPrint('Bitwave local folder rescan failed: $error');
    } finally {
      _syncingIOSFolder = false;
    }
  }

  void _openPlayer() {
    if (_canvasController.hasClients) _canvasController.jumpToPage(1);
  }

  void _openMenu() {
    if (_canvasController.hasClients) {
      _canvasController.animateToPage(
        2,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _openLibrary() {
    if (_canvasController.hasClients) {
      _canvasController.animateToPage(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _beginPaneEdgeDrag() {
    _paneDragStartPage = _canvasController.hasClients
        ? (_canvasController.page ?? 1)
        : 1;
    _paneDragDelta = 0;
  }

  void _updatePaneEdgeDrag(double delta, double viewportWidth) {
    if (!_canvasController.hasClients || viewportWidth <= 0) return;
    _paneDragDelta += delta;
    final page = (_paneDragStartPage - _paneDragDelta / viewportWidth).clamp(
      0.0,
      2.0,
    );
    _canvasController.position.jumpTo(page * viewportWidth);
  }

  void _endPaneEdgeDrag(double velocity) {
    if (!_canvasController.hasClients) return;
    final page = (_canvasController.page ?? 1).clamp(0.0, 2.0);
    final destination = velocity.abs() > 350
        ? (velocity < 0 ? page.ceil() : page.floor())
        : page.round();
    _canvasController.animateToPage(
      destination.clamp(0, 2).toInt(),
      duration: const Duration(milliseconds: 210),
      curve: Curves.easeOutCubic,
    );
  }

  void _selectCategory(int index) {
    if (index < 0 || index >= _categoryTitles.length) return;
    setState(() {
      _activeCategoryIndex = index;
      _activeDeckItemIndex = 0;
      _section = switch (index) {
        0 => LibrarySection.recentlyAdded,
        1 => LibrarySection.albums,
        2 => LibrarySection.artists,
        3 => LibrarySection.songs,
        4 => LibrarySection.genres,
        5 => LibrarySection.folders,
        6 => LibrarySection.playlists,
        _ => LibrarySection.library,
      };
      _selectedArtist = null;
      _selectedFolderPath = null;
      _selectedGenre = null;
      _selectedPlaylistId = null;
      _selectedPlaylistTracks = [];
      _albumDetailTracks = null;
    });
    _openLibrary();
  }

  void _onCategoryTap(int index) {
    if (index < 0 || index >= _categoryTitles.length) return;
    if (index == _activeCategoryIndex) {
      _selectCategory(index);
      return;
    }
    _activateCategory(index);
  }

  void _backToLibraryDeck() {
    setState(() {
      _section = LibrarySection.library;
      _selectedArtist = null;
      _selectedFolderPath = null;
      _selectedGenre = null;
      _selectedPlaylistId = null;
      _selectedPlaylistTracks = [];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_deckController.hasClients) {
        _deckController.jumpToPage(_activeCategoryIndex);
      }
      _scrollRibbonTo(_activeCategoryIndex);
    });
  }

  void _activateCategory(int index) {
    setState(() {
      _activeCategoryIndex = index;
      _activeDeckItemIndex = 0;
      _section = LibrarySection.library;
      _selectedPlaylistId = null;
      _selectedPlaylistTracks = [];
      _albumDetailTracks = null;
    });
    if (_deckController.hasClients && _deckController.page?.round() != index) {
      _deckController.animateToPage(
        index,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
    _openLibrary();
  }

  void _scrollRibbonTo(int index) {
    if (!_categoryController.hasClients) return;
    final offset = (index * 160.0).clamp(
      0.0,
      _categoryController.position.maxScrollExtent,
    );
    _categoryController.animateTo(
      offset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  void _onCategoryRibbonScroll() {
    if (!_categoryController.hasClients) return;
    final index = (_categoryController.offset / 160).round().clamp(
      0,
      _categoryTitles.length - 1,
    );
    if (index != _activeCategoryIndex) _activateCategory(index);
  }

  void _onDeckPageChanged(int index) {
    if (index < 0 || index >= _categoryTitles.length) return;
    if (index == _activeCategoryIndex) return;
    setState(() {
      _activeCategoryIndex = index;
      _activeDeckItemIndex = 0;
      _section = LibrarySection.library;
      _selectedPlaylistId = null;
      _selectedPlaylistTracks = [];
      _albumDetailTracks = null;
    });
    _scrollRibbonTo(index);
  }

  Future<void> _refresh() async {
    try {
      final tracks = await widget.library.load();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _indexLibrary(tracks);
        _libraryReady = true;
        _libraryLoadError = null;
      });
      final playlistId = _selectedPlaylistId;
      final results = await Future.wait([
        widget.library.database.playlists(),
        playlistId == null
            ? Future.value(<Track>[])
            : widget.library.database.playlistTracks(playlistId),
        widget.library.database.getSetting('now_playing_artwork_style'),
      ]);
      final playlists = results[0] as List<Playlist>;
      final playlistTracks = results[1] as List<Track>;
      final style = results[2] as String?;
      if (mounted) {
        setState(() {
          _playlists = playlists;
          if (_selectedPlaylistId == playlistId) {
            _selectedPlaylistTracks = playlistTracks;
          }
          _artworkStyle = style ?? 'automatic';
        });
      }
      final tracksById = {for (final track in tracks) track.id: track};
      _tracksById = tracksById;
      for (final queuedTrack in widget.audio.tracks) {
        final updated = tracksById[queuedTrack.id];
        if (updated != null) widget.audio.updateTrackMetadata(updated);
      }
    } catch (error) {
      debugPrint('Bitwave library load failed: $error');
      if (mounted) {
        setState(() {
          _libraryReady = false;
          _libraryLoadError = error.toString();
        });
      }
    }
  }

  Future<void> _refreshLibraryFromSettings() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final changed = Platform.isIOS
          ? await widget.library.syncIOSLocalFiles()
          : 0;
      await _refresh();
      if (mounted && _libraryLoadError == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              changed == 0
                  ? 'Library is up to date.'
                  : 'Library refreshed · $changed file changes applied.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Library refresh failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _indexLibrary(List<Track> tracks) {
    final weekAgo = DateTime.now()
        .subtract(const Duration(days: 7))
        .millisecondsSinceEpoch;
    _libraryBytes = 0;
    _filesChangedThisWeek = 0;
    _albumIndex = {};
    _artistIndex = {};
    for (final track in tracks) {
      _libraryBytes += track.fileSize;
      if (track.modifiedMs >= weekAgo) _filesChangedThisWeek++;
      final albumKey = _albumKey(track);
      (_albumIndex[albumKey] ??= []).add(track);
      (_artistIndex[track.displayArtist] ??= []).add(track);
    }
    _tracksById = {for (final track in tracks) track.id: track};
    _genreKeys = {
      for (final track in tracks)
        track.genre.isEmpty ? 'Uncategorized' : track.genre,
    };
    _folderKeys = {for (final track in tracks) File(track.path).parent.path};

    _recentDeckItems = List<Track>.of(tracks)
      ..sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    _albumDeckItems = _albumIndex.values.map((items) => items.first).toList()
      ..sort(_compareAlbumTracks);
    _artistDeckItems = _artistIndex.values.map((items) => items.first).toList()
      ..sort(_compareArtistTracks);
    _songDeckItems = List<Track>.of(tracks)..sort(_compareSongTracks);
    final genres = <String, Track>{};
    final folders = <String, Track>{};
    for (final track in tracks) {
      genres.putIfAbsent(
        track.genre.isEmpty ? 'Uncategorized' : track.genre,
        () => track,
      );
      folders.putIfAbsent(File(track.path).parent.path, () => track);
    }
    _genreDeckItems = genres.values.toList()
      ..sort(
        (a, b) =>
            _genreName(a).toLowerCase().compareTo(_genreName(b).toLowerCase()),
      );
    _folderDeckItems = folders.values.toList()
      ..sort(
        (a, b) =>
            _folderName(a)
                .toLowerCase()
                .compareTo(_folderName(b).toLowerCase()),
      );
  }

  static int _compareAlbumTracks(Track a, Track b) =>
      a.displayAlbum.toLowerCase().compareTo(b.displayAlbum.toLowerCase());

  static int _compareArtistTracks(Track a, Track b) =>
      a.displayArtist.toLowerCase().compareTo(b.displayArtist.toLowerCase());

  static int _compareSongTracks(Track a, Track b) =>
      a.title.toLowerCase().compareTo(b.title.toLowerCase());

  static String _genreName(Track track) =>
      track.genre.isEmpty ? 'Uncategorized' : track.genre;

  String _albumKey(Track track) {
    final albumName = track.displayAlbum.trim().toLowerCase();
    final artist = track.albumArtist.trim().isEmpty
        ? track.displayArtist.trim().toLowerCase()
        : track.albumArtist.trim().toLowerCase();
    return '$albumName\u0000$artist';
  }

  String _albumArtistLabel(Iterable<Track> tracks) {
    final albumArtist = tracks
        .map((track) => track.albumArtist.trim())
        .firstWhere((artist) => artist.isNotEmpty, orElse: () => '');
    if (albumArtist.isNotEmpty) return albumArtist;
    final artists = tracks.map((track) => track.displayArtist).toSet();
    if (artists.length == 1) return artists.first;
    return artists.isEmpty ? 'Unknown artist' : 'Various Artists';
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

  Future<void> _chooseImport() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: BitwaveColors.panel,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.audio_file_outlined),
            title: const Text('Import audio files'),
            onTap: () {
              Navigator.pop(sheetContext);
              _import();
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Import a music folder'),
            subtitle: const Text('Find supported audio files inside a folder'),
            onTap: () {
              Navigator.pop(sheetContext);
              _importFolder();
            },
          ),
          if (Platform.isIOS) ...[
            const ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('Files  ›  On My iPhone  ›  Bitwave'),
              subtitle: Text('Add music in the Local Files folder'),
            ),
            ListTile(
              leading: const Icon(Icons.sync_rounded),
              title: const Text('Rescan Bitwave folder'),
              onTap: () {
                Navigator.pop(sheetContext);
                _syncIOSLocalFolder();
              },
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Future<void> _import() => _runImport(widget.library.importAudio);

  Future<void> _importFolder() => _runImport(widget.library.importAudioFolder);

  Future<void> _runImport(Future<List<Track>> Function() import) async {
    setState(() => _scanning = true);
    try {
      final imported = await import();
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
    if (_section == LibrarySection.recentlyAdded) {
      tracks = List<Track>.of(tracks)
        ..sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    }
    if (_section == LibrarySection.folders && _selectedFolderPath != null) {
      tracks = tracks
          .where((track) => File(track.path).parent.path == _selectedFolderPath)
          .toList();
    }
    if (_section == LibrarySection.genres && _selectedGenre != null) {
      tracks = tracks
          .where(
            (track) =>
                (track.genre.isEmpty ? 'Uncategorized' : track.genre) ==
                _selectedGenre,
          )
          .toList();
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
    LibrarySection.recentlyAdded => 'Recently added',
    LibrarySection.albums => 'Albums',
    LibrarySection.artists => 'Artists',
    LibrarySection.songs => 'Songs',
    LibrarySection.genres => 'Genres',
    LibrarySection.folders =>
      _selectedFolderPath == null
          ? 'Folders'
          : _selectedFolderPath!.split(Platform.pathSeparator).last,
    LibrarySection.favorites => 'Favorites',
    LibrarySection.playlists =>
      _selectedPlaylistId == null
          ? 'Playlists'
          : _playlists
                    .where((playlist) => playlist.id == _selectedPlaylistId)
                    .firstOrNull
                    ?.name ??
                'Playlists',
    LibrarySection.queue => 'Queue',
    LibrarySection.settings => 'Settings',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF090A0B),
    body: LayoutBuilder(
      builder: (context, viewport) => Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _canvasController,
            builder: (context, _) {
              final page = _canvasController.hasClients
                  ? (_canvasController.page ?? 1)
                  : 1.0;
              if (page > .5 && page < 1.5) return const SizedBox.shrink();
              return StreamBuilder<MediaItem?>(
                stream: widget.audio.mediaItem,
                builder: (context, snapshot) {
                  final id = snapshot.data?.id;
                  final track = id == null
                      ? null
                      : widget.audio.tracks
                            .where((item) => item.id == id)
                            .firstOrNull;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (track != null)
                        Positioned.fill(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              _AdaptiveArtworkBackdrop(
                                key: ValueKey('global-backdrop-${track.id}'),
                                track: track,
                              ),
                              const ColoredBox(color: Color(0xA8000000)),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
          PageView(
            controller: _canvasController,
            physics: const PageScrollPhysics(parent: BouncingScrollPhysics()),
            children: [
              _libraryPane(),
              LayoutBuilder(
                builder: (context, constraints) => AnimatedBuilder(
                  animation: _canvasController,
                  child: _NowPlayingScreen(
                    audio: widget.audio,
                    artworkStyle: _artworkStyle,
                    lyricsSharingEnabled: _lyricsSharingEnabled,
                    onOpenDetails: _openTrackDetails,
                    onAddToPlaylist: _addTrackToPlaylist,
                    onOpenMenu: _openMenu,
                  ),
                  builder: (context, child) {
                    final page = _canvasController.hasClients
                        ? (_canvasController.page ?? 1)
                        : 1.0;
                    final libraryProgress = (1 - page).clamp(0.0, 1.0);
                    return GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: libraryProgress > .8 ? _openPlayer : null,
                      child: AbsorbPointer(
                        absorbing: libraryProgress > .8,
                        child: Transform.translate(
                          offset: Offset(
                            -constraints.maxWidth * libraryProgress,
                            0,
                          ),
                          child: Transform.scale(
                            alignment: Alignment.centerRight,
                            scale: math.max(
                              46 / constraints.maxWidth,
                              1 - .9 * libraryProgress,
                            ),
                            child: Transform.scale(
                              scaleY: 1 - .14 * libraryProgress,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              _menuPane(),
            ],
          ),
          AnimatedBuilder(
            animation: _canvasController,
            builder: (context, _) {
              final page = _canvasController.hasClients
                  ? (_canvasController.page ?? 1)
                  : 1.0;
              final progress = (1 - page).clamp(0.0, 1.0);
              if (progress < .35) return const SizedBox.shrink();
              return Positioned.fill(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Opacity(
                    opacity: ((progress - .35) / .4).clamp(0.0, 1.0),
                    child: _NowPlayingPill(
                      audio: widget.audio,
                      onTap: _openPlayer,
                      onSwipe: _openPlayer,
                      availableHeight: viewport.maxHeight,
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 24,
            child: Semantics(
              label: 'Drag right to show the next pane',
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _beginPaneEdgeDrag(),
                onHorizontalDragUpdate: (details) => _updatePaneEdgeDrag(
                  details.primaryDelta ?? 0,
                  viewport.maxWidth,
                ),
                onHorizontalDragEnd: (details) =>
                    _endPaneEdgeDrag(details.primaryVelocity ?? 0),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 24,
            child: Semantics(
              label: 'Drag left to show the next pane',
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _beginPaneEdgeDrag(),
                onHorizontalDragUpdate: (details) => _updatePaneEdgeDrag(
                  details.primaryDelta ?? 0,
                  viewport.maxWidth,
                ),
                onHorizontalDragEnd: (details) =>
                    _endPaneEdgeDrag(details.primaryVelocity ?? 0),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _libraryPane() {
    final detailTracks = _albumDetailTracks;
    if (detailTracks != null) {
      return _AlbumDetailPage(
        tracks: detailTracks,
        audio: widget.audio,
        onEditArtwork: () => _editArtwork(detailTracks),
        onAddToPlaylist: () => _addTracksToPlaylist(detailTracks),
        onBack: () => setState(() => _albumDetailTracks = null),
      );
    }
    if (_section == LibrarySection.library) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: _libraryDeck(),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 64,
        leading: IconButton(
          tooltip: 'Back to library deck',
          onPressed: _backToLibraryDeck,
          icon: const Icon(Icons.arrow_back_rounded),
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
            onPressed: _scanning ? null : _chooseImport,
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
          : _section == LibrarySection.playlists
          ? _playlistBrowser()
          : _libraryPage(),
      bottomNavigationBar: _miniPlayer(),
    );
  }

  Widget _libraryDeck() {
    final deckItems = _deckItemsForCategory(_activeCategoryIndex);
    final featured = deckItems.isEmpty
        ? null
        : deckItems[math.min(_activeDeckItemIndex, deckItems.length - 1)];
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          controller: _deckController,
          scrollDirection: Axis.horizontal,
          physics: const PageScrollPhysics(parent: BouncingScrollPhysics()),
          itemCount: _categoryTitles.length,
          onPageChanged: _onDeckPageChanged,
          itemBuilder: (context, category) => _deckCategoryPage(category),
        ),
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, .34, .6, 1],
                  colors: [
                    Color(0x76000000),
                    Color(0x10000000),
                    Color(0x61000000),
                    Color(0xF2090A0B),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(27, 12, 26, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        _categoryTitles[_activeCategoryIndex],
                        style: const TextStyle(
                          fontSize: 42,
                          height: 1.02,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -1.8,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: _searching ? 'Close search' : 'Search',
                      onPressed: () => setState(() {
                        _searching = !_searching;
                        if (!_searching) _query = '';
                      }),
                      icon: Icon(_searching ? Icons.close : Icons.search),
                    ),
                    IconButton(
                      tooltip: 'Import audio',
                      onPressed: _scanning ? null : _chooseImport,
                      icon: _scanning
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
              if (_searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(27, 8, 27, 0),
                  child: TextField(
                    autofocus: true,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                      hintText: 'Search your library',
                      border: InputBorder.none,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(29, 14, 28, 0),
                child: Text(
                  _libraryLoadError != null
                      ? 'Library unavailable · refresh from Settings'
                      : !_libraryReady
                      ? 'Loading saved library…'
                      : _activeCategoryIndex == 0
                      ? '$_filesChangedThisWeek files changed this week'
                      : '${_categoryCount(_activeCategoryIndex)} ${_categoryCountLabel(_activeCategoryIndex)}',
                  style: const TextStyle(
                    fontSize: 15,
                    color: Color(0xFFD0CECC),
                  ),
                ),
              ),
              const Spacer(),
              if (featured != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 32, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () =>
                            _openDeckItem(_activeCategoryIndex, featured),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            _featuredTitle(_activeCategoryIndex, featured),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 29,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      InkWell(
                        onTap: () =>
                            _openDeckItem(_activeCategoryIndex, featured),
                        child: Text(
                          _featuredSubtitle(_activeCategoryIndex, featured),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 17),
                        ),
                      ),
                    ],
                  ),
                ),
              if (featured == null && _activeCategoryIndex != 6)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 32, 20),
                  child: Text(
                    _libraryLoadError != null
                        ? 'Library could not be loaded. Open Settings and refresh to retry.'
                        : _activeCategoryIndex == 5
                        ? 'Folders containing your imported music will appear here.'
                        : 'Your local music will appear here after you import audio.',
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFFD0CECC),
                    ),
                  ),
                ),
              if (_activeCategoryIndex == 6)
                SafeArea(top: false, child: _categoryRibbon())
              else ...[
                _librarySourceCard(_libraryBytes),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _librarySourceCard(int totalBytes) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 17),
    padding: const EdgeInsets.fromLTRB(22, 19, 14, 10),
    decoration: BoxDecoration(
      color: const Color(0xE5222324),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0x24FFFFFF)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x44000000),
          blurRadius: 28,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'On this device',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        Text(
          _libraryLoadError != null
              ? 'Library unavailable · refresh from Settings'
              : _libraryReady
              ? '${_formatStorage(totalBytes)}  ·  ${_tracks.length} ${_tracks.length == 1 ? 'track' : 'tracks'}'
              : 'Loading saved library…',
          style: const TextStyle(color: Color(0xFFB8B8B8), fontSize: 14),
        ),
        const SizedBox(height: 18),
        InkWell(
          onTap: _scanning ? null : _chooseImport,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Text(
              _scanning ? 'Importing…' : 'Browse / Import',
              style: const TextStyle(color: Color(0xFFB8B8B8), fontSize: 14),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _categoryRibbon(),
      ],
    ),
  );

  List<Track> _deckItemsForCategory(int category) {
    return switch (category) {
      0 => _recentDeckItems,
      1 => _albumDeckItems,
      2 => _artistDeckItems,
      3 => _songDeckItems,
      4 => _genreDeckItems,
      5 => _folderDeckItems,
      _ => const [],
    };
  }

  String _featuredTitle(int category, Track track) => switch (category) {
    1 => track.displayAlbum,
    2 => track.displayArtist,
    4 => track.genre.isEmpty ? 'Uncategorized' : track.genre,
    5 => _folderName(track),
    _ => track.title,
  };

  String _featuredSubtitle(int category, Track track) => switch (category) {
    1 => _albumArtistLabel(_albumIndex[_albumKey(track)] ?? [track]),
    2 => '${_artistIndex[track.displayArtist]?.length ?? 0} tracks',
    4 => '${_genreTrackCount(track)} tracks',
    5 => '${_folderTrackCount(track)} tracks',
    _ => track.displayArtist,
  };

  int _categoryCount(int category) => switch (category) {
    0 || 3 => _visibleTracks.length,
    1 => _albumIndex.length,
    2 => _artistIndex.length,
    4 => _genreKeys.length,
    5 => _folderKeys.length,
    6 => _playlists.length,
    _ => 0,
  };

  String _categoryCountLabel(int category) => switch (category) {
    1 => 'albums',
    2 => 'artists',
    4 => 'genres',
    5 => 'folders',
    6 => 'playlists',
    _ => 'tracks',
  };

  String _folderName(Track track) {
    final path = File(track.path).parent.path;
    return path
            .split(Platform.pathSeparator)
            .where((part) => part.isNotEmpty)
            .lastOrNull ??
        path;
  }

  int _genreTrackCount(Track track) {
    final genre = _genreName(track);
    return _tracks.where((item) => _genreName(item) == genre).length;
  }

  int _folderTrackCount(Track track) {
    final folder = File(track.path).parent.path;
    return _tracks
        .where((item) => File(item.path).parent.path == folder)
        .length;
  }

  static String _formatStorage(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  static const _categoryTitles = [
    'Recently added',
    'Albums',
    'Artists',
    'Songs',
    'Genres',
    'Folders',
    'Playlists',
  ];

  Widget _categoryRibbon() => LayoutBuilder(
    builder: (context, constraints) {
      const tabWidth = 160.0;
      final sidePadding = math.max(0.0, (constraints.maxWidth - tabWidth) / 2);
      return SizedBox(
        height: 102,
        child: SingleChildScrollView(
          controller: _categoryController,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: sidePadding),
            child: Row(
              children: List.generate(
                _categoryTitles.length,
                (index) => SizedBox(
                  width: tabWidth,
                  child: InkWell(
                    onTap: () => _onCategoryTap(index),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 140),
                            style: TextStyle(
                              color: index == _activeCategoryIndex
                                  ? BitwaveColors.paper
                                  : BitwaveColors.muted,
                              fontSize: 18,
                              fontWeight: index == _activeCategoryIndex
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            child: Text(
                              _categoryTitles[index],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _libraryReady ? '${_categoryCount(index)}' : '—',
                            style: TextStyle(
                              color: index == _activeCategoryIndex
                                  ? const Color(0xFFE7E5E3)
                                  : BitwaveColors.muted,
                              fontSize: 25,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _deckCategoryPage(int category) {
    if (category == 6) return _playlistDeckPage();
    final items = _deckItemsForCategory(category);
    if (items.isEmpty) return const SizedBox.expand();
    final itemIndex = _activeCategoryIndex == category
        ? _activeDeckItemIndex.clamp(0, items.length - 1)
        : 0;
    final track = items[itemIndex];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDeckItem(category, track),
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 280) return;
        setState(() {
          _activeDeckItemIndex = velocity < 0
              ? (itemIndex + 1).clamp(0, items.length - 1)
              : (itemIndex - 1).clamp(0, items.length - 1);
        });
      },
      child: _NowPlayingArtwork(track: track),
    );
  }

  Widget _playlistDeckPage() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 150, 20, 320),
    children: [
      if (_playlists.isEmpty)
        ListTile(
          leading: const Icon(Icons.playlist_add_rounded),
          title: const Text('Create your first playlist'),
          onTap: _createPlaylist,
        ),
      ..._playlists.map(
        (playlist) => ListTile(
          leading: const Icon(Icons.queue_music_rounded),
          title: Text(playlist.name, maxLines: 1),
          subtitle: Text(
            '${playlist.trackCount} ${playlist.trackCount == 1 ? 'track' : 'tracks'}',
            style: const TextStyle(color: BitwaveColors.muted),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _openPlaylist(playlist),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.add_rounded),
        title: const Text('New playlist'),
        onTap: _createPlaylist,
      ),
    ],
  );

  void _openDeckItem(int category, Track track) {
    if (category == 1) {
      final albumTracks = _albumIndex[_albumKey(track)] ?? const <Track>[];
      if (albumTracks.isNotEmpty) _openAlbum(albumTracks);
    } else if (category == 2) {
      _openArtist(track.displayArtist);
    } else if (category == 4) {
      final genre = track.genre.isEmpty ? 'Uncategorized' : track.genre;
      final genreTracks = _tracks
          .where((candidate) => candidate.genre == track.genre)
          .toList();
      _showTrackSheet(genre, genreTracks);
    } else if (category == 5) {
      final folder = File(track.path).parent.path;
      final folderTracks = _tracks
          .where((candidate) => File(candidate.path).parent.path == folder)
          .toList();
      _showTrackSheet(_folderName(track), folderTracks);
    } else {
      final tracks = _visibleTracks;
      final index = tracks.indexOf(track);
      if (index >= 0) widget.audio.playTracks(tracks, initialIndex: index);
      _openPlayer();
    }
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
              if (_section == LibrarySection.albums)
                IconButton(
                  tooltip: _grid ? 'Show list' : 'Show grid',
                  onPressed: () => setState(() => _grid = !_grid),
                  icon: Icon(
                    _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                    color: BitwaveColors.muted,
                  ),
                ),

              if (_section == LibrarySection.albums)
                PopupMenuButton<String>(
                  tooltip: 'Sort albums',
                  initialValue: _albumSort,
                  icon: const Icon(Icons.sort_rounded, color: BitwaveColors.muted),
                  onSelected: (value) => unawaited(_setAlbumSort(value)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'title_asc', child: Text('Title A–Z')),
                    PopupMenuItem(value: 'title_desc', child: Text('Title Z–A')),
                    PopupMenuItem(value: 'year_asc', child: Text('Year ascending')),
                    PopupMenuItem(value: 'year_desc', child: Text('Year descending')),
                  ],
                ),
              if (_section == LibrarySection.playlists)
                IconButton(
                  tooltip: _selectedPlaylistId == null
                      ? 'Create playlist'
                      : 'Add tracks to playlist',
                  onPressed: _selectedPlaylistId == null
                      ? _createPlaylist
                      : _chooseTracksForPlaylist,
                  icon: Icon(
                    _selectedPlaylistId == null
                        ? Icons.playlist_add_rounded
                        : Icons.add_rounded,
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: 'Sort library',
                  icon: const Icon(
                    Icons.sort_rounded,
                    color: BitwaveColors.muted,
                  ),
                  onSelected: (_) => setState(
                    () => _tracks.sort(
                      (a, b) => a.title.toLowerCase().compareTo(
                        b.title.toLowerCase(),
                      ),
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
            ],
          ),
        ),
        const Divider(height: 1, color: BitwaveColors.line),
        Expanded(
          child: tracks.isEmpty
              ? _emptyLibrary()
              : switch (_section) {
                  LibrarySection.albums => _albumBrowser(tracks),
                  LibrarySection.artists => _artistBrowser(tracks),
                  LibrarySection.genres =>
                    _selectedGenre == null
                        ? _genreBrowser(tracks)
                        : _songList(tracks),
                  LibrarySection.folders =>
                    _selectedFolderPath == null
                        ? _folderBrowser(tracks)
                        : _songList(tracks),
                  _ => _songList(tracks),
                },
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
          Text(
            Platform.isIOS
                ? 'Add music in Files → On My iPhone → Bitwave → Local Files, or import audio here. Bitwave keeps that folder in sync for offline listening.'
                : 'Import audio files from your device. Bitwave keeps a private copy and indexes their tags for offline listening.',
            textAlign: TextAlign.center,
            style: TextStyle(color: BitwaveColors.muted, height: 1.45),
          ),
          const SizedBox(height: 21),
          FilledButton.icon(
            onPressed: _chooseImport,
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

  Widget _playlistBrowser() {
    final playlistId = _selectedPlaylistId;
    if (playlistId == null) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: const Icon(Icons.add_rounded, color: BitwaveColors.accent),
            title: const Text('Create playlist'),
            onTap: _createPlaylist,
          ),
          if (_playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(28),
              child: Text(
                'Your playlists are stored on this device and work offline.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BitwaveColors.muted),
              ),
            ),
          ..._playlists.map(
            (playlist) => ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.queue_music_rounded),
              ),
              title: Text(playlist.name),
              subtitle: Text(
                '${playlist.trackCount} ${playlist.trackCount == 1 ? 'track' : 'tracks'}',
                style: const TextStyle(color: BitwaveColors.muted),
              ),
              onTap: () => _openPlaylist(playlist),
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'rename') _renamePlaylist(playlist);
                  if (value == 'delete') _deletePlaylist(playlist);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final playlist = _playlists
        .where((item) => item.id == playlistId)
        .firstOrNull;
    if (playlist == null) return const SizedBox.shrink();
    final tracks = _selectedPlaylistTracks;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
          child: Row(
            children: [
              IconButton(
                tooltip: 'All playlists',
                onPressed: () => setState(() {
                  _selectedPlaylistId = null;
                  _selectedPlaylistTracks = [];
                }),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Text(
                  '${tracks.length} ${tracks.length == 1 ? 'track' : 'tracks'}',
                  style: const TextStyle(color: BitwaveColors.muted),
                ),
              ),
              IconButton(
                tooltip: 'Play playlist',
                onPressed: tracks.isEmpty
                    ? null
                    : () => widget.audio.playTracks(tracks),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
              IconButton(
                tooltip: 'Shuffle playlist',
                onPressed: tracks.isEmpty
                    ? null
                    : () => widget.audio.playTracks(List.of(tracks)..shuffle()),
                icon: const Icon(Icons.shuffle_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: BitwaveColors.line),
        Expanded(
          child: tracks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('This playlist is empty.'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _chooseTracksForPlaylist,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add tracks'),
                      ),
                    ],
                  ),
                )
              : ReorderableListView.builder(
                  itemCount: tracks.length,
                  onReorderItem: (from, to) async {
                    await widget.library.database.movePlaylistTrack(
                      playlistId,
                      from,
                      to,
                    );
                    await _reloadPlaylistState();
                  },
                  itemBuilder: (context, index) => KeyedSubtree(
                    key: ValueKey('playlist-$playlistId-${tracks[index].id}'),
                    child: _trackRow(
                      tracks[index],
                      index,
                      tracks,
                      playlistId: playlistId,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _openPlaylist(Playlist playlist) async {
    final tracks = await widget.library.database.playlistTracks(playlist.id);
    if (!mounted) return;
    setState(() {
      _section = LibrarySection.playlists;
      _selectedPlaylistId = playlist.id;
      _selectedPlaylistTracks = tracks;
    });
    _openLibrary();
  }

  Future<void> _renamePlaylist(Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.library.database.renamePlaylist(playlist.id, name);
      await _reloadPlaylistState();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not rename playlist: $error')),
        );
      }
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${playlist.name}?'),
        content: const Text('Tracks in your library will not be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.library.database.deletePlaylist(playlist.id);
    if (_selectedPlaylistId == playlist.id) {
      setState(() {
        _selectedPlaylistId = null;
        _selectedPlaylistTracks = [];
      });
    }
    await _reloadPlaylistState();
  }

  Future<void> _addTrackToPlaylist(Track track) async {
    if (_playlists.isEmpty) {
      final id = await _createPlaylist();
      if (id == null) return;
      await widget.library.database.addTrackToPlaylist(id, track.id);
      await _reloadPlaylistState();
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BitwaveColors.panel,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Add to playlist')),
            ..._playlists.map(
              (playlist) => ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(playlist.name),
                onTap: () => Navigator.pop(sheetContext, playlist.id),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Create playlist'),
              onTap: () => Navigator.pop(sheetContext, '__create__'),
            ),
          ],
        ),
      ),
    );
    final playlistId = selected == '__create__'
        ? await _createPlaylist()
        : selected;
    if (playlistId == null) return;
    await widget.library.database.addTrackToPlaylist(playlistId, track.id);
    await _reloadPlaylistState();
  }

  Future<String?> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Playlist name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return null;
    try {
      final id = await widget.library.database.createPlaylist(name);
      await _reloadPlaylistState();
      return id;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create playlist: $error')),
        );
      }
      return null;
    }
  }

  Future<void> _chooseTracksForPlaylist() async {
    final playlistId = _selectedPlaylistId;
    if (playlistId == null || _tracks.isEmpty) return;
    final selectedIds = <String>{};
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add tracks'),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.sizeOf(context).height * .58,
            child: ListView.builder(
              itemCount: _tracks.length,
              itemBuilder: (_, index) {
                final track = _tracks[index];
                final alreadyAdded = _selectedPlaylistTracks.any(
                  (item) => item.id == track.id,
                );
                return CheckboxListTile(
                  value: alreadyAdded || selectedIds.contains(track.id),
                  onChanged: alreadyAdded
                      ? null
                      : (value) => setDialogState(() {
                          if (value == true) {
                            selectedIds.add(track.id);
                          } else {
                            selectedIds.remove(track.id);
                          }
                        }),
                  title: Text(track.title, maxLines: 1),
                  subtitle: Text(track.displayArtist, maxLines: 1),
                  secondary: _artwork(track, 40),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, selectedIds.toList()),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    for (final trackId in selected) {
      await widget.library.database.addTrackToPlaylist(playlistId, trackId);
    }
    await _reloadPlaylistState();
  }

  Future<void> _reloadPlaylistState() async {
    final playlists = await widget.library.database.playlists();
    final tracks = _selectedPlaylistId == null
        ? <Track>[]
        : await widget.library.database.playlistTracks(_selectedPlaylistId!);
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _selectedPlaylistTracks = tracks;
    });
  }

  Widget _trackRow(
    Track track,
    int index,
    List<Track> contextTracks, {
    String? playlistId,
  }) => ListTile(
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
            if (v == 'playlist') await _addTrackToPlaylist(track);
            if (v == 'remove_playlist' && playlistId != null) {
              await widget.library.database.removeTrackFromPlaylist(
                playlistId,
                track.id,
              );
              await _reloadPlaylistState();
            }
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
            const PopupMenuItem(
              value: 'playlist',
              child: Text('Add to playlist'),
            ),
            if (playlistId != null)
              const PopupMenuItem(
                value: 'remove_playlist',
                child: Text('Remove from playlist'),
              ),
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
      albums.putIfAbsent(_albumKey(track), () => []).add(track);
    }
    final entries = albums.entries.toList()
      ..sort((a, b) {
        final aPinned = _pinnedAlbumKeys.contains(a.key);
        final bPinned = _pinnedAlbumKeys.contains(b.key);
        if (aPinned != bPinned) return aPinned ? -1 : 1;
        final aTrack = a.value.first;
        final bTrack = b.value.first;
        int result;
        if (_albumSort.startsWith('year')) {
          final ay = a.value.map((t) => t.year).whereType<int>().toList();
          final by = b.value.map((t) => t.year).whereType<int>().toList();
          final aYear = ay.isEmpty ? null : ay.reduce((x, y) => x > y ? x : y);
          final bYear = by.isEmpty ? null : by.reduce((x, y) => x > y ? x : y);
          if (aYear == null && bYear != null) return 1;
          if (bYear == null && aYear != null) return -1;
          result = (aYear ?? 0).compareTo(bYear ?? 0);
          if (_albumSort == 'year_desc') result = -result;
        } else {
          result = aTrack.displayAlbum.toLowerCase().compareTo(bTrack.displayAlbum.toLowerCase());
          if (_albumSort == 'title_desc') result = -result;
        }
        if (result != 0) return result;
        return aTrack.displayArtist.toLowerCase().compareTo(bTrack.displayArtist.toLowerCase());
      });
    if (!_grid) {
      return ListView.builder(
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final t = e.value.first;
          final pinned = _pinnedAlbumKeys.contains(e.key);
          return ListTile(
            leading: _artwork(t, 52),
            title: Text(t.displayAlbum),
            subtitle: Text(
              '${_albumArtistLabel(e.value)}  ·  ${e.value.length} tracks${t.year == null ? '' : '  ·  ${t.year}'}',
              style: const TextStyle(color: BitwaveColors.muted, fontSize: 12),
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'Album options',
              onSelected: (value) { if (value == 'pin') unawaited(_toggleAlbumPin(e.key)); },
              itemBuilder: (_) => [PopupMenuItem(value: 'pin', child: Text(pinned ? 'Unpin album' : 'Pin album to top'))],
              icon: Icon(pinned ? Icons.push_pin_rounded : Icons.more_vert_rounded),
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
        final pinned = _pinnedAlbumKeys.contains(e.key);
        return InkWell(
          onTap: () => _openAlbum(e.value),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Center(child: _artwork(t, 158, radius: 7)),
                    Positioned(
                      top: 4, right: 4,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        child: PopupMenuButton<String>(
                          tooltip: 'Album options',
                          icon: Icon(pinned ? Icons.push_pin_rounded : Icons.more_horiz_rounded, color: Colors.white, size: 20),
                          onSelected: (value) { if (value == 'pin') unawaited(_toggleAlbumPin(e.key)); },
                          itemBuilder: (_) => [PopupMenuItem(value: 'pin', child: Text(pinned ? 'Unpin album' : 'Pin album to top'))],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 9),
              Text(
                t.displayAlbum,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                _albumArtistLabel(e.value),
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
    if (_selectedArtist case final selectedArtist?) {
      final selectedTracks = tracks
          .where((track) => track.displayArtist == selectedArtist)
          .toList();
      return Column(
        children: [
          ListTile(
            leading: const Icon(Icons.arrow_back_rounded),
            title: Text(selectedArtist),
            subtitle: Text('${selectedTracks.length} tracks'),
            onTap: () => setState(() => _selectedArtist = null),
          ),
          const Divider(height: 1, color: BitwaveColors.line),
          Expanded(child: _songList(selectedTracks)),
        ],
      );
    }
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
          onTap: () => setState(() => _selectedArtist = name),
        );
      },
    );
  }

  void _openArtist(String artist) {
    setState(() {
      _section = LibrarySection.artists;
      _selectedArtist = artist;
    });
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
        onTap: () => setState(() => _selectedGenre = names[i]),
      ),
    );
  }

  Widget _folderBrowser(List<Track> tracks) {
    final folders = <String, List<Track>>{};
    for (final track in tracks) {
      folders.putIfAbsent(File(track.path).parent.path, () => []).add(track);
    }
    final paths = folders.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (paths.isEmpty) return _emptyLibrary();
    return ListView.builder(
      itemCount: paths.length,
      itemBuilder: (context, index) {
        final path = paths[index];
        final folderTracks = folders[path]!;
        final name = path.split(Platform.pathSeparator).last;
        return ListTile(
          leading: const Icon(
            Icons.folder_outlined,
            color: BitwaveColors.accent,
          ),
          title: Text(name.isEmpty ? path : name),
          subtitle: Text('${folderTracks.length} tracks'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => setState(() => _selectedFolderPath = path),
        );
      },
    );
  }

  void _openAlbum(List<Track> tracks) {
    if (tracks.isEmpty) return;
    setState(() => _albumDetailTracks = _tracksByTrackNumber(tracks));
  }

  Future<void> _addTracksToPlaylist(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    if (_playlists.isEmpty) {
      final id = await _createPlaylist();
      if (id == null) return;
      for (final track in tracks) {
        await widget.library.database.addTrackToPlaylist(id, track.id);
      }
      await _reloadPlaylistState();
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BitwaveColors.panel,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Add album to playlist')),
            ..._playlists.map(
              (playlist) => ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(playlist.name),
                onTap: () => Navigator.pop(sheetContext, playlist.id),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Create playlist'),
              onTap: () => Navigator.pop(sheetContext, '__create__'),
            ),
          ],
        ),
      ),
    );
    final playlistId = selected == '__create__'
        ? await _createPlaylist()
        : selected;
    if (playlistId == null) return;
    for (final track in tracks) {
      await widget.library.database.addTrackToPlaylist(playlistId, track.id);
    }
    await _reloadPlaylistState();
  }

  List<Track> _tracksByTrackNumber(List<Track> tracks) {
    final sorted = List<Track>.of(tracks);
    sorted.sort((a, b) {
      final byDisc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
      if (byDisc != 0) return byDisc;
      final aNumber = a.trackNumber;
      final bNumber = b.trackNumber;
      if (aNumber == null && bNumber != null) return 1;
      if (aNumber != null && bNumber == null) return -1;
      final byNumber = (aNumber ?? 0).compareTo(bNumber ?? 0);
      return byNumber != 0
          ? byNumber
          : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return sorted;
  }

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

  Widget _menuPane() => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        tooltip: 'Return to now playing',
        onPressed: _openPlayer,
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      title: const Text('Menu'),
    ),
    body: SafeArea(
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
                  _libraryReady
                      ? '${_tracks.length} tracks  ·  ${_albumCount()} albums'
                      : 'Loading library…',
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
                ListTile(
                  leading: const Icon(
                    Icons.headphones_rounded,
                    color: BitwaveColors.muted,
                  ),
                  title: const Text('Listening'),
                  onTap: _openPlayer,
                ),
                _navItem(
                  LibrarySection.playlists,
                  Icons.queue_music_rounded,
                  'Playlists',
                ),
                const Divider(color: BitwaveColors.line, height: 14),
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
                  LibrarySection.genres,
                  Icons.category_outlined,
                  'Genres',
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: StreamBuilder<PlaybackState>(
              stream: widget.audio.playbackState,
              initialData: widget.audio.playbackState.value,
              builder: (context, snapshot) {
                final state = snapshot.data;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(
                      tooltip: state?.shuffleMode == AudioServiceShuffleMode.all
                          ? 'Shuffle on'
                          : 'Shuffle off',
                      onPressed: widget.audio.toggleShuffle,
                      icon: Icon(
                        Icons.shuffle_rounded,
                        color: state?.shuffleMode == AudioServiceShuffleMode.all
                            ? BitwaveColors.accent
                            : BitwaveColors.muted,
                      ),
                    ),
                    IconButton(
                      tooltip: switch (state?.repeatMode) {
                        AudioServiceRepeatMode.one => 'Repeat one',
                        AudioServiceRepeatMode.all => 'Repeat all',
                        _ => 'Repeat off',
                      },
                      onPressed: widget.audio.cycleRepeat,
                      icon: Icon(
                        state?.repeatMode == AudioServiceRepeatMode.one
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        color: state?.repeatMode == AudioServiceRepeatMode.none
                            ? BitwaveColors.muted
                            : BitwaveColors.accent,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      onPressed: () {
                        setState(() {
                          _section = LibrarySection.settings;
                          _selectedPlaylistId = null;
                        });
                        _openLibrary();
                      },
                      icon: const Icon(
                        Icons.settings_outlined,
                        color: BitwaveColors.muted,
                      ),
                    ),
                  ],
                );
              },
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
        _selectedArtist = null;
        _selectedFolderPath = null;
        _selectedGenre = null;
        _selectedPlaylistId = null;
        _selectedPlaylistTracks = [];
        if (section == LibrarySection.library) _activeCategoryIndex = 0;
      });
      if (section == LibrarySection.library && _deckController.hasClients) {
        _deckController.jumpToPage(0);
      }
      _openLibrary();
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Add to playlist',
                            icon: const Icon(
                              Icons.playlist_add_rounded,
                              color: BitwaveColors.muted,
                            ),
                            onPressed: () => _addTrackToPlaylist(t),
                          ),
                          IconButton(
                            tooltip: 'Remove from queue',
                            icon: const Icon(
                              Icons.close,
                              color: BitwaveColors.muted,
                            ),
                            onPressed: () => widget.audio.removeFromQueue(i),
                          ),
                        ],
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
        Icons.sync_rounded,
        'Refresh library',
        _scanning
            ? 'Checking local music…'
            : 'Reload saved tracks and check the Bitwave folder',
        onTap: _scanning ? null : _refreshLibraryFromSettings,
      ),
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
      _settingRow(
        Icons.folder_open_rounded,
        'Import music folder',
        'Add supported audio files from a folder',
        onTap: _importFolder,
      ),
      _settingHeading('SCROBBLING'),
      _settingRow(
        Icons.radio_button_checked_rounded,
        'Last.fm',
        widget.audio.lastFm.connected
            ? 'Connected as ${widget.audio.lastFm.username ?? 'Last.fm user'}'
            : 'Connect your account and scrobble plays',
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  LastFmSettingsPage(scrobbler: widget.audio.lastFm),
            ),
          );
          if (mounted) setState(() {});
        },
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
      _settingHeading('PLAYBACK'),
      _settingRow(
        Icons.timer_outlined,
        'Sleep timer',
        _sleepDeadline == null
            ? 'Off'
            : 'Stops at ${TimeOfDay.fromDateTime(_sleepDeadline!).format(context)}',
        onTap: _chooseSleepTimer,
      ),
      if (Platform.isIOS)
        _settingRow(
          Icons.equalizer_rounded,
          'Equalizer',
          '10-band audio equalizer',
          onTap: _openEqualizer,
        ),
      _settingHeading('LYRICS'),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Lyrics sharing'),
        subtitle: const Text('Allow exporting lyrics as shareable images'),
        value: _lyricsSharingEnabled,
        onChanged: (value) async {
          await widget.library.database.setLyricsSharingEnabled(value);
          if (mounted) setState(() => _lyricsSharingEnabled = value);
        },
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

  Future<void> _openEqualizer() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EqualizerPage(
          equalizer: widget.audio.equalizer,
          onChanged: () async {
            final enabled = widget.audio.equalizer.enabled;
            final bands = widget.audio.equalizer.bands.join(',');
            await widget.library.database.setEqualizerEnabled(enabled);
            await widget.library.database.setEqualizerBands(bands);
          },
        ),
      ),
    );
  }

  Widget _artwork(Track? track, double size, {double radius = 8}) {
    final decodeSize = size.isFinite
        ? (size * MediaQuery.devicePixelRatioOf(context)).round()
        : null;
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
        cacheWidth: decodeSize,
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
        cacheWidth: decodeSize,
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
    return _tracksById[id];
  }

  int _albumCount() => _albumIndex.length;
  static String _time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _AlbumDetailPage extends StatelessWidget {
  const _AlbumDetailPage({
    required this.tracks,
    required this.audio,
    required this.onEditArtwork,
    required this.onAddToPlaylist,
    required this.onBack,
  });

  final List<Track> tracks;
  final BitwaveAudioHandler audio;
  final VoidCallback onEditArtwork;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onBack;

  String _durationLabel(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) return '$hours hr $minutes min';
    return '$minutes min';
  }

  String _trackTime(Duration duration) =>
      '${duration.inMinutes}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final album = tracks.first;
    final artists = tracks.map((track) => track.displayArtist).toSet();
    final artist = artists.length == 1
        ? artists.first
        : artists.isEmpty
        ? 'Unknown artist'
        : 'Various Artists';
    final totalDuration = tracks.fold<Duration>(
      Duration.zero,
      (total, track) => total + track.duration,
    );
    final formats = tracks.map((track) => track.format.toUpperCase()).toSet();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            foregroundColor: Colors.white,
            expandedHeight: MediaQuery.sizeOf(context).width * 1.02,
            toolbarHeight: 82,
            leadingWidth: 76,
            leading: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: _albumAction(
                icon: Icons.chevron_left_rounded,
                label: 'Back',
                onPressed: onBack,
              ),
            ),
            actions: [
              _albumAction(
                icon: Icons.play_arrow_rounded,
                label: 'Play album',
                onPressed: () => audio.playTracks(tracks),
              ),
              _albumAction(
                icon: Icons.shuffle_rounded,
                label: 'Shuffle album',
                onPressed: () => audio.playTracks(List.of(tracks)..shuffle()),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 18),
                child: PopupMenuButton<String>(
                  tooltip: 'Album options',
                  color: BitwaveColors.panel,
                  icon: const CircleAvatar(
                    backgroundColor: Color(0x66282828),
                    child: Icon(Icons.more_horiz_rounded),
                  ),
                  onSelected: (value) {
                    if (value == 'artwork') onEditArtwork();
                    if (value == 'playlist') onAddToPlaylist();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'playlist',
                      child: Text('Add album to playlist'),
                    ),
                    PopupMenuItem(
                      value: 'artwork',
                      child: Text('Edit album artwork'),
                    ),
                  ],
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _NowPlayingArtwork(track: album),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x33000000),
                          Colors.transparent,
                          Color(0xCC090A0B),
                        ],
                        stops: [0, .52, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.displayAlbum,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 38,
                      height: 1.05,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -1.1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '$artist  ·  ${tracks.length} songs  ·  ${_durationLabel(totalDuration)}',
                    style: const TextStyle(
                      color: Color(0xFFC5C4C3),
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formats.join(' · '),
                    style: const TextStyle(
                      color: Color(0xFFAAA9A8),
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 32),
            sliver: SliverList.separated(
              itemCount: tracks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (context, index) {
                final track = tracks[index];
                final number = track.trackNumber ?? index + 1;
                return StreamBuilder<MediaItem?>(
                  stream: audio.mediaItem,
                  builder: (context, snapshot) {
                    final isCurrent = snapshot.data?.id == track.id;
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () =>
                          audio.playTracks(tracks, initialIndex: index),
                      child: SizedBox(
                        height: 76,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 38,
                              child: Text(
                                '$number',
                                textAlign: TextAlign.left,
                                style: TextStyle(
                                  color: isCurrent
                                      ? BitwaveColors.accent
                                      : const Color(0xFF8F9092),
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    track.displayArtist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFFAAA9A8),
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Text(
                              _trackTime(track.duration),
                              style: const TextStyle(
                                color: Color(0xFFAAA9A8),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _albumAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 5),
    child: IconButton(
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: const Color(0x66282828),
        foregroundColor: const Color(0xFFF4F2EF),
        fixedSize: const Size(46, 46),
      ),
      icon: Icon(icon, size: 25),
    ),
  );
}

class _NowPlayingScreen extends StatefulWidget {
  const _NowPlayingScreen({
    required this.audio,
    required this.artworkStyle,
    required this.lyricsSharingEnabled,
    required this.onOpenDetails,
    required this.onAddToPlaylist,
    required this.onOpenMenu,
  });

  final BitwaveAudioHandler audio;
  final String artworkStyle;
  final bool lyricsSharingEnabled;
  final ValueChanged<Track> onOpenDetails;
  final ValueChanged<Track> onAddToPlaylist;
  final VoidCallback onOpenMenu;

  @override
  State<_NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingPill extends StatelessWidget {
  const _NowPlayingPill({
    required this.audio,
    required this.onTap,
    required this.onSwipe,
    required this.availableHeight,
  });

  final BitwaveAudioHandler audio;
  final VoidCallback onTap;
  final VoidCallback onSwipe;
  final double availableHeight;

  @override
  Widget build(BuildContext context) => StreamBuilder<MediaItem?>(
    stream: audio.mediaItem,
    builder: (context, snapshot) {
      final item = snapshot.data;
      final rawTitle = item?.title;
      final title = rawTitle == null || rawTitle.isEmpty
          ? 'Now playing'
          : rawTitle.trim();
      final label = [
        title,
        if ((item?.artist ?? '').isNotEmpty) item!.artist!,
      ].join(' · ');
      final maxHeight = math.max(
        150.0,
        math.min(availableHeight * .78, availableHeight - 24),
      );
      final minHeight = math.min(180.0, maxHeight);
      final pillHeight = (label.length * 7.5 + 104).clamp(minHeight, maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onHorizontalDragEnd: (_) => onSwipe(),
        onVerticalDragEnd: (_) => onSwipe(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: 46,
          height: pillHeight,
          decoration: BoxDecoration(
            color: const Color(0xFF08090B),
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(27),
            ),
            border: Border.all(color: const Color(0x20FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 18,
                offset: Offset(-5, 0),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: Center(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SizedBox(
                        width: math.max(40, constraints.maxHeight - 52),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFE5E3E1),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            letterSpacing: .2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                StreamBuilder<bool>(
                  stream: audio.player.playingStream,
                  initialData: audio.player.playing,
                  builder: (context, playback) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Icon(
                      playback.data == true
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: const Color(0xFFF3F0EB),
                      size: 22,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _NowPlayingScreenState extends State<_NowPlayingScreen> {
  bool _immersiveArtwork = false;
  bool _playbackControlVisible = true;
  Timer? _playbackControlTimer;

  @override
  void initState() {
    super.initState();
    _schedulePlaybackControlHide();
  }

  @override
  void didUpdateWidget(covariant _NowPlayingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealPlaybackControl();
  }

  @override
  void dispose() {
    _playbackControlTimer?.cancel();
    super.dispose();
  }

  void _schedulePlaybackControlHide() {
    _playbackControlTimer?.cancel();
    _playbackControlTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _playbackControlVisible = false);
    });
  }

  void _revealPlaybackControl() {
    if (!_playbackControlVisible) {
      setState(() => _playbackControlVisible = true);
    }
    _schedulePlaybackControlHide();
  }

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
      if (item == null) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: 4,
                  right: 10,
                  child: IconButton(
                    tooltip: 'Open menu',
                    onPressed: widget.onOpenMenu,
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.graphic_eq_rounded,
                        color: BitwaveColors.accent,
                        size: 54,
                      ),
                      const SizedBox(height: 16),
                      const Text('Nothing playing'),
                      const SizedBox(height: 6),
                      Text(
                        'Swipe right to open your library',
                        style: TextStyle(color: BitwaveColors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      final track = widget.audio.tracks
          .where((t) => t.id == item.id)
          .firstOrNull;
      final ratio = _aspectRatio(track);
      final immersiveArtwork = _immersiveArtwork;

      return Scaffold(
        backgroundColor: const Color(0xFF090A0B),
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (track != null)
              _AdaptiveArtworkBackdrop(
                key: ValueKey('backdrop-${track.id}'),
                track: track,
              ),
            if (track != null && immersiveArtwork)
              Positioned.fill(
                child: _NowPlayingArtwork(
                  key: ValueKey('immersive-${track.id}'),
                  track: track,
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x10000000),
                    Color(0x22000000),
                    Color(0x72000000),
                    Color(0xD9090A0B),
                  ],
                  stops: [0, .35, .72, 1],
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 10,
              child: SafeArea(
                child: IconButton(
                  tooltip: 'Open menu',
                  onPressed: widget.onOpenMenu,
                  icon: const Icon(Icons.more_horiz_rounded),
                  color: const Color(0xFFD7D5D3),
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth > constraints.maxHeight) {
                    return _landscapeNowPlaying(
                      constraints: constraints,
                      item: item,
                      track: track,
                      ratio: ratio,
                    );
                  }
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
                          child: Stack(
                            fit: StackFit.expand,
                            alignment: Alignment.center,
                            children: [
                              track == null
                                  ? const _ArtworkPlaceholder()
                                  : GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        _revealPlaybackControl();
                                        if (widget.audio.player.playing) {
                                          widget.audio.pause();
                                        } else {
                                          widget.audio.play();
                                        }
                                      },
                                      onDoubleTap: () {
                                        _revealPlaybackControl();
                                        setState(
                                          () => _immersiveArtwork =
                                              !_immersiveArtwork,
                                        );
                                      },
                                      onVerticalDragEnd: (details) {
                                        final velocity =
                                            details.primaryVelocity ?? 0;
                                        if (velocity < -350) {
                                          _revealPlaybackControl();
                                          widget.audio.skipToNext();
                                        } else if (velocity > 350) {
                                          _revealPlaybackControl();
                                          widget.audio.skipToPrevious();
                                        }
                                      },
                                      child: immersiveArtwork
                                          ? const SizedBox.expand()
                                          : _NowPlayingArtwork(
                                              key: ValueKey(track.id),
                                              track: track,
                                            ),
                                    ),
                              if (track != null)
                                IgnorePointer(
                                  child: AnimatedOpacity(
                                    opacity: _playbackControlVisible ? 1 : 0,
                                    duration: const Duration(milliseconds: 260),
                                    child: StreamBuilder<bool>(
                                      stream: widget.audio.player.playingStream,
                                      initialData: widget.audio.player.playing,
                                      builder: (context, playback) => Center(
                                        child: DecoratedBox(
                                          decoration: const BoxDecoration(
                                            color: Color(0x55000000),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(15),
                                            child: Icon(
                                              playback.data == true
                                                  ? Icons.pause_rounded
                                                  : Icons.play_arrow_rounded,
                                              size: 38,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: constraints.maxHeight * .09),
                      if (track?.lyrics?.trim().isNotEmpty == true)
                        WordSyncedLyrics(
                          lyrics: track!.lyrics!,
                          track: track!,
                          lyricsSharingEnabled: widget.lyricsSharingEnabled,
                          positionStream: widget.audio.player.positionStream,
                          onSeek: (position) =>
                              widget.audio.player.seek(position),
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
                            if (track != null)
                              IconButton(
                                tooltip: 'Add to playlist',
                                onPressed: () => widget.onAddToPlaylist(track),
                                icon: const Icon(
                                  Icons.playlist_add_rounded,
                                  color: BitwaveColors.muted,
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
                      _OutputDeviceLabel(formatInfo: _compactFormatInfo(track)),
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

  static String _format(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  static String _compactFormatInfo(Track? track) {
    final parts = <String>[];
    if (track?.codec != null) {
      parts.add(track!.codec!);
      if (track.isLossless) {
        parts.add('LOSSLESS');
      }
    } else {
      parts.add(track?.format ?? 'Audio');
    }
    if (track?.bitrateKbps != null) {
      parts.add('${track!.bitrateKbps} kbps');
    }
    return parts.join('  ·  ');
  }

  Widget _landscapeNowPlaying({
    required BoxConstraints constraints,
    required MediaItem item,
    required Track? track,
    required double ratio,
  }) {
    final artWidth = math.min(
      (constraints.maxHeight - 28) * ratio,
      constraints.maxWidth * .48,
    );
    final albumLine = [
      if ((track?.displayAlbum ?? '').isNotEmpty) track!.displayAlbum,
      if (track?.year != null) '${track!.year}',
    ].join('  ·  ');
    return Row(
      children: [
        SizedBox(
          width: constraints.maxWidth * .49,
          child: Center(
            child: SizedBox(
              width: artWidth,
              height: artWidth / ratio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (track != null)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _revealPlaybackControl();
                        if (widget.audio.player.playing) {
                          widget.audio.pause();
                        } else {
                          widget.audio.play();
                        }
                      },
                      onDoubleTap: () {
                        _revealPlaybackControl();
                        setState(() => _immersiveArtwork = !_immersiveArtwork);
                      },
                      onVerticalDragEnd: (details) {
                        final velocity = details.primaryVelocity ?? 0;
                        if (velocity < -350) {
                          _revealPlaybackControl();
                          widget.audio.skipToNext();
                        } else if (velocity > 350) {
                          _revealPlaybackControl();
                          widget.audio.skipToPrevious();
                        }
                      },
                      child: _NowPlayingArtwork(
                        key: ValueKey('landscape-${track.id}'),
                        track: track,
                      ),
                    )
                  else
                    const _ArtworkPlaceholder(),
                  if (track != null)
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _playbackControlVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 260),
                        child: StreamBuilder<bool>(
                          stream: widget.audio.player.playingStream,
                          initialData: widget.audio.player.playing,
                          builder: (context, playback) => Center(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                color: Color(0x55000000),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Icon(
                                  playback.data == true
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 34,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 46, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                Center(
                  child: Column(
                    children: [
                      Text(
                        albumLine.isEmpty ? item.album ?? '' : albumLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '${track?.format ?? 'Audio'}${track?.bitrateKbps == null ? '' : '  ·  ${track!.bitrateKbps} kbps'}',
                        style: const TextStyle(
                          color: BitwaveColors.muted,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                InkWell(
                  onTap: track == null
                      ? null
                      : () => widget.onOpenDetails(track),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 34,
                          height: 1.05,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        track?.displayArtist ?? item.artist ?? 'Unknown artist',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                StreamBuilder<Duration>(
                  stream: widget.audio.player.positionStream,
                  builder: (context, positionSnapshot) {
                    final duration = item.duration ?? Duration.zero;
                    final position = positionSnapshot.data ?? Duration.zero;
                    final max = duration.inMilliseconds.toDouble();
                    final value = max <= 0
                        ? 0.0
                        : position.inMilliseconds
                              .clamp(0, duration.inMilliseconds)
                              .toDouble();
                    return Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2.5,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 3.2,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                          ),
                          child: Slider(
                            value: value,
                            max: max <= 0 ? 1 : max,
                            onChanged: max <= 0
                                ? null
                                : (nextPosition) => widget.audio.seek(
                                    Duration(
                                      milliseconds: nextPosition.round(),
                                    ),
                                  ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_format(position)),
                              Text(_format(duration)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 13),
                Center(
                  child: _OutputDeviceLabel(
                    formatInfo: _compactFormatInfo(track),
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AdaptiveArtworkBackdrop extends StatelessWidget {
  const _AdaptiveArtworkBackdrop({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final track = this.track;
    final path = track.artworkPath ?? track.embeddedArtworkPath;
    final media = MediaQuery.sizeOf(context);
    final decodeSize =
        (math.max(media.width, media.height) *
                MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(1, 1536);
    final Widget image;
    if (track.providerArtworkUrl != null && track.customArtworkPath == null) {
      image = Image.network(
        track.providerArtworkUrl!,
        fit: BoxFit.cover,
        cacheWidth: decodeSize,
        errorBuilder: (_, _, _) => const _ArtworkPlaceholder(),
      );
    } else if (path != null) {
      image = Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: decodeSize,
        errorBuilder: (_, _, _) => const _ArtworkPlaceholder(),
      );
    } else if (track.artwork != null) {
      image = Image.memory(
        track.artwork!,
        fit: BoxFit.cover,
        cacheWidth: decodeSize,
        gaplessPlayback: true,
      );
    } else {
      image = const _ArtworkPlaceholder();
    }
    return ClipRect(
      child: Transform.scale(
        scale: 1.22,
        child: RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
            child: image,
          ),
        ),
      ),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF17191B),
    child: Center(
      child: Icon(
        Icons.graphic_eq_rounded,
        size: 90,
        color: BitwaveColors.accent,
      ),
    ),
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
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * .88,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0x6608080A),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x28FFFFFF)),
        ),
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
      ),
    ),
  );
}

class _NowPlayingArtwork extends StatelessWidget {
  const _NowPlayingArtwork({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final fit = track.artworkFit == 'fit' ? BoxFit.contain : BoxFit.cover;
    final alignment = Alignment(track.artworkFocusX, track.artworkFocusY);
    final path = track.artworkPath;
    final media = MediaQuery.sizeOf(context);
    final decodeSize =
        (math.max(media.width, media.height) *
                MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(1, 2048);
    if (path != null) {
      return Image.file(
        File(path),
        fit: fit,
        alignment: alignment,
        cacheWidth: decodeSize,
        errorBuilder: (_, _, _) => _fallback(),
      );
    }
    if (track.providerArtworkUrl != null) {
      return Image.network(
        track.providerArtworkUrl!,
        fit: BoxFit.cover,
        cacheWidth: decodeSize,
        errorBuilder: (_, _, _) => _localOrFallback(),
      );
    }
    if (track.artwork != null) {
      return Image.memory(
        track.artwork!,
        fit: BoxFit.cover,
        cacheWidth: decodeSize,
        gaplessPlayback: true,
      );
    }
    return _fallback();
  }

  Widget _localOrFallback() {
    final path = track.embeddedArtworkPath;
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
