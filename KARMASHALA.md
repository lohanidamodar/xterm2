# Karmashala's fork of xterm2

This is [PopupBits/Karmashala](https://github.com/lohanidamodar)'s fork of
[SoFluffyOS/xterm2](https://github.com/SoFluffyOS/xterm2). It exists to carry
thirteen changes that upstream has not made, on a branch that can be rebased
onto upstream whenever upstream moves.

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
| 6 | `lib/src/ui/painter.dart` | `paintCellForeground` condenses an overflowing complex-script cluster into its cells instead of clipping its right-hand side off. |
| 7 | `lib/src/core/buffer/line.dart` | `getText` renders a blank cell as a space, so text laid out by moving the cursor copies with its gaps intact. |
| 8 | `lib/src/core/input/kitty_handler.dart` | Functional keys are encoded by the kitty protocol on every event type, not only on a repeat or a release, so cursor key mode, `SS3` F1-F4, `CSI R` for F3 and the lock and super modifiers stop leaking into a pane that enabled the protocol. |
| 9 | `lib/src/core/buffer/line.dart` | `resize` blanks the cells a narrower length cuts off, so they cannot come back beside newer text when the line widens again. |
| 10 | `lib/src/core/buffer/buffer.dart` | `EL 0` and `EL 1` keep a row's wrapped flag while cells of it remain, so a line repainted as `text ESC[K` (ConPTY after every resize) still reflows. |
| 11 | `lib/src/core/buffer/buffer.dart` | Shrinking the height keeps rows below the cursor that hold text, scrolling the top into scrollback instead, so an inline TUI's relative redraw still lands on the rows it drew. |
| 12 | `lib/src/core/buffer/buffer.dart`, `lib/src/core/reflow.dart` | A width change does not reflow the live area — from a cursor parked at column 0 downward, or below the line being written — so an inline TUI's full-width rows keep their row count and its redraw erases all of them. |
| 13 | `lib/src/core/buffer/line.dart`, `lib/src/core/reflow.dart` | A live-area row cut by a narrowing gets its cells back when the width grows again, unless the program repainted it meanwhile, so a resize that ends where it began is lossless. |

Each is one commit, on purpose: thirteen focused commits rebase onto a moving
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

### 7. Blank cells copy as spaces (`line.dart`)

`getText` walked the cells and wrote a code point for each, skipping any cell
whose code point was 0. A cell is 0 both when nothing was ever written to it
and when a program *moved the cursor over it* — `CUF`, `CHA`, an absolute
column jump, a tab stop — which is how every diff-based TUI renderer redraws a
line it has only partly changed. On screen such a cell is a blank; copied, it
vanished. So a pane's output came back with the spaces deleted from the lines
the CLI had repositioned and intact on the lines it had rewritten:

```
Crashandanalyticsvendors.That'stheoneImostwantedtobakeinanddeliberatelydidn't.
  deduplicated on-device log and a Diagnostics screen the user can share.
```

A blank cell now contributes one space. Four things stop that from being blunt:

- **The empty tail is dropped.** Blanks are held in a counter and only flushed
  when a glyph follows, so a 200-column line of `hi` copies as `hi`, not as
  `hi` and 198 spaces. That is also what keeps `getText()` and `toString()`
  usable as a line's content, and what `Buffer.getText`'s wrapped-line join
  relies on: a blanked tail on the first row must not be spelled out into the
  middle of a word that wrapped onto the second.
- **A wide glyph's spacer is not a blank.** It has code point 0 and width 0
  like an untouched cell, and is told apart the same way the rest of the file
  does it — the cell before it has width 2.
- **A tab keeps its cells elided.** `Terminal.tab` writes a real `HT` at the
  origin and leaves the cells it skipped empty; the `HT` already encodes the
  advance, so spelling those cells out as well would paste the text past the
  column it was drawn at. A gap the tab could *not* claim — the stop was
  already occupied, so no `HT` was written — is an ordinary cursor move and
  does become spaces.
- **`Buffer.getText`'s `trimWhitespace` is unchanged** and still needed: it
  trims *real* trailing spaces and tabs off each row of a selection, which the
  line-level tail trim never sees.

Pinned by `test/src/core/buffer/karmashala_copy_spacing_test.dart`; nine of its
fifteen tests fail against the base commit and the other six pin the behaviour
that must *not* change.

**This one edits upstream tests**, which no other divergence does. Seventeen
expectations across `test/src/core/buffer/buffer_test.dart`,
`test/src/core/buffer/line_test.dart` and `test/src/terminal_test.dart` used
`getText()` / `toString()` as a census of the glyphs on a line and so were
written without the blanks between them — `'de'` for a line reading `   de`,
`'AB CD'`'s predecessor `'ABCD'`, `'mnXr'` for `mnX  r`. Each now spells the
blanks out, which is what those tests' neighbouring `getCodePoint(i) == 0`
assertions were already saying. On a rebase they are the conflicts to expect
after `painter.dart`.

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

The same commit adds kitty's release gate — `encode_key` opens with
`if (!ev->report_all_event_types && ev->action == RELEASE) return 0;` — at the
top of the handler. Without it a pane that only disambiguated saw a second
escape sequence for every F13-F24 and keypad keystroke, because those two paths
answer a release exactly as they answer a press.

**With no modifiers, no locks and cursor key mode off the bytes are unchanged**,
which is the point: `ESC [ C` for `Right` and `ESC [ F` for `End` in kitty mode
and out of it alike. `test/src/core/input/handler_test.dart`'s
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
and grow" in `test/src/core/buffer/line_test.dart`, and `Terminal.reflowEnabled`
"truncates at the narrower width when reflow is disabled" in
`test/src/terminal_test.dart`. With reflow off, narrowing now truncates for
good, as xterm and xterm.js do.

**Not changed, and worth knowing:** narrowing a buffer whose cursor has blank
rows under it still scrolls the top row out rather than using those blank rows
up, which xterm.js avoids. A TUI cannot reach a row once it is in the
scrollback, so that row stays as the old width left it.

### 10. Erasing part of a row keeps it on its logical line (`buffer.dart`)

`BufferLine.isWrapped` says a row continues the one above it. Upstream's
`eraseLineFromCursor` (`EL 0`) and `eraseLineToCursor` (`EL 1`) cleared it on
every call, though the cells they leave still continue that row. Reflow joins
rows by the flag, so a row that lost it was cut off its logical line for good.

Windows ConPTY triggers this on every resize. It keeps only a screen, and after
`ResizePseudoConsole` it repaints that screen as `ESC[H`, then each logical line
as `text ESC[K`, joined by CR LF, leaving the long ones to autowrap (captured
from the inbox pseudoconsole on 10.0.26200). Autowrap sets the flag on each
continuation row, and the `ESC[K` after the text cleared it again on the last
one. Narrow a pane and every soft-wrapped line on the screen lost its last row.
Once those rows scrolled up, widening could not unwrap them: the scrollback kept
lines broken at the narrow width, with the last fragment on a row of its own.

`EL 0` now clears the flag only when the cursor is in the first column, where
nothing of the row is left, and `EL 1` leaves it alone; `ED 0` inherits the
first rule and `ED 1` still clears the cursor row. `EL 2` and the rows `ED`
blanks whole are unchanged. That is xterm.js's rule.

Pinned by `test/src/core/karmashala_erase_keeps_wrap_test.dart`, which replays
the repaint's shape through narrow, scroll, widen and narrow again. Seven of its
eleven tests fail without the change.

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

Pinned by `test/src/core/karmashala_shrink_keeps_rows_test.dart`, which replays
that redraw after a shrink, after a shrink and grow, and through the logged
flip-flop. All three fail without the change.

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

Pinned by `test/src/core/karmashala_live_area_keeps_rows_test.dart`. Its
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
`test/src/core/karmashala_live_area_keeps_rows_test.dart`; two of them fail
without the change, and the third holds divergence 9's guarantee.

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

Ten commits will replay. Expect conflicts in `painter.dart` above all — it is
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
   `test/src/ui/karmashala_render_test.dart` (divergences 1 and 2),
   `test/src/ui/karmashala_complex_script_test.dart` (divergence 6, and the
   buffer clustering it rests on), the `alias-safe detach (Karmashala)`
   group in `test/src/utils/circular_buffer_test.dart` (divergence 5),
   `test/src/core/buffer/karmashala_copy_spacing_test.dart` (divergence 7),
   `test/src/core/karmashala_resize_scrollback_test.dart` (divergence 9),
   `test/src/core/karmashala_erase_keeps_wrap_test.dart` (divergence 10), and
   the `KittyKeyboardInputHandler functional keys` group in
   `test/src/core/input/handler_test.dart` (divergence 8). If the
   pixel-equivalence test fails, the batcher is merging something it must not.
4. **Drop anything upstream has fixed**, and record it in the section above.
5. Then `flutter analyze` and `flutter test`.

### Known baseline

At the base commit, on this toolchain:

- `flutter analyze` reports 5 pre-existing `analysis_options_deprecated_plugins`
  warnings (the `dart_code_metrics` legacy analyzer plugin, in the package's and
  the example's `analysis_options.yaml`). Our branch adds none.
- `flutter test` is `+774 ~2 -2` at the commit divergence 8 branched from. The
  two failures, `TerminalView.textScaler works` and
  `TerminalView.textScaler can obtain textScaler from parent`, are pre-existing
  — re-confirmed on 2026-09-09 with the working tree stashed. Our branch is
  `+780 ~2 -2`: the same two failures, six added tests.
- With divergence 9, on 2026-09-17 (macOS, Flutter's bundled Dart): `+796`, no
  failures — twelve added tests, two upstream tests turned round.
- With divergence 10, on 2026-09-21 (Windows): `+803 ~2 -2`, against `+792 ~2
  -2` at divergence 9 on the same machine — eleven added tests. The two
  failures are the `textScaler` pair above, which fail on Windows either way.

Note that `flutter analyze` rewrites `analysis_options.yaml` (it adds `exclude:`
entries); `git checkout -- analysis_options.yaml example/analysis_options.yaml`
after running it.
