## Headless tests for the uirelays terminal driver.
##
## They run entirely *offscreen*: the driver renders into its in-memory
## `captured` buffer and feeds bytes into an in-memory event queue, so no real
## terminal and no window are required. This is the mock pattern from
## focim/tests/ansitest.nim (test the driver's own logic, no window), adapted to
## the terminal backend's real procs rather than stubbed relays.
##
## Run:
##   nim c -r tests/terminaldriver.nim -d:terminal --path:src

import std/[os, strutils, times]                # getEnv / putEnv, contains, epochTime
import uirelays
## Import only the driver's own symbols; a plain `import` of the driver also
## brings `fillRect`, `refresh`, `createWindow`, ... into scope and makes them
## ambiguous with the `uirelays` wrappers.
from uirelays/drivers/terminal_driver import
  captured, feedBytes, termColor, newUtf8Decoder, decodeByte, utf8Encode,
  drAscii, drCodepoint, drPartial, drError, setTerminalCursor, tcSteadyUnderline,
  blitStyle, blitHalfBlocks, blitCells

## Force offscreen mode and a fixed 16-colour palette so the assertions below
## are deterministic no matter where this is run (CI has no TTY; a developer's
## shell might).
putEnv("UIRELAYS_TERMINAL_OFFSCREEN", "1")
putEnv("TERM", "xterm")                    # not 256color => 16-colour path
putEnv("UIRELAYS_TERMINAL_COLORS", "16")   # deterministic vs. ambient COLORTERM

var failures = 0
proc check(name: string; cond: bool) =
  if cond: echo "  PASS  ", name
  else:
    inc failures
    echo "  FAIL  ", name

# ---------------------------------------------------------------------------
# Colour (PLAN: unit-test pure colour maths headlessly).
# ---------------------------------------------------------------------------
proc colourTests =
  echo "colour maths:"
  ## `termColor` folds to the nearest of the sixteen and prints the SGR param.
  check("red -> foreground 31", termColor(color(205, 0, 0), false) == "31")
  check("red -> background 41", termColor(color(205, 0, 0), true) == "41")
  ## White and black are the bright variants of index 0.
  check("white -> foreground 97", termColor(color(255, 255, 255), false) == "97")
  check("black -> background 40", termColor(color(0, 0, 0), true) == "40")

