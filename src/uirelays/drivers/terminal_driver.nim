## Terminal backend for uirelays.
##
## Renders uirelays apps as a full-screen terminal program instead of a GUI
## window. The model, from PLAN.md, is deliberately simple:
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
## below is what runs, and on Windows the driver simply stays a no-op surface
## until the console backend is ported.

import uirelays/[coords, screen, input]
import posix/termios
import posix/posix
import std/terminal   # hideCursor, showCursor, setCursorPos
import std/times       # cpuTime

# ---------------------------------------------------------------------------
# The cell, and the module-level state that one live surface keeps.
# ---------------------------------------------------------------------------

type
  Cell* = object
    ## One screen cell, kept in two buffers: `buf` (what this frame will show)
    ## and `lastBuf` (what the previous frame showed, to diff against). The
    ## colour fields are what the *app* asked for (already composited for
    ## alpha), which is also exactly what the diff needs to compare.
    ch*: char
    fg*, bg*: Color
    attr*: uint16      ## bit 0 = bold; the terminal's only other easy flourish

  Utf8Decoder* = object
    ## State of the incremental UTF-8 decoder (Step 5a): how many more
    ## continuation bytes a codepoint needs, the value folded so far, and the
    ## largest value a sequence of this length may hold (RFC 3629).
    n*: int            ## continuation bytes still needed (0 = at a boundary)
    value*: uint32     ## the codepoint folded so far
    maxVal*: uint32    ## upper bound for the sequence in progress
    totalLen*: int     ## how long this sequence is, for the split-read case

  DecResult* = enum
    drAscii, drCodepoint, drPartial, drError

const
  KeySequenceMaxLen = 100      ## longest key sequence seen; per-cycle cap too
  DrainMax = 16 * 1024         ## bytes drained from the terminal in one poll
  MaxChangedFrame = 256 * 1024 ## per-frame output cap, focim/terminal.nim's MaxPerFrame
  ResetAttr: uint16 = 0'u16

# Surface state. All of it is reset by `createEmptySurface`.
var
  cols, rows*: int
  buf, lastBuf: seq[Cell]
  clip*: Rect = Rect(x: 0, y: 0, w: 0, h: 0)
  clipStack: seq[Rect]
  gFirstFrame = true
  g256 = false
  tty = false                    ## attached to a real terminal
  captured*: string              ## offscreen: every emitted byte, for tests
  gWinch = false                 ## SIGWINCH fired; a resize is pending
  gShutdown = false              ## SIGINT/SIGTERM fired; a Quit is pending
  curMods: set[Modifier]
  escAccum: string               ## an escape sequence cut off mid-way, held
  eventQueue: seq[Event]
  outSink: proc (s: string) {.nimcall.}

# ---------------------------------------------------------------------------
# Colour (Step 1) -- ported verbatim from focim/src/focim/ansi.nim, which is
# exactly the 24-bit / 256-colour -> 16-colour reduction this needs.
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

proc cubeColor(idx: int): int =
  ## A 256-colour index folded to one of the sixteen (see ansi.nim).
  if idx < 16: idx
  elif idx < 232:
    let n = idx - 16
    template level(v: int): int = (if v == 0: 0 else: 55 + 40 * v)
    nearest(level(n div 36), level((n div 6) mod 6), level(n mod 6))
  else:
    let v = 8 + 10 * (idx - 232)
    nearest(v, v, v)

proc termColor*(c: Color; bg: bool = false): string =
  ## The SGR parameter string to paint colour `c` (background when `bg`):
  ## `38;5;n` / `48;5;n` when the terminal advertises 256 colours, otherwise
  ## the plain `30 + i` / `90 + i` of the nearest of the sixteen. This is the
  ## one public colour entry point; everything inside the driver builds on it.
  ##
  ## Alpha is not representable in a cell attribute: `drawText`/`fillRect`
  ## composite against their own background before they get here, so by the
  ## time a colour reaches `termColor` it is already opaque.
  let idx = nearest(c.r, c.g, c.b)
  if g256:
    (if bg: "48;5;" else: "38;5;") & $idx
  else:
    let base = (if bg: 40'u8 else: 30'u8)
    let bright = uint8(if idx >= 8: 8 else: 0)
    $(base + bright + uint8(idx))

