import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../../library/domain/track.dart';
import '../domain/lrc_document.dart';

enum CardAspectRatio { square, portrait }

enum CardBackground { gradient, dark, warm }

/// A render-only card. The share action lives in the sheet so it is not
/// accidentally included in the exported image.
class LyricsShareCard extends StatelessWidget {
  const LyricsShareCard({
    super.key,
    required this.track,
    required this.selectedLines,
    this.aspectRatio = CardAspectRatio.square,
    this.background = CardBackground.gradient,
  });

  final Track track;
  final List<String> selectedLines;
  final CardAspectRatio aspectRatio;
  final CardBackground background;

  @override
  Widget build(BuildContext context) {
    final width = aspectRatio == CardAspectRatio.square ? 420.0 : 360.0;
    final height = aspectRatio == CardAspectRatio.square ? 420.0 : 640.0;

    return RepaintBoundary(
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: _gradient,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: EdgeInsets.all(aspectRatio == CardAspectRatio.square ? 28 : 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.graphic_eq_rounded,
                          color: Color(0xFF101010), size: 17),
                    ),
                    const SizedBox(width: 9),
                    const Text(
                      'BITWAVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.2,
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.format_quote_rounded,
                        color: Colors.white70, size: 27),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < selectedLines.length; i++)
                            Padding(
                              padding: EdgeInsets.only(
                                  bottom: i == selectedLines.length - 1 ? 0 : 12),
                              child: Text(
                                selectedLines[i],
                                softWrap: true,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: _lyricFontSize,
                                  height: 1.16,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    _artwork(),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            track.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              height: 1.15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            track.displayArtist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double get _lyricFontSize {
    if (selectedLines.length >= 4) return 23;
    if (selectedLines.length == 3) return 27;
    return aspectRatio == CardAspectRatio.square ? 31 : 34;
  }

  LinearGradient get _gradient => switch (background) {
        CardBackground.gradient => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF7356D8), Color(0xFF402A80), Color(0xFF151327)],
          ),
        CardBackground.dark => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF343434), Color(0xFF151515), Color(0xFF080808)],
          ),
        CardBackground.warm => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFB45C3B), Color(0xFF773D4E), Color(0xFF241B34)],
          ),
      };

  Widget _artwork() {
    final path = track.artworkPath;
    if (path != null && path.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackArtwork(),
        ),
      );
    }
    return _fallbackArtwork();
  }

  Widget _fallbackArtwork() => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.music_note_rounded,
            color: Colors.white, size: 26),
      );
}

class LyricsShareCardSheet extends StatefulWidget {
  const LyricsShareCardSheet({
    super.key,
    required this.track,
    required this.lyrics,
    required this.lyricsSource,
  });

  final Track track;
  final String lyrics;
  final String lyricsSource;

  @override
  State<LyricsShareCardSheet> createState() => _LyricsShareCardSheetState();
}

