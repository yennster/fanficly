#!/usr/bin/env python3
"""The Apple app's CI, in Xcode Cloud.

Every Apple build runs on the newest Xcode 27 or later (xcode_cloud.py says
why), and GitHub's macOS runners don't have it yet, so the tests GitHub CI
used to run (ci.yml) run in Xcode Cloud's "CI" workflow instead, on every pull
request into main and every push to main that touches apple/. Xcode Cloud
reports each action on the pull request as a check:

  Unit tests (iPhone, iPad)   FanficlyTests on the newest iPhone and iPad simulators
  Unit tests (Mac)            FanficlyTests under Mac Catalyst
  UI tests (iPhone, iPad)     ReaderLayoutTests and NonReaderAccessibilityTests

The iPhone Duo's ReaderLayoutTests stay in their own "Duo tests" workflow
(bin/xcode-cloud-duo.py, xcode-cloud-duo.yml), which also exports their
screenshots.

  setup    makes or updates the workflow (the newest Xcode 27+, the start
           conditions, the actions)

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
Run:  bin/.venv/bin/python bin/xcode-cloud-ci.py setup
"""
from __future__ import annotations

import sys

import xcode_cloud as xcc

NAME = "CI"
IPHONE = ["iPhone 17 Pro Max"]
IPAD = ["iPad Pro 13-inch (M5)"]
APPLE_FILES = {"mode": "START_IF_ANY_FILE_MATCHES", "matchers": [{"directory": "apple"}]}


def setup() -> None:
    xc, mac = xcc.latest_xcode()
    phones = [xcc.simulator(xc, IPHONE, "iPhone"), xcc.simulator(xc, IPAD, "iPad")]
    main_only = {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]}
    xcc.upsert_workflow({
        "name": NAME,
        "description": "Unit and UI tests for apple/ on the newest Xcode 27+, for pull requests into "
                       "main and pushes to main. Kept up to date by xcode-cloud-setup.yml in GitHub.",
        "clean": False,
        "pullRequestStartCondition": {
            "source": {"isAllMatch": True},
            "destination": main_only,
            "filesAndFoldersRule": APPLE_FILES,
            "autoCancel": True,
        },
        "branchStartCondition": {
            "source": main_only,
            "filesAndFoldersRule": APPLE_FILES,
            "autoCancel": True,
        },
        "manualBranchStartCondition": {"source": {"isAllMatch": True}},
        "actions": [
            {
                "name": "Unit tests (iPhone, iPad)",
                "actionType": "TEST",
                "scheme": "FanficlyUnitTests",
                "platform": "IOS",
                "isRequiredToPass": True,
                "testConfiguration": {"kind": "USE_SCHEME_SETTINGS", "testDestinations": phones},
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
                "testConfiguration": {"kind": "USE_SCHEME_SETTINGS", "testDestinations": phones},
            },
        ],
    }, xc, mac)


def main() -> None:
    match sys.argv[1:]:
        case ["setup"]:
            setup()
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
