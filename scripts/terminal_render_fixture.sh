#!/usr/bin/env bash
# In-app terminal RENDER FIXTURE (W2).
#
# Emits a deterministic escape-sequence pattern so the DEVID in-app terminal's
# "1:1 render" can be verified OBJECTIVELY (not eyeballed): run this inside the
# CLI Pulse in-app terminal AND inside macOS Terminal.app side-by-side — every
# section must look pixel-for-pixel identical (colors, attributes, box-drawing,
# CJK width, cursor addressing, spinner). See docs/DEVID_TERMINAL_SMOKE.md.
#
# Pure ANSI + UTF-8; no dependencies. Safe to run anywhere.
#
# Usage:
#   bash scripts/terminal_render_fixture.sh           # full fixture
#   bash scripts/terminal_render_fixture.sh --no-spin # skip the animated spinner

set -u
ESC=$'\033'
NOSPIN=0
[[ "${1:-}" == "--no-spin" ]] && NOSPIN=1

rule() { printf '%s\n' "── $1 ────────────────────────────────────────────"; }

# 0. OSC 0/2 window title (verifies the app forwards the title to its title bar).
printf '%s]0;CLI Pulse render fixture%s\a' "$ESC" ""

rule "1. 16 ANSI colors (fg then bg)"
for c in $(seq 0 7);  do printf '%s[3%sm  %s  %s[0m' "$ESC" "$c" "$c" "$ESC"; done; printf '\n'
for c in $(seq 0 7);  do printf '%s[9%sm  %s  %s[0m' "$ESC" "$c" "$c" "$ESC"; done; printf '\n'
for c in $(seq 0 7);  do printf '%s[4%sm  %s  %s[0m' "$ESC" "$c" "$c" "$ESC"; done; printf '\n'

rule "2. 256-color ramp (foreground)"
for i in $(seq 16 51); do printf '%s[38;5;%sm█%s[0m' "$ESC" "$i" "$ESC"; done; printf '\n'
for i in $(seq 52 87); do printf '%s[38;5;%sm█%s[0m' "$ESC" "$i" "$ESC"; done; printf '\n'

rule "3. 24-bit truecolor gradient"
for i in $(seq 0 71); do
  r=$(( (i * 255) / 71 )); g=$(( 128 )); b=$(( 255 - (i * 255) / 71 ))
  printf '%s[38;2;%s;%s;%sm█%s[0m' "$ESC" "$r" "$g" "$b" "$ESC"
done; printf '\n'

rule "4. SGR attributes"
printf '%s[1mbold%s[0m  %s[2mdim%s[0m  %s[3mitalic%s[0m  %s[4munderline%s[0m  ' \
  "$ESC" "$ESC" "$ESC" "$ESC" "$ESC" "$ESC" "$ESC" "$ESC"
printf '%s[7mreverse%s[0m  %s[9mstrike%s[0m  %s[5mblink%s[0m\n' \
  "$ESC" "$ESC" "$ESC" "$ESC" "$ESC" "$ESC"

rule "5. Box drawing (single / double / rounded) + blocks"
printf '┌─────────┬─────────┐   ╔═════════╗   ╭─────────╮\n'
printf '│ cell A  │ cell B  │   ║  double ║   │ rounded │\n'
printf '├─────────┼─────────┤   ╚═════════╝   ╰─────────╯\n'
printf '└─────────┴─────────┘   ░▒▓█ shading  ▁▂▃▄▅▆▇█\n'

rule "6. CJK / wide-char width (each | must align in column 13)"
# Wide glyphs MUST occupy 2 cells. If width handling is wrong the trailing |
# columns will be ragged.
printf '%-12s|\n' "ascii123456"
printf '中文宽度测试|\n'
printf '日本語テスト|\n'
printf '한글테스트연|\n'

rule "7. Cursor addressing (absolute positioning)"
# Save cursor, jump around drawing X marks, restore. Renderer must place each
# X exactly; a broken CUP leaves them mispositioned.
printf '%s[s' "$ESC"            # save
printf '%s[1C%s[0;33mX' "$ESC" "$ESC"
printf '%s[3C%s[0;36mX' "$ESC" "$ESC"
printf '%s[3C%s[0;35mX%s[0m' "$ESC" "$ESC" "$ESC"
printf '%s[u' "$ESC"            # restore
printf '            (three X marks above, evenly spaced)\n'

if [[ "$NOSPIN" -eq 0 ]]; then
  rule "8. Spinner (braille) — should animate smoothly then settle"
  frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  for _ in 1 2 3; do
    for ((j=0; j<${#frames}; j++)); do
      printf '\r%s[36m%s%s[0m working…' "$ESC" "${frames:$j:1}" "$ESC"
      sleep 0.05
    done
  done
  printf '\r%s[32m✓%s[0m done.        \n' "$ESC" "$ESC"
fi

rule "9. Done"
printf 'If every section is identical to macOS Terminal.app, render is 1:1.\n'
