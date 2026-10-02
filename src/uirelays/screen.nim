# Platform-independent screen/drawing relays.
# Part of the core stdlib abstraction (plan.md).

import coords

type
  Color* = object
    r*, g*, b*, a*: uint8

  Font* = distinct int    ## opaque handle; 0 = invalid
  Image* = distinct int   ## opaque handle; 0 = invalid

  FontStyle* {.pure.} = enum
    bold, italics, underline, strikethrough
  FontStyles* = set[FontStyle]
    ## Text-style hints asked of a font, beyond its size. `bold` and `italics`
    ## are faces (a different cut, or one the driver synthesises); `underline`
    ## and `strikethrough` are decorations a driver applies while drawing. They
    ## are carried on the font handle so `drawText` needs no style parameter,
    ## and every one is a wish: a driver that cannot produce it draws the plain
    ## face/run instead, so styled text is at worst unstyled, never missing.
    ## `{}` is the upright regular face every driver can produce.

  TextExtent* = object
    w*, h*: int

  FontMetrics* = object
    ascent*, descent*, lineHeight*: int

  ScreenLayout* = object
    ## Everything here is integers on purpose: a display's scale is either a
    ## whole number of device pixels per coordinate unit, or -- for the 125%
    ## and 150% displays where that is not true -- a percentage, which is
    ## still an integer.
    width*, height*: int  ## window size, in the unit the driver draws in
    pitch*: int
    scaleX*, scaleY*: int ## device pixels the driver *already* puts per
                          ## coordinate unit, so `width * scaleX` is the
                          ## physical width. Purely informational: an app
                          ## must not scale its own drawing by this.
    uiScale*: int         ## percent an app should enlarge its fonts and
                          ## hardcoded pixel sizes by to keep them physically
                          ## the same on any display. 100 means the driver or
                          ## the platform already accounts for the display's
                          ## density; 200 means the app draws twice as large.
    fullScreen*: bool

  CursorKind* = enum
    curDefault, curArrow, curIbeam, curWait,
    curCrosshair, curHand, curSizeNS, curSizeWE

  WindowRelays* = object
    createWindow*: proc (layout: var ScreenLayout;
                         icon: pointer; iconLen: int) {.nimcall.}
      ## `icon` is a packed `_NET_WM_ICON` payload -- `iconLen` `uint32`s of
      ## (width, height, then ARGB pixels), or nil. Everything a window is
      ## given once and for its whole life is given here: its size, and the
      ## picture and the name a desktop knows it by. The name is not a
      ## parameter, because a driver can read it off the executable itself.
      ## Ignored by the backends that take their icon from a PE resource, from
      ## a bundle, or from an icon theme.
    getWindowLayout*: proc (): ScreenLayout {.nimcall.}
    refresh*: proc () {.nimcall.}
    saveState*: proc () {.nimcall.}
    restoreState*: proc () {.nimcall.}
    setClipRect*: proc (r: Rect) {.nimcall.}
    setCursor*: proc (c: CursorKind) {.nimcall.}
    setWindowTitle*: proc (title: string) {.nimcall.}
      ## What the window says it is *showing* -- a document name, typically,
      ## and it changes as often as that does. What it says it *is* is
      ## `WM_CLASS`, which `createWindow` sets and nothing changes.

  FontRelays* = object
    openFont*: proc (path: string; size: int; style: FontStyles;
                     metrics: var FontMetrics): Font {.nimcall.}
    closeFont*: proc (f: Font) {.nimcall.}
    getFontMetrics*: proc (f: Font): FontMetrics {.nimcall.}
    measureText*: proc (f: Font; text: string): TextExtent {.nimcall.}
    drawText*: proc (f: Font; x, y: int; text: string;
                     fg, bg: Color): TextExtent {.nimcall.}
    drawMeasuredText*: proc (f: Font; x, y: int; text: string;
                             fg, bg: Color; size: TextExtent) {.nimcall.}
      ## `drawText` for a caller that has measured the text already: the
      ## driver is handed the extent instead of walking the glyphs a second
      ## time to find how wide a background to fill. Optional, and a shortcut
      ## rather than a second way to draw -- a driver that leaves it nil is
      ## called through `drawText` and draws exactly what it drew before.

  DrawRelays* = object
    fillRect*: proc (r: Rect; color: Color) {.nimcall.}
    drawLine*: proc (x1, y1, x2, y2: int; color: Color) {.nimcall.}
    drawPoint*: proc (x, y: int; color: Color) {.nimcall.}
    loadImage*: proc (path: string): Image {.nimcall.}
    freeImage*: proc (img: Image) {.nimcall.}
    drawImage*: proc (img: Image; src, dst: Rect) {.nimcall.}
    imageSize*: proc (img: Image): tuple[w, h: int] {.nimcall.}
      ## The picture's own size, in its own pixels. `drawImage`'s `src` is a
      ## rectangle in exactly those, so without this a caller can crop but
      ## cannot say "all of it": it has no idea how big all of it is, and a
      ## whole image drawn as `rect(0, 0, dst.w, dst.h)` is the top-left
      ## corner of it, cropped to the shape of the hole it was going into.
      ## Optional, and `(0, 0)` when a driver leaves it nil -- a caller that
      ## wants the aspect ratio has to have another plan for that case.
    blitRGBA*: proc (pixels: ptr UncheckedArray[uint32]; w, h: int;
                     dst: Rect): bool {.nimcall.}
      ## Put `w` * `h` finished pixels on the surface at `dst`, one row after
      ## another, each `0x00RRGGBB` in the host's own byte order. Opaque:
      ## whatever was transparent about them the caller has already composited
      ## against what it wanted behind them, because a surface is not asked to
      ## blend and the top byte is ignored.
      ##
      ## No scaling -- `w` and `h` are what lands, and `dst.w` and `dst.h`
      ## only clip. A caller with a picture of another size resizes it first,
      ## which is where it belongs: the caller knows whether this is a
      ## thumbnail or a print, and the surface would only ever nearest-
      ## neighbour it.
      ##
      ## This is the escape hatch for anything a driver has no relay for.
      ## An application that can produce pixels -- a picture decoder, a chart,
      ## a PDF page -- needs nothing of the driver but somewhere to put them,
      ## and gets the clip rectangle and the frame's dirty tracking for free
      ## by going through the driver rather than around it.
      ##
      ## `false` when the surface cannot take them at all: too odd a pixel
      ## format, or no window yet. It is not an error the caller can fix, so
      ## the answer is meant for choosing a fallback to draw instead, and it
      ## is the same answer every time for a given surface.

