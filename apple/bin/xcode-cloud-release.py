#!/usr/bin/env python3
"""The iOS release build, archived in Xcode Cloud.

An app linked against an SDK that predates a device runs in compatibility mode
on it: 1.11.0 was built with the GitHub runner's Xcode 26.6, so the iPhone Duo
showed it as a letterboxed iPhone app, without its Duo layout. GitHub's macOS
runners have no Xcode with the iOS 27.1 SDK yet, so the iOS binary is archived
in Xcode Cloud's "Release (iOS)" workflow instead, with the newest Xcode that
has the iPhone Duo, and Xcode Cloud uploads it to App Store Connect. The
release workflow (release.yml) then hands the build number to fastlane, which
attaches it to the App Store version or TestFlight. The Mac build stays on the
runner (Mac Catalyst has no Duo).

  setup            makes or updates that Xcode Cloud workflow
  run BRANCH OUT   setup, archive BRANCH, wait until App Store Connect has
                   processed the build, write its build number to OUT

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
Run:  bin/.venv/bin/python bin/xcode-cloud-release.py setup|run ...
"""
from __future__ import annotations

import importlib.util
import os
import sys
import time
from pathlib import Path

from asc_assets import API, req

# The Duo tests' helpers: the newest Xcode with a Duo, paging, the product.
_spec = importlib.util.spec_from_file_location("xcode_cloud_duo", Path(__file__).with_name("xcode-cloud-duo.py"))
duo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(duo)

NAME = "Release (iOS)"
SCHEME = "Fanficly"


def setup() -> tuple[dict, dict]:
    """The release workflow, made or brought up to date, and its repository."""
    xc, _ = duo.duo_xcode()
    macs = req("GET", f"{API}/ciXcodeVersions/{xc['id']}/macOsVersions")["data"]
    mac = duo.newest(macs, lambda m: m["attributes"].get("version"))
    print(f"==> macOS {mac['attributes'].get('version')}")

    product, workflows = duo.product_and_workflows()
    repo = req("GET", f"{API}/ciWorkflows/{workflows[0]['id']}/repository")["data"]
    attributes = {
        "name": NAME,
        "description": "The iOS App Store build, archived with an Xcode that has the iPhone Duo. "
                       "Started only by release.yml in GitHub, which keeps this workflow up to date.",
        "isEnabled": True,
        "clean": True,
        "containerFilePath": duo.PROJECT,
        # Started by release.yml only, and only on main.
        "manualBranchStartCondition": {
            "source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]},
        },
        "actions": [{
            "name": "Archive for the App Store",
            "actionType": "ARCHIVE",
            "scheme": SCHEME,
            "platform": "IOS",
            "destination": "ANY_IOS_DEVICE",
            "buildDistributionAudience": "APP_STORE_ELIGIBLE",
            "isRequiredToPass": True,
        }],
    }
    relationships = {
        "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": xc["id"]}},
        "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": mac["id"]}},
    }
    existing = next((w for w in workflows if w["attributes"].get("name") == NAME), None)
    if existing:
        wf = req("PATCH", f"{API}/ciWorkflows/{existing['id']}", json={"data": {
            "type": "ciWorkflows", "id": existing["id"],
            "attributes": attributes, "relationships": relationships}})["data"]
        print(f"==> Updated workflow {wf['id']}")
    else:
        relationships |= {
            "product": {"data": {"type": "ciProducts", "id": product["id"]}},
            "repository": {"data": {"type": "scmRepositories", "id": repo["id"]}},
        }
        wf = req("POST", f"{API}/ciWorkflows", json={"data": {
            "type": "ciWorkflows", "attributes": attributes, "relationships": relationships}})["data"]
        print(f"==> Created workflow {wf['id']}")
    return wf, repo


def run(branch: str, out: Path) -> None:
    wf, repo = setup()
    refs = duo.all_pages(f"{API}/scmRepositories/{repo['id']}/gitReferences")
    ref = next((r for r in refs if r["attributes"].get("canonicalName") == f"refs/heads/{branch}"), None)
    if not ref:
        sys.exit(f"Xcode Cloud doesn't see branch {branch}")

    run_ = req("POST", f"{API}/ciBuildRuns", json={"data": {
        "type": "ciBuildRuns", "attributes": {"clean": True},
        "relationships": {
            "workflow": {"data": {"type": "ciWorkflows", "id": wf["id"]}},
            "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref["id"]}},
        }}})["data"]
    print(f"==> Started Xcode Cloud build {run_['attributes'].get('number')} ({run_['id']})")
    for _ in range(100):  # queue + clean archive; the job has 240 minutes in all
        time.sleep(60)
        attrs = req("GET", f"{API}/ciBuildRuns/{run_['id']}")["data"]["attributes"]
        print(f"    {attrs.get('executionProgress')} {attrs.get('completionStatus') or ''}", flush=True)
        if attrs.get("executionProgress") == "COMPLETE":
            break
    else:
        sys.exit("The Xcode Cloud archive didn't finish in 100 minutes: see Xcode Cloud in App Store Connect")
    if attrs.get("completionStatus") != "SUCCEEDED":
        for action in req("GET", f"{API}/ciBuildRuns/{run_['id']}/actions")["data"]:
            a = action["attributes"]
            print(f"==> {a.get('name')}: {a.get('completionStatus')} {a.get('issueCounts')}")
        sys.exit(f"The Xcode Cloud archive ended {attrs.get('completionStatus')}: see Xcode Cloud in App Store Connect")

    # The Mac build and the tag are this workflow run's commit, so iOS must be too.
    sha = (attrs.get("sourceCommit") or {}).get("commitSha")
    expected = os.environ.get("GITHUB_SHA")
    if expected and sha and sha != expected:
        sys.exit(f"Xcode Cloud archived {sha[:7]}, not {expected[:7]}: {branch} moved during the release. "
                 "Run the release again; the stray upload can stay unused in TestFlight.")

    # The upload shows up as a build once App Store Connect has it; fastlane
    # can only attach it once it's processed.
    for _ in range(60):
        builds = req("GET", f"{API}/ciBuildRuns/{run_['id']}/builds")["data"]
        if builds:
            b = builds[0]["attributes"]
            print(f"    build {b.get('version')}: {b.get('processingState')}", flush=True)
            if b.get("processingState") == "VALID":
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text(f"{b['version']}\n")
                print(f"==> iOS build {b['version']} is on App Store Connect")
                return
            if b.get("processingState") in ("FAILED", "INVALID"):
                sys.exit(f"App Store Connect rejected build {b.get('version')}: {b.get('processingState')}")
        time.sleep(60)
    sys.exit("The archive never finished processing on App Store Connect")


def main() -> None:
    match sys.argv[1:]:
        case ["setup"]:
            setup()
        case ["run", branch, out]:
            run(branch, Path(out))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
