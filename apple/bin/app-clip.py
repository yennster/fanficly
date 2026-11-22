#!/usr/bin/env python3
"""The App Clip's setup outside Xcode (#292), so none of it needs a Mac or a
click in App Store Connect:

  aasa --team TEAMID   write website/.well-known/apple-app-site-association:
                       the app's universal links (fanficly.app/works/*) and
                       the clip, from the bundle IDs in project.yml
  aasa --check         CI: the committed file (when there is one), project.yml,
                       the entitlements, WorkLink.swift and website/vercel.json
                       all name the same host, bundle IDs and team
  identifiers [--apply]
                       App Store Connect API: the bundle IDs' capabilities
                       (Associated Domains on the app; App Groups and
                       Associated Domains on the clip)
  experiences [--apply]
                       App Store Connect API: the clip's default experience
                       (on the editable App Store version) and its advanced
                       experiences, from appclip/experiences.json, with the
                       card image cut from the store art's header

Without --apply the API commands only report what they would change. Run by
the App Clip workflow (.github/workflows/app-clip.yml); docs/RELEASING.md
says when.

The public App Store Connect API can't mark a bundle ID as an App Clip of its
parent, so `identifiers` doesn't create the clip's: Xcode Cloud's
cloud-managed signing registers it, with its capabilities, the first time the
Release workflow archives the app with the clip in it. Run `identifiers`
after that to check, or before it to turn on Associated Domains for the app.

Auth (API commands): fastlane/api_key.json + the AuthKey .p8, as for the
other uploaders.
Run:  bin/.venv/bin/python bin/app-clip.py <command> [...]
"""
from __future__ import annotations

import hashlib
import io
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # apple/
REPO = ROOT.parent
PROJECT_YML = ROOT / "project.yml"
CONFIG = ROOT / "appclip" / "experiences.json"
HEADER_ART = ROOT / "screenshots" / "creative" / "header-3840x1646.png"
AASA = REPO / "website" / ".well-known" / "apple-app-site-association"
VERCEL = REPO / "website" / "vercel.json"
WORK_LINK = ROOT / "Fanficly" / "WorkLink.swift"
APP_ENTITLEMENTS = [ROOT / "Fanficly" / "Fanficly.entitlements", ROOT / "Fanficly" / "FanficlyMac.entitlements"]
CLIP_ENTITLEMENTS = ROOT / "FanficlyClip" / "FanficlyClip.entitlements"

APP_TARGET = "Fanficly"
CLIP_TARGET = "FanficlyClip"
# The paths the app opens as universal links, in order (Apple takes the first
# match): WorkLink accepts only /works/<id>, so deeper paths stay on the web.
APPLINK_COMPONENTS = [
    {"/": "/works/*/*", "exclude": True, "comment": "Not a work link: the web page"},
    {"/": "/works/*", "comment": "A shared work (WorkLink.swift)"},
]
CARD_SIZE = (1800, 1200)
TEAM_RE = re.compile(r"^[A-Z0-9]{10}$")


# ------------------------------------------------------------------ project

def bundle_ids() -> dict[str, str]:
    """PRODUCT_BUNDLE_IDENTIFIER of each top-level target in project.yml.

    A small line reader rather than a YAML parser, so CI's tooling job needs
    no packages: targets sit at two spaces under `targets:`, and each one's
    first PRODUCT_BUNDLE_IDENTIFIER is its own.
    """
    ids: dict[str, str] = {}
    in_targets = False
    target = None
    for line in PROJECT_YML.read_text().splitlines():
        if re.match(r"^\S", line):
            in_targets = line.startswith("targets:")
            target = None
            continue
        if not in_targets:
            continue
        m = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if m:
            target = m.group(1)
            continue
        m = re.match(r"^\s+PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)\s*$", line)
        if m and target and target not in ids:
            ids[target] = m.group(1)
    for name in (APP_TARGET, CLIP_TARGET):
        if name not in ids:
            sys.exit(f"project.yml has no PRODUCT_BUNDLE_IDENTIFIER for the {name} target")
    return ids


def host() -> str:
    m = re.search(r'static let host = "([^"]+)"', WORK_LINK.read_text())
    if not m:
        sys.exit(f"no `static let host` in {WORK_LINK.relative_to(REPO)}")
    return m.group(1)


def aasa_document(team: str) -> dict:
    ids = bundle_ids()
    return {
        "applinks": {
            "details": [{
                "appIDs": [f"{team}.{ids[APP_TARGET]}"],
                "components": APPLINK_COMPONENTS,
            }],
        },
        "appclips": {"apps": [f"{team}.{ids[CLIP_TARGET]}"]},
    }


def render(doc: dict) -> str:
    return json.dumps(doc, indent=2) + "\n"


