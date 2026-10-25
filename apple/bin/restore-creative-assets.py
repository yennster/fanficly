#!/usr/bin/env python3
"""Bring back the product-page header and search-results art the live iOS
version shows, for when the newer art isn't wanted and the originals only
exist in App Store Connect:

    1. Find the PRODUCT_PAGE_HEADER_ASSET and APP_STORE_SEARCH_RESULTS_ASSET
       placements on the live (READY_FOR_SALE) iOS version's en-US page.
    2. Download each image into fastlane/creative/en-US/ under the names
       bin/upload-creative-assets.py uses, so they can be kept in git.
    3. With --apply, put those same library assets on the editable version in
       place of whatever is there (the same as Remove, then Browse Assets, in
       App Store Connect). The replaced assets stay in the library. Nothing is
       re-uploaded and nothing submits.

Run with the repo venv:  bin/.venv/bin/python bin/restore-creative-assets.py [--apply]
"""
import sys
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_assets as asc  # noqa: E402

CREATIVE = asc.ROOT / "fastlane" / "creative" / "en-US"
SLOTS = [
    ("PRODUCT_PAGE_HEADER_ASSET", "header-3840x1646.png"),
    ("APP_STORE_SEARCH_RESULTS_ASSET", "search-3840x2560.png"),
]
GROUP = "DEFAULT_PROFILE"
APPLY = "--apply" in sys.argv


def live_localization(app: str) -> str:
    versions = asc.req("GET", f"{asc.API}/apps/{app}/appStoreVersions",
                       params={"filter[platform]": "IOS",
                               "filter[appStoreState]": "READY_FOR_SALE"})["data"]
    if not versions:
        sys.exit("no live iOS version")
    version = versions[0]
    print(f"==> live iOS {version['attributes']['versionString']}")
    locs = asc.req("GET", f"{asc.API}/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
    return next(loc["id"] for loc in locs if loc["attributes"]["locale"] == "en-US")


def template_url(attrs: dict) -> dict | None:
    """The {templateUrl, width, height} image asset somewhere in the attributes."""
    for value in attrs.values():
        if isinstance(value, dict) and "templateUrl" in value:
            return value
    return None


def download(image_id: str, path: Path) -> None:
    attrs = asc.req("GET", f"{asc.API}/appAssetLibraryImages/{image_id}")["data"]["attributes"]
    print(f"    {attrs.get('referenceName')!r} ({attrs.get('fileName')})")
    asset = template_url(attrs)
    if not asset:
        sys.exit(f"    no download URL; attributes: {sorted(attrs)}")
    url = (asset["templateUrl"].replace("{w}", str(asset["width"]))
           .replace("{h}", str(asset["height"])).replace("{f}", "png").replace("{c}", "bb"))
    r = requests.get(url, timeout=120)
    r.raise_for_status()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(r.content)
    print(f"    saved {path.name} ({asset['width']}x{asset['height']}, {len(r.content) // 1024} KB)")


def image_id(placement: dict) -> str | None:
    return ((placement.get("relationships", {}).get("image") or {}).get("data") or {}).get("id")


def main() -> None:
    app = asc.app_id()
    live = live_localization(app)
    # Download both first, so they're kept even if the editable version
    # can't take them (already submitted, say).
    old = {}
    for placement_type, name in SLOTS:
        print(f"==> {placement_type}")
        current = asc.placements(live, placement_type)
        old[placement_type] = image_id(current[0]) if current else None
        if not old[placement_type]:
            sys.exit("    the live version has no image there")
        download(old[placement_type], CREATIVE / name)
    if not APPLY:
        print("Done. Pass --apply to put them on the editable version.")
        return
    editable = asc.editable_localization(app)
    for placement_type, _ in SLOTS:
        print(f"==> {placement_type} on the editable version")
        current = asc.placements(editable, placement_type)
        if any(image_id(p) == old[placement_type] for p in current):
            print("    already there")
            continue
        # Only the placements go; the rendered assets stay in the library
        # (Browse Assets can still pick them).
        for placement in current:
            asc.req("DELETE", f"{asc.API}/appAssetLibraryPlacements/{placement['id']}")
            print(f"    removed placement {placement['id']}")
        placement = asc.place({"kind": "appAssetLibraryImages", "id": old[placement_type]},
                              editable, placement_type, GROUP)
        print(f"    placed ({placement['attributes']['state']})")
    print("Done. Nothing was submitted.")


if __name__ == "__main__":
    main()