# ---------------------------------------------------------------------------
# UTF-8 (PLAN: valid 2/3/4-byte sequences, split across two reads).
# ---------------------------------------------------------------------------
proc utf8Tests =
  echo "utf-8 decoder:"
  var d = newUtf8Decoder()
  # ASCII: one byte, one codepoint.
  let (a, av) = decodeByte(d, 0x41'u8)
  check("0x41 is ascii", a == drAscii and av == 0x41'u32)
  # 'é' (U+00E9) = C3 A9, split across two feedBytes calls.
  let (b, _) = decodeByte(d, 0xC3'u8)
  check("C3 needs one more byte", b == drPartial and d.n == 1)
  let (c, cv) = decodeByte(d, 0xA9'u8)
  check("A9 completes 'é'", c == drCodepoint and cv == 0xE9'u32)
  # U+4E6D '中' = E4 B9 AD (3 bytes) via the encoder.
  var arr: array[4, char]
  let n = utf8Encode(0x4E6D'u32, arr)
  check("中 = 3 bytes", n == 3)
  check("中 bytes E4 B9 AD",
        arr[0] == 0xE4'u8.chr and arr[1] == 0xB9'u8.chr and arr[2] == 0xAD'u8.chr)
  # A broken continuation byte deadens the sequence; the next byte starts fresh.
  var d2 = newUtf8Decoder()
  discard decodeByte(d2, 0xC3'u8)          # start 'é'
  let (dead, _) = decodeByte(d2, 0xFF'u8)  # bad continuation
  check("bad continuation is error", dead == drError)
  let (fresh, fv) = decodeByte(d2, 0x41'u8)
  check("fresh codepoint after a dead one", fresh == drAscii and fv == 0x41'u32)

# ---------------------------------------------------------------------------
# Render (PLAN: drive createWindow offscreen, a sequence of draws, refresh,
# assert the captured frame).
# ---------------------------------------------------------------------------
proc renderTests =
  echo "offscreen render:"
  var fm = FontMetrics()
  let font = openFont("", 18, fm)
  let layout = createWindow(40, 10)
  check("offscreen size is the requested cells",
    getWindowLayout().width == 40 and getWindowLayout().height == 10)
  discard layout

  ## A solid red fill paints every cell with a red background.
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(205, 0, 0))
  refresh()
  check("filled red background reached the buffer", captured.contains("\e[41m"))

  ## Text is stamped as literal glyphs into the buffer.
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(30, 30, 46))
  discard drawText(font, 1, 1, "Hi", color(255, 255, 255), color(30, 30, 46))
  refresh()
  check("drawText stamped glyphs into the buffer", captured.contains("Hi"))

  ## Non-ASCII is one codepoint per cell: measureText counts codepoints and the
  ## emitted glyph is the whole UTF-8 sequence, not one byte per cell.
  check("measureText counts 'ä' as one column", measureText(font, "ä").w == 1)
  check("measureText counts 'grün' as four columns",
    measureText(font, "grün").w == 4)
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(30, 30, 46))
  discard drawText(font, 0, 0, "äöü", color(255, 255, 255), color(30, 30, 46))
  refresh()
  ## Each glyph's bytes are contiguous because they come from one cell; two
  ## separate cells would have a cursor-position escape between them.
  check("drawn 'ä' emits both UTF-8 bytes", captured.contains("\xC3\xA4"))
  check("drawn 'ö' emits both UTF-8 bytes", captured.contains("\xC3\xB6"))
  check("drawn 'ü' emits both UTF-8 bytes", captured.contains("\xC3\xBC"))
  check("measureText counts 'äöü' as three columns",
    measureText(font, "äöü").w == 3)

  ## drawLine must terminate and reach its endpoint for axis-aligned lines at
  ## any offset -- the origin masked both the halved error and the cx/cy
  ## initialisation bug.
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(30, 30, 46))
  refresh()
  captured.setLen 0
  drawLine(2, 1, 6, 1, color(205, 0, 0))          # horizontal
  refresh()
  check("drawLine paints a 5-cell horizontal run", captured.count("H") == 5)
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(30, 30, 46))
  refresh()
  captured.setLen 0
  drawLine(2, 1, 2, 4, color(205, 0, 0))          # vertical
  refresh()
  check("drawLine paints a 4-cell vertical run", captured.count("H") == 4)
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(30, 30, 46))
  refresh()
  captured.setLen 0
  drawLine(5, 5, 5, 5, color(205, 0, 0))          # a single cell
  refresh()
  check("drawLine of one point paints one cell", captured.count("H") == 1)
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(30, 30, 46))
  refresh()
  captured.setLen 0
  drawLine(2, 1, 5, 4, color(205, 0, 0))          # diagonal
  refresh()
  check("drawLine paints a 4-cell diagonal", captured.count("H") == 4)
  check("drawLine uses the line colour", captured.contains("\e[31m"))
  closeFont(font)

# ---------------------------------------------------------------------------
# Colour-depth reduction: 16 / 256 / truecolor.
# ---------------------------------------------------------------------------
proc colorModeTests =
  echo "colour reduction:"
  ## The other colour tests force 16; here the override is moved through the
  ## other depths and `createWindow` re-reads it.
  putEnv("UIRELAYS_TERMINAL_COLORS", "256")
  discard createWindow(40, 10)
  check("256: red is the system red (index 1)",
    termColor(color(205, 0, 0), false) == "38;5;1")
  check("256: red background", termColor(color(205, 0, 0), true) == "48;5;1")
  check("256: an exact cube colour keeps its cube index",
    termColor(color(95, 135, 175), false) == "38;5;67")
  check("256: a mid grey uses the grey ramp",
    termColor(color(128, 128, 128), false) == "38;5;244")
  check("256: orange uses the colour cube (208)",
    termColor(color(255, 128, 0), false) == "38;5;208")
  putEnv("UIRELAYS_TERMINAL_COLORS", "24")
  discard createWindow(40, 10)
  check("24: exact truecolor",
    termColor(color(12, 34, 56), false) == "38;2;12;34;56")
  check("24: exact truecolor background",
    termColor(color(12, 34, 56), true) == "48;2;12;34;56")
  putEnv("UIRELAYS_TERMINAL_COLORS", "16")
  discard createWindow(40, 10)
  check("16: red is SGR 31", termColor(color(205, 0, 0), false) == "31")

# ---------------------------------------------------------------------------
# Text styles carried by the font handle.
# ---------------------------------------------------------------------------
proc styleTests =
  echo "text styles:"
  var fm = FontMetrics()
  let regular = openFont("", 1, fm)
  let bold = styledFont(regular, {FontStyle.bold})
  let italic = styledFont(regular, {FontStyle.italics})
  let underlined = styledFont(regular, {FontStyle.underline})
  let struck = styledFont(regular, {FontStyle.strikethrough})

  check("styledFont returns a distinct handle", bold.int != regular.int)
  check("each style gets its own handle",
    italic.int != bold.int and underlined.int != italic.int and
    struck.int != underlined.int)

  proc drawn(f: Font): string =
    captured.setLen 0
    fillRect(rect(0, 0, 40, 10), color(0, 0, 0))
    refresh()
    captured.setLen 0
    discard drawText(f, 0, 0, "X", color(255, 255, 255), color(0, 0, 0))
    refresh()
    result = captured

  check("bold emits SGR 1", drawn(bold).contains("\e[1m"))
  check("italic emits SGR 3", drawn(italic).contains("\e[3m"))
  check("underline emits SGR 4", drawn(underlined).contains("\e[4m"))
  check("strikethrough emits SGR 9", drawn(struck).contains("\e[9m"))
  let plain = drawn(regular)
  check("the regular face emits no attribute",
    not plain.contains("\e[1m") and not plain.contains("\e[3m") and
    not plain.contains("\e[4m") and not plain.contains("\e[9m"))

  ## A regular run right after a bold one must reset the attribute.
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(0, 0, 0))
  refresh()
  captured.setLen 0
  discard drawText(bold, 0, 0, "B", color(255, 255, 255), color(0, 0, 0))
  discard drawText(regular, 1, 0, "r", color(255, 255, 255), color(0, 0, 0))
  refresh()
  check("bold then regular emits the reset", captured.contains("\e[22m"))

  closeFont(regular)

# ---------------------------------------------------------------------------
# blitRGBA: pixels to cells, half-block or one-per-cell.
# ---------------------------------------------------------------------------
proc blitTests =
  echo "blitRGBA:"
  var img = newSeq[uint32](4 * 4)
  for i in 0 ..< img.len: img[i] = 0x00FF0000'u32   # red
  let px = cast[ptr UncheckedArray[uint32]](addr img[0])

  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(0, 0, 0))
  refresh()
  captured.setLen 0
  blitStyle = blitHalfBlocks
  check("half blocks: returns true", blitRGBA(px, 4, 4, rect(0, 0, 4, 4)))
  refresh()
  check("half blocks: 4x4 pixels fill 8 cells", captured.count("H") == 8)
  check("half blocks: emits the upper-half glyph",
    captured.contains("\xE2\x96\x80"))

  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(0, 0, 0))
  refresh()
  captured.setLen 0
  blitStyle = blitCells
  check("cells: returns true", blitRGBA(px, 4, 4, rect(0, 0, 4, 4)))
  refresh()
  check("cells: 4x4 pixels fill 16 cells", captured.count("H") == 16)
  check("cells: no half-block glyph", not captured.contains("\xE2\x96\x80"))

  check("nil pixels -> false", not blitRGBA(nil, 4, 4, rect(0, 0, 4, 4)))
  check("empty size -> false",
    not blitRGBA(px, 0, 4, rect(0, 0, 4, 4)) and
    not blitRGBA(px, 4, 4, rect(0, 0, 0, 0)))
  blitStyle = blitHalfBlocks

# ---------------------------------------------------------------------------
# Application units: the wrappers scale, relays and drivers see driver coords.
# ---------------------------------------------------------------------------
proc unitSizeTests =
  echo "unit size:"
  var fm = FontMetrics()
  setUnitSize(2, 3)
  let font = openFont("", 1, fm)
  var e: Event

  let layout = createWindow(10, 4)
  check("the window request scales to driver cells",
    getWindowLayout().width == 10 and getWindowLayout().height == 4)
  check("the returned layout is in application units",
    layout.width == 10 and layout.height == 4)

  captured.setLen 0
  fillRect(rect(0, 0, 10, 4), color(0, 0, 0))
  refresh()
  captured.setLen 0
  fillRect(rect(1, 1, 2, 2), color(205, 0, 0))   # app units
  refresh()
  check("a 2x2 app rect fills 4x6 driver cells", captured.count("H") == 24)

  captured.setLen 0
  fillRect(rect(0, 0, 10, 4), color(0, 0, 0))
  refresh()
  captured.setLen 0
  discard drawText(font, 1, 1, "X", color(255, 255, 255), color(0, 0, 0))
  refresh()
  check("drawText at app (1,1) lands at driver (2,3)",
    captured.contains("\e[4;3H"))

  ## A point fills a whole unit (2x3 cells); a line is a run of those.
  captured.setLen 0
  fillRect(rect(0, 0, 10, 4), color(0, 0, 0))
  refresh()
  captured.setLen 0
  drawPoint(1, 1, color(205, 0, 0))
  refresh()
  check("drawPoint fills a unit (2x3 cells)", captured.count("H") == 6)

  captured.setLen 0
  fillRect(rect(0, 0, 10, 4), color(0, 0, 0))
  refresh()
  captured.setLen 0
  drawLine(0, 0, 2, 0, color(205, 0, 0))
  refresh()
  check("drawLine is one unit thick (3 blocks of 2x3)",
    captured.count("H") == 18)

  ## Mouse coordinates come back in application units.
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('<').uint8, ord('0').uint8,
              ord(';').uint8, ord('5').uint8, ord(';').uint8, ord('7').uint8,
              ord('M').uint8])
  check("mouse unscales to app units",
    pollEvent(e) and e.kind == MouseDownEvent and e.x == 2 and e.y == 2)

  closeFont(font)
  setUnitSize(1, 1)

