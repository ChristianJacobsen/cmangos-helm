#!/usr/bin/env python3
"""Print SQL that creates CMaNGOS realmd accounts from environment variables.

Input: ACCOUNT_<n>_USERNAME, ACCOUNT_<n>_PASSWORD and ACCOUNT_<n>_GMLEVEL for
n = 0, 1, 2, ... (the first missing username ends the list).

The script creates an account only when the username does not exist. It
always sets the GM level. It never changes the password of an account that
exists, because players can change their passwords in the game.

The verifier follows AccountMgr::CreateAccount and SRP6::CalculateVerifier in
the core. --self-test checks it against the default accounts in
sql/base/realmd.sql.
"""
import hashlib
import os
import re
import secrets
import sys

# From src/shared/Auth/SRP6.cpp.
N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
G = 7
SALT_BYTES = 32
# MAX_ACCOUNT_STR in the core, for names and passwords. Names must also be
# plain SQL-safe text.
MAX_ACCOUNT_STR = 16
USERNAME_RE = re.compile(rf"^[A-Z0-9_-]{{1,{MAX_ACCOUNT_STR}}}$")
MAX_GMLEVEL = 3                     # SEC_ADMINISTRATOR


def verifier(username: str, password: str, salt_hex: str) -> str:
    """Return the verifier (upper-case hex) for an upper-cased user and password."""
    digest = hashlib.sha1(f"{username}:{password}".encode("utf-8")).digest()
    # The core hashes the salt as a little-endian byte array, and reads the
    # result as a little-endian number.
    salt_le = bytes.fromhex(salt_hex)[::-1]
    x = int.from_bytes(hashlib.sha1(salt_le + digest).digest(), "little")
    return format(pow(G, x, N), "X")


def new_salt() -> str:
    # A leading zero byte would not survive the core's hex round trip.
    while True:
        salt = secrets.token_bytes(SALT_BYTES)
        if salt[0] != 0:
            return salt.hex().upper()


def self_test() -> None:
    vectors = [
        ("ADMINISTRATOR",
         "312B99EEF1C0196BB73B79D114CE161C5D089319E6EF54FAA6117DAB8B672C14",
         "8EB5DE915AA3D805FA7099CF61C0BB8A77990EA869078A0C5B9EEE55828F4505"),
        ("PLAYER",
         "3738EC7E7C731FD431C716990C6D97CA5C1D50EF0DA7DE9819076DE1D03AA891",
         "EBA23AF194D89B8061CA7FEBA06D336B1C38D8FBDABA76F2C51D45141362D881"),
    ]
    for user, v, s in vectors:
        if verifier(user, user, s) != v:
            sys.exit(f"self-test failed for {user}")
    print("srp6 self-test passed", file=sys.stderr)


def main() -> None:
    if "--self-test" in sys.argv:
        self_test()
        return

    n = 0
    while True:
        prefix = f"ACCOUNT_{n}_"
        username = os.environ.get(prefix + "USERNAME", "")
        if not username:
            break
        password = os.environ.get(prefix + "PASSWORD", "")
        gmlevel = os.environ.get(prefix + "GMLEVEL", "0") or "0"

        # AccountMgr::normalizeString upper-cases both values.
        username = username.upper()
        password = password.upper()
        if not USERNAME_RE.match(username):
            sys.exit(f"account {n}: username must match {USERNAME_RE.pattern}")
        if not password:
            sys.exit(f"account {n} ({username}): empty password")
        if len(password) > MAX_ACCOUNT_STR:
            sys.exit(f"account {n} ({username}): password longer than {MAX_ACCOUNT_STR} characters")
        if not gmlevel.isdigit() or int(gmlevel) > MAX_GMLEVEL:
            sys.exit(f"account {n} ({username}): gmlevel must be 0-{MAX_GMLEVEL}")

        salt = new_salt()
        v = verifier(username, password, salt)
        print(
            "INSERT INTO account (username, gmlevel, v, s, joindate) "
            f"SELECT '{username}', {int(gmlevel)}, '{v}', '{salt}', NOW() FROM DUAL "
            f"WHERE NOT EXISTS (SELECT 1 FROM account WHERE username = '{username}');"
        )
        print(f"UPDATE account SET gmlevel = {int(gmlevel)} WHERE username = '{username}';")
        print(f"account {username}: gmlevel {gmlevel}", file=sys.stderr)
        n += 1


if __name__ == "__main__":
    main()
