# Base types for the UI layer. No SDL or platform dependencies.

type
  Rect* = object
    x*, y*: int
    w*, h*: int

  Point* = object
    x*, y*: int

  GlobalPos* = object
    x*, y*, z*: int
    t*: int

proc rect*(x, y, w, h: int): Rect =
  Rect(x: x, y: y, w: w, h: h)

proc point*(x, y: int): Point =
  Point(x: x, y: y)

proc contains*(r: Rect; p: Point): bool =
  p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h

# ---------------------------------------------------------------------------
# Application units
#
# An app can declare how many driver coordinates one of its own units covers,
# so its drawing code -- a terminal app's cell grid, say -- stays the same on
# every backend. The wrappers in `screen`/`input` apply the factor; relays and
# drivers only ever see driver coordinates. Default 1x1: no scaling at all.
# ---------------------------------------------------------------------------

var
  unitW* = 1   ## driver coordinates per application unit, horizontally
  unitH* = 1   ## driver coordinates per application unit, vertically

proc setUnitSize*(w, h: int) =
  ## One application unit covers `w` x `h` driver coordinates. A terminal-first
  ## app draws in cells; setting `(9, 18)` makes the same code fill a 9x18 px
  ## grid on a GUI backend. Values are clamped to at least 1.
  unitW = max(1, w)
  unitH = max(1, h)

proc unitSize*(): tuple[w, h: int] {.inline.} =
  (unitW, unitH)

proc toUnitX*(v: int): int {.inline.} =
  ## Driver coordinate -> application units. Truncates; a caller that needs
  ## exactness keeps its maths in application units and only draws here.
  (if unitW > 1: v div unitW else: v)

proc toUnitY*(v: int): int {.inline.} =
  (if unitH > 1: v div unitH else: v)

proc scaled*(r: Rect): Rect {.inline.} =
  ## The driver-coordinate rectangle for an application-unit rectangle.
  rect(r.x * unitW, r.y * unitH, r.w * unitW, r.h * unitH)

proc scaled*(p: Point): Point {.inline.} =
  point(p.x * unitW, p.y * unitH)