# ---------------------------------------------------------------------------
# getTicks must be a wall clock; it was CPU time, which made `sleep`'s timeout
# never elapse while the app idled in `select`.
# ---------------------------------------------------------------------------
proc timingTests =
  echo "timing:"
  let t0 = getTicks()
  let w0 = epochTime()
  os.sleep(80)                        # a real wall sleep, not the driver's
  let dt = getTicks() - t0
  let dw = int((epochTime() - w0) * 1000.0)
  check("getTicks tracks the wall clock",
    dt >= 60 and abs(dt - dw) < 60)

# ---------------------------------------------------------------------------
# Input (PLAN: push synthetic byte strings in, check the events out).
# ---------------------------------------------------------------------------
proc inputTests =
  echo "input parsing:"
  var e = Event()

  ## Plain typing: the driver fabricates KeyDown, KeyUp, then the TextInput.
  feedBytes(@[ord('a').uint8])
  check("'a' is a KeyDown on A",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyA)
  check("'a' is a KeyUp on A",
    pollEvent(e) and e.kind == KeyUpEvent and e.key == KeyA)
  check("'a' is a TextInput of 'a'",
    pollEvent(e) and e.kind == TextInputEvent and e.text[0] == 'a')

  ## CSI arrow: ESC [ A.
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('A').uint8])
  check("ESC [ A is KeyDown(Up)",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyUp)
  check("ESC [ A is KeyUp(Up)",
    pollEvent(e) and e.kind == KeyUpEvent and e.key == KeyUp)

  ## SGR mouse press (ESC [ <0;10;20M) at column 10, row 20 -> (9,19).
  ## SGR encodes MB1 as 0 (ctlseqs.ms "SGR (1006)"; SGR adds no 32).
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('<').uint8,
                      ord('0').uint8, ord(';').uint8, ord('1').uint8, ord('0').uint8,
                      ord(';').uint8, ord('2').uint8, ord('0').uint8, ord('M').uint8])
  check("SGR press is a MouseDown",
    pollEvent(e) and e.kind == MouseDownEvent and e.button == LeftButton)
  if e.kind == MouseDownEvent:
    check("SGR press reports the cell", e.x == 9 and e.y == 19)
  ## SGR mouse release (lowercase m).
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('<').uint8,
                      ord('0').uint8, ord(';').uint8, ord('1').uint8, ord('0').uint8,
                      ord(';').uint8, ord('2').uint8, ord('0').uint8, ord('m').uint8])
  check("SGR release is a MouseUp",
    pollEvent(e) and e.kind == MouseUpEvent)

