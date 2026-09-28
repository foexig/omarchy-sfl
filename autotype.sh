#!/usr/bin/env bash
# Auto-type for the fabio.crypto vault: types each value with Tab between
# them, then Enter, into the window that was focused when the panel opened.
# Reads one JSON line on stdin: {"seq": [values], "win": address}
# (stdin, not argv: wtype arguments would show up in `ps`).
set -euo pipefail

IFS= read -r req
win=$(jq -r '.win' <<<"$req")

fail() { notify-send -u critical "Vault auto-type" "$1"; echo "$1" >&2; exit 1; }

sleep 0.4 # let focus go back from the panel to the page
active=$(hyprctl activewindow -j)
[[ -n $win && $(jq -r '.address // ""' <<<"$active") == "$win" ]] ||
  fail "Focus moved to another window, nothing was typed."
# Never type secrets into terminals or chat/agent windows: Enter would send them
shopt -s nocasematch
[[ ! $(jq -r '.class // ""' <<<"$active") =~ (foot|kitty|alacritty|ghostty|wezterm|konsole|terminal|org\.omarchy\.agent) ]] ||
  fail "The focused window is a terminal, nothing was typed. Click the login field in your browser first."

n=$(jq '.seq | length' <<<"$req")
((n > 0)) || fail "Nothing to type."
for ((i = 0; i < n; i++)); do
  ((i == 0)) || wtype -k Tab
  jq -j --argjson i "$i" '.seq[$i]' <<<"$req" | wtype -d 8 -
done
wtype -k Return
