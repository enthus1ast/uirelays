Mouse clicks and moves are not delivered, the problem is this:
1. Die Terminal-Mausunterstützung ist im Backend nicht aktiviert
• Maus-Events aktivieren (z. B. beim Start):
	• \e[?1000h (Aktiviert normale Mausklicks / Pressed & Released)
	• \e[?1003h (Aktiviert Klicks UND alle Mausbewegungen / Mouse Tracking)
	• \e[?1006h (Aktiviert das moderne SGR-Maus-Format, damit Koordinaten > 223 korrekt gelesen werden können – dringend empfohlen)
• Maus-Events deaktivieren (beim Beenden in shutdown()):
	• \e[?1000l oder \e[?1003l
	• \e[?1006l





# Known Bugs in uirelays terminal_driver.nim

## 1. Clipping mis‑calculation in `drawTextBody`
- **Location**: `drawTextBody` (around the loop that stamps each character)
- **Description**: The variables `inBounds` and `inClip` are computed once before the `for ch in text:` loop using the initial cursor position `cx`. Inside the loop `cx` is incremented, so the bounds/clip test quickly becomes stale. This causes characters to be drawn outside the clip rect or outside the surface when the string starts near a boundary, and it can also skip drawing characters that *should* be visible when the string starts inside but later moves outside.
- **Effect**: Visual corruption – missing or misplaced text.
- **Suggested fix**: Move the bounds/clip checks inside the loop (or recompute them each iteration).

```nim
for ch in text:
    let inBounds = cx >= 0 and y >= 0 and cx < cols and y < rows
    let inClip   = cx >= clip.x and cx < clip.x+clip.w and y >= clip.y and y < clip.y+clip.h
    if inBounds and inClip:
        setCell(cx, y, makeCell(ch, fg, bg))
    inc cx
```

## 2. Incorrect sentinel colour in `emitCell`
- **Location**: `emitCell` (when the cursor position changes)
- **Description**: To force a colour/SGR rewrite after a cursor move, the code sets `outFg` and `outBg` to a concrete white colour (`Color(r:255,g:255,b:255,a:255)`). If the following cell actually *is* white, the subsequent `if cell.fg != outFg` / `if cell.bg != outBg` tests will be false and the colour escape will **not** be emitted, leaving the terminal with the previous colour.
- **Effect**: Wrong foreground/background colours after a cursor move.
- **Suggested fix**: Use an invalid sentinel colour that can never match a real cell (e.g., `Color(r:255,g:255,b:255,a:0)`) or keep a boolean `positionChanged` flag and always emit colour escapes when the position changes.

## 3. Minor: `waitReady` error handling
- **Location**: `waitReady` – handling of `select` return value `< 0`
- **Description**: Any `n < 0` is treated as a possible `EINTR` and the loop simply continues. This masks other genuine errors (e.g., `EBADF`) that should be reported or handled differently.
- **Effect**: In rare cases the loop could spin forever or hide a real problem.
- **Suggested fix**: Check `errno` explicitly:
  ```nim
  if n < 0:
      if errno == EINTR:
          continue
      else:
          quit("select failed: " & strerror(errno))
  ```

## 4. Minor: `emitEscape` comment on ESC+SPACE
- **Location**: `emitEscape` – two‑byte sequence handling
- **Description**: The comment claims that `ESC` + space is treated as a “lone Escape key”, but the code actually consumes both bytes as an ignored control sequence (since space is excluded from the printable range check). The comment is misleading.
- **Effect**: No functional bug, but confusion for maintainers.
- **Suggested fix**: Update the comment to accurately describe the behaviour (or adjust the logic if the intent was different).

---

These bugs were identified during a code review of `src/uirelays/drivers/terminal_driver.nim`. Fixing the first two will resolve the most noticeable visual artefacts. The remaining items are optional improvements for robustness and clarity.





MORE:

    # ... (deine Schleife) ...

  # Am Ende wieder ausschalten, sonst verhält sich dein Terminal danach komisch!
  stdout.write("\e[?1000l\e[?1006l")
  stdout.flushFile()
  
  closeFont(font)
  shutdown()
