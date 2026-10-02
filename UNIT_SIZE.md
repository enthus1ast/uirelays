# Application units (scaling)

A terminal-first app draws in a cell grid — `createWindow(80, 24)`, font size 1,
coordinates like `rect(10, 2, 30, 1)`. Built as a GUI, those numbers are read as
pixels and everything comes out tiny. **Application units** let the same drawing
code say how big one of its units is, and the framework does the scaling.

```nim
setUnitSize(9, 18)          # one app unit = 9x18 driver coordinates
let layout = createWindow(80, 24)   # → an 80x24 grid, 720x432 on screen
openFont("", 1, fm)         # size 1 in app units → 18 px
fillRect(rect(10, 2, 30, 1), color(...))   # → rect(90, 36, 270, 18)
```

Nothing in the drawing code mentions pixels or calls `scaled()`.

## The model

An application unit is whatever the app lays out in. `setUnitSize(w, h)` maps it
to driver coordinates; the wrappers in `screen`/`input` apply the factor before
touching a relay. Relays and drivers **never see app units** — they keep working
in driver coordinates, exactly as before.

Default is `1 x 1`: no scaling, so every existing app behaves identically (the
terminal backend is a no-op — a cell *is* its unit).

## What scales

Everything geometric, applied in the `screen`/`input` wrappers:

| API | effect |
|---|---|
| `createWindow(w, h)` | request scaled by `(unitW, unitH)` |
| `getWindowLayout()` | width/height returned in app units |
| `fillRect`, `drawLine`, `drawPoint`, `drawFrame` | coordinates/rect scaled |
| `drawText` | `x`, `y` scaled; `known` extent scaled to driver coords |
| `openFont` | `size` scaled by `unitH` |
| `getFontMetrics`, `fontLineSkip`, `measureText` | returned in app units |
| `setClipRect` | rect scaled |
| `pollEvent`, `waitEvent` | mouse position and window size unscaled back to app units |

## What does **not** scale

- **Image pixels.** `blitRGBA`/`drawImage` scale `dst` (placement), but the
  pixel buffer's `w`/`h` are left alone: a bitmap has its own resolution, and
  the relay contract promises no scaling. Size the buffer with `deviceRect(r)`
  so it lands crisp instead of being stretched by the driver.
- **Scroll deltas** (`MouseWheelEvent.x/y`): they are counts, not coordinates.
- **`src`** of `drawImage`: a rectangle in the picture's own pixels.

## API

```nim
# coords.nim
proc setUnitSize*(w, h: int)          # one app unit = w x h driver coordinates
proc unitSize*(): tuple[w, h: int]
proc toUnitX*(v: int): int            # driver coord -> app units (truncating)
proc toUnitY*(v: int): int
proc scaled*(r: Rect): Rect           # app units -> driver coords
proc scaled*(p: Point): Point

# screen.nim
proc deviceRect*(r: Rect): Rect       # app rect -> pixel rect for an image buffer
```

## Backends

`unitSize` maps *application units to driver coordinates*. How a driver's
coordinates reach the screen is its own business, and the backends already
differ:

| Backend | coordinate unit | reaches the screen |
|---|---|---|
| terminal | cell | 1:1 |
| Cocoa, GTK4, figdraw | logical point | platform scales to the backing store |
| X11, WinAPI, SDL | device pixel | 1:1 (its `uiScale` reports the display DPI) |

So on the auto-scaling backends `setUnitSize(9, 18)` is all a terminal-first app
needs. On raw-pixel backends the window and drawing are 9x18 px per cell — a
readable window, not a DPI-correct one. The natural next step is to fold the
backend density into the factor (`s = unitSize * uiScale/100`), which also
scales the window request; that needs the display scale *before* the window
exists, so it is left out of this prototype.

Do **not** combine `setUnitSize` with `layout.scaled(...)`: `scaled` is the
app-side DPI knob, and the wrappers already applied `unitSize` to the font size.

## Example

`examples/terminal_first.nim` is one drawing path:

```nim
when defined(terminal):
  const CellW = 1; CellH = 1
else:
  const CellW = 9; CellH = 18

setUnitSize(CellW, CellH)
let layout = createWindow(80, 24)     # in cells, always
```

Compile it either way — `nim c -d:terminal examples/terminal_first.nim` or
`nim c examples/terminal_first.nim` — and the layout code is unchanged.

## Caveats

- `measureText` returns app units by truncating driver pixels (`v div unitW`), so
  a width not divisible by the unit can be off by one; keep layout maths in app
  units and only draw in driver space.
- The unit is per-axis, so non-square cells (`9x18`) are fine.

## Tests

- `tests/terminaldriver.nim` → `unitSizeTests`: window request scaling, a 2x2
  app rect filling 4x6 driver cells, `drawText` landing at the scaled cell, and
  mouse events coming back in app units.
- `tools/smoke_terminal.sh` → `terminal_first` runs the example and checks it
  renders and quits.
