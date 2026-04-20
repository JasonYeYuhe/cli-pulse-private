#!/usr/bin/env python3
"""Focused submission prep for iOS v1.9.2.

Does:
  1. Binds build 30 to the iOS v1.9.2 App Store version.
  2. Updates the en-US "What's New" text.
  3. Uploads the 5 composed iPad Pro 13" screenshots to APP_IPAD_PRO_3GEN_129.

Does NOT:
  - Submit for review (macOS v1.9.2 is already in review; per memory, IAP
    binding requires the ASC web UI).
  - Touch iPhone screenshots (already uploaded).
  - Touch app description / keywords (unchanged).
"""

from __future__ import annotations
import hashlib
import os
import sys
import time
from pathlib import Path

import jwt
import requests

API_KEY_ID = "DMMFP6XTXX"
API_ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
API_KEY_PATH = os.path.expanduser(
    "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8"
)
APP_ID = "6761163709"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

IOS_VERSION_ID = "c3e5321e-a70d-49a7-829c-05a6a27942d4"  # v1.9.2 PREPARE_FOR_SUBMISSION
BUILD_ID = "41aaea27-4584-4711-ac32-482ed35eff43"         # build 30, VALID

WHATS_NEW = (
    "Ask Siri for your CLI usage. Tap the widget to refresh. "
    "Richer iPad dashboard that scales to every screen size."
)

REPO = Path(__file__).resolve().parent.parent
IPAD_DIR = REPO / "screenshots" / "ipad" / "composed"


def token() -> str:
    with open(API_KEY_PATH) as f:
        pk = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": API_ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        pk,
        algorithm="ES256",
        headers={"kid": API_KEY_ID},
    )


def H():
    return {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}


def get(path):
    r = requests.get(f"{BASE_URL}{path}", headers=H())
    if r.status_code >= 400:
        print(f"  GET {path} -> {r.status_code}: {r.text[:400]}")
    r.raise_for_status()
    return r.json()


def post(path, data, ok404=False):
    r = requests.post(f"{BASE_URL}{path}", headers=H(), json=data)
    if r.status_code >= 400:
        print(f"  POST {path} -> {r.status_code}")
        print(f"  {r.text[:600]}")
        if not ok404:
            r.raise_for_status()
        return None
    return r.json()


def patch(path, data):
    r = requests.patch(f"{BASE_URL}{path}", headers=H(), json=data)
    if r.status_code >= 400:
        print(f"  PATCH {path} -> {r.status_code}")
        print(f"  {r.text[:600]}")
        r.raise_for_status()
    return r.json() if r.text else {}


def delete(path):
    r = requests.delete(f"{BASE_URL}{path}", headers=H())
    return r.status_code


# --- Step 1: bind build -----------------------------------------------------

def bind_build():
    print("\n[1/3] Binding build 30 to iOS v1.9.2 …")
    # Check current binding
    r = get(f"/appStoreVersions/{IOS_VERSION_ID}/relationships/build")
    current = r.get("data")
    if current and current.get("id") == BUILD_ID:
        print("  Already bound. Skipping.")
        return
    patch(
        f"/appStoreVersions/{IOS_VERSION_ID}/relationships/build",
        {"data": {"type": "builds", "id": BUILD_ID}},
    )
    print(f"  Bound build {BUILD_ID}.")


# --- Step 2: What's New -----------------------------------------------------

def update_whats_new():
    print("\n[2/3] Updating en-US What's New …")
    r = get(f"/appStoreVersions/{IOS_VERSION_ID}/appStoreVersionLocalizations")
    locs = r.get("data", [])
    en_id = None
    for loc in locs:
        if loc["attributes"]["locale"] == "en-US":
            en_id = loc["id"]
            break
    if not en_id:
        print("  No en-US localization found — creating.")
        r = post(
            "/appStoreVersionLocalizations",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {"locale": "en-US", "whatsNew": WHATS_NEW},
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": IOS_VERSION_ID}
                        }
                    },
                }
            },
        )
        en_id = r["data"]["id"]
    else:
        patch(
            f"/appStoreVersionLocalizations/{en_id}",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": en_id,
                    "attributes": {"whatsNew": WHATS_NEW},
                }
            },
        )
    print(f"  en-US localization {en_id} now has What's New.")
    return en_id


