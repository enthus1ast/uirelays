## tools/pty_smoke.nim
## Run a terminal program in a pseudo-terminal, feed it scripted input, then
## reconstruct the screen from the ANSI stream and check what it drew.
##
## This is the tool the terminal demos are smoke-tested with: it drives a real
## TTY, so the driver takes its `tty` path (raw mode, alternate screen, SGR
## mouse enable) instead of the offscreen capture the unit tests use.
##
## Build:
##   nim c -o:pty_smoke tools/pty_smoke.nim
##
## Use:
##   pty_smoke <program> [args...] [options]
##
## Options (values use `=`; repeat `--send`/`--expect` as needed):
##   --cols=N        pty width in cells        (default 80)
##   --rows=N        pty height in cells       (default 24)
##   --wait=SEC      how long to drive it      (default 3.0)
##   --send=MS:BYTES input at MS milliseconds; `\e`, `\n`, `\r`, `\t`, `\xHH`
##                   and `\\` are translated
##   --resize=MS:COLSxROWS
##                   an ioctl(TIOCSWINSZ) at MS, which makes the kernel send
##                   SIGWINCH to the program (exercises the resize path)
##   --expect=TEXT   fail unless TEXT is somewhere on the reconstructed screen
##   --expect-raw=BYTES
##                   fail unless BYTES (escapes translated) appear in the raw
##                   output -- for cursor/mode/clipboard escapes the screen
##                   model does not show
##   --expect-exit   fail unless the program exited before `--wait` (i.e. it
##                   handled a quit/Ctrl-C rather than being killed)
##   --dump          print the reconstructed screen
##
## Example -- click the first button of terminal_demo and check the log:
##   nim c -d:terminal -o:/tmp/terminal_demo examples/terminal_demo.nim
##   nim c -o:/tmp/pty_smoke tools/pty_smoke.nim
##   /tmp/pty_smoke /tmp/terminal_demo \
##     --send='300:\e[<35;3;3M' --send='450:\e[<0;3;3M' \
##     --send='550:\e[<0;3;3m'  --send='900:\ex' \
##     --expect='Count -> 1' --dump
##
## Exit status is non-zero when any `--expect` was not found (or the program
## never started).

import std/[algorithm, os, parseopt, posix, strutils, times]

type
  Winsize {.importc: "struct winsize", header: "<termios.h>".} = object
    ws_row*, ws_col*, ws_xpixel*, ws_ypixel*: cushort
  ScriptedInput = object
    atMs*: int
    bytes*: string
  ScriptedResize = object
    atMs*: int
    cols*, rows*: int

proc openpty(amaster, aslave: ptr cint; name: cstring;
             termp, winp: pointer): cint {.importc, header: "<pty.h>".}
proc login_tty(fd: cint): cint {.importc, header: "<utmp.h>".}
proc ioctl(fd: cint; request: culong; arg: pointer): cint
  {.importc, header: "<sys/ioctl.h>", varargs.}

const TIOCSWINSZ = culong(0x5414)

const HexDigits = {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}

proc hexVal(c: char): int =
  if c in {'0' .. '9'}: ord(c) - ord('0')
  elif c in {'a' .. 'f'}: ord(c) - ord('a') + 10
  else: ord(c) - ord('A') + 10

proc unescape(s: string): string =
  ## Translate the handful of escapes a terminal test needs.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of 'e', 'E': result.add '\e'; i += 2
      of 'n': result.add '\n'; i += 2
      of 'r': result.add '\r'; i += 2
      of 't': result.add '\t'; i += 2
      of '\\': result.add '\\'; i += 2
      of 'x':
        var v = 0
        var j = i + 2
        var n = 0
        while j < s.len and n < 2 and s[j] in HexDigits:
          v = v * 16 + hexVal(s[j])
          inc j
          inc n
        result.add chr(v)
        i = j
      else:
        result.add s[i]
        inc i
    else:
      result.add s[i]
      inc i

