## examples/event_echo.nim
## Simple test that echoes received events to stdout.
##
## Compile:
##   nim c -d:terminal examples/event_echo.nim
##
## Run:
##   ./event_echo
##
## Press keys, click mouse, resize window, etc. to see event descriptions.

import uirelays
import uirelays/[screen, input]

when isMainModule:
  # Importing uirelays already called initBackend() (terminal backend due to -d:terminal)

  # Create a modest window; the terminal backend will adapt to the real terminal size.
  let layout = createWindow(80, 24)   # width, height in cells
  var width = layout.width
  var height = layout.height

  # Open a font (size 1 -> one cell tall)
  var fm = FontMetrics()
  let font = openFont("", layout.scaled(1), fm)
  setWindowTitle("Event Echo Test")

  var running = true
  while running:
    var e = Event()
    while pollEvent(e):
      case e.kind

      of QuitEvent, WindowCloseEvent:
        running = false
      of KeyDownEvent:
        echo "KeyDown: key=", e.key, " mods=", e.mods
        if e.key == KeyQ:
          running = false
          break
      else:

        echo e

      # of KeyUpEvent:
      #   echo "KeyUp:   key=", e.key, " mods=", e.mods
      # of TextInputEvent:
      #   echo "TextInput: text=", e.text
      # of MouseDownEvent:
      #   echo "MouseDown: button=", e.button, " x=", e.x, " y=", e.y, " mods=", e.mods, " clicks=", e.clicks
      # of MouseUpEvent:
      #   echo "MouseUp:   button=", e.button, " x=", e.x, " y=", e.y, " mods=", e.mods
      # of MouseMoveEvent:
      #   echo "MouseMove: x=", e.x, " y=", e.y, " mods=", e.mods
      # of MouseWheelEvent:
      #   echo "MouseWheel: delta=", e.y, " x=", e.x, " y=", e.y, " mods=", e.mods
      # of WindowResizeEvent:
      #   echo "WindowResize: width=", e.x, " height=", e.y
      #   width = e.x
      #   height = e.y
      # of WindowMetricsEvent:
      #   echo "WindowMetrics: width=", e.x, " height=", e.y, " scaleX=", e.scaleX, " scaleY=", e.scaleY, " uiScale=", e.uiScale
      # of WindowFocusGainedEvent:
      #   echo "WindowFocusGained"
      # of WindowFocusLostEvent:
      #   echo "WindowFocusLost"
      # else:
      #   echo "Event kind: ", e.kind

    # Optional: clear screen and show a prompt so we see something.
    # We'll just draw a simple background and instructions.
    let bg = color(0, 0, 0)
    let fg = color(255, 255, 255)
    fillRect(rect(0, 0, width, height), bg)
    discard drawText(font, 1, 1, "Event Echo Test - click/type keys", fg, bg)
    discard drawText(font, 1, height-1, "Esc or Ctrl+Q to quit", fg, bg)
    refresh()
    sleep(16)   # ~60fps

  closeFont(font)
  shutdown()
