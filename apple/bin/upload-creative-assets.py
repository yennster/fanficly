#!/usr/bin/env python3
"""Upload the App Store creative assets in fastlane/creative/en-US/ to App Store
Connect and place them on the editable iOS version's en-US localization:

    header-3840x1646.png -> PRODUCT_PAGE_HEADER_ASSET       (product page header)
    search-3840x2560.png -> APP_STORE_SEARCH_RESULTS_ASSET  (search results)

Neither deliver nor fastlane supports creative assets, so this drives the App
Asset Library API (see bin/asc_assets.py). Each placement type allows one asset
per localization. A slot that's already filled is skipped; pass --replace to
delete that placement (and its asset, if nothing else uses it) and upload
again. The assets go through App Review with the version. Nothing here submits.

Run with the repo venv:  bin/.venv/bin/python bin/upload-creative-assets.py [--replace]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_assets as asc  # noqa: E402

CREATIVE = asc.ROOT / "fastlane" / "creative" / "en-US"
# (placementType, file, referenceName)
SLOTS = [
    ("PRODUCT_PAGE_HEADER_ASSET", CREATIVE / "header-3840x1646.png", "Product page header"),
    ("APP_STORE_SEARCH_RESULTS_ASSET", CREATIVE / "search-3840x2560.png", "Search results"),
]
GROUP = "DEFAULT_PROFILE"
REPLACE = "--replace" in sys.argv


def main() -> None:
    app = asc.app_id()
    library = asc.library_id(app)
    loc = asc.editable_localization(app)
    for placement_type, path, name in SLOTS:
        print(f"==> {placement_type} <- {path.name}")
        if not path.exists():
            sys.exit(f"missing {path}")
        current = asc.placements(loc, placement_type)
        if current and not REPLACE:
            print("    already placed — skipping (pass --replace to re-upload)")
            continue
        for placement in current:
            asc.remove_placement(placement)
        image = asc.upload(library, path, "CREATIVE_ASSETS", name)
        if image.get("specId") not in asc.accepted_specs(placement_type, GROUP):
            sys.exit(f"    {path.name} matched spec {image.get('specId')}, which "
                     f"{placement_type} doesn't accept — check its size/format")
        placement = asc.place(image, loc, placement_type, GROUP)
        print(f"    placed ({placement['attributes']['state']})")
    print("Done. Submit for Review in App Store Connect when ready.")


if __name__ == "__main__":
    main()
