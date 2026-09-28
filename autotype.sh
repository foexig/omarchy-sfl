#!/usr/bin/env bash
# Auto-type for the fabio.crypto vault: types username, Tab, password, Enter
# into the window that was focused when the panel opened.
# Reads one JSON line on stdin: {"u": user, "p": password, "win": address}
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

user=$(jq -r '.u' <<<"$req")
if [[ -n $user ]]; then
  printf %s "$user" | wtype -d 8 -
  wtype -k Tab
fi
jq -j '.p' <<<"$req" | wtype -d 8 -
wtype -k Return
