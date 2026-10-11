import 'package:bitwave/features/lyrics/domain/lrc_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses centiseconds and applies an LRC offset', () {
    final lyrics = LrcDocument.parse(
      '[ti:Example]\n[offset:-100]\n[00:01.20]First line\n[00:02.4]Second line',
    );

    expect(lyrics.lineAt(const Duration(milliseconds: 1099)), isEmpty);
    expect(lyrics.lineAt(const Duration(milliseconds: 1100)), 'First line');
    expect(lyrics.lineAt(const Duration(milliseconds: 2300)), 'Second line');
  });

  test('supports multiple timestamps on one line and sorts timestamps', () {
    final lyrics = LrcDocument.parse(
      '[00:03.00]Later\n[00:01.00][00:02.00]Repeated',
    );

    expect(lyrics.lines.map((line) => line.text), [
      'Repeated',
      'Repeated',
      'Later',
    ]);
    expect(lyrics.lineAt(const Duration(seconds: 2)), 'Repeated');
    expect(lyrics.lineAt(const Duration(seconds: 4)), 'Later');
  });
}