def domains(path: Path) -> list[str]:
    """The associated-domains entries of an entitlements plist."""
    text = path.read_text()
    m = re.search(r"<key>com\.apple\.developer\.associated-domains</key>\s*<array>(.*?)</array>", text, re.S)
    return re.findall(r"<string>([^<]+)</string>", m.group(1)) if m else []


def check() -> None:
    problems: list[str] = []
    ids = bundle_ids()
    site = host()
    if not ids[CLIP_TARGET].startswith(ids[APP_TARGET] + "."):
        problems.append(f"the clip's bundle ID {ids[CLIP_TARGET]} must start with the app's ({ids[APP_TARGET]}.)")

    for path in APP_ENTITLEMENTS:
        if f"applinks:{site}" not in domains(path):
            problems.append(f"{path.relative_to(REPO)} lacks applinks:{site}")
    if f"appclips:{site}" not in domains(CLIP_ENTITLEMENTS):
        problems.append(f"{CLIP_ENTITLEMENTS.relative_to(REPO)} lacks appclips:{site}")
    parents = CLIP_ENTITLEMENTS.read_text()
    if f"$(AppIdentifierPrefix){ids[APP_TARGET]}<" not in parents:
        problems.append(f"{CLIP_ENTITLEMENTS.relative_to(REPO)}'s parent-application-identifiers isn't the app ({ids[APP_TARGET]})")

    vercel = json.loads(VERCEL.read_text())
    served = [h for h in vercel.get("headers", []) if h.get("source") == "/.well-known/apple-app-site-association"]
    if not any(x.get("key", "").lower() == "content-type" and x.get("value") == "application/json"
               for h in served for x in h.get("headers", [])):
        problems.append("website/vercel.json doesn't serve /.well-known/apple-app-site-association as application/json")

    if AASA.exists():
        try:
            doc = json.loads(AASA.read_text())
        except json.JSONDecodeError as e:
            problems.append(f"{AASA.relative_to(REPO)} isn't JSON: {e}")
            doc = None
        if doc is not None:
            apps = doc.get("appclips", {}).get("apps", [])
            team = apps[0].split(".", 1)[0] if apps else ""
            if not TEAM_RE.match(team):
                problems.append(f"{AASA.relative_to(REPO)}: no team ID in front of the clip's bundle ID")
            elif AASA.read_text() != render(aasa_document(team)):
                problems.append(f"{AASA.relative_to(REPO)} is out of date with project.yml: "
                                f"run bin/app-clip.py aasa --team {team}")
    else:
        print(f"note: {AASA.relative_to(REPO)} isn't committed yet (the App Clip workflow writes it)")

    if problems:
        for p in problems:
            print(f"::error::{p}")
        sys.exit(1)
    print(f"App Clip setup agrees: {site}, {ids[APP_TARGET]}, {ids[CLIP_TARGET]}")


def write_aasa(team: str) -> None:
    if not TEAM_RE.match(team):
        sys.exit("--team needs the 10-character Apple Developer Team ID")
    AASA.parent.mkdir(parents=True, exist_ok=True)
    AASA.write_text(render(aasa_document(team)))
    print(f"wrote {AASA.relative_to(REPO)}")


# --------------------------------------------------------------------- API

def api():
    import asc_assets  # needs requests + PyJWT (bin/requirements.txt)
    return asc_assets


def bundle_id_record(asc, identifier: str) -> dict | None:
    data = asc.req("GET", f"{asc.API}/bundleIds", params={
        "filter[identifier]": identifier, "include": "bundleIdCapabilities", "limit": 50})
    # filter[identifier] matches prefixes too; keep the exact one.
    for item in data.get("data", []):
        if item["attributes"]["identifier"] == identifier:
            caps = {c["id"]: c["attributes"].get("capabilityType")
                    for c in data.get("included", []) if c["type"] == "bundleIdCapabilities"}
            mine = {r["id"] for r in item["relationships"]["bundleIdCapabilities"].get("data", [])}
            item["capabilities"] = {caps[i] for i in mine if i in caps}
            return item
    return None


def identifiers(apply: bool) -> None:
    asc = api()
    ids = bundle_ids()
    wanted = {
        ids[APP_TARGET]: ["ASSOCIATED_DOMAINS"],
        ids[CLIP_TARGET]: ["APP_GROUPS", "ASSOCIATED_DOMAINS"],
    }
    for identifier, capabilities in wanted.items():
        record = bundle_id_record(asc, identifier)
        if record is None:
            if identifier == ids[CLIP_TARGET]:
                print(f"MISSING  {identifier}: the first Release archive with the clip registers it "
                      "(Xcode Cloud's cloud-managed signing); the public API can't make an App Clip ID")
            else:
                print(f"MISSING  {identifier}: expected to exist already")
            continue
        print(f"OK       {identifier} (team {record['attributes'].get('seedId')}): "
              f"{', '.join(sorted(record['capabilities'])) or 'no capabilities'}")
        for capability in capabilities:
            if capability in record["capabilities"]:
                continue
            if not apply:
                print(f"    would turn on {capability}")
                continue
            asc.req("POST", f"{asc.API}/bundleIdCapabilities", json={"data": {
                "type": "bundleIdCapabilities",
                "attributes": {"capabilityType": capability},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": record["id"]}}},
            }})
            print(f"    turned on {capability}")


