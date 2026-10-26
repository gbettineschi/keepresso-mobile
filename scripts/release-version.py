#!/usr/bin/env python3
"""Map a numeric release tag to the shared display version and Android versionCode."""
import re
import sys


def release_version(tag):
    match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    if not match:
        raise ValueError("Expected vX.Y.Z with no leading zeroes.")
    major, minor, patch = map(int, match.groups())
    code = major * 1_000_000 + minor * 1_000 + patch
    if minor > 999 or patch > 999 or not 0 < code <= 2_100_000_000:
        raise ValueError("Version does not fit the Android release version-code scheme.")
    return tag[1:], code


if __name__ == "__main__":
    ver, code = release_version(sys.argv[1])
    print(f"version={ver}\nversion_code={code}")
