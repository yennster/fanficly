#!/usr/bin/env python3
"""ReaderLayoutTests on the iPhone Duo simulator, in Xcode Cloud.

GitHub's macOS runners don't have an Xcode with the iPhone Duo yet, so the Duo
runs in Xcode Cloud. Its "Duo tests" workflow tests the FanficlyReaderLayout
scheme (ReaderLayoutTests only) on the Duo, in the pose the simulator boots
in. To save Xcode Cloud's compute hours it starts on its own only for pull
requests into main that change the reader's layout (LAYOUT_FILES), and
otherwise by hand (xcode-cloud-duo.yml with a branch, or Start Build in App
Store Connect). Xcode Cloud reports it on the PR as a check. Run by the workflows in
xcode-cloud-duo.yml, no Mac needed:

  setup                makes or updates that Xcode Cloud workflow: the newest
                       Xcode that has a Duo simulator, and its start conditions
  run BRANCH OUT       setup, start it on BRANCH, wait, download the result
                       bundle to OUT
  fetch SHA OUT        download the result bundle of the newest finished build
                       of commit SHA to OUT (after Xcode Cloud's check ends)

The screenshots are attachments in the result bundle.

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
Run:  bin/.venv/bin/python bin/xcode-cloud-duo.py setup|run|fetch ...
"""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

import requests

from asc_assets import API, app_id, req

NAME = "Duo tests"
SCHEME = "FanficlyReaderLayout"
PROJECT = "apple/Fanficly.xcodeproj"
# What ReaderLayoutTests exercise: the reader, the app's window and layout,
# the reader's settings, and the tests themselves. A PR that changes none of
# them can't change the Duo's result.
LAYOUT_FILES = {"mode": "START_IF_ANY_FILE_MATCHES", "matchers": [
    {"directory": "apple/Fanficly/Reader"},
    {"directory": "apple/Fanficly/DesignSystem"},
    {"directory": "apple/Fanficly", "fileName": "RootView.swift"},
    {"directory": "apple/Fanficly", "fileName": "FanficlyApp.swift"},
    {"directory": "apple/Fanficly/Settings", "fileName": "ReaderSettingsView.swift"},
    {"directory": "apple/FanficlyUITests", "fileName": "FanficlyUITests.swift"},
]}


def all_pages(url: str, params: dict | None = None) -> list[dict]:
    out, params = [], dict(params or {}, limit=200)
    while url:
        page = req("GET", url, params=params)
        out += page["data"]
        url, params = page.get("links", {}).get("next"), None
    return out


def version(text: str | None) -> tuple[int, ...]:
    """(27, 1) from "27.1" or "iOS 27.1"; () for aliases like "Latest Release"."""
    return tuple(int(n) for n in re.findall(r"\d+", text or ""))


def newest(items: list, key) -> object:
    """The item with the highest version, skipping ones with none (the API's
    order isn't documented)."""
    real = [i for i in items if version(key(i))]
    return max(real or items, key=lambda i: version(key(i)))


def duo_xcode() -> tuple[dict, dict]:
    """The newest Xcode that has an iPhone Duo simulator, and that destination."""
    found = []
    for xc in all_pages(f"{API}/ciXcodeVersions"):
        attrs = xc["attributes"]
        dests = attrs.get("testDestinations") or []
        names = sorted({d.get("deviceTypeName", "?") for d in dests if "iPhone" in d.get("deviceTypeName", "")})
        print(f"Xcode {attrs.get('version')} ({attrs.get('name')}): {', '.join(names[-6:])}")
        for d in dests:
            if "Duo" in d.get("deviceTypeName", ""):
                found.append((xc, d))
    if not found:
        sys.exit("No Xcode in Xcode Cloud offers an iPhone Duo simulator yet")
    xc, dest = newest(found, lambda f: f[0]["attributes"].get("version"))
    print(f"==> Using Xcode {xc['attributes']['version']} and {dest['deviceTypeName']}")
    return xc, dest


def product_and_workflows() -> tuple[dict, list[dict]]:
    product = req("GET", f"{API}/apps/{app_id()}/ciProduct")["data"]
    workflows = req("GET", f"{API}/ciProducts/{product['id']}/workflows", params={"limit": 200})["data"]
    if not workflows:
        sys.exit("No Xcode Cloud workflows to borrow the repository from")
    return product, workflows