proc utf8LenAt(data: string; i: int): int =
  ## Bytes of the UTF-8 codepoint at `data[i]`; 1 for ASCII or a malformed byte.
  ## One codepoint occupies one terminal cell, so the screen model must advance
  ## by this, not by a byte.
  let b = data[i].uint8
  var k = 0
  if b < 0x80: k = 1
  elif b >= 0xC2 and b <= 0xDF: k = 2
  elif b >= 0xE0 and b <= 0xEF: k = 3
  elif b >= 0xF0 and b <= 0xF4: k = 4
  else: return 1
  if i + k > data.len: return 1
  for j in 1 ..< k:
    if data[i + j].uint8 notin 0x80'u8 .. 0xBF'u8: return 1
  k

proc reconstruct(data: string; w, h: int): seq[string] =
  ## A tiny ANSI screen model: cursor positioning, erase-display, and literal
  ## text. Each cell holds one whole UTF-8 codepoint. Colours and private modes
  ## are ignored -- enough to read the UI back.
  var cells = newSeq[seq[string]](h)
  for r in 0 ..< h:
    cells[r] = newSeq[string](w)
    for c in 0 ..< w: cells[r][c] = " "
  var cx, cy = 0
  var i = 0
  while i < data.len:
    let c = data[i]
    if c == '\e' and i + 1 < data.len:
      if data[i + 1] == '[':
        var j = i + 2
        while j < data.len and data[j] notin {'@' .. '~'}: inc j
        if j >= data.len: break
        let params = data[(i + 2) ..< j]
        case data[j]
        of 'H':
          let p = params.split(';')
          cy = (if p.len > 0 and p[0].len > 0: parseInt(p[0]) else: 1) - 1
          cx = (if p.len > 1 and p[1].len > 0: parseInt(p[1]) else: 1) - 1
        of 'J':
          for r in 0 ..< h:
            for cc in 0 ..< w: cells[r][cc] = " "
        else: discard
        i = j + 1
        continue
      elif data[i + 1] == ']':          # OSC ... BEL
        var j = i + 2
        while j < data.len and data[j] != '\a': inc j
        i = j + 1
        continue
      else:
        i += 2
        continue
    elif ord(c) >= 32:
      let n = utf8LenAt(data, i)
      if cy >= 0 and cy < h and cx >= 0 and cx < w:
        cells[cy][cx] = data[i ..< i + n]
      inc cx
      i += n
      continue
    inc i
  result = newSeq[string](h)
  for r in 0 ..< h:
    result[r] = cells[r].join("")

proc toCStringArray(args: seq[string]): cstringArray =
  result = cast[cstringArray](alloc0((args.len + 1) * sizeof(cstring)))
  for i, a in args:
    result[i] = a.cstring

proc usage() =
  echo "usage: pty_smoke <program> [args...] [--cols=N] [--rows=N] [--wait=SEC]"
  echo "                 [--send=MS:BYTES]... [--resize=MS:COLSxROWS]..."
  echo "                 [--expect=TEXT]... [--dump]"