# ---------------------------------------------------------------------------
# UTF-8 (Step 5a) -- the incremental decoder the stdlib has none of.
# ---------------------------------------------------------------------------

proc leadLen(b: uint8): int =
  ## How many bytes a lead byte starts: 0x00-0x7F -> 1, 0xC2-0xDF -> 2,
  ## 0xE0-0xEF -> 3, 0xF0-0xF4 -> 4, 0xC0/0xC1/0xF5-0xFF -> invalid (0).
  when defined(nimIntSize64):
    const T = [0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
               0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
               0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
               0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
               0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
               0,0,2,2,2,2,2,2, 2,2,2,2,2,2,2,2, 3,3,3,3,3,3,3,3,
               4,4,4,4,4,0,0,0]
    T[b.int]
  else:
    when false:
      discard
    else:
      if b < 0x80: 1
      elif b <= 0xDF: 2
      elif b <= 0xEF: 3
      elif b <= 0xF4: 4
      else: 0

proc maxValForLen(k: int): uint32 =
  ## Largest codepoint a k-byte sequence can even encode (used to reject
  ## values that overflow, i.e. overlong and the U+110000+ that RFC 3629
  ## forbids).
  uint32(1) uint32 ((k) * 5) - 1
    ## 2 bytes: 0x7FF, 3: 0xFFFF, 4: 0x10FFFF  (== (1<<(5*k))-1)

proc newUtf8Decoder(): Utf8Decoder =
  Utf8Decoder(n: 0, value: 0'u32, maxVal: 0'u32, totalLen: 1)

