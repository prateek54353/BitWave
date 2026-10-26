import 'package:flutter/material.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../../library/domain/track.dart';
import 'lyrics_share_card.dart';
import '../domain/lrc_document.dart';

/// Compact, wrapping lyric preview with a full scrollable, tap-to-seek view.
class WordSyncedLyrics extends StatefulWidget {
  const WordSyncedLyrics({
    super.key,
    required this.lyrics,
    required this.positionStream,
    required this.onSeek,
    required this.track,
    this.lyricsSharingEnabled = false,
    this.height = 76,
  });

  final String lyrics;
  final Stream<Duration> positionStream;
  final ValueChanged<Duration> onSeek;
  final Track track;
  final bool lyricsSharingEnabled;
  final double height;

  @override
  State<WordSyncedLyrics> createState() => _WordSyncedLyricsState();
}

class _WordSyncedLyricsState extends State<WordSyncedLyrics> {
  late LrcDocument _document;
  late List<String> _plainLines;

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
      _plainLines = const [];
      return;
    }

    _document = LrcDocument.parse(widget.lyrics);
    _plainLines = widget.lyrics
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
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final index = _document.lineIndexAt(position);
        final current = index >= 0 ? _document.lines[index] : null;
        final next = index + 1 >= 0 && index + 1 < _document.lines.length
            ? _document.lines[index + 1]
            : null;
        final preview = current?.text ??
            (_plainLines.isNotEmpty ? _plainLines.first : '');

        return SizedBox(
          height: widget.height,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _openLyrics(position),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (current != null && current.hasWordTiming)
                            _buildWordText(current, position, maxLines: 2)
                          else
                            Text(
                              preview,
                              maxLines: 2,
                              softWrap: true,
                              overflow: TextOverflow.fade,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16,
                                height: 1.25,
                                fontWeight: FontWeight.w700,
                                color: BitwaveColors.paper,
                              ),
                            ),
                          if (next != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                next.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: BitwaveColors.muted,
                                  height: 1.2,
                                ),
                              ),
                            )
                          else if (current == null &&
                              _plainLines.length > 1)
                            Text(
                              _plainLines[1],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                color: BitwaveColors.muted,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.lyrics_rounded,
                      color: BitwaveColors.muted,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWordText(
    LrcLine line,
    Duration position, {
    int? maxLines,
  }) {
    final activeIndex = _activeWordIndex(line.words, position);
    final spans = <InlineSpan>[];
    for (var i = 0; i < line.words.length; i++) {
      final active = i == activeIndex;
      final past = activeIndex >= 0 && i < activeIndex;
      spans.add(TextSpan(
        text: line.words[i].text,
        style: TextStyle(
          color: active
              ? BitwaveColors.accent
              : past
                  ? BitwaveColors.paper.withValues(alpha: .72)
                  : BitwaveColors.paper,
          fontSize: active ? 17 : 16,
          fontWeight: active ? FontWeight.w800 : FontWeight.w600,
        ),
      ));
      if (i != line.words.length - 1) spans.add(const TextSpan(text: ' '));
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      softWrap: true,
      overflow: TextOverflow.fade,
      textAlign: TextAlign.center,
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

  Future<void> _openLyrics(Duration position) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: BitwaveColors.panel,
      barrierColor: Colors.black.withValues(alpha: .58),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => _LyricsSheet(
        document: _document,
        plainLines: _plainLines,
        positionStream: widget.positionStream,
        initialPosition: position,
        onSeek: (value) {
          widget.onSeek(value);
        },
        track: widget.track,
        lyricsSharingEnabled: widget.lyricsSharingEnabled,
        lyrics: widget.lyrics,
      ),
    );
  }
}

class _LyricsSheet extends StatefulWidget {
  const _LyricsSheet({
    required this.document,
    required this.plainLines,
    required this.positionStream,
    required this.initialPosition,
    required this.onSeek,
    required this.track,
    required this.lyricsSharingEnabled,
    required this.lyrics,
  });

  final LrcDocument document;
  final List<String> plainLines;
  final Stream<Duration> positionStream;
  final Duration initialPosition;
  final ValueChanged<Duration> onSeek;
  final Track track;
  final bool lyricsSharingEnabled;
  final String lyrics;

