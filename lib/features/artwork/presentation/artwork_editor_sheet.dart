import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../../library/domain/track.dart';
import '../data/artwork_repository.dart';
import '../data/apple_music_motion_provider.dart';
import '../domain/artwork_asset.dart';

class ArtworkEditorSheet extends StatefulWidget {
  const ArtworkEditorSheet({
    super.key,
    required this.tracks,
    required this.repository,
    required this.onSaved,
  });

  final List<Track> tracks;
  final ArtworkRepository repository;
  final Future<void> Function() onSaved;

  @override
  State<ArtworkEditorSheet> createState() => _ArtworkEditorSheetState();
}

class _ArtworkEditorSheetState extends State<ArtworkEditorSheet> {
  static const _ratios = <String, double>{
    '1:1': 1,
    '3:4': .75,
    '4:5': .8,
    '9:16': .5625,
  };

  late ArtworkAsset? _asset;
  late double? _ratio;
  late double _focusX;
  late double _focusY;
  late String _fit;
  bool _saving = false;
  final _motionProvider = AppleMusicMotionProvider();

  @override
  void initState() {
    super.initState();
    final track = widget.tracks.first;
    _asset = track.customArtworkPath == null
        ? null
        : ArtworkAsset(
            path: track.customArtworkPath!,
            aspectRatio: track.artworkAspectRatio ?? 1,
            animated: track.animatedArtwork,
            posterPath: track.artworkPosterPath,
          );
    _ratio = track.artworkAspectRatio;
    _focusX = track.artworkFocusX;
    _focusY = track.artworkFocusY;
    _fit = track.artworkFit;
  }

  double get _previewRatio => _ratio ?? _asset?.aspectRatio ?? 1;
  String? get _previewPath => _asset?.animated == true
      ? _asset?.posterPath
      : _asset?.path ?? widget.tracks.first.artworkPath;

  Future<void> _pick({required bool motion}) async {
    try {
      final asset = motion
          ? await widget.repository.importMotionArtwork()
          : await widget.repository.importStillImage();
      if (asset == null || !mounted) return;
      setState(() {
        _asset = asset;
        _ratio = asset.aspectRatio;
        _focusX = 0;
        _focusY = 0;
      });
    } catch (error) {
      if (mounted) _message(error.toString());
    }
  }

  Future<void> _save() async {
    final asset = _asset;
    if (asset == null) {
      _message('Choose artwork first.');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.repository.assign(
        tracks: widget.tracks,
        asset: asset,
        cropRatio: _ratio,
        focusX: _focusX,
        focusY: _focusY,
        fit: _fit,
      );
      await widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) _message('Artwork could not be saved: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    await widget.repository.reset(widget.tracks);
    await widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _findMotionArtwork() async {
    final track = widget.tracks.first;
    if (track.artist.trim().isEmpty || track.album.trim().isEmpty) {
      _message(
        'Add artist and album tags before searching for motion artwork.',
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final match = await _motionProvider.search(
        artist: track.albumArtist.trim().isEmpty
            ? track.artist
            : track.albumArtist,
        album: track.album,
        title: track.title,
      );
      if (!mounted) return;
      if (match == null) {
        _message('No animated Apple Music artwork was found for this album.');
        return;
      }
      final options = <(String, String, double)>[
        if (match.squareUrl != null)
          ('Square motion cover', match.squareUrl!, 1),
        if (match.tallUrl != null) ('Tall motion cover', match.tallUrl!, .5625),
      ];
      final selected = await showDialog<(String, String, double)>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Review motion artwork match'),
          content: Text(
            '${match.artist} · ${match.album}\n\n'
            'This community service streams the selected motion cover while online. '
            'The current local artwork remains its static fallback.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ...options.map(
              (option) => TextButton(
                onPressed: () => Navigator.pop(context, option),
                child: Text('Use ${option.$1.toLowerCase()}'),
              ),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      await widget.repository.assignMotionArtworkUrl(
        widget.tracks,
        selected.$2,
        aspectRatio: selected.$3,
      );
      await widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) _message('Motion artwork search failed: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  void dispose() {
    _motionProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAlbum = widget.tracks.length > 1;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          22,
          12,
          22,
          18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: BitwaveColors.muted.withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 19),
              Text(
                'Edit ${isAlbum ? 'album' : 'track'} artwork',
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isAlbum
                    ? widget.tracks.first.displayAlbum
                    : widget.tracks.first.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BitwaveColors.muted),
              ),
              const SizedBox(height: 17),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : () => _pick(motion: false),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Choose image'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : () => _pick(motion: true),
                      icon: const Icon(Icons.motion_photos_on_outlined),
                      label: const Text('Motion cover'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : _findMotionArtwork,
                icon: const Icon(Icons.auto_awesome_motion_outlined),
                label: const Text('Find Apple Music motion cover'),
              ),
              const SizedBox(height: 18),
              Center(
                child: GestureDetector(
                  onPanUpdate: _fit == 'crop'
                      ? (event) => setState(() {
                          _focusX = (_focusX + event.delta.dx / 150).clamp(
                            -1,
                            1,
                          );
                          _focusY = (_focusY + event.delta.dy / 150).clamp(
                            -1,
                            1,
                          );
                        })
                      : null,
                  child: AspectRatio(
                    aspectRatio: _previewRatio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: ColoredBox(
                        color: BitwaveColors.elevated,
                        child: _previewPath == null
                            ? const Center(
                                child: Icon(
                                  Icons.image_outlined,
                                  size: 54,
                                  color: BitwaveColors.accent,
                                ),
                              )
                            : Image.file(
                                File(_previewPath!),
                                fit: _fit == 'fit'
                                    ? BoxFit.contain
                                    : BoxFit.cover,
                                alignment: Alignment(_focusX, _focusY),
                                cacheWidth: 1400,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    size: 46,
                                    color: BitwaveColors.muted,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  _fit == 'crop'
                      ? 'Drag the image to reposition the crop'
                      : _fit == 'fit'
                      ? 'Fit keeps the full image visible'
                      : 'Fill crops from the center',
                  style: TextStyle(color: BitwaveColors.muted, fontSize: 12),
                ),
              ),
              const SizedBox(height: 17),
              const Text(
                'CROP RATIO',
                style: TextStyle(
                  color: BitwaveColors.accent,
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ..._ratios.entries.map(
                    (entry) => ChoiceChip(
                      label: Text(entry.key),
                      selected: _ratio == entry.value,
                      onSelected: (_) => setState(() => _ratio = entry.value),
                    ),
                  ),
                  ChoiceChip(
                    label: const Text('Original'),
                    selected: _ratio == null,
                    onSelected: (_) => setState(() => _ratio = null),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              const Text(
                'DISPLAY',
                style: TextStyle(
                  color: BitwaveColors.accent,
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'fit', label: Text('Fit')),
                  ButtonSegment(value: 'fill', label: Text('Fill')),
                  ButtonSegment(value: 'crop', label: Text('Crop')),
                ],
                selected: {_fit},
                onSelectionChanged: (values) => setState(() {
                  _fit = values.first;
                  if (_fit == 'fill') {
                    _focusX = 0;
                    _focusY = 0;
                  }
                }),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (widget.tracks.any(
                    (track) =>
                        track.customArtworkPath != null ||
                        track.providerArtworkUrl != null,
                  ))
                    TextButton(
                      onPressed: _saving ? null : _reset,
                      child: const Text('Reset to embedded'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 7),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save artwork'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
