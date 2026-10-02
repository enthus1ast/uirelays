## examples/terminal_demo.nim
## A fuller terminal-backend demo: a virtual mouse pointer, a row of clickable
## buttons, live coordinates, and a log of the events as they arrive.
##
## The terminal driver turns on SGR mouse reporting (1003h + 1006h), so motion,
## clicks and the wheel all reach `pollEvent`. A real terminal has no pointer
## of its own, so the demo paints one into the cell grid.
##
## Compile:
##   nim c -d:terminal examples/terminal_demo.nim
##
## Run:
##   ./terminal_demo
##
## Controls:
##   mouse      move the pointer, click a button, scroll the wheel
##   left click on empty space
##              drop a point; consecutive points are joined with `drawLine`,
##              each segment a different colour (row 1 is a hue spectrum, row 5
##              a black-to-white ramp -- both show how deep the terminal is)
##   1-6        activate the matching button from the keyboard
##   Frame      switch between a solid colour frame and character frames
##   Cursor     cycle through every cursor shape this terminal can show
##   i          toggle the `blitRGBA` image view (half blocks vs 1x1 cells)
##   c          clear the event log and the drawn line
##   Esc/Ctrl+Q quit

import std/strutils
import uirelays
from uirelays/drivers/terminal_driver import TerminalCursor, setTerminalCursor,
  BlitStyle, blitStyle, blitHalfBlocks, blitCells

const
  ButtonCount = 6
  MaxLog = 200
  CursorShapes = [
    tcDefault, tcBlinkBlock, tcSteadyBlock,
    tcBlinkUnderline, tcSteadyUnderline, tcBlinkBar, tcSteadyBar,
  ]

type
  Button = object
    label: string
    r: Rect

  FrameMode = enum
    frameSolid, frameSingle, frameDouble, frameRounded, frameHeavy, frameAscii

  BoxChars = object
    tl, tr, bl, br, h, v: string

const
  boxSingle = BoxChars(tl: "┌", tr: "┐", bl: "└", br: "┘", h: "─", v: "│")
  boxDouble = BoxChars(tl: "╔", tr: "╗", bl: "╚", br: "╝", h: "═", v: "║")
  boxRounded = BoxChars(tl: "╭", tr: "╮", bl: "╰", br: "╯", h: "─", v: "│")
  boxHeavy = BoxChars(tl: "┏", tr: "┓", bl: "┗", br: "┛", h: "━", v: "┃")
  boxAscii = BoxChars(tl: "+", tr: "+", bl: "+", br: "+", h: "-", v: "|")

proc frameName(m: FrameMode): string =
  case m
  of frameSolid: "solid"
  of frameSingle: "single"
  of frameDouble: "double"
  of frameRounded: "rounded"
  of frameHeavy: "heavy"
  of frameAscii: "ascii"

proc drawBox(font: Font; r: Rect; b: BoxChars; fg, bg: Color) =
  ## A character border, built only from `drawText` -- no driver help needed.
  ## One `drawText` per edge, so it is a handful of calls per frame.
  if r.w < 2 or r.h < 2: return
  discard drawText(font, r.x, r.y, b.tl & repeat(b.h, r.w - 2) & b.tr, fg, bg)
  discard drawText(font, r.x, r.y + r.h - 1,
                   b.bl & repeat(b.h, r.w - 2) & b.br, fg, bg)
  for y in r.y + 1 ..< r.y + r.h - 1:
    discard drawText(font, r.x, y, b.v, fg, bg)
    discard drawText(font, r.x + r.w - 1, y, b.v, fg, bg)

proc drawPanel(font: Font; r: Rect; mode: FrameMode; fg, bg: Color) =
  ## The switch: a solid colour frame, or a character frame.
  case mode
  of frameSolid: drawFrame(r, fg, 1)
  of frameSingle: drawBox(font, r, boxSingle, fg, bg)
  of frameDouble: drawBox(font, r, boxDouble, fg, bg)
  of frameRounded: drawBox(font, r, boxRounded, fg, bg)
  of frameHeavy: drawBox(font, r, boxHeavy, fg, bg)
  of frameAscii: drawBox(font, r, boxAscii, fg, bg)

