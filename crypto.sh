#!/usr/bin/env bash
# Backend for the fabio.crypto bar plugin.
# Usage: crypto.sh <hash|password|keys|uuid|ssh>
# Hash mode reads its input from $CRYPTO_INPUT (env, not argv, so it
# doesn't show up in `ps`). Prints a JSON array of {label, value, secret}.
set -euo pipefail

# The value goes through env, not argv: jq's arguments would show secrets in `ps`
emit() { V=$2 jq -nc --arg l "$1" --argjson s "${3:-false}" '{label:$l,value:$ENV.V,secret:$s}'; }
digest() { printf %s "$CRYPTO_INPUT" | openssl dgst "-$1" -r | cut -d' ' -f1; }

# n random chars from a tr set; tr gets SIGPIPE when head closes, so
# pipefail is off inside the subshell and the length is checked instead.
rand_chars() {
  local out
  out=$(set +o pipefail; LC_ALL=C tr -dc "$1" </dev/urandom | head -c "$2")
  [[ ${#out} -eq $2 ]] || { echo "random generator failed" >&2; exit 1; }
  printf %s "$out"
}

b64url() { openssl rand -base64 "$1" | tr -d '\n=' | tr '+/' '-_'; }

hash_mode() {
  [[ -n ${CRYPTO_INPUT:-} ]] || return 0
  emit "MD5" "$(digest md5)"
  emit "SHA-1" "$(digest sha1)"
  emit "SHA-256" "$(digest sha256)"
  emit "SHA-512" "$(digest sha512)"
  emit "SHA3-256" "$(digest sha3-256)"
  emit "BLAKE2b-512" "$(digest blake2b512)"
  emit "Base64" "$(printf %s "$CRYPTO_INPUT" | base64 -w0)"
  emit "Hex" "$(printf %s "$CRYPTO_INPUT" | od -An -tx1 -v | tr -d ' \n')"
  emit "URL-encoded" "$(printf %s "$CRYPTO_INPUT" | jq -sRr @uri)"
  emit "ROT13" "$(printf %s "$CRYPTO_INPUT" | tr 'A-Za-z' 'N-ZA-Mn-za-m')"
  emit "bcrypt (password hash)" "$(printf %s "$CRYPTO_INPUT" | mkpasswd -m bcrypt -R 12 -s)" true
  emit "SHA-512 crypt (/etc/shadow)" "$(printf %s "$CRYPTO_INPUT" | mkpasswd -m sha512crypt -s)" true
}

password_mode() {
  emit "Strong password (24)" "$(rand_chars 'A-Za-z0-9!@#%^&*_+=?-' 24)" true
  emit "Alphanumeric (16)" "$(rand_chars 'A-Za-z0-9' 16)" true
  local words
  words=$(grep -xE '[a-z]{4,8}' /usr/share/dict/cracklib-small | shuf -n 6 --random-source=/dev/urandom | paste -sd-)
  emit "Passphrase (6 words)" "$words" true
  emit "PIN (6 digits)" "$(rand_chars '0-9' 6)" true
}

keys_mode() {
  emit "AES-256 key (hex)" "$(openssl rand -hex 32)" true
  emit "256-bit key (base64)" "$(openssl rand -base64 32)" true
  emit "JWT / HMAC secret (base64url, 512-bit)" "$(b64url 64)" true
  emit "API token" "tok_$(rand_chars 'A-Za-z0-9' 40)" true
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  # WireGuard keys are raw X25519 keys: the last 32 bytes of the DER encoding
  openssl genpkey -algorithm X25519 -out "$tmp/wg.pem"
  emit "WireGuard private key" "$(openssl pkey -in "$tmp/wg.pem" -outform DER | tail -c 32 | base64)" true
  emit "WireGuard public key" "$(openssl pkey -in "$tmp/wg.pem" -pubout -outform DER | tail -c 32 | base64)"
}

uuid_mode() {
  emit "UUID v4 (random)" "$(uuidgen -r)"
  emit "UUID v7 (time-ordered)" "$(uuidgen -7)"
  emit "Nano ID" "$(rand_chars 'A-Za-z0-9_-' 21)"
  emit "128-bit hex ID" "$(openssl rand -hex 16)"
}

ssh_mode() {
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C "$USER@$(uname -n)" -f "$tmp/id_ed25519"
  emit "Public key (id_ed25519.pub)" "$(cat "$tmp/id_ed25519.pub")"
  emit "Private key (id_ed25519)" "$(cat "$tmp/id_ed25519")" true
  emit "Fingerprint" "$(ssh-keygen -lf "$tmp/id_ed25519.pub" | cut -d' ' -f2)"
}

case ${1:-} in
  hash) hash_mode ;;
  password) password_mode ;;
  keys) keys_mode ;;
  uuid) uuid_mode ;;
  ssh) ssh_mode ;;
  *) echo "usage: $0 <hash|password|keys|uuid|ssh>" >&2; exit 2 ;;
esac | jq -sc .
