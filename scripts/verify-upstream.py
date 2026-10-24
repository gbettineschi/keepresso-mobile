#!/usr/bin/env python3
"""Check the pinned upstream tree without importing or executing its code."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


def main() -> int:
    repository = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path,
                        default=repository / "macos/ThirdParty/KeepressoCore/Sources")
    args = parser.parse_args()
    manifest = json.loads((repository / "shared/upstream.json").read_text())
    expected = manifest["sources_sha256"]
    source = args.source_root.resolve()
    failures = []
    for relative, digest in expected.items():
        name = Path(relative)
        if name.is_absolute() or ".." in name.parts:
            failures.append(f"Invalid manifest path: {relative}")
            continue
        path = source / name
        if path.is_symlink() or not path.is_file():
            failures.append(f"Missing file or symbolic link: {relative}")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            failures.append(f"Changed upstream file: {relative}")
    actual = {str(path.relative_to(source)) for path in source.rglob("*")
              if path.is_file() or path.is_symlink()}
    failures.extend(f"Unrecorded upstream file: {relative}"
                    for relative in sorted(actual - expected.keys()))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Verified {len(expected)} unchanged upstream files: "
          f"{manifest['tag']} ({manifest['commit']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
