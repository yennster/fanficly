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
       App Store Connect). Nothing is re-uploaded and nothing submits.

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


def main() -> None:
    app = asc.app_id()
    live = live_localization(app)
    editable = asc.editable_localization(app) if APPLY else None
    for placement_type, name in SLOTS:
        print(f"==> {placement_type}")
        old = asc.placements(live, placement_type)
        if not old:
            sys.exit("    the live version has none")
        image = (old[0].get("relationships", {}).get("image") or {}).get("data")
        if not image:
            sys.exit("    the live placement isn't an image")
        download(image["id"], CREATIVE / name)
        if not APPLY:
            continue
        current = asc.placements(editable, placement_type)
        if any((p.get("relationships", {}).get("image") or {}).get("data", {}).get("id") == image["id"]
               for p in current):
            print("    already on the editable version")
            continue
        for placement in current:
            asc.remove_placement(placement)
        placement = asc.place({"kind": "appAssetLibraryImages", "id": image["id"]},
                              editable, placement_type, GROUP)
        print(f"    placed on the editable version ({placement['attributes']['state']})")
    print("Done." + ("" if APPLY else " Pass --apply to put them on the editable version."))


if __name__ == "__main__":
    main()
