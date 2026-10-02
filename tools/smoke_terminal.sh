#!/bin/sh
# Smoke-test the terminal backend examples in a real pseudo-terminal.
#
#   tools/smoke_terminal.sh
#
# Builds `tools/pty_smoke.nim` and the two terminal examples, then drives each
# one with scripted SGR mouse input (motion, click, wheel, tilt) and checks the
# screen reconstructed from the ANSI stream. Run it from anywhere; artifacts go
# to `.build/` (git-ignored).
#
# This complements `tests/terminaldriver.nim`: that one tests the driver
# offscreen (capture buffer, no TTY), this one exercises the real TTY path --
# raw mode, the alternate screen, SGR mouse enable/disable -- end to end.

set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mkdir -p .build

nim c --hints:off -o:.build/pty_smoke tools/pty_smoke.nim
nim c --hints:off --path:src -d:terminal -o:.build/terminal_demo examples/terminal_demo.nim
nim c --hints:off --path:src -d:terminal -o:.build/terminal_button examples/terminal_button.nim

echo "smoke: terminal_demo"
.build/pty_smoke .build/terminal_demo --wait=2.0 \
  --send='300:\e[<35;3;3M' \
  --send='450:\e[<0;3;3M' \
  --send='550:\e[<0;3;3m' \
  --send='700:\e[<64;3;3M' \
  --send='850:\e[<66;3;3M' \
  --send='1200:\e[<35;70;20M' \
  --send='1500:\ex' \
  --expect='uirelays :: terminal demo' \
  --expect='Count -> 1' \
  --expect='Clicks: 1' \
  --expect='Wheel y=1' \
  --expect='Wheel x=1'

echo "smoke: terminal_button"
.build/pty_smoke .build/terminal_button --wait=1.4 \
  --send='300:\e[<35;41;11M' \
  --send='450:\e[<0;41;11M' \
  --send='550:\e[<0;41;11m' \
  --send='900:\e[<35;60;20M' \
  --expect='uirelays terminal button' \
  --expect='Button toggled ON'

echo "terminal smoke: OK"
