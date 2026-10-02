## Terminal backend for uirelays.
##
## Renders uirelays apps as a full-screen terminal program instead of a GUI
## window. The model, from the plan, is deliberately simple:
##
##   * one cell == one pixel; font height == 1, so a window is `cols x rows`
##     cells and `ScreenLayout.pitch == cols`.
##   * a cell holds a character plus foreground/background colour attributes,
##     exactly what a real terminal cell already holds: the terminal draws the
##     glyphs, this driver only decides which character and which colours.
##   * double buffering is a diff between two cell buffers, so `refresh` emits
##     only the cells that changed, as ANSI escapes.
##
## It opts in with `-d:terminal` (see backend.nim). It only touches a real
## terminal when it is actually attached to one: when stdin/stdout are not TTYs
## (CI, pipes, tests) it falls back to an offscreen surface whose output is
## captured, so the whole driver -- drawing, diffing, input parsing, UTF-8 --
## runs and can be tested with no terminal at all.
##
## Windows (`when defined(windows)`) is out of scope for v1: the POSIX path
## below is what runs, and on Windows the driver simply stays an offscreen
## surface until the console backend is ported.

import uirelays/[coords, screen, input]
import posix/termios
import posix/posix
import std/terminal   # hideCursor, showCursor, setCursorPos
import std/times       # cpuTime, epochTime
import std/os          # getEnv
import std/strutils    # contains
import std/base64      # clipboard OSC 52

## POSIX signal numbers and the "default handler" sentinel. `posix/posix` does
## not reliably export them (only the generic ANSI-C ones, when at all), and the
## platform signal we need (SIGWINCH) is nowhere in stdlib, so we declare what we
## use directly. `signal()` takes the signum as a `cint`; `SIG_DFL` is just the
## NULL handler, so a plain constant is a valid handler argument.
const
  SIGINT*   = cint(2)
  SIGTERM*  = cint(15)
  SIGWINCH* = cint(28)
  SIG_DFL*  = cast[proc(a: cint) {.noconv.}](0)

proc c_pipe(fds: ptr array[0 .. 1, cint]): cint
  {.importc: "pipe", header: "<unistd.h>".}

# ---------------------------------------------------------------------------
# The cell, and the module-level state that one live surface keeps.
# ---------------------------------------------------------------------------

const MaxGlyphBytes* = 4        ## UTF-8 bytes one cell can hold

type
  Cell* = object
    ## One screen cell, kept in two buffers: `buf` (what this frame will show)
    ## and `lastBuf` (what the previous frame showed, to diff against). `glyph`
    ## is the whole UTF-8 sequence the terminal should draw (1-4 bytes) and
    ## `glyphLen` how many are valid: keeping a multi-byte codepoint together in
    ## one cell is what makes an umlaut one column instead of two broken bytes.
    ## The colour fields are what the *app* asked for (already composited for
    ## alpha), which is also exactly what the diff needs to compare.
    glyph*: array[MaxGlyphBytes, char]
    glyphLen*: uint8
    fg*, bg*: Color
    attr*: uint16      ## bit 0 = bold; the terminal's only easy flourish

  Utf8Decoder* = object
    ## State of the incremental UTF-8 decoder: how many more continuation bytes
    ## a codepoint needs, the value folded so far, and the largest value a
    ## sequence of this length may hold (RFC 3629).
    n*: int          ## continuation bytes still needed (0 = at a boundary)
    value*: uint32   ## the codepoint folded so far
    maxVal*: uint32  ## upper bound for the sequence in progress
    totalLen*: int   ## how long this sequence is, for the split-read case

  DecResult* = enum
    drAscii, drCodepoint, drPartial, drError

const
  DrainMax = 16 * 1024          ## bytes drained from the terminal in one poll
  MaxChangedFrame = 256 * 1024  ## per-frame output cap (focim's MaxPerFrame)

type
  TermColors* = enum
    ## How many colours the terminal can show. `tc16` is the safe default,
    ## `tc256` the xterm 256-colour palette, `tc24` direct RGB (truecolor).
    tc16, tc256, tc24

# Surface state. All of it is reset by `createWindow`.
var
  cols, rows*: int
  buf, lastBuf: seq[Cell]
  clip*: Rect = Rect(x: 0, y: 0, w: 0, h: 0)
  clipStack: seq[Rect]
  gFirstFrame = true
  gColors: TermColors = tc16
  tty = false                   ## attached to a real terminal
  captured*: string             ## offscreen: every emitted byte, for tests
  gWinch = false                ## SIGWINCH fired; a resize is pending
  gShutdown = false             ## SIGINT/SIGTERM fired; a Quit is pending
  gFocus = -1'i8                ## -1 unknown, 0 lost, 1 gained (dedupe)
  sigFd: array[0 .. 1, cint] = [-1.cint, -1.cint]  ## self-pipe for wakeups
  sigByte: uint8 = 0            ## the byte the signal handlers write
  escAccum: string              ## an escape sequence cut off mid-way, held
  utf8State: Utf8Decoder        ## a UTF-8 codepoint cut off mid-way, held
  eventQueue: seq[Event]
  lastClickTick = 0             ## ms of the previous press, for click runs
  lastClickX, lastClickY = 0
  lastClickButton = LeftButton
  clickCount = 1
  outSink: proc (s: string) {.nimcall.}

proc emit*(s: string) {.nimcall.} =
  ## On a real TTY: write and flush; offscreen: capture for tests.
  if tty:
    stdout.write s
    stdout.flushFile()
  else:
    captured.add s

outSink = emit

proc zeroTimeval(): Timeval =
  ## A zero-valued `Timeval` (used as a non-blocking poll timeout). The C
  ## struct's fields are `distinct clong`, so a bare `0` will not bind.
  Timeval(tv_sec: posix.Time(0), tv_usec: posix.Suseconds(0))

# ---------------------------------------------------------------------------
# Colour (Step 1). The requested RGB is kept in the cell and reduced to the
# best the terminal can show at emit time: truecolor, the xterm 256 palette,
# or the sixteen ANSI colours.
# ---------------------------------------------------------------------------

const
  Xterm: array[16, tuple[r, g, b: int]] = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
    (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]

proc nearest(r, g, b: int): int =
  ## Which of the sixteen a colour is closest to, by squared RGB distance.
  result = 0
  var best = high(int)
  for i in 0 ..< 16:
    let dr = r - Xterm[i].r
    let dg = g - Xterm[i].g
    let db = b - Xterm[i].b
    let d = dr*dr + dg*dg + db*db
    if d < best:
      best = d
      result = i

proc cubeColor*(idx: int): int =
  ## A 256-colour index folded to one of the sixteen (see focim/ansi.nim).
  if idx < 16: idx
  elif idx < 232:
    let n = idx - 16
    template level(v: int): int = (if v == 0: 0 else: 55 + 40 * v)
    nearest(level(n div 36), level((n div 6) mod 6), level(n mod 6))
  else:
    let v = 8 + 10 * (idx - 232)
    nearest(v, v, v)

const CubeLevels: array[6, int] = [0, 95, 135, 175, 215, 255]

proc cubeIndex(v: int): int =
  ## The 0..5 cube level closest to `v`.
  result = 0
  var best = high(int)
  for i in 0 ..< 6:
    let d = abs(v - CubeLevels[i])
    if d < best:
      best = d
      result = i

