#!/usr/bin/env python3
"""Encrypted password vault backend for the fabio.crypto bar plugin.

Reads one JSON request line on stdin (secrets never go through argv or env)
and prints one JSON object on stdout. On failure it prints {"error": ...}
and exits 1.

Every request except status may carry "vault": name (default "vault");
each vault is its own file, <name>.enc, with its own master password.

Requests:
  {"op": "status"}                          -> {"vaults": [names]}
  {"op": "delete", "key": hex | "sudo": password, "confirm": name} -> {"ok": true}
      (with sudo instead of key it deletes a locked vault, e.g. a forgotten password)
  {"op": "create", "password": str}         -> {"key": hex, "entries": [], "usernames": [], "emails": []}
  {"op": "unlock", "password": str}         -> {"key": hex, "entries", "usernames", "emails"}
  {"op": "save", "key": hex, "entries": [], "usernames": [], "emails": []} -> {"ok": true}
  {"op": "rekey", "key": hex, "password": str} -> {"key": hex}

File format (JSON): {"v", "kdf": {alg, t, m, p, salt}, "nonce", "ct"}.
The master password goes through Argon2id (1 GiB, 4 passes) to a 256-bit
key; the entries are sealed with AES-256-GCM, with the header as associated
data so the KDF parameters can't be tampered with. Each save uses a fresh
nonce. Writes are atomic (temp file + fsync + rename) and the previous
version is kept as vault.enc.bak (dropped on a master password change).
"""
import base64
import fcntl
import json
import os
import re
import subprocess
import sys

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id

DATA_DIR = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "fabio.crypto")
VAULT = None  # path of the vault this request is about, set in handle()
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _-]{0,31}")
KDF_DEFAULTS = {"alg": "argon2id", "t": 4, "m": 1048576, "p": 4}  # m in KiB
MIN_PASSWORD = 12


class VaultError(Exception):
    pass


def b64e(b):
    return base64.b64encode(b).decode()


def b64d(s):
    return base64.b64decode(s, validate=True)


def derive(password, kdf):
    if kdf.get("alg") != "argon2id":
        raise VaultError("Unsupported KDF")
    # bound what a tampered header can make us allocate or spin on
    if not (8192 <= kdf["m"] <= 4194304 and 1 <= kdf["t"] <= 16 and 1 <= kdf["p"] <= 16):
        raise VaultError("Vault file has unsafe KDF parameters")
    return Argon2id(salt=b64d(kdf["salt"]), length=32, iterations=kdf["t"],
                    lanes=kdf["p"], memory_cost=kdf["m"]).derive(password.encode())


def aad(header):
    return json.dumps({"v": header["v"], "kdf": header["kdf"]}, sort_keys=True, separators=(",", ":")).encode()


def read_header():
    try:
        with open(VAULT) as f:
            header = json.load(f)
    except FileNotFoundError:
        raise VaultError("No vault yet")
    except ValueError:
        raise VaultError("Vault file is corrupt")
    if header.get("v") != 1:
        raise VaultError("Unknown vault version")
    return header


def decrypt(header, key):
    try:
        plain = AESGCM(key).decrypt(b64d(header["nonce"]), b64d(header["ct"]), aad(header))
    except InvalidTag:
        raise VaultError("Wrong master password")
    data = json.loads(plain)
    data.setdefault("usernames", [])
    data.setdefault("emails", [])
    return data


