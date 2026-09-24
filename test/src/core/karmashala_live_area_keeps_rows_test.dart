import 'package:test/test.dart';
import 'package:xterm2/src/terminal.dart';

/// An inline TUI (Claude Code) draws its live region below its parked cursor as
/// rows exactly as wide as the screen — rules, an input box — and after a
/// resize redraws it relatively, erasing as many rows as it drew. Reflowing
/// those rows wraps a full-width rule onto a second row when the screen
/// narrows, so the erase falls one row short per rule and the overflow stays on
/// screen (2026-09-24, a Karmashala agent pane: `────` under each rule).
const _rows = 5;

String _region(int width, String tag) => [
      '─' * width,
      '❯ $tag',
      '─' * width,
      '  status $tag',
      '  hint $tag',
    ].join('\r\n');

String _redraw(int width, String tag) => '\x1b[${_rows - 1}B'
    '${'\x1b[2K\x1b[1A' * (_rows - 1)}\x1b[2K\r'
    '${_region(width, tag)}'
    '\x1b[${_rows - 1}A\r';

List<String> _all(Terminal t) => [
      for (var i = 0; i < t.buffer.lines.length; i++)
        t.buffer.lines[i].getText().trimRight(),
    ];

void main() {
  Terminal drawn(int width) {
    final t = Terminal(maxLines: 1000)..resize(width, 20);
    // History that soft-wraps at the narrow width, so it must still reflow.
    for (var i = 0; i < 10; i++) {
      t.write('history $i ${'x' * 70}\r\n');
    }
    t.write('${_region(width, 'v1')}\x1b[${_rows - 1}A\r');
    return t;
  }

  void expectClean(Terminal t, int width, String tag) {
    final lines = _all(t);
    final bottom = lines.sublist(lines.length - t.viewHeight);
    final at = bottom.indexOf('─' * width);
    expect(at, isNot(-1), reason: bottom.join('\n'));
    expect(
      bottom.sublist(at, at + _rows),
      _region(width, tag).split('\r\n'),
      reason: bottom.join('\n'),
    );
    expect(
      bottom.sublist(at + _rows).where((l) => l.isNotEmpty),
      isEmpty,
      reason: 'debris below the region:\n${bottom.join('\n')}',
    );
    expect(
      lines.where((l) => l.startsWith('─') && l.length != width),
      isEmpty,
      reason: 'a rule of the old width survived:\n${lines.join('\n')}',
    );
    for (var i = 0; i < 10; i++) {
      expect(lines.any((l) => l.startsWith('history $i ')), isTrue);
    }
  }

  test('narrowing keeps the live region to the rows it was drawn in', () {
    final t = drawn(80)..resize(60, 20);
    t.write(_redraw(60, 'v2'));
    expectClean(t, 60, 'v2');
  });

  test('widening leaves no piece of the narrower frame behind', () {
    final t = drawn(60)..resize(80, 20);
    t.write(_redraw(80, 'v2'));
    expectClean(t, 80, 'v2');
  });

  test('history above the cursor still reflows', () {
    final t = drawn(80)..resize(40, 20);
    final lines = _all(t);
    final first = lines.indexWhere((l) => l.startsWith('history 0 '));
    expect(t.buffer.lines[first + 1].isWrapped, isTrue);
    t.resize(80, 20);
    expect(_all(t), contains('history 0 ${'x' * 70}'));
  });

  // Claude Code's renderer keeps a model of its screen and writes only what
  // changed; after a resize that ends where it began it writes nothing at all
  // (a host recording, 2026-09-24: 124 → 93 → 61 → 124 columns, then only
  // keyboard-mode resets). So the live rows must come back as they were, the
  // way reflow brings a native terminal's back.
  List<String> screen(Terminal t) => _all(t).sublist(_all(t).length - 20);

  test('a round trip with no redraw brings the live rows back exactly', () {
    final t = drawn(80);
    final before = screen(t);
    t
      ..resize(40, 20)
      ..resize(80, 20);
    expect(screen(t), before);
  });

  test('so does one through several widths, narrowing and widening', () {
    final t = drawn(80);
    final before = screen(t);
    for (final width in [70, 40, 55, 30, 80]) {
      t.resize(width, 20);
    }
    expect(screen(t), before);
  });

  test('a row redrawn while narrow does not get its old cells back', () {
    final t = drawn(80)..resize(40, 20);
    // The region's top row, repainted at the narrow width.
    t.write('\x1b[2K${'═' * 40}\r');
    t.resize(80, 20);
    final lines = _all(t);
    final top = lines[lines.length - 20 + t.buffer.cursorY];
    expect(top, '═' * 40, reason: 'no ─ from the old frame beside it');
  });
}
