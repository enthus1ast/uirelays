# Text styles carried on the font handle

Design decision behind extending `FontStyle` with `underline` and
`strikethrough` and having the terminal backend honour it.

## Problem

`FontStyles` already existed (`{bold, italics}`) and native drivers already used
it — but the terminal driver did `discard style` in `openFont`, returned
`Font(1)` for every font, and `drawTextBody` never set an attribute. So text
styles were completely lost on the terminal, and `styledFont` could not tell two
styles apart.

## Decision

Carry the text style **on the font handle**, not as a `drawText` parameter, and
extend the enum:

```nim
FontStyle = enum bold, italics, underline, strikethrough
```

The terminal maps the handle's style to cell attribute bits, which `emitCell`
turns into SGR. App code is identical to the native backends:

```nim
let link = styledFont(body, {FontStyle.underline})
discard drawText(link, x, y, "https://…", accent, bg)
```

## Rationale

- **One API everywhere.** Native drivers must know the style at *open* time to
  pick a face, so the style already belongs to the handle. The terminal just
  stops discarding it. `drawText` keeps its signature; nothing is added to the
  core drawing API.
- **Cheap.** `Cell.attr` already exists as a `uint16` using one bit. Four styles
  are four bits — **0 bytes** more per cell (`sizeof(Cell)` stays 16).
- **Free in the diff.** Attribute bits are part of `Cell` equality, so a style
  change repaints exactly the affected cells.
- **Graceful on other backends.** Every driver reads the set with membership
  tests (`if FontStyle.bold in style`), so the new bits are simply ignored where
  unsupported — the documented "plain at worst" contract. No native driver
  change is required.

## Mechanism

Terminal driver:

- `openFont` hands out a fresh handle per open and remembers its `FontStyles`
  (`fontStyles: seq[FontStyles]`); `fontStyleOf` reads it back in `drawTextBody`.
- `attrOf` maps the style to bits: `AttrBold 0x01`, `AttrItalic 0x02`,
  `AttrUnderline 0x04`, `AttrStrike 0x08`.
- `emitCell` tracks `outAttr` and emits only the SGR bits that changed
  (sets `1/3/4/9`, resets `22/23/24/29`); the frame starts reset, so `not
  outValid` just sets what is on.

`screen.nim`:

- `variantIndex` becomes a bitmask (0..15) and `StyledSlot.variants` grows to
  `array[16, Font]`, so every combination of the four styles caches its own
  handle.

## The trade-off we accept: faces **and** decorations

`bold`/`italics` are *faces* — a different cut, chosen once when the font is
loaded. `underline`/`strikethrough` are *decorations* — a line drawn over the
text. Some backends treat them as a font property (SDL_ttf, Win32 `HFONT`),
others as a per-run attribute (X11, Cocoa, GTK). Putting all four in
`FontStyles` means:

- `FontStyles` now means "style hints", not strictly "which face";
- decorations are per-handle, not per-run — you open a `link` handle rather than
  flagging one `drawText` call.

We accept this because it keeps a single, simple model ("the handle is a bundle
of style hints the backend applies as best it can"), and per-run decoration is
not needed yet. If it ever is, an optional `attrs` parameter on `drawText` can
be added later without disturbing this.

## Memory

`sizeof(Cell) = 16` before and after (the bits were unused). The only growth is
the per-base-font variant cache: `array[3, Font]` → `array[16, Font]`
(a few `int` handles), and `emitCell`'s local `outBold: bool` → `outAttr:
uint16`.

## Not included

`reverse`, `dim`, `blink` — a terminal can show them just as cheaply, but they
are not requested and would widen the enum further. Stop at the four that map to
real text intent.

## Verification

- `tests/terminaldriver.nim` → `styleTests`: distinct handles per style, SGR
  1/3/4/9 per style, no attribute for the regular face, and the `\e[22m` reset
  when a bold run is followed by a regular one.
- `tools/smoke_terminal.sh` → the demo draws a `regular bold italic underline
  strike` legend, asserted on screen and via raw `\e[4m` / `\e[9m`.
