// DIVERGENCE (Karmashala): tests for the fork's complex-script glyph fitting.
// See KARMASHALA.md.

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show TextScaler;
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// The test font advances every glyph — including the `.notdef` box it draws
/// for a code point it has no glyph for — at exactly one em, which is what
/// makes the assertions below exact rather than font-dependent: a cell is
/// [_fontSize] wide and a cluster of _n_ code points lays out at _n_ cells.
const _fontSize = 14.0;

TerminalPainter _newPainter() {
  return TerminalPainter(
    theme: TerminalThemes.whiteOnBlack,
    textStyle: const TerminalStyle(fontSize: _fontSize, height: 1),
    textScaler: TextScaler.noScaling,
  );
}

/// How many pixels of ink each column of the painted line carries.
///
/// The test font draws a hollow rectangle for every code point it cannot
/// render, so a column through a glyph's vertical edge is inked over most of
/// the cell and a column through its hollow interior over very little. The
/// profile of those counts is therefore a faithful, machine-independent
/// picture of *how many* glyphs were drawn and *how wide* each one was — which
/// is exactly what this divergence changes.
Future<List<int>> _inkProfile(Terminal terminal, int columns) async {
  final painter = _newPainter();
  final cellSize = painter.cellSize;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  painter.beginFrame();
  painter.paintLine(canvas, ui.Offset.zero, terminal.buffer.lines[0]);
  final picture = recorder.endRecording();
  final width = (cellSize.width * columns).ceil();
  final height = cellSize.height.ceil();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  painter.dispose();
  if (bytes == null) fail('expected line pixels');

  final pixels = bytes.buffer.asUint8List();
  return [
    for (var x = 0; x < width; x++)
      () {
        var ink = 0;
        for (var y = 0; y < height; y++) {
          final offset = (y * width + x) * 4;
          if (pixels[offset] > 40 ||
              pixels[offset + 1] > 40 ||
              pixels[offset + 2] > 40) {
            ink++;
          }
        }
        return ink;
      }(),
  ];
}

List<int> _cell(List<int> profile, int index) =>
    profile.sublist(index * _fontSize.toInt(), (index + 1) * _fontSize.toInt());

List<int> _quarterOfCluster(List<int> profile, int cluster, int quarter) {
  const cellWidth = 14;
  final start = cluster * cellWidth + quarter * (cellWidth ~/ 2);
  return profile.sublist(start, start + cellWidth ~/ 2);
}

void main() {
  group('the buffer clusters Devanagari before the painter sees it', () {
    // The premise the painting divergence rests on. If these ever fail the
    // painter is innocent and the bug is in `Buffer._joinsPreviousGrapheme`.
    test('a conjunct is one cluster in one two-cell grapheme', () {
      final terminal = Terminal(maxLines: 10)..resize(12, 2);
      terminal.write('नमस्ते');
      final line = terminal.buffer.lines[0];

      // न and म stand alone; स + virama + त + vowel sign is one grapheme,
      // which is Unicode 15.1's GB9c Indic-conjunct rule.
      expect(line.getCodePoint(0), 0x0928);
      expect(line.getWidth(0), 1);
      expect(line.getCombiningCharacters(0), isNull);

      expect(line.getCodePoint(1), 0x092E);
      expect(line.getWidth(1), 1);
      expect(line.getCombiningCharacters(1), isNull);

      expect(line.getCodePoint(2), 0x0938);
      expect(line.getWidth(2), 2);
      expect(line.getCombiningCharacters(2), '्ते');

      // The second half of the wide grapheme, and then nothing.
      expect(line.getWidth(3), 0);
      expect(line.getCodePoint(4), 0);
    });

    test('a spacing vowel sign joins the consonant it follows', () {
      final terminal = Terminal(maxLines: 10)..resize(12, 2);
      terminal.write('कार्यशाला');
      final line = terminal.buffer.lines[0];

      // Four orthographic syllables, each one two-cell grapheme.
      const expected = <(int, String)>[
        (0x0915, 'ा'), // का
        (0x0930, '्य'), // र्य
        (0x0936, 'ा'), // शा
        (0x0932, 'ा'), // ला
      ];
      for (var syllable = 0; syllable < expected.length; syllable++) {
        final column = syllable * 2;
        expect(line.getCodePoint(column), expected[syllable].$1);
        expect(line.getWidth(column), 2);
        expect(line.getCombiningCharacters(column), expected[syllable].$2);
        expect(line.getWidth(column + 1), 0);
      }
    });
  });

  group('the painter condenses a complex-script cluster into its cells', () {
    test('every code point of the cluster is drawn, evenly across its cells',
        () async {
      final terminal = Terminal(maxLines: 10)..resize(12, 2);
      terminal.write('नमस्ते');
      final profile = await _inkProfile(terminal, 12);

      // न and म each lay out at exactly one cell, so they are drawn untouched:
      // one glyph filling one cell.
      expect(_cell(profile, 0), _cell(profile, 1));
      expect(_cell(profile, 0).where((ink) => ink > 0).length, 12);

      // The conjunct is four code points — स, virama, त, vowel sign — in the
      // two cells the buffer gave it, so it lays out at four cells and has to
      // be condensed to half width. All four glyphs are then drawn, each half
      // a cell wide, which makes the profile repeat with a period of half a
      // cell across cells 2 and 3.
      final first = _quarterOfCluster(profile, 2, 0);
      expect(first.where((ink) => ink > 0), isNotEmpty);
      for (var quarter = 1; quarter < 4; quarter++) {
        expect(
          _quarterOfCluster(profile, 2, quarter),
          first,
          reason: 'quarter $quarter of the cluster differs from the first, so '
              'the cluster was not condensed evenly into its two cells',
        );
      }
    });

    test('a cluster outside the complex scripts is still clipped', () async {
      // Greek alpha with two combining accents: three code points in one cell,
      // exactly the overflow the condensing path exists for — but not a script
      // whose letters lose their identity when clipped, so it must keep
      // upstream's behaviour of drawing the first glyph and clipping the rest.
      final terminal = Terminal(maxLines: 10)..resize(12, 2);
      terminal.write('\u0928\u03b1\u0301\u0302');
      final profile = await _inkProfile(terminal, 12);

      expect(
        _cell(profile, 1),
        _cell(profile, 0),
        reason: 'the alpha cell should hold one full-width glyph, as it did '
            'before this divergence, not three condensed ones',
      );
    });
  });
}
