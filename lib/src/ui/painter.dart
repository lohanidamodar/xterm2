import 'dart:math' show max, min;
import 'dart:ui';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import 'package:xterm2/src/ui/palette_builder.dart';
import 'package:xterm2/src/ui/paragraph_cache.dart';
import 'package:xterm2/src/ui/procedural_glyphs.dart';
import 'package:xterm2/xterm.dart';

const _dimColorFactor = 0.66;
const _specialBoldColor = 0;
const _specialUnderlineColor = 1;
const _specialBlinkColor = 2;
const _specialReverseColor = 3;
const _specialItalicColor = 4;
// DIVERGENCE (Karmashala): 2048 upstream, 10240 here — and the size is a
// decision, not an oversight.
//
// The per-cell cache is no longer only a nicety: it is the floor the run
// batcher falls back onto. When a frame exhausts its paragraph-layout budget
// (see [TerminalPainter.beginFrame]) every remaining run is painted cell by
// cell out of *this* cache, and that trade is only worth taking because a key
// of (colour, decoration colour, visual flags, cell content, scaler,
// combining) hits essentially always for real output. A 200x50 viewport is
// 10 000 cells; sized below the working set the cache thrashes and re-lays out
// every frame, which turns the fallback from a saving into a pessimisation —
// measured on xterm 4.0.0, a 4096-entry cache made the adversarial corpus 4x
// *slower* than not batching at all.
//
// Entries are single glyphs and eviction disposes them, so the ceiling is
// bounded; the constructor parameter is still there for a caller that wants a
// smaller one.
const _defaultParagraphCacheSize = 10240;

/// DIVERGENCE (Karmashala): cache for whole-run paragraphs, kept separate from
/// the per-cell cache so runs and cells cannot evict one another — the fallback
/// path depends on the per-cell cache staying warm exactly when the run cache
/// is missing.
///
/// Only runs of two or more cells are stored (a one-cell run goes to
/// [TerminalPainter.paintCellForeground], whose key hits far more often than a
/// run's text can), so this holds far fewer entries than its ceiling in
/// practice. It is sized to the same 10 240 for the same reason: the pathology
/// to avoid is a cache smaller than the screen's working set.
const _defaultRunCacheSize = 10240;

/// How far two ASCII advances may differ and still count as the same, in
/// logical pixels. See [TerminalPainter.beginFrame].
const _advanceTolerance = 0.01;

/// DIVERGENCE (Karmashala): how far a complex-script cluster may be condensed
/// to fit the cells it was allotted before clipping is the lesser evil.
///
/// Measured against the fonts Windows actually falls back to, a Devanagari
/// syllable overflows its cells by 4-33% (Nirmala UI shapes `म` at 1.22 cells,
/// Mangal at 1.33), so the real range is 0.75-0.96 and no real text comes near
/// this floor. It exists so a pathologically wide cluster degrades to
/// upstream's clip — which at least keeps the strokes their true weight —
/// rather than being smeared into an unreadable stripe.
const _minimumGlyphSqueeze = 0.4;

bool _isSymbolLike(int codePoint) {
  return switch (codePoint) {
    >= 0x2190 && <= 0x21FF => true,
    >= 0x2460 && <= 0x24FF => true,
    >= 0x2600 && <= 0x27BF => true,
    >= 0xE000 && <= 0xF8FF => true,
    >= 0x1F100 && <= 0x1F1FF => true,
    >= 0x1F300 && <= 0x1F6FF => true,
    >= 0xF0000 && <= 0xFFFFD => true,
    >= 0x100000 && <= 0x10FFFD => true,
    _ => false,
  };
}

