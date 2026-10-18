#!/usr/bin/env python3
"""Upload the iPhone Duo screenshots and app preview to the editable iOS
version's en-US localization (fastlane deliver doesn't know the Duo sizes):

    fastlane/screenshots-duo/en-US/duo-inner-*.png -> APP_SCREENSHOT / IPHONE_DUO_PROFILE
    fastlane/previews/en-US/iphone.mp4             -> APP_PREVIEW    / IPHONE_DUO_PROFILE

The Duo group holds up to 10 screenshots of either display (outer 1398×2034,
inner 2007×2853), so pick the set with --display inner|outer (default inner,
the unfolded showcase). The Duo preview slot takes the same 886×1920 video as
the 6.9" iPhone, so the iPhone preview is reused. Each run replaces what's
already in the Duo group, keeps the slide order, and submits nothing.

Run with the repo venv:  bin/.venv/bin/python bin/upload-duo-assets.py [--display outer] [--skip-preview]
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_assets as asc  # noqa: E402

GROUP = "IPHONE_DUO_PROFILE"
SHOTS = asc.ROOT / "fastlane" / "screenshots-duo" / "en-US"
PREVIEW = asc.ROOT / "fastlane" / "previews" / "en-US" / "iphone.mp4"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--display", choices=["inner", "outer"], default="inner")
    parser.add_argument("--skip-preview", action="store_true")
    args = parser.parse_args()

    files = sorted(SHOTS.glob(f"duo-{args.display}-*.png"))[:10]
    if not files:
        sys.exit(f"no duo-{args.display}-*.png in {SHOTS} — run bin/frame-screenshots.py first")
    app = asc.app_id()
    library = asc.library_id(app)
    loc = asc.editable_localization(app)

    print(f"==> APP_SCREENSHOT / {GROUP} <- {len(files)} × duo-{args.display}")
    for placement in asc.placements(loc, "APP_SCREENSHOT", GROUP):
        asc.remove_placement(placement)
    specs = asc.accepted_specs("APP_SCREENSHOT", GROUP)
    placed = []
    for path in files:
        image = asc.upload(library, path, "APP_SCREENSHOTS_AND_PREVIEWS", f"iPhone Duo — {path.stem}")
        if image.get("specId") not in specs:
            sys.exit(f"    {path.name} matched spec {image.get('specId')}, which the Duo group doesn't accept")
        placed.append(asc.place(image, loc, "APP_SCREENSHOT", GROUP)["id"])
    asc.order(loc, GROUP, placed)
    print(f"    placed and ordered {len(placed)} screenshots")

    if not args.skip_preview:
        print(f"==> APP_PREVIEW / {GROUP} <- {PREVIEW.name}")
        for placement in asc.placements(loc, "APP_PREVIEW", GROUP):
            asc.remove_placement(placement)
        video = asc.upload(library, PREVIEW, "APP_SCREENSHOTS_AND_PREVIEWS", "iPhone Duo — preview",
                           video=True, preview_frame="00:00:10:00")
        if video.get("specId") not in asc.accepted_specs("APP_PREVIEW", GROUP):
            sys.exit(f"    {PREVIEW.name} matched spec {video.get('specId')}, which the Duo slot doesn't accept")
        asc.place(video, loc, "APP_PREVIEW", GROUP)
        print("    placed")
    print("Done. Submit for Review in App Store Connect when ready.")


if __name__ == "__main__":
    main()
