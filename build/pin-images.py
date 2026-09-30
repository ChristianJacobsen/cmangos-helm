#!/usr/bin/env python3
"""Pin images.server and images.db in the chart values to a tag and digest.

Edits the tag and digest lines as text: a YAML round trip would drop the
comments that document values.yaml.
"""
import argparse
import pathlib
import re
import sys

VALUES = pathlib.Path(__file__).resolve().parent.parent / "charts" / "cmangos" / "values.yaml"
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def pin(text: str, component: str, tag: str, digest: str) -> str:
    lines = text.splitlines(keepends=True)
    in_images = in_component = False
    done = set()
    for i, line in enumerate(lines):
        if re.match(r"^images:\s*$", line):
            in_images = True
            continue
        if in_images and re.match(r"^\S", line):
            break
        if in_images and re.match(r"^  \S", line) and not line.lstrip().startswith("#"):
            in_component = line.strip() == f"{component}:"
            continue
        if in_component:
            m = re.match(r"^(    )(tag|digest):", line)
            if m:
                value = tag if m.group(2) == "tag" else digest
                lines[i] = f'{m.group(1)}{m.group(2)}: "{value}"\n'
                done.add(m.group(2))
    if done != {"tag", "digest"}:
        sys.exit(f"images.{component}: tag or digest line not found in {VALUES}")
    return "".join(lines)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--tag", required=True)
    p.add_argument("--server-digest", required=True)
    p.add_argument("--db-digest", required=True)
    p.add_argument("--values", type=pathlib.Path, default=VALUES)
    args = p.parse_args()
    for d in (args.server_digest, args.db_digest):
        if not DIGEST.match(d):
            sys.exit(f"not a sha256 digest: {d}")
    text = args.values.read_text()
    text = pin(text, "server", args.tag, args.server_digest)
    text = pin(text, "db", args.tag, args.db_digest)
    args.values.write_text(text)
    print(f"pinned images to {args.tag}")


if __name__ == "__main__":
    main()
