#!/bin/sh
# Compile-check the terminal driver (headless, no codegen).
# Usage: ./build_terminal.sh
set -e
cd "$(dirname "$0")"
nim c --noMain --path:src --hints:off -c src/uirelays/drivers/terminal_driver.nim