proc `==`*(a, b: Font): bool {.borrow.}
proc `==`*(a, b: Image): bool {.borrow.}

var windowRelays* = WindowRelays(
  createWindow: proc (layout: var ScreenLayout;
                      icon: pointer; iconLen: int) = discard,
  getWindowLayout: proc (): ScreenLayout =
    ScreenLayout(scaleX: 1, scaleY: 1, uiScale: 100),
  refresh: proc () = discard,
  saveState: proc () = discard,
  restoreState: proc () = discard,
  setClipRect: proc (r: Rect) = discard,
  setCursor: proc (c: CursorKind) = discard,
  setWindowTitle: proc (title: string) = discard)

var fontRelays* = FontRelays(
  openFont: proc (path: string; size: int; style: FontStyles;
                  metrics: var FontMetrics): Font = Font(0),
  closeFont: proc (f: Font) = discard,
  getFontMetrics: proc (f: Font): FontMetrics = FontMetrics(),
  measureText: proc (f: Font; text: string): TextExtent = TextExtent(),
  drawText: proc (f: Font; x, y: int; text: string;
                  fg, bg: Color): TextExtent = TextExtent())

var drawRelays* = DrawRelays(
  fillRect: proc (r: Rect; color: Color) = discard,
  drawLine: proc (x1, y1, x2, y2: int; color: Color) = discard,
  drawPoint: proc (x, y: int; color: Color) = discard,
  loadImage: proc (path: string): Image = Image(0),
  freeImage: proc (img: Image) = discard,
  drawImage: proc (img: Image; src, dst: Rect) = discard)

