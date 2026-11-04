#!/usr/bin/env python3
"""Prints the UDID of an available simulator for GitHub CI (ci.yml).

  ci-simulator.py iPhone      the newest iOS runtime's iPhone, never the Duo
  ci-simulator.py iPad        the newest iOS runtime's iPad
  ci-simulator.py "iPhone Duo"

Picks by kind, not by exact name, so a runner image that renames its newest
iPhone or iPad doesn't break CI. Within the newest runtime that has the kind,
a "Pro Max" or "Pro 13-inch" (the store-art sizes) wins when there is one.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys

PREFERRED = ("Pro Max", "Pro 13-inch")


def version(runtime: str) -> tuple[int, ...]:
    return tuple(int(n) for n in re.findall(r"\d+", runtime.rsplit(".", 1)[-1]))


def matches(kind: str, name: str) -> bool:
    if kind == "iPhone Duo":
        return name == "iPhone Duo"
    return name.startswith(kind) and "Duo" not in name


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    kind = sys.argv[1]
    out = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                         check=True, capture_output=True, text=True).stdout
    devices = json.loads(out)["devices"]
    for runtime in sorted((r for r in devices if ".iOS-" in r), key=version, reverse=True):
        found = [d for d in devices[runtime] if matches(kind, d["name"])]
        if found:
            best = next((d for p in PREFERRED for d in found if p in d["name"]), found[0])
            print(f"{best['name']} on {runtime.rsplit('.', 1)[-1]}: {best['udid']}", file=sys.stderr)
            print(best["udid"])
            return
    sys.exit(f"No {kind} simulator on this runner")


if __name__ == "__main__":
    main()
