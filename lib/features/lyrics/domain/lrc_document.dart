class LrcWord {
  const LrcWord({required this.at, required this.text});

  /// Audio position at which this word begins.
  final Duration at;
  final String text;
}

class LrcLine {
  const LrcLine(this.at, this.text, {this.words = const []});

  final Duration at;
  final String text;
  final List<LrcWord> words;

  bool get hasWordTiming => words.isNotEmpty;
}

class LrcDocument {
  const LrcDocument(this.lines);

  final List<LrcLine> lines;

  static final _lineStamp =
      RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  static final _wordStamp =
      RegExp(r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>');
  static final _offset = RegExp(
    r'^\s*\[offset:([+-]?\d+)\]\s*$',
    caseSensitive: false,
  );
  static final _metadata = RegExp(
    r'^\s*\[(?:ar|ti|al|by|re|ve|length|la|tool|kana|au|id):',
    caseSensitive: false,
  );

  factory LrcDocument.parse(String source) {
    var offsetMs = 0;
    final parsed = <LrcLine>[];

    for (final raw in source.split(RegExp(r'\r?\n'))) {
      final offsetMatch = _offset.firstMatch(raw);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
        continue;
      }
      if (_metadata.hasMatch(raw) || raw.trim().isEmpty) continue;

      final lineStamps = _lineStamp.allMatches(raw).toList(growable: false);
      final wordStamps = _wordStamp.allMatches(raw).toList(growable: false);

      if (wordStamps.isNotEmpty) {
        final words = <LrcWord>[];
        for (var i = 0; i < wordStamps.length; i++) {
          final stamp = wordStamps[i];
          final segmentStart = stamp.end;
          final segmentEnd =
              i + 1 < wordStamps.length ? wordStamps[i + 1].start : raw.length;
          final wordText = raw.substring(segmentStart, segmentEnd);
          final cleaned = wordText.replaceAll(_lineStamp, '').trim();
          if (cleaned.isEmpty) continue;

          words.add(LrcWord(at: _parseStamp(stamp, offsetMs), text: cleaned));
        }

        if (words.isNotEmpty) {
          final lineAt = lineStamps.isNotEmpty
              ? _parseStamp(lineStamps.first, offsetMs)
              : words.first.at;
          parsed.add(
            LrcLine(
              lineAt,
              words.map((word) => word.text).join(' '),
              words: List.unmodifiable(words),
            ),
          );
        }
        continue;
      }

      if (lineStamps.isEmpty) continue;
      final text = raw.replaceAll(_lineStamp, '').trim();
      if (text.isEmpty) continue;

      for (final stamp in lineStamps) {
        parsed.add(LrcLine(_parseStamp(stamp, offsetMs), text));
      }
    }

    parsed.sort((a, b) => a.at.compareTo(b.at));
    return LrcDocument(List.unmodifiable(parsed));
  }

  static Duration _parseStamp(RegExpMatch stamp, int offsetMs) {
    final minutes = int.tryParse(stamp.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(stamp.group(2) ?? '') ?? 0;
    final fraction = (stamp.group(3) ?? '').padRight(3, '0');
    final milliseconds = int.tryParse(fraction) ?? 0;
    final totalMs = minutes * 60000 + seconds * 1000 + milliseconds + offsetMs;
    return Duration(milliseconds: totalMs < 0 ? 0 : totalMs);
  }

  int lineIndexAt(Duration position) {
    if (lines.isEmpty) return -1;
    var low = 0;
    var high = lines.length - 1;
    var current = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (lines[middle].at <= position) {
        current = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return current;
  }

  String? lineAt(Duration position) {
    final index = lineIndexAt(position);
    return index < 0 ? '' : lines[index].text;
  }
}
