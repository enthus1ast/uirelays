# Terminal backend: correctness, input, colour, demos, PTY tooling

## Summary

Reworks the `-d:terminal` backend from a prototype into a tested, usable
backend. Fixes the framebuffer/redraw, UTF-8, input, mouse, resize/signals and
colour handling; adds the missing relays (clipboard, cursor, focus); adds two
examples and a real-PTY smoke-test tool.

Everything is covered by the offscreen unit tests and the PTY smoke tests.

## Drawing / framebuffer

- Default clip rect is the whole surface (was 0×0, so every cell was discarded
  and the terminal stayed black).
- First frame and resize clear with `\e[2J` **and** repaint every cell, so a
  stale `lastBuf` can no longer leave holes.
- `termColor`: correct bright codes (`90–97` / `100–107`, previously collided
  with the `46–53` background range).
- `drawTextBody`: per-cell bound/clip checks; UTF-8 aware — a `Cell` now holds a
  whole glyph, `measureText` counts codepoints.
- `emitCell`: no forced-white SGR sentinel; colours/bold survive cursor moves.
- `drawLine`: fixed Bresenham (`err = dx + dy`, `cx`/`cy` init). Axis-aligned
  and off-origin lines used to loop forever.
- `loadImage`/`freeImage`/`drawImage` wrappers are nil-safe (no more `SIGSEGV`
  on backends without images).

## Input

- Persistent UTF-8 decoder; `drPartial` no longer drops multi-byte codepoints;
  correct error recovery (replacement char + reprocess).
- Ctrl+A–Z / Ctrl+Space / punctuation, CSI modifier parameters
  (Shift/Ctrl/Alt/Meta on arrows, Home/End, Insert/Delete, PageUp/Down,
  F-keys), Shift+Tab, and End via `CSI F` (PC-style).
- Corrected F-key table: F5=15~, F6=17~ … F10=21~, F11=23~, F12=24~
  (16/22 unassigned); F1–F4 also with modifiers.
- SGR mouse: vertical wheel + horizontal tilt, extra buttons ignored,
  double/triple click (wall-clock 500 ms, 4 cells, same button).
- Focus in/out (mode 1004), deduplicated.

## Signals / resize

- Signal handlers actually set their flags (they were `discard gWinch`, i.e.
  no-ops) and write one byte to a **self-pipe** so a blocking `select` wakes even
  though `signal()` sets `SA_RESTART`.
- `SIGWINCH` re-queries the size, resizes the surface, repaints everything and
  emits a `WindowMetricsEvent`; Ctrl-C still exits gracefully.

## Colour

- Real colour-depth detection: `UIRELAYS_TERMINAL_COLORS` (`16`/`256`/`24`) →
  `COLORTERM` → `TERM`.
- `termColor` approximates the requested RGB per depth: exact `38;2;r;g;b`,
  nearest of the xterm 256 palette (16 system + 6×6×6 cube + 24 greys), or the
  nearest of the 16.

## Relays / terminal setup

- Clipboard write via OSC 52 (`getText` is empty — no query round trip).
- Cursor shape via DECSCUSR: `setCursor` maps the portable `CursorKind`, and
  `setTerminalCursor`/`TerminalCursor` expose all seven terminal shapes.
- Focus reporting (1004) enabled/disabled; mouse 1003+1006; alt screen 1049;
  title OSC 0.

## Examples

- `examples/terminal_demo.nim` (new): virtual mouse pointer, five buttons with
  hover/press (Count/Theme/Cursor/Clear/Quit), cursor-shape cycling, live
  status, typed text (UTF-8), event log, click-to-draw `drawLine` polyline
  (rainbow hues), and a hue/greyscale spectrum that shows the terminal's real
  colour depth.
- `examples/terminal_button.nim`: simplified and made resize/UTF-8 safe.

## Tests & tooling

- `tests/terminaldriver.nim`: expanded offscreen tests — colour maths and depth
  reduction, UTF-8 decode, draw primitives (`drawLine` at offsets), keys
  (modifiers, F-keys, editing keys), mouse, click runs, focus, clipboard,
  cursor.
- `tools/pty_smoke.nim`: drive a program in a real pty, feed scripted input and
  resizes, reconstruct the screen from the ANSI stream, assert text/raw escapes.
- `tools/smoke_terminal.sh`: builds `pty_smoke` + the examples and runs seven
  scenarios (demo, colours, truecolor, keys/Cyrillic, draw, clicks, button).
- Docs: `TERMINAL_DRIVER.md`, `tools/PTY_SMOKE.md`.
- Removed the obsolete `BUGS*.md` review notes (superseded by fixes/tests).

## Testing

```sh
nim c -r -d:terminal --path:src tests/terminaldriver.nim   # ALL PASS
./build_terminal.sh                                        # ok
./tools/smoke_terminal.sh                                  # terminal smoke: OK
```

## Known limitations

- No image relay (would need Sixel/Kitty or a file decoder).
- Double-width glyphs (CJK, emoji) count as one cell — no `wcwidth`.
- `Alt+<key>` is reported as `Esc` + text.
- Bracketed paste and modifyOtherKeys/Kitty keyboard are not enabled.

Signed-off-by: enthus1ast (David Krause) <david@dkrause.org>