proc nearest256(r, g, b: int): int =
  ## Index in the xterm 256-colour palette closest to (r, g, b): the sixteen
  ## system colours, the 6x6x6 cube, or the 24-step grey ramp -- whichever is
  ## nearest by squared RGB distance.
  var best = 0
  var bestD = high(int)
  for i in 0 ..< 16:
    let dr = r - Xterm[i].r
    let dg = g - Xterm[i].g
    let db = b - Xterm[i].b
    let d = dr*dr + dg*dg + db*db
    if d < bestD:
      bestD = d
      best = i
  ## The cube is a product of the three level sets, so the nearest level per
  ## channel is the nearest cube colour.
  let ri = cubeIndex(r)
  let gi = cubeIndex(g)
  let bi = cubeIndex(b)
  block:
    let dr = r - CubeLevels[ri]
    let dg = g - CubeLevels[gi]
    let db = b - CubeLevels[bi]
    let d = dr*dr + dg*dg + db*db
    if d < bestD:
      bestD = d
      best = 16 + 36 * ri + 6 * gi + bi
  ## The grey ramp 232..255 is finer than the cube's greys.
  for i in 0 ..< 24:
    let v = 8 + 10 * i
    let d = (r - v)*(r - v) + (g - v)*(g - v) + (b - v)*(b - v)
    if d < bestD:
      bestD = d
      best = 232 + i
  best