# ---------------------------------------------------------------------------
# SGR mouse (1006), verified against xterm's ctlseqs.ms "Mouse Tracking".
# ---------------------------------------------------------------------------
proc feedStr(s: string) =
  var b = newSeq[uint8](s.len)
  for i, c in s: b[i] = c.uint8
  feedBytes(b)

proc firstEvent(s: string): Event =
  feedStr(s)
  discard pollEvent(result)

proc keyEvent(s: string): Event =
  ## One F-key/arrow press, with the paired KeyUp drained so the next case
  ## starts clean.
  result = firstEvent(s)
  if result.kind == KeyDownEvent:
    var up: Event
    discard pollEvent(up)

proc functionKeyTests =
  echo "function keys:"
  var e: Event

  ## ctlseqs.ms "PC-Style Function Keys": F1-F4 are SS3 (or CSI with a
  ## modifier), F5=15~, F6=17~, F7=18~, ..., F10=21~, F11=23~, F12=24~.
  e = keyEvent("\eOP")
  check("ESC O P -> F1", e.kind == KeyDownEvent and e.key == KeyF1)
  e = keyEvent("\e[15~")
  check("CSI 15~ -> F5", e.kind == KeyDownEvent and e.key == KeyF5)
  e = keyEvent("\e[16~")
  check("CSI 16~ is unassigned (no event)", e.kind == NoEvent)
  e = keyEvent("\e[17~")
  check("CSI 17~ -> F6", e.kind == KeyDownEvent and e.key == KeyF6)
  e = keyEvent("\e[18~")
  check("CSI 18~ -> F7", e.kind == KeyDownEvent and e.key == KeyF7)
  e = keyEvent("\e[21~")
  check("CSI 21~ -> F10", e.kind == KeyDownEvent and e.key == KeyF10)
  e = keyEvent("\e[23~")
  check("CSI 23~ -> F11", e.kind == KeyDownEvent and e.key == KeyF11)
  e = keyEvent("\e[24~")
  check("CSI 24~ -> F12", e.kind == KeyDownEvent and e.key == KeyF12)
  e = keyEvent("\e[1;2P")
  check("CSI 1;2P -> Shift+F1",
    e.kind == KeyDownEvent and e.key == KeyF1 and ShiftPressed in e.mods)

