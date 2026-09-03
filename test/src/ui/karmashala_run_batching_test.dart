// Tests for the Karmashala fork's run-batched foreground painter.
// See KARMASHALA.md.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show TextScaler;
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

const _viewWidth = 80;
const _viewHeight = 24;

TerminalPainter _newPainter() {
  return TerminalPainter(
    theme: TerminalThemes.whiteOnBlack,
    textStyle: const TerminalStyle(fontSize: 14, height: 1),
    textScaler: TextScaler.noScaling,
  );
}

Future<ByteData> _paintViewport(
  Terminal terminal, {
  required bool batched,
  int? activeHyperlinkId,
  bool exhaustBudget = false,
}) async {
  final painter = _newPainter();
  // Force the font probe before overriding what it decided.
  final cellSize = painter.cellSize;
  painter.runBatchingEnabled = batched;
  if (exhaustBudget) {
    // Nothing refills the budget between frames here, so painting one frame
    // with a full budget and then draining it leaves every run on the
    // per-cell fallback path.
    for (var i = 0; i < TerminalPainter.maxRunLayoutsPerFrame; i++) {
      painter.spendRunLayoutBudgetForTesting();
    }
  }

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var y = 0; y < _viewHeight; y++) {
    painter.paintLine(
      canvas,
      ui.Offset(0, y * cellSize.height),
      terminal.buffer.lines[y],
      activeHyperlinkId: activeHyperlinkId,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (cellSize.width * _viewWidth).ceil(),
    (cellSize.height * _viewHeight).ceil(),
  );
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  painter.dispose();
  if (bytes == null) fail('expected viewport bytes');
  return bytes;
}

Terminal _terminalWith(String content) {
  final terminal = Terminal(maxLines: 200)
    ..resize(_viewWidth, _viewHeight)
    ..write(content);
  return terminal;
}

/// Output shaped like the things a terminal actually spends its frames on,
/// plus one of every per-cell concern a run must break on.
const _corpus = 'plain ascii output, the common case\r\n'
    '\x1b[32mdrwxr-xr-x\x1b[0m  \x1b[34msrc\x1b[0m   \x1b[36mlib\x1b[0m\r\n'
    '\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[2mfaint\x1b[0m \x1b[7minverse\x1b[0m\r\n'
    '\x1b[4munderline\x1b[0m \x1b[21mdouble\x1b[0m \x1b[4:3mcurly\x1b[0m\r\n'
    '\x1b[4:4mdotted\x1b[0m \x1b[4:5mdashed\x1b[0m \x1b[9mstrike\x1b[0m \x1b[53moverline\x1b[0m\r\n'
    '\x1b[51mframed\x1b[0m \x1b[52mencircled\x1b[0m \x1b[8minvisible\x1b[0m\r\n'
    '\x1b[5mblinking\x1b[0m and not\r\n'
    '\u250c\u2500\u2500\u2510 box drawing \u2514\u2500\u2500\u2518\r\n'
    '\u28ff\u2800 braille \u2588\u2591 blocks\r\n'
    'CJK \u4f60\u597d\u4e16\u754c wide\r\n'
    'combining e\u0301 a\u0300 o\u0308\r\n'
    '    deeply     spaced     columns\r\n'
    '\x1b[41;97mred bg\x1b[0m normal \x1b[48;5;27mindexed\x1b[0m\r\n'
    '\x1b[38;2;255;128;0mtruecolor\x1b[0m tail\r\n'
    '\x1b]8;;https://example.com\x07a hyperlink\x1b]8;;\x07 after\r\n'
    'trailing spaces      \r\n'
    'tab\there\r\n'
    '\x1b[1;4;31mbold underline red\x1b[0m\r\n';

void main() {
  test('the test font advances uniformly, so batching is on by default', () {
    final painter = _newPainter();
    expect(painter.cellSize.width, greaterThan(0));
    expect(painter.runBatchingEnabled, isTrue);
    painter.dispose();
  });

  test('batched painting rasterises exactly like per-cell painting', () async {
    final batched = await _paintViewport(_terminalWith(_corpus), batched: true);
    final perCell = await _paintViewport(_terminalWith(_corpus), batched: false);
    expect(batched.lengthInBytes, perCell.lengthInBytes);
    expect(
      batched.buffer.asUint8List(),
      orderedEquals(perCell.buffer.asUint8List()),
    );
  });

  test('an active hyperlink is drawn the same either way', () async {
    final batched = await _paintViewport(
      _terminalWith(_corpus),
      batched: true,
      activeHyperlinkId: 1,
    );
    final perCell = await _paintViewport(
      _terminalWith(_corpus),
      batched: false,
      activeHyperlinkId: 1,
    );
    expect(
      batched.buffer.asUint8List(),
      orderedEquals(perCell.buffer.asUint8List()),
    );
  });

  test('a run past the frame budget is drawn the same as one inside it',
      () async {
    final inBudget = await _paintViewport(_terminalWith(_corpus), batched: true);
    final overBudget = await _paintViewport(
      _terminalWith(_corpus),
      batched: true,
      exhaustBudget: true,
    );
    expect(
      overBudget.buffer.asUint8List(),
      orderedEquals(inBudget.buffer.asUint8List()),
    );
  });

  test('plain output really is batched, and per-cell concerns break runs', () {
    final painter = _newPainter();
    final cellSize = painter.cellSize;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    final terminal = _terminalWith(
      'the quick brown fox jumps over the lazy dog\r\n'
      '\x1b[4munderlined text is not batched\x1b[0m\r\n',
    );

    painter.beginFrame();
    painter.resetPaintCounters();
    painter.paintLine(canvas, ui.Offset.zero, terminal.buffer.lines[0]);

    // One run for the whole line: 43 cells, one paragraph.
    expect(painter.runsDrawn, 1);
    expect(painter.cellsInDrawnRuns, 43);
    expect(painter.runParagraphsLaidOut, 1);
    expect(painter.cellParagraphsLaidOut, 0);

    painter.resetPaintCounters();
    painter.paintLine(
      canvas,
      ui.Offset(0, cellSize.height),
      terminal.buffer.lines[1],
    );

    // Underlined text stays on the per-cell path.
    expect(painter.runsDrawn, 0);
    expect(painter.cellParagraphsLaidOut, greaterThan(0));

    recorder.endRecording().dispose();
    painter.dispose();
  });

  test('a repainted line hits the run cache instead of laying out again', () {
    final painter = _newPainter();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final terminal = _terminalWith('a settled screen costs nothing to repaint');

    painter.beginFrame();
    painter.paintLine(canvas, ui.Offset.zero, terminal.buffer.lines[0]);

    painter.beginFrame();
    painter.resetPaintCounters();
    painter.paintLine(canvas, ui.Offset.zero, terminal.buffer.lines[0]);

    expect(painter.runsDrawn, 1);
    expect(painter.runParagraphsLaidOut, 0);
    expect(painter.cellParagraphsLaidOut, 0);

    recorder.endRecording().dispose();
    painter.dispose();
  });

}
