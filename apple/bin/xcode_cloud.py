"""Shared Xcode Cloud plumbing for the scripts that keep its workflows in code
(bin/xcode-cloud-ci.py, bin/xcode-cloud-release.py, bin/xcode-cloud-store-art.py).

Every Apple build runs on the newest Xcode 27 or later, in Xcode Cloud,
because an app built with an older SDK runs in compatibility mode on the
iPhone Duo (what 1.11.0 shipped, built with Xcode 26.6). GitHub's macOS
runners don't have Xcode 27 yet. latest_xcode() picks Xcode Cloud's "Latest
Release" when it is new enough, so the workflows follow new Xcodes on their
own, and refuses anything older than MIN_XCODE. ci_scripts/ci_post_clone.sh
checks the Xcode again inside every build.

Auth: fastlane/api_key.json + the AuthKey .p8, as for the other uploaders.
"""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

import requests

from asc_assets import API, app_id, req

PROJECT = "apple/Fanficly.xcodeproj"
MIN_XCODE = 27


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
    """The item with the highest version, skipping ones with none."""
    real = [i for i in items if version(key(i))]
    return max(real or items, key=lambda i: version(key(i)))


def is_beta(item: dict) -> bool:
    a = item["attributes"]
    return "beta" in f"{a.get('version')} {a.get('name')}".lower()


def is_latest_release(item: dict) -> bool:
    a = item["attributes"]
    return "latest release" in f"{a.get('version')} {a.get('name')}".lower()


def has_duo(xc: dict) -> bool:
    return any("Duo" in d.get("deviceTypeName", "") for d in xc["attributes"].get("testDestinations") or [])


def latest_xcode() -> tuple[dict, dict]:
    """The Xcode and macOS every workflow builds with: "Latest Release" when it
    has the iPhone Duo (so it's 27.1 or later), else the newest Xcode 27+ that
    has it. Exits when there is none, rather than build with an older one."""
    xcodes = all_pages(f"{API}/ciXcodeVersions")
    for xc in xcodes:
        a = xc["attributes"]
        print(f"Xcode {a.get('version')} ({a.get('name')}){' with iPhone Duo' if has_duo(xc) else ''}")
    # App Store Connect refuses uploads built with a beta, so betas never count.
    alias = next((x for x in xcodes if is_latest_release(x) and has_duo(x)), None)
    real = [x for x in xcodes if version(x["attributes"].get("version"))[:1] >= (MIN_XCODE,)
            and has_duo(x) and not is_beta(x)]
    xc = alias or (newest(real, lambda x: x["attributes"].get("version")) if real else None)
    if not xc:
        sys.exit(f"Xcode Cloud has no Xcode {MIN_XCODE} or later with the iPhone Duo")
    macs = all_pages(f"{API}/ciXcodeVersions/{xc['id']}/macOsVersions")
    mac = next((m for m in macs if is_latest_release(m)), None) \
        or newest([m for m in macs if not is_beta(m)] or macs, lambda m: m["attributes"].get("version"))
    print(f"==> Xcode {xc['attributes'].get('version')} on macOS {mac['attributes'].get('version')}")
    return xc, mac


# Releases that only run on the iPhone Duo. The API lists them for every
# device anyway, and Xcode Cloud then refuses an iPhone 17 Pro Max or iPad Pro
# on them as "incompatible with iOS 27.1". Drop one once others can run it.
DUO_ONLY_RUNTIMES = {"iOS 27.1"}


def latest_runtime(runtimes: list[dict], duo: bool = False) -> dict:
    """The newest runtime the device can run."""
    usable = [r for r in runtimes if duo or r.get("runtimeName") not in DUO_ONLY_RUNTIMES]
    if not usable:
        sys.exit(f"Only iPhone Duo runtimes listed: {', '.join(r.get('runtimeName', '?') for r in runtimes)}")
    return newest(usable, lambda r: r.get("runtimeName"))


def simulator(xc: dict, prefer: list[str], prefix: str) -> dict:
    """A test destination: the first of `prefer` this Xcode has, on its newest
    runtime. Exits when it has none, rather than test on an older device."""
    dests = [d for d in xc["attributes"].get("testDestinations") or [] if d.get("kind") == "SIMULATOR"]
    dest = next((d for name in prefer for d in dests if d.get("deviceTypeName") == name), None)
    if not dest:
        sys.exit(f"This Xcode has none of {', '.join(prefer)}: add its newest {prefix} to bin/xcode-cloud-ci.py")
    runtimes = dest.get("availableRuntimes") or []
    if not runtimes:
        sys.exit(f"{dest['deviceTypeName']} has no runtimes listed")
    print(f"    {dest['deviceTypeName']}: {', '.join(r.get('runtimeName', '?') for r in runtimes)}")
    runtime = latest_runtime(runtimes, duo="Duo" in dest["deviceTypeName"])
    print(f"==> {dest['deviceTypeName']} on {runtime['runtimeName']}")
    return {
        "deviceTypeName": dest["deviceTypeName"],
        "deviceTypeIdentifier": dest["deviceTypeIdentifier"],
        "runtimeName": runtime["runtimeName"],
        "runtimeIdentifier": runtime["runtimeIdentifier"],
        "kind": "SIMULATOR",
    }


