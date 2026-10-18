#!/usr/bin/env python3
"""Point Fanficly's Xcode Cloud workflows at the project in apple/.

Xcode Cloud stores each workflow's project path (containerFilePath) on Apple's
side, so moving the app into apple/ broke every workflow ("Fanficly.xcodeproj
does not exist at the root of the repository"). This lists the workflows and,
with --apply, PATCHes any that still point elsewhere. Without --apply it only
reports. Run by the "Xcode Cloud project path" workflow, no Mac needed.

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
Run:  bin/.venv/bin/python bin/xcode-cloud-project-path.py [--apply]
"""
from __future__ import annotations

import sys

from asc_assets import API, app_id, req

PROJECT = "apple/Fanficly.xcodeproj"


def main() -> None:
    apply = "--apply" in sys.argv[1:]
    product = req("GET", f"{API}/apps/{app_id()}/ciProduct")["data"]
    workflows = req("GET", f"{API}/ciProducts/{product['id']}/workflows",
                    params={"limit": 200})["data"]
    if not workflows:
        sys.exit("No Xcode Cloud workflows found for Fanficly")
    for wf in workflows:
        attrs = wf["attributes"]
        name, path = attrs.get("name"), attrs.get("containerFilePath")
        state = "enabled" if attrs.get("isEnabled") else "disabled"
        if path == PROJECT:
            print(f"OK       {name} ({state}): {path}")
            continue
        if not apply:
            print(f"OUTDATED {name} ({state}): {path} -> would set {PROJECT}")
            continue
        req("PATCH", f"{API}/ciWorkflows/{wf['id']}", json={"data": {
            "type": "ciWorkflows", "id": wf["id"],
            "attributes": {"containerFilePath": PROJECT},
        }})
        print(f"UPDATED  {name} ({state}): {path} -> {PROJECT}")
    if not apply:
        print("Dry run: run again with apply checked to change them.")


if __name__ == "__main__":
    main()
