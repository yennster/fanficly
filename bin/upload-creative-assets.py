#!/usr/bin/env python3
"""Upload the App Store creative assets in fastlane/creative/en-US/ to App Store
Connect and place them on the editable iOS version's en-US localization:

    header-3840x1646.png -> PRODUCT_PAGE_HEADER_ASSET       (product page header)
    search-3840x2560.png -> APP_STORE_SEARCH_RESULTS_ASSET  (search results)

Neither deliver nor fastlane supports creative assets, so this drives the App
Asset Library API directly: reserve an image (category CREATIVE_ASSETS), PUT
the bytes, commit, wait for processing, then create a placement. Each placement
type allows one asset per localization. A slot that's already filled is skipped;
pass --replace to delete that placement (and its asset, if nothing else uses it)
and upload again. The assets go through App Review with the version. Nothing
here submits anything.

Auth: fastlane/api_key.json + the AuthKey .p8, same as the release lanes.
Run with the repo venv:  bin/.venv/bin/python bin/upload-creative-assets.py
"""
import json
import sys
import time
from pathlib import Path

import jwt
import requests

ROOT = Path(__file__).resolve().parent.parent
API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "io.github.yennster.fanficly"
CREATIVE = ROOT / "fastlane" / "creative" / "en-US"
# (placementType, file, referenceName)
SLOTS = [
    ("PRODUCT_PAGE_HEADER_ASSET", CREATIVE / "header-3840x1646.png", "Product page header"),
    ("APP_STORE_SEARCH_RESULTS_ASSET", CREATIVE / "search-3840x2560.png", "Search results"),
]
GROUP = "DEFAULT_PROFILE"
REPLACE = "--replace" in sys.argv


def token() -> str:
    key = json.loads((ROOT / "fastlane" / "api_key.json").read_text())
    p8 = (ROOT / "fastlane" / f"AuthKey_{key['key_id']}.p8").read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": key["issuer_id"], "iat": now, "exp": now + 1100,
         "aud": "appstoreconnect-v1"},
        p8, algorithm="ES256", headers={"kid": key["key_id"]})


def req(method: str, url: str, ok_404: bool = False, **kw) -> dict:
    r = requests.request(method, url, headers={
        "Authorization": f"Bearer {token()}",
        "Content-Type": "application/json",
    }, timeout=60, **kw)
    if ok_404 and r.status_code == 404:
        return {}
    if r.status_code >= 400:
        sys.exit(f"ASC API {method} {url} -> {r.status_code}: {r.text[:800]}")
    return r.json() if r.text else {}


def editable_ios_localization(app_id: str) -> str:
    versions = req("GET", f"{API}/apps/{app_id}/appStoreVersions",
                   params={"filter[platform]": "IOS",
                           "filter[appStoreState]": "PREPARE_FOR_SUBMISSION"})["data"]
    if not versions:
        sys.exit("no editable iOS version — run `fastlane release` first")
    version = versions[0]
    print(f"==> iOS {version['attributes']['versionString']}")
    locs = req("GET", f"{API}/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
    for loc in locs:
        if loc["attributes"]["locale"] == "en-US":
            return loc["id"]
    sys.exit("no en-US localization on the editable iOS version")


def specs_for(placement_type: str) -> set[str]:
    ref = req("GET", f"{API}/appAssetLibraryRefData",
              params={"fields[appAssetLibraryRefData]": "placementTypes"})["data"][0]["attributes"]
    for pt in ref["placementTypes"]:
        if pt["placementTypeId"] == placement_type:
            return {s for m in pt["specMappings"] if m["placementGroupId"] == GROUP for s in m["specs"]}
    sys.exit(f"{placement_type} isn't in the reference data")


def existing_placements(loc_id: str, placement_type: str) -> list[dict]:
    return req("GET", f"{API}/appStoreVersionLocalizations/{loc_id}/placements",
               params={"filter[placementType]": placement_type, "include": "image"}).get("data", [])


def remove(placement: dict) -> None:
    image = (placement.get("relationships", {}).get("image", {}) or {}).get("data")
    req("DELETE", f"{API}/appAssetLibraryPlacements/{placement['id']}")
    print(f"    deleted placement {placement['id']}")
    if image:
        others = req("GET", f"{API}/appAssetLibraryImages/{image['id']}/placements").get("data", [])
        if not others:
            req("DELETE", f"{API}/appAssetLibraryImages/{image['id']}")
            print(f"    deleted image {image['id']}")


def upload_image(library_id: str, path: Path, name: str) -> dict:
    data = path.read_bytes()
    image = req("POST", f"{API}/appAssetLibraryImages", json={"data": {
        "type": "appAssetLibraryImages",
        "attributes": {"fileName": path.name, "fileSize": len(data),
                       "category": "CREATIVE_ASSETS", "referenceName": name},
        "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": library_id}}},
    }})["data"]
    for op in image["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        r = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=300)
        if r.status_code >= 400:
            sys.exit(f"upload part failed: {r.status_code} {r.text[:300]}")
    req("PATCH", f"{API}/appAssetLibraryImages/{image['id']}", json={"data": {
        "type": "appAssetLibraryImages", "id": image["id"], "attributes": {"uploaded": True}}})
    print(f"    uploaded {path.name} ({len(data) // 1024} KB), processing…")
    deadline = time.time() + 600
    while time.time() < deadline:
        attrs = req("GET", f"{API}/appAssetLibraryImages/{image['id']}")["data"]["attributes"]
        if attrs["state"] == "PREPARE_FOR_SUBMISSION":
            return {"id": image["id"], **attrs}
        if attrs["state"] == "FAILED":
            sys.exit(f"processing failed: {json.dumps(attrs.get('stateDetails'))}")
        time.sleep(5)
    sys.exit(f"timed out waiting for {path.name} to process (image {image['id']})")


def main() -> None:
    app = req("GET", f"{API}/apps", params={"filter[bundleId]": BUNDLE_ID})["data"][0]
    library_id = req("GET", f"{API}/apps/{app['id']}/assetLibrary")["data"]["id"]
    loc_id = editable_ios_localization(app["id"])
    for placement_type, path, name in SLOTS:
        print(f"==> {placement_type} <- {path.name}")
        if not path.exists():
            sys.exit(f"missing {path}")
        current = existing_placements(loc_id, placement_type)
        if current and not REPLACE:
            print("    already placed — skipping (pass --replace to re-upload)")
            continue
        for placement in current:
            remove(placement)
        image = upload_image(library_id, path, name)
        if image.get("specId") not in specs_for(placement_type):
            sys.exit(f"    {path.name} matched spec {image.get('specId')}, which "
                     f"{placement_type} doesn't accept — check its size/format")
        placement = req("POST", f"{API}/appAssetLibraryPlacements", json={"data": {
            "type": "appAssetLibraryPlacements",
            "attributes": {"placementType": placement_type, "placementGroup": GROUP},
            "relationships": {
                "image": {"data": {"type": "appAssetLibraryImages", "id": image["id"]}},
                "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}},
            },
        }})["data"]
        print(f"    placed ({placement['attributes']['state']})")
    print("Done. Submit for Review in App Store Connect when ready.")


if __name__ == "__main__":
    main()
