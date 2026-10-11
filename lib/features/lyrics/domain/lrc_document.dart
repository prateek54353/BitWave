class LrcLine {
  const LrcLine(this.at, this.text);

  final Duration at;
  final String text;
}

class LrcDocument {
  const LrcDocument(this.lines);

  final List<LrcLine> lines;

  static final _stamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
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
    final lines = <LrcLine>[];
    for (final raw in source.split(RegExp(r'\r?\n'))) {
      final offsetMatch = _offset.firstMatch(raw);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
        continue;
      }
      if (_metadata.hasMatch(raw)) continue;

      final stamps = _stamp.allMatches(raw).toList(growable: false);
      final text = raw.replaceAll(_stamp, '').trim();
      if (stamps.isEmpty || text.isEmpty) continue;
      for (final stamp in stamps) {
        final minutes = int.tryParse(stamp.group(1) ?? '') ?? 0;
        final seconds = int.tryParse(stamp.group(2) ?? '') ?? 0;
        final fraction = (stamp.group(3) ?? '').padRight(3, '0');
        final milliseconds = int.tryParse(fraction) ?? 0;
        final totalMs =
            minutes * 60000 + seconds * 1000 + milliseconds + offsetMs;
        lines.add(
          LrcLine(Duration(milliseconds: totalMs < 0 ? 0 : totalMs), text),
        );
      }
    }
    lines.sort((a, b) => a.at.compareTo(b.at));
    return LrcDocument(List.unmodifiable(lines));
  }

  String? lineAt(Duration position) {
    if (lines.isEmpty) return null;
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
    return current < 0 ? '' : lines[current].text;
  }
}
