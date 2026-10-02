## examples/terminal_first.nim
## One drawing path, in cell units, readable as a terminal app *and* as a GUI.
##
## The app lays everything out on an 80x24 grid. `setUnitSize` says how many
## driver coordinates one cell covers -- 1x1 on the terminal (a cell *is* the
## unit), 9x18 elsewhere (one cell is 9x18 device pixels). Nothing below ever
## mentions pixels, and nothing scales itself: the framework does.
##
## Compile as a terminal app:
##   nim c -d:terminal examples/terminal_first.nim
## Compile as a GUI (whichever backend the platform picks):
##   nim c examples/terminal_first.nim
##
## Ctrl+plus / Ctrl+minus change the cell size (GUI only; a terminal cell is
## fixed).

import uirelays

when defined(terminal):
  const
    CellW = 1
    CellH = 1
else:
  const
    CellW = 9
    CellH = 18

proc centered(font: Font; r: Rect; s: string): tuple[x, y: int] =
  ## Where a one-row label sits in `r`, in cell units.
  (r.x + max(0, (r.w - measureText(font, s).w) div 2),
   r.y + max(0, (r.h - 1) div 2))

proc main =
  var cellW = CellW
  var cellH = CellH
  setUnitSize(cellW, cellH)
  let layout = createWindow(80, 24)
  var width = layout.width
  var height = layout.height

  var fm = FontMetrics()
  var font = openFont("", 1, fm)
  setWindowTitle("terminal-first demo")

  proc zoom(delta: int) =
    ## Ctrl+plus / Ctrl+minus change the cell size. On a terminal a cell is
    ## fixed, so it only does something on a GUI.
    when not defined(terminal):
      cellW = max(4, min(28, cellW + delta))
      cellH = max(8, min(56, cellH + 2 * delta))
      setUnitSize(cellW, cellH)
      closeFont(font)
      font = openFont("", 1, fm)
      let l = getWindowLayout()
      width = l.width
      height = l.height
    else:
      discard delta

  let bg = color(24, 24, 32)
  let panel = color(40, 42, 54)
  let fg = color(220, 220, 230)
  let accent = color(90, 160, 250)
  let muted = color(120, 122, 140)

  var running = true
  while running:
    var e = Event()
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of WindowMetricsEvent, WindowResizeEvent:
        width = e.x          # already in cells: the input wrapper unscales
        height = e.y
      of KeyDownEvent:
        if e.key == KeyEsc or (e.key == KeyQ and CtrlPressed in e.mods):
          running = false
        elif CtrlPressed in e.mods and e.key in {KeyPlus, KeyEqual}:
          zoom(1)
        elif CtrlPressed in e.mods and e.key == KeyMinus:
          zoom(-1)
      else: discard

    fillRect(rect(0, 0, width, height), bg)

    # header
    fillRect(rect(0, 0, width, 1), panel)
    discard drawText(font, 1, 0, "terminal-first demo", fg, panel)
    let sizeTag = $width & "x" & $height
    if sizeTag.len + 2 < width:
      discard drawText(font, width - sizeTag.len - 1, 0, sizeTag, accent, panel)

    # sidebar
    let sideW = max(10, width div 4)
    fillRect(rect(0, 2, sideW, height - 4), panel)
    discard drawText(font, 2, 3, "Menu", accent, panel)
    for i, item in ["Overview", "Files", "Settings", "About"]:
      discard drawText(font, 3, 5 + i, item, fg, panel)

    # main panel, outlined in the accent colour
    let main = rect(sideW + 1, 2, width - sideW - 2, height - 4)
    if main.w > 2 and main.h > 2:
      fillRect(main, panel)
      drawFrame(main, accent, 1)
      let title = "one layout, " & $cellW & "x" & $cellH & " per cell"
      let p = centered(font, main, title)
      discard drawText(font, p.x, p.y, title, fg, panel)

    # footer
    fillRect(rect(0, height - 1, width, 1), panel)
    discard drawText(font, 1, height - 1,
                     "Esc or Ctrl+Q quit", muted, panel)

    refresh()
    sleep(16)

  closeFont(font)
  shutdown()

main()