proc main =
  var cols = 80
  var rows = 24
  var waitSec = 3.0
  var dump = false
  var expectExit = false
  var sends: seq[ScriptedInput] = @[]
  var resizes: seq[ScriptedResize] = @[]
  var expects: seq[string] = @[]
  var expectsRaw: seq[string] = @[]
  var cmd: seq[string] = @[]

  for kind, key, val in getopt():
    case kind
    of cmdArgument: cmd.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "cols", "c": cols = parseInt(val)
      of "rows", "r": rows = parseInt(val)
      of "wait", "w": waitSec = parseFloat(val)
      of "send", "s":
        let colon = val.find(':')
        if colon < 0: quit "--send needs MS:BYTES, got: " & val
        sends.add ScriptedInput(atMs: parseInt(val[0 ..< colon]),
                                bytes: unescape(val[colon + 1 .. ^1]))
      of "resize", "z":
        let colon = val.find(':')
        let x = val.find('x')
        if colon < 0 or x < 0 or x < colon:
          quit "--resize needs MS:COLSxROWS, got: " & val
        resizes.add ScriptedResize(atMs: parseInt(val[0 ..< colon]),
                                   cols: parseInt(val[colon + 1 ..< x]),
                                   rows: parseInt(val[x + 1 .. ^1]))
      of "expect", "e": expects.add val
      of "expect-raw": expectsRaw.add unescape(val)
      of "expect-exit": expectExit = true
      of "dump", "d": dump = true
      of "help", "h": usage(); return
      else: quit "unknown option: " & key
    of cmdEnd: discard

  if cmd.len == 0:
    usage()
    quit 1
  sends.sort(proc (a, b: ScriptedInput): int = cmp(a.atMs, b.atMs))
  resizes.sort(proc (a, b: ScriptedResize): int = cmp(a.atMs, b.atMs))

  var ws = Winsize(ws_row: rows.cushort, ws_col: cols.cushort)
  var master, slave: cint
  if openpty(addr master, addr slave, nil, nil, addr ws) != 0:
    quit "openpty failed"

  let prog = toCStringArray(cmd)
  let pid = fork()
  if pid == 0:
    discard setsid()
    discard login_tty(slave)
    putEnv("TERM", "xterm-256color")
    discard execv(cmd[0].cstring, prog)
    quit 1
  discard close(slave)

  var outp = ""
  var idx = 0
  var ridx = 0
  var finalCols = cols
  var finalRows = rows
  let start = epochTime()
  var alive = true
  while alive and epochTime() - start < waitSec:
    var fds: TFdSet
    FD_ZERO(fds)
    FD_SET(master, fds)
    var tv = Timeval(tv_sec: posix.Time(0), tv_usec: posix.Suseconds(50_000))
    if select(master + 1, addr fds, nil, nil, addr tv) > 0:
      var buf: array[65536, char]
      let r = read(master, addr buf[0], buf.len)
      if r <= 0: alive = false
      else:
        for i in 0 ..< r: outp.add buf[i]
    let t = epochTime() - start
    while idx < sends.len and t * 1000.0 >= sends[idx].atMs.float:
      let msg = sends[idx].bytes
      if msg.len > 0:
        discard write(master, unsafeAddr msg[0], msg.len)
      inc idx
    while ridx < resizes.len and t * 1000.0 >= resizes[ridx].atMs.float:
      var ws = Winsize(ws_row: resizes[ridx].rows.cushort,
                       ws_col: resizes[ridx].cols.cushort)
      ## TIOCSWINSZ on the master makes the kernel signal SIGWINCH to the
      ## program's process group, exactly like a real terminal window resizing.
      discard ioctl(master, TIOCSWINSZ, addr ws)
      finalCols = resizes[ridx].cols
      finalRows = resizes[ridx].rows
      inc ridx

  if alive:
    discard kill(pid, SIGKILL)
  var status: cint
  discard waitpid(pid, status, 0)

  var failures = 0
  if expectExit:
    if alive:
      echo "  FAIL  program did not exit before --wait"
      inc failures
    else:
      echo "  PASS  program exited"

  let grid = reconstruct(outp, finalCols, finalRows)
  if dump:
    echo "=== reconstructed screen (", finalCols, "x", finalRows, ") ==="
    for r in 0 ..< grid.len:
      echo align($r, 2), "|", grid[r], "|"

  let screen = grid.join("\n")
  for want in expects:
    if screen.contains(want):
      echo "  PASS  ", want
    else:
      inc failures
      echo "  FAIL  ", want
  for want in expectsRaw:
    if outp.contains(want):
      echo "  PASS  raw ", want.escape
    else:
      inc failures
      echo "  FAIL  raw ", want.escape
  if expects.len == 0 and expectsRaw.len == 0 and not expectExit:
    echo "captured ", outp.len, " bytes"
  elif failures == 0:
    echo "ALL PASS"
  else:
    echo failures, " FAILURE(S)"
  if failures > 0: quit 1

main()