proc decodeByte*(d: var Utf8Decoder; b: uint8): tuple[result: DecResult, value: uint32] =
  ## One byte into the decoder. `drPartial` means "need more bytes" and the
  ## decoder keeps everything it has; `drError` means "this byte is not what a
  ## valid sequence wanted" and the caller reprocesses it (it is not advanced
  ## past unless it was an invalid *lead* byte, handled by the caller).
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
      # A bad continuation byte: the codepoint in progress is dead, and this
      # byte may start something fresh, so drop the half-sequence and let the
      # caller reprocess it without advancing.
      result = (drError, 0xFFFD'u32)
      d = newUtf8Decoder()
    return
  # At a codepoint boundary.
  if b < 0x80'u8:
    result = (drAscii, b.uint32)
    return
  let k = leadLen(b)
  if k == 0:
    ## 0xC0/0xC1, 0xF5-0xFF: an invalid lead byte.
    result = (drError, 0xFFFD'u32)
    return
  if k == 1:
    result = (drAscii, b.uint32)
    return
  d.totalLen = k
  d.value = b and ((1 uint32 (8 - k)) - 1'u8).uint32
  d.maxVal = maxValForLen(k)
  d.n = k - 1
  result = (drPartial, 0'u32)

proc utf8Encode*(cp: uint32; out: var array[4, char]): int =
  ## Encode a codepoint into `out`, returning how many bytes were written.
  if cp < 0x80:
    out[0] = char(cp)
    1
  elif cp < 0x800:
    out[0] = char(0xC0'u8 or uint8(cp shr 6))
    out[1] = char(0x80'u8 or uint8(cp and 0x3F))
    2
  elif cp < 0x10000:
    out[0] = char(0xE0'u8 or uint8(cp shr 12))
    out[1] = char(0x80'u8 or uint8((cp shr 6) and 0x3F))
    out[2] = char(0x80'u8 or uint8(cp and 0x3F))
    3
  else:
    out[0] = char(0xF0'u8 or uint8(cp shr 18))
    out[1] = char(0x80'u8 or uint8((cp shr 12) and 0x3F))
    out[2] = char(0x80'u8 or uint8((cp shr 6) and 0x3F))
    out[3] = char(0x80'u8 or uint8(cp and 0x3F))
    4

# ---------------------------------------------------------------------------
# Cell helpers (Step 2) -- the drawing primitives all funnel through here,
# honouring the clip rect, bounds-checked, so nothing writes off the surface.
# ---------------------------------------------------------------------------

proc makeCell(ch: char; fg, bg: Color; bold = false): Cell =
  Cell(ch: ch, fg: fg, bg: bg, attr: (if bold: 1'u16 else: ResetAttr))

proc setCell(x, y: int; cell: Cell) =
  if x < 0 or y < 0 or x >= cols or y >= rows: return
  if x < clip.x or x >= clip.x + clip.w or y < clip.y or y >= clip.y + clip.h:
    return
  buf[y * cols + x] = cell

proc setCellColor(x, y: int; fg, bg: Color; ch = ' '; bold = false) =
  setCell(x, y, makeCell(ch, fg, bg, bold))

# ---------------------------------------------------------------------------
# Draw relays (Step 2).
# ---------------------------------------------------------------------------

proc drawRectCells(x, y, w, h: int; fg, bg: Color) =
  ## Fill the cell rectangle [x, x+w) x [y, y+h). Bounds + clip handled per cell.
  var x0 = if x < 0: 0 else: x
  var y0 = if y < 0: 0 else: y
  var x1 = if x + w > cols: cols else: x + w
  var y1 = if y + h > rows: rows else: y + h
  for yy in y0 ..< y1:
    for xx in x0 ..< x1:
      setCell(xx, yy, makeCell(' ', fg, bg))

proc fillRect*(r: Rect; color: Color) =
  ## A solid block: both the glyph and its colour are `color`. Alpha was
  ## composited into `color` by the caller, so this is a flat coloured region.
  let c = if color.a >= 255: color else:
            color*(color.r, color.g, color.b)  # over its own background
  drawRectCells(r.x, r.y, r.w, r.h, c, c)

proc drawPoint*(x, y: int; color: Color) =
  let c = (if color.a >= 255: color else: color*(color.r, color.g, color.b))
  setCellColor(x, y, c, c)

proc drawLine*(x1, y1, x2, y2: int; color: Color) =
  ## Bresenham's line over cells: uniform spacing via the decision parameter,
  ## so a diagonal is a steady 2:1 step and not the jagged look of rounding
  ## each float.
  let c = (if color.a >= 255: color else: color*(color.r, color.g, color.b))
  let dx = abs(x2 - x1)
  let dy = -abs(y2 - y1)
  var sx = (if x1 < x2: 1 else: -1)
  var sy = (if y1 < y2: 1 else: -1)
  var err = (dx + dy) div 2
  var cx, cy = x1
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
  ## One pixel per cell (cell==pixel), one row tall.
  result = TextExtent(w: text.len, h: 1)

proc drawTextBody*(f: Font; x, y: int; text: string;
                   fg, bg: Color; known: TextExtent): TextExtent =
  ## Stamp each character into the cell buffer over the clip rect, painting the
  ## *full* background of every cell in the run so a label drawn over a coloured
  ## box reads clean. Returns the same extent `measureText` would.
  let res = (if known.w > 0: known else: measureText(f, text))
  var cx = x
  for ch in text:
    if cx >= clip.x and cx < clip.x + clip.w and y >= clip.y and y < clip.y + clip.h
       and cx >= 0 and y >= 0 and cx < cols and y < rows:
      setCell(cx, y, makeCell(ch, fg, bg))
    inc cx
  res

proc drawText*(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
  let fg2 = (if fg.a >= 255: fg else: fg*(fg.r, fg.g, fg.b))
  let bg2 = (if bg.a >= 255: bg else: bg*(bg.r, bg.g, bg.b))
  drawTextBody(f, x, y, text, fg2, bg2, TextExtent())

proc drawMeasuredText*(f: Font; x, y: int; text: string;
                       fg, bg: Color; size: TextExtent): TextExtent =
  ## The same body, for a caller that already measured: a shortcut, not a
  ## second way to draw.
  let fg2 = (if fg.a >= 255: fg else: fg*(fg.r, fg.g, fg.b))
  let bg2 = (if bg.a >= 255: bg else: bg*(bg.r, bg.g, bg.b))
  drawTextBody(f, x, y, text, fg2, bg2, size)

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
  if nr <= 0: nr = 24
  if nc <= 0: nc = 80
  if nr == rows and nc == cols: return
  cols = nc
  rows = nr
  buf.setLen(rows * cols)
  lastBuf.setLen(rows * cols)
  gFirstFrame = true
  ## An empty cell is a space on the default (black-on-black) background; a full
  ## redraw clears the stale cells from the old size.
  for i in 0 ..< buf.len:
    buf[i] = makeCell(' ', Color(r: 0, g: 0, b: 0),
                          Color(r: 0, g: 0, b: 0))

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
  tty = isatty(STDIN_FILENO) > 0 and isatty(1) > 0
  g256 = "256color" in getEnv("TERM")
  if tty:
    let (nr, nc) = queryWinsize()
    resizeSurface(nr, nc)
    if layout.width == 0 and layout.height == 0:
      discard
  else:
    resizeSurface(reqH, reqW)   # offscreen: requested height/width are cells
  if rows == 0 or cols == 0:
    resizeSurface(24, 80)
  layout.width = cols
  layout.height = rows
  layout.pitch = cols
  layout.scaleX = 1
  layout.scaleY = 1
  layout.uiScale = 100         # a terminal is already at native cell size
  layout.fullScreen = true
  outSink = if tty: (proc (s: string) {.nimcall.} =
                       stdout.write s; stdout.flushFile())
            else: (proc (s: string) {.nimcall.} = captured.add s)
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
  ## A terminal has no shaped cursor to show; hide it while drawing and let the
  ## app restore it via `hideCursor`/`showCursor` if it wants a text cursor.
  if c == curDefault or c == curIbeam:
    showCursor()
  else:
    hideCursor()
proc setWindowTitle*(title: string) =
  ## Best effort: an OSC 0 title. Ignored by terminals that do not honour it.
  if tty:
    outSink("\e]0;" & title & "\a")

# ---------------------------------------------------------------------------
# The frame: diff buf against lastBuf and emit only the changed cells.
# ---------------------------------------------------------------------------

proc emitCell(sb: var string; x, y: int; cell: Cell;
              var outCol, outRow: int; var outFg, outBg: Color;
              var outBold: bool) =
  if x != outCol or y != outRow:
    sb.add "\e[" & $((y + 1)) & ";" & $((x + 1)) & "H"
    outCol = x
    outRow = y
    outFg = Color(r: 255, g: 255, b: 255, a: 255)  # force a rewrite
    outBg = outFg
    outBold = false
  if cell.attr and 1'u16 != 0'u16 and not outBold:
    sb.add "\e[1m"; outBold = true
  elif cell.attr and 1'u16 == 0'u16 and outBold:
    sb.add "\e[22m"; outBold = false
  if cell.fg != outFg:
    sb.add "\e[" & termColor(cell.fg, false) & "m"; outFg = cell.fg
  if cell.bg != outBg:
    sb.add "\e[" & termColor(cell.bg, true) & "m"; outBg = cell.bg
  sb.add cell.ch

proc refresh*() =
  ## Copy the new frame's changed cells to the surface (or, offscreen, to the
  ## captured buffer), then remember this frame as the previous one. Bounded by
  ## MaxChangedFrame: past it the frame is too busy to diff cheaply, so a full
  ## clear + redraw wins.
  var sb = ""
  if gFirstFrame:
    sb.add "\e[2J"
    if tty: sb.add "\e[?25l"    # hide the text cursor for the whole app
    gFirstFrame = false
  var changed = 0
  var outCol = -1, outRow = -1
  var outFg = Color(r: 255, g: 255, b: 255, a: 255),
      outBg = Color(r: 255, g: 255, b: 255, a: 255)
  var outBold = false
  var capped = false
  for y in 0 ..< rows:
    for x in 0 ..< cols:
      let idx = y * cols + x
      if buf[idx] != lastBuf[idx]:
        if changed >= MaxChangedFrame:
          capped = true
          break
        emitCell(sb, x, y, buf[idx], outCol, outRow, outFg, outBg, outBold)
        inc changed
    if capped: break
  if capped:
    sb.add "\e[0m\e[2J\e[H"
  sb.add "\e[0m"
  outSink(sb)
  if tty:
    outSink("\e[?25h")          # restore the cursor after the frame
  lastBuf = buf
  captured.setLen 0

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
  if c in 'a'..'z': KeyA + (ord(c) - ord('a'))
  elif c in 'A'..'Z': KeyA + (ord(c) - ord('A'))
  elif c in '0'..'9': Key0 + (ord(c) - ord('0'))
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

proc parseMouseSGR(bytes: openArray[uint8]; start: int): Event =
  ## `\eM <btn> <col> <row>` (or `\em` for release). `start` points at ESC.
  ## 1-based coordinates, subtract one; the button/mods are in the first byte.
  if start + 4 >= bytes.len + 1:
    return Event(kind: NoEvent)
  let btnb = bytes[start + 1].uint32
  let col = bytes[start + 2].uint32
  let row = bytes[start + 3].uint32
  let isRelease = (bytes[start + 1] == ord('m'))
  # The real data bytes follow the `M`/`m`; here the caller points at the M/m
  # already, so read the three bytes after it.
  discard btnb; discard col; discard row; discard isRelease
  result = Event(kind: NoEvent)

# The real SGR-mouse reader needs the three data bytes that come *after* the
# button byte; keep the stub above out of the way and read it inline instead.

proc emitSGRMouse(bytes: openArray[uint8]; mIdx: int) =
  ## `bytes[mIdx]` is the `M`/`m`; the next three bytes are button, col, row.
  if mIdx + 3 >= bytes.len: return
  let buttonByte = bytes[mIdx + 1].uint32
  let col = bytes[mIdx + 2].uint8
  let row = bytes[mIdx + 3].uint8
  let release = bytes[mIdx] == ord('m')
  let move = buttonByte.testBit(5)
  let scroll = buttonByte.testBit(6)
  let shift = buttonByte.testBit(2)
  let ctrl = buttonByte.testBit(4)
  let btnbits = (buttonByte and 3'u32).int
  var mods: set[Modifier] = {}
  if shift: mods.incl ShiftPressed
  if ctrl: mods.incl CtrlPressed
  let mx = if col > 0: col.int - 1 else: 0
  let my = if row > 0: row.int - 1 else: 0
  if release:
    eventQueue.add Event(kind: MouseUpEvent, x: mx, y: my,
                         button: MouseButton(btnbits), mods: mods)
  elif scroll:
    eventQueue.add Event(kind: MouseWheelEvent, x: mx, y: my,
                         mods: mods,
                         y: (if buttonByte.testBit(0): -1 else: 1))
  elif move:
    eventQueue.add Event(kind: MouseMoveEvent, x: mx, y: my, mods: mods)
  else:
    let mb = MouseButton(if btnbits == 2: 2 elif btnbits == 1: 1 else: 0)
    ## 0=left,1=middle,2=right; anything else (button-4/5 modifiers) -> left.
    eventQueue.add Event(kind: MouseDownEvent, x: mx, y: my, button: mb,
                         mods: mods, clicks: 1)

proc emitSS3(fn: uint8) =
  ## `\eO <fn>`: the application-cursor SS3 arrows and function keys.
  case fn
  of ord('A'): eventQueue.add mkKey(KeyUp, curMods, true); eventQueue.add mkKey(KeyUp, curMods, false)
  of ord('B'): eventQueue.add mkKey(KeyDown, curMods, true); eventQueue.add mkKey(KeyDown, curMods, false)
  of ord('C'): eventQueue.add mkKey(KeyRight, curMods, true); eventQueue.add mkKey(KeyRight, curMods, false)
  of ord('D'): eventQueue.add mkKey(KeyLeft, curMods, true); eventQueue.add mkKey(KeyLeft, curMods, false)
  of ord('H'): eventQueue.add mkKey(KeyHome, curMods, true); eventQueue.add mkKey(KeyHome, curMods, false)
  of ord('F'): eventQueue.add mkKey(KeyEnd, curMods, true); eventQueue.add mkKey(KeyEnd, curMods, false)
  of ord('P'): eventQueue.add mkKey(KeyF1, curMods, true); eventQueue.add mkKey(KeyF1, curMods, false)
  of ord('Q'): eventQueue.add mkKey(KeyF2, curMods, true); eventQueue.add mkKey(KeyF2, curMods, false)
  of ord('R'): eventQueue.add mkKey(KeyF3, curMods, true); eventQueue.add mkKey(KeyF3, curMods, false)
  of ord('S'): eventQueue.add mkKey(KeyF4, curMods, true); eventQueue.add mkKey(KeyF4, curMods, false)
  else: discard

proc emitCSI(seq: openArray[uint8]) =
  ## `seq` is a complete CSI: ESC, '[', params, final byte.
  if seq.len >= 2 and seq[1] == ord('<'):
    ## Private CSI mouse: ESC [ <btn> ;col ;row M(m)
    var j = 2
    while j < seq.len and seq[j] != ord('>') and seq[j] != ord('M') and seq[j] != ord('m'):
      inc j
    # find the M/m after the '>'
    var mIdx = -1
    for k in j ..< seq.len:
      if seq[k] in {ord('M'), ord('m')}:
        mIdx = k
        break
    if mIdx >= 0: emitSGRMouse(seq, mIdx)
    return
  let final = seq[^1]
  var params: seq[int] = @[]
  var n = -1
  for k in 2 ..< seq.len - 1:
    let c = seq[k]
    if c in '0'..'9':
      n = (if n < 0: 0 else: n) * 10 + (c.ord - '0'.ord)
    elif c == ';':
      params.add (if n < 0: 0 else: n)
      n = -1
  if n >= 0: params.add n
  let p0 = if params.len > 0: params[0] else: 0
  case final
  of ord('A'): eventQueue.add mkKey(KeyUp, curMods, true); eventQueue.add mkKey(KeyUp, curMods, false)
  of ord('B'): eventQueue.add mkKey(KeyDown, curMods, true); eventQueue.add mkKey(KeyDown, curMods, false)
  of ord('C'): eventQueue.add mkKey(KeyRight, curMods, true); eventQueue.add mkKey(KeyRight, curMods, false)
  of ord('D'): eventQueue.add mkKey(KeyLeft, curMods, true); eventQueue.add mkKey(KeyLeft, curMods, false)
  of ord('H'), ord('f'):
    if p0 in {0, 1}: eventQueue.add mkKey(KeyHome, curMods, true); eventQueue.add mkKey(KeyHome, curMods, false)
  of ord('~'):
    case p0
    of 1, 7: eventQueue.add mkKey(KeyHome, curMods, true); eventQueue.add mkKey(KeyHome, curMods, false)
    of 2: eventQueue.add mkKey(KeyInsert, curMods, true); eventQueue.add mkKey(KeyInsert, curMods, false)
    of 3: eventQueue.add mkKey(KeyDelete, curMods, true); eventQueue.add mkKey(KeyDelete, curMods, false)
    of 4, 8: eventQueue.add mkKey(KeyEnd, curMods, true); eventQueue.add mkKey(KeyEnd, curMods, false)
    of 5, 6: eventQueue.add mkKey(KeyPageUp, curMods, true); eventQueue.add mkKey(KeyPageUp, curMods, false)
    of 6: eventQueue.add mkKey(KeyPageDown, curMods, true); eventQueue.add mkKey(KeyPageDown, curMods, false)
    of 11, 15: eventQueue.add mkKey(KeyF1, curMods, true); eventQueue.add mkKey(KeyF1, curMods, false)
    of 12, 16: eventQueue.add mkKey(KeyF2, curMods, true); eventQueue.add mkKey(KeyF2, curMods, false)
    of 13, 17: eventQueue.add mkKey(KeyF3, curMods, true); eventQueue.add mkKey(KeyF3, curMods, false)
    of 14, 18: eventQueue.add mkKey(KeyF4, curMods, true); eventQueue.add mkKey(KeyF4, curMods, false)
    of 15, 19: eventQueue.add mkKey(KeyF5, curMods, true); eventQueue.add mkKey(KeyF5, curMods, false)
    of 17, 21: eventQueue.add mkKey(KeyF6, curMods, true); eventQueue.add mkKey(KeyF6, curMods, false)
    of 18, 22: eventQueue.add mkKey(KeyF7, curMods, true); eventQueue.add mkKey(KeyF7, curMods, false)
    of 19, 23: eventQueue.add mkKey(KeyF8, curMods, true); eventQueue.add mkKey(KeyF8, curMods, false)
    of 21, 25: eventQueue.add mkKey(KeyF9, curMods, true); eventQueue.add mkKey(KeyF9, curMods, false)
    of 22, 26: eventQueue.add mkKey(KeyF10, curMods, true); eventQueue.add mkKey(KeyF10, curMods, false)
    of 24, 28: eventQueue.add mkKey(KeyF11, curMods, true); eventQueue.add mkKey(KeyF11, curMods, false)
    of 25, 29: eventQueue.add mkKey(KeyF12, curMods, true); eventQueue.add mkKey(KeyF12, curMods, false)
    else: discard
  of ord('m'), ord('d'), ord('S'), ord('T'):
    ## SGR attributes, cursor-position, page-scroll: nothing to report.
    discard
  else:
    discard

proc emitEscape(bytes: openArray[uint8]; i: var int) =
  ## Parse the escape sequence starting at `bytes[i]` (a leading ESC), consuming
  ## it and setting `i` past it. Returns without moving `i` when the sequence
  ## is cut off mid-way (it is held in `escAccum` for next time), or leaves `i`
  ## on the byte after ESC when ESC was a lone Escape key followed by text.
  if i + 1 >= bytes.len:
    escAccum.add char(0x1B'u8)
    return
  let c = bytes[i + 1]
  if c == ord('['):
    ## CSI: params (0x30-0x3F), intermediates (0x20-0x2F), then one final byte.
    var j = i + 2
    while j < bytes.len and bytes[j] in 0x30'u8 .. 0x3F'u8: inc j
    while j < bytes.len and bytes[j] in 0x20'u8 .. 0x2F'u8: inc j
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
  elif c in {ord('M'), ord('m')}:
    ## SGR mouse press/move (`M`) or release (`m`), three data bytes follow.
    if i + 4 < bytes.len:
      emitSGRMouse(bytes, i + 1)
      i = i + 5
    else:
      escAccum.add char(0x1B'u8); escAccum.add c.chr
      return
  else:
    ## A two-byte sequence. Printable followings are the lone Escape key (a
    ## real Escape press) followed by the following byte as ordinary text;
    ## control followings (`ESC 7`, `ESC =`, ...) are swallowed.
    if c in 0x20'u8 .. 0x7E'u8 and c != ord(' '):
      eventQueue.add mkKey(KeyEsc, {}, true)
      i = i + 1          # reprocess the following byte as text next iteration
    else:
      i = i + 2

proc feedBytes*(bytes: openArray[uint8]) =
  ## The unified input machine (PLAN 6.2): at a codepoint boundary, an ESC starts
  ## an escape sequence (key or mouse); anything else is one UTF-8 codepoint,
  ## emitted as a single TextInputEvent. A partial sequence at the end is held
  ## for the next call, so a codepoint or escape split across reads stays whole.
  var work = bytes
  if escAccum.len > 0:
    work = newSeq[uint8](escAccum.len + bytes.len)
    for i, c in escAccum: work[i] = ord(c)
    for j, c in bytes: work[escAccum.len + j] = c
    escAccum.setLen 0
  var d = newUtf8Decoder()
  var i = 0
  while i < work.len:
    let b = work[i]
    if d.n == 0 and b == 0x1B'u8:
      emitEscape(work, i)
      continue
    let (res, val) = decodeByte(d, b)
    case res
    of drAscii:
      ## Printable ASCII: a KeyDown (when it maps to a key) and the text.
      if b in 1 .. 8 or (b in 14 .. 31):
        let k = asciiToKey(chr(b))
        if k != KeyNone:
          curMods = {CtrlPressed}
          eventQueue.add mkKey(k, curMods, true); eventQueue.add mkKey(k, curMods, false)
          curMods = {}
      elif b in 32 .. 126:
        let k = asciiToKey(chr(b))
        if k != KeyNone:
          eventQueue.add mkKey(k, {}, true); eventQueue.add mkKey(k, {}, false)
        # one codepoint of text
        var chArr: array[4, char]
        let n = utf8Encode(b.uint32, chArr)
        var te = Event(kind: TextInputEvent)
        for k in 0 ..< te.text.len: te.text[k] = '\0'
        for k in 0 ..< n: te.text[k] = chArr[k]
        eventQueue.add te
      else:
        discard
    of drCodepoint:
      var chArr: array[4, char]
      let n = utf8Encode(val, chArr)
      var te = Event(kind: TextInputEvent)
      for k in 0 ..< te.text.len: te.text[k] = '\0'
      for k in 0 ..< n: te.text[k] = chArr[k]
      eventQueue.add te
    of drPartial:
      break   # stream ended mid-codepoint; the decoder already holds it
    of drError:
      ## One replacement character. If it was a bad *continuation* byte
      ## (the decoder was mid-sequence), reprocess this byte without advancing;
      ## if it was an invalid *lead* byte, consume it so we do not loop.
      var te = Event(kind: TextInputEvent)
      for k in 0 ..< te.text.len: te.text[k] = '\0'
      for k in 0 ..< 3: te.text[k] = 'Ã' # U+FFFD lead (3 bytes, always fits)
      te.text[1] = '¿'
      eventQueue.add te
      if d.n > 0:
        discard     # mid-sequence: reprocess b fresh, do not advance
      else:
        inc i
    inc i

proc drainInput(): bool =
  ## Read every pending byte, parse it into the event queue. Returns whether any
  ## byte was read. This is the single place input enters, so `waitEvent` and
  ## `sleep` keep pumping it (PLAN R8): the OS never sees a starving app.
  var tv: Timeval
  tv.tv_sec = 0
  tv.tv_usec = 0
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
    let tv0: Timeval = Timeval(tv_sec: 0, tv_usec: 0)
    if select(STDIN_FILENO + 1, probe.addr, nil, nil, tv0.addr) <= 0: break
    let r = read(STDIN_FILENO, unsafeAddr data[n], 1)
    if r > 0: inc n
    else: break
  if n > 0:
    feedBytes(data[0 ..< n])
    return true
  return false

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
    var tv: Timeval
    var tvptr: ptr Timeval = nil
    if timeoutMs >= 0:
      var rem = timeoutMs - (getTicks() - start)
      if rem <= 0: return false
      tv.tv_sec = rem div 1000
      tv.tv_usec = (rem mod 1000) * 1000
      tvptr = tv.addr
    var fds: TFdSet
    FD_ZERO(fds)
    FD_SET(STDIN_FILENO, fds)
    let n = select(STDIN_FILENO + 1, fds.addr, nil, nil, tvptr)
    if n > 0:
      drainInput()
    elif timeoutMs < 0 and n < 0:
      ## EINTR from a signal handler: just loop and block again.
      continue
    else:
      if timeoutMs < 0:
        if n > 0 or eventQueue.len > 0: continue
        return false      # truly blocked and nothing came
      var rem = timeoutMs - (getTicks() - start)
      if rem <= 0: return false

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
proc shutdown*() =
  if tty:
    leaveTerminal()
  gShutdown = true

# ---------------------------------------------------------------------------
# Signals, raw mode, the alternate buffer (Step 4 + PLAN R2).
# ---------------------------------------------------------------------------

proc installSignals() =
  proc onWinch(sig: cint) {.noconv.} = gWinch = true
  proc onTerm(sig: cint) {.noconv.} = gShutdown = true
  proc onInt(sig: cint) {.noconv.} = gShutdown = true
  discard signal(SIGWINCH, onWinch)
  discard signal(SIGINT, onInt)
  discard signal(SIGTERM, onTerm)

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
  stdout.write "\e[?1006h"   # SGR mouse
  stdout.flushFile()
  hideCursor()
proc leaveTerminal() =
  stdout.write "\e[?1006l\e[?1049l\e[0m"
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
  curMods = {}
  eventQueue.setLen 0
  clipStack.setLen 0
  captured.setLen 0

  gPollEventImpl = proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.} =
    if eventQueue.len > 0:
      e = eventQueue[0]
      eventQueue.delete(0)
      return true
    drainInput()
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