class _LyricsShareCardSheetState extends State<LyricsShareCardSheet> {
  final ScreenshotController _screenshotController = ScreenshotController();
  final Set<int> _selectedIndices = <int>{};
  late final List<_ShareLyricLine> _lines;
  CardAspectRatio _aspectRatio = CardAspectRatio.square;
  CardBackground _background = CardBackground.gradient;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _lines = _parseLines(widget.lyrics);
    // Like Spotify's lyric sharing flow, start with a small ready-to-share
    // selection instead of presenting an empty card.
    if (_lines.isNotEmpty) _selectedIndices.add(0);
    if (_lines.length > 1) _selectedIndices.add(1);
  }

  List<_ShareLyricLine> _parseLines(String source) {
    final document = LrcDocument.parse(source);
    if (document.lines.isNotEmpty) {
      return document.lines
          .map((line) => _ShareLyricLine(line.text.trim(), line.at))
          .where((line) => line.text.isNotEmpty)
          .toList(growable: false);
    }

    return source
        .split(RegExp(r'\\r?\\n'))
        .map((line) => line
            .replaceAll(RegExp(r'\\[\\d{1,3}:\\d{2}(?:[.:]\\d{1,3})?\\]'), '')
            .trim())
        .where((line) =>
            line.isNotEmpty &&
            !RegExp(
              r'^\\s*\\[(?:ar|ti|al|by|re|ve|length|la|tool|kana|au|id|offset):',
              caseSensitive: false,
            ).hasMatch(line))
        .map((line) => _ShareLyricLine(line, null))
        .toList(growable: false);
  }

  List<String> get _selectedLines => _selectedIndices
      .toList()
      ..sort();

  List<String> get _selectedText => _selectedLines
      .map((index) => _lines[index].text)
      .toList(growable: false);

  void _toggleLine(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else if (_selectedIndices.length < 5) {
        _selectedIndices.add(index);
      }
    });
  }

  Future<void> _shareCard() async {
    if (_sharing || _selectedIndices.isEmpty) return;
    setState(() => _sharing = true);

    Directory? tempDir;
    try {
      final image = await _screenshotController.capture(pixelRatio: 3);
      if (image == null) {
        throw StateError('Could not render the lyric card.');
      }

      tempDir = await Directory.systemTemp.createTemp('bitwave_lyrics_');
      final file = File('${tempDir.path}/bitwave_lyrics.png');
      await file.writeAsBytes(image, flush: true);

      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: '“${_selectedText.join(' ')}” — ${widget.track.title} · ${widget.track.displayArtist}\nShared from BitWave',
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Could not share lyric card: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create the lyric card. Try again.')),
        );
      }
    } finally {
      if (tempDir != null) {
        try {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        } catch (_) {
          // The platform share sheet may still be reading the image.
        }
      }
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final cardWidth = _aspectRatio == CardAspectRatio.square ? 420.0 : 360.0;
    final cardHeight = _aspectRatio == CardAspectRatio.square ? 420.0 : 640.0;

    return SafeArea(
      top: false,
      child: Container(
        height: screenHeight * .92,
        decoration: const BoxDecoration(
          color: Color(0xFF101112),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Share lyrics',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800)),
                        SizedBox(height: 4),
                        Text('Choose a line and make it yours',
                            style: TextStyle(
                                color: Colors.white60, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _ratioButton(CardAspectRatio.square, 'Square'),
                  const SizedBox(width: 8),
                  _ratioButton(CardAspectRatio.portrait, 'Story'),
                  const Spacer(),
                  Text('${_selectedIndices.length}/5',
                      style: const TextStyle(
                          color: Colors.white70, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              flex: 5,
              child: Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = [
                      constraints.maxWidth / cardWidth,
                      constraints.maxHeight / cardHeight,
                      1.0,
                    ].reduce((a, b) => a < b ? a : b);
                    return Screenshot(
                      controller: _screenshotController,
                      child: Transform.scale(
                        scale: scale,
                        child: LyricsShareCard(
                          track: widget.track,
                          selectedLines: _selectedText.isEmpty
                              ? const ['Select a lyric below']
                              : _selectedText,
                          aspectRatio: _aspectRatio,
                          background: _background,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 38,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                children: [
                  _backgroundChip(CardBackground.gradient, 'Violet'),
                  _backgroundChip(CardBackground.dark, 'Midnight'),
                  _backgroundChip(CardBackground.warm, 'Warm'),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              flex: 3,
              child: _lines.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          'No shareable lyrics were found for this track.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      itemCount: _lines.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Colors.white10),
                      itemBuilder: (context, index) {
                        final line = _lines[index];
                        final selected = _selectedIndices.contains(index);
                        return ListTile(
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          leading: Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            color: selected
                                ? BitwaveColors.accent
                                : Colors.white38,
                          ),
                          title: Text(
                            line.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? Colors.white : Colors.white70,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                          subtitle: line.at == null
                              ? null
                              : Text(_formatDuration(line.at!),
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11)),
                          onTap: () => _toggleLine(index),
                        );
                      },
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, 12 + MediaQuery.viewInsetsOf(context).bottom),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed:
                      _sharing || _selectedIndices.isEmpty ? null : _shareCard,
                  icon: _sharing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.share_rounded),
                  label: Text(_sharing ? 'Preparing image…' : 'Share lyric card'),
                  style: FilledButton.styleFrom(
                    backgroundColor: BitwaveColors.accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ratioButton(CardAspectRatio ratio, String label) {
    final selected = _aspectRatio == ratio;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _aspectRatio = ratio),
      selectedColor: BitwaveColors.accent.withValues(alpha: .22),
      backgroundColor: Colors.white.withValues(alpha: .06),
      labelStyle: TextStyle(
        color: selected ? BitwaveColors.accent : Colors.white70,
        fontWeight: FontWeight.w700,
      ),
      side: BorderSide(
        color: selected ? BitwaveColors.accent : Colors.white12,
      ),
    );
  }

  Widget _backgroundChip(CardBackground background, String label) {
    final selected = _background == background;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _background = background),
        selectedColor: BitwaveColors.accent.withValues(alpha: .22),
        backgroundColor: Colors.white.withValues(alpha: .06),
        labelStyle: TextStyle(
          color: selected ? BitwaveColors.accent : Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        side: BorderSide(
          color: selected ? BitwaveColors.accent : Colors.white12,
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _ShareLyricLine {
  const _ShareLyricLine(this.text, this.at);

  final String text;
  final Duration? at;
}
