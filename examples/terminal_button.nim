## examples/terminal_button.nim
## The terminal backend's "hello, world": one clickable button, the virtual
## mouse pointer the driver can now feed from SGR mouse motion, and a line that
## shows the last event. See `terminal_demo.nim` for the fuller version.
##
## Compile:
##   nim c -d:terminal examples/terminal_button.nim
##
## Run:
##   ./terminal_button
##
## Click the button to toggle it; Esc or Ctrl+Q quits.

import uirelays

proc drawPointer(x, y: int; color: Color) =
  ## A small blocky arrow, so the pointer is visible in a character grid.
  const Shape = [
    (0, 0),
    (0, 1), (1, 1),
    (0, 2), (1, 2), (2, 2),
    (0, 3), (1, 3), (2, 3), (3, 3),
  ]
  for p in Shape:
    fillRect(rect(x + p[0], y + p[1], 1, 1), color)

proc main =
  let layout = createWindow(60, 20)
  var width = layout.width
  var height = layout.height
  var fm = FontMetrics()
  let font = openFont("", layout.scaled(1), fm)
  setWindowTitle("Terminal button demo")

  let bg = color(0, 0, 0)
  let fg = color(255, 255, 255)
  let offColor = color(180, 0, 0)
  let onColor = color(0, 180, 0)
  let hotColor = color(80, 80, 110)
  let muted = color(150, 150, 150)
  let pointerColor = color(249, 226, 175)

  var on = false
  var running = true
  var mouseX = width div 2
  var mouseY = height div 2
  var mouseSeen = false
  var down = false
  var lastEvent = "Click the button"

  ## The button is centred both ways, so it keeps looking right after a resize.
  proc buttonRect(): Rect =
    let w = min(24, max(10, width - 12))
    let h = 3
    rect((width - w) div 2, (height - h) div 2 - 1, w, h)

  while running:
    let br = buttonRect()

    # --- events -----------------------------------------------------------
    var e = Event()
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowMetricsEvent, WindowResizeEvent:
        width = e.x
        height = e.y
      of MouseMoveEvent:
        mouseX = e.x
        mouseY = e.y
        mouseSeen = true
      of MouseDownEvent:
        mouseX = e.x
        mouseY = e.y
        mouseSeen = true
        if e.button == LeftButton and br.contains(point(e.x, e.y)):
          down = true
          lastEvent = "Button pressed"
        else:
          lastEvent = "MouseDown " & $e.button & " at " & $e.x & "," & $e.y
      of MouseUpEvent:
        mouseX = e.x
        mouseY = e.y
        if down and br.contains(point(e.x, e.y)):
          on = not on
          lastEvent = "Button toggled " & (if on: "ON" else: "OFF")
        down = false
      of MouseWheelEvent:
        lastEvent = "Wheel dx=" & $e.x & " dy=" & $e.y
      of KeyDownEvent:
        if e.key == KeyEsc or (e.key == KeyQ and CtrlPressed in e.mods):
          running = false
        else:
          lastEvent = "Key " & $e.key
      else: discard

    # --- draw -------------------------------------------------------------
    let hovered = br.contains(point(mouseX, mouseY))
    fillRect(rect(0, 0, width, height), bg)

    let fill =
      if down and hovered: hotColor
      elif hovered: hotColor
      else: (if on: onColor else: offColor)
    fillRect(br, fill)
    drawFrame(br, fg, 1)

    let label = if on: "ON" else: "OFF"
    discard drawText(font, br.x + (br.w - label.len) div 2, br.y + br.h div 2,
                     label, fg, fill)

    discard drawText(font, 2, 1, "uirelays terminal button", fg, bg)
    discard drawText(font, 2, height - 2, lastEvent, fg, bg)

    var coords = "x=" & $mouseX & " y=" & $mouseY
    if not mouseSeen:
      coords &= "  (move the mouse)"
    discard drawText(font, 2, height - 1, coords, muted, bg)

    if mouseSeen:
      drawPointer(mouseX, mouseY, pointerColor)

    refresh()
    sleep(16)

  closeFont(font)
  shutdown()

main()