bool _isGraphicsElement(int codePoint) {
  return switch (codePoint) {
    >= 0x2500 && <= 0x259F => true,
    >= 0xE0B0 && <= 0xE0D7 => true,
    >= 0x1FB00 && <= 0x1FBFF => true,
    >= 0x1CC00 && <= 0x1CEBF => true,
    _ => false,
  };
}

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    int paragraphCacheSize = _defaultParagraphCacheSize,
    int runCacheSize = _defaultRunCacheSize,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler,
        _paragraphCache = ParagraphCache(paragraphCacheSize),
        _runCache = ParagraphCache(runCacheSize);

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final ParagraphCache _paragraphCache;

  /// DIVERGENCE (Karmashala): laid-out paragraphs for whole *runs* of
  /// same-styled text, keyed on (text, colour, bold, italic, scaler).
  ///
  /// See [paintLineForegrounds] for what may enter a run and [beginFrame] for
  /// why laying one out is rationed.
  final ParagraphCache _runCache;

  /// DIVERGENCE (Karmashala): whether every printable ASCII glyph in the
  /// current style advances by exactly [cellSize].width, so that a string of
  /// them lays out at exactly `n * cellWidth` and one paragraph can stand in
  /// for n per-cell paragraphs.
  ///
  /// Measured in [_measureCharSize], because that is where the font is already
  /// being probed and because it must be re-derived whenever the style, the
  /// scaler or the system fonts change. False disables run batching entirely —
  /// with a proportional font the per-cell painter clips each glyph into its
  /// cell, and a run would instead let a wide glyph shove every glyph after it
  /// out of its column.
  var _uniformAsciiAdvance = false;

  /// Whether [paintLineForegrounds] is currently allowed to batch runs.
  ///
  /// DIVERGENCE (Karmashala): writable so a test can paint the same content
  /// both ways and require the two to rasterise identically. Read [cellSize]
  /// first — measuring the font is what decides the initial value, and it
  /// happens lazily.
  @visibleForTesting
  bool get runBatchingEnabled => _uniformAsciiAdvance;

  @visibleForTesting
  set runBatchingEnabled(bool value) => _uniformAsciiAdvance = value;

  /// DIVERGENCE (Karmashala): scratch state for the run batcher, held on the
  /// painter rather than allocated per line — this is the *busy* frame's path,
  /// and a 200x50 viewport would otherwise allocate hundreds of these a frame
  /// exactly when the frame has no time to spare. The painter is never
  /// re-entered, so one of each is enough.
  final _runCell = CellData.empty();
  final _fallbackCell = CellData.empty();
  final _runText = StringBuffer();

  /// Reused during cell painting to avoid allocating objects per visible cell.
  final _foregroundPaint = Paint();
  final _backgroundPaint = Paint();

  final Map<int, Color> _indexedColorOverrides = {};
  final Map<int, Color> _specialColorOverrides = {};

  int _colorRevision = -1;

  Object? _colorSource;

  Color? _foregroundColorOverride;

  Color? _backgroundColorOverride;

  Color? _cursorColorOverride;

  Color? _selectionColorOverride;

  Color? _selectionForegroundColorOverride;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear(); // DIVERGENCE (Karmashala)
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear(); // DIVERGENCE (Karmashala)
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _runCache.clear(); // DIVERGENCE (Karmashala)
  }

  bool get reverseDisplay => _reverseDisplay;
  bool _reverseDisplay = false;
  set reverseDisplay(bool value) {
    if (value == _reverseDisplay) return;
    _reverseDisplay = value;
    _paragraphCache.clear();
    _runCache.clear(); // DIVERGENCE (Karmashala)
  }

  Size _measureCharSize() {
    final textStyle = _textStyle.toTextStyle();
    final paragraphStyle = textStyle.getParagraphStyle();
    final textStyleRun = textStyle.getTextStyle(textScaler: _textScaler);

    var width = 0.0;
    var height = 0.0;
    for (var codePoint = 0x21; codePoint <= 0x7e; codePoint++) {
      final builder = ParagraphBuilder(paragraphStyle);
      builder.pushStyle(textStyleRun);
      builder.addText(String.fromCharCode(codePoint));

      final paragraph = builder.build();
      paragraph.layout(ParagraphConstraints(width: double.infinity));

      width = max(width, paragraph.maxIntrinsicWidth);
      height = max(height, paragraph.height);
      paragraph.dispose();
    }

    _uniformAsciiAdvance = _measureUniformAdvance(width);

    return Size(width, height);
  }

  /// DIVERGENCE (Karmashala): whether a *string* of printable ASCII lays out at
  /// exactly one [cellWidth] per character, which is the single assumption run
  /// batching rests on.
  ///
  /// Probed with one paragraph rather than by comparing per-glyph advances,
  /// because that measures the property directly — including the space, whose
  /// advance a one-character paragraph does not reliably report, and including
  /// whatever shaping survives the font features [TerminalStyle] disables. The
  /// probe puts the space in the interior and ends on a visible glyph so no
  /// trailing whitespace is involved.
  bool _measureUniformAdvance(double cellWidth) {
    if (cellWidth <= 0) return false;

    final textStyle = _textStyle.toTextStyle();
    final paragraphStyle = textStyle.getParagraphStyle();
    final textStyleRun = textStyle.getTextStyle(textScaler: _textScaler);

    final probe = StringBuffer();
    for (var codePoint = 0x21; codePoint <= 0x7e; codePoint++) {
      probe.writeCharCode(codePoint);
    }
    probe.writeCharCode(0x20);
    for (var codePoint = 0x21; codePoint <= 0x7e; codePoint++) {
      probe.writeCharCode(codePoint);
    }
    final text = probe.toString();

    final builder = ParagraphBuilder(paragraphStyle);
    builder.pushStyle(textStyleRun);
    builder.addText(text);
    final paragraph = builder.build();
    paragraph.layout(const ParagraphConstraints(width: double.infinity));
    final measured = paragraph.maxIntrinsicWidth;
    paragraph.dispose();

    return (measured - text.length * cellWidth).abs() <=
        _advanceTolerance * text.length;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  int get paragraphCacheLength => _paragraphCache.length;

  int glyphConstraintCellSpan(BufferLine line, int column) {
    final gridWidth = line.getWidth(column);
    if (gridWidth > 1) return gridWidth;

    final codePoint = line.getCodePoint(column);
    if (!_isSymbolLike(codePoint)) return 1;
    if (column + 1 >= line.length) return 1;

    if (column > 0) {
      final previous = line.getCodePoint(column - 1);
      if (_isSymbolLike(previous) && !_isGraphicsElement(previous)) return 1;
    }

    final next = line.getCodePoint(column + 1);
    if (next == 0 || next == 0x20 || next == 0x2002) return 2;
    return 1;
  }

  Color get foregroundColor => _foregroundColorOverride ?? _theme.foreground;

  Color get backgroundColor => _backgroundColorOverride ?? _theme.background;

  Color get cursorColor => _cursorColorOverride ?? _theme.cursor;

  Color get selectionColor => _selectionColorOverride ?? _theme.selection;

  Color? get selectionForegroundColor => _selectionForegroundColorOverride;

  Color get searchHitBackgroundColor => _theme.searchHitBackground;

  Color get searchHitBackgroundCurrentColor =>
      _theme.searchHitBackgroundCurrent;

  Color get searchHitForegroundColor => _theme.searchHitForeground;

  Color get cursorLineHighlightColor => selectionColor.withValues(alpha: 0.18);

  Color? get backgroundColorOverride => _backgroundColorOverride;

  void updateColorOverrides(
    Object source,
    int revision,
    Iterable<MapEntry<int, int>> indexedColors,
    Iterable<MapEntry<int, int>> specialColors,
    int? foreground,
    int? background,
    int? cursor,
    int? selection,
    int? selectionForeground,
  ) {
    if (identical(_colorSource, source) && _colorRevision == revision) return;
    _colorSource = source;
    _colorRevision = revision;
    _indexedColorOverrides
      ..clear()
      ..addEntries(indexedColors.map(
        (entry) => MapEntry(entry.key, Color(0xff000000 | entry.value)),
      ));
    _specialColorOverrides
      ..clear()
      ..addEntries(specialColors.map(
        (entry) => MapEntry(entry.key, Color(0xff000000 | entry.value)),
      ));
    _foregroundColorOverride = switch (foreground) {
      final value? => Color(0xff000000 | value),
      null => null,
    };
    _backgroundColorOverride = switch (background) {
      final value? => Color(0xff000000 | value),
      null => null,
    };
    _cursorColorOverride = switch (cursor) {
      final value? => Color(0xff000000 | value),
      null => null,
    };
    _selectionColorOverride = switch (selection) {
      final value? => Color(0xff000000 | value),
      null => null,
    };
    _selectionForegroundColorOverride = switch (selectionForeground) {
      final value? => Color(0xff000000 | value),
      null => null,
    };
    _paragraphCache.clear();
    _runCache.clear(); // DIVERGENCE (Karmashala)
  }

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _runCache.clear(); // DIVERGENCE (Karmashala)
  }

  void dispose() {
    _paragraphCache.dispose();
    _runCache.dispose(); // DIVERGENCE (Karmashala)
  }

  /// DIVERGENCE (Karmashala): how many *new* run paragraphs
  /// [paintLineForegrounds] may lay out in one frame before it stops laying
  /// out and paints the rest of that frame's misses cell by cell instead. See
  /// [beginFrame] for why there is a budget at all.
  ///
  /// 48 is picked from the cost of a miss, not from taste. Instrumenting the
  /// miss branch on xterm 4.0.0 gave ~11 us of fixed `ParagraphBuilder` +
  /// `build` + `layout` overhead per paragraph plus ~0.19 us per character, so
  /// a 200-column run costs ~49 us and a ~11-column `ls` entry ~23 us; measured
  /// again here on a 200x50 viewport of `ls --color`-shaped output, ~25 us per
  /// run laid out. 48 runs is therefore ~1.2-2.4 ms — well under a seventh of a
  /// 16.67 ms frame, small enough to leave room for the rest of the app's
  /// paint, and large enough that a viewport of one-run-per-line output
  /// converges to fully batched in two frames.
  static const maxRunLayoutsPerFrame = 48;

  /// Remaining layouts in the current frame. Starts full so that a painter
  /// driven directly — by a test, or by anything that does not call
  /// [beginFrame] — still batches its first frame.
  int _runLayoutBudget = maxRunLayoutsPerFrame;

  /// Number of run paragraphs laid out since [resetPaintCounters].
  ///
  /// Exposed because this is the quantity the painter's cost is made of: at
  /// ~11-49 us apiece it is the great majority of the time a frame whose
  /// content changed spends painting text.
  @visibleForTesting
  int runParagraphsLaidOut = 0;

  /// Number of runs painted cell by cell because the frame's layout budget was
  /// already spent. Counted so a test can tell "the budget held" apart from
  /// "there was nothing to lay out".
  @visibleForTesting
  int runsDeferredToCells = 0;

  /// Number of *cell* paragraphs laid out since [resetPaintCounters].
  ///
  /// The claim that makes the fallback worth taking is that [_paragraphCache]
  /// hits where [_runCache] cannot, because its key is a single cell rather
  /// than a whole run's text — a few hundred live entries for real output
  /// against one per distinct run. This counter is how that claim can be
  /// pinned by a number instead of by the comment above it.
  @visibleForTesting
  int cellParagraphsLaidOut = 0;

  /// Number of runs drawn as a single paragraph since [resetPaintCounters],
  /// and the number of cells those runs covered.
  @visibleForTesting
  int runsDrawn = 0;

  @visibleForTesting
  int cellsInDrawnRuns = 0;

  @visibleForTesting
  void resetPaintCounters() {
    runParagraphsLaidOut = 0;
    runsDeferredToCells = 0;
    cellParagraphsLaidOut = 0;
    runsDrawn = 0;
    cellsInDrawnRuns = 0;
  }

  /// DIVERGENCE (Karmashala): called once per frame, before the frame's first
  /// [paintLine], to refill the paragraph-layout budget.
  ///
  /// A terminal's paint cost is dominated by laying out paragraphs for text it
  /// has never seen before, and the frames where that happens are exactly the
  /// frames that are already busy: a screenful of new output arrives, every run
  /// on every line misses [_runCache], and the painter lays out one paragraph
  /// per run before it may draw anything. Measured on xterm 4.0.0 with a full
  /// 200x50 viewport of freshly arrived `ls --color`-shaped output: 686 layouts
  /// per frame, 15.6 ms of the frame's 16.7 ms inside the miss branch, zero
  /// cache hits. That is the whole frame budget spent on text that will have
  /// scrolled away in a second. Re-measured against this painter, the same
  /// corpus produces ~438 runs a frame at ~25 us to lay one out — ~11 ms a
  /// frame if nothing stopped it.
  ///
  /// So the budget is refilled here rather than being unlimited. Runs past it
  /// are painted cell by cell out of [_paragraphCache], whose key is one cell
  /// rather than the run's text — a key space of a few hundred entries for real
  /// output, so it hits essentially always. Painting a run out of that cache
  /// costs ~0.17 us per cell, which beats laying the run out at any run length.
  ///
  /// What the budget costs is draw calls, and only until the screen settles: a
  /// run that misses today is laid out on a later frame and batched from then
  /// on, so a screen that stops changing converges to exactly the same drawing
  /// an unbudgeted painter would do. Each pane has its own painter and so its
  /// own budget, which is the intended shape — four split panes all filling
  /// with new output at once cost 4 x 2.4 ms of layout rather than 4 x 15.6 ms.
  ///
  /// Ruled out on the way here, so nobody re-measures them:
  ///
  /// * **Hoisting the style objects out of the miss branch.** `toTextStyle` +
  ///   `getParagraphStyle` + `getTextStyle` (which copies a long font fallback
  ///   list) looks like the allocation to kill, but it is ~1.5 us of a ~16 us
  ///   miss. Worth ~10%, not the 5x.
  /// * **Growing or re-keying [_runCache].** The hit rate on a streaming
  ///   viewport is not low, it is *zero* — the key is the run's text and the
  ///   text is new. No cache size and no cheaper key changes that.
  /// * **Dropping run batching and always painting per cell.** Measured on this
  ///   painter, a settled 200x50 screen repaints in 2.4-2.6 ms per cell against
  ///   0.6-0.7 ms batched — 10 000 `drawParagraph` calls against ~400, four
  ///   times the cost, paid on *every* frame including the ones where nothing
  ///   changed. That is what the batching exists to remove; the budget exists
  ///   so that removing it does not cost more on the frames that are already
  ///   the busiest.
  void beginFrame() {
    _runLayoutBudget = maxRunLayoutsPerFrame;
  }

  /// Consumes one layout from the current frame's budget without drawing
  /// anything, so a test can drive the painter onto its fallback path.
  /// DIVERGENCE (Karmashala).
  @visibleForTesting
  void spendRunLayoutBudgetForTesting() {
    if (_runLayoutBudget > 0) _runLayoutBudget--;
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
    int cellWidth = 1,
    Color? color,
  }) {
    final cursorSize = Size(_cellSize.width * cellWidth, _cellSize.height);
    final paint = Paint()
      ..color = color ?? cursorColor
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & cursorSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & cursorSize, paint);
        return;
      case TerminalCursorType.underline:
        final underlineHeight = max(2.0, _cellSize.height * 0.12);
        return canvas.drawRect(
          Rect.fromLTWH(
            offset.dx,
            offset.dy + _cellSize.height - underlineHeight,
            cursorSize.width,
            underlineHeight,
          ),
          paint,
        );
      case TerminalCursorType.verticalBar:
        final barWidth = max(2.0, _cellSize.width * 0.2);
        return canvas.drawRect(
          Rect.fromLTWH(offset.dx, offset.dy, barWidth, _cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    canvas.drawRect(
      Rect.fromPoints(offset, endOffset),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  bool paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line, {
    bool blinkVisible = true,
    int? activeHyperlinkId,
  }) {
    paintLineBackgrounds(canvas, offset, line);
    return paintLineForegrounds(
      canvas,
      offset,
      line,
      blinkVisible: blinkVisible,
      activeHyperlinkId: activeHyperlinkId,
    );
  }

  void paintLineBackgrounds(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellData = CellData.empty();

    var backgroundRunStart = 0;
    var backgroundRunEnd = 0;
    Color? backgroundRunColor;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData, includeUnderlineColor: false);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellSpan = switch (charWidth == 2) {
        true => 2,
        false => 1,
      };
      final color = resolveCellBackgroundColor(cellData);
      final runColor = backgroundRunColor;

      if (color == null) {
        if (runColor != null) {
          paintBackgroundRun(
            canvas,
            offset,
            backgroundRunStart,
            backgroundRunEnd,
            runColor,
          );
        }
        backgroundRunColor = null;
        backgroundRunStart = i + cellSpan;
        backgroundRunEnd = backgroundRunStart;

        if (charWidth == 2) {
          i++;
        }
        continue;
      }

      if (runColor != null && runColor == color && backgroundRunEnd == i) {
        backgroundRunEnd += cellSpan;

        if (charWidth == 2) {
          i++;
        }
        continue;
      }

      if (runColor != null) {
        paintBackgroundRun(
          canvas,
          offset,
          backgroundRunStart,
          backgroundRunEnd,
          runColor,
        );
      }

      backgroundRunColor = color;
      backgroundRunStart = i;
      backgroundRunEnd = i + cellSpan;

      if (charWidth == 2) {
        i++;
      }
    }

    final runColor = backgroundRunColor;
    if (runColor != null) {
      paintBackgroundRun(
        canvas,
        offset,
        backgroundRunStart,
        backgroundRunEnd,
        runColor,
      );
    }
  }

  /// DIVERGENCE (Karmashala): consecutive cells that share a style and take the
  /// plain glyph path are drawn as **one** [Paragraph] instead of one per cell.
  ///
  /// This is the change the fork exists for. Upstream lays out and draws one
  /// paragraph per visible cell; on a 200x50 viewport that is 10 000 draw calls
  /// and, on any frame carrying text the cache has not seen, 10 000 layouts. On
  /// xterm 4.0.0 the equivalent rewrite took a streaming-output frame from
  /// 16.7 ms to 3.0 ms, and it is the fix for real typing lag in Karmashala.
  ///
  /// **What may join a run.** A run has to rasterise exactly as the per-cell
  /// loop would, so it may only contain cells that take
  /// [paintCellForeground]'s plain "draw the cached glyph at the cell origin"
  /// path. Every other concern in that method is per-cell and cannot be merged
  /// across, so each one breaks the run — see [_isBatchable]:
  ///
  /// * `charWidth != 1` — a double-width glyph's advance is not guaranteed to
  ///   be `2 * cellWidth`, and a zero-width continuation cell composes with the
  ///   glyph before it.
  /// * anything outside printable ASCII (`0x20`-`0x7e`). That excludes, by
  ///   construction and without having to test for them separately, every
  ///   procedural glyph (`procedural_glyphs.dart` starts at `0x00b0`), every
  ///   box- and branch-drawing character (`branch_glyphs.dart`), blank braille,
  ///   everything [glyphConstraintCellSpan] widens (`_isSymbolLike` starts at
  ///   `0x2190`), the empty cell, and the tab. It also keeps runs clear of
  ///   contextual shaping and of font fallback, neither of which composes
  ///   glyph-by-glyph.
  /// * any per-cell decoration — underline in all five styles (solid, double,
  ///   wavy, dotted, dashed), strikethrough, overline, framed/encircled. Wavy,
  ///   dotted and dashed restart their pattern at each cell origin, so a run
  ///   would draw a *different* line; double underline and the frame box are
  ///   drawn per cell around `allocatedWidth`. Solid underline could arguably
  ///   merge, but it travels in the same flag mask as the four that cannot, and
  ///   underlined output is not the case that drops frames.
  /// * `invisible`, and `blink` in either state — blinking text has to be able
  ///   to disappear, and it is rare enough not to be worth a second code path.
  /// * a cell inside the *active* hyperlink, which is drawn underlined and with
  ///   its own cache key while the pointer is over it.
  /// * a combining character, which composes with the glyph before it.
  /// * the cursor cell, whose foreground is overridden and whose selection
  ///   contrast is suppressed.
  ///
  /// Two batchable cells then join only if their foreground, background and
  /// *visual* flags are equal — which is exactly what
  /// [resolveCellForegroundColor] and [resolveSelectionForegroundColor] read,
  /// so one colour is right for the whole run. Semantic and protection bits are
  /// masked out of the comparison because they change nothing visual and would
  /// otherwise split every prompt from its output.
  ///
  /// This is deliberately narrower than the same optimisation was on xterm
  /// 4.0.0, which had none of the procedural glyphs, underline styles,
  /// hyperlinks or combining marks to respect. Correct and narrower beats fast
  /// and wrong: what remains is plain single-width text, which is what a
  /// terminal spends its frames drawing.
  ///
  /// Spaces are kept *inside* a run — an undecorated space paints nothing and
  /// advances one cell, exactly as it does per-cell — but are trimmed off both
  /// ends and an all-space run is skipped entirely, so indentation and column
  /// padding cost nothing.
  bool paintLineForegrounds(
    Canvas canvas,
    Offset offset,
    BufferLine line, {
    bool blinkVisible = true,
    int? activeHyperlinkId,
    int? cursorColumn,
    Color? cursorForeground,
    Color? foregroundOverride,
    bool ensureSelectionContrast = false,
  }) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;
    final hasCombiningCharacters = line.hasCombiningCharacters;
    // Reading `_cellSize` above has already forced the font probe.
    final batchRuns = _uniformAsciiAdvance;
    final runCell = _runCell;
    var runStart = 0;
    var runEnd = 0;

    var hasBlinkingText = false;
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      if (cellData.content & CellContent.codepointMask == 0) {
        if (runEnd > runStart) {
          _paintForegroundRun(
            canvas,
            offset,
            line,
            runStart,
            runEnd,
            blinkVisible: blinkVisible,
            activeHyperlinkId: activeHyperlinkId,
            foregroundOverride: foregroundOverride,
            ensureSelectionContrast: ensureSelectionContrast,
          );
          runStart = runEnd = i;
        }
        if (charWidth == 2) {
          i++;
        }
        continue;
      }

      if (cellData.flags & CellFlags.blink != 0) {
        hasBlinkingText = true;
      }

      if (batchRuns &&
          i != cursorColumn &&
          _isBatchable(cellData, charWidth, activeHyperlinkId) &&
          (!hasCombiningCharacters ||
              line.getCombiningCharacters(i) == null)) {
        final visualFlags = cellData.flags & CellAttr.visualMask;
        if (runEnd == i &&
            runEnd > runStart &&
            cellData.foreground == runCell.foreground &&
            cellData.background == runCell.background &&
            visualFlags == runCell.flags) {
          runEnd = i + 1;
          continue;
        }
        if (runEnd > runStart) {
          _paintForegroundRun(
            canvas,
            offset,
            line,
            runStart,
            runEnd,
            blinkVisible: blinkVisible,
            activeHyperlinkId: activeHyperlinkId,
            foregroundOverride: foregroundOverride,
            ensureSelectionContrast: ensureSelectionContrast,
          );
        }
        runStart = i;
        runEnd = i + 1;
        runCell.foreground = cellData.foreground;
        runCell.background = cellData.background;
        runCell.flags = visualFlags;
        continue;
      }

      if (runEnd > runStart) {
        _paintForegroundRun(
          canvas,
          offset,
          line,
          runStart,
          runEnd,
          blinkVisible: blinkVisible,
          activeHyperlinkId: activeHyperlinkId,
          foregroundOverride: foregroundOverride,
          ensureSelectionContrast: ensureSelectionContrast,
        );
        runStart = runEnd = i;
      }

      final cellOffset = offset.translate(i * cellWidth, 0);

      paintCellForeground(
        canvas,
        cellOffset,
        cellData,
        combiningCharacters: switch (hasCombiningCharacters) {
          true => line.getCombiningCharacters(i),
          false => null,
        },
        glyphCellSpan: glyphConstraintCellSpan(line, i),
        blinkVisible: blinkVisible,
        activeHyperlinkId: activeHyperlinkId,
        foregroundOverride: switch (i == cursorColumn) {
          true => cursorForeground,
          false => foregroundOverride,
        },
        ensureSelectionContrast: ensureSelectionContrast && i != cursorColumn,
      );

      if (charWidth == 2) {
        i++;
      }
    }

    if (runEnd > runStart) {
      _paintForegroundRun(
        canvas,
        offset,
        line,
        runStart,
        runEnd,
        blinkVisible: blinkVisible,
        activeHyperlinkId: activeHyperlinkId,
        foregroundOverride: foregroundOverride,
        ensureSelectionContrast: ensureSelectionContrast,
      );
    }

    return hasBlinkingText;
  }

  /// Flags that force a cell onto the per-cell path. See
  /// [paintLineForegrounds]. DIVERGENCE (Karmashala).
  static const _unbatchableFlags = CellFlags.invisible |
      CellFlags.blink |
      CellAttr.underlineMask |
      CellAttr.strikethrough |
      CellAttr.overline |
      CellAttr.frameMask;

  /// Whether [cellData] may be merged into a text run. See
  /// [paintLineForegrounds]. DIVERGENCE (Karmashala).
  @pragma('vm:prefer-inline')
  bool _isBatchable(CellData cellData, int charWidth, int? activeHyperlinkId) {
    if (charWidth != 1) return false;

    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode < 0x20 || charCode > 0x7e) return false;

    if (cellData.flags & _unbatchableFlags != 0) return false;

    final hyperlinkId = cellData.hyperlinkId;
    if (hyperlinkId != 0 && hyperlinkId == activeHyperlinkId) return false;

    return true;
  }

  /// Draws `[start, end)` of [line] as one paragraph, or cell by cell when this
  /// frame can no longer afford to lay one out. DIVERGENCE (Karmashala).
  void _paintForegroundRun(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    int start,
    int end, {
    required bool blinkVisible,
    required int? activeHyperlinkId,
    required Color? foregroundOverride,
    required bool ensureSelectionContrast,
  }) {
    // An undecorated space paints nothing, so it can be trimmed off either end
    // and an all-space run skipped outright.
    var from = start;
    var to = end;
    while (from < to && line.getCodePoint(from) == 0x20) {
      from++;
    }
    while (to > from && line.getCodePoint(to - 1) == 0x20) {
      to--;
    }
    if (from >= to) return;

    if (to - from == 1) {
      // A one-cell run is what the per-cell painter already does best: its key
      // is one cell rather than a string, so it hits across every line on the
      // screen instead of only where the same text repeats.
      _paintRunPerCell(
        canvas,
        offset,
        line,
        from,
        to,
        blinkVisible: blinkVisible,
        activeHyperlinkId: activeHyperlinkId,
        foregroundOverride: foregroundOverride,
        ensureSelectionContrast: ensureSelectionContrast,
      );
      return;
    }

    final runCell = _runCell;
    final color = switch (ensureSelectionContrast) {
      true => resolveSelectionForegroundColor(
          runCell,
          foregroundOverride: foregroundOverride,
        ),
      false => resolveCellForegroundColor(
          runCell,
          foregroundOverride: foregroundOverride,
        ),
    };
    final bold = runCell.flags & CellFlags.bold != 0;
    final italic = runCell.flags & CellFlags.italic != 0;

    _runText.clear();
    for (var i = from; i < to; i++) {
      _runText.writeCharCode(line.getCodePoint(i));
    }
    final text = _runText.toString();

    final cacheKey = (text, color, bold, italic, _textScaler);
    var paragraph = _runCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      if (_runLayoutBudget <= 0) {
        runsDeferredToCells++;
        _paintRunPerCell(
          canvas,
          offset,
          line,
          from,
          to,
          blinkVisible: blinkVisible,
          activeHyperlinkId: activeHyperlinkId,
          foregroundOverride: foregroundOverride,
          ensureSelectionContrast: ensureSelectionContrast,
        );
        return;
      }
      _runLayoutBudget--;
      runParagraphsLaidOut++;

      paragraph = _runCache.performAndCacheLayout(
        text,
        _textStyle.toTextStyle(color: color, bold: bold, italic: italic),
        _textScaler,
        cacheKey,
      );

      // The whole scheme rests on a run occupying exactly its cells. The font
      // probe in [_measureCharSize] establishes that up front; this catches a
      // style where it somehow does not, in debug builds, before a user sees
      // sheared text.
      assert(
        (paragraph.maxIntrinsicWidth - (to - from) * _cellSize.width).abs() <=
            0.5 + _advanceTolerance * (to - from),
        'run paragraph "$text" laid out at ${paragraph.maxIntrinsicWidth}, '
        'expected ${(to - from) * _cellSize.width}',
      );
    }

    runsDrawn++;
    cellsInDrawnRuns += to - from;
    canvas.drawParagraph(
      paragraph,
      offset.translate(from * _cellSize.width, 0),
    );
  }

  /// Paints `[from, to)` of [line] one cell at a time, which is what
  /// [_paintForegroundRun] falls back to when the frame's layout budget is
  /// spent. DIVERGENCE (Karmashala).
  ///
  /// This is not an approximation of the batched path, it is the path the
  /// batched one is held to: it calls the same [paintCellForeground] the
  /// unbatched loop calls, over the same cells, with the same arguments, so
  /// colour, faint, bold, italic, inverse and selection contrast are all
  /// re-derived from the cells themselves and nothing can drift out of step
  /// with the run path. Only cells a run was allowed to contain reach it —
  /// single width, printable ASCII, no combining mark, not the cursor — so
  /// unlike the main loop it needs no double-width skipping.
  void _paintRunPerCell(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    int from,
    int to, {
    required bool blinkVisible,
    required int? activeHyperlinkId,
    required Color? foregroundOverride,
    required bool ensureSelectionContrast,
  }) {
    final cell = _fallbackCell;
    final cellWidth = _cellSize.width;
    for (var i = from; i < to; i++) {
      line.getCellData(i, cell);
      paintCellForeground(
        canvas,
        offset.translate(i * cellWidth, 0),
        cell,
        glyphCellSpan: glyphConstraintCellSpan(line, i),
        blinkVisible: blinkVisible,
        activeHyperlinkId: activeHyperlinkId,
        foregroundOverride: foregroundOverride,
        ensureSelectionContrast: ensureSelectionContrast,
      );
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(
    Canvas canvas,
    Offset offset,
    CellData cellData, {
    String? combiningCharacters,
    int? glyphCellSpan,
    bool blinkVisible = true,
    int? activeHyperlinkId,
    Color? foregroundOverride,
    bool ensureSelectionContrast = false,
  }) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;
    if (charCode == 0x09) return;

    final cellFlags = cellData.flags;
    if (cellFlags & CellFlags.invisible != 0) return;
    if (cellFlags & CellFlags.blink != 0 && !blinkVisible) return;

    final isActiveHyperlink =
        cellData.hyperlinkId != 0 && cellData.hyperlinkId == activeHyperlinkId;
    final isBlankBraille = charCode == 0x2800;
    if (combiningCharacters == null &&
        (charCode == 0x20 || isBlankBraille) &&
        !isActiveHyperlink &&
        !_hasVisibleSpaceDecoration(cellFlags)) {
      return;
    }
    final color = switch (ensureSelectionContrast) {
      true => resolveSelectionForegroundColor(
          cellData,
          foregroundOverride: foregroundOverride,
        ),
      false => resolveCellForegroundColor(
          cellData,
          foregroundOverride: foregroundOverride,
        ),
    };
    final charWidth = cellData.content >> CellContent.widthShift;
    final cellSpan = switch (charWidth) {
      2 => 2,
      _ => 1,
    };
    final allocatedWidth = _cellSize.width * cellSpan;
    final glyphClipWidth =
        _cellSize.width * max(cellSpan, glyphCellSpan ?? cellSpan);
    final decorationColor = switch (cellData.underlineColor) {
      0 => _underlineDecorationColor(cellFlags, color),
      _ => resolveForegroundColor(cellData.underlineColor),
    };

    if (combiningCharacters == null && (charCode == 0x20 || isBlankBraille)) {
      _paintManualDecorations(
        canvas,
        offset,
        color,
        decorationColor,
        cellFlags,
        allocatedWidth: allocatedWidth,
        isActiveHyperlink: isActiveHyperlink,
      );
      return;
    }

    _foregroundPaint.color = color;
    if (combiningCharacters == null &&
        paintProceduralGlyph(
          canvas,
          offset,
          _cellSize,
          charCode,
          _foregroundPaint,
        )) {
      _paintManualDecorations(
        canvas,
        offset,
        color,
        decorationColor,
        cellFlags,
        allocatedWidth: allocatedWidth,
        isActiveHyperlink: isActiveHyperlink,
      );
      return;
    }

    final visualFlags = cellData.flags & CellAttr.visualMask;
    final hyperlinkFlag = switch (isActiveHyperlink) {
      true => CellAttr.hyperlinkMarker,
      false => 0,
    };
    final cacheKey = (
      color,
      decorationColor,
      visualFlags | hyperlinkFlag,
      cellData.content,
      _textScaler,
      combiningCharacters,
    );
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final style = _textStyle.toTextStyle(
        color: color,
        decorationColor: decorationColor,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: _hasUnderline(cellFlags) || isActiveHyperlink,
        doubleUnderline: _hasDoubleUnderline(cellFlags, isActiveHyperlink),
        decorationStyle: _decorationStyle(cellFlags),
        strikethrough: cellFlags & CellAttr.strikethrough != 0,
        overline: cellFlags & CellAttr.overline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if ((_hasUnderline(cellFlags) || isActiveHyperlink) &&
          (charCode == 0x20 || isBlankBraille)) {
        char = String.fromCharCode(0xA0);
      }
      if (combiningCharacters != null) {
        char += combiningCharacters;
      }

      cellParagraphsLaidOut++; // DIVERGENCE (Karmashala)
      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    if (paragraph.maxIntrinsicWidth <= glyphClipWidth &&
        paragraph.height <= _cellSize.height) {
      canvas.drawParagraph(paragraph, offset);
      _paintFrameDecoration(
        canvas,
        offset,
        color,
        cellFlags,
        allocatedWidth: allocatedWidth,
      );
      return;
    }
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
        offset.dx,
        offset.dy,
        glyphClipWidth,
        _cellSize.height,
      ),
    );
    // DIVERGENCE (Karmashala): condense a complex-script cluster into the cells
    // it was allotted rather than chopping its right-hand side off. See
    // [_horizontalSqueeze].
    final squeeze = _horizontalSqueeze(
      charCode,
      paragraph.maxIntrinsicWidth,
      glyphClipWidth,
    );
    if (squeeze != null) {
      canvas.translate(offset.dx, 0);
      canvas.scale(squeeze, 1);
      canvas.drawParagraph(paragraph, Offset(0, offset.dy));
    } else {
      canvas.drawParagraph(paragraph, offset);
    }
    canvas.restore();
    _paintFrameDecoration(
      canvas,
      offset,
      color,
      cellFlags,
      allocatedWidth: allocatedWidth,
    );
  }

  /// DIVERGENCE (Karmashala): the horizontal scale that fits an overflowing
  /// complex-script cluster into the cells its grapheme was allotted, or null
  /// to keep upstream's clip.
  ///
  /// A terminal gives a grapheme a whole number of cells and a monospace
  /// advance; a Devanagari syllable comes back from a proportional fallback
  /// font at whatever width its shaping produced. `नमस्ते` is three graphemes —
  /// `न`, `म`, and the conjunct `स्ते`, which `Buffer` correctly stores as one
  /// two-cell cluster — but at 14 px Consolas (cell 7.70 px) Nirmala UI shapes
  /// `न` at 8.50 px and `म` at 9.43 px against one cell, and `न्दी` at 16.45 px
  /// against two. Upstream clips, so every bare consonant loses the right
  /// 10-25% of itself — and in Devanagari that is not cosmetic: the right-hand
  /// vertical stem *is* the letter, so a clipped `क` reads as `व`, `झ` as `इ`
  /// and `छ` as `ङ`. Condensing the cluster by the same 10-25% keeps every
  /// letter whole and keeps it inside its own cells.
  ///
  /// Scoped to the Indic blocks [Buffer] already knows — the same range its
  /// Unicode 15.1 GB9c conjunct rule uses — so the buffer's idea of what forms
  /// a cluster and the painter's idea of what to condense agree. Deliberately
  /// **not** applied to symbols, emoji or box drawing: those overflow too, but
  /// [glyphConstraintCellSpan] already lets them overhang a blank neighbour and
  /// condensing them would change output nobody complained about.
  ///
  /// Costs nothing on the common path: printable ASCII either never reaches
  /// [paintCellForeground] at all (it is batched) or fits its cell and returns
  /// before this. Only a cell that upstream was already about to clip — which
  /// already pays a `save`/`clipRect`/`restore` — reaches here, and for it this
  /// adds one range test and, when it fires, a `translate` and a `scale`.
  /// Neither is a draw call.
  @pragma('vm:prefer-inline')
  static double? _horizontalSqueeze(
    int codePoint,
    double glyphWidth,
    double availableWidth,
  ) {
    if (!_isComplexScript(codePoint)) return null;
    if (availableWidth <= 0 || glyphWidth <= availableWidth) return null;
    final scale = availableWidth / glyphWidth;
    // Below this a glyph is a smear rather than a letter; clip instead, which
    // at least keeps the strokes their real thickness.
    if (scale < _minimumGlyphSqueeze) return null;
    return scale;
  }

  /// DIVERGENCE (Karmashala): scripts whose glyphs a monospace cell must
  /// condense rather than clip. See [_horizontalSqueeze].
  ///
  /// These are exactly the nine Indic blocks `Buffer._isIndicCodePoint`
  /// recognises, plus Devanagari Extended and the Vedic Extensions, which the
  /// same shaping produces. Another script can join once someone has measured
  /// it; the failure mode this fixes — a letter whose identity lives in the
  /// part that gets chopped — is not universal.
  @pragma('vm:prefer-inline')
  static bool _isComplexScript(int codePoint) {
    if (codePoint < 0x0900) return false;
    return switch (codePoint) {
      >= 0x0900 && <= 0x0DFF => true, // Devanagari .. Sinhala
      >= 0x1CD0 && <= 0x1CFF => true, // Vedic Extensions
      >= 0xA8E0 && <= 0xA8FF => true, // Devanagari Extended
      _ => false,
    };
  }

  @pragma('vm:prefer-inline')
  bool _hasUnderline(int cellFlags) {
    return cellFlags & CellAttr.underlineMask != 0;
  }

  @pragma('vm:prefer-inline')
  bool _hasDoubleUnderline(int cellFlags, bool isActiveHyperlink) {
    if (cellFlags & CellAttr.doubleUnderline != 0) {
      return true;
    }
    return isActiveHyperlink && (cellFlags & CellFlags.underline != 0);
  }

  @pragma('vm:prefer-inline')
  bool _hasVisibleSpaceDecoration(int cellFlags) {
    return cellFlags &
            (CellAttr.underlineMask |
                CellAttr.strikethrough |
                CellAttr.overline |
                CellAttr.frameMask) !=
        0;
  }

  void _paintManualDecorations(
    Canvas canvas,
    Offset offset,
    Color color,
    Color decorationColor,
    int cellFlags, {
    required double allocatedWidth,
    required bool isActiveHyperlink,
  }) {
    if (isActiveHyperlink ||
        cellFlags &
                (CellFlags.underline |
                    CellAttr.undercurl |
                    CellAttr.dottedUnderline |
                    CellAttr.dashedUnderline) !=
            0) {
      _paintUnderlineDecoration(
        canvas,
        offset,
        decorationColor,
        cellFlags,
        allocatedWidth: allocatedWidth,
        isHyperlink: isActiveHyperlink,
      );
    }
    if (cellFlags & CellAttr.doubleUnderline != 0) {
      _paintDoubleUnderline(canvas, offset, decorationColor, allocatedWidth);
    }

    _foregroundPaint.color = decorationColor;
    if (cellFlags & CellAttr.strikethrough != 0) {
      canvas.drawLine(
        offset.translate(0, _cellSize.height / 2),
        offset.translate(allocatedWidth, _cellSize.height / 2),
        _foregroundPaint,
      );
    }
    if (cellFlags & CellAttr.overline != 0) {
      canvas.drawLine(
        offset,
        offset.translate(allocatedWidth, 0),
        _foregroundPaint,
      );
    }
    _paintFrameDecoration(
      canvas,
      offset,
      color,
      cellFlags,
      allocatedWidth: allocatedWidth,
    );
  }

  void _paintFrameDecoration(
    Canvas canvas,
    Offset offset,
    Color color,
    int cellFlags, {
    required double allocatedWidth,
  }) {
    if (cellFlags & CellAttr.frameMask == 0) return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rect = Rect.fromLTWH(
      offset.dx + 0.5,
      offset.dy + 0.5,
      allocatedWidth - 1,
      _cellSize.height - 1,
    );

    if (cellFlags & CellAttr.encircled != 0) {
      canvas.drawOval(rect, paint);
      return;
    }

    canvas.drawRect(rect, paint);
  }

  @pragma('vm:prefer-inline')
  TextDecorationStyle _decorationStyle(int cellFlags) {
    if (cellFlags & CellAttr.undercurl != 0) {
      return TextDecorationStyle.wavy;
    }
    if (cellFlags & CellAttr.dottedUnderline != 0) {
      return TextDecorationStyle.dotted;
    }
    if (cellFlags & CellAttr.dashedUnderline != 0) {
      return TextDecorationStyle.dashed;
    }
    return TextDecorationStyle.solid;
  }

  void _paintUnderlineDecoration(
    Canvas canvas,
    Offset offset,
    Color color,
    int cellFlags, {
    required double allocatedWidth,
    required bool isHyperlink,
  }) {
    if (isHyperlink && (cellFlags & CellFlags.underline != 0)) {
      _paintDoubleUnderline(canvas, offset, color, allocatedWidth);
      return;
    }
    if (cellFlags & CellAttr.undercurl != 0) {
      _paintWavyUnderline(canvas, offset, color, allocatedWidth);
      return;
    }
    if (cellFlags & CellAttr.dottedUnderline != 0) {
      _paintDottedUnderline(canvas, offset, color, allocatedWidth);
      return;
    }
    if (cellFlags & CellAttr.dashedUnderline != 0) {
      _paintDashedUnderline(canvas, offset, color, allocatedWidth);
      return;
    }
    if (cellFlags & CellFlags.underline == 0 && !isHyperlink) {
      return;
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(
      offset.translate(0, _cellSize.height - 1),
      offset.translate(allocatedWidth, _cellSize.height - 1),
      paint,
    );
  }

  void _paintDoubleUnderline(
    Canvas canvas,
    Offset offset,
    Color color,
    double allocatedWidth,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(
      offset.translate(0, _cellSize.height - 3),
      offset.translate(allocatedWidth, _cellSize.height - 3),
      paint,
    );
    canvas.drawLine(
      offset.translate(0, _cellSize.height - 1),
      offset.translate(allocatedWidth, _cellSize.height - 1),
      paint,
    );
  }

  void _paintWavyUnderline(
    Canvas canvas,
    Offset offset,
    Color color,
    double allocatedWidth,
  ) {
    final baseline = offset.dy + _cellSize.height - 2;
    final amplitude = (_cellSize.height / 12).clamp(1.0, 2.0).toDouble();
    final segmentWidth = (_cellSize.width / 2).clamp(3.0, 6.0).toDouble();
    final path = Path()..moveTo(offset.dx, baseline);
    var x = offset.dx;
    var waveUp = true;
    while (x < offset.dx + allocatedWidth) {
      final controlY = switch (waveUp) {
        true => baseline - amplitude,
        false => baseline + amplitude,
      };
      final nextX = (x + segmentWidth)
          .clamp(offset.dx, offset.dx + allocatedWidth)
          .toDouble();
      path.quadraticBezierTo(
        x + segmentWidth / 2,
        controlY,
        nextX,
        baseline,
      );
      x = nextX;
      waveUp = !waveUp;
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(path, paint);
  }

  void _paintDottedUnderline(
    Canvas canvas,
    Offset offset,
    Color color,
    double allocatedWidth,
  ) {
    final y = offset.dy + _cellSize.height - 1;
    final radius = (_cellSize.height / 18).clamp(0.75, 1.25).toDouble();
    final step = (radius * 4).clamp(3.0, 5.0).toDouble();
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    var x = offset.dx + radius;
    while (x < offset.dx + allocatedWidth) {
      canvas.drawCircle(Offset(x, y), radius, paint);
      x += step;
    }
  }

  void _paintDashedUnderline(
    Canvas canvas,
    Offset offset,
    Color color,
    double allocatedWidth,
  ) {
    final y = offset.dy + _cellSize.height - 1;
    final dashWidth = (_cellSize.width / 3).clamp(3.0, 6.0).toDouble();
    final gapWidth = (dashWidth / 2).clamp(1.0, 3.0).toDouble();
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    var x = offset.dx;
    while (x < offset.dx + allocatedWidth) {
      final endX = (x + dashWidth)
          .clamp(offset.dx, offset.dx + allocatedWidth)
          .toDouble();
      canvas.drawLine(Offset(x, y), Offset(endX, y), paint);
      x = endX + gapWidth;
    }
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    final color = resolveCellBackgroundColor(cellData);
    if (color == null) return;

    _backgroundPaint.color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = switch (doubleWidth) {
      true => 2,
      false => 1,
    };
    final size = Size(_cellSize.width * widthScale, _cellSize.height);
    canvas.drawRect(offset & size, _backgroundPaint);
  }

  @pragma('vm:prefer-inline')
  void paintBackgroundRun(
    Canvas canvas,
    Offset offset,
    int start,
    int end,
    Color color,
  ) {
    _backgroundPaint.color = color;
    final runOffset = offset.translate(start * _cellSize.width, 0);
    final runSize = Size(
      (end - start) * _cellSize.width,
      _cellSize.height,
    );
    canvas.drawRect(runOffset & runSize, _backgroundPaint);
  }

  /// Get the effective background color for a cell, or null when the cell uses
  /// the normal transparent terminal background.
  @pragma('vm:prefer-inline')
  Color? resolveCellBackgroundColor(CellData cellData) {
    final colorType = cellData.background & CellColor.typeMask;

    final inverse =
        (cellData.flags & CellFlags.inverse != 0) != _reverseDisplay;
    if (inverse) {
      return _resolveLogicalForegroundColor(cellData);
    }

    if (colorType == CellColor.normal) return null;

    return resolveBackgroundColor(cellData.background);
  }

  Color resolveCellForegroundColor(
    CellData cellData, {
    Color? foregroundOverride,
  }) {
    final inverse =
        (cellData.flags & CellFlags.inverse != 0) != _reverseDisplay;
    final color = foregroundOverride ??
        switch (inverse) {
          false => _resolveLogicalForegroundColor(cellData),
          true => _specialColorOverrides[_specialReverseColor] ??
              resolveBackgroundColor(cellData.background),
        };
    return color;
  }

  Color resolveSelectionForegroundColor(
    CellData cellData, {
    Color? foregroundOverride,
  }) {
    final foreground = resolveCellForegroundColor(
      cellData,
      foregroundOverride: foregroundOverride,
    );
    final cellBackground =
        resolveCellBackgroundColor(cellData) ?? backgroundColor;
    final selectedBackground = Color.alphaBlend(
      selectionColor,
      cellBackground,
    );
    if (_contrastRatio(foreground, selectedBackground) >= 1.5) {
      return foreground;
    }

    final terminalBackgroundContrast =
        _contrastRatio(backgroundColor, selectedBackground);
    final terminalForegroundContrast =
        _contrastRatio(foregroundColor, selectedBackground);
    return switch (terminalBackgroundContrast >= terminalForegroundContrast) {
      true => backgroundColor,
      false => foregroundColor,
    };
  }

  Color _resolveLogicalForegroundColor(CellData cellData) {
    final specialColor = _attributeForegroundColor(cellData.flags);
    final color =
        specialColor ?? resolveForegroundColor(_boldBrightForeground(cellData));
    if (cellData.flags & CellFlags.faint == 0) return color;
    return color.withValues(
      red: color.r * _dimColorFactor,
      green: color.g * _dimColorFactor,
      blue: color.b * _dimColorFactor,
    );
  }

  Color? _attributeForegroundColor(int cellFlags) {
    if (cellFlags & CellFlags.bold != 0) {
      final color = _specialColorOverrides[_specialBoldColor];
      if (color != null) return color;
    }
    if (cellFlags & CellFlags.italic != 0) {
      final color = _specialColorOverrides[_specialItalicColor];
      if (color != null) return color;
    }
    if (cellFlags & CellFlags.blink != 0) {
      final color = _specialColorOverrides[_specialBlinkColor];
      if (color != null) return color;
    }
    return null;
  }

  int _boldBrightForeground(CellData cellData) {
    if (!_textStyle.drawBoldTextWithBrightColors) {
      return cellData.foreground;
    }
    if (cellData.flags & CellFlags.bold == 0) {
      return cellData.foreground;
    }

    final colorType = cellData.foreground & CellColor.typeMask;
    if (colorType != CellColor.named && colorType != CellColor.palette) {
      return cellData.foreground;
    }

    final colorValue = cellData.foreground & CellColor.valueMask;
    if (colorValue > 7) {
      return cellData.foreground;
    }

    return colorType | (colorValue + 8);
  }

  Color _underlineDecorationColor(int cellFlags, Color fallback) {
    if (cellFlags & CellAttr.underlineMask == 0) return fallback;
    return _specialColorOverrides[_specialUnderlineColor] ?? fallback;
  }

  ({Color background, Color foreground}) resolveCursorColors(
    CellData cellData,
  ) {
    final inverse =
        (cellData.flags & CellFlags.inverse != 0) != _reverseDisplay;
    final cellForeground = switch (inverse) {
      true => resolveBackgroundColor(cellData.background),
      false => _resolveLogicalForegroundColor(cellData),
    };
    final cellBackground = switch (inverse) {
      true => _resolveLogicalForegroundColor(cellData),
      false => resolveBackgroundColor(cellData.background),
    };

    if (_contrastRatio(cellForeground, cellBackground) < 1.5) {
      return (
        background: foregroundColor,
        foreground: backgroundColor,
      );
    }
    return (
      background: cursorColor,
      foreground: cellBackground,
    );
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return foregroundColor;
      case CellColor.named:
      case CellColor.palette:
        return _indexedColorOverrides[colorValue] ??
            _paletteColorOrDefault(colorValue, foregroundColor);
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return backgroundColor;
      case CellColor.named:
      case CellColor.palette:
        return _indexedColorOverrides[colorValue] ??
            _paletteColorOrDefault(colorValue, backgroundColor);
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  Color _paletteColorOrDefault(int colorValue, Color defaultColor) {
    if (colorValue < 0 || colorValue >= _colorPalette.length) {
      return defaultColor;
    }
    return _colorPalette[colorValue];
  }
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = max(firstLuminance, secondLuminance);
  final darker = min(firstLuminance, secondLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}
