// DIVERGENCE (Karmashala): pins that a line forgets what a narrower grid hid
// (KARMASHALA.md, divergence 9), and the reflow that rests on it: a resize
// must leave the scrollback as the logical lines wrapped at the new width, with nothing to the right of them and no row twice. The
// byte streams here are shaped like a coding-agent TUI's: it answers every
// SIGWINCH by moving up over its live region, erasing it and painting it again.
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
      out.add(line.substring(at, end).trimRight());
    }
  }
  return out;
}

/// Distinct text per line, so a fragment in the wrong row names its origin.
String logicalLine(int index, int length) {
  final seed = 'line$index:';
  final buffer = StringBuffer(seed);
  var n = 0;
  while (buffer.length < length) {
    buffer.write(String.fromCharCode(0x61 + (index + n++) % 26));
  }
  return buffer.toString().substring(0, length);
}

void main() {
  group('stale cells', () {
    test('a row repainted while narrow shows nothing old when widened', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(100, 10);
      final long = 'A pass over the other states: devices connected, emulator '
          'starting, errors, and Wi-Fi pairing.';
      expect(long.length, greaterThan(60));
      terminal.write('$long\r\n');

      terminal.resize(60, 10);
      // The TUI's answer to SIGWINCH: up over its region, erase, repaint. The
      // row it repaints is the one that held the long line's second half.
      terminal.write('\x1b[1A\r\x1b[J');
      terminal.write("What's wrong in your screenshot:\r\n");
      // Scroll the repainted row into the scrollback.
      terminal.write('\r\n' * 20);

      terminal.resize(100, 10);
      expect(rows(terminal), [
        long.substring(0, 60),
        "What's wrong in your screenshot:",
      ]);
    });

    test('erase-in-line at a narrow width leaves no tail to widen into', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 5);
      terminal.write('${'x' * 70}TAIL-TAIL\r\n');
      terminal.resize(40, 5);
      // Narrowing wrapped the line over two rows and scrolled the first out;
      // the second, holding the tail, is now the top of the screen.
      terminal.write('\x1b[H\x1b[2Kshort');
      terminal.write('\x1b[5;1H${'\r\n' * 10}');
      terminal.resize(80, 5);
      expect(rows(terminal), ['x' * 40, 'short']);
    });

    test('the alternate screen hides what it held before it narrowed', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(80, 5);
      terminal.write('\x1b[?1049h${'y' * 70}RIGHT-EDGE');
      terminal.resize(40, 5);
      terminal.write('\x1b[H\x1b[2Kleft');
      terminal.resize(80, 5);
      expect(terminal.altBuffer.lines[0].toString().trimRight(), 'left');
    });

    test('a line handed back by resize holds blanks past its old length', () {
      final line = BufferLine(80);
      for (var i = 0; i < 80; i++) {
        line.setCell(i, 0x41 + i % 26, 1, CursorStyle.empty);
      }
      line.resize(30);
      line.resize(80);
      expect(line.getTrimmedLength(), 30);
      expect(line.toString().trimRight(), hasLength(30));
    });
  });

  group('scrollback reflow', () {
    final logical = [
      for (var i = 0; i < 40; i++) logicalLine(i, i.isEven ? 30 + i * 5 : 12),
    ];

    Terminal filled(int width) {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(width, 8);
      for (final line in logical) {
        terminal.write('$line\r\n');
      }
      return terminal;
    }

    test('narrowing re-wraps every scrollback line', () {
      final terminal = filled(120);
      terminal.resize(47, 8);
      expect(rows(terminal), wrapped(logical, 47));
    });

    test('widening merges the continuation rows back', () {
      final terminal = filled(40);
      terminal.resize(133, 8);
      expect(rows(terminal), wrapped(logical, 133));
    });

    test('narrowing then widening gives back the original rows', () {
      final terminal = filled(120);
      final before = rows(terminal);
      terminal.resize(33, 8);
      terminal.resize(120, 8);
      expect(rows(terminal), before);
    });

    test('a drag through many widths ends as one resize would', () {
      final terminal = filled(120);
      for (final width in [119, 110, 97, 80, 61, 44, 30, 31, 45, 70, 99, 140]) {
        terminal.resize(width, 8);
      }
      expect(rows(terminal), wrapped(logical, 140));
      for (final width in [139, 90, 52, 20, 9, 20, 64, 101]) {
        terminal.resize(width, 8);
      }
      expect(rows(terminal), wrapped(logical, 101));
    });

    test('a drag with the TUI repainting at each width leaves no debris', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(120, 8);
      final history = [for (var i = 0; i < 12; i++) logicalLine(i, 100)];
      for (final line in history) {
        terminal.write('$line\r\n');
      }
      // The live region: three rows, the last right-aligned like a status row.
      void paint(int width) {
        terminal.write('\x1b[J');
        terminal.write('${'-' * width}\r\n');
        terminal.write('> prompt at $width\r\n');
        final status = 'tokens@$width';
        terminal.write('${' ' * (width - status.length)}$status');
        terminal.write('\r\x1b[2A');
      }

      paint(120);
      final said = <String>[];
      for (final width in [100, 80, 60, 50, 70, 90, 110, 130]) {
        terminal.resize(width, 8);
        // Erase the region, say something over where it was, paint it below:
        // the rows a wider status row sat in now hold transcript, and scroll.
        terminal.write('\x1b[J');
        for (var i = 0; i < 4; i++) {
          said.add('said at $width #$i');
          terminal.write('${said.last}\r\n');
        }
        paint(width);
      }
      // What the TUI leaves behind when it exits: its region erased.
      terminal.write('\x1b[J');

      final got = rows(terminal);
      for (final row in got) {
        final clean = !row.contains('tokens@') &&
            (!row.contains('said at') || said.contains(row));
        expect(clean, isTrue, reason: 'debris beside other text: "$row"');
      }
      // The history above the live region is exactly re-wrapped.
      final expected = wrapped(history, 130);
      expect(got.take(expected.length).toList(), expected);
    });
  });

  group('wide characters at the wrap column', () {
    test('a wide cell that straddles the new width moves down whole', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(20, 6);
      terminal.write('abcdefghi\u{1F600}jkl\r\n');
      terminal.resize(10, 6);
      expect(rows(terminal), ['abcdefghi', '\u{1F600}jkl']);
      terminal.resize(20, 6);
      expect(rows(terminal), ['abcdefghi\u{1F600}jkl']);
    });

    test('CJK text survives a narrow and widen round trip', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.resize(30, 6);
      const text = 'ab床前明月光疑是地上霜cd举头望明月';
      terminal.write('$text\r\n');
      final before = rows(terminal);
      for (final width in [29, 17, 9, 5, 3, 8, 21, 30]) {
        terminal.resize(width, 6);
      }
      expect(rows(terminal), before);
    });
  });

  test('reflowing 10,000 rows of 200 columns stays inside its budget', () {
    final terminal = Terminal(maxLines: 10000);
    terminal.resize(200, 50);
    final line = logicalLine(7, 200);
    for (var i = 0; i < 10000; i++) {
      terminal.write('$line\r\n');
    }
    final narrow = Stopwatch()..start();
    terminal.resize(120, 50);
    narrow.stop();
    final widen = Stopwatch()..start();
    terminal.resize(200, 50);
    widen.stop();
    // ignore: avoid_print
    print('reflow 10k x 200: narrow ${narrow.elapsedMilliseconds} ms, '
        'widen ${widen.elapsedMilliseconds} ms');
    expect(narrow.elapsedMilliseconds, lessThan(250));
    expect(widen.elapsedMilliseconds, lessThan(250));
  });
}
