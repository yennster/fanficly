"""Shared App Store Connect plumbing for the App Asset Library uploaders
(bin/upload-creative-assets.py, bin/upload-duo-assets.py).

The asset library is the API for media deliver doesn't handle: creative assets
and new display classes like iPhone Duo. Flow per file: reserve an image/video
(POST), PUT the bytes to the returned upload operations, commit (PATCH
uploaded=true), wait for PREPARE_FOR_SUBMISSION, then create a placement that
puts it on a surface (an App Store version localization). Nothing here submits.

Auth: fastlane/api_key.json + the AuthKey .p8, same as the release lanes.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import jwt
import requests

ROOT = Path(__file__).resolve().parent.parent
API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "io.github.yennster.fanficly"


def token() -> str:
    key = json.loads((ROOT / "fastlane" / "api_key.json").read_text())
    p8 = (ROOT / "fastlane" / f"AuthKey_{key['key_id']}.p8").read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": key["issuer_id"], "iat": now, "exp": now + 1100,
         "aud": "appstoreconnect-v1"},
        p8, algorithm="ES256", headers={"kid": key["key_id"]})


def req(method: str, url: str, **kw) -> dict:
    r = requests.request(method, url, headers={
        "Authorization": f"Bearer {token()}",
        "Content-Type": "application/json",
    }, timeout=60, **kw)
    if r.status_code >= 400:
        sys.exit(f"ASC API {method} {url} -> {r.status_code}: {r.text[:800]}")
    return r.json() if r.text else {}


def app_id() -> str:
    return req("GET", f"{API}/apps", params={"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]


def library_id(app: str) -> str:
    return req("GET", f"{API}/apps/{app}/assetLibrary")["data"]["id"]


def editable_localization(app: str, platform: str = "IOS", locale: str = "en-US") -> str:
    versions = req("GET", f"{API}/apps/{app}/appStoreVersions",
                   params={"filter[platform]": platform,
                           "filter[appStoreState]": "PREPARE_FOR_SUBMISSION"})["data"]
    if not versions:
        sys.exit(f"no editable {platform} version — run `fastlane release` first")
    version = versions[0]
    print(f"==> {platform} {version['attributes']['versionString']}")
    locs = req("GET", f"{API}/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
    for loc in locs:
        if loc["attributes"]["locale"] == locale:
            return loc["id"]
    sys.exit(f"no {locale} localization on the editable {platform} version")


def accepted_specs(placement_type: str, group: str) -> set[str]:
    ref = req("GET", f"{API}/appAssetLibraryRefData",
              params={"fields[appAssetLibraryRefData]": "placementTypes"})["data"][0]["attributes"]
    for pt in ref["placementTypes"]:
        if pt["placementTypeId"] == placement_type:
            return {s for m in pt["specMappings"] if m["placementGroupId"] == group for s in m["specs"]}
    sys.exit(f"{placement_type} isn't in the reference data")


def placements(loc: str, placement_type: str, group: str | None = None) -> list[dict]:
    params = {"filter[placementType]": placement_type, "include": "image,video",
              "sort": "placementGroupPosition", "limit": 50}
    if group:
        params["filter[placementGroup]"] = group
    return req("GET", f"{API}/appStoreVersionLocalizations/{loc}/placements", params=params).get("data", [])


def remove_placement(placement: dict) -> None:
    """Delete a placement, then its asset if nothing else uses it."""
    rel = placement.get("relationships", {})
    asset = ((rel.get("image") or {}).get("data") or (rel.get("video") or {}).get("data"))
    req("DELETE", f"{API}/appAssetLibraryPlacements/{placement['id']}")
    print(f"    deleted placement {placement['id']}")
    if asset:
        kind = asset["type"]
        if not req("GET", f"{API}/{kind}/{asset['id']}/placements").get("data"):
            req("DELETE", f"{API}/{kind}/{asset['id']}")
            print(f"    deleted {kind[len('appAssetLibrary'):-1].lower()} {asset['id']}")


def upload(library: str, path: Path, category: str, name: str, video: bool = False,
           preview_frame: str | None = None) -> dict:
    """Reserve, upload, commit and wait for one image or video; returns its attributes + id."""
    kind = "appAssetLibraryVideos" if video else "appAssetLibraryImages"
    data = path.read_bytes()
    attrs = {"fileName": path.name, "fileSize": len(data), "category": category, "referenceName": name}
    if video and preview_frame:
        attrs["previewFrameTimeCode"] = preview_frame
    asset = req("POST", f"{API}/{kind}", json={"data": {
        "type": kind, "attributes": attrs,
        "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": library}}},
    }})["data"]
    for op in asset["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        r = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=600)
        if r.status_code >= 400:
            sys.exit(f"upload part failed: {r.status_code} {r.text[:300]}")
    req("PATCH", f"{API}/{kind}/{asset['id']}", json={"data": {
        "type": kind, "id": asset["id"], "attributes": {"uploaded": True}}})
    print(f"    uploaded {path.name} ({len(data) // 1024} KB), processing…")
    deadline = time.time() + 900
    while time.time() < deadline:
        attrs = req("GET", f"{API}/{kind}/{asset['id']}")["data"]["attributes"]
        if attrs["state"] == "PREPARE_FOR_SUBMISSION":
            return {"id": asset["id"], "kind": kind, **attrs}
        if attrs["state"] == "FAILED":
            sys.exit(f"processing failed for {path.name}: {json.dumps(attrs.get('stateDetails'))}")
        time.sleep(5)
    sys.exit(f"timed out waiting for {path.name} to process ({asset['id']})")


def place(asset: dict, loc: str, placement_type: str, group: str) -> dict:
    rel = "video" if asset["kind"] == "appAssetLibraryVideos" else "image"
    return req("POST", f"{API}/appAssetLibraryPlacements", json={"data": {
        "type": "appAssetLibraryPlacements",
        "attributes": {"placementType": placement_type, "placementGroup": group},
        "relationships": {
            rel: {"data": {"type": asset["kind"], "id": asset["id"]}},
            "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc}},
        },
    }})["data"]


def order(loc: str, group: str, placement_ids: list[str]) -> None:
    req("POST", f"{API}/appAssetLibraryPlacementOrderingRequests", json={"data": {
        "type": "appAssetLibraryPlacementOrderingRequests",
        "attributes": {"placementGroup": group},
        "relationships": {
            "orderedPlacements": {"data": [{"type": "appAssetLibraryPlacements", "id": i} for i in placement_ids]},
            "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc}},
        },
    }})
