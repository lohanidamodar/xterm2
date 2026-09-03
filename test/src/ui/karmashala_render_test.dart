// DIVERGENCE (Karmashala): tests for the fork's render-object divergences.
// See KARMASHALA.md.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('viewport grid reconciliation', () {
    test('XTWINOPS does not latch the grid out of sync with the box', () {
      final setup = _createRenderTerminal(autoResize: true);
      final render = setup.render;
      final terminal = setup.terminal;
      final owner = PipelineOwner();

      render.attach(owner);
      final constraints = BoxConstraints.tight(Size(
        render.cellSize.width * 20,
        render.cellSize.height * 8,
      ));
      render.layout(constraints);

      expect(terminal.viewWidth, 20);
      expect(terminal.viewHeight, 8);

      // A program in the pane resizes the grid behind the render object's back.
      terminal.write('\x1b[8;3;5t');
      expect(terminal.viewWidth, 5);
      expect(terminal.viewHeight, 3);

      // The next layout must put it back: the box decides.
      render.markNeedsLayout();
      render.layout(constraints);

      expect(terminal.viewWidth, 20);
      expect(terminal.viewHeight, 8);

      render.detach();
      setup.focusNode.dispose();
    });

    test('autoResize: false still leaves the grid to its caller', () {
      final setup = _createRenderTerminal();
      final render = setup.render;
      final terminal = setup.terminal;
      final owner = PipelineOwner();

      render.attach(owner);
      final constraints = BoxConstraints.tight(Size(
        render.cellSize.width * 20,
        render.cellSize.height * 8,
      ));
      render.layout(constraints);
      terminal.write('\x1b[8;3;5t');

      render.markNeedsLayout();
      render.layout(constraints);

      expect(terminal.viewWidth, 5);
      expect(terminal.viewHeight, 3);

      render.detach();
      setup.focusNode.dispose();
    });
  });

  group('drag selection anchor', () {
    test('a drag start stays put while the view scrolls under it', () {
      final offset = _TestViewportOffset();
      final setup = _createRenderTerminal(offset: offset);
      final render = setup.render;
      final terminal = setup.terminal;
      final controller = setup.controller;
      final owner = PipelineOwner();

      render.attach(owner);
      final constraints = BoxConstraints.tight(Size(
        render.cellSize.width * 10,
        render.cellSize.height * 5,
      ));
      render.layout(constraints);

      terminal.write('one\r\ntwo\r\nthree\r\nfour\r\nfive');
      render.markNeedsLayout();
      render.layout(constraints);
      offset.jumpTo(0);

      // The drag begins on the top visible row, which is buffer line 0.
      final startAt = Offset(0, render.cellSize.height * 0.5);
      render.selectCharacters(startAt);
      expect(
        controller.selectionFor(terminal.buffer)!.normalized.begin.y,
        0,
      );

      // Five screenfuls of output arrive and the view follows the bottom, so
      // the pixel the drag started on is now over a completely different line.
      terminal.write('\r\nsix\r\nseven\r\neight\r\nnine\r\nten');
      render.markNeedsLayout();
      render.layout(constraints);
      offset.jumpTo(offset.maxScrollExtent);
      expect(offset.pixels, greaterThan(0));

      render.selectCharacters(
        startAt,
        Offset(render.cellSize.width * 2, render.cellSize.height * 4.5),
      );

      // Upstream re-derives the start from the screen position plus the
      // current scroll offset and loses everything that scrolled off the top.
      final selection = controller.selectionFor(terminal.buffer)!.normalized;
      expect(selection.begin.y, 0);
      expect(selection.end.y, greaterThan(4));

      render.detach();
      setup.focusNode.dispose();
    });

    test('a drag start evicted from scrollback clamps to the oldest line', () {
      final offset = _TestViewportOffset();
      final setup = _createRenderTerminal(offset: offset, maxLines: 8);
      final render = setup.render;
      final terminal = setup.terminal;
      final controller = setup.controller;
      final owner = PipelineOwner();

      render.attach(owner);
      final constraints = BoxConstraints.tight(Size(
        render.cellSize.width * 10,
        render.cellSize.height * 5,
      ));
      render.layout(constraints);

      terminal.write('one\r\ntwo');
      render.selectCharacters(Offset(0, render.cellSize.height * 0.5));

      // Push the anchored line out of scrollback entirely.
      for (var i = 0; i < 40; i++) {
        terminal.write('line $i\r\n');
      }
      render.markNeedsLayout();
      render.layout(constraints);
      offset.jumpTo(offset.maxScrollExtent);

      render.selectCharacters(
        Offset(0, render.cellSize.height * 0.5),
        Offset(render.cellSize.width * 3, render.cellSize.height * 4.5),
      );

      // The selection survives, truncated to the history that is left.
      final selection = controller.selectionFor(terminal.buffer);
      expect(selection, isNotNull);
      expect(selection!.normalized.begin.y, 0);

      render.detach();
      setup.focusNode.dispose();
    });
  });
}

({
  RenderTerminal render,
  Terminal terminal,
  TerminalController controller,
  FocusNode focusNode,
}) _createRenderTerminal({
  bool autoResize = false,
  int maxLines = 200,
  ViewportOffset? offset,
}) {
  final terminal = Terminal(maxLines: maxLines)..resize(10, 5);
  final controller = TerminalController();
  final focusNode = FocusNode();
  final render = RenderTerminal(
    terminal: terminal,
    controller: controller,
    offset: offset ?? ViewportOffset.fixed(0),
    padding: EdgeInsets.zero,
    autoResize: autoResize,
    backgroundOpacity: 1,
    textStyle: const TerminalStyle(fontSize: 20, height: 1),
    textScaler: TextScaler.noScaling,
    theme: TerminalThemes.whiteOnBlack,
    focusNode: focusNode,
    cursorType: TerminalCursorType.block,
    alwaysShowCursor: false,
  );
  return (
    render: render,
    terminal: terminal,
    controller: controller,
    focusNode: focusNode,
  );
}

class _TestViewportOffset extends ViewportOffset {
  double _pixels = 0;

  double maxScrollExtent = 0;

  @override
  bool get allowImplicitScrolling => false;

  @override
  bool get hasPixels => true;

  @override
  double get pixels => _pixels;

  @override
  ScrollDirection get userScrollDirection => ScrollDirection.idle;

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) async {
    jumpTo(to);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    this.maxScrollExtent = maxScrollExtent;
    return true;
  }

  @override
  bool applyViewportDimension(double viewportDimension) {
    return true;
  }

  @override
  void correctBy(double correction) {
    _pixels += correction;
  }

  @override
  void jumpTo(double pixels) {
    _pixels = pixels;
    notifyListeners();
  }
}