def card_image() -> tuple[str, bytes]:
    """The App Clip card image (1800x1200, opaque): the middle of the store
    art's product-page header, the headline with an iPhone either side."""
    from PIL import Image

    art = Image.open(HEADER_ART).convert("RGB")
    w, h = art.size
    crop_w = round(h * CARD_SIZE[0] / CARD_SIZE[1])
    left = (w - crop_w) // 2
    card = art.crop((left, 0, left + crop_w, h)).resize(CARD_SIZE, Image.LANCZOS)
    out = io.BytesIO()
    card.save(out, format="PNG", optimize=True)
    return "app-clip-card-1800x1200.png", out.getvalue()


def upload_image(asc, kind: str, attrs: dict, relationships: dict | None) -> str:
    """Reserve, upload and commit an App Clip image; returns its id."""
    import requests

    name, data = card_image()
    body = {"type": kind, "attributes": {"fileName": name, "fileSize": len(data), **attrs}}
    if relationships:
        body["relationships"] = relationships
    image = asc.req("POST", f"{asc.API}/{kind}", json={"data": body})["data"]
    for op in image["attributes"].get("uploadOperations") or []:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        r = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=600)
        if r.status_code >= 400:
            sys.exit(f"card image upload failed: {r.status_code} {r.text[:300]}")
    asc.req("PATCH", f"{asc.API}/{kind}/{image['id']}", json={"data": {
        "type": kind, "id": image["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    print(f"    uploaded the card image ({len(data) // 1024} KB)")
    return image["id"]


def app_clip_id(asc, clip_bundle: str) -> str | None:
    clips = asc.req("GET", f"{asc.API}/apps/{asc.app_id()}/appClips", params={"limit": 50}).get("data", [])
    for clip in clips:
        if clip["attributes"].get("bundleId") == clip_bundle:
            return clip["id"]
    return None


def editable_version(asc) -> dict | None:
    versions = asc.req("GET", f"{asc.API}/apps/{asc.app_id()}/appStoreVersions", params={
        "filter[platform]": "IOS", "filter[appStoreState]": "PREPARE_FOR_SUBMISSION"}).get("data", [])
    return versions[0] if versions else None


def default_experience(asc, clip: str, config: dict, review_urls: list[str], apply: bool) -> None:
    version = editable_version(asc)
    if version is None:
        print("SKIP     default experience: no editable iOS version (the Release workflow makes one)")
        return
    label = f"{version['attributes']['versionString']}"
    existing = asc.req("GET", f"{asc.API}/appStoreVersions/{version['id']}/appClipDefaultExperience").get("data")
    if existing is None:
        if not apply:
            print(f"would create the default experience on {label} ({config['action']}, \"{config['subtitle']}\")")
            return
        existing = asc.req("POST", f"{asc.API}/appClipDefaultExperiences", json={"data": {
            "type": "appClipDefaultExperiences",
            "attributes": {"action": config["action"]},
            "relationships": {
                "appClip": {"data": {"type": "appClips", "id": clip}},
                "releaseWithAppStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
            },
        }})["data"]
        print(f"created the default experience on {label}")
    else:
        print(f"OK       default experience on {label}")
        if existing["attributes"].get("action") != config["action"]:
            if apply:
                asc.req("PATCH", f"{asc.API}/appClipDefaultExperiences/{existing['id']}", json={"data": {
                    "type": "appClipDefaultExperiences", "id": existing["id"],
                    "attributes": {"action": config["action"]}}})
                print(f"    set its action to {config['action']}")
            else:
                print(f"    would set its action to {config['action']}")

    locs = asc.req("GET", f"{asc.API}/appClipDefaultExperiences/{existing['id']}"
                          "/appClipDefaultExperienceLocalizations").get("data", [])
    loc = next((l for l in locs if l["attributes"]["locale"] == config["locale"]), None)
    if loc is None:
        if not apply:
            print(f"    would add the {config['locale']} subtitle")
            return
        loc = asc.req("POST", f"{asc.API}/appClipDefaultExperienceLocalizations", json={"data": {
            "type": "appClipDefaultExperienceLocalizations",
            "attributes": {"locale": config["locale"], "subtitle": config["subtitle"]},
            "relationships": {"appClipDefaultExperience": {
                "data": {"type": "appClipDefaultExperiences", "id": existing["id"]}}},
        }})["data"]
        print(f"    added the {config['locale']} subtitle")
    elif loc["attributes"].get("subtitle") != config["subtitle"]:
        if apply:
            asc.req("PATCH", f"{asc.API}/appClipDefaultExperienceLocalizations/{loc['id']}", json={"data": {
                "type": "appClipDefaultExperienceLocalizations", "id": loc["id"],
                "attributes": {"subtitle": config["subtitle"]}}})
            print(f"    updated the {config['locale']} subtitle")
        else:
            print(f"    would update the {config['locale']} subtitle")

    image = asc.req("GET", f"{asc.API}/appClipDefaultExperienceLocalizations/{loc['id']}"
                           "/relationships/appClipHeaderImage").get("data")
    if image is None:
        if apply:
            upload_image(asc, "appClipHeaderImages", {}, {"appClipDefaultExperienceLocalization": {
                "data": {"type": "appClipDefaultExperienceLocalizations", "id": loc["id"]}}})
        else:
            print("    would upload the card image")

    if review_urls:
        detail = asc.req("GET", f"{asc.API}/appClipDefaultExperiences/{existing['id']}"
                                "/appClipAppStoreReviewDetail").get("data")
        attrs = {"invocationUrls": review_urls}
        if not apply:
            print(f"    would set App Review's invocation URLs: {', '.join(review_urls)}")
        elif detail is None:
            asc.req("POST", f"{asc.API}/appClipAppStoreReviewDetails", json={"data": {
                "type": "appClipAppStoreReviewDetails", "attributes": attrs,
                "relationships": {"appClipDefaultExperience": {
                    "data": {"type": "appClipDefaultExperiences", "id": existing["id"]}}}}})
            print("    set App Review's invocation URLs")
        elif detail["attributes"].get("invocationUrls") != review_urls:
            asc.req("PATCH", f"{asc.API}/appClipAppStoreReviewDetails/{detail['id']}", json={"data": {
                "type": "appClipAppStoreReviewDetails", "id": detail["id"], "attributes": attrs}})
            print("    updated App Review's invocation URLs")


def advanced_experiences(asc, clip: str, configs: list[dict], apply: bool) -> None:
    existing = asc.req("GET", f"{asc.API}/appClips/{clip}/appClipAdvancedExperiences",
                       params={"limit": 200}).get("data", [])
    by_link = {e["attributes"].get("link"): e for e in existing}
    for config in configs:
        found = by_link.get(config["link"])
        if found is not None:
            # Edits to a live experience go through Apple's review of it;
            # change the copy here and in App Store Connect together.
            print(f"OK       advanced experience {config['link']} ({found['attributes'].get('status')})")
            continue
        if not apply:
            print(f"would create the advanced experience {config['link']}")
            continue
        image = upload_image(asc, "appClipAdvancedExperienceImages", {}, None)
        locals_ = [{"type": "appClipAdvancedExperienceLocalizations", "id": f"${{local-{i}}}",
                    "attributes": loc} for i, loc in enumerate(config["localizations"])]
        attrs = {k: config[k] for k in ("link", "action", "businessCategory", "defaultLanguage", "isPoweredBy")}
        asc.req("POST", f"{asc.API}/appClipAdvancedExperiences", json={
            "data": {
                "type": "appClipAdvancedExperiences",
                "attributes": attrs,
                "relationships": {
                    "appClip": {"data": {"type": "appClips", "id": clip}},
                    "headerImage": {"data": {"type": "appClipAdvancedExperienceImages", "id": image}},
                    "localizations": {"data": [{"type": l["type"], "id": l["id"]} for l in locals_]},
                },
            },
            "included": locals_,
        })
        print(f"created the advanced experience {config['link']}")


def experiences(apply: bool) -> None:
    asc = api()
    config = json.loads(CONFIG.read_text())
    clip_bundle = bundle_ids()[CLIP_TARGET]
    clip = app_clip_id(asc, clip_bundle)
    if clip is None:
        sys.exit(f"App Store Connect has no App Clip {clip_bundle} yet: it appears once a build "
                 "with the clip is uploaded (the Release workflow)")
    default_experience(asc, clip, config["default"], config.get("reviewInvocationUrls", []), apply)
    advanced_experiences(asc, clip, config.get("advanced", []), apply)


def main() -> None:
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    command, rest = args[0], args[1:]
    apply = "--apply" in rest
    if command == "aasa":
        if "--check" in rest:
            check()
        elif "--team" in rest and rest.index("--team") + 1 < len(rest):
            write_aasa(rest[rest.index("--team") + 1])
        else:
            sys.exit("aasa needs --check or --team TEAMID")
    elif command == "identifiers":
        identifiers(apply)
    elif command == "experiences":
        experiences(apply)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