const
  MaxWindowWidth* = -1
    ## Pass as `createWindow`'s width for "every bit of width the desktop
    ## gives a window". See `MaxWindowHeight`.
  MaxWindowHeight* = -1
    ## Pass as `createWindow`'s height for "every bit of height the desktop
    ## gives a window" -- the screen minus the menu bar, the Dock, the
    ## taskbar, whatever the platform reserves.
    ##
    ## This is not `fullScreen`: the window keeps its title bar and its place
    ## among the other windows, and on macOS it does not move to a Space of
    ## its own. Either dimension can be given on its own, so a window can
    ## span the full width at a fixed height.

# Convenience wrappers
proc createWindow*(requestedW, requestedH: int; fullScreen = false;
                   icon: openArray[uint32] = []): ScreenLayout =
  ## The defaults are what a driver that knows nothing about display density
  ## reports, so a driver only has to write back what it actually knows.
  ##
  ## `MaxWindowWidth` / `MaxWindowHeight` ask for as much space as a window
  ## may have. The layout that comes back always holds the real size in
  ## pixels -- the sentinel never survives the call, so the rest of an app
  ## never has to know about it.
  ##
  ## `icon` is the taskbar and title-bar bitmap, in the layout X11 asks for:
  ## one or more images, each `width`, `height`, then `width*height` pixels as
  ## `0xAARRGGBB`. It belongs here rather than in a call of its own because it
  ## is wanted before the window is on screen -- a window that is mapped first
  ## and given its icon afterwards shows the desktop's placeholder in between.
  ##
  ## Who the window *belongs to* is not passed in and cannot be: it is the name
  ## of the executable, which the driver reads for itself and puts in
  ## `WM_CLASS`. That is what a `.desktop` file's `StartupWMClass` matches, and
  ## matching it is the other way an icon reaches the taskbar -- through the
  ## entry's `Icon=` and the icon theme. `icon` is for the window itself, and
  ## for the desktops and the moments where no entry is installed to look up.
  result = ScreenLayout(width: requestedW * unitW, height: requestedH * unitH,
                        scaleX: 1, scaleY: 1, uiScale: 100,
                        fullScreen: fullScreen)
  windowRelays.createWindow(result,
    if icon.len > 0: cast[pointer](unsafeAddr icon[0]) else: nil, icon.len)
  ## The driver fills the layout in driver coordinates; the app sees units.
  result.width = toUnitX(result.width)
  result.height = toUnitY(result.height)

proc getWindowLayout*(): ScreenLayout =
  ## The current size and scale, in application units. Worth re-reading after
  ## the window moved to another monitor; `WindowMetricsEvent` reports the same
  ## numbers.
  result = windowRelays.getWindowLayout()
  result.width = toUnitX(result.width)
  result.height = toUnitY(result.height)

proc scaled*(layout: ScreenLayout; value: int): int =
  ## Enlarge a hardcoded font size or pixel dimension for this display.
  ## Integer arithmetic throughout, so 125% and 150% displays stay exact.
  value * layout.uiScale div 100

proc refresh*() = windowRelays.refresh()
proc saveState*() = windowRelays.saveState()
proc restoreState*() = windowRelays.restoreState()
proc setClipRect*(r: Rect) = windowRelays.setClipRect(r.scaled)
proc setCursor*(c: CursorKind) = windowRelays.setCursor(c)
proc setWindowTitle*(title: string) = windowRelays.setWindowTitle(title)

type
  StyledSlot = object
    ## What `styledFont` needs to open a bold or italic version of a font that
    ## is already open: the very arguments it was opened with.
    base: Font
    path: string
    size: int
    variants: array[16, Font]  ## one per combination of the four style bits

