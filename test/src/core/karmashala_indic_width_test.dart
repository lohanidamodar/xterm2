import 'package:test/test.dart';
import 'package:xterm2/src/terminal.dart';

/// Claude Code measures text with `string-width`: a grapheme cluster is as wide
/// as its first code point. Devanagari drawn under the default rule came out
/// wider than Claude's model of the screen, so its redraws landed in the wrong
/// columns (2026-09-30, a Karmashala agent pane with Nepali text). The widths
/// below are what `string-width` reports under Bun and Node.
int _cursorAfter(String text, {required bool fromBase}) {
  final t = Terminal()
    ..resize(80, 5)
    ..indicClusterWidthFromBase = fromBase;
  t.write(text);
  return t.buffer.cursorX;
}

void main() {
  const claudeWidths = {
    'का': 1,
    'की': 1,
    'क्ष': 1,
    'नमस्ते': 3,
    'मेरो नेपाली': 6,
    'दशैं': 2,
    'त्यो': 1,
    'ज्ञान': 2,
    'श्री': 1,
    'प्रश्न': 2,
    'abc': 3,
    'é': 1,
  };

  group('indicClusterWidthFromBase', () {
    for (final entry in claudeWidths.entries) {
      test('${entry.key} is ${entry.value} cells, as string-width counts', () {
        expect(_cursorAfter(entry.key, fromBase: true), entry.value);
      });
    }

    test('off by default, an Indic cluster still widens to two cells', () {
      expect(Terminal().indicClusterWidthFromBase, isFalse);
      expect(_cursorAfter('का', fromBase: false), 2);
    });

    test('the text is kept whole, only its width changes', () {
      final t = Terminal()
        ..resize(80, 5)
        ..indicClusterWidthFromBase = true;
      t.write('मेरो नेपाली|');
      expect(t.buffer.lines[0].getText().trimRight(), 'मेरो नेपाली|');
    });
  });
}
