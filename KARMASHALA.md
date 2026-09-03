# Karmashala's fork of xterm2

This is [PopupBits/Karmashala](https://github.com/lohanidamodar)'s fork of
[SoFluffyOS/xterm2](https://github.com/SoFluffyOS/xterm2). It exists to carry
five changes that upstream has not made, on a branch that can be rebased onto
upstream whenever upstream moves.

- **Upstream:** `https://github.com/SoFluffyOS/xterm2`, branch `master`
- **Branched from:** `2a339558ba103e38a304a4eda7c984b45c47e186`
  ("fix(terminal): pass global position to auto-scroller in TerminalView drag
  selection", 2026-08-06). That commit is 50 ahead of the last published tag,
  `5.2.0`; `pubspec.yaml` claims `5.3.0`, which was never tagged or published.
- **Our branch:** `karmashala`

Consume it with:

```yaml
dependencies:
  xterm2:
    git:
      url: https://github.com/lohanidamodar/xterm2.git
      ref: karmashala
```

Pin `ref` to a commit SHA rather than the branch name if you want a build to be
reproducible.

## Finding the divergences

Every change to upstream code carries a `DIVERGENCE (Karmashala)` comment:

```
grep -rn 'DIVERGENCE (Karmashala)' lib/ test/
```

Nothing else differs from the base commit. **Keep it that way** — a new
divergence must be listed in the table below, marked in code, and justified.

## What we changed

| # | File | Change |
| - | ---- | ------ |
| 1 | `lib/src/ui/render.dart` | `_updateViewportSize` reconciles against the terminal's actual grid, not only against its own cache. |
| 2 | `lib/src/ui/render.dart` | A drag selection's start is held as a `CellAnchor`, not re-derived from a screen position on every update. |
| 3 | `lib/src/ui/painter.dart` | `paintLineForegrounds` batches runs of same-styled text into one `Paragraph`, with a per-frame layout budget. |
| 4 | `lib/ui.dart` | Exports `TerminalPainter` and `RenderTerminal`. |
| 5 | `lib/src/utils/circular_buffer.dart` | `_adoptChild` / `_moveChild` do not detach an item that has already been re-homed elsewhere. |

Each is one commit, on purpose: five focused commits rebase onto a moving
upstream far better than one squashed blob, and that is the whole point of
maintaining this as a fork rather than a vendored copy.

### 1. XTWINOPS grid latch (`render.dart`)

`_updateViewportSize` compared the grid it computed from the box only against
`_viewportSize` — a cache of what the render object last *sent* to
`Terminal.resize`. But `CSI 8 ; rows ; cols t` (XTWINOPS) reaches
`Terminal.resize` straight from the escape parser, so a program running in the
pane can change the grid without the render object being involved. Once the two
disagree the cache latches: it reports "already sent that" forever, and the pane
is painted in one grid while its buffer and its PTY believe another, until the
box happens to change by a whole cell.

Now `_terminalHasViewportSize` compares the terminal's actual grid too, floored
at 1x1 the way `Terminal.resize` stores it. `autoResize: false` still sends
nothing. Cost: two int comparisons per layout.

### 2. Drag anchor (`render.dart`)

`TerminalGestureHandler` passes the screen position a drag *began* at on every
update (`_updateDragSelection`, `onLongPressMoveUpdate`), and `selectCharacters`
/ `selectWord` / `selectLine` fed it back through `getCellOffset`, which adds the
**current** scroll offset. So as soon as the buffer moved under the pointer, the
start of the selection slid onto a different line and everything that had already
scrolled off the top fell out of it. Dragging over a build log while it was still
printing selected the last screen, not what you dragged over.

The start is now held as a `CellAnchor` (`_dragAnchor`), which the buffer keeps
pinned to its line across scrolls and reports detached once scrollback evicts it
— in which case the start is clamped to the oldest surviving line rather than the
selection being dropped. Every entry point with a null `to` re-anchors; that is
exactly the gesture handler's "drag begins here". Released in `dispose`.

This one was **reworked, not ported**: upstream restructured selection around
`_cellSelectionStart` / `_cellSelectionEnd` and grew a `selectLine`, so the
anchor is threaded through the new shape.

### 3. Run-batched foreground painting (`painter.dart`)

The big one, and the reason the fork exists. Upstream lays out and draws one
`Paragraph` per visible cell; on a 200x50 viewport that is 10 000
`drawParagraph` calls on every frame, including the frames where nothing
changed. Consecutive cells that share a style are now drawn as a single
paragraph.

Measured in `test/src/ui/karmashala_run_batching_test.dart`'s harness, 200x50,
`ls --color`-shaped content:

| | per cell (upstream) | run-batched |
| - | - | - |
| settled screen, caches warm | 2.4–2.6 ms/frame | **0.6–0.7 ms/frame** |
| streaming fresh text | 2.9 ms/frame | 4.1–4.3 ms/frame |
| draw calls, settled screen | ~10 000 | ~400 |

**What may join a run.** Only cells that take `paintCellForeground`'s plain
"draw the cached glyph at the cell origin" path, because a run has to rasterise
exactly as the per-cell loop would. Everything else there is per-cell and breaks
the run — see `_isBatchable`:

- `charWidth != 1` — a double-width glyph's advance is not guaranteed to be
  `2 * cellWidth`, and a zero-width continuation composes with the glyph before
  it.
- anything outside printable ASCII (`0x20`–`0x7e`). That excludes, by
  construction and without a separate test for each, every procedural glyph
  (`procedural_glyphs.dart` starts at `0x00b0`), every box and branch glyph
  (`branch_glyphs.dart`), blank braille, everything `glyphConstraintCellSpan`
  widens (`_isSymbolLike` starts at `0x2190`), the empty cell and the tab — and
  it keeps runs clear of contextual shaping and of font fallback, neither of
  which composes glyph by glyph.
- any underline style (solid, double, wavy, dotted, dashed), strikethrough,
  overline, framed or encircled. Wavy, dotted and dashed restart their pattern at
  each cell origin, so a run would draw a *different* line; double underline and
  the frame box are drawn per cell around `allocatedWidth`.
- `invisible`, and `blink` in either state.
- the *active* hyperlink, drawn underlined and with its own cache key.
- combining marks, which compose with the glyph before them.
- the cursor cell, whose foreground is overridden and selection contrast
  suppressed.

Two batchable cells then join only if foreground, background and *visual* flags
match, which is exactly what `resolveCellForegroundColor` and
`resolveSelectionForegroundColor` read. Semantic and protection bits are masked
out so a prompt is not split from its output for no visual reason.

This is deliberately **narrower** than the same optimisation was on xterm 4.0.0,
which had none of the procedural glyphs, underline styles, hyperlinks or
combining marks to respect. Correct and narrower beats fast and wrong, and what
remains — plain single-width text — is what a terminal spends its frames drawing.
Spaces stay inside runs (an undecorated space paints nothing and advances one
cell) but are trimmed off both ends, and an all-space run is skipped entirely.

**The safety property** is that a string of printable ASCII lays out at exactly
one cell width per character. That is measured, not assumed: `_measureCharSize`
lays out a 189-character probe (with the space in the interior, so no trailing
whitespace is involved) and turns batching off for a style where it does not
hold. A proportional font therefore falls back to upstream's clipped per-cell
drawing rather than shearing every glyph after a wide one.

**Layout budget.** A cache keyed on a run's text cannot hit on text a terminal
has never printed, and printing text it has never printed is what a terminal
does. Unbudgeted, the streaming corpus produces ~438 runs a frame at ~25 us to
lay one out, ~11 ms a frame — and 15.6 ms of a 16.7 ms frame when it was measured
on xterm 4.0.0. So `TerminalPainter.beginFrame`, called from
`RenderTerminal._paint`, refills a budget of `maxRunLayoutsPerFrame` (48), and
runs past it are painted cell by cell out of the per-cell cache, which hits
essentially always. The budget caps the streaming cost and the screen converges
to fully batched as soon as it settles. **If `beginFrame` ever stops being
called, the painter batches its first screenful and then falls back forever** —
which is why `RenderTerminal.painter` is exposed for a test to check.

**ParagraphCache sizes.** `_defaultParagraphCacheSize` goes back to **10240**
from upstream's 2048, and `_defaultRunCacheSize` is a separate **10240**. This is
a decision, not an oversight: the per-cell cache is now the floor the layout
budget falls onto, and sized below the screen's working set it thrashes and
re-lays out every frame, turning the fallback from a saving into a pessimisation
(measured on 4.0.0: a 4096-entry cache made the adversarial corpus 4x *slower*
than not batching). The two caches are separate so runs and cells cannot evict
one another. Entries are disposed on eviction, so the ceiling is bounded, and
both are still constructor parameters.

Pinned by `test/src/ui/karmashala_run_batching_test.dart`, which rasterises a
viewport of colours, all five underline styles, strikethrough, overline, framed
and encircled cells, box drawing, braille, CJK, combining marks, hyperlinks,
blinking and invisible text **both ways** and requires the bytes to match — with
the layout budget both intact and exhausted.

### 4. Exports (`lib/ui.dart`)

`TerminalPainter` and `RenderTerminal` are package-private in upstream's public
surface. Karmashala's performance harness drives the painter directly, reads its
counters and rasterises viewports with it, and needs the render object to prove
`paint` still calls `beginFrame`. Exporting them made upstream's own
`painter_test.dart` and `render_test.dart` import `src/` redundantly, so those
two imports were dropped.

### 5. Alias-safe detach (`circular_buffer.dart`)

`Buffer._scrollUpFullWidth` and `_scrollDownFullWidth` move lines by assigning
`lines[i] = lines[i +/- count]`, so between iterations a single line object is
referenced from **two** slots. Detaching whatever occupied a slot before writing
over it detached those aliases while they were still live at their new index, and
the next `insert` asserted `attached` on one of them — real Codex TUI output
tripped it after 2 304 bytes.

`_isHomedAt` asks the outgoing occupant where it thinks it lives and checks that
slot actually holds it, which separates eviction from aliasing exactly.
`_moveChild` also uses `_attach` rather than `_move`, because `_move` asserts the
item is already attached and an alias reaching it need not be. `_move` is kept,
unused, so upstream's shape stays recognisable across a rebase.

Upstream narrowed the exposure — the margin path now uses `copyFrom` — but the
full-width fallback still aliases. Pinned by two tests in
`test/src/utils/circular_buffer_test.dart` that fail without the fix.

## What we dropped, because upstream fixed it properly

These were divergences in Karmashala's older vendored fork of TerminalStudio
`xterm` 4.0.0. **Do not re-apply them.**

- **`highlight(underline:)` on `TerminalController`.** Superseded by xterm2's
  native `TerminalController.underline({p1, p2, color})` / `TerminalUnderline`,
  wired through `RenderTerminal._paintUnderlines`. Callers that used
  `controller.highlight(..., underline: true)` for a Ctrl+hover link affordance
  should call `controller.underline(...)` instead.
- **`parser.dart` `_csiHandleSgr` prefixed-CSI bail.** Upstream now handles
  `CSI > Ps ; Ps m` as `setModifyOtherKeysMode` and bails on
  `_csi.prefix != null || intermediates.isNotEmpty`, so a `modifyOtherKeys`
  probe is no longer misread as SGR and no longer leaves the pane underlined and
  faint.
- **`byte_consumer.dart` `_toRunes` `Uint32List` fast path.** `ByteConsumer` was
  rewritten to be `codeUnitAt`-based with no `runes.toList()`, so the old fast
  path is obsolete. Worth re-benchmarking the new implementation at some point,
  but not worth carrying the old patch.

Packaging-only edits from the vendored era (`publish_to: none`, dropped
dev-dependencies, a permissive `analysis_options.yaml`, deleted `example/`,
`bin/`, `script/`, `media/` and `test/`) are also gone. A consumed GitHub fork
should keep upstream's files intact.

## Rebasing onto a newer upstream

```sh
git remote add upstream https://github.com/SoFluffyOS/xterm2.git   # once
git fetch upstream
git checkout karmashala
git rebase upstream/master
```

Five commits will replay. Expect conflicts in `painter.dart` above all — it is
the file upstream changes most and the file we changed most. When one lands:

1. **Re-derive, do not re-apply.** Especially for divergence 3: the question is
   never "how do I make my hunk apply" but "what per-cell concerns does
   `paintCellForeground` have *now*, and does `_isBatchable` still break the run
   on every one of them?" A new underline style, a new procedural glyph range, a
   new per-cell override, a new argument to `paintCellForeground` — each is a new
   reason a run must break, and none of them will announce itself as a conflict.
2. **Check `beginFrame` is still called** from `RenderTerminal._paint`, and that
   `paintLineForegrounds` is still where the per-line foreground loop lives.
3. **Run the pinning tests.** Every divergence except the exports has one, and
   each has been checked to fail against the base commit:
   `test/src/ui/karmashala_run_batching_test.dart` (divergence 3 — proves the
   batched painter and the per-cell painter rasterise identically),
   `test/src/ui/karmashala_render_test.dart` (divergences 1 and 2), and the
   `alias-safe detach (Karmashala)` group in
   `test/src/utils/circular_buffer_test.dart` (divergence 5). If the
   pixel-equivalence test fails, the batcher is merging something it must not.
4. **Drop anything upstream has fixed**, and record it in the section above.
5. Then `flutter analyze` and `flutter test`.

### Known baseline

At the base commit, on this toolchain:

- `flutter analyze` reports 5 pre-existing `analysis_options_deprecated_plugins`
  warnings (the `dart_code_metrics` legacy analyzer plugin, in the package's and
  the example's `analysis_options.yaml`). Our branch adds none.
- `flutter test` is `+742 ~2 -2`. The two failures,
  `TerminalView.textScaler works` and
  `TerminalView.textScaler can obtain textScaler from parent`, are pre-existing.
  Our branch is `+755 ~2 -2` — same two failures, thirteen added tests.

Note that `flutter analyze` rewrites `analysis_options.yaml` (it adds `exclude:`
entries); `git checkout -- analysis_options.yaml example/analysis_options.yaml`
after running it.