var openedFonts: seq[StyledSlot]
  ## Only the upright fonts an app opened itself; the variants hang off them
  ## and are closed with them, so an app never has to know they exist.

proc variantIndex(style: FontStyles): int {.inline.} =
  ## One bit per style, so the four styles give sixteen cache slots.
  if FontStyle.bold in style: result = result or 1
  if FontStyle.italics in style: result = result or 2
  if FontStyle.underline in style: result = result or 4
  if FontStyle.strikethrough in style: result = result or 8

proc openFont*(path: string; size: int; metrics: var FontMetrics;
               style: FontStyles = {}): Font =
  ## `path` is a font file, or "" for the platform's monospaced default.
  ## `size` is in application units; `metrics` comes back in the same.
  result = fontRelays.openFont(path, size * unitH, style, metrics)
  metrics.ascent = toUnitY(metrics.ascent)
  metrics.descent = toUnitY(metrics.descent)
  metrics.lineHeight = toUnitY(metrics.lineHeight)
  if result.int != 0 and style == {}:
    openedFonts.add StyledSlot(base: result, path: path, size: size)

proc styledFont*(f: Font; style: FontStyles): Font =
  ## The same font in bold, in italics, or in both -- opened the first time it
  ## is asked for and closed together with `f`, so this can sit in a drawing
  ## loop.
  ##
  ## Hands back `f` itself when there is nothing to do: the plain style, a font
  ## this module never saw opened, or a face the driver could not produce. The
  ## worst case is text drawn upright, never text not drawn at all.
  if style == {} or f.int == 0: return f
  let k = variantIndex(style)
  for i in 0 ..< openedFonts.len:
    if openedFonts[i].base == f:
      if openedFonts[i].variants[k].int == 0:
        var metrics = FontMetrics()
        let v = fontRelays.openFont(openedFonts[i].path,
                                    openedFonts[i].size * unitH,
                                    style, metrics)
        # A failure is remembered as `f`, or every frame would try again.
        openedFonts[i].variants[k] = (if v.int == 0: f else: v)
      return openedFonts[i].variants[k]
  result = f

proc closeFont*(f: Font) =
  for i in 0 ..< openedFonts.len:
    if openedFonts[i].base == f:
      for v in openedFonts[i].variants:
        # `v == f` is the remembered failure above, closed once, below.
        if v.int != 0 and v != f: fontRelays.closeFont(v)
      openedFonts.del i
      break
  fontRelays.closeFont(f)

proc getFontMetrics*(f: Font): FontMetrics =
  result = fontRelays.getFontMetrics(f)
  result.ascent = toUnitY(result.ascent)
  result.descent = toUnitY(result.descent)
  result.lineHeight = toUnitY(result.lineHeight)
proc fontLineSkip*(f: Font): int =
  toUnitY(fontRelays.getFontMetrics(f).lineHeight)
proc measureText*(f: Font; text: string): TextExtent =
  ## The extent in application units (a driver returns driver coordinates).
  result = fontRelays.measureText(f, text)
  result.w = toUnitX(result.w)
  result.h = toUnitY(result.h)
proc drawText*(f: Font; x, y: int; text: string; fg, bg: Color;
               known = TextExtent()): TextExtent =
  ## `known` is what `measureText` answered for this very text in this very
  ## font. A caller that has asked already -- an editor has, to know where the
  ## run it is drawing ends -- passes it on, and the driver draws without
  ## measuring. It is a shortcut and not an instruction: a driver that does
  ## not offer one measures as it always did, so a wrong `known` is a wrong
  ## background on some platforms and nothing at all on others. Pass what
  ## `measureText` said or pass nothing.
  if known.w > 0 and fontRelays.drawMeasuredText != nil:
    let scaled = TextExtent(w: known.w * unitW, h: known.h * unitH)
    fontRelays.drawMeasuredText(f, x * unitW, y * unitH, text, fg, bg, scaled)
    result = known
  else:
    result = fontRelays.drawText(f, x * unitW, y * unitH, text, fg, bg)
    result.w = toUnitX(result.w)
    result.h = toUnitY(result.h)

