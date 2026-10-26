#!/usr/bin/env python3
"""The App Store screenshots, captured in Xcode Cloud.

The screenshots show the app as it ships, so they're captured with the same
newest Xcode 27 or later as every build (xcode_cloud.py says why), which
GitHub's macOS runners don't have yet; the iPhone Duo set needs it anyway. The
"Store art" workflow runs ScreenshotTests (the FanficlyScreenshots scheme) on
the iPhone, iPad and iPhone Duo simulators the store slots are sized for. The
iPad run also captures the "Mac" set (a landscape iPad split view, as
locally). Each shot is a result-bundle attachment named <folder>__<name>,
which store-assets.yml exports and `place` puts where the local capture would
have written it, docs/screenshots/<folder>/<name>.png, for
bin/frame-screenshots.py to frame. The Duo captures the display it boots on
(the pose can't be scripted); frame-screenshots.py keeps the committed
captures for the other.

  setup                 makes or updates the workflow
  run BRANCH OUT        setup, start it on BRANCH, wait, and download its
                        result bundles to OUT
  place ATTACHMENTS     copy exported attachments (xcresulttool export
                        attachments output folders, anywhere under
                        ATTACHMENTS, each named for its result bundle so
                        its device is known) into docs/screenshots/

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
Run:  bin/.venv/bin/python bin/xcode-cloud-store-art.py setup|run|place ...
"""
from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

import xcode_cloud as xcc

NAME = "Store art"
SCHEME = "FanficlyScreenshots"
# The Fastfile's IPHONE_SIM, IPAD_SIM and DUO_SIM: the App Store slot sizes.
DEVICES = [(["iPhone 17 Pro Max"], "iPhone"), (["iPad Pro 13-inch (M5)"], "iPad"), (["iPhone Duo"], "iPhone Duo")]
FOLDERS = {"iphone", "ipad", "mac", "duo-inner", "duo-outer"}
# The folders each device's captures may fill, by the device name in the
# result bundle's name ("... on iPhone Duo (iOS 27.1)"), Duo first since
# "iPhone" matches it too. A Duo that mistook itself for an iPhone would
# otherwise overwrite the iPhone set with its own shots.
DEVICE_FOLDERS = [("iPhone Duo", {"duo-inner", "duo-outer"}), ("iPad", {"ipad", "mac"}), ("iPhone", {"iphone"})]
SHOTS = Path(__file__).resolve().parent.parent / "docs" / "screenshots"


def setup() -> tuple[dict, dict]:
    xc, mac = xcc.latest_xcode()
    return xcc.upsert_workflow({
        "name": NAME,
        "description": "The App Store screenshots (ScreenshotTests) on the newest Xcode 27+. Started "
                       "only by store-assets.yml in GitHub, which keeps this workflow up to date.",
        "clean": False,
        "manualBranchStartCondition": {"source": {"isAllMatch": True}},
        # One action per device, so each runs and reports on its own and
        # leaves its own result bundle: with all three in one action, the
        # iPad and Duo runs errored after 100 minutes without one.
        "actions": [{
            "name": f"Capture on {kind}",
            "actionType": "TEST",
            "scheme": SCHEME,
            "platform": "IOS",
            "isRequiredToPass": True,
            "testConfiguration": {
                "kind": "USE_SCHEME_SETTINGS",
                "testDestinations": [xcc.simulator(xc, names, kind)],
            },
        } for names, kind in DEVICES],
    }, xc, mac)


def run(branch: str, out: Path) -> None:
    wf, repo = setup()
    r = xcc.start(wf, repo, branch)
    attrs = xcc.wait(r, 150)
    print(f"==> {attrs.get('completionStatus')}")
    # A failed device still leaves the others' screens; place reports what's missing.
    xcc.download_results(r["id"], out, logs=True)
    sha, expected = (attrs.get("sourceCommit") or {}).get("commitSha"), os.environ.get("EXPECTED_SHA")
    if expected and sha and sha != expected:
        sys.exit(f"Xcode Cloud captured {sha[:7]}, not {expected[:7]}")


def place(attachments: Path) -> None:
    """Copies each <folder>__<name> attachment to docs/screenshots/<folder>/<name>.png."""
    placed: dict[str, list[str]] = {}
    for manifest in sorted(attachments.rglob("manifest.json")):
        # Each bundle is exported to a folder named for it (store-assets.yml).
        # One without a device in its name (the per-action merge, whose
        # name is the same for every device) is the same shots again.
        bundle = manifest.parent.name
        allowed = next((f for d, f in DEVICE_FOLDERS if f" on {d}" in bundle), None)
        if allowed is None:
            print(f"    skipping {bundle}: no device in its name")
            continue
        for test in json.loads(manifest.read_text()):
            for att in test.get("attachments", []):
                # "iphone__01-home_0_<UUID>.png": the names themselves have no "_".
                human = Path(att.get("suggestedHumanReadableName", "")).stem
                folder, sep, rest = human.partition("__")
                if not sep or folder not in FOLDERS:
                    continue
                if folder not in allowed:
                    print(f"::warning::{bundle} captured {human!r}, not one of its own folders: skipped")
                    continue
                name = rest.split("_")[0]
                dest = SHOTS / folder / f"{name}.png"
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(manifest.parent / att["exportedFileName"], dest)
                placed.setdefault(folder, []).append(name)
    for folder, names in sorted(placed.items()):
        print(f"==> docs/screenshots/{folder}: {', '.join(sorted(set(names)))}")
    # A device that didn't finish keeps its committed captures, which
    # frame-screenshots.py frames as before; only no captures at all fails.
    if not placed:
        sys.exit("No captures in the result bundles")
    for folder in sorted({"iphone", "ipad", "mac"} - placed.keys()):
        print(f"::warning::No {folder} captures: the committed ones stay")
    if not placed.keys() & {"duo-inner", "duo-outer"}:
        print("::warning::No iPhone Duo captures: the committed ones stay")


def main() -> None:
    match sys.argv[1:]:
        case ["setup"]:
            setup()
        case ["run", branch, out]:
            run(branch, Path(out))
        case ["place", attachments]:
            place(Path(attachments))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
