#!/usr/bin/env bash
# Auto-type for the fabio.crypto vault: types each value with Tab between
# them, then Enter, into the window that was focused when the panel opened.
# A null in seq is an extra Enter (sites that want Enter after each field);
# after it we wait for the next page and check the window again.
# Reads one JSON line on stdin: {"seq": [value | null], "win": address}
# (stdin, not argv: wtype arguments would show up in `ps`).
set -euo pipefail

IFS= read -r req
win=$(jq -r '.win' <<<"$req")

fail() { notify-send -u low -t 5000 "Vault auto-type" "$1"; echo "$1" >&2; exit 1; }

check_window() {
  local active
  active=$(hyprctl activewindow -j)
  [[ -n $win && $(jq -r '.address // ""' <<<"$active") == "$win" ]] ||
    fail "Focus moved to another window, $1."
  # Never type secrets into terminals or chat/agent windows: Enter would send them
  shopt -s nocasematch
  [[ ! $(jq -r '.class // ""' <<<"$active") =~ (foot|kitty|alacritty|ghostty|wezterm|konsole|terminal|org\.omarchy\.agent) ]] ||
    fail "The focused window is a terminal, nothing was typed. Click the login field in your browser first."
}

sleep 0.4 # let focus go back from the panel to the page
check_window "nothing was typed"

n=$(jq '.seq | length' <<<"$req")
((n > 0)) || fail "Nothing to type."
prev=""
for ((i = 0; i < n; i++)); do
  if [[ $(jq --argjson i "$i" '.seq[$i] == null' <<<"$req") == true ]]; then
    wtype -k Return
    sleep 1.5 # the next field is often on a new page
    check_window "stopped halfway"
    prev=enter
  else
    ((i == 0)) || check_window "stopped halfway" # a popup may have stolen focus
    [[ $prev != text ]] || wtype -k Tab
    jq -j --argjson i "$i" '.seq[$i]' <<<"$req" | wtype -d 8 -
    prev=text
  fi
done
wtype -k Return