# --- Step 3: iPad screenshots -----------------------------------------------

def upload_ipad_screenshots(en_loc_id: str):
    files = sorted(IPAD_DIR.glob("*.png"))
    if not files:
        print(f"  No iPad screenshots in {IPAD_DIR}. Skipping.")
        return
    print(f"\n[3/3] Uploading {len(files)} iPad Pro 13\" screenshots …")
    display_type = "APP_IPAD_PRO_3GEN_129"

    # Locate or create the screenshot set
    r = get(f"/appStoreVersionLocalizations/{en_loc_id}/appScreenshotSets")
    sets = r.get("data", [])
    set_id = None
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == display_type:
            set_id = s["id"]
            break
    if set_id:
        # Clear existing so we start clean
        r = get(f"/appScreenshotSets/{set_id}/appScreenshots")
        for ss in r.get("data", []):
            code = delete(f"/appScreenshots/{ss['id']}")
            if code >= 400:
                print(f"  Could not delete existing screenshot {ss['id']} ({code})")
        print(f"  Reusing existing set {set_id} (cleared).")
    else:
        r = post(
            "/appScreenshotSets",
            {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": display_type},
                    "relationships": {
                        "appStoreVersionLocalization": {
                            "data": {
                                "type": "appStoreVersionLocalizations",
                                "id": en_loc_id,
                            }
                        }
                    },
                }
            },
        )
        set_id = r["data"]["id"]
        print(f"  Created set {set_id}.")

    for i, fp in enumerate(files, 1):
        data = fp.read_bytes()
        size = len(data)
        checksum = hashlib.md5(data).hexdigest()
        print(f"  [{i}/{len(files)}] Reserving {fp.name} ({size} bytes)…")
        r = post(
            "/appScreenshots",
            {
                "data": {
                    "type": "appScreenshots",
                    "attributes": {"fileName": fp.name, "fileSize": size},
                    "relationships": {
                        "appScreenshotSet": {
                            "data": {"type": "appScreenshotSets", "id": set_id}
                        }
                    },
                }
            },
        )
        ss_id = r["data"]["id"]
        ops = r["data"]["attributes"].get("uploadOperations", [])
        for op in ops:
            url = op["url"]
            hdrs = {h["name"]: h["value"] for h in op["requestHeaders"]}
            chunk = data[op["offset"] : op["offset"] + op["length"]]
            up = requests.put(url, headers=hdrs, data=chunk)
            if up.status_code >= 400:
                print(f"    Chunk upload failed: {up.status_code} {up.text[:200]}")
        patch(
            f"/appScreenshots/{ss_id}",
            {
                "data": {
                    "type": "appScreenshots",
                    "id": ss_id,
                    "attributes": {"uploaded": True, "sourceFileChecksum": checksum},
                }
            },
        )
        print(f"    Committed {fp.name}")
    print(f"  {len(files)} iPad screenshots uploaded.")


def main():
    # Sanity: confirm version + build exist and have expected state
    v = get(f"/appStoreVersions/{IOS_VERSION_ID}")["data"]["attributes"]
    b = get(f"/builds/{BUILD_ID}")["data"]["attributes"]
    print(f"Version: v{v['versionString']} [{v['appStoreState']}]")
    print(
        f"Build:   #{b['version']} [{b['processingState']}] "
        f"valid={b.get('valid')} expired={b.get('expired')}"
    )
    if b.get("processingState") != "VALID":
        print("Build not VALID yet — aborting.")
        sys.exit(1)

    bind_build()
    en_id = update_whats_new()
    upload_ipad_screenshots(en_id)

    print("\nDone.")
    print("Next (manual, web UI):")
    print(
        "  1. Open https://appstoreconnect.apple.com/apps/6761163709/appstore/ios/version/inflight"
    )
    print("  2. Verify IAP/subscription bindings are present.")
    print("  3. Click 'Add for Review' → Submit.")


if __name__ == "__main__":
    main()
