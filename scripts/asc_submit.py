#!/usr/bin/env python3
"""App Store Connect: attach an uploaded build to an app-store version and
submit it for review — for BOTH platforms (IOS + MAC_OS).

Promoted from the throwaway /tmp/asc_lib.py + /tmp/asc_submit.py pattern into a
committed, parameterized tool (DEV_PLAN_2026-07-02 §S6). Self-contained: no
/tmp side-files.

PREREQ (per [[feedback_asc_icloud_key_tcc]]): the ASC API .p8 key must live at
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
NOT on iCloud Drive — a headless/background process is TCC-denied there. The
KEY_ID / ISSUER / APP_ID below are identifiers, not secrets; only the .p8 is.

The build must already be UPLOADED and finished processing (processingState=
VALID). iOS processing can lag ~1 h after `build-appstore.sh … --upload`; poll
`--list-builds ios` until the target build shows VALID before submitting.

Usage:
  # list processed builds for a platform (find the build id to submit):
  python3 scripts/asc_submit.py --list-builds ios
  python3 scripts/asc_submit.py --list-builds macos

  # submit a specific build for review (whatsNew from a file):
  python3 scripts/asc_submit.py --submit ios   --build <BUILD_ID> --version 1.37.0 --whatsnew whatsnew_137.txt
  python3 scripts/asc_submit.py --submit macos --build <BUILD_ID> --version 1.37.0 --whatsnew whatsnew_137.txt

Exit 0 on success; non-zero on any API failure (prints the ASC error body).
"""
from __future__ import annotations

import argparse
import os
import sys
import time

try:
    import jwt  # PyJWT
    import requests
except ImportError:
    sys.exit("pip install pyjwt requests  (needed for the ASC API)")

KEY_ID = "DMMFP6XTXX"
ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
APP_ID = "6761163709"
BASE = "https://api.appstoreconnect.apple.com/v1"

# Platform tokens the ASC API expects.
PLATFORMS = {"ios": "IOS", "macos": "MAC_OS"}