proc editKeyTests =
  echo "editing keys:"
  var e: Event
  e = keyEvent("\e[1~")
  check("CSI 1~ -> Home", e.kind == KeyDownEvent and e.key == KeyHome)
  e = keyEvent("\e[H")
  check("CSI H -> Home", e.kind == KeyDownEvent and e.key == KeyHome)
  e = keyEvent("\eOH")
  check("SS3 H -> Home", e.kind == KeyDownEvent and e.key == KeyHome)
  e = keyEvent("\e[4~")
  check("CSI 4~ -> End", e.kind == KeyDownEvent and e.key == KeyEnd)
  e = keyEvent("\e[8~")
  check("CSI 8~ -> End", e.kind == KeyDownEvent and e.key == KeyEnd)
  e = keyEvent("\e[F")
  check("CSI F -> End (PC-style)", e.kind == KeyDownEvent and e.key == KeyEnd)
  e = keyEvent("\eOF")
  check("SS3 F -> End", e.kind == KeyDownEvent and e.key == KeyEnd)
  e = keyEvent("\e[2~")
  check("CSI 2~ -> Insert", e.kind == KeyDownEvent and e.key == KeyInsert)
  e = keyEvent("\e[3~")
  check("CSI 3~ -> Delete", e.kind == KeyDownEvent and e.key == KeyDelete)
  e = keyEvent("\e[5~")
  check("CSI 5~ -> PageUp", e.kind == KeyDownEvent and e.key == KeyPageUp)
  e = keyEvent("\e[6~")
  check("CSI 6~ -> PageDown", e.kind == KeyDownEvent and e.key == KeyPageDown)
  e = keyEvent("\e[3;5~")
  check("CSI 3;5~ -> Ctrl+Delete",
    e.kind == KeyDownEvent and e.key == KeyDelete and CtrlPressed in e.mods)
  e = keyEvent("\e[1;5F")
  check("CSI 1;5F -> Ctrl+End",
    e.kind == KeyDownEvent and e.key == KeyEnd and CtrlPressed in e.mods)

  ## Several sequences back to back in one read must all come through.
  feedStr("\e[2~\e[3~\e[4~\e[F")
  var got: seq[KeyCode] = @[]
  while pollEvent(e):
    if e.kind == KeyDownEvent: got.add e.key
  check("back-to-back editing keys keep their order",
    got == @[KeyInsert, KeyDelete, KeyEnd, KeyEnd])

