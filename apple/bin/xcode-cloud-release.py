#!/usr/bin/env python3
"""The App Store builds (iOS and Mac), archived in Xcode Cloud.

An app linked against an SDK that predates a device runs in compatibility mode
on it: 1.11.0 was built with the GitHub runner's Xcode 26.6, so the iPhone Duo
showed it as a letterboxed iPhone app, without its Duo layout. So every
shipping binary is archived in Xcode Cloud with the newest Xcode 27 or later
(xcode_cloud.latest_xcode), in its "Release (iOS)" and "Release (Mac)"
workflows, and Xcode Cloud uploads it to App Store Connect. The release
workflow (release.yml) then hands the build numbers to fastlane, which attaches
them to the App Store versions or TestFlight (ios_build:, mac_build:).

  setup                       makes or updates both workflows
  run BRANCH OUTDIR [ios|mac]...
                              setup, archive BRANCH for each platform (both by
                              default) at once, wait until App Store Connect
                              has processed each upload, and write its build
                              number to OUTDIR/<platform>-build-number.txt

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
Run:  bin/.venv/bin/python bin/xcode-cloud-release.py setup|run ...
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import xcode_cloud as xcc
from asc_assets import API, req

SCHEME = "Fanficly"
PLATFORMS = {
    "ios": {"name": "Release (iOS)", "platform": "IOS", "destination": "ANY_IOS_DEVICE",
            "label": "iOS (iPhone, iPad, iPhone Duo)"},
    "mac": {"name": "Release (Mac)", "platform": "MACOS", "destination": "ANY_MAC_CATALYST",
            "label": "Mac (Mac Catalyst)"},
}


def setup(platforms: list[str]) -> dict[str, tuple[dict, dict]]:
    """The release workflows, made or brought up to date, and their repository."""
    xc, mac = xcc.latest_xcode()
    out = {}
    for p in platforms:
        cfg = PLATFORMS[p]
        out[p] = xcc.upsert_workflow({
            "name": cfg["name"],
            "description": f"The {cfg['label']} App Store build, archived with the newest Xcode 27+. "
                           "Started only by release.yml in GitHub, which keeps this workflow up to date.",
            "clean": True,
            # Started by release.yml only, and only on main.
            "manualBranchStartCondition": {
                "source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]},
            },
            "actions": [{
                "name": "Archive for the App Store",
                "actionType": "ARCHIVE",
                "scheme": SCHEME,
                "platform": cfg["platform"],
                "destination": cfg["destination"],
                "buildDistributionAudience": "APP_STORE_ELIGIBLE",
                "isRequiredToPass": True,
            }],
        }, xc, mac)
    return out


def processed_build(p: str, run: dict) -> str | None:
    """The run's build number once App Store Connect has processed it, else None."""
    builds = req("GET", f"{API}/ciBuildRuns/{run['id']}/builds")["data"]
    if not builds:
        return None
    b = builds[0]["attributes"]
    print(f"    {p} build {b.get('version')}: {b.get('processingState')}", flush=True)
    if b.get("processingState") in ("FAILED", "INVALID"):
        sys.exit(f"App Store Connect rejected {p} build {b.get('version')}: {b.get('processingState')}")
    return b["version"] if b.get("processingState") == "VALID" else None


def run(branch: str, outdir: Path, platforms: list[str]) -> None:
    workflows = setup(platforms)
    runs = {p: xcc.start(wf, repo, branch, clean=True) for p, (wf, repo) in workflows.items()}

    # The other builds and the tag are this workflow run's commit, so these must be too.
    expected = os.environ.get("GITHUB_SHA")
    for p, r in runs.items():
        attrs = xcc.wait(r, 100)  # queue + clean archive; the job has 240 minutes in all
        if attrs.get("completionStatus") != "SUCCEEDED":
            for action in req("GET", f"{API}/ciBuildRuns/{r['id']}/actions")["data"]:
                a = action["attributes"]
                print(f"==> {a.get('name')}: {a.get('completionStatus')} {a.get('issueCounts')}")
            sys.exit(f"The {p} Xcode Cloud archive ended {attrs.get('completionStatus')}: "
                     "see Xcode Cloud in App Store Connect")
        sha = (attrs.get("sourceCommit") or {}).get("commitSha")
        if expected and sha and sha != expected:
            sys.exit(f"Xcode Cloud archived {sha[:7]}, not {expected[:7]}: {branch} moved during the release. "
                     "Run the release again; the stray upload can stay unused in TestFlight.")

    # An upload shows up as a build once App Store Connect has it; fastlane can
    # only attach it once it's processed.
    pending = dict(runs)
    for _ in range(60):
        for p, r in list(pending.items()):
            if number := processed_build(p, r):
                outdir.mkdir(parents=True, exist_ok=True)
                (outdir / f"{p}-build-number.txt").write_text(f"{number}\n")
                print(f"==> {p} build {number} is on App Store Connect")
                del pending[p]
        if not pending:
            return
        time.sleep(60)
    sys.exit(f"{', '.join(pending)} never finished processing on App Store Connect")


def main() -> None:
    match sys.argv[1:]:
        case ["setup"]:
            setup(list(PLATFORMS))
        case ["run", branch, outdir, *platforms] if all(p in PLATFORMS for p in platforms):
            run(branch, Path(outdir), platforms or list(PLATFORMS))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
