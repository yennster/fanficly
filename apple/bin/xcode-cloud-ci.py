#!/usr/bin/env python3
"""The Apple app's CI, in Xcode Cloud, started by hand only.

The tests run on every pull request in GitHub's ci.yml, on its "xcode-27"
runner (Xcode 27, free for this public repo). Xcode Cloud has 100 compute
hours a month, kept for the release archives and the store art, so this "CI"
workflow never starts on its own: no pull request, branch, tag or schedule
start conditions. It stays as a fallback for when GitHub's runner can't run
the tests: start it on a branch with Start Build in App Store Connect (Xcode
Cloud > CI). Its actions, reported on that build:

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
# The workflows kept in code: this one, bin/xcode-cloud-release.py's two,
# bin/xcode-cloud-store-art.py's and bin/xcode-cloud-duo.py's.
MANAGED = {NAME, "Release (iOS)", "Release (Mac)", "Store art", "Duo tests"}
AUTO_STARTS = ("branchStartCondition", "pullRequestStartCondition", "tagStartCondition", "scheduledStartCondition")


def setup() -> None:
    xc, mac = xcc.latest_xcode()
    iphone, ipad = xcc.simulator(xc, IPHONE, "iPhone"), xcc.simulator(xc, IPAD, "iPad")
    xcc.upsert_workflow({
        "name": NAME,
        "description": "Unit and UI tests on the newest Xcode 27+, started by hand only (GitHub's ci.yml "
                       "runs them on every PR). Kept up to date by xcode-cloud-setup.yml in GitHub.",
        "clean": False,
        # GitHub's ci.yml tests every PR; this one only runs when started by hand.
        "pullRequestStartCondition": None,
        "branchStartCondition": None,
        "tagStartCondition": None,
        "scheduledStartCondition": None,
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
