# Karmashala's fork of xterm2

This is [PopupBits/Karmashala](https://github.com/lohanidamodar)'s fork of
[SoFluffyOS/xterm2](https://github.com/SoFluffyOS/xterm2). It exists to carry
the changes upstream has not made, on a branch that can be rebased onto
upstream whenever upstream moves. Fourteen of the sixteen numbered divergences
still change code; 5 and 7 went when upstream fixed them.

- **Upstream:** `https://github.com/SoFluffyOS/xterm2`, branch `master`
- **Branched from:** `da7e1c4a0ca71398a08ecd0eaade8ca21e52eb80` ("fix(core):
  keep wrapped rows joined when a line is erased", 2026-10-23). That commit is
  two ahead of tag `5.4.0`; `core/` is `xterm2_core` 1.0.0, unreleased changes
  included.
- **Our branch:** `karmashala-5.4`. The older `karmashala` branch stays as it
  is, on `0f8f42da5`: every Karmashala release up to 1.34.17 pins it, so it must
  stay reachable. It is never force-pushed or moved.

Consume it with:

```yaml
dependencies:
  xterm2:
    git:
      url: https://github.com/lohanidamodar/xterm2.git
      ref: <commit SHA of karmashala-5.4>
```

Pin `ref` to a commit SHA, not the branch name, so a build is reproducible.
`xterm2_core` needs no line of its own: divergence 16 makes `xterm2` depend on
it by `path: core`, so pub takes it from the same commit (`source: git`,
`path: core` in `pubspec.lock`) and never from pub.dev, whose copy has none of
the divergences below.

## Finding the divergences

Every change to upstream code carries a `DIVERGENCE (Karmashala)` comment:

```
grep -rn 'DIVERGENCE (Karmashala)' lib/ test/ core/lib/ core/test/
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
| 6 | `lib/src/ui/painter.dart` | `paintCellForeground` condenses an overflowing complex-script cluster into its cells instead of clipping its right-hand side off. |
| 8 | `core/lib/src/core/input/kitty_handler.dart` | Functional keys are encoded by the kitty protocol on every event type, not only on a repeat or a release, so cursor key mode, `SS3` F1-F4, `CSI R` for F3 and the lock and super modifiers stop leaking into a pane that enabled the protocol. |
| 9 | `core/lib/src/core/buffer/line.dart` | `resize` blanks the cells a narrower length cuts off, so they cannot come back beside newer text when the line widens again. |
| 10 | `core/lib/src/core/buffer/buffer.dart` | `EL 2` and `ED 0` from column 0 still end the row's own link to the row above, which upstream's rule keeps, so an inline TUI's new text is not glued to the history above it. |
| 11 | `core/lib/src/core/buffer/buffer_resize.dart` | Shrinking the height keeps rows below the cursor that hold text, scrolling the top into scrollback instead, so an inline TUI's relative redraw still lands on the rows it drew. |
| 12 | `core/lib/src/core/buffer/buffer_resize.dart`, `core/lib/src/core/reflow.dart` | A width change does not reflow the live area — from a cursor parked at column 0 downward, or below the line being written — so an inline TUI's full-width rows keep their row count and its redraw erases all of them. |
| 13 | `core/lib/src/core/buffer/line.dart`, `core/lib/src/core/reflow.dart` | A live-area row cut by a narrowing gets its cells back when the width grows again, unless the program repainted it meanwhile, so a resize that ends where it began is lossless. |
| 14 | `lib/src/ui/painter.dart` | Faint (SGR 2) text fades towards the terminal background instead of being multiplied towards black, so dim text is dimmer on a light ground too, not darker. |
| 15 | `core/lib/src/core/buffer/buffer.dart`, `core/lib/src/terminal.dart`, `core/lib/src/core/state.dart` | With `Terminal.indicClusterWidthFromBase` set, an Indic grapheme cluster keeps its first code point's width instead of widening to two cells, matching `string-width`. Off by default. |
| 16 | `pubspec.yaml` | `xterm2` depends on `xterm2_core` by `path: core`, not `^1.0.0`, so a git consumer gets the core of the same commit. |

Each is one commit, on purpose: focused commits rebase onto a moving
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

Those are the 2026-09 numbers. Re-measured after the 5.4 rebase with Karmashala's
`app/tool/benchmark/paint_bench.dart` and `paint_stream_bench.dart`, 200x50,
Windows, the old pin (`0f8f42da5`) and this branch run one after the other on one
machine (medians, one run each):

| | old pin | 5.4 |
| - | - | - |
| settled, batched: `plainLog` | 156 us | 163 us |
| settled, batched: `colorizedLs` | 585 us | 565 us |
| settled, batched: `tuiFrame` | 257 us | 276 us |
| settled, batched: `adversarial` | 6989 us | 6065 us |
| per cell: `plainLog` | 1988 us | 1099 us |
| per cell: `colorizedLs` | 4556 us | 3464 us |
| streaming plain, 50 lines a frame | 2669 us | 2611 us |
| streaming colour, 50 lines a frame | 6098 us | 5394 us |
| fling, 12 lines a frame | 758 us | 806 us |
| animated TUI | 1952 us | 2049 us |

The settled screen is level within a run's noise. The per-cell floor improved
because of upstream's `plainAscii` path and its O(1) `ParagraphCache` recency,
which both reach our batcher's fallback untouched. `plainAscii` needed no change
to `_isBatchable`: it only short-cuts cells that already draw the cached glyph
at the cell origin.

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

### 6. Complex-script glyph fitting (`painter.dart`)

A terminal gives a grapheme a whole number of cells and a monospace advance. A
Devanagari syllable comes back from a *proportional* fallback font at whatever
width its shaping produced, and the two do not agree.

The buffer model is not the problem, and a test pins that
(`karmashala_complex_script_test.dart`): `graphemeClusterMode` defaults on, and
`Buffer._joinsPreviousGrapheme` already implements Unicode 15.1's GB9c
Indic-conjunct rule, so `नमस्ते` is stored exactly right — `न` and `म` in one
cell each and the conjunct `स्ते` as **one** two-cell grapheme with `्ते` as its
combining characters.

The painter was the problem. Measured at 14 px with Consolas as the primary
(cell 7.70 px) and Windows' own Devanagari fallbacks:

| cluster | cells it holds | Nirmala UI | Mangal |
| - | - | - | - |
| `न` | 1 | 1.10 | 1.23 |
| `म` | 1 | 1.22 | 1.33 |
| `का` | 2 | 2.04 | 1.90 |
| `न्दी` | 2 | 2.14 | 2.47 |
| `स्ते` | 2 | 1.88 | 2.25 |
| `र्य` | 2 | 1.13 | 1.23 |

Upstream draws such a cell and clips it to `glyphClipWidth`, so **every bare
consonant loses the right 10-33% of itself**. In Devanagari that is not
cosmetic: the right-hand vertical stem *is* the letter. A clipped `क` reads as
`व`, `झ` as `इ`, `छ` as `ङ`. The text is not ugly, it is *wrong*.

`_horizontalSqueeze` condenses the cluster by that same 10-33% instead, so every
letter is drawn whole and stays inside its own cells. It is scoped to the Indic
blocks `Buffer._isIndicCodePoint` already knows (plus Devanagari Extended and
the Vedic Extensions), so the buffer's idea of what forms a cluster and the
painter's idea of what to condense agree. Symbols, emoji and box drawing
overflow too and are deliberately **left alone** — `glyphConstraintCellSpan`
already lets those overhang a blank neighbour, and nobody complained about them.

**Why not extend `glyphConstraintCellSpan` instead.** That widens a glyph's
clip into the *next* cell, and only when the next cell is empty or a space.
Devanagari is a dense run of occupied cells, so it would fire only on the last
syllable of each word — rendering that one syllable at full width beside three
chopped ones, which is worse than uniform condensation, not better. It cannot
help a glyph whose neighbour is another glyph, which is the case that matters.

**Cost.** Nothing on the common path, and this is counted rather than timed.
Printable ASCII either never reaches `paintCellForeground` (it is batched) or
fits its cell and returns before the clip branch, so the new code is
*unreachable* for it. Canvas-op counts over Karmashala's frozen 200x50 corpora
are byte-identical before and after — `plainLog` 50 draw ops, `colorizedLs` 920,
`tuiFrame` 198, `adversarial` 10 000, and `scale`/`translate` zero on all four.
A screenful of nothing but Devanagari gains exactly two canvas *state* ops per
condensed cluster (`scale` and `translate` 0 → 2000) and **no** draw calls
(`drawParagraph` stays 4 600, `save`/`clipRect` stay 2 000 — those cells were
already being clipped). Interleaved best-of-five medians for that all-Devanagari
frame: 3.40 ms before, 3.77 ms after, about +11% on content a terminal never
actually shows a whole screen of.

**What is still wrong.** A syllable narrower than the two cells the shell counts
for it — `र्य` at 1.13 cells — is drawn at its natural width and leaves the rest
of its second cell blank, so Devanagari words look loosely spaced. That is the
column accounting, not the painter: the shell counts `का` as two columns too, so
narrowing it would desynchronise the grid. Windows Terminal has the same gaps.

### 7. Blank cells copy as spaces: test only, upstream does it now

Upstream's `getText` writes a blank cell as a space, keeps a tab's cells elided
and drops the empty tail, which is this divergence's behaviour. The code went
in the 5.4 rebase; `core/test/src/core/buffer/karmashala_copy_spacing_test.dart`
stays to pin it, because a copy with its spaces deleted is what we forked this
for. Its wrapped-tail test blanks with `ECH` now: upstream's `EL` ends the
logical line at that row, on purpose.

### 8. Kitty functional keys (`kitty_handler.dart`)

`KittyKeyboardInputHandler` answered for a functional key only on a *repeat* or
a *release*, leaving every press to `KeytabInputHandler`. That looks free —
kitty's encoding of an unmodified cursor key is byte-for-byte the legacy one,
because `serialize` omits a key number of `1` and omits the parameter list with
it — but the keytab answers from terminal state the protocol says to ignore, and
from a modifier set it cannot express. Measured against kitty's own encoder
(`kitty/key_encoding.c`, `encode_function_key`) and the two tables in its
`keyboard-protocol` document, four things were wrong the moment any enhancement
was on:

| key | keytab (before) | kitty |
| - | - | - |
| `End`, cursor key mode on | `ESC O F` | `ESC [ F` |
| `F1` | `ESC O P` | `ESC [ P` |
| `F3` | `ESC O R` / `ESC [ 1;2 R` | `ESC [ 13 ~` / `ESC [ 13;2 ~` |
| `End`, num lock on | `ESC [ F` | `ESC [ 1;129 F` |
| `Right`, super held | `ESC [ C` | `ESC [ 1;9 C` |

`encode_function_key` reaches the `SS3` forms only when `legacy_mode` — no
*disambiguate*, no *report event types*, no *report all keys* — so under the
protocol they are unreachable, and F1-F4 lose `SS3` with them. F3 is `CSI 13 ~`
because `CSI R` is a cursor position report; the spec removed the `CSI R` form
for exactly that collision. And `convert_glfw_mods` masks caps lock and num lock
off *only* when the flags are zero, so the locks are part of a functional key's
modifier value under the protocol, while the keytab's `*` substitution stops at
ctrl+alt+shift and drops super entirely.

This commit used to add kitty's release gate as well. Upstream has it now
(`adabf90`), and omits private-use key codes unless *report all keys* is on
(`e3bcbe1`), so under flag 1 alone F13-F24 and the keypad fall through to the
keytab. Only the functional keys are still ours.

**With no modifiers, no locks and cursor key mode off the bytes are unchanged**,
which is the point: `ESC [ C` for `Right` and `ESC [ F` for `End` in kitty mode
and out of it alike. `core/test/src/core/input/handler_test.dart`'s
`KittyKeyboardInputHandler functional keys` group pins both halves — what kitty
sends under flags 7, and the full legacy set byte for byte with the flags at 0,
in and out of cursor key mode.

### 9. A narrowed line forgets what it lost (`line.dart`)

`BufferLine.resize` to a shorter length only lowered `_length`. The cells past
it stayed in `_data`, whose capacity never shrinks, and nothing could reach them
any more: every erase (`EL`, `ED`, `ECH`) stops at the line's length. Growing the
line back raised `_length` over them again, so they reappeared — beside whatever
the row had come to hold in the meantime.

That is invisible while nothing writes to the row between the two resizes, and
upstream pinned it as a feature for `reflowEnabled: false` ("preserves hidden
cells"). A TUI that repaints on `SIGWINCH` writes to the row every time. Drag a
divider narrower and wider under a coding agent and the agent erases and
repaints its region at each width; the rows it repainted while narrow kept the
tail of what they held while wide. On the screen the next repaint covers it. In
the scrollback nothing ever repaints, so the debris was permanent:

```
What's wrong in your screenshot:                          -Fi pairing.
   - Android rows use a text link ...     It must fail on the current layout first.   /rc
```

Reflow does not need the hidden cells — when a line narrows, the overflow is
copied onto the next row *before* the line is shortened — so they were only ever
a second, stale copy.

`resize` now zeroes the cells between the new length and the old one, and drops
the combining characters and underline colours recorded for them. The invariant
is the one xterm.js keeps: nothing past a line's length holds content. Cost: one
`fillRange` over the cells cut off, only when a line actually narrows; a 10 000
row x 200 column reflow measures the same before and after (about 22 ms to
narrow, 5 ms to widen, on an M-series laptop).

Two upstream tests asserted the old behaviour and now assert the new one, each
marked: `BufferLine.resize` "forgets hidden combining characters across shrink
and grow" in `core/test/src/core/buffer/line_test.dart`, and `Terminal.reflowEnabled`
"truncates at the narrower width when reflow is disabled" in
`core/test/src/terminal_test.dart`. With reflow off, narrowing now truncates for
good, as xterm and xterm.js do.

**Not changed, and worth knowing:** narrowing a buffer whose cursor has blank
rows under it still scrolls the top row out rather than using those blank rows
up, which xterm.js avoids. A TUI cannot reach a row once it is in the
scrollback, so that row stays as the old width left it.

### 10. EL 2 and ED 0 end a row's link to the row above (`buffer.dart`)

`BufferLine.isWrapped` says a row continues the one above it, and reflow joins
rows by it. There are two ways to get this wrong, and each has a real program
behind it.

**Clear the flag on every erase**, as upstream did until `da7e1c4`, and a row
repainted as `text ESC[K` falls off its logical line. Windows ConPTY repaints
its whole screen that way after every `ResizePseudoConsole`, so every
soft-wrapped line lost its last row and history could never unwrap. zsh's
`CR EL` redraw of a long command broke the same way. Upstream now keeps the
flag on `EL` and clears the *next* row's instead ("erasing ends the line at that
row"), which is xterm's rule and covers both.

**Keep the flag on every erase**, as that rule does, and an inline TUI suffers.
Ink erases its region with `CSI 2K`, and a TUI clears with `CR ESC[J`. Each then
writes a new line onto a row that is still flagged, and the next reflow glues it
to the history above: `emulator stWhat's wrong in your screenshot:`.

So we take upstream's rule for `EL 0` and `EL 1`, the zsh and ConPTY shapes, and
keep clearing the row's own flag where the whole row is gone: `EL 2`, and `ED 0`
from column 0. `EL 0` from column 0 stays linked, because that is exactly zsh's
`CR EL` and the bytes cannot tell it from a TUI's. A TUI that erases with `CR EL`
and writes a new line keeps the glue.

Pinned by `core/test/src/core/karmashala_erase_keeps_wrap_test.dart`, which
replays the ConPTY repaint through narrow, scroll, widen and narrow again, and
by the `stale cells` group in `karmashala_resize_scrollback_test.dart`, whose
first two tests fail without this. Upstream's own tests pass unchanged.

### 11. Shrinking the height keeps what is drawn below the cursor (`buffer.dart`)

Upstream's `resize` shrank a screen by popping rows off the bottom whenever the
cursor was not already on them, whatever they held. An inline TUI parks its
cursor at the top of its live region and draws the rest *below* it — Claude
Code's is about thirteen rows — and redraws relatively: `CSI n B` to the
region's last row, `CSI 2K CSI 1A` up it, the new frame, `CSI n A` back
(captured from a Karmashala agent pane's host recording, 2026-09-24). With the
region's lower rows popped, `CSI n B` clamps at the new bottom, the erase climbs
into the history above, and the old frame's top survives beside the new one:
duplicated lines, a prompt in the wrong place, history rows gone. The same
pane's resize log flipped between 49, 50 and 54 rows twenty times at one output
offset, so it compounded.

A row below the cursor that holds text now stays, and the cursor moves up
instead, which scrolls the top row into scrollback; growing back already pulls
rows back out of scrollback, so a shrink and a grow now undo each other. A
blank row is still dropped, and so is a row when the cursor is on the top row
and cannot move up. The saved cursor moves with the cursor. The alternate
screen is unchanged: it holds exactly one screen, and a full-screen program
redraws all of it on `SIGWINCH` anyway.

Pinned by `core/test/src/core/karmashala_shrink_keeps_rows_test.dart`, which replays
that redraw after a shrink, after a shrink and grow, and through the logged
flip-flop. All three fail without the change.

The code now lives in `buffer_resize.dart`, upstream's new home for `resize`.
The saved cursor moves only when `reflowMain` holds, as upstream's own grow does.

### 12. A width change leaves the live area's rows where they are (`buffer.dart`, `reflow.dart`)

Claude Code draws its input box as rows exactly as wide as the screen and
parks the cursor at column 0 atop its region. After a resize it erases the
number of rows it drew and draws again. Reflow wrapped each full-width row
onto a second row when the screen narrowed, so the erase fell a row short per
rule and the overflow stayed: a `────` fragment under every rule and a stale
status row below the box (a Karmashala agent pane, 2026-09-24).

`reflow` takes a `keepFrom` row; from it on, lines keep their rows and are only
cut to the new width. `Buffer.resize` passes the cursor's row when the cursor is
at column 0 on a row that does not continue the one above, which is where an
inline TUI parks it. Anywhere else the cursor is writing text, and that line
still reflows, so the live area starts below it; every upstream reflow test
writes a line and resizes with the cursor at its end, and all of them still
pass. History above the live area reflows as before. The cut cells are blanked
(divergence 9), which is right for a region its program redraws and costs a
plain shell only the rows below its prompt, which are empty.

Pinned by `core/test/src/core/karmashala_live_area_keeps_rows_test.dart`. Its
narrowing case fails without the change; widening never joined hard rows, and
the third case holds history's reflow in place.

### 13. A live-area row gets back what a narrowing cut (`line.dart`, `reflow.dart`)

Divergence 12 keeps the live area's rows and cuts them to the new width, and
divergence 9 blanks what a cut removes. Together that lost the cells for good.
Claude Code's renderer writes only what changed against its model of the
screen, and after a resize that ends where it began it writes nothing: a host
recording on 2026-09-24 went 124 → 93 → 61 → 124 columns and then carried only
keyboard-mode resets. The input box's lower rule stayed 61 cells wide. A native
terminal's reflow is lossless on that round trip; this was not.

`BufferLine.resizeKeepingTail` stashes the row's cells the first time a
narrowing cuts it, at the widest width seen. A widening copies the stashed tail
back when the cells still showing are exactly the stashed ones, and drops the
stash otherwise or once the row is whole again. A row the program repainted
while narrow no longer matches, so divergence 9's guarantee holds: nothing
stale reappears beside new text. `reflow` uses it for the kept rows only.
Underline colours are not stashed.

Pinned by the round-trip cases in
`core/test/src/core/karmashala_live_area_keeps_rows_test.dart`; two of them fail
without the change, and the third holds divergence 9's guarantee.

### 14. Faint text fades towards the background (`painter.dart`)

Upstream multiplies a faint foreground by a constant, which is towards black.
On a light ground that made dim text darker, so it read as emphasis. It now
blends towards the terminal's background, so dim is dimmer on either ground.
Pinned in `test/src/ui/painter_test.dart`.

### 15. Indic clusters measured from their base (`buffer.dart`, `terminal.dart`)

Claude Code is laid out with `string-width`, which splits text with
`Intl.Segmenter` and gives each grapheme cluster the width of its first code
point: `का` is 1, `मेरो नेपाली` is 6. Grapheme cluster mode here widens an Indic
cluster to two cells as soon as a joining code point of width > 0 arrives, so
the same text is 2 and 9. Every Devanagari line was wider than Claude's model
of the screen, and its differential redraws — typing, scrolling, Ctrl+L,
resizing — landed in the wrong columns (2026-09-30).

`Terminal.indicClusterWidthFromBase` (off by default, not a DEC mode) makes
`Buffer.writeChar` join such a code point to the cluster as a combining
character, leaving the cluster's width alone. It stays off for everything
else: a shell's readline and Codex (Rust `unicode-width`) count per code point,
which the default rule matches. The host decides per pane.

Pinned by `core/test/src/core/karmashala_indic_width_test.dart`, whose widths are
what `string-width` reports under Bun 1.4 and Node.

### 16. `xterm2_core` by path (`pubspec.yaml`)

Upstream's `xterm2` depends on `xterm2_core: ^1.0.0`. Consumed from git that
resolves to pub.dev's copy, which is the stock terminal model: none of the
divergences above would be running, and nothing would fail to say so. A relative
path inside a git dependency resolves to the same repository at the same commit,
so `path: core` is all it takes, and every consumer is right without an override.
Checked by reading `pubspec.lock` in a consumer: `source: git`, `path: core`, one
`resolved-ref` for both packages. It would have to go before publishing, which
this fork never does.

## What we dropped, because upstream fixed it properly

**Do not re-apply these.** From the 5.4 rebase:

- **Divergence 5, alias-safe detach.** `Buffer` moved rows by assigning
  `lines[i] = lines[i +/- count]`, so one line sat in two slots and the next
  `insert` asserted. Upstream moves them with `lines.swap` now (`6058682`), in
  all four places, so nothing aliases and there is nothing to guard.
- **Divergence 7, blank cells copy as spaces.** Upstream's `getText` does it. The
  pinning test stays.
- **The kitty release gate in divergence 8.** Upstream's `adabf90`.
- **Most of divergence 10.** Upstream's `da7e1c4` covers `EL 0` and `EL 1`.

From Karmashala's older vendored fork of TerminalStudio `xterm` 4.0.0:

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
git checkout -b karmashala-<version> karmashala-5.4
git rebase upstream/master
```

Rebase onto a **new branch**: a Karmashala release pins each old head, so none of
them may move. Set `merge.directoryRenames` to `true` if a move is in play. Expect
conflicts in `painter.dart` above all — it is the file upstream changes most and
the file we changed most. When one lands:

1. **Re-derive, do not re-apply.** Especially for divergence 3: the question is
   never "how do I make my hunk apply" but "what per-cell concerns does
   `paintCellForeground` have *now*, and does `_isBatchable` still break the run
   on every one of them?" A new underline style, a new procedural glyph range, a
   new per-cell override, a new argument to `paintCellForeground` — each is a new
   reason a run must break, and none of them will announce itself as a conflict.
2. **Check `beginFrame` is still called** from `RenderTerminal._paint`, and that
   `paintLineForegrounds` is still where the per-line foreground loop lives.
3. **Run the pinning tests.** Every divergence except the exports and the
   packaging has one:
   `test/src/ui/karmashala_run_batching_test.dart` (divergence 3 — proves the
   batched painter and the per-cell painter rasterise identically),
   `test/src/ui/karmashala_render_test.dart` (divergences 1 and 2),
   `test/src/ui/karmashala_complex_script_test.dart` (divergence 6, and the
   buffer clustering it rests on),
   `core/test/src/core/buffer/karmashala_copy_spacing_test.dart` (divergence 7),
   `core/test/src/core/karmashala_resize_scrollback_test.dart` (divergences 9
   and 10), `core/test/src/core/karmashala_erase_keeps_wrap_test.dart`
   (divergence 10), `core/test/src/core/karmashala_shrink_keeps_rows_test.dart`
   (11), `core/test/src/core/karmashala_live_area_keeps_rows_test.dart` (12 and
   13), `core/test/src/core/karmashala_indic_width_test.dart` (15), and the
   `KittyKeyboardInputHandler functional keys` group in
   `core/test/src/core/input/handler_test.dart` (divergence 8). If the
   pixel-equivalence test fails, the batcher is merging something it must not.
4. **Drop anything upstream has fixed**, and record it in the section above. Read
   a test that fails after an upstream fix before you change it: in the 5.4
   rebase two of divergence 9's failed because upstream's erase rule had reopened
   a bug, not because the tests were stale.
5. Then `flutter analyze`, `flutter test` at the root and `dart test` in `core/`.

### Known baseline

Windows, Flutter 3.47.8, Dart 3.13.7, 2026-10-30:

| | upstream `da7e1c4` | `karmashala-5.4` |
| - | - | - |
| `flutter test` (root) | `+191 ~2 -2` | `+206 ~2 -2` |
| `dart test` (`core/`) | `+697` | `+764` |
| `flutter analyze` | 5 issues | 6 issues |

The two failures are `TerminalView.textScaler works` and
`TerminalView.textScaler can obtain textScaler from parent`, on both sides and
on every base since 2026-09. The five analyzer issues are the
`analysis_options_deprecated_plugins` warnings for the `dart_code_metrics` legacy
plugin. The sixth on our side is pub's warning that a publishable package has a`npath dependency, which is divergence 16 and harmless: this fork is never published.`nMost of the suite moved to `core/` with the terminal model.

Note that `flutter analyze` rewrites `analysis_options.yaml` (it adds `exclude:`
entries), and `flutter pub get` regenerates `pubspec.lock` and the example's
plugin registrants. `git checkout` those files before you commit or rebase.