proc centered(r: Rect; label: string): tuple[x, y: int] =
  ## Where a one-row label sits so it looks centred in the rectangle.
  (r.x + max(0, (r.w - label.len) div 2), r.y + r.h div 2)

proc cursorName(c: TerminalCursor): string =
  ## A readable name for the status line.
  case c
  of tcDefault: "default"
  of tcBlinkBlock: "blinking block"
  of tcSteadyBlock: "steady block"
  of tcBlinkUnderline: "blinking underline"
  of tcSteadyUnderline: "steady underline"
  of tcBlinkBar: "blinking bar"
  of tcSteadyBar: "steady bar"

proc hueColor(h: float; s = 1.0; v = 1.0): Color =
  ## HSV -> RGB, `h` in [0, 1). Small and dependency-free, used for the spectrum
  ## strips and the rainbow polyline.
  let sector = int(h * 6.0)
  let f = h * 6.0 - float(sector)
  let p = v * (1.0 - s)
  let q = v * (1.0 - f * s)
  let t = v * (1.0 - (1.0 - f) * s)
  var r, g, b: float
  case sector mod 6
  of 0: r = v; g = t; b = p
  of 1: r = q; g = v; b = p
  of 2: r = p; g = v; b = t
  of 3: r = p; g = q; b = v
  of 4: r = t; g = p; b = v
  else: r = v; g = p; b = q
  color(uint8(r * 255.0 + 0.5), uint8(g * 255.0 + 0.5), uint8(b * 255.0 + 0.5))