# ---------------------------------------------------------------------------
# Modifier-carrying protocols: xterm modifyOtherKeys and the kitty protocol.
# ---------------------------------------------------------------------------
proc modifierTests =
  echo "modifiers:"
  proc mkey(seq: string; want: KeyCode; wantMods: set[Modifier]) =
    let e = firstEvent(seq)
    check(seq & " -> " & $want & " " & $wantMods,
      e.kind == KeyDownEvent and e.key == want and e.mods == wantMods)
    var tmp: Event
    while pollEvent(tmp): discard          # drain the pair / text

  ## xterm modifyOtherKeys: CSI 27 ; mod ; code ~
  mkey("\e[27;3;120~", KeyX, {AltPressed})       # Alt+x
  mkey("\e[27;5;61~", KeyEqual, {CtrlPressed})   # Ctrl+=
  mkey("\e[27;5;45~", KeyMinus, {CtrlPressed})   # Ctrl+-
  mkey("\e[27;2;97~", KeyA, {ShiftPressed})      # Shift+a
  mkey("\e[27;9;120~", KeyX, {GuiPressed})       # Meta+x

  ## kitty: CSI code ; mod u
  mkey("\e[120;3u", KeyX, {AltPressed})
  mkey("\e[61;5u", KeyEqual, {CtrlPressed})
  mkey("\e[57352;2u", KeyUp, {ShiftPressed})     # functional Shift+Up
  mkey("\e[57364;5u", KeyF1, {CtrlPressed})      # Ctrl+F1
  mkey("\e[97;17u", KeyA, {GuiPressed})          # Hyper+a -> Gui
  mkey("\e[97;5:2u", KeyA, {CtrlPressed})        # `mod:event` drops the event

  ## kitty represents the Escape key as `CSI 27 u`.
  mkey("\e[27u", KeyEsc, {})

  ## A bare ESC with nothing after it is the Escape key after a short pause
  ## (a terminal that supports neither protocol sends just `ESC`).
  var e2: Event
  feedBytes(@[0x1B'u8])
  check("a lone ESC queues nothing at first", not pollEvent(e2))
  os.sleep(100)
  check("a lone ESC times out to KeyEsc",
    pollEvent(e2) and e2.kind == KeyDownEvent and e2.key == KeyEsc)

proc clickTests =
  echo "click counts:"
  var e: Event

  ## Three presses in the same cell in quick succession: 1, 2, 3.
  e = firstEvent("\e[<0;5;5M")
  check("press 1 -> clicks = 1", e.kind == MouseDownEvent and e.clicks == 1)
  e = firstEvent("\e[<0;5;5M")
  check("press 2 -> double click", e.kind == MouseDownEvent and e.clicks == 2)
  e = firstEvent("\e[<0;5;5M")
  check("press 3 -> triple click", e.kind == MouseDownEvent and e.clicks == 3)

  ## A press well away from the last one starts a new run.
  e = firstEvent("\e[<0;30;20M")
  check("far press -> clicks = 1", e.kind == MouseDownEvent and e.clicks == 1)

  ## A different button in the same cell also starts a new run.
  e = firstEvent("\e[<2;30;20M")
  check("other button -> clicks = 1",
    e.kind == MouseDownEvent and e.button == RightButton and e.clicks == 1)

  ## The 500 ms window is wall-clock: a real pause resets the run.
  e = firstEvent("\e[<0;1;1M")
  check("press after a move -> clicks = 1", e.clicks == 1)
  e = firstEvent("\e[<0;1;1M")
  check("quick repeat -> clicks = 2", e.clicks == 2)
  os.sleep(600)
  e = firstEvent("\e[<0;1;1M")
  check("after a 600 ms pause -> clicks = 1", e.clicks == 1)

proc mouseTests =
  echo "sgr mouse:"
  var e: Event

  e = firstEvent("\e[<64;5;5M")
  check("wheel up -> y = +1",
    e.kind == MouseWheelEvent and e.x == 0 and e.y == 1)
  e = firstEvent("\e[<65;5;5M")
  check("wheel down -> y = -1",
    e.kind == MouseWheelEvent and e.x == 0 and e.y == -1)
  e = firstEvent("\e[<66;5;5M")   # button 6 = tilt right
  check("tilt right -> x = +1",
    e.kind == MouseWheelEvent and e.x == 1 and e.y == 0)
  e = firstEvent("\e[<67;5;5M")   # button 7 = tilt left
  check("tilt left -> x = -1",
    e.kind == MouseWheelEvent and e.x == -1 and e.y == 0)
  e = firstEvent("\e[<128;5;5M")  # button 8 has no uirelays equivalent
  check("extra button 8 is ignored", e.kind == NoEvent)

  e = firstEvent("\e[<2;5;5M")
  check("SGR value 2 -> RightButton",
    e.kind == MouseDownEvent and e.button == RightButton)
  e = firstEvent("\e[<1;5;5M")
  check("SGR value 1 -> MiddleButton",
    e.kind == MouseDownEvent and e.button == MiddleButton)
  e = firstEvent("\e[<16;5;5M")
  check("button value 16 -> Ctrl", e.kind == MouseDownEvent and CtrlPressed in e.mods)
  e = firstEvent("\e[<8;5;5M")
  check("button value 8 -> Alt", e.kind == MouseDownEvent and AltPressed in e.mods)
  e = firstEvent("\e[<32;5;5M")
  check("motion -> MouseMove at the cell",
    e.kind == MouseMoveEvent and e.x == 4 and e.y == 4)

  ## Two presses at the same cell in quick succession form a double click;
  ## the (1,1) cell is far enough from (4,4) to start a fresh run.
  e = firstEvent("\e[<0;1;1M")
  check("first press -> clicks = 1", e.kind == MouseDownEvent and e.clicks == 1)
  e = firstEvent("\e[<0;1;1M")
  check("second press -> double click", e.kind == MouseDownEvent and e.clicks == 2)

  ## A lone ESC (cut off mid-sequence) queues nothing yet -- nothing leaks.
  ## This runs last: the ESC stays held in `escAccum` until the next byte, so a
  ## later feed would be prefixed with the dangling ESC and misparse.
  var ev: Event
  feedBytes(@[0x1B'u8])
  check("lone ESC queues nothing", not pollEvent(ev))

# ---------------------------------------------------------------------------
# Non-ASCII input: multi-byte UTF-8, split across reads, and error recovery.
# ---------------------------------------------------------------------------
proc unicodeTests =
  echo "unicode input:"
  var e = Event()

  ## 'ä' = C3 A4, in one read.
  feedBytes(@[0xC3'u8, 0xA4'u8])
  check("'ä' is one TextInput",
    pollEvent(e) and e.kind == TextInputEvent and
    e.text[0].uint8 == 0xC3 and e.text[1].uint8 == 0xA4)

  ## The same umlaut split across two reads: the decoder has to persist.
  feedBytes(@[0xC3'u8])
  check("split lead queues nothing", not pollEvent(e))
  feedBytes(@[0xA4'u8])
  check("split 'ä' completes across reads",
    pollEvent(e) and e.kind == TextInputEvent and
    e.text[0].uint8 == 0xC3 and e.text[1].uint8 == 0xA4)

  ## '€' = E2 82 AC (three bytes, one column).
  feedBytes(@[0xE2'u8, 0x82'u8, 0xAC'u8])
  check("'€' is one TextInput",
    pollEvent(e) and e.kind == TextInputEvent and
    e.text[0].uint8 == 0xE2 and e.text[1].uint8 == 0x82 and e.text[2].uint8 == 0xAC)

  ## An invalid lead byte becomes U+FFFD, and the next ASCII byte still arrives.
  feedBytes(@[0xFF'u8, ord('x').uint8])
  check("bad lead -> replacement char",
    pollEvent(e) and e.kind == TextInputEvent and
    e.text[0].uint8 == 0xEF and e.text[1].uint8 == 0xBF and e.text[2].uint8 == 0xBD)
  check("byte after a bad lead is reprocessed",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyX)
  discard pollEvent(e)   # KeyUp X
  discard pollEvent(e)   # TextInput 'x'

  ## A bad continuation drops the half-sequence but reprocesses the byte, so a
  ## lead byte that follows a broken one is not swallowed.
  feedBytes(@[0xC3'u8, ord('A').uint8])
  check("bad continuation -> replacement char",
    pollEvent(e) and e.kind == TextInputEvent and e.text[0].uint8 == 0xEF)
  check("byte after a bad continuation is reprocessed",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyA)
  discard pollEvent(e)
  discard pollEvent(e)

# ---------------------------------------------------------------------------
# Ctrl combinations and CSI modifier parameters.
# ---------------------------------------------------------------------------
proc keyModTests =
  echo "key modifiers:"
  var e = Event()

  ## Ctrl+A is byte 0x01, reported as a key with Ctrl rather than a raw control.
  feedBytes(@[0x01'u8])
  check("Ctrl+A is KeyA with Ctrl",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyA and
    CtrlPressed in e.mods)
  check("Ctrl+A also reports the KeyUp",
    pollEvent(e) and e.kind == KeyUpEvent and e.key == KeyA and
    CtrlPressed in e.mods)

  ## Ctrl+Z is 0x1A.
  feedBytes(@[0x1A'u8])
  check("Ctrl+Z is KeyZ with Ctrl",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyZ and
    CtrlPressed in e.mods)
  discard pollEvent(e)

  ## Ctrl+Space (NUL), and Ctrl+\ (0x1C), which has no letter to name.
  feedBytes(@[0x00'u8])
  check("Ctrl+Space is KeySpace with Ctrl",
    pollEvent(e) and e.key == KeySpace and CtrlPressed in e.mods)
  discard pollEvent(e)
  feedBytes(@[0x1C'u8])
  check("Ctrl+\\ is KeyNone with Ctrl, not a wrong key",
    pollEvent(e) and e.key == KeyNone and CtrlPressed in e.mods)
  discard pollEvent(e)

  ## xterm modifier parameters: ESC [ 1 ; 5 A is Ctrl+Up.
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('1').uint8, ord(';').uint8,
              ord('5').uint8, ord('A').uint8])
  check("ESC[1;5A is Ctrl+Up",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyUp and
    CtrlPressed in e.mods)
  discard pollEvent(e)

  ## ESC [ 3 ; 2 ~ is Shift+Delete (and not Ctrl).
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('3').uint8, ord(';').uint8,
              ord('2').uint8, ord('~').uint8])
  check("ESC[3;2~ is Shift+Delete",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyDelete and
    ShiftPressed in e.mods and CtrlPressed notin e.mods)
  discard pollEvent(e)

  ## Shift+Tab has its own sequence.
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('Z').uint8])
  check("ESC[Z is Shift+Tab",
    pollEvent(e) and e.kind == KeyDownEvent and e.key == KeyTab and
    ShiftPressed in e.mods)
  discard pollEvent(e)

# ---------------------------------------------------------------------------
# The relays that used to be stubs: clipboard write, cursor shape, focus.
# ---------------------------------------------------------------------------
proc relayTests =
  echo "relays:"

  ## Clipboard write is OSC 52 with the base64 of the text.
  captured.setLen 0
  putClipboardText("hi")
  check("putClipboardText emits OSC 52", captured.contains("\e]52;c;aGk=\a"))
  check("getClipboardText is empty (no read round trip)",
    getClipboardText() == "")

  ## Cursor shapes are DECSCUSR; the portable kinds map onto the terminal's.
  captured.setLen 0
  setCursor(curIbeam)
  check("setCursor(curIbeam) emits a steady bar", captured.contains("\e[6 q"))
  captured.setLen 0
  setCursor(curDefault)
  check("setCursor(curDefault) emits the default shape", captured.contains("\e[0 q"))
  captured.setLen 0
  setTerminalCursor(tcSteadyUnderline)
  check("setTerminalCursor emits DECSCUSR 4", captured.contains("\e[4 q"))

  ## Focus in/out (mode 1004) turn into the focus events; repeats are
  ## deduplicated because terminals report the same transition more than once.
  var e = Event()
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('I').uint8])
  check("ESC[I -> WindowFocusGainedEvent",
    pollEvent(e) and e.kind == WindowFocusGainedEvent)
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('I').uint8])
  check("repeated ESC[I is deduplicated", not pollEvent(e))
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('O').uint8])
  check("ESC[O -> WindowFocusLostEvent",
    pollEvent(e) and e.kind == WindowFocusLostEvent)
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('O').uint8])
  check("repeated ESC[O is deduplicated", not pollEvent(e))
  feedBytes(@[0x1B'u8, ord('[').uint8, ord('I').uint8])
  check("focus gained again after lost",
    pollEvent(e) and e.kind == WindowFocusGainedEvent)

# ---------------------------------------------------------------------------
proc main() =
  colourTests()
  utf8Tests()
  renderTests()
  colorModeTests()
  styleTests()
  blitTests()
  unitSizeTests()
  timingTests()
  inputTests()
  unicodeTests()
  keyModTests()
  functionKeyTests()
  editKeyTests()
  modifierTests()
  relayTests()
  clickTests()
  mouseTests()

  echo()
  echo(if failures == 0: "ALL PASS"
       else: $failures & " FAILURE(S)")
  if failures > 0: quit 1

main()
