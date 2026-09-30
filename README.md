# SFL: Secure Fast Login v1.0 for Omarchy

**SFL** is an encrypted password vault for the Omarchy shell bar, plus quick generators
for hashes, passwords, keys, UUIDs and SSH keypairs. Click any value to copy it.

## Features

- **Password vault** — several vaults, each with its own master password.
  Search, edit, and auto-type logins into the window you came from.
- **Generators** — strong passwords, passphrases, PINs, AES/HMAC keys,
  WireGuard keypairs, API tokens, UUID v4/v7, Nano IDs, ed25519 SSH keypairs.
- **Hashes** — MD5, SHA-1/256/512, SHA3, BLAKE2b, bcrypt, sha512crypt,
  Base64, hex, URL-encoding, ROT13.

## Install

```bash
omarchy plugin add https://github.com/foexig/omarchy-sfl.git --enable
```

Dependencies (Arch): `sudo pacman -S --needed python-cryptography jq wl-clipboard wtype openssl whois cracklib`

## Security design

- Master password → **Argon2id** (1 GiB, 4 passes) → 256-bit key; entries sealed
  with **AES-256-GCM**, fresh nonce per save, header authenticated so KDF
  parameters can't be tampered with (and are bounds-checked).
- Vaults live in `~/.local/share/fabio.crypto/` (dir `700`, files `600`),
  written atomically; the master password is never stored, only the derived
  key is held while unlocked.
- Secrets travel over stdin or env, never argv, so they don't show in `ps`.
- Copied secrets use `wl-copy --sensitive` (kept out of clipboard history) and
  are cleared after 30 s. The vault auto-locks after 5 idle minutes.
- Auto-type refuses terminals and agent windows, and stops if focus moves.

Your vault is only as strong as your master password: use 5–6 random words.

## License

MIT