proc termColor*(c: Color; bg: bool = false): string =
  ## The SGR parameter string to paint `c` (background when `bg`), reduced to
  ## what the terminal can show:
  ##   * truecolor -> `38;2;r;g;b` / `48;2;r;g;b`
  ##   * 256       -> `38;5;n` / `48;5;n`, nearest of the xterm 256 palette
  ##   * 16        -> `30+i`/`90+i` (fg), `40+i`/`100+i` (bg), nearest of 16
  ## This is the one public colour entry point; everything inside builds on it.
  ##
  ## Alpha is not representable in a cell attribute: `drawText`/`fillRect`
  ## composite against their own background before they get here, so by the
  ## time a colour reaches `termColor` it is already opaque.
  case gColors
  of tc24:
    (if bg: "48;2;" else: "38;2;") & $c.r & ";" & $c.g & ";" & $c.b
  of tc256:
    (if bg: "48;5;" else: "38;5;") & $nearest256(int(c.r), int(c.g), int(c.b))
  of tc16:
    let idx = nearest(int(c.r), int(c.g), int(c.b))
    let base = (if bg: 40'u8 else: 30'u8)
    if idx < 8:
      $(base + uint8(idx))          # 30-37 / 40-47
    else:
      $(base + 52'u8 + uint8(idx))  # 90-97 / 100-107

proc over*(c: Color): Color =
  ## Composite a colour over itself, dropping its alpha. A solid fill asks for
  ## one fg and one bg that are the same colour, so this keeps a translucent
  ## fill looking right instead of handing an alpha byte to a cell that has none.
  if c.a >= 255'u8: return c
  let inv = 255'u8 - c.a
  Color(r: uint8((uint(c.r) * uint(c.a) + uint(c.r) * uint(inv)) div 255),
        g: uint8((uint(c.g) * uint(c.a) + uint(c.g) * uint(inv)) div 255),
        b: uint8((uint(c.b) * uint(c.a) + uint(c.b) * uint(inv)) div 255),
        a: 255'u8)

# ---------------------------------------------------------------------------
# UTF-8 (Step 5a) -- the incremental decoder the stdlib has none of.
# ---------------------------------------------------------------------------

proc leadLen(b: uint8): int =
  ## How many bytes a lead byte starts: 0x00-0x7F -> 1, 0xC2-0xDF -> 2,
  ## 0xE0-0xEF -> 3, 0xF0-0xF4 -> 4, 0xC0/0xC1/0xF5-0xFF -> invalid (0).
  if b >= 0xC0'u8 and b <= 0xC1'u8: 0    ## overlong leads: invalid
  elif b < 0x80'u8: 1
  elif b <= 0xDF'u8: 2
  elif b <= 0xEF'u8: 3
  elif b <= 0xF4'u8: 4
  else: 0

proc maxValForLen(k: int): uint32 =
  ## Largest codepoint a k-byte sequence can even encode (used to reject the
  ## values above U+10FFFF that RFC 3629 forbids).
  case k
  of 2: 0x7FF'u32
  of 3: 0xFFFF'u32
  of 4: 0x10FFFF'u32
  else: 0xFFFFFFFF'u32

proc newUtf8Decoder*(): Utf8Decoder =
  Utf8Decoder(n: 0, value: 0'u32, maxVal: 0'u32, totalLen: 1)

proc decodeByte*(d: var Utf8Decoder; b: uint8): tuple[result: DecResult, value: uint32] =
  ## One byte into the decoder. `drPartial` means "need more bytes" and the
  ## decoder keeps everything it has; `drError` means "this byte is not what a
  ## valid sequence wanted" and the caller reprocesses it (it is not advanced
  ## past, unless it was an invalid *lead* byte, handled by the caller).
  result = (drAscii, 0'u32)
  if d.n > 0:
    # In the middle of a codepoint.
    if b >= 0x80'u8 and b <= 0xBF'u8:
      d.value = (d.value shl 6) or (b and 0x3F'u8)
      dec d.n
      if d.n == 0:
        if d.value > d.maxVal: result = (drError, 0xFFFD'u32)
        else: result = (drCodepoint, d.value)
      else:
        result = (drPartial, 0'u32)
    else:
      ## A bad continuation byte: the codepoint in progress is dead, and this
      ## byte may start something fresh, so drop the half-sequence and let the
      ## caller reprocess it without advancing.
      result = (drError, 0xFFFD'u32)
      d = newUtf8Decoder()
    return
  ## At a codepoint boundary.
  if b < 0x80'u8:
    result = (drAscii, b.uint32)
    return
  let k = leadLen(b)
  if k <= 1:
    ## 0xC0/0xC1/0xF5-0xFF: invalid lead byte.
    result = (drError, 0xFFFD'u32)
    return
  d.totalLen = k
  let mask = uint32((1'u8 shl (8 - k)) - 1'u8)  ## low (8-k) bits of the lead
  d.value = uint32(b) and mask
  d.maxVal = maxValForLen(k)
  d.n = k - 1
  result = (drPartial, 0'u32)

proc utf8Encode*(cp: uint32; s: var array[4, char]): int =
  ## Encode a codepoint into `s`, returning how many bytes were written.
  if cp < 0x80:
    s[0] = char(cp)
    1
  elif cp < 0x800:
    s[0] = char(0xC0'u8 or uint8(cp shr 6))
    s[1] = char(0x80'u8 or uint8(cp and 0x3F))
    2
  elif cp < 0x10000:
    s[0] = char(0xE0'u8 or uint8(cp shr 12))
    s[1] = char(0x80'u8 or uint8((cp shr 6) and 0x3F))
    s[2] = char(0x80'u8 or uint8(cp and 0x3F))
    3
  else:
    s[0] = char(0xF0'u8 or uint8(cp shr 18))
    s[1] = char(0x80'u8 or uint8((cp shr 12) and 0x3F))
    s[2] = char(0x80'u8 or uint8((cp shr 6) and 0x3F))
    s[3] = char(0x80'u8 or uint8(cp and 0x3F))
    4

# ---------------------------------------------------------------------------
# Cell helpers (Step 2) -- the drawing primitives all funnel through here,
# honouring the clip rect, bounds-checked, so nothing writes off the surface.
# ---------------------------------------------------------------------------

proc makeCell(ch: char; fg, bg: Color; bold = false): Cell =
  Cell(glyph: [ch, '\0', '\0', '\0'], glyphLen: 1,
       fg: fg, bg: bg, attr: (if bold: 1'u16 else: 0'u16))

proc makeCellGlyph(s: string; start, n: int; fg, bg: Color;
                   bold = false): Cell =
  ## A cell holding the `n` bytes at `s[start]`: one whole UTF-8 codepoint.
  result = Cell(fg: fg, bg: bg, attr: (if bold: 1'u16 else: 0'u16))
  let m = min(n, MaxGlyphBytes)
  for k in 0 ..< m: result.glyph[k] = s[start + k]
  result.glyphLen = uint8(m)

proc glyphLenAt(s: string; i: int): int =
  ## Byte length of the UTF-8 codepoint starting at `s[i]`; 1 for ASCII or for
  ## a malformed sequence, so a bad byte still occupies exactly one cell.
  let b = s[i].uint8
  let k = leadLen(b)
  if k < 2: return 1
  if i + k > s.len: return 1
  for j in 1 ..< k:
    if s[i + j].uint8 notin 0x80'u8 .. 0xBF'u8: return 1
  k

proc setCell(x, y: int; cell: Cell) =
  if x < 0 or y < 0 or x >= cols or y >= rows: return
  if x < clip.x or x >= clip.x + clip.w or y < clip.y or y >= clip.y + clip.h:
    return
  buf[y * cols + x] = cell

proc setCellColor(x, y: int; fg, bg: Color; ch = ' ') =
  setCell(x, y, makeCell(ch, fg, bg))

# ---------------------------------------------------------------------------
# Draw relays (Step 2).
# ---------------------------------------------------------------------------

proc drawRectCells(x, y, w, h: int; fg, bg: Color) =
  ## Fill the cell rectangle [x, x+w) x [y, y+h). Bounds + clip handled per cell.
  var x0 = (if x < 0: 0 else: x)
  var y0 = (if y < 0: 0 else: y)
  var x1 = (if x + w > cols: cols else: x + w)
  var y1 = (if y + h > rows: rows else: y + h)
  for yy in y0 ..< y1:
    for xx in x0 ..< x1:
      setCell(xx, yy, makeCell(' ', fg, bg))

proc fillRect*(r: Rect; color: Color) =
  ## A solid block: both the glyph and its colour are `color`. Alpha was
  ## composited into `color` by the caller, so this is a flat coloured region.
  let c = over(color)
  drawRectCells(r.x, r.y, r.w, r.h, c, c)

proc drawPoint*(x, y: int; color: Color) =
  let c = over(color)
  setCellColor(x, y, c, c)

proc drawLine*(x1, y1, x2, y2: int; color: Color) =
  ## Bresenham's line over cells: uniform spacing via the decision parameter,
  ## so a diagonal is a steady 2:1 step and not the jagged look of rounding
  ## each float.
  let c = over(color)
  let dx = abs(x2 - x1)
  let dy = -abs(y2 - y1)
  var sx = (if x1 < x2: 1 else: -1)
  var sy = (if y1 < y2: 1 else: -1)
  ## The classic all-octant Bresenham initialises the error to `dx + dy`. The
  ## old `(dx + dy) div 2` halved it, which broke the decision thresholds for
  ## axis-aligned lines: a horizontal or vertical line stepped off the axis on
  ## the first cell and its endpoint was never reached, so the loop never
  ## terminated. Every `drawLine` border in the terminal backend hung on it.
  var err = dx + dy
  ## `var cx, cy = x1` would set *both* to `x1`; the y start is `y1`.
  var cx = x1
  var cy = y1
  while true:
    setCellColor(cx, cy, c, c)
    if cx == x2 and cy == y2: break
    let e2 = err * 2
    if e2 >= dy:
      err += dy
      cx += sx
    if e2 <= dx:
      err += dx
      cy += sy

# images: left at the default stubs (0 / discard) -- out of scope by design.

# ---------------------------------------------------------------------------
# Font + text relays (Step 3). Font height is 1: a line is one cell row.
# ---------------------------------------------------------------------------

proc openFont*(path: string; size: int; style: FontStyles;
               metrics: var FontMetrics): Font =
  ## `size` and `path` are accepted but do not rasterise anything: the terminal
  ## draws each stamped character with its own native font. Only the metrics
  ## are written, and they obey the cell==pixel rule (one row, one cell tall).
  metrics = FontMetrics(ascent: 1, descent: 0, lineHeight: 1)
  discard style
  discard path
  discard size
  Font(1)

proc closeFont*(f: Font) = discard

proc getFontMetrics*(f: Font): FontMetrics =
  ## Every font the driver offers is the same flat 1-row grid.
  FontMetrics(ascent: 1, descent: 0, lineHeight: 1)

proc measureText*(f: Font; text: string): TextExtent =
  ## One column per codepoint (cell==pixel), one row tall. Bytes are not
  ## columns: "ä" measures 1, not 2.
  var w = 0
  var i = 0
  while i < text.len:
    inc w
    i += glyphLenAt(text, i)
  TextExtent(w: w, h: 1)

proc drawTextBody*(f: Font; x, y: int; text: string;
                   fg, bg: Color; known: TextExtent): TextExtent =
  ## Stamp each character into the cell buffer over the clip rect, painting the
  ## *full* background of every cell in the run so a label drawn over a coloured
  ## box reads clean. Returns the same extent `measureText` would.
  let res = (if known.w > 0: known else: measureText(f, text))
  var cx = x
  ## `setCell` bounds- and clip-checks every cell itself, so the run stays
  ## correct even when it starts at a negative x. Decode by codepoint, not by
  ## byte: one cell receives the whole UTF-8 sequence of one character, so an
  ## umlaut is one column and not two garbage cells.
  var i = 0
  while i < text.len:
    let n = glyphLenAt(text, i)
    setCell(cx, y, makeCellGlyph(text, i, n, fg, bg))
    inc cx
    i += n
  res

proc drawText*(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
  drawTextBody(f, x, y, text, over(fg), over(bg), TextExtent())

proc drawMeasuredText*(f: Font; x, y: int; text: string;
                       fg, bg: Color; size: TextExtent) =
  ## The same body, for a caller that already measured: a shortcut, not a
  ## second way to draw. The public `drawText*` wrapper supplies the extent it
  ## measured, so this driver just stamps the glyphs and reports nothing -- the
  ## relay field `drawMeasuredText` is void on purpose.
  discard drawTextBody(f, x, y, text, over(fg), over(bg), size)

# ---------------------------------------------------------------------------
# Window relays (Step 4).
# ---------------------------------------------------------------------------

proc queryWinsize(): tuple[rows, cols: int] =
  ## Terminal size from TIOCGWINSZ on the output fd; (0, 0) if it fails.
  var ws: IOctl_WinSize
  if ioctl(1, TIOCGWINSZ, addr ws) != 0:
    return (0, 0)
  (int(ws.ws_row), int(ws.ws_col))

proc resizeSurface(nr, nc: int) =
  var nrows = nr
  var ncols = nc
  if nrows <= 0: nrows = 24
  if ncols <= 0: ncols = 80
  if nrows == rows and ncols == cols: return
  cols = ncols
  rows = nrows
  buf.setLen(rows * cols)
  lastBuf.setLen(rows * cols)
  gFirstFrame = true
  ## A caller that never calls `setClipRect` draws into the whole surface, so
  ## the default clip is the full grid -- not the empty rectangle a global
  ## `Rect()` starts as, which would silently discard every cell.
  clip = Rect(x: 0, y: 0, w: cols, h: rows)
  ## An empty cell is a space on the default (black-on-black) background; a full
  ## redraw clears the stale cells from the old size. Alpha is pinned to 255 so
  ## a cell built here compares equal to the same colour built by `over`.
  for i in 0 ..< buf.len:
    buf[i] = makeCell(' ', Color(r: 0, g: 0, b: 0, a: 255'u8),
                           Color(r: 0, g: 0, b: 0, a: 255'u8))

proc detectColors(): TermColors =
  ## Which colour depth to use. `UIRELAYS_TERMINAL_COLORS` overrides everything
  ## (16 / 256 / 24), then `COLORTERM` marks truecolor, then a `TERM` ending in
  ## `-direct`, then the `256color` suffix. Terminals that can do truecolor but
  ## do not advertise it stay on 256, which is safe.
  let forced = getEnv("UIRELAYS_TERMINAL_COLORS", "").toLowerAscii
  case forced
  of "16", "8": return tc16
  of "256": return tc256
  of "24", "24bit", "truecolor": return tc24
  else: discard
  let ct = getEnv("COLORTERM", "").toLowerAscii
  if ct.contains("truecolor") or ct.contains("24bit"): return tc24
  let term = getEnv("TERM", "").toLowerAscii
  if term.contains("direct"): return tc24
  if term.contains("256color"): return tc256
  tc16

proc enterTerminal()   ## forward decl: installed with the terminal, below
proc createWindow*(layout: var ScreenLayout;
                   icon: pointer; iconLen: int) =
  ## The only window. Size it from the real terminal when there is one, else
  ## from the requested size (offscreen mode); then enter the alternate buffer,
  ## hide the cursor, enable SGR mouse, and install the signal handlers that
  ## keep the terminal sane across Ctrl-C and resize.
  discard icon
  discard iconLen
  let reqW = layout.width
  let reqH = layout.height
  ## Real mode needs a real terminal on both ends. Tests run with no TTY, and a
  ## `-d:terminal` app can force offscreen with `UIRELAYS_TERMINAL_OFFSCREEN=1`
  ## so a captured run never puts a terminal into raw mode; otherwise fall back
  ## to offscreen the moment either fd is not a terminal.
  let forceOffscreen =
    getEnv("UIRELAYS_TERMINAL_OFFSCREEN", "0").toLowerAscii.contains("1")
  tty = not forceOffscreen and isatty(STDIN_FILENO) > 0 and isatty(1) > 0
  gColors = detectColors()
  if tty:
    let (nr, nc) = queryWinsize()
    resizeSurface(nr, nc)
  else:
    resizeSurface(reqH, reqW)   # offscreen: requested height/width are cells
  if rows == 0 or cols == 0:
    resizeSurface(24, 80)
  clip = Rect(x: 0, y: 0, w: cols, h: rows)
  layout.width = cols
  layout.height = rows
  layout.pitch = cols
  layout.scaleX = 1
  layout.scaleY = 1
  layout.uiScale = 100         # a terminal is already at native cell size
  layout.fullScreen = true
  if tty:
    enterTerminal()
  gFirstFrame = true

proc getWindowLayout*(): ScreenLayout =
  ScreenLayout(width: cols, height: rows, pitch: cols,
               scaleX: 1, scaleY: 1, uiScale: 100, fullScreen: true)

proc setClipRect*(r: Rect) =
  clip = r
proc saveState*() =
  clipStack.add clip
proc restoreState*() =
  if clipStack.len > 0:
    clip = clipStack.pop
proc setCursor*(c: CursorKind) =
  ## A terminal has no shaped cursor to hand out, but DECSCUSR can choose
  ## between a block, a bar and an underline. Visibility is the frame's job: it
  ## hides the cursor while drawing and shows it again in `refresh`.
  let ps =
    case c
    of curIbeam: 6              # steady bar
    of curDefault, curArrow: 2  # steady block
    else: 1                     # blinking block
  outSink("\e[" & $ps & " q")
  if tty:
    if c == curDefault or c == curIbeam:
      showCursor()
    else:
      hideCursor()

proc clipboardWrite(text: string) =
  ## OSC 52: ask the terminal to put `text` on the system clipboard. Best
  ## effort -- terminals commonly gate this behind a setting, and some ignore
  ## it entirely, but it is the only clipboard a terminal app can reach.
  outSink("\e]52;c;" & encode(text) & "\a")

proc clipboardRead(): string =
  ## Reading needs an OSC 52 query and the terminal's reply parsed off stdin,
  ## a round trip this driver does not do. Empty is "nothing", which is also
  ## what a terminal that refuses the query would answer.
  ""
proc setWindowTitle*(title: string) =
  ## Best effort: an OSC 0 title. Ignored by terminals that do not honour it.
  if tty:
    outSink("\e]0;" & title & "\a")

# ---------------------------------------------------------------------------
# The frame: diff buf against lastBuf and emit only the changed cells.
# ---------------------------------------------------------------------------

proc emitCell(sb: var string; x, y: int; cell: Cell;
              outCol, outRow: var int; outFg, outBg: var Color;
              outBold, outValid: var bool) =
  if x != outCol or y != outRow:
    sb.add "\e[" & $((y + 1)) & ";" & $((x + 1)) & "H"
    outCol = x
    outRow = y
    ## Moving the cursor leaves the SGR attributes untouched, so the tracked
    ## colours and bold state stay valid -- nothing is forced here. (The old
    ## code reset them to white, which suppressed the colour escape whenever
    ## the next cell happened to be white, and lost track of bold.)
  if (cell.attr and 1'u16) != 0'u16 and (not outValid or not outBold):
    sb.add "\e[1m"; outBold = true
  elif (cell.attr and 1'u16) == 0'u16 and outValid and outBold:
    sb.add "\e[22m"; outBold = false
  if not outValid or cell.fg != outFg:
    sb.add "\e[" & termColor(cell.fg, false) & "m"; outFg = cell.fg
  if not outValid or cell.bg != outBg:
    sb.add "\e[" & termColor(cell.bg, true) & "m"; outBg = cell.bg
  outValid = true
  for k in 0 ..< int(cell.glyphLen):
    sb.add cell.glyph[k]

proc refresh*() =
  ## Copy this frame's changed cells to the surface (or, offscreen, to the
  ## captured buffer), then remember this frame as the previous one. Bounded by
  ## MaxChangedFrame: past it the frame is too busy to diff cheaply, so a full
  ## clear + redraw wins.
  var sb = ""
  ## `gFirstFrame` means the physical screen is about to be cleared, so every
  ## cell must be repainted. Diffing against `lastBuf` here would skip the cells
  ## that happen not to have changed since before the clear -- which is exactly
  ## the blank header a resize used to leave behind, the old buffer's contents
  ## for the overlapping region matching the new frame.
  let full = gFirstFrame
  if full:
    sb.add "\e[2J\e[0m"
    if tty:
      sb.add "\e[?25l"
    gFirstFrame = false
  var changed = 0
  var outCol = -1
  var outRow = -1
  var outFg = Color(r: 255, g: 255, b: 255, a: 255)
  var outBg = Color(r: 255, g: 255, b: 255, a: 255)
  var outBold = false
  var outValid = false
  var capped = false
  for y in 0 ..< rows:
    for x in 0 ..< cols:
      let idx = y * cols + x
      if full or buf[idx] != lastBuf[idx]:
        if not full and changed >= MaxChangedFrame:
          capped = true
          break
        emitCell(sb, x, y, buf[idx], outCol, outRow, outFg, outBg, outBold,
                 outValid)
        inc changed
    if capped: break
  if capped:
    sb.add "\e[0m\e[2J\e[H"
  sb.add "\e[0m"
  outSink(sb)
  if tty:
    outSink("\e[?25h")          # restore the cursor after the frame
  lastBuf = buf
  ## NB: `captured` is NOT reset here. On a real TTY `outSink`/`emit` writes to
  ## stdout and `captured` stays empty; offscreen (tests) it is what the whole
  ## session emitted, so clearing it here would throw away the capture. It is
  ## reset once, in `initTerminalDriver`, at the start of a run.

# ---------------------------------------------------------------------------
# Input (Step 5) -- the unified state machine, then the relays that feed it.
# ---------------------------------------------------------------------------

proc mkKey(code: KeyCode; mods: set[Modifier]; down: bool): Event =
  Event(kind: (if down: KeyDownEvent else: KeyUpEvent),
        key: code, mods: mods)

proc asciiToKey(c: char): KeyCode =
  ## The printable ASCII the terminal types, mapped to a KeyCode -- so a typed
  ## letter is both a KeyDown (apps that only watch keys still see it) and the
  ## TextInputEvent it always was.
  if c in 'a'..'z': KeyCode(ord(KeyA) + (ord(c) - ord('a')))
  elif c in 'A'..'Z': KeyCode(ord(KeyA) + (ord(c) - ord('A')))
  elif c in '0'..'9': KeyCode(ord(Key0) + (ord(c) - ord('0')))
  else:
    case c
    of ' ': KeySpace
    of ',': KeyComma
    of '.': KeyPeriod
    of '/': KeySlash
    of '-': KeyMinus
    of '=': KeyEqual
    of '+': KeyPlus
    else: KeyNone

# --- escape-sequence parsing: turn ESC ... into one Event (emitKey) ---------

proc sgrMouseBtn(b: int): MouseButton =
  ## SGR reports 0=left, 1=middle, 2=right; the uirelays enum is
  ## LeftButton, RightButton, MiddleButton, so the numbers do not line up.
  case b
  of 0: LeftButton
  of 1: MiddleButton
  of 2: RightButton
  else: LeftButton

proc nextClickCount(x, y: int; button: MouseButton): int =
  ## A press within 500 ms, in the same cell neighbourhood, and on the same
  ## button continues a click run (double/triple click), the rule the X11 and
  ## WinAPI drivers apply. The terminal reports no click count, so it is
  ## derived here. Wall-clock time is used deliberately: `getTicks` is CPU
  ## time, and an app idling in `select` accrues almost none, so under the old
  ## code two clicks minutes apart still looked simultaneous.
  let now = int(epochTime() * 1000)
  if now - lastClickTick < 500 and
     abs(x - lastClickX) < 4 and abs(y - lastClickY) < 4 and
     button == lastClickButton:
    inc clickCount
  else:
    clickCount = 1
  lastClickTick = now
  lastClickX = x
  lastClickY = y
  lastClickButton = button
  result = clickCount

proc emitSGRMouse(seq: openArray[uint8]) =
  ## SGR mouse (1006): `ESC [ < button ; Px ; Py M/m`. The trailing `M`/`m`
  ## marks press/release; everything between `<` and it is ASCII decimal.
  ## `button` is raw -- SGR adds no 32 (ctlseqs.ms, "SGR (1006)"): bits 0-1
  ## identity (0=left, 1=middle, 2=right, 3=release), bit 2 Shift, bit 3
  ## Meta/Alt, bit 4 Control, bit 5 motion (1002/1003), bit 6 wheel/tilt
  ## (buttons 4-7), bit 7 extra buttons (8-11). Coordinates are 1-based.
  if seq.len < 7 or seq[2] != ord('<') or seq[^1] notin {ord('M'), ord('m')}:
    return
  let release = seq[^1] == ord('m')
  ## Split the three semicolon-separated numbers between `<` (index 2) and the
  ## final `M`/`m` (index ^1) out of the byte run, capping each so a
  ## pathological report cannot overflow `int`.
  var parts: seq[int] = @[]
  var n = -1
  for k in 3 ..< seq.len - 1:
    let c = seq[k]
    if c in 0x30'u8 .. 0x39'u8:
      if n < 0: n = 0
      if n < 0xFFFF: n = n * 10 + (int(c) - ord('0'))
    elif c == ord(';'):
      parts.add (if n < 0: 0 else: n)
      n = -1
  if n >= 0: parts.add n
  if parts.len != 3: return
  let buttonByte = parts[0].uint32
  let col = parts[1]
  let row = parts[2]
  if (buttonByte and 1'u32 shl 7) != 0'u32:
    ## Buttons 8-11 (`+128`): uirelays has no such button; ignore the report.
    return
  let move = (buttonByte and 1'u32 shl 5) != 0'u32
  let wheel = (buttonByte and 1'u32 shl 6) != 0'u32
  let shift = (buttonByte and 1'u32 shl 2) != 0'u32
  let alt = (buttonByte and 1'u32 shl 3) != 0'u32
  let ctrl = (buttonByte and 1'u32 shl 4) != 0'u32
  let btnbits = (buttonByte and 3'u32).int
  var mods: set[Modifier] = {}
  if shift: mods.incl ShiftPressed
  if ctrl: mods.incl CtrlPressed
  if alt: mods.incl AltPressed
  let mx = if col > 0: col - 1 else: 0
  let my = if row > 0: row - 1 else: 0
  if release:
    eventQueue.add Event(kind: MouseUpEvent, x: mx, y: my,
                         button: sgrMouseBtn(btnbits), mods: mods)
  elif wheel:
    ## Buttons 4/5 (`+64`) scroll vertically; 6/7 (`+64`, bit 1 set) tilt
    ## horizontally (ctlseqs.ms, "Other buttons"). Deltas live in `x`/`y`
    ## like the native drivers; bit 0 gives the sign, +1 = up or right.
    let positive = (buttonByte and 1'u32) == 0'u32
    let delta = (if positive: 1 else: -1)
    if (buttonByte and 2'u32) != 0'u32:
      eventQueue.add Event(kind: MouseWheelEvent, x: delta, y: 0, mods: mods)
    else:
      eventQueue.add Event(kind: MouseWheelEvent, x: 0, y: delta, mods: mods)
  elif move:
    eventQueue.add Event(kind: MouseMoveEvent, x: mx, y: my, mods: mods)
  else:
    let btn = sgrMouseBtn(btnbits)
    eventQueue.add Event(kind: MouseDownEvent, x: mx, y: my,
                         button: btn, mods: mods,
                         clicks: nextClickCount(mx, my, btn))

proc modsFromParam(p: int): set[Modifier] =
  ## xterm's modifier parameter in a CSI sequence: 1 plus a bitmask, 1=Shift,
  ## 2=Alt, 4=Ctrl, 8=Meta. So `ESC[1;5A` is Ctrl+Up and `ESC[3;2~` is
  ## Shift+Delete.
  if p <= 1: return {}
  let m = p - 1
  if (m and 1) != 0: result.incl ShiftPressed
  if (m and 2) != 0: result.incl AltPressed
  if (m and 4) != 0: result.incl CtrlPressed
  if (m and 8) != 0: result.incl GuiPressed

proc emitKeyPair(code: KeyCode; mods: set[Modifier]) =
  ## A key press is reported as a down/up pair, so an app that watches only
  ## KeyDown still sees exactly one edge.
  eventQueue.add mkKey(code, mods, true)
  eventQueue.add mkKey(code, mods, false)

proc emitSS3(fn: uint8) =
  ## `\eO <fn>`: the application-cursor SS3 arrows and function keys. SS3 has
  ## no modifier parameter, so these are always unmodified.
  case fn
  of ord('A'): emitKeyPair(KeyUp, {})
  of ord('B'): emitKeyPair(KeyDown, {})
  of ord('C'): emitKeyPair(KeyRight, {})
  of ord('D'): emitKeyPair(KeyLeft, {})
  of ord('H'): emitKeyPair(KeyHome, {})
  of ord('F'): emitKeyPair(KeyEnd, {})
  of ord('P'): emitKeyPair(KeyF1, {})
  of ord('Q'): emitKeyPair(KeyF2, {})
  of ord('R'): emitKeyPair(KeyF3, {})
  of ord('S'): emitKeyPair(KeyF4, {})
  else: discard

proc emitCSI(seq: openArray[uint8]) =
  ## `seq` is a complete CSI: ESC, '[', params, final byte.
  if seq.len >= 3 and seq[2] == ord('<'):
    ## Private CSI mouse (SGR, 1006): ESC [ <btn> ;col ;row M(m). The `<` sits
    ## at index 2 (seq[0]=ESC, seq[1]='['), so the raw scan for it at index 1
    ## never matched; hand the whole sequence to the SGR parser instead.
    emitSGRMouse(seq)
    return
  let final = seq[^1]
  var params: seq[int] = @[]
  var n = -1
  for k in 2 ..< seq.len - 1:
    let c = seq[k]
    if c.chr in '0'..'9':
      n = (if n < 0: 0 else: n) * 10 + (c.ord - '0'.ord)
    elif c.chr == ';':
      params.add (if n < 0: 0 else: n)
      n = -1
  if n >= 0: params.add n
  let p0 = if params.len > 0: params[0] else: 0
  ## The second parameter, when present, is the modifier (modsFromParam); it
  ## decorates the arrows, Home/End, Delete and the F-keys.
  let mods = if params.len > 1: modsFromParam(params[1]) else: {}
  case final
  of ord('A'): emitKeyPair(KeyUp, mods)
  of ord('B'): emitKeyPair(KeyDown, mods)
  of ord('C'): emitKeyPair(KeyRight, mods)
  of ord('D'): emitKeyPair(KeyLeft, mods)
  of ord('H'), ord('f'):
    if p0 in {0, 1}: emitKeyPair(KeyHome, mods)
  of ord('F'):
    ## PC-style End in normal cursor mode; application mode sends SS3 F (handled
    ## in `emitSS3`). F5-F12 and the VT220 editing keys use the `~` forms below.
    if p0 in {0, 1}: emitKeyPair(KeyEnd, mods)
  of ord('Z'):
    ## Shift+Tab is its own sequence, with no parameter to carry the modifier.
    emitKeyPair(KeyTab, {ShiftPressed})
  of ord('P'), ord('Q'), ord('R'), ord('S'):
    ## F1-F4 with a modifier: xterm switches the SS3 prefix to CSI when the
    ## sequence carries a modifier parameter (`CSI 1;mod P..S`). The bare
    ## `CSI P..S` form is accepted too for terminals that use it unmodified.
    if p0 in {0, 1}:
      case final
      of ord('P'): emitKeyPair(KeyF1, mods)
      of ord('Q'): emitKeyPair(KeyF2, mods)
      of ord('R'): emitKeyPair(KeyF3, mods)
      else: emitKeyPair(KeyF4, mods)
  of ord('~'):
    ## ctlseqs.ms, "PC-Style Function Keys": F5=15~, then 17~..21~ for
    ## F6..F10 and 23~, 24~ for F11, F12. 16 and 22 are unassigned, so the old
    ## 16..22 run shifted every key from F6 on by one.
    case p0
    of 1, 7: emitKeyPair(KeyHome, mods)
    of 2: emitKeyPair(KeyInsert, mods)
    of 3: emitKeyPair(KeyDelete, mods)
    of 4, 8: emitKeyPair(KeyEnd, mods)
    of 5: emitKeyPair(KeyPageUp, mods)
    of 6: emitKeyPair(KeyPageDown, mods)
    of 11: emitKeyPair(KeyF1, mods)
    of 12: emitKeyPair(KeyF2, mods)
    of 13: emitKeyPair(KeyF3, mods)
    of 14: emitKeyPair(KeyF4, mods)
    of 15: emitKeyPair(KeyF5, mods)
    of 17: emitKeyPair(KeyF6, mods)
    of 18: emitKeyPair(KeyF7, mods)
    of 19: emitKeyPair(KeyF8, mods)
    of 20: emitKeyPair(KeyF9, mods)
    of 21: emitKeyPair(KeyF10, mods)
    of 23: emitKeyPair(KeyF11, mods)
    of 24: emitKeyPair(KeyF12, mods)
    else: discard
  of ord('I'):
    ## Focus in/out, when mode 1004 is enabled. They carry no payload. A
    ## terminal may report the same transition more than once (blur *and*
    ## deactivate both send `CSI O`), so the state is only reported when it
    ## actually changes.
    if gFocus != 1'i8:
      gFocus = 1'i8
      eventQueue.add Event(kind: WindowFocusGainedEvent)
  of ord('O'):
    if gFocus != 0'i8:
      gFocus = 0'i8
      eventQueue.add Event(kind: WindowFocusLostEvent)
  of ord('m'), ord('d'), ord('T'):
    ## SGR attributes, cursor-position, page-scroll: nothing to report.
    discard
  else:
    discard

proc emitEscape(bytes: openArray[uint8]; i: var int) =
  ## Parse the escape sequence starting at `bytes[i]` (a leading ESC), consuming
  ## it and setting `i` past it. Leaves `i` unmoved when the sequence is cut off
  ## mid-way (held in `escAccum` for next time).
  if i + 1 >= bytes.len:
    escAccum.add char(0x1B'u8)
    return
  let c = bytes[i + 1]
  if c == ord('['):
    ## CSI: the DEC grammar treats parameter and intermediate bytes (0x20-0x3F,
    ## which includes `<`, digits, and `;`) as one class that may intermix in
    ## any order before the single final byte (0x40-0x7E). The old two-scan
    ## stopped at `;` (0x3B), which broke SGR mouse sequences; merge to a single
    ## range so the whole CSI reaches emitCSI.
    var j = i + 2
    while j < bytes.len and bytes[j] in 0x20'u8 .. 0x3F'u8: inc j
    if j < bytes.len and bytes[j] in 0x40'u8 .. 0x7E'u8:
      var seq = newSeq[uint8](j - i + 1)
      for k in i .. j: seq[k - i] = bytes[k]
      emitCSI(seq)
      i = j + 1
    else:
      escAccum.setLen 0
      for k in i ..< bytes.len: escAccum.add char(bytes[k])
      return
  elif c == ord('O'):
    if i + 2 < bytes.len:
      emitSS3(bytes[i + 2])
      i = i + 3
    else:
      escAccum = "\eO"
      return
  else:
    ## A two-byte sequence. A printable following is the lone Escape key (a real
    ## Escape press), reprocessed as text; a control following (`ESC 7`, `ESC =`,
    ## ...) is swallowed.
    if c in 0x20'u8 .. 0x7E'u8 and c != ord(' '):
      eventQueue.add mkKey(KeyEsc, {}, true)
      i = i + 1          # reprocess the following byte as text next iteration
    else:
      i = i + 2

proc newTextInput(cp: uint32): Event =
  ## One UTF-8 codepoint as a TextInputEvent: its bytes in `e.text`, the rest
  ## zeroed, exactly the X11-driver contract.
  var chArr: array[4, char]
  let n = utf8Encode(cp, chArr)
  result = Event(kind: TextInputEvent)
  for k in 0 ..< 4: result.text[k] = '\0'
  for k in 0 ..< n: result.text[k] = chArr[k]

proc feedBytes*(bytes: openArray[uint8]) =
  ## The unified input machine (PLAN 6.2): at a codepoint boundary, an ESC starts
  ## an escape sequence (key or mouse); anything else is one UTF-8 codepoint,
  ## emitted as a single TextInputEvent. A partial sequence at the end is held
  ## for the next call, so a codepoint or escape split across reads stays whole.
  var work: seq[uint8] = @bytes
  if escAccum.len > 0:
    work = newSeq[uint8](escAccum.len + bytes.len)
    for i, c in escAccum: work[i] = c.uint8
    for j, c in bytes: work[escAccum.len + j] = c
    escAccum.setLen 0
  var i = 0
  while i < work.len:
    let b = work[i]
    if utf8State.n == 0 and b == 0x1B'u8:
      let saveI = i
      emitEscape(work, i)
      if i == saveI: break    # held for more bytes; stop this chunk
      continue
    let wasPartial = utf8State.n > 0
    let (res, val) = decodeByte(utf8State, b)
    case res
    of drAscii:
      case b
      of 9:
        eventQueue.add mkKey(KeyTab, {}, true); eventQueue.add mkKey(KeyTab, {}, false)
      of 10, 13:
        eventQueue.add mkKey(KeyEnter, {}, true); eventQueue.add mkKey(KeyEnter, {}, false)
      of 8, 127:
        eventQueue.add mkKey(KeyBackspace, {}, true); eventQueue.add mkKey(KeyBackspace, {}, false)
      of 32 .. 126:
        let k = asciiToKey(chr(b))
        if k != KeyNone:
          eventQueue.add mkKey(k, {}, true); eventQueue.add mkKey(k, {}, false)
        eventQueue.add newTextInput(b.uint32)
      else:
        ## The remaining C0 controls are Ctrl combinations: 1..26 are Ctrl+A ..
        ## Ctrl+Z, 0 is Ctrl+Space. Ctrl+\, Ctrl+] and friends have no KeyCode,
        ## so they carry KeyNone with Ctrl rather than a wrong key.
        var k = KeyNone
        if b.int == 0:
          k = KeySpace
        elif b.int >= 1 and b.int <= 26:
          k = KeyCode(ord(KeyA) + (b.int - 1))
        emitKeyPair(k, {CtrlPressed})
      inc i
    of drCodepoint:
      eventQueue.add newTextInput(val)
      inc i
    of drPartial:
      ## The decoder now holds the bytes so far and the rest of this codepoint
      ## arrives in a later read; `utf8State` is module state, so the sequence
      ## survives the call. (This used to `break`, which discarded every
      ## multi-byte codepoint -- umlauts never reached the app at all.)
      inc i
    of drError:
      eventQueue.add newTextInput(0xFFFD)
      if wasPartial:
        ## A bad continuation: the decoder reset and did not consume `b`, so
        ## reprocess it as a fresh byte -- it may be a valid lead.
        discard
      else:
        inc i       # invalid lead byte: consume it

proc drainInput(): bool =
  ## Read every pending byte, parse it into the event queue. Returns whether any
  ## byte was read. This is the single place input enters, so `waitEvent` and
  ## `sleep` keep pumping it (PLAN R8): the OS never sees a starving app.
  var tv = zeroTimeval()
  var fds: TFdSet
  FD_ZERO(fds)
  FD_SET(STDIN_FILENO, fds)
  if select(STDIN_FILENO + 1, fds.addr, nil, nil, tv.addr) <= 0:
    return false
  var data = newSeq[uint8](DrainMax)
  var n = 0
  while n < DrainMax:
    var probe: TFdSet
    FD_ZERO(probe)
    FD_SET(STDIN_FILENO, probe)
    var tv0 = zeroTimeval()
    if select(STDIN_FILENO + 1, probe.addr, nil, nil, tv0.addr) <= 0: break
    let r = read(STDIN_FILENO, unsafeAddr data[n], 1)
    if r > 0: inc n
    else: break
  if n > 0:
    feedBytes(data[0 ..< n])
    return true
  return false

proc handleResizeEvent() =
  ## A SIGWINCH fired: re-query the size, resize the surface, and deliver one
  ## WindowMetricsEvent so an app listening for a single resize stays correct.
  gWinch = false
  if tty:
    let (nr, nc) = queryWinsize()
    resizeSurface(nr, nc)
  eventQueue.add Event(kind: WindowMetricsEvent,
                       x: cols, y: rows, scaleX: 1, scaleY: 1, uiScale: 100)

proc drainSignalPipe() =
  ## Empty the self-pipe. The flags the handlers set are what the code acts on;
  ## the bytes are only there to make `select` return.
  if sigFd[0] < 0: return
  var buf: array[64, uint8]
  while read(sigFd[0], addr buf[0], buf.len) > 0:
    discard

proc waitReady(timeoutMs: int): bool =
  ## Block until an event is queued, the timeout expires, or shutdown fires.
  ## Pumps input on every iteration so a real terminal never reports "not
  ## responding" while waiting (PLAN R8).
  let start = getTicks()
  while true:
    if eventQueue.len > 0: return true
    if gWinch:
      handleResizeEvent()
      return true
    if gShutdown:
      eventQueue.add Event(kind: QuitEvent)
      return true
    var tv = zeroTimeval()
    var tvptr: ptr Timeval = nil
    if timeoutMs >= 0:
      var rem = timeoutMs - (getTicks() - start)
      if rem <= 0: return false
      tv.tv_sec = posix.Time(rem div 1000)
      tv.tv_usec = posix.Suseconds((rem mod 1000) * 1000)
      tvptr = tv.addr
    var fds: TFdSet
    FD_ZERO(fds)
    FD_SET(STDIN_FILENO, fds)
    var nfds = STDIN_FILENO + 1
    if sigFd[0] >= 0:
      FD_SET(sigFd[0], fds)
      if sigFd[0] >= nfds: nfds = sigFd[0] + 1
    let n = select(cint(nfds), fds.addr, nil, nil, tvptr)
    if n > 0:
      drainSignalPipe()
      discard drainInput()
    elif timeoutMs < 0 and n < 0:
      continue   # EINTR from a signal handler: block again
    else:
      if timeoutMs < 0:
        if n > 0 or eventQueue.len > 0: continue
        return false   # truly blocked and nothing came
      var rem = timeoutMs - (getTicks() - start)
      if rem <= 0: return false

# ---------------------------------------------------------------------------
# The input relays, installed from initTerminalDriver (so the proc bodies can
# close over the module state without ordering issues).
# ---------------------------------------------------------------------------

var gPollEventImpl: proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.}
var gWaitEventImpl: proc (e: var Event; timeoutMs: int;
                         flags: set[InputFlag]): bool {.nimcall.}

proc pollEvent*(e: var Event; flags: set[InputFlag] = {}): bool =
  gPollEventImpl(e, flags)
proc waitEvent*(e: var Event; timeoutMs: int = -1;
                flags: set[InputFlag] = {}): bool =
  gWaitEventImpl(e, timeoutMs, flags)
proc getTicks*(): int =
  ## Monotonic milliseconds; `cpuTime` is monotonic for this process.
  int(cpuTime() * 1000.0)
proc sleep*(ms: int) =
  ## Sleep, but pump input the whole time (R8): a sleeping terminal app must
  ## still see the user press a key.
  discard waitReady(ms)
proc leaveTerminal()   ## forward decl: installed with the terminal, below
proc shutdown*() =
  if tty:
    leaveTerminal()
  gShutdown = true

# ---------------------------------------------------------------------------
# Signals, raw mode, the alternate buffer (Step 4 + PLAN R2).
# ---------------------------------------------------------------------------

proc installSignals() =
  ## A self-pipe: each handler records its flag *and* writes one byte, and
  ## `waitReady` selects on the read end. `signal()` installs with SA_RESTART
  ## on glibc, so a blocking `select()` would be restarted rather than return
  ## EINTR; the pipe byte is what actually wakes it, and it also closes the
  ## race where the signal lands between the flag check and the select. (The
  ## handlers used to be `discard gWinch`, which read the flag and threw it
  ## away instead of setting it -- so nothing was ever signalled.)
  if sigFd[0] < 0:
    if c_pipe(addr sigFd) == 0:
      discard fcntl(sigFd[0], F_SETFL, O_NONBLOCK)
      discard fcntl(sigFd[1], F_SETFL, O_NONBLOCK)
  proc onWinch(sig: cint) {.noconv.} =
    gWinch = true
    discard write(sigFd[1], addr sigByte, 1)
  proc onTerm(sig: cint) {.noconv.} =
    gShutdown = true
    discard write(sigFd[1], addr sigByte, 1)
  proc onInt(sig: cint) {.noconv.} =
    gShutdown = true
    discard write(sigFd[1], addr sigByte, 1)
  signal(SIGWINCH, onWinch)
  signal(SIGINT, onInt)
  signal(SIGTERM, onTerm)

proc nonblock(enabled: bool) =
  var st: Termios
  discard tcGetAttr(STDIN_FILENO, st.addr)
  if enabled:
    st.c_lflag = st.c_lflag and not Cflag(ICANON or ECHO)
    st.c_cc[VMIN] = 0.char
  else:
    st.c_lflag = st.c_lflag or ICANON or ECHO
  discard tcSetAttr(STDIN_FILENO, TCSANOW, st.addr)

proc enterTerminal() =
  installSignals()
  nonblock(true)
  stdout.write "\e[?1049h"   # alternate screen buffer
  stdout.write "\e[?1003h"   # mouse: clicks and all motion
  stdout.write "\e[?1006h"   # mouse: SGR encoding
  stdout.write "\e[?1004h"   # focus in/out reports (CSI I / CSI O)
  stdout.flushFile()
  hideCursor()
proc leaveTerminal() =
  stdout.write "\e[?1004l\e[?1003l\e[?1006l\e[?1049l\e[0m"
  stdout.flushFile()
  showCursor()
  nonblock(false)
  signal(SIGWINCH, SIG_DFL)
  signal(SIGINT, SIG_DFL)
  signal(SIGTERM, SIG_DFL)

# ---------------------------------------------------------------------------
# Wiring (Step 6): the one init the backend calls.
# ---------------------------------------------------------------------------

proc initTerminalDriver*() =
  ## Install the relays. The real terminal setup happens in `createWindow`, so
  ## importing this module touches nothing -- safe even when the driver is
  ## compiled in but never used.
  eventQueue.setLen 0
  clipStack.setLen 0
  captured.setLen 0
  escAccum.setLen 0
  utf8State = newUtf8Decoder()
  gFocus = -1'i8
  gFirstFrame = true

  ## Populate the five global relays. Each field here points at a module-level
  ## proc defined above; the default stubs (in screen.nim / input.nim) are left
  ## for clipboard, which v1 does not talk to.
  windowRelays = WindowRelays(
    createWindow: createWindow, getWindowLayout: getWindowLayout,
    refresh: refresh, saveState: saveState, restoreState: restoreState,
    setClipRect: setClipRect, setCursor: setCursor,
    setWindowTitle: setWindowTitle)
  fontRelays = FontRelays(
    openFont: openFont, closeFont: closeFont,
    getFontMetrics: getFontMetrics, measureText: measureText,
    drawText: drawText, drawMeasuredText: drawMeasuredText)
  drawRelays = DrawRelays(
    fillRect: fillRect, drawLine: drawLine, drawPoint: drawPoint)
  inputRelays = InputRelays(
    pollEvent: pollEvent, waitEvent: waitEvent,
    getTicks: getTicks, sleep: sleep, shutdown: shutdown)
  ## OSC 52 for writes; reads are not attempted (see `clipboardRead`).
  clipboardRelays = ClipboardRelays(getText: clipboardRead,
                                    putText: clipboardWrite)

  gPollEventImpl = proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.} =
    if eventQueue.len > 0:
      e = eventQueue[0]
      eventQueue.delete(0)
      return true
    drainSignalPipe()
    discard drainInput()
    if eventQueue.len > 0:
      e = eventQueue[0]
      eventQueue.delete(0)
      return true
    if gWinch:
      handleResizeEvent()
      return true
    false

  gWaitEventImpl = proc (e: var Event; timeoutMs: int;
                         flags: set[InputFlag]): bool {.nimcall.} =
    if waitReady(timeoutMs):
      e = eventQueue[0]
      eventQueue.delete(0)
      return true
    false