def mac_destination(xc: dict) -> dict:
    """The Mac test destination (the Mac Catalyst app runs on Xcode Cloud's Mac)."""
    dests = [d for d in xc["attributes"].get("testDestinations") or [] if d.get("kind") == "MAC"]
    dest = next((d for d in dests if "catalyst" in (d.get("deviceTypeName", "") + d.get("deviceTypeIdentifier", "")).lower()),
                dests[0] if dests else None)
    if not dest:
        sys.exit("This Xcode has no Mac test destination")
    if not dest.get("availableRuntimes"):
        sys.exit(f"{dest['deviceTypeName']} has no runtimes listed")
    runtime = latest_runtime(dest["availableRuntimes"])
    return {
        "deviceTypeName": dest["deviceTypeName"],
        "deviceTypeIdentifier": dest["deviceTypeIdentifier"],
        "runtimeName": runtime["runtimeName"],
        "runtimeIdentifier": runtime["runtimeIdentifier"],
        "kind": "MAC",
    }


def product_and_workflows() -> tuple[dict, list[dict]]:
    product = req("GET", f"{API}/apps/{app_id()}/ciProduct")["data"]
    workflows = all_pages(f"{API}/ciProducts/{product['id']}/workflows")
    if not workflows:
        sys.exit("No Xcode Cloud workflows to borrow the repository from")
    return product, workflows


def upsert_workflow(attributes: dict, xc: dict, mac: dict) -> tuple[dict, dict]:
    """Makes or updates the workflow named attributes["name"]; returns it and its repository."""
    product, workflows = product_and_workflows()
    repo = req("GET", f"{API}/ciWorkflows/{workflows[0]['id']}/repository")["data"]
    attributes = {"isEnabled": True, "containerFilePath": PROJECT} | attributes
    relationships = {
        "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": xc["id"]}},
        "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": mac["id"]}},
    }
    existing = next((w for w in workflows if w["attributes"].get("name") == attributes["name"]), None)
    if existing:
        wf = req("PATCH", f"{API}/ciWorkflows/{existing['id']}", json={"data": {
            "type": "ciWorkflows", "id": existing["id"],
            "attributes": attributes, "relationships": relationships}})["data"]
        print(f"==> Updated workflow {attributes['name']} ({wf['id']})")
    else:
        relationships |= {
            "product": {"data": {"type": "ciProducts", "id": product["id"]}},
            "repository": {"data": {"type": "scmRepositories", "id": repo["id"]}},
        }
        wf = req("POST", f"{API}/ciWorkflows", json={"data": {
            "type": "ciWorkflows", "attributes": attributes, "relationships": relationships}})["data"]
        print(f"==> Created workflow {attributes['name']} ({wf['id']})")
    return wf, repo


def start(wf: dict, repo: dict, branch: str, clean: bool = False) -> dict:
    """Starts wf on branch; returns the build run."""
    ref = None
    for _ in range(20):  # Xcode Cloud can take a few minutes to see a new branch
        refs = all_pages(f"{API}/scmRepositories/{repo['id']}/gitReferences")
        ref = next((r for r in refs if r["attributes"].get("canonicalName") == f"refs/heads/{branch}"), None)
        if ref:
            break
        time.sleep(30)
    if not ref:
        sys.exit(f"Xcode Cloud doesn't see branch {branch}")
    run = req("POST", f"{API}/ciBuildRuns", json={"data": {
        "type": "ciBuildRuns", "attributes": {"clean": clean},
        "relationships": {
            "workflow": {"data": {"type": "ciWorkflows", "id": wf["id"]}},
            "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref["id"]}},
        }}})["data"]
    print(f"==> Started {wf['attributes'].get('name')}: build {run['attributes'].get('number')} ({run['id']})")
    return run


def wait(run: dict, minutes: int) -> dict:
    """The run's attributes once it completes; exits after `minutes`."""
    for _ in range(minutes):
        time.sleep(60)
        attrs = req("GET", f"{API}/ciBuildRuns/{run['id']}")["data"]["attributes"]
        print(f"    build {attrs.get('number')}: {attrs.get('executionProgress')} {attrs.get('completionStatus') or ''}",
              flush=True)
        if attrs.get("executionProgress") == "COMPLETE":
            return attrs
    sys.exit(f"Xcode Cloud build {run['attributes'].get('number')} didn't finish in {minutes} minutes")


def download_results(run_id: str, out: Path) -> None:
    """The run's result bundles (zipped) into out; exits when there are none."""
    out.mkdir(parents=True, exist_ok=True)
    got = 0
    for action in req("GET", f"{API}/ciBuildRuns/{run_id}/actions")["data"]:
        a = action["attributes"]
        print(f"==> {a.get('name')}: {a.get('completionStatus')} {a.get('issueCounts')}")
        for art in req("GET", f"{API}/ciBuildActions/{action['id']}/artifacts")["data"]:
            aa = art["attributes"]
            print(f"    artifact {aa.get('fileType')} {aa.get('fileName')}")
            if aa.get("fileType") != "RESULT_BUNDLE" or not aa.get("downloadUrl"):
                continue
            r = requests.get(aa["downloadUrl"], timeout=600)
            r.raise_for_status()
            (out / aa["fileName"]).write_bytes(r.content)
            got += 1
    if not got:
        sys.exit("The build left no result bundle")
