#!/usr/bin/env python3
"""The Apple app's CI, in Xcode Cloud.

Every Apple build runs on the newest Xcode 27 or later (xcode_cloud.py says
why), and GitHub's macOS runners don't have it yet, so the tests GitHub CI
used to run (ci.yml) run in Xcode Cloud's "CI" workflow instead. Xcode Cloud
has 100 compute hours a month, so it starts only for pull requests into main
that change what gets built (APP_FILES: the app's code, tests, project and
ci_scripts, not docs, screenshots, store text or the release tooling), never
again for the merge to main, and cancels a run a newer push supersedes. Xcode
Cloud reports each action on the pull request as a check:

  Unit tests (iPhone)         FanficlyTests on the newest iPhone simulator
  Unit tests (Mac)            FanficlyTests under Mac Catalyst
  UI tests (iPhone, iPad)     ReaderLayoutTests and NonReaderAccessibilityTests

The unit tests are logic, not layout, so one simulator covers them; the UI
tests keep the iPhone and the iPad, whose layouts differ.

The iPhone Duo's ReaderLayoutTests stay in their own "Duo tests" workflow
(bin/xcode-cloud-duo.py, xcode-cloud-duo.yml), which also exports their
screenshots.

  setup    makes or updates the workflow (the newest Xcode 27+, the start
           conditions, the actions)
  others   turns off the automatic starts of every Xcode Cloud workflow not
           kept in code (one made by hand in App Store Connect), so only the
           ones here spend compute hours; they can still be started by hand

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
Run:  bin/.venv/bin/python bin/xcode-cloud-ci.py setup|others
"""
from __future__ import annotations

import sys

import xcode_cloud as xcc
from asc_assets import API, req

NAME = "CI"
IPHONE = ["iPhone 17 Pro Max"]
IPAD = ["iPad Pro 13-inch (M5)"]
# What a build depends on. Everything else in apple/ (docs/, screenshots/,
# appstore/, fastlane/, bin/, the Markdown) can't change a test result.
APP_FILES = {"mode": "START_IF_ANY_FILE_MATCHES", "matchers": [
    *({"directory": f"apple/{d}"} for d in ("Fanficly", "FanficlyShare", "FanficlyWidget", "FanficlyTests",
                                             "FanficlyUITests", "Fanficly.xcodeproj", "ci_scripts")),
    {"directory": "apple", "fileName": "project.yml"},
    {"directory": "apple", "fileName": "Signing.xcconfig"},
]}
# The workflows kept in code: this one, bin/xcode-cloud-release.py's two,
# bin/xcode-cloud-store-art.py's and bin/xcode-cloud-duo.py's.
MANAGED = {NAME, "Release (iOS)", "Release (Mac)", "Store art", "Duo tests"}
AUTO_STARTS = ("branchStartCondition", "pullRequestStartCondition", "tagStartCondition", "scheduledStartCondition")


def setup() -> None:
    xc, mac = xcc.latest_xcode()
    iphone, ipad = xcc.simulator(xc, IPHONE, "iPhone"), xcc.simulator(xc, IPAD, "iPad")
    main_only = {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]}
    xcc.upsert_workflow({
        "name": NAME,
        "description": "Unit and UI tests on the newest Xcode 27+, for pull requests into main that "
                       "change the app's code. Kept up to date by xcode-cloud-setup.yml in GitHub.",
        "clean": False,
        "pullRequestStartCondition": {
            "source": {"isAllMatch": True},
            "destination": main_only,
            "filesAndFoldersRule": APP_FILES,
            "autoCancel": True,
        },
        # The PR already ran it; the merge to main doesn't run it again.
        "branchStartCondition": None,
        "manualBranchStartCondition": {"source": {"isAllMatch": True}},
        "actions": [
            {
                "name": "Unit tests (iPhone)",
                "actionType": "TEST",
                "scheme": "FanficlyUnitTests",
                "platform": "IOS",
                "isRequiredToPass": True,
                "testConfiguration": {"kind": "USE_SCHEME_SETTINGS", "testDestinations": [iphone]},
            },
            {
                "name": "Unit tests (Mac)",
                "actionType": "TEST",
                "scheme": "FanficlyUnitTests",
                "platform": "MACOS",
                "destination": "ANY_MAC_CATALYST",
                "isRequiredToPass": True,
                "testConfiguration": {"kind": "USE_SCHEME_SETTINGS",
                                      "testDestinations": [xcc.mac_destination(xc)]},
            },
            {
                "name": "UI tests (iPhone, iPad)",
                "actionType": "TEST",
                "scheme": "FanficlyCIUITests",
                "platform": "IOS",
                "isRequiredToPass": True,
                "testConfiguration": {"kind": "USE_SCHEME_SETTINGS", "testDestinations": [iphone, ipad]},
            },
        ],
    }, xc, mac)


def others() -> None:
    """Leaves each workflow not in MANAGED startable by hand only."""
    _, workflows = xcc.product_and_workflows()
    for wf in workflows:
        a = wf["attributes"]
        name, auto = a.get("name"), [k for k in AUTO_STARTS if a.get(k)]
        if name in MANAGED or not a.get("isEnabled") or not auto:
            print(f"OK       {name}: {'kept in code' if name in MANAGED else 'no automatic starts'}")
            continue
        attributes = dict.fromkeys(auto) | {
            "manualBranchStartCondition": a.get("manualBranchStartCondition") or {"source": {"isAllMatch": True}}}
        req("PATCH", f"{API}/ciWorkflows/{wf['id']}", json={"data": {
            "type": "ciWorkflows", "id": wf["id"], "attributes": attributes}})
        print(f"MANUAL   {name}: removed {', '.join(auto)}; start it by hand in App Store Connect")


def main() -> None:
    match sys.argv[1:]:
        case ["setup"]:
            setup()
        case ["others"]:
            others()
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