proc fillRect*(r: Rect; color: Color) = drawRelays.fillRect(r.scaled, color)
proc drawFrame*(r: Rect; color: Color; width = 1) =
  ## An outline `width` pixels thick, drawn just inside `r`. Four `fillRect`s,
  ## so it needs nothing of a driver that `fillRect` does not already need.
  if r.w <= 0 or r.h <= 0 or width <= 0: return
  let w = min(width, min(r.w, r.h))
  fillRect(rect(r.x, r.y, r.w, w), color)
  fillRect(rect(r.x, r.y + r.h - w, r.w, w), color)
  fillRect(rect(r.x, r.y, w, r.h), color)
  fillRect(rect(r.x + r.w - w, r.y, w, r.h), color)
proc drawPoint*(x, y: int; color: Color) =
  ## One application unit. With a unit of one pixel this is the driver's own
  ## point; otherwise it fills a whole unit, which is what a terminal cell is --
  ## a driver point is a single pixel and would come out hairline-thin.
  if unitW == 1 and unitH == 1:
    drawRelays.drawPoint(x, y, color)
  else:
    drawRelays.fillRect(rect(x * unitW, y * unitH, unitW, unitH), color)
proc drawLine*(x1, y1, x2, y2: int; color: Color) =
  ## One unit thick. With a unit of one pixel this is the driver's own line;
  ## otherwise it steps cell by cell -- the way the terminal's line does -- so
  ## a diagonal is a run of unit blocks and not a one-pixel thread.
  if unitW == 1 and unitH == 1:
    drawRelays.drawLine(x1, y1, x2, y2, color)
    return
  ## Bresenham in application units.
  let dx = abs(x2 - x1)
  let dy = -abs(y2 - y1)
  var sx = (if x1 < x2: 1 else: -1)
  var sy = (if y1 < y2: 1 else: -1)
  var err = dx + dy
  var cx = x1
  var cy = y1
  while true:
    drawPoint(cx, cy, color)
    if cx == x2 and cy == y2: break
    let e2 = err * 2
    if e2 >= dy:
      err += dy
      cx += sx
    if e2 <= dx:
      err += dx
      cy += sy
proc loadImage*(path: string): Image =
  ## `Image(0)` from a driver that does not offer images, the same handle it
  ## gives for a file it could not open.
  if drawRelays.loadImage != nil: drawRelays.loadImage(path)
  else: Image(0)
proc freeImage*(img: Image) =
  if drawRelays.freeImage != nil: drawRelays.freeImage(img)
proc drawImage*(img: Image; src, dst: Rect) =
  ## `src` is in the picture's own pixels; `dst` is in application units.
  if drawRelays.drawImage != nil: drawRelays.drawImage(img, src, dst.scaled)
proc imageSize*(img: Image): tuple[w, h: int] =
  ## `(0, 0)` from a driver that does not offer it. See the relay.
  if drawRelays.imageSize != nil: drawRelays.imageSize(img)
  else: (0, 0)
proc blitRGBA*(pixels: ptr UncheckedArray[uint32]; w, h: int; dst: Rect): bool =
  ## `false` from a driver that does not offer it. `dst` is in application
  ## units and gets scaled; `w`/`h` are the pixel buffer's own size and are
  ## left alone, so the app decides the resolution (see `deviceRect`).
  if drawRelays.blitRGBA != nil: drawRelays.blitRGBA(pixels, w, h, dst.scaled)
  else: false

proc deviceRect*(r: Rect): Rect =
  ## The driver-coordinate rectangle an application-unit rectangle covers, at
  ## the current scale. Size an image's pixel buffer to this (`w`/`h`) so it
  ## lands crisp instead of being stretched by the driver.
  r.scaled

# Color constructors
proc color*(r, g, b: uint8; a: uint8 = 255): Color =
  Color(r: r, g: g, b: b, a: a)
