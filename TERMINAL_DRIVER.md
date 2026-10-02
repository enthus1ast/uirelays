# Terminal driver

Full-screen terminal backend for uirelays. Selected with `-d:terminal` (wins
over every other backend).

```sh
nim c -d:terminal -o:app app.nim
```

## Model

One cell == one pixel, font height 1. A window is `cols x rows`
(`pitch == cols`, `scaleX/Y == 1`, `uiScale == 100`, `fullScreen`). A `Cell`
holds one whole UTF-8 glyph (1–4 bytes), `fg`/`bg` RGB and a bold bit.

## Rendering

`buf`/`lastBuf` double buffer: `refresh()` diffs and emits only changed cells
(absolute cursor + SGR + glyph bytes). `gFirstFrame` (init/resize) clears with
`\e[2J` and repaints everything, so a stale buffer cannot leave holes.
`fillRect`/`drawLine` (Bresenham)/`drawPoint` honour the clip rect;
`MaxChangedFrame` caps a busy diff.

## Colour depth

`termColor` reduces the requested RGB: `tc24` → exact `38;2;r;g;b`; `tc256` →
`38;5;n`, nearest of 16 system + 6×6×6 cube + 24 greys; `tc16` → `30–37/90–97`
(fg), `40–47/100–107` (bg), nearest of 16. Detected in `createWindow`:
`UIRELAYS_TERMINAL_COLORS` (`16`/`256`/`24`) → `COLORTERM` → `TERM`.

## Input

`feedBytes` is one state machine: persistent UTF-8 decoder, then escapes
(CSI/SS3) or text.

- keys: UTF-8 text, Ctrl+A–Z/`\`/`]`/…, Ctrl+Space, Tab/Shift+Tab, Enter,
  Backspace, arrows, Home/End, Insert/Delete, PageUp/Down, F1–F12 — with
  Shift/Ctrl/Alt/Meta modifiers.
- SGR mouse (1003 + 1006): motion, down/up, wheel + horizontal tilt,
  double/triple click (500 ms, 4 cells, same button).
- focus in/out (1004), deduplicated.
- partial sequences are held until the next read.

## Terminal setup

Raw mode (`ICANON`/`ECHO` off), alternate screen `1049`, mouse `1003`+`1006`,
focus `1004`. `SIGWINCH`/`SIGINT`/`SIGTERM` set flags and write to a **self-pipe**
so a blocking `select` wakes despite `SA_RESTART`; `SIGWINCH` re-queries the
size and emits a `WindowMetricsEvent`. Title OSC 0, cursor shape DECSCUSR
(`setCursor` maps `CursorKind`; `setTerminalCursor`/`TerminalCursor` expose all
seven shapes), clipboard write OSC 52.

## Relays

All five groups are installed. Images are partly there: `blitRGBA` lands pixels
the app produced, as half-blocks or one-per-cell (`blitStyle`);
`loadImage`/`drawImage`/`imageSize` are nil-safe no-ops. Clipboard: `putText`
via OSC 52, `getText` returns `""`.

Text styles ride on the font handle: `styledFont(f, {FontStyle.underline})`
(and `bold`/`italics`/`strikethrough`) makes `drawText` emit the matching SGR
attribute. See `PR2.md` for why the style lives on the handle.

## Offscreen mode

When stdin/stdout are not TTYs, or `UIRELAYS_TERMINAL_OFFSCREEN=1`, output goes
to the `captured` string instead of a terminal. All unit tests run this way.

## Tests

- `tests/terminaldriver.nim` — offscreen unit tests.
- `tools/pty_smoke.nim` + `tools/smoke_terminal.sh` — real PTY, scripted input,
  reconstructed screen.
- `./build_terminal.sh` — compile check.

## Limitations

- no image *decoder* (`loadImage`/`drawImage`); apps hand over finished pixels
  with `blitRGBA` instead;
- double-width glyphs (CJK, emoji) count as one cell (no `wcwidth`);
- `Alt+<key>` is reported as `Esc` + text;
- bracketed paste / modifyOtherKeys / Kitty keyboard not enabled.