def _key_path() -> str:
    candidates = [
        os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"),
        # legacy fallback — TCC-denied headless, but allow interactive runs.
        os.path.expanduser(
            f"~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_{KEY_ID}.p8"
        ),
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    sys.exit(
        f"ASC key not found. Place AuthKey_{KEY_ID}.p8 at "
        f"~/.appstoreconnect/private_keys/ (NOT iCloud — TCC-denied headless)."
    )


def _token() -> str:
    key = open(_key_path()).read()
    return jwt.encode(
        {"iss": ISSUER, "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def _headers() -> dict[str, str]:
    return {"Authorization": "Bearer " + _token(), "Content-Type": "application/json"}


def _get(path: str) -> dict:
    r = requests.get(BASE + path, headers=_headers(), timeout=30)
    if r.status_code >= 300:
        # Fail LOUDLY — a silent {} here made --list-builds print nothing and
        # exit 0 on auth/API failures (2026-07-03 review).
        sys.exit(f"ASC GET {path} failed {r.status_code}: {r.text[:400]}")
    return r.json()


def _post(path: str, body: dict):
    return requests.post(BASE + path, headers=_headers(), json=body, timeout=30)


def _patch(path: str, body: dict):
    return requests.patch(BASE + path, headers=_headers(), json=body, timeout=30)


def list_builds(platform_key: str) -> None:
    plat = PLATFORMS[platform_key]
    r = _get(
        f"/builds?filter[app]={APP_ID}&filter[preReleaseVersion.platform]={plat}"
        f"&sort=-uploadedDate&limit=10"
        f"&fields[builds]=version,processingState,uploadedDate"
    )
    for b in r.get("data", []):
        a = b.get("attributes", {})
        print(f"{b['id']}  build {a.get('version')}  {a.get('processingState')}  {a.get('uploadedDate')}")


def submit(platform_key: str, build_id: str, version: str, whatsnew: str) -> bool:
    plat = PLATFORMS[platform_key]
    # 1. find-or-create the appStoreVersion row for this version+platform.
    r = _get(
        f"/apps/{APP_ID}/appStoreVersions"
        f"?filter[platform]={plat}&filter[versionString]={version}"
    )
    vs = r.get("data", [])
    if vs:
        ver_id = vs[0]["id"]
        print(f"[{plat}] reuse version {ver_id} state={vs[0]['attributes']['appStoreState']}")
    else:
        cr = _post(
            "/appStoreVersions",
            {"data": {"type": "appStoreVersions",
                      "attributes": {"platform": plat, "versionString": version,
                                     "releaseType": "AFTER_APPROVAL"},
                      "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}},
        )
        if cr.status_code >= 300:
            print(f"[{plat}] CREATE version FAILED {cr.status_code}: {cr.text[:400]}")
            return False
        ver_id = cr.json()["data"]["id"]
        print(f"[{plat}] created version {ver_id}")

    # 2. set whatsNew on every localization.
    for loc in _get(f"/appStoreVersions/{ver_id}/appStoreVersionLocalizations").get("data", []):
        lid = loc["id"]
        pr = _patch(
            f"/appStoreVersionLocalizations/{lid}",
            {"data": {"type": "appStoreVersionLocalizations", "id": lid,
                      "attributes": {"whatsNew": whatsnew}}},
        )
        print(f"[{plat}] whatsNew {loc['attributes']['locale']}: {pr.status_code}")

    # 3. attach the processed build.
    br = _patch(
        f"/appStoreVersions/{ver_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
    )
    print(f"[{plat}] attach build: {br.status_code} {'' if br.status_code < 300 else br.text[:300]}")
    if br.status_code >= 300:
        return False

    # 4. create a reviewSubmission, add the version as an item, submit.
    sr = _post(
        "/reviewSubmissions",
        {"data": {"type": "reviewSubmissions", "attributes": {"platform": plat},
                  "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}},
    )
    if sr.status_code >= 300:
        print(f"[{plat}] reviewSubmission FAILED {sr.status_code}: {sr.text[:400]}")
        return False
    sub_id = sr.json()["data"]["id"]
    ir = _post(
        "/reviewSubmissionItems",
        {"data": {"type": "reviewSubmissionItems",
                  "relationships": {
                      "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                      "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}},
    )
    print(f"[{plat}] add item: {ir.status_code} {'' if ir.status_code < 300 else ir.text[:300]}")
    if ir.status_code >= 300:
        # ASC allows only ONE open reviewSubmission per platform — a dangling
        # empty one would block every retry. Cancel it before bailing
        # (2026-07-03 review).
        cr2 = _patch(
            f"/reviewSubmissions/{sub_id}",
            {"data": {"type": "reviewSubmissions", "id": sub_id,
                      "attributes": {"canceled": True}}},
        )
        print(f"[{plat}] add-item failed — canceled dangling submission {sub_id}: {cr2.status_code}")
        return False
    fr = _patch(
        f"/reviewSubmissions/{sub_id}",
        {"data": {"type": "reviewSubmissions", "id": sub_id, "attributes": {"submitted": True}}},
    )
    ok = fr.status_code < 300
    print(f"[{plat}] SUBMIT: {fr.status_code} {'OK — submitted for review' if ok else fr.text[:400]}")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description="ASC attach-build + submit-for-review")
    ap.add_argument("--list-builds", choices=PLATFORMS.keys(), help="list recent builds for a platform")
    ap.add_argument("--submit", choices=PLATFORMS.keys(), help="submit a build for review")
    ap.add_argument("--build", help="build id (from --list-builds)")
    # No default on purpose: a hardcoded default silently attaches the next
    # train's build to the WRONG version row (2026-07-03 review).
    ap.add_argument("--version", help="marketing version string, e.g. 1.37.0")
    ap.add_argument("--whatsnew", help="path to a whatsNew text file")
    args = ap.parse_args()

    if args.list_builds:
        list_builds(args.list_builds)
        return 0
    if args.submit:
        if not args.build:
            return ap.error("--submit requires --build <BUILD_ID>")
        if not args.version:
            return ap.error("--submit requires --version <X.Y.Z>")
        whatsnew = ""
        if args.whatsnew:
            whatsnew = open(args.whatsnew).read().strip()
        if not whatsnew:
            return ap.error("--whatsnew <file> is required and must be non-empty")
        return 0 if submit(args.submit, args.build, args.version, whatsnew) else 1
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