proc makeTestImage(w, h: int): seq[uint32] =
  ## A shaded hue disc, in the 0x00RRGGBB the blit relay wants. The ring makes
  ## the difference between half-block and one-pixel-per-cell obvious.
  result = newSeq[uint32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let u = float(x) / float(max(1, w - 1))
      let v = float(y) / float(max(1, h - 1))
      let dx = u - 0.5
      let dy = v - 0.5
      let r2 = dx * dx + dy * dy
      var c = hueColor(u, 0.8, 0.35 + 0.65 * v)
      if r2 > 0.20: c = color(18, 18, 28)
      elif r2 > 0.155: c = color(235, 235, 245)
      result[y * w + x] = (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

proc pixelPtr(s: var seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](addr s[0])

proc keyLabel(e: Event): string =
  ## `KeyPageUp` -> `PageUp`, prefixed with the modifiers that came with it:
  ## `Ctrl+A`, `Shift+Delete`, `Alt+Up`, ...
  var parts: seq[string] = @[]
  if ShiftPressed in e.mods: parts.add "Shift"
  if CtrlPressed in e.mods: parts.add "Ctrl"
  if AltPressed in e.mods: parts.add "Alt"
  if GuiPressed in e.mods: parts.add "Meta"
  var name = $e.key
  if name.len > 3 and name[0 .. 2] == "Key":
    name = name[3 .. ^1]
  (if parts.len > 0: parts.join("+") & "+" else: "") & name

proc drawArrow(x, y: int; body, tip: Color) =
  ## A blocky arrow that still reads as a pointer in a character grid.
  const Shape = [
    (0, 0),
    (0, 1), (1, 1),
    (0, 2), (1, 2), (2, 2),
    (0, 3), (1, 3), (2, 3), (3, 3),
    (0, 4), (1, 4),
  ]
  for p in Shape:
    drawPoint(x + p[0], y + p[1], body)
  ## A one-cell tip in the outline colour marks the exact hot spot.
  drawPoint(x, y, tip)

proc addLog(log: var seq[string]; line: string) =
  log.insert(line, 0)
  if log.len > MaxLog:
    log.setLen(MaxLog)

proc main =
  let layout = createWindow(80, 24)
  var width = layout.width
  var height = layout.height
  var fm = FontMetrics()
  let font = openFont("", layout.scaled(1), fm)
  ## The terminal carries the style on the font handle: one variant per style,
  ## `drawText` turns it into cell attributes.
  let fontBold = styledFont(font, {FontStyle.bold})
  let fontItalic = styledFont(font, {FontStyle.italics})
  let fontUnderline = styledFont(font, {FontStyle.underline})
  let fontStrike = styledFont(font, {FontStyle.strikethrough})
  setWindowTitle("uirelays terminal demo")

  let palette = [
    color(137, 180, 250),   # blue
    color(166, 227, 161),   # green
    color(203, 166, 247),   # mauve
    color(243, 139, 168),   # red
  ]
  let bg = color(30, 30, 46)
  let panel = color(49, 50, 68)
  let panelAlt = color(24, 24, 37)
  let fg = color(205, 214, 244)
  let muted = color(127, 132, 156)
  let border = color(88, 91, 112)
  let pointerColor = color(249, 226, 175)

  var running = true
  var counter = 0
  var theme = 0
  var mouseX = width div 2
  var mouseY = height div 2
  var mouseSeen = false
  var hovered = -1
  var pressed = -1
  var log: seq[string] = @[]
  var typed: seq[string] = @[]   ## typed codepoints (each event is one)
  var cursorIdx = 0              ## index into CursorShapes
  var lastCursorIdx = -1         ## last shape pushed to the terminal
  var frameMode = frameSolid     ## solid frame or one of the character frames
  var imageMode = false          ## the blitRGBA image view

  ## One image rendered both ways: half blocks need 2 rows of pixels per cell,
  ## one-per-cell needs as many pixel rows as cell rows.
  const ImgW = 26
  const ImgRows = 12
  var imgHalf = makeTestImage(ImgW, ImgRows * 2)
  var imgCells = makeTestImage(ImgW, ImgRows)
  var polyline: seq[Point] = @[] ## left clicks on empty space, joined by lines
  var buttons: array[ButtonCount, Button]

  addLog(log, "Ready -- move the mouse, click a button, scroll, type.")

  proc buttonAt(x, y: int): int =
    for i in 0 ..< ButtonCount:
      if buttons[i].r.contains(point(x, y)):
        return i
    -1

  proc activate(i: int) =
    case i
    of 0:
      inc counter
      addLog(log, "Count -> " & $counter)
    of 1:
      theme = (theme + 1) mod palette.len
      addLog(log, "Theme -> " & $theme)
    of 2:
      cursorIdx = (cursorIdx + 1) mod CursorShapes.len
      addLog(log, "Cursor -> " & cursorName(CursorShapes[cursorIdx]))
    of 3:
      frameMode = (if frameMode == high(FrameMode): low(FrameMode)
                   else: FrameMode(ord(frameMode) + 1))
      addLog(log, "Frame -> " & frameName(frameMode))
    of 4:
      log.setLen 0
      polyline.setLen 0
      addLog(log, "Log and line cleared")
    of 5:
      running = false
    else: discard

  while running:
    # --- geometry for this frame ------------------------------------------
    let margin = 1
    let gap = 2
    let btnY = 2
    let btnH = 3
    let btnW = max(6, (width - 2 * margin - (ButtonCount - 1) * gap) div ButtonCount)
    for i in 0 ..< ButtonCount:
      buttons[i].r = rect(margin + i * (btnW + gap), btnY, btnW, btnH)
    buttons[0].label = "Count"
    buttons[1].label = "Theme"
    buttons[2].label = "Cursor"
    buttons[3].label = "Frame"
    buttons[4].label = "Clear"
    buttons[5].label = "Quit"

    # --- events ------------------------------------------------------------
    var e = Event()
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowMetricsEvent, WindowResizeEvent:
        width = e.x
        height = e.y
      of WindowFocusGainedEvent:
        addLog(log, "focus gained")
      of WindowFocusLostEvent:
        addLog(log, "focus lost")
      of MouseMoveEvent:
        mouseX = e.x
        mouseY = e.y
        mouseSeen = true
      of MouseDownEvent:
        mouseX = e.x
        mouseY = e.y
        mouseSeen = true
        pressed = buttonAt(e.x, e.y)
        var tag = ""
        case e.clicks
        of 2: tag = " double-click"
        of 3: tag = " triple-click"
        else: discard
        addLog(log, "MouseDown " & $e.button & tag & " @ " & $e.x & "," & $e.y)
        if e.button == LeftButton and pressed >= 0:
          activate(pressed)
        elif e.button == LeftButton:
          ## Empty space: drop a vertex for the `drawLine` polyline.
          polyline.add point(e.x, e.y)
          if polyline.len > 64: polyline.delete(0)
      of MouseUpEvent:
        mouseX = e.x
        mouseY = e.y
        pressed = -1
        addLog(log, "MouseUp " & $e.button & " @ " & $e.x & "," & $e.y)
      of MouseWheelEvent:
        if e.x != 0:
          addLog(log, "Wheel x=" & $e.x)
        else:
          addLog(log, "Wheel y=" & $e.y)
      of KeyDownEvent:
        case e.key
        of KeyEsc:
          running = false
        of KeyQ:
          if CtrlPressed in e.mods: running = false
          else: addLog(log, "Key " & keyLabel(e))
        of Key1 .. Key6:
          activate(ord(e.key) - ord(Key1))
        of KeyC:
          log.setLen 0
          polyline.setLen 0
          addLog(log, "Log and line cleared")
        of KeyY:
          if CtrlPressed in e.mods:
            var copied = ""
            for cp in typed: copied.add cp
            putClipboardText(copied)
            addLog(log, "Copied " & $copied.len & " bytes to clipboard")
          else:
            addLog(log, "Key " & keyLabel(e))
        of KeyI:
          imageMode = not imageMode
        else:
          addLog(log, "Key " & keyLabel(e))
      of TextInputEvent:
        ## One codepoint per event, already UTF-8. Keep the last 24 as whole
        ## strings so a multi-byte character is never cut in half.
        var cp = ""
        for c in e.text:
          if c == '\0': break
          cp.add c
        typed.add cp
        if typed.len > 24: typed.delete(0)
      else: discard

    # --- draw --------------------------------------------------------------
    hovered = buttonAt(mouseX, mouseY)

    fillRect(rect(0, 0, width, height), bg)

    # header
    fillRect(rect(0, 0, width, 1), panel)
    discard drawText(font, 1, 0, "uirelays :: terminal demo", fg, panel)
    let themeTag = "theme " & $theme & " "
    if themeTag.len + 2 < width:
      discard drawText(font, width - themeTag.len - 1, 0, themeTag,
                       palette[theme], panel)

    # --- colour spectrum --------------------------------------------------
    # Row 1 sweeps the hue, row 5 goes from black to white. On a 16-colour
    # terminal both band visibly, on 256 less, on truecolor not at all -- the
    # clearest way to see how deep the terminal really is.
    if width > 1:
      let last = float(width - 1)
      for x in 0 ..< width:
        let t = float(x) / last
        drawPoint(x, 1, hueColor(t))
        let g = uint8(t * 255.0 + 0.5)
        drawPoint(x, 5, color(g, g, g))

    # A legend of the text styles, drawn over the ramp. Each is the *same*
    # `drawText` call with a differently styled handle.
    block:
      var sx = 1
      sx += drawText(font, sx, 5, "regular ", fg, bg).w
      sx += drawText(fontBold, sx, 5, "bold ", fg, bg).w
      sx += drawText(fontItalic, sx, 5, "italic ", fg, bg).w
      sx += drawText(fontUnderline, sx, 5, "underline ", fg, bg).w
      discard drawText(fontStrike, sx, 5, "strike", fg, bg)

    # buttons
    for i in 0 ..< ButtonCount:
      let b = buttons[i]
      let isHot = i == hovered
      let isDown = i == pressed and isHot
      let fill = (if isDown: palette[theme]
                  elif isHot: panelAlt
                  else: panel)
      fillRect(b.r, fill)
      drawPanel(font, b.r, frameMode, palette[theme], fill)
      let p = centered(b.r, b.label)
      discard drawText(font, p.x, p.y, b.label,
                       (if isDown: bg else: fg), fill)

    # live status
    discard drawText(font, margin, btnY + btnH + 1,
                     "Clicks: " & $counter, fg, bg)
    var status = $width & "x" & $height &
                 "  cursor: " & cursorName(CursorShapes[cursorIdx]) &
                 "  mouse x=" & $mouseX & " y=" & $mouseY
    if hovered >= 0:
      status &= "  over: " & buttons[hovered].label
    elif not mouseSeen:
      status &= "  (move the mouse to show the pointer)"
    if status.len < width - 1:
      discard drawText(font, margin, btnY + btnH + 2, status, muted, bg)
    ## Show what has been typed, umlauts included (one drawText writes each
    ## codepoint's whole UTF-8 sequence into one cell). Skip it rather than cut
    ## a glyph in half when the line does not fit.
    if btnY + btnH + 3 < height - 1:
      var typedStr = "typed: "
      for cp in typed: typedStr.add cp
      if typedStr.len <= width - 2:
        discard drawText(font, margin, btnY + btnH + 3, typedStr, fg, bg)

    # event log
    let helpY = height - 1
    let logH = max(3, min(16, height - 10))
    let logY = max(btnY + btnH + 3, helpY - logH)
    if logY < helpY:
      let rh = helpY - logY
      fillRect(rect(0, logY, width, rh), panelAlt)
      drawPanel(font, rect(0, logY, width, rh), frameMode, border, panelAlt)
      discard drawText(font, 1, logY, " Events ", palette[theme], panelAlt)
      var row = 0
      for line in log:
        if row >= rh - 2: break
        var s = line
        if width > 4 and s.len > width - 3:
          s = s[0 ..< width - 3]
        discard drawText(font, 2, logY + 1 + row, s, fg, panelAlt)
        inc row

    # help line
    discard drawText(font, margin, helpY,
                     "1-6 buttons  c clear  click empty: draw  i image  Ctrl+Q quit",
                     muted, bg)

    ## The same pixels through `blitRGBA` both ways, side by side -- `blitStyle`
    ## is the terminal-wide knob, flipped per call so one frame shows both.
    if imageMode:
      let top = btnY + btnH + 1
      let imgY = top + 1
      let availH = max(1, helpY - imgY)
      fillRect(rect(0, top, width, helpY - top), panelAlt)
      discard drawText(font, 1, top, "half blocks (26x24px)", fg, panelAlt)
      discard drawText(font, 29, top, "1x1 cells (26x12px)", fg, panelAlt)
      blitStyle = blitHalfBlocks
      discard blitRGBA(pixelPtr(imgHalf), ImgW, ImgRows * 2,
                       rect(1, imgY, ImgW, availH))
      blitStyle = blitCells
      discard blitRGBA(pixelPtr(imgCells), ImgW, ImgRows,
                       rect(29, imgY, ImgW, availH))

    # The `drawLine` polyline: segments between the dropped points, a marker at
    # each vertex, and a rubber band from the last point to the pointer. Drawn
    # before the pointer so the pointer stays on top.
    if polyline.len > 0:
      for i in 1 ..< polyline.len:
        ## Each segment gets its own hue, so the drawing shows colour with the
        ## same reduction the terminal really has.
        let h = float(i - 1) / float(max(1, polyline.len - 1))
        drawLine(polyline[i - 1].x, polyline[i - 1].y,
                 polyline[i].x, polyline[i].y, hueColor(h))
      for p in polyline:
        drawPoint(p.x, p.y, fg)
      if mouseSeen:
        let last = polyline[^1]
        drawLine(last.x, last.y, mouseX, mouseY, border)

    ## Push the cursor shape when it changes (DECSCUSR). The frame shows the
    ## cursor again after each refresh, so this is what stays visible.
    if cursorIdx != lastCursorIdx:
      setTerminalCursor(CursorShapes[cursorIdx])
      lastCursorIdx = cursorIdx

    # the virtual pointer, last so it is always on top
    if mouseSeen:
      drawArrow(mouseX, mouseY, pointerColor, bg)

    refresh()
    sleep(16)   # ~60fps

  closeFont(font)
  shutdown()

main()