  @override
  State<_LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<_LyricsSheet> {
  final ScrollController _scrollController = ScrollController();
  late final List<GlobalKey> _lineKeys;
  int _lastAutoScrolledIndex = -1;

  @override
  void initState() {
    super.initState();
    _lineKeys = List.generate(widget.document.lines.length, (_) => GlobalKey());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasSyncedLyrics = widget.document.lines.isNotEmpty;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .78,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: BitwaveColors.muted.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 18, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LYRICS',
                        style: TextStyle(
                          color: BitwaveColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Follow the words',
                        style: TextStyle(
                          color: BitwaveColors.paper,
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.lyricsSharingEnabled)
                  IconButton(
                    tooltip: 'Share lyrics',
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => LyricsShareCardSheet(
                        track: widget.track,
                        lyrics: widget.lyrics,
                        lyricsSource: 'Local library',
                      ),
                    ),
                    icon: const Icon(Icons.ios_share_rounded,
                        color: BitwaveColors.paper),
                  ),
                if (hasSyncedLyrics)
                  const Row(
                    children: [
                      Icon(Icons.touch_app_rounded,
                          color: BitwaveColors.muted, size: 16),
                      SizedBox(width: 5),
                      Text(
                        'Tap a line to seek',
                        style: TextStyle(
                          color: BitwaveColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const Divider(color: BitwaveColors.line, height: 1),
          Expanded(
            child: hasSyncedLyrics
                ? StreamBuilder<Duration>(
                    stream: widget.positionStream,
                    initialData: widget.initialPosition,
                    builder: (context, snapshot) {
                      final position =
                          snapshot.data ?? widget.initialPosition;
                      final active = widget.document.lineIndexAt(position);
                      _scheduleAutoScroll(active);

                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(22, 22, 22, 42),
                        itemCount: widget.document.lines.length,
                        itemBuilder: (context, index) {
                          final line = widget.document.lines[index];
                          final isActive = index == active;
                          return GestureDetector(
                            key: _lineKeys[index],
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              widget.onSeek(line.at);
                              if (Navigator.of(context).canPop()) {
                                Navigator.of(context).pop();
                              }
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              margin: const EdgeInsets.only(bottom: 15),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? BitwaveColors.elevated
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isActive
                                      ? BitwaveColors.accent
                                          .withValues(alpha: .38)
                                      : Colors.transparent,
                                ),
                              ),
                              child: _lineContent(line, position, isActive),
                            ),
                          );
                        },
                      );
                    },
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(26, 24, 26, 40),
                    children: [
                      for (final line in widget.plainLines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: Text(
                            line,
                            softWrap: true,
                            style: const TextStyle(
                              color: BitwaveColors.paper,
                              fontSize: 17,
                              height: 1.5,
                            ),
                          ),
                        ),
                      if (widget.plainLines.isEmpty)
                        const Center(
                          child: Text(
                            'No readable lyrics available',
                            style: TextStyle(color: BitwaveColors.muted),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _lineContent(LrcLine line, Duration position, bool isActive) {
    if (!line.hasWordTiming) {
      return Text(
        line.text,
        softWrap: true,
        style: TextStyle(
          color: isActive ? BitwaveColors.paper : BitwaveColors.muted,
          fontSize: isActive ? 20 : 18,
          height: 1.45,
          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
        ),
      );
    }

    final activeWord = _activeWordIndex(line.words, position);
    final spans = <InlineSpan>[];
    for (var i = 0; i < line.words.length; i++) {
      final active = isActive && i == activeWord;
      final past = isActive && activeWord >= 0 && i < activeWord;
      spans.add(TextSpan(
        text: line.words[i].text,
        style: TextStyle(
          color: active
              ? BitwaveColors.accent
              : past
                  ? BitwaveColors.paper.withValues(alpha: .70)
                  : isActive
                      ? BitwaveColors.paper
                      : BitwaveColors.muted,
          fontSize: active ? 21 : (isActive ? 20 : 18),
          height: 1.45,
          fontWeight: active ? FontWeight.w800 : FontWeight.w600,
        ),
      ));
      if (i != line.words.length - 1) spans.add(const TextSpan(text: ' '));
    }
    return Text.rich(TextSpan(children: spans), softWrap: true);
  }

  int _activeWordIndex(List<LrcWord> words, Duration position) {
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

  void _scheduleAutoScroll(int activeIndex) {
    if (activeIndex < 0 ||
        activeIndex == _lastAutoScrolledIndex ||
        activeIndex >= _lineKeys.length) {
      return;
    }
    _lastAutoScrolledIndex = activeIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _lineKeys[activeIndex].currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        alignment: .42,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }
}
