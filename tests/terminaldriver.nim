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

import std/[os, strutils]                # getEnv / putEnv, contains
import uirelays
## Import only the driver's own symbols; a plain `import` of the driver also
## brings `fillRect`, `refresh`, `createWindow`, ... into scope and makes them
## ambiguous with the `uirelays` wrappers.
from uirelays/drivers/terminal_driver import
  captured, feedBytes, termColor, newUtf8Decoder, decodeByte, utf8Encode,
  drAscii, drCodepoint, drPartial, drError

## Force offscreen mode and a fixed 16-colour palette so the assertions below
## are deterministic no matter where this is run (CI has no TTY; a developer's
## shell might).
putEnv("UIRELAYS_TERMINAL_OFFSCREEN", "1")
putEnv("TERM", "xterm")                    # not 256color => 16-colour path

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
  closeFont(font)

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
proc main() =
  colourTests()
  utf8Tests()
  renderTests()
  inputTests()
  mouseTests()

  echo()
  echo(if failures == 0: "ALL PASS"
       else: $failures & " FAILURE(S)")
  if failures > 0: quit 1

main()