def setup() -> tuple[dict, dict]:
    """The Duo workflow, made or brought up to date, and its repository."""
    xc, dest = duo_xcode()
    runtimes = dest.get("availableRuntimes") or []
    if not runtimes:
        sys.exit(f"{dest['deviceTypeName']} has no runtimes listed")
    runtime = newest(runtimes, lambda r: r.get("runtimeName"))
    macs = req("GET", f"{API}/ciXcodeVersions/{xc['id']}/macOsVersions")["data"]
    mac = newest(macs, lambda m: m["attributes"].get("version"))
    print(f"==> macOS {mac['attributes'].get('version')}, runtime {runtime.get('runtimeName')}")

    product, workflows = product_and_workflows()
    repo = req("GET", f"{API}/ciWorkflows/{workflows[0]['id']}/repository")["data"]
    attributes = {
        "name": NAME,
        "description": "ReaderLayoutTests on the iPhone Duo simulator, for pull requests that change "
                       "the reader's layout, or by hand. Kept up to date by xcode-cloud-duo.yml in GitHub.",
        "isEnabled": True,
        "clean": False,
        "containerFilePath": PROJECT,
        "manualBranchStartCondition": {"source": {"isAllMatch": True}},
        "pullRequestStartCondition": {
            "source": {"isAllMatch": True},
            "destination": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]},
            "filesAndFoldersRule": LAYOUT_FILES,
            "autoCancel": True,
        },
        "actions": [{
            "name": "Test on iPhone Duo",
            "actionType": "TEST",
            "scheme": SCHEME,
            "platform": "IOS",
            "isRequiredToPass": True,
            "testConfiguration": {
                "kind": "USE_SCHEME_SETTINGS",
                "testDestinations": [{
                    "deviceTypeName": dest["deviceTypeName"],
                    "deviceTypeIdentifier": dest["deviceTypeIdentifier"],
                    "runtimeName": runtime["runtimeName"],
                    "runtimeIdentifier": runtime["runtimeIdentifier"],
                    "kind": "SIMULATOR",
                }],
            },
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


def download(run_id: str, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    got = 0
    for action in req("GET", f"{API}/ciBuildRuns/{run_id}/actions")["data"]:
        a = action["attributes"]
        print(f"==> {a.get('name')}: {a.get('completionStatus')} {a.get('issueCounts')}")
        for art in req("GET", f"{API}/ciBuildActions/{action['id']}/artifacts")["data"]:
            aa = art["attributes"]
            print(f"    artifact {aa.get('fileType')} {aa.get('fileName')}")
            if aa.get("fileType") not in ("RESULT_BUNDLE", "LOG_BUNDLE") or not aa.get("downloadUrl"):
                continue
            r = requests.get(aa["downloadUrl"], timeout=600)
            r.raise_for_status()
            (out / aa["fileName"]).write_bytes(r.content)
            got += aa.get("fileType") == "RESULT_BUNDLE"
    if not got:
        sys.exit("The build left no result bundle")


def run(branch: str, out: Path) -> None:
    wf, repo = setup()
    ref = None
    for _ in range(20):  # Xcode Cloud can take a few minutes to see a new branch
        refs = all_pages(f"{API}/scmRepositories/{repo['id']}/gitReferences")
        ref = next((r for r in refs if r["attributes"].get("canonicalName") == f"refs/heads/{branch}"), None)
        if ref:
            break
        time.sleep(30)
    if not ref:
        sys.exit(f"Xcode Cloud doesn't see branch {branch}")

    build = req("POST", f"{API}/ciBuildRuns", json={"data": {
        "type": "ciBuildRuns", "attributes": {"clean": False},
        "relationships": {
            "workflow": {"data": {"type": "ciWorkflows", "id": wf["id"]}},
            "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref["id"]}},
        }}})["data"]
    print(f"==> Started build {build['attributes'].get('number')} ({build['id']})")
    while True:
        time.sleep(60)
        attrs = req("GET", f"{API}/ciBuildRuns/{build['id']}")["data"]["attributes"]
        print(f"    {attrs.get('executionProgress')} {attrs.get('completionStatus') or ''}", flush=True)
        if attrs.get("executionProgress") == "COMPLETE":
            break
    download(build["id"], out)


def fetch(sha: str, out: Path) -> None:
    _, workflows = product_and_workflows()
    wf = next((w for w in workflows if w["attributes"].get("name") == NAME), None)
    if not wf:
        sys.exit(f"No Xcode Cloud workflow named {NAME}")
    # The check can end a little before the API shows the build complete.
    for _ in range(10):
        builds = req("GET", f"{API}/ciWorkflows/{wf['id']}/buildRuns", params={"limit": 50})["data"]
        builds = sorted(builds, key=lambda b: b["attributes"].get("number") or 0, reverse=True)
        build = next((b for b in builds
                      if (b["attributes"].get("sourceCommit") or {}).get("commitSha") == sha), None)
        if build and build["attributes"].get("executionProgress") == "COMPLETE":
            status = build["attributes"].get("completionStatus")
            print(f"==> Build {build['attributes'].get('number')}: {status}")
            if status in ("CANCELED", "SKIPPED"):
                print("Nothing to download")  # superseded by a newer push
                return
            download(build["id"], out)
            return
        time.sleep(30)
    sys.exit(f"No finished {NAME} build of {sha}")


def main() -> None:
    match sys.argv[1:]:
        case ["setup"]:
            setup()
        case ["run", branch, out]:
            run(branch, Path(out))
        case ["fetch", sha, out]:
            fetch(sha, Path(out))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