def write(kdf, key, data, backup=True):
    header = {"v": 1, "kdf": kdf}
    nonce = os.urandom(12)
    plain = json.dumps(data, separators=(",", ":")).encode()
    header["nonce"] = b64e(nonce)
    header["ct"] = b64e(AESGCM(key).encrypt(nonce, plain, aad(header)))

    tmp = VAULT + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(header, f)
        f.flush()
        os.fsync(f.fileno())
    if backup and os.path.exists(VAULT):
        os.replace(VAULT, VAULT + ".bak")
    os.replace(tmp, VAULT)
    if not backup and os.path.exists(VAULT + ".bak"):
        os.remove(VAULT + ".bak")  # it still opens with the old password
    dfd = os.open(DATA_DIR, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def check_password(pw):
    if not isinstance(pw, str) or len(pw) < MIN_PASSWORD:
        raise VaultError(f"Master password needs at least {MIN_PASSWORD} characters")


def key_from(req):
    try:
        key = bytes.fromhex(req.get("key", ""))
    except ValueError:
        key = b""
    if len(key) != 32:
        raise VaultError("Vault is locked")
    return key


def check_data(req):
    entries = req.get("entries")
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        raise VaultError("Bad entries")
    data = {"entries": entries}
    for kind in ("usernames", "emails"):  # presets for new logins
        data[kind] = req.get(kind, [])
        if not isinstance(data[kind], list) or not all(isinstance(u, str) for u in data[kind]):
            raise VaultError("Bad " + kind)
    return data


def check_sudo(password):
    if password == "":
        raise VaultError("Enter your sudo password")  # don't burn a sudo try
    # -k: never reuse a cached sudo login; -S: password from stdin, not argv
    try:
        ok = subprocess.run(["sudo", "-k", "-S", "-p", "", "true"], input=password + "\n", text=True,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20).returncode == 0
    except subprocess.TimeoutExpired:
        ok = False
    if not ok:
        raise VaultError("Wrong sudo password (too many tries locks sudo for a while)")


def list_vaults():
    try:
        return sorted((f[:-4] for f in os.listdir(DATA_DIR) if f.endswith(".enc") and NAME_RE.fullmatch(f[:-4])), key=str.lower)
    except FileNotFoundError:
        return []


def handle(req):
    global VAULT
    op = req.get("op")
    if op == "status":
        return {"vaults": list_vaults()}

    name = req.get("vault", "vault")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise VaultError("Vault names: letters, digits, space, _ and -, up to 32 characters")
    VAULT = os.path.join(DATA_DIR, name + ".enc")

    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    os.chmod(DATA_DIR, 0o700)
    lock = os.open(os.path.join(DATA_DIR, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX)

    if op == "create":
        if os.path.exists(VAULT):
            raise VaultError("A vault already exists")
        check_password(req.get("password"))
        kdf = dict(KDF_DEFAULTS, salt=b64e(os.urandom(16)))
        key = derive(req["password"], kdf)
        empty = {"entries": [], "usernames": [], "emails": []}
        write(kdf, key, empty)
        return dict(empty, key=key.hex())

    if op == "unlock":
        header = read_header()
        key = derive(str(req.get("password", "")), header["kdf"])
        return dict(decrypt(header, key), key=key.hex())

    if op == "save":
        header = read_header()
        key = key_from(req)
        decrypt(header, key)  # refuse to overwrite the vault with a wrong key
        write(header["kdf"], key, check_data(req))
        return {"ok": True}

    if op == "delete":
        header = read_header()
        if req.get("confirm") != name:
            raise VaultError("Type the vault name to confirm")
        if "key" in req:
            decrypt(header, key_from(req))  # an open vault: make sure it's this one
        else:
            # A locked vault (forgotten password) needs the sudo password
            check_sudo(str(req.get("sudo", "")))
        for path in (VAULT, VAULT + ".bak"):
            if os.path.exists(path):
                os.remove(path)
        return {"ok": True}

    if op == "rekey":
        header = read_header()
        data = decrypt(header, key_from(req))
        check_password(req.get("password"))
        kdf = dict(KDF_DEFAULTS, salt=b64e(os.urandom(16)))
        key = derive(req["password"], kdf)
        write(kdf, key, data, backup=False)
        return {"key": key.hex()}

    raise VaultError("Unknown op")


def main():
    os.umask(0o077)
    try:
        req = json.loads(sys.stdin.readline() or "{}")
        if not isinstance(req, dict):
            raise VaultError("Bad request")
        out = handle(req)
    except VaultError as e:
        print(json.dumps({"error": str(e)}))
        return 1
    except Exception as e:  # never leak a traceback with secrets in locals
        print(json.dumps({"error": f"{type(e).__name__}: vault operation failed"}))
        return 1
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
