// DIVERGENCE (Karmashala): pins that erasing part of a row does not cut it off
// the logical line it continues (KARMASHALA.md, divergence 10). The byte
// streams are shaped like Windows ConPTY's answer to a resize, captured from
// the inbox pseudoconsole on 10.0.26200: home the cursor, then every row of its
// buffer as `text ESC[K CR LF`, the long ones left to autowrap.
import 'package:test/test.dart';
import 'package:xterm2/core.dart';

/// Every row of the main buffer, trailing blank rows dropped.
List<String> rows(Terminal terminal) {
  final lines = terminal.mainBuffer.lines;
  final out = <String>[
    for (var i = 0; i < lines.length; i++) lines[i].toString().trimRight(),
  ];
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}

/// [logical] as a terminal [width] columns wide soft-wraps it.
List<String> wrapped(Iterable<String> logical, int width) {
  final out = <String>[];
  for (final line in logical) {
    if (line.isEmpty) {
      out.add('');
      continue;
    }
    for (var at = 0; at < line.length; at += width) {
      final end = at + width < line.length ? at + width : line.length;
      out.add(line.substring(at, end));
    }
  }
  return out;
}

String logicalLine(int index, int length) {
  final buffer = StringBuffer('L$index-');
  var n = 0;
  while (buffer.length < length) {
    buffer.write(String.fromCharCode(0x61 + (index + n++) % 26));
  }
  return buffer.toString().substring(0, length);
}

void main() {
  group('erase in line keeps the row on its logical line', () {
    Terminal wrappedOnce() {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(10, 5);
      // Fifteen cells: row 0 full, row 1 its continuation.
      terminal.write('abcdefghijKLMNO');
      expect(terminal.mainBuffer.lines[1].isWrapped, isTrue);
      return terminal;
    }

    test('EL 0 after text keeps the continuation wrapped', () {
      final terminal = wrappedOnce();
      terminal.write('\x1b[K');
      expect(terminal.mainBuffer.lines[1].isWrapped, isTrue);
    });

    test('EL 0 part-way along the row keeps it wrapped', () {
      final terminal = wrappedOnce();
      terminal.write('\x1b[2;3H\x1b[K');
      expect(rows(terminal), ['abcdefghij', 'KL']);
      expect(terminal.mainBuffer.lines[1].isWrapped, isTrue);
    });

    test('EL 1 keeps the continuation wrapped', () {
      final terminal = wrappedOnce();
      terminal.write('\x1b[2;2H\x1b[1K');
      expect(terminal.mainBuffer.lines[1].isWrapped, isTrue);
    });

    test('EL 0 from the first column empties the row and ends the line', () {
      final terminal = wrappedOnce();
      terminal.write('\x1b[2;1H\x1b[K');
      expect(terminal.mainBuffer.lines[1].isWrapped, isFalse);
    });

    test('EL 2 still ends the line', () {
      final terminal = wrappedOnce();
      terminal.write('\x1b[2K');
      expect(terminal.mainBuffer.lines[1].isWrapped, isFalse);
    });

    test('ED 0 after text keeps the cursor row wrapped, clears those below',
        () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(10, 5);
      terminal.write('x' * 25);
      expect(terminal.mainBuffer.lines[2].isWrapped, isTrue);
      terminal.write('\x1b[2;4H\x1b[J');
      expect(terminal.mainBuffer.lines[1].isWrapped, isTrue);
      expect(terminal.mainBuffer.lines[2].isWrapped, isFalse);
    });

    test('ED 0 from the first column ends the line', () {
      final terminal = wrappedOnce();
      terminal.write('\x1b[2;1H\x1b[J');
      expect(terminal.mainBuffer.lines[1].isWrapped, isFalse);
    });

    test('ED 1 still ends the cursor row', () {
      final terminal = wrappedOnce();
      terminal.write('\x1b[2;3H\x1b[1J');
      expect(terminal.mainBuffer.lines[1].isWrapped, isFalse);
    });
  });

  group('a ConPTY resize repaint', () {
    /// What the pseudoconsole sends after a resize. It keeps only a screen, so
    /// it holds what [terminal] shows: each logical line on it (the first
    /// perhaps begun above it) as `text ESC[K`, joined by CR LF, then the
    /// cursor put back.
    String repaint(Terminal terminal) {
      final lines = terminal.mainBuffer.lines;
      final top = lines.length - terminal.viewHeight;
      final logical = <String>[];
      for (var i = top; i < lines.length; i++) {
        final text = lines[i].toString().trimRight();
        if (i > top && lines[i].isWrapped) {
          logical.last = logical.last.padRight(terminal.viewWidth) + text;
        } else {
          logical.add(text);
        }
      }
      final cursor = '\x1b[${terminal.buffer.cursorY + 1};'
          '${terminal.buffer.cursorX + 1}H';
      return '\x1b[?25l\x1b[H'
          '${logical.map((line) => '$line\x1b[K').join('\r\n')}'
          '$cursor\x1b[?25h';
    }

    final logical = [for (var i = 0; i < 6; i++) logicalLine(i, 143)];

    Terminal filled() {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(100, 10);
      for (final line in logical) {
        terminal.write('$line\r\n');
      }
      return terminal;
    }

    /// Narrows to 40 columns, where each line is four rows, and plays the
    /// pseudoconsole's repaint over the screen.
    Terminal narrowedAndRepainted() {
      final terminal = filled();
      terminal.resize(40, 10);
      final before = rows(terminal);
      expect(before, wrapped(logical, 40));
      final lines = terminal.mainBuffer.lines;
      expect(
        lines[lines.length - terminal.viewHeight].isWrapped,
        isTrue,
        reason: 'the screen opens part-way through a line, as it did live',
      );
      terminal.write(repaint(terminal));
      expect(rows(terminal), before, reason: 'the repaint shows the same text');
      return terminal;
    }

    test('leaves the rows it repainted soft-wrapped', () {
      final terminal = narrowedAndRepainted();
      final lines = terminal.mainBuffer.lines;
      for (var line = 0; line < 6; line++) {
        for (var row = 1; row < 4; row++) {
          expect(
            lines[line * 4 + row].isWrapped,
            isTrue,
            reason: 'row $row of line $line',
          );
        }
      }
    });

    test('narrow, repaint, scroll away, widen: the history reflows', () {
      final terminal = narrowedAndRepainted();
      // Enough output to push every repainted row into the scrollback.
      final after = [for (var i = 0; i < 25; i++) 'after $i'];
      for (final line in after) {
        terminal.write('$line\r\n');
      }

      terminal.resize(100, 10);
      expect(
        rows(terminal).take(wrapped(logical, 100).length + after.length),
        [...wrapped(logical, 100), ...after],
      );
    });

    test('and back to narrow: the history rewraps', () {
      final terminal = narrowedAndRepainted();
      final after = [for (var i = 0; i < 25; i++) 'after $i'];
      for (final line in after) {
        terminal.write('$line\r\n');
      }
      terminal.resize(100, 10);
      terminal.resize(33, 10);
      expect(
        rows(terminal).take(wrapped(logical, 33).length + after.length),
        [...wrapped(logical, 33), ...after],
      );
    });
  });
}
