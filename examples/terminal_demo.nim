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
##   1-4        activate the matching button from the keyboard
##   c          clear the event log
##   Esc/Ctrl+Q quit

import std/strutils
import uirelays

const
  ButtonCount = 4
  MaxLog = 200

type
  Button = object
    label: string
    r: Rect

proc centered(r: Rect; label: string): tuple[x, y: int] =
  ## Where a one-row label sits so it looks centred in the rectangle.
  (r.x + max(0, (r.w - label.len) div 2), r.y + r.h div 2)

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
    fillRect(rect(x + p[0], y + p[1], 1, 1), body)
  ## A one-cell tip in the outline colour marks the exact hot spot.
  fillRect(rect(x, y, 1, 1), tip)

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
      log.setLen 0
      addLog(log, "Log cleared")
    of 3:
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
    buttons[2].label = "Clear"
    buttons[3].label = "Quit"

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
        of Key1 .. Key4:
          activate(ord(e.key) - ord(Key1))
        of KeyC:
          log.setLen 0
          addLog(log, "Log cleared")
        of KeyY:
          if CtrlPressed in e.mods:
            var copied = ""
            for cp in typed: copied.add cp
            putClipboardText(copied)
            addLog(log, "Copied " & $copied.len & " bytes to clipboard")
          else:
            addLog(log, "Key " & keyLabel(e))
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

    # buttons
    for i in 0 ..< ButtonCount:
      let b = buttons[i]
      let isHot = i == hovered
      let isDown = i == pressed and isHot
      let fill = (if isDown: palette[theme]
                  elif isHot: panelAlt
                  else: panel)
      fillRect(b.r, fill)
      drawFrame(b.r, palette[theme], 1)
      let p = centered(b.r, b.label)
      discard drawText(font, p.x, p.y, b.label,
                       (if isDown: bg else: fg), fill)

    # live status
    discard drawText(font, margin, btnY + btnH + 1,
                     "Clicks: " & $counter, fg, bg)
    var status = $width & "x" & $height & "  mouse x=" & $mouseX & " y=" & $mouseY
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
      drawFrame(rect(0, logY, width, rh), border, 1)
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
                     "1-4 buttons  c clear  Ctrl/Shift/Alt logged  Ctrl+Q quit",
                     muted, bg)

    # the virtual pointer, last so it is always on top
    if mouseSeen:
      drawArrow(mouseX, mouseY, pointerColor, bg)

    refresh()
    sleep(16)   # ~60fps

  closeFont(font)
  shutdown()

main()
