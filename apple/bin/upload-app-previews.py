#!/usr/bin/env python3
"""Upload the app-preview videos in fastlane/previews/en-US/ to App Store
Connect (deliver can't upload previews). Attaches each video to the editable
(PREPARE_FOR_SUBMISSION) version's en-US localization:

    iphone.mp4 -> IPHONE_67 slot   (iOS version)
    ipad.mp4   -> IPAD_PRO_3GEN_129 (iOS version)
    mac.mp4    -> DESKTOP           (macOS version)

Requires an editable version on each platform (run `fastlane release` /
`release_mac` first). Idempotent: a slot that already holds a preview is
skipped — pass --replace to delete and re-upload. Auth: fastlane/api_key.json
+ the AuthKey .p8, same as the release lanes.

Run with the repo venv:  bin/.venv/bin/python bin/upload-app-previews.py
"""
import hashlib
import json
import sys
import time
from pathlib import Path

import jwt
import requests

ROOT = Path(__file__).resolve().parent.parent
API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "io.github.yennster.fanficly"
PREVIEWS = ROOT / "fastlane" / "previews" / "en-US"
# (platform, previewType, file)
SLOTS = [
    ("IOS", "IPHONE_67", PREVIEWS / "iphone.mp4"),
    ("IOS", "IPAD_PRO_3GEN_129", PREVIEWS / "ipad.mp4"),
    ("MAC_OS", "DESKTOP", PREVIEWS / "mac.mp4"),
]
REPLACE = "--replace" in sys.argv


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
        sys.exit(f"ASC API {method} {url} -> {r.status_code}: {r.text[:500]}")
    return r.json() if r.text else {}


def editable_version(app_id: str, platform: str) -> str | None:
    data = req("GET", f"{API}/apps/{app_id}/appStoreVersions",
               params={"filter[platform]": platform,
                       "filter[appStoreState]": "PREPARE_FOR_SUBMISSION"})["data"]
    return data[0]["id"] if data else None


def en_us_localization(version_id: str) -> str:
    locs = req("GET", f"{API}/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    for loc in locs:
        if loc["attributes"]["locale"] == "en-US":
            return loc["id"]
    sys.exit(f"no en-US localization on version {version_id}")


def preview_set(loc_id: str, preview_type: str) -> dict:
    sets = req("GET", f"{API}/appStoreVersionLocalizations/{loc_id}/appPreviewSets")["data"]
    for s in sets:
        if s["attributes"]["previewType"] == preview_type:
            return s
    return req("POST", f"{API}/appPreviewSets", json={"data": {
        "type": "appPreviewSets",
        "attributes": {"previewType": preview_type},
        "relationships": {"appStoreVersionLocalization": {
            "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}},
    }})["data"]


def upload(set_id: str, path: Path) -> None:
    blob = path.read_bytes()
    reserved = req("POST", f"{API}/appPreviews", json={"data": {
        "type": "appPreviews",
        "attributes": {"fileName": path.name, "fileSize": len(blob)},
        "relationships": {"appPreviewSet": {
            "data": {"type": "appPreviewSets", "id": set_id}}},
    }})["data"]
    for op in reserved["attributes"]["uploadOperations"]:
        chunk = blob[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
        r = requests.request(op["method"], op["url"], data=chunk,
                             headers=headers, timeout=300)
        r.raise_for_status()
    req("PATCH", f"{API}/appPreviews/{reserved['id']}", json={"data": {
        "type": "appPreviews", "id": reserved["id"],
        "attributes": {"uploaded": True,
                       "sourceFileChecksum": hashlib.md5(blob).hexdigest()},
    }})
    print(f"    uploaded {path.name} ({len(blob) // 1024} KB) — ASC is processing it")


def main() -> None:
    apps = req("GET", f"{API}/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        sys.exit(f"no app with bundle id {BUNDLE_ID}")
    app_id = apps[0]["id"]

    for platform, preview_type, path in SLOTS:
        print(f"==> {platform} / {preview_type} <- {path.name}")
        if not path.exists():
            sys.exit(f"missing {path} — run bin/record-app-previews.sh first")
        version_id = editable_version(app_id, platform)
        if not version_id:
            print(f"    SKIP: no editable {platform} version (upload a build first)")
            continue
        loc_id = en_us_localization(version_id)
        pset = preview_set(loc_id, preview_type)
        existing = req("GET", f"{API}/appPreviewSets/{pset['id']}/appPreviews")["data"]
        if existing and not REPLACE:
            print(f"    SKIP: slot already has {len(existing)} preview(s); --replace to overwrite")
            continue
        for prev in existing:
            req("DELETE", f"{API}/appPreviews/{prev['id']}")
            print(f"    deleted existing preview {prev['id']}")
        upload(pset["id"], path)


if __name__ == "__main__":
    main()
