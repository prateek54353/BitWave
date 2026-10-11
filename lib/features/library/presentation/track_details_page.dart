import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../../../core/database/library_database.dart';
import '../../artwork/data/apple_music_artwork_provider.dart';
import '../../artwork/data/artwork_repository.dart';
import '../../artwork/domain/artwork_asset.dart';
import '../../artwork/presentation/artwork_editor_sheet.dart';
import '../../player/data/bitwave_audio_handler.dart';
import '../../lyrics/data/lrclib_provider.dart';
import '../data/library_repository.dart';
import '../domain/track.dart';

class TrackDetailsPage extends StatefulWidget {
  const TrackDetailsPage({
    super.key,
    required this.track,
    required this.library,
    required this.artworkRepository,
    required this.audio,
    required this.onUpdated,
  });

  final Track track;
  final LibraryRepository library;
  final ArtworkRepository artworkRepository;
  final BitwaveAudioHandler audio;
  final Future<void> Function() onUpdated;

  @override
  State<TrackDetailsPage> createState() => _TrackDetailsPageState();
}

class _TrackDetailsPageState extends State<TrackDetailsPage> {
  static const _storage = FlutterSecureStorage();
  final _provider = AppleMusicArtworkProvider();
  final _lyricsProvider = LrclibProvider();
  late Track _track;
  late final Map<String, TextEditingController> _fields;
  List<AppleArtworkMatch> _matches = [];
  bool _saving = false;
  bool _searching = false;
  bool _searchingLyrics = false;
  List<LyricsMatch> _lyricsMatches = [];
  String? _lyricsError;
  String? _providerError;

