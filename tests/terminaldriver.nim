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

  ## drawLine paints one cell per step; each new x forces a cursor move, so the
  ## five-cell line below yields exactly five `...H` sequences.
  captured.setLen 0
  fillRect(rect(0, 0, 40, 10), color(30, 30, 46))
  refresh()
  captured.setLen 0
  drawLine(0, 0, 4, 0, color(205, 0, 0))
  refresh()
  check("drawLine paints five cells", captured.count("H") == 5)
  check("drawLine uses the line colour", captured.contains("\e[31m"))
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

  ## Cursor shape is DECSCUSR.
  captured.setLen 0
  setCursor(curIbeam)
  check("setCursor(curIbeam) emits a steady bar", captured.contains("\e[6 q"))
  captured.setLen 0
  setCursor(curDefault)
  check("setCursor(curDefault) emits a steady block", captured.contains("\e[2 q"))

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
  inputTests()
  unicodeTests()
  keyModTests()
  relayTests()
  clickTests()
  mouseTests()

  echo()
  echo(if failures == 0: "ALL PASS"
       else: $failures & " FAILURE(S)")
  if failures > 0: quit 1

main()
