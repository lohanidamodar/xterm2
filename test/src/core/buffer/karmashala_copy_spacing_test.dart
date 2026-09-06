import 'package:test/test.dart';
import 'package:xterm2/core.dart';

/// DIVERGENCE (Karmashala): pins that a blank cell copies as a space.
///
/// A CLI that lays text out by moving the cursor — `CUF`, `CHA`, a tab stop —
/// leaves the cells it skipped at code point 0. Upstream's `getText` wrote
/// nothing for those, so copied output came back with every gap deleted and
/// its words run together, while text written with literal spaces copied
/// intact. The mixed result is the whole symptom.
void main() {
  group('BufferLine.getText() blank cells', () {
    test('restores gaps a cursor-forward layout left behind', () {
      final terminal = Terminal()..resize(40, 3);

      terminal.write('Crash\x1b[Cand\x1b[Canalytics\x1b[Cvendors.');

      expect(
        terminal.buffer.lines[0].getText(),
        'Crash and analytics vendors.',
      );
    });

    test('restores gaps an absolute column jump left behind', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('abc\x1b[10Gdef');

      expect(terminal.buffer.lines[0].getText(), 'abc      def');
    });

    test('keeps indentation a cursor jump wrote no spaces for', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('\x1b[5Gindented');

      expect(terminal.buffer.lines[0].getText(), '    indented');
    });

    test('drops the empty tail rather than padding to the line width', () {
      final terminal = Terminal()..resize(200, 3);

      terminal.write('hi');

      expect(terminal.buffer.lines[0].getText(), 'hi');
      expect(terminal.buffer.lines[0].getText(0, 200), 'hi');
    });

    test('drops the empty tail of a requested range too', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('ab\x1b[10Gcd');

      expect(terminal.buffer.lines[0].getText(0, 20), 'ab       cd');
      expect(terminal.buffer.lines[0].getText(0, 6), 'ab');
    });

    test('reports an all-blank line as empty', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('abc\r\x1b[K');

      expect(terminal.buffer.lines[0].getText(), '');
    });

    test('leaves the cells a horizontal tab skipped elided', () {
      final terminal = Terminal()..resize(20, 2);

      terminal.write('\tabc');

      // The tab already encodes its own advance. Spelling its cells out as
      // well would paste `abc` at column 15 instead of the 8 it was drawn at.
      expect(terminal.buffer.lines[0].getText(), '\tabc');
    });

    test('spells out a gap a tab could not claim', () {
      final terminal = Terminal()..resize(20, 2);

      // The tab stop is taken, so no HT cell is written and the gap is the
      // cursor move's, not the tab's.
      terminal.write('x\r\tabc');

      expect(terminal.buffer.lines[0].getText(), 'x       abc');
    });
  });

  group('BufferLine.getText() wide characters', () {
    test('does not turn a wide glyph spacer into a space', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('中文abc');

      expect(terminal.buffer.lines[0].getText(), '中文abc');
    });

    test('keeps a real blank between two wide glyphs', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('中\x1b[5G文');

      expect(terminal.buffer.lines[0].getText(), '中  文');
    });

    test('keeps the whole glyph when a range splits its spacer', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('ab中\x1b[8Gcd');

      // `to` lands on the spacer and is widened to include the glyph.
      expect(terminal.buffer.lines[0].getText(0, 3), 'ab中');
      // `from` lands on the spacer and is widened back to the glyph.
      expect(terminal.buffer.lines[0].getText(3, 9), '中   cd');
    });
  });

  group('Buffer.getText() blank cells', () {
    test('joins a wrapped line without injecting its blank tail', () {
      final terminal = Terminal()..resize(10, 4);

      terminal.write('abcdefghijklm');
      // Blank the tail of the first row while the second stays wrapped.
      terminal.write('\x1b[1;9H\x1b[K');

      expect(terminal.buffer.lines[1].isWrapped, isTrue);
      expect(
        terminal.buffer.getText(
          BufferRangeLine(const CellOffset(0, 0), const CellOffset(10, 1)),
        ),
        'abcdefghklm',
      );
    });

    test('keeps a line selection gap and still trims each row', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('one\x1b[8Gtwo\r\nthree\x1b[12Gfour');

      expect(
        terminal.buffer.getText(
          BufferRangeLine(const CellOffset(0, 0), const CellOffset(20, 1)),
          true,
        ),
        'one    two\nthree      four',
      );
    });

    test('keeps a block selection rectangular in its interior', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('ab\x1b[8Gcd\r\nef\x1b[8Ggh');

      expect(
        terminal.buffer.getText(
          BufferRangeBlock(const CellOffset(0, 0), const CellOffset(10, 1)),
        ),
        'ab     cd\nef     gh',
      );
    });

    test('trims a block selection row whose tail is blank', () {
      final terminal = Terminal()..resize(20, 3);

      terminal.write('abc\r\nde');

      expect(
        terminal.buffer.getText(
          BufferRangeBlock(const CellOffset(0, 0), const CellOffset(6, 1)),
        ),
        'abc\nde',
      );
    });
  });
}
