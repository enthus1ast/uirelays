## examples/terminal_button.nim
## A minimal example using the terminal backend that draws a clickable button.
##
## Compile:
##   nim c -d:terminal examples/terminal_button.nim
##
## Run:
##   ./terminal_button
##
## Click inside the button to toggle its colour and print a message.

import uirelays
import uirelays/[screen, input]

# ----------------------------------------------------------------------
# Button state
# ----------------------------------------------------------------------
var buttonPressed = false
const
  ButtonX = 10
  ButtonY = 10
  ButtonW = 20
  ButtonH = 3

# ----------------------------------------------------------------------
# Helper: point-in-rect test
# ----------------------------------------------------------------------
proc insideButton(x, y: int): bool =
  x >= ButtonX and x < ButtonX + ButtonW and
  y >= ButtonY and y < ButtonY + ButtonH

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
when isMainModule:
  # No explicit init needed; importing uirelays already called initBackend()
  # (which selects the terminal backend because we compile with -d:terminal).

  # Create window – we ask for a reasonable size; the terminal backend will
  # adapt to the actual terminal size (or the requested size when offscreen).
  let layout = createWindow(60, 20)   # width, height in cells
  var width = layout.width
  var height = layout.height

  # Open a font (any size works; the terminal backend treats height as 1 cell).
  var fm = FontMetrics()
  let font = openFont("", layout.scaled(1), fm)   # size 1 -> one cell tall
  setWindowTitle("Terminal button demo")

  var running = true
  var msg = "Click the button"

  while running:
    echo "foo"
    # --- process events ---
    var e = Event()
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of KeyDownEvent:
        if e.key == KeyEsc:
          running = false
        elif e.key == KeyQ and CtrlPressed in e.mods:
          running = false
      of MouseDownEvent:
        if e.button == LeftButton and insideButton(e.x, e.y):
          buttonPressed = not buttonPressed
          msg = "Button toggled to: " & (if buttonPressed: "ON" else: "OFF")
          echo msg
      else: discard

    # --- draw frame ---
    let bg = color(0, 0, 0)          # black background
    let fg = color(255, 255, 255)    # white foreground
    let buttonColor = if buttonPressed: color(0, 180, 0) else: color(180, 0, 0)  # green/red

    # clear screen
    fillRect(rect(0, 0, width, height), bg)

    # draw button rectangle
    fillRect(rect(ButtonX, ButtonY, ButtonW, ButtonH), buttonColor)

    # draw button label (centered)
    let label = if buttonPressed: "ON" else: "OFF"
    let labelWidth = label.len
    let labelX = ButtonX + (ButtonW - labelWidth) div 2
    let labelY = ButtonY + ButtonH div 2   # only one cell tall, so y = ButtonY
    discard drawText(font, labelX, labelY, label, fg, buttonColor)

    # show message at bottom
    discard drawText(font, 0, height - 1, msg, fg, bg)

    refresh()
    sleep(16)   # ~60fps

  closeFont(font)
  shutdown()
