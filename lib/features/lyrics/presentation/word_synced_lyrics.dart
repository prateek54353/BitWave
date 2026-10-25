import 'package:flutter/material.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../domain/lrc_document.dart';

/// Karaoke-style lyric display driven by the audio player's position stream.
class WordSyncedLyrics extends StatefulWidget {
  const WordSyncedLyrics({
    super.key,
    required this.lyrics,
    required this.positionStream,
    this.height = 58,
  });

  final String lyrics;
  final Stream<Duration> positionStream;
  final double height;

  @override
  State<WordSyncedLyrics> createState() => _WordSyncedLyricsState();
}

class _WordSyncedLyricsState extends State<WordSyncedLyrics> {
  late LrcDocument _document;
  late String? _plainPreview;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(covariant WordSyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) _parse();
  }

  void _parse() {
    if (widget.lyrics.startsWith('BITWAVE_SPICY_LYRICS:')) {
      _document = const LrcDocument([]);
      _plainPreview = null;
      return;
    }

    _document = LrcDocument.parse(widget.lyrics);
    final plain = widget.lyrics
        .split(RegExp(r'\r?\n'))
        .where((line) =>
            line.trim().isNotEmpty &&
            !RegExp(
              r'^\s*\[(?:ar|ti|al|by|re|ve|length|la|tool|kana|au|id|offset):',
              caseSensitive: false,
            ).hasMatch(line))
        .map((line) => line
            .replaceAll(RegExp(r'\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]'), '')
            .replaceAll(RegExp(r'<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>'), '')
            .trim())
        .where((line) => line.isNotEmpty)
        .take(2)
        .join('\n');
    _plainPreview = plain.isEmpty ? null : plain;
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: widget.positionStream,
        builder: (context, snapshot) {
          final position = snapshot.data ?? Duration.zero;
          final index = _document.lineIndexAt(position);

          if (_document.lines.isEmpty) {
            final lines = (_plainPreview ?? '').split('\n');
            return _twoLineDisplay(
              lines.isEmpty ? '' : lines.first,
              lines.length > 1 ? lines[1] : '',
            );
          }

          final current = index >= 0 ? _document.lines[index] : null;
          final nextIndex = index + 1;
          final next = nextIndex >= 0 && nextIndex < _document.lines.length
              ? _document.lines[nextIndex]
              : null;

          if (current == null && next == null) {
            return SizedBox(height: widget.height);
          }

          return SizedBox(
            height: widget.height,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (current != null)
                    current.hasWordTiming
                        ? _wordLine(current, position)
                        : Text(
                            current.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -.2,
                            ),
                          ),
                  if (next != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        next.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          color: BitwaveColors.muted,
                          letterSpacing: -.1,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );

  Widget _wordLine(LrcLine line, Duration position) {
    final activeIndex = _activeWordIndex(line.words, position);
    return LayoutBuilder(
      builder: (context, constraints) {
        final spans = <InlineSpan>[];
        for (var i = 0; i < line.words.length; i++) {
          final isActive = i == activeIndex;
          final isPast = activeIndex >= 0 && i < activeIndex;
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 90),
                curve: Curves.easeOut,
                style: TextStyle(
                  fontSize: isActive ? 17 : 16,
                  height: 1.2,
                  fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                  letterSpacing: -.25,
                  color: isActive
                      ? BitwaveColors.accent
                      : isPast
                          ? BitwaveColors.paper.withValues(alpha: .72)
                          : BitwaveColors.paper.withValues(alpha: .92),
                ),
                child: Text(line.words[i].text),
              ),
            ),
          );
          if (i != line.words.length - 1) {
            spans.add(const TextSpan(text: ' '));
          }
        }

        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth),
          child: Text.rich(
            TextSpan(children: spans),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }

  int _activeWordIndex(List<LrcWord> words, Duration position) {
    if (words.isEmpty) return -1;
    var low = 0;
    var high = words.length - 1;
    var active = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (words[middle].at <= position) {
        active = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return active;
  }

  Widget _twoLineDisplay(String current, String next) {
    if (current.isEmpty && next.isEmpty) {
      return SizedBox(height: widget.height);
    }
    return SizedBox(
      height: widget.height,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (current.isNotEmpty)
              Text(
                current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.2,
                ),
              ),
            if (next.isNotEmpty)
              Text(
                next,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: BitwaveColors.muted,
                  letterSpacing: -.1,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