  @override
  void initState() {
    super.initState();
    _track = widget.track;
    _fields = {
      'Title': TextEditingController(text: _track.title),
      'Artist': TextEditingController(text: _track.artist),
      'Album': TextEditingController(text: _track.album),
      'Album artist': TextEditingController(text: _track.albumArtist),
      'Genre': TextEditingController(text: _track.genre),
      'Year': TextEditingController(text: _track.year?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _provider.dispose();
    _lyricsProvider.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    await widget.onUpdated();
    final all = await widget.library.load();
    final latest = all.where((track) => track.id == _track.id).firstOrNull;
    if (latest != null && mounted) setState(() => _track = latest);
  }

  Future<void> _saveTags() async {
    final yearValue = int.tryParse(_fields['Year']!.text.trim());
    if (_fields['Year']!.text.trim().isNotEmpty && yearValue == null) {
      _message('Enter a valid four-digit year.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.library.database.updateTags(
        id: _track.id,
        title: _fields['Title']!.text.trim(),
        artist: _fields['Artist']!.text.trim(),
        album: _fields['Album']!.text.trim(),
        albumArtist: _fields['Album artist']!.text.trim(),
        genre: _fields['Genre']!.text.trim(),
        year: yearValue,
      );
      final all = await widget.library.load();
      final updated = all.where((track) => track.id == _track.id).first;
      widget.audio.updateTrackMetadata(updated);
      await widget.onUpdated();
      if (mounted) {
        setState(() => _track = updated);
        _message(
          'Tags saved to the Bitwave library. The audio file was not changed.',
        );
      }
    } catch (error) {
      if (mounted) _message('Tags could not be saved: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetTags() async {
    try {
      final metadata = readMetadata(File(_track.path), getImage: false);
      _fields['Title']!.text = _source(metadata.title) ?? _track.title;
      _fields['Artist']!.text = _source(metadata.artist) ?? '';
      _fields['Album']!.text = _source(metadata.album) ?? '';
      _fields['Album artist']!.text = _source(metadata.albumArtist) ?? '';
      _fields['Genre']!.text = metadata.genres.join(', ');
      _fields['Year']!.text = metadata.year?.year.toString() ?? '';
      await _saveTags();
    } catch (error) {
      _message('The file tags could not be read: $error');
    }
  }

  Future<void> _editArtwork() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BitwaveColors.panel,
      builder: (_) => ArtworkEditorSheet(
        tracks: [_track],
        repository: widget.artworkRepository,
        onSaved: _reload,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _searchAppleMusic() async {
    final token = await _storage.read(key: 'apple_music_developer_token');
    if (token == null || token.trim().isEmpty) {
      setState(
        () => _providerError = 'Add an Apple Music developer token in Settings → Library → Artwork Providers.',
      );
      return;
    }
    final query = [
      _fields['Title']!.text,
      _fields['Artist']!.text,
      _fields['Album artist']!.text,
      _fields['Album']!.text,
      _fields['Year']!.text,
    ].where((value) => value.trim().isNotEmpty).join(' ');
    setState(() {
      _searching = true;
      _providerError = null;
      _matches = [];
    });
    try {
      final storefront =
          await widget.library.database.getSetting('apple_music_storefront') ??
          'us';
      final results = await _provider.search(
        term: query,
        developerToken: token,
        storefront: storefront,
      );
      if (mounted) setState(() => _matches = results);
    } catch (error) {
      if (mounted) setState(() => _providerError = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _chooseAppleMatch(AppleArtworkMatch match) async {
    await widget.artworkRepository.assignAppleMatch(
      [_track],
      match,
      1000,
      1000,
    );
    await _reload();
    if (mounted) {
      _message(
        'Apple Music artwork linked. Bitwave stores the artwork URL, not a downloaded copy.',
      );
    }
  }

  Future<void> _searchLyrics() async {
    setState(() {
      _searchingLyrics = true;
      _lyricsMatches = [];
      _lyricsError = null;
    });
    try {
      final results = await _lyricsProvider.search(
        title: _fields['Title']!.text.trim(),
        artist: _fields['Artist']!.text.trim().isEmpty
            ? _fields['Album artist']!.text.trim()
            : _fields['Artist']!.text.trim(),
        album: _fields['Album']!.text.trim(),
      );
      if (mounted) {
        setState(() {
          _lyricsMatches = results;
          if (results.isEmpty) _lyricsError = 'No lyrics matches found.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _lyricsError = error.toString());
    } finally {
      if (mounted) setState(() => _searchingLyrics = false);
    }
  }

  Future<void> _chooseLyrics(LyricsMatch match) async {
    final lyrics = match.preferredLyrics;
    if (lyrics == null) return;
    await widget.library.database.updateLyrics(id: _track.id, lyrics: lyrics);
    await _reload();
    if (mounted) _message('Lyrics saved for offline playback.');
  }

  Future<void> _clearLyrics() async {
    await widget.library.database.updateLyrics(id: _track.id, lyrics: null);
    await _reload();
    if (mounted) _message('Saved lyrics removed.');
  }

  String? _source(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : null;
  void _message(String value) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Track details', style: TextStyle(fontSize: 17)),
      actions: [
        TextButton(
          onPressed: _saving ? null : _saveTags,
          child: Text(_saving ? 'Saving' : 'Save'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 34),
      children: [
        _heroArtwork(),
        const SizedBox(height: 22),
        _artistSummary(),
        const SizedBox(height: 15),
        _panel(
          children: [
            for (final entry in _fields.entries)
              _tagField(entry.key, entry.value),
            _artworkField(),
          ],
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _resetTags,
            icon: const Icon(Icons.undo_rounded, size: 17),
            label: const Text('Reset to file tags'),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                'LYRICS',
                style: TextStyle(
                  color: BitwaveColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
            ),
            if ((_track.lyrics ?? '').isNotEmpty)
              TextButton(onPressed: _clearLyrics, child: const Text('Remove')),
            TextButton.icon(
              onPressed: _searchingLyrics ? null : _searchLyrics,
              icon: _searchingLyrics
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search, size: 18),
              label: const Text('LRCLIB'),
            ),
          ],
        ),
        if ((_track.lyrics ?? '').trim().isNotEmpty)
          _panel(
            children: [
              Padding(
                padding: const EdgeInsets.all(15),
                child: Text(
                  _track.lyrics!.trim(),
                  maxLines: 7,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: BitwaveColors.muted,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          )
        else
          _panel(
            children: const [
              Padding(
                padding: EdgeInsets.all(15),
                child: Text(
                  'No saved lyrics for this track.',
                  style: TextStyle(color: BitwaveColors.muted),
                ),
              ),
            ],
          ),
        if (_lyricsError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _lyricsError!,
              style: const TextStyle(color: BitwaveColors.muted),
            ),
          ),
        if (_lyricsMatches.isNotEmpty) _lyricsMatchList(),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                'SUGGESTED ARTWORK',
                style: TextStyle(
                  color: BitwaveColors.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _searching ? null : _searchAppleMusic,
              icon: _searching
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search, size: 18),
              label: const Text('Apple Music'),
            ),
          ],
        ),
        if (_providerError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _providerError!,
              style: const TextStyle(color: BitwaveColors.muted, height: 1.4),
            ),
          ),
        if (_matches.isNotEmpty) _appleMatches(),
        if (_matches.isEmpty && _providerError == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 7),
            child: Text(
              'Search the catalog and choose a release yourself. Matches are never applied automatically.',
              style: TextStyle(color: BitwaveColors.muted, fontSize: 13),
            ),
          ),
        const SizedBox(height: 18),
        const Text(
          'FILE',
          style: TextStyle(
            color: BitwaveColors.accent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 9),
        _panel(
          children: [
            _technicalLine('Format', _track.format),
            _technicalLine('Duration', _format(_track.duration)),
            _technicalLine(
              'Bitrate',
              _track.bitrateKbps == null ? '—' : '${_track.bitrateKbps} kbps',
            ),
            _technicalLine(
              'Sample rate',
              _track.sampleRate == null
                  ? '—'
                  : '${(_track.sampleRate! / 1000).toStringAsFixed(1)} kHz',
            ),
            _technicalLine('File size', _size(_track.fileSize)),
          ],
        ),
      ],
    ),
  );

  Widget _heroArtwork() {
    final path = _track.artworkPath;
    Widget image;
    if (_track.providerArtworkUrl != null && _track.customArtworkPath == null) {
      image = Image.network(
        _track.providerArtworkUrl!,
        fit: BoxFit.cover,
        cacheWidth: 1100,
        errorBuilder: (_, _, _) => _fallback(),
      );
    } else if (path != null) {
      image = Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 1100,
        errorBuilder: (_, _, _) => _fallback(),
      );
    } else if (_track.artwork != null) {
      image = Image.memory(
        _track.artwork!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(),
      );
    } else {
      image = _fallback();
    }
    final ratio = _track.artworkAspectRatio?.clamp(.5625, 1.5) ?? 1.0;
    return Center(
      child: SizedBox(
        width: 300,
        child: AspectRatio(
          aspectRatio: ratio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                Align(
                  alignment: Alignment.bottomCenter,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .75),
                        ],
                      ),
                    ),
                    child: SizedBox(
                      height: 70,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _track.format,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(width: 9),
                          Text(
                            _track.bitrate == null
                                ? _format(_track.duration)
                                : '${_track.bitrateKbps} kbps  ·  ${_track.sampleRate == null ? '—' : '${(_track.sampleRate! / 1000).toStringAsFixed(1)} kHz'}',
                            style: const TextStyle(color: BitwaveColors.paper),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback() => ColoredBox(
    color: BitwaveColors.elevated,
    child: Center(
      child: Icon(
        Icons.graphic_eq_rounded,
        size: 60,
        color: BitwaveColors.accent.withValues(alpha: .8),
      ),
    ),
  );

  Widget _artistSummary() => _panel(
    children: [
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(25),
          child: SizedBox(
            width: 48,
            height: 48,
            child: _track.providerArtworkUrl != null
                ? Image.network(_track.providerArtworkUrl!, fit: BoxFit.cover)
                : _track.artworkPath == null
                ? _fallback()
                : Image.file(File(_track.artworkPath!), fit: BoxFit.cover),
          ),
        ),
        title: Text(
          _track.albumArtist.isEmpty
              ? _track.displayArtist
              : _track.albumArtist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${_track.album.isEmpty ? 'Album unavailable' : _track.album}  ·  ${_track.year ?? 'Year unknown'}',
          style: const TextStyle(color: BitwaveColors.muted),
        ),
        trailing: const Icon(Icons.chevron_right, color: BitwaveColors.muted),
      ),
    ],
  );

  Widget _tagField(String label, TextEditingController controller) => InkWell(
    onTap: () => _editField(label, controller),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      child: Row(
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(color: BitwaveColors.muted, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              controller.text.isEmpty ? '—' : controller.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.edit_outlined, size: 16, color: BitwaveColors.muted),
        ],
      ),
    ),
  );

  Widget _artworkField() => InkWell(
    onTap: _editArtwork,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(15, 10, 15, 12),
      child: Row(
        children: [
          const SizedBox(
            width: 105,
            child: Text(
              'Artwork',
              style: TextStyle(color: BitwaveColors.muted, fontSize: 13),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 48,
              height: 48,
              child: _track.providerArtworkUrl != null
                  ? Image.network(_track.providerArtworkUrl!, fit: BoxFit.cover)
                  : _track.artworkPath == null
                  ? _fallback()
                  : Image.file(File(_track.artworkPath!), fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Edit Artwork', style: TextStyle(fontSize: 14)),
          ),
          const Icon(Icons.chevron_right_rounded, color: BitwaveColors.muted),
        ],
      ),
    ),
  );

  Widget _technicalLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: BitwaveColors.muted, fontSize: 13),
          ),
        ),
        Text(value, style: const TextStyle(fontSize: 13)),
      ],
    ),
  );
  Widget _panel({required List<Widget> children}) => DecoratedBox(
    decoration: BoxDecoration(
      color: BitwaveColors.panel,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );

  Future<void> _editField(
    String label,
    TextEditingController controller,
  ) async {
    final temp = TextEditingController(text: controller.text);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: temp,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          keyboardType: label == 'Year'
              ? TextInputType.number
              : TextInputType.text,
          decoration: InputDecoration(hintText: 'Enter $label'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, temp.text),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    temp.dispose();
    if (value != null) setState(() => controller.text = value);
  }

  Widget _appleMatches() => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    itemCount: _matches.length,
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: .68,
    ),
    itemBuilder: (context, index) {
      final match = _matches[index];
      return InkWell(
        onTap: () => _chooseAppleMatch(match),
        borderRadius: BorderRadius.circular(13),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: BitwaveColors.panel,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          match.artworkAt(400, 400),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _fallback(),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  match.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  match.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: BitwaveColors.muted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${match.type == 'albums' ? 'Album' : 'Track'}${match.year == null ? '' : '  ·  ${match.year}'}',
                  style: const TextStyle(
                    color: BitwaveColors.muted,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Select artwork',
                  style: TextStyle(
                    color: BitwaveColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _lyricsMatchList() => DecoratedBox(
    decoration: BoxDecoration(
      color: BitwaveColors.panel,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        for (final match in _lyricsMatches)
          ListTile(
            title: Text(
              match.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${match.artist} · ${match.album.isEmpty ? 'Album unknown' : match.album} · '
              '${match.syncedLyrics?.trim().isNotEmpty == true ? 'Synced' : 'Plain'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.download_outlined),
            onTap: () => _chooseLyrics(match),
          ),
      ],
    ),
  );

  static String _format(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';
}

class AppleMusicArtworkSettingsPage extends StatefulWidget {
  const AppleMusicArtworkSettingsPage({super.key, required this.database});
  final LibraryDatabase database;

  @override
  State<AppleMusicArtworkSettingsPage> createState() =>
      _AppleMusicArtworkSettingsPageState();
}

class _AppleMusicArtworkSettingsPageState
    extends State<AppleMusicArtworkSettingsPage> {
  static const _storage = FlutterSecureStorage();
  final _token = TextEditingController();
  final _storefront = TextEditingController(text: 'us');
  bool _loading = true;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _token.dispose();
    _storefront.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _token.text = await _storage.read(key: 'apple_music_developer_token') ?? '';
    _storefront.text =
        await widget.database.getSetting('apple_music_storefront') ?? 'us';
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final token = _token.text.trim();
    final storefront = _storefront.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2}$').hasMatch(storefront)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a two-letter storefront country code.'),
        ),
      );
      return;
    }
    if (token.isEmpty) {
      await _storage.delete(key: 'apple_music_developer_token');
    } else {
      await _storage.write(key: 'apple_music_developer_token', value: token);
    }
    await widget.database.setSetting('apple_music_storefront', storefront);
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Artwork provider settings saved.')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Apple Music artwork', style: TextStyle(fontSize: 17)),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(22),
            children: [
              const Icon(
                Icons.music_note_rounded,
                size: 42,
                color: BitwaveColors.accent,
              ),
              const SizedBox(height: 14),
              const Text(
                'Connect the public catalog',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Catalog search requires a signed Apple Music developer token from an Apple Developer Program account. A listener subscription and music-user token are not required for catalog search. Bitwave stores the selected artwork URL, not a downloaded image; offline listening falls back to the embedded or custom local cover.',
                style: TextStyle(color: BitwaveColors.muted, height: 1.5),
              ),
              const SizedBox(height: 23),
              TextField(
                controller: _token,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Developer token',
                  hintText: 'Paste a current signed JWT',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _storefront,
                maxLength: 2,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Storefront',
                  helperText: 'Two-letter country code, for example US',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _save,
                child: Text(_saved ? 'Saved' : 'Save provider settings'),
              ),
              const SizedBox(height: 15),
              const Text(
                'Apple Music search is user initiated. Every result is shown for manual selection; Bitwave never replaces artwork based only on a title match. API rate limits are surfaced without retry loops. Catalog artwork is shown with its associated track in the player, and its URL is requested from Apple only while online.',
                style: TextStyle(
                  color: BitwaveColors.muted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
  );
}
