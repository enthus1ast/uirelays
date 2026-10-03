# PTY smoke tests

The terminal backend has two test layers:

- `tests/terminaldriver.nim` drives the driver **offscreen** (capture buffer, no
  TTY) — fast, deterministic, no terminal needed.
- `tools/pty_smoke.nim` runs a program in a **real pseudo-terminal**, so the
  driver takes its TTY path (raw mode, alternate screen, SGR mouse enable,
  signals). This is where the end-to-end behaviour is checked.

## `tools/pty_smoke.nim`

Opens a pty (`openpty` + `fork` + `login_tty`), execs the program, then while it
runs: reads its output, feeds scheduled input, and can change the pty size (the
kernel then sends `SIGWINCH`). At the end it reconstructs the screen from the
ANSI stream — cursor positioning, erase-display, one UTF-8 codepoint per cell —
and checks expectations.

```sh
nim c -o:pty_smoke tools/pty_smoke.nim
pty_smoke <program> [args...] [options]
```

| option | meaning |
|---|---|
| `--cols=N` / `--rows=N` | pty size in cells (default 80×24) |
| `--wait=SEC` | how long to drive the program (default 3.0) |
| `--send=MS:BYTES` | input at `MS` ms; `\e`, `\n`, `\r`, `\t`, `\xHH`, `\\` are translated |
| `--resize=MS:COLSxROWS` | `ioctl(TIOCSWINSZ)` at `MS` → `SIGWINCH` for the program |
| `--expect=TEXT` | fail unless `TEXT` is on the reconstructed screen |
| `--expect-raw=BYTES` | fail unless `BYTES` (escapes translated) is in the raw output — for cursor/mode/clipboard escapes the screen model doesn't show |
| `--expect-exit` | fail unless the program exited before `--wait` (quit/Ctrl-C handled, not killed) |
| `--dump` | print the reconstructed screen |

Repeat `--send`/`--expect`/`--expect-raw` as needed. Exit status is non-zero if
any expectation fails.

Example:

```sh
pty_smoke ./terminal_demo \
  --send='300:\e[<35;3;3M' --send='450:\e[<0;3;3M' --send='550:\e[<0;3;3m' \
  --send='900:\ex' \
  --expect='Count -> 1' --dump
```

## `tools/smoke_terminal.sh`

Builds `pty_smoke` and the two terminal examples, then runs the scenarios below
(artifacts in `.build/`, git-ignored). Run from anywhere.

```sh
./tools/smoke_terminal.sh
```

| scenario | covers |
|---|---|
| `terminal_demo` | button click, wheel + tilt, resize to 60×24, umlaut typing, Ctrl+A / Ctrl+Up / Shift+Delete, focus in/out, Ctrl+Y clipboard (OSC 52), raw `?1004h`, Ctrl-C quit |
| `terminal_demo colours` | 256-colour SGR (`38;5;` / `48;5;`) |
| `terminal_demo truecolor` | `COLORTERM=truecolor` → `38;2;` / `48;2;` |
| `terminal_demo keys` | Insert/Delete/End/End-as-`ESC[F`/Home logging, Cyrillic `Привет` |
| `terminal_demo draw` | empty-space clicks → `drawLine` polyline, no hang |
| `terminal_demo clicks` | double- and triple-click tags |
| `terminal_button` | toggle a single button |

Everything prints `ALL PASS` per scenario and `terminal smoke: OK` at the end.
