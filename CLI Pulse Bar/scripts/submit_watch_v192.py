#!/usr/bin/env python3
"""Upload 5 native Apple Watch Ultra screenshots to iOS v1.9.2 en-US.

ASC accepts Watch screenshots at several device-native sizes (422x514 for
Ultra 3, 410x502 for Ultra/Ultra 2, 416x496 for Series 11, ...). They all go
into one screenshot set — we try APP_WATCH_ULTRA first (works for both Ultra
and Ultra 3 sources), then fall back to other known Watch display types if
the set creation is rejected.
"""
from __future__ import annotations
import hashlib, sys, os
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from submit_ios_v192 import get, post, patch, delete, IOS_VERSION_ID, requests, H  # reuse helpers

REPO = Path(__file__).resolve().parent.parent
WATCH_DIR = REPO / "screenshots" / "watch" / "composed"

# In priority order — the first type that ASC accepts wins.
CANDIDATE_DISPLAY_TYPES = [
    "APP_WATCH_ULTRA",
    "APP_WATCH_SERIES_10",
    "APP_WATCH_SERIES_7",
    "APP_WATCH_SERIES_4",
]


def find_en_loc() -> str:
    r = get(f"/appStoreVersions/{IOS_VERSION_ID}/appStoreVersionLocalizations")
    for loc in r.get("data", []):
        if loc["attributes"]["locale"] == "en-US":
            return loc["id"]
    raise RuntimeError("No en-US localization found for v1.9.2")


def clear_all_watch_sets(en_loc_id: str):
    r = get(f"/appStoreVersionLocalizations/{en_loc_id}/appScreenshotSets")
    for s in r.get("data", []):
        dt = s["attributes"]["screenshotDisplayType"]
        if dt.startswith("APP_WATCH"):
            print(f"  Clearing existing set {dt} ({s['id']})…")
            scrs = get(f"/appScreenshotSets/{s['id']}/appScreenshots").get("data", [])
            for sc in scrs:
                delete(f"/appScreenshots/{sc['id']}")
            delete(f"/appScreenshotSets/{s['id']}")


def create_set(en_loc_id: str, display_type: str):
    """Try to create a screenshot set for the given display type."""
    r = requests.post(
        "https://api.appstoreconnect.apple.com/v1/appScreenshotSets",
        headers=H(),
        json={
            "data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": en_loc_id}
                    }
                },
            }
        },
    )
    if r.status_code >= 400:
        return None, r.text[:400]
    return r.json()["data"]["id"], None


def upload_one(set_id: str, fp: Path):
    data = fp.read_bytes()
    size = len(data)
    checksum = hashlib.md5(data).hexdigest()
    print(f"  Reserving {fp.name} ({size} bytes)…")
    r = post(
        "/appScreenshots",
        {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": fp.name, "fileSize": size},
                "relationships": {
                    "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}
                },
            }
        },
    )
    if r is None:
        return False
    ss_id = r["data"]["id"]
    for op in r["data"]["attributes"].get("uploadOperations", []):
        url = op["url"]
        hdrs = {h["name"]: h["value"] for h in op["requestHeaders"]}
        chunk = data[op["offset"] : op["offset"] + op["length"]]
        up = requests.put(url, headers=hdrs, data=chunk)
        if up.status_code >= 400:
            print(f"    Chunk fail {up.status_code}: {up.text[:200]}")
            return False
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
    return True


def main():
    files = sorted(WATCH_DIR.glob("*.png"))
    if not files:
        print(f"No screenshots in {WATCH_DIR}")
        sys.exit(1)
    print(f"Found {len(files)} Watch screenshots")

    en_loc = find_en_loc()
    print(f"en-US loc: {en_loc}")
    clear_all_watch_sets(en_loc)

    set_id = None
    for dt in CANDIDATE_DISPLAY_TYPES:
        print(f"\nTrying display type {dt}…")
        sid, err = create_set(en_loc, dt)
        if sid:
            set_id = sid
            print(f"  Created set {sid} ({dt})")
            break
        print(f"  Rejected: {err}")

    if not set_id:
        print("No Watch display type accepted. Abort.")
        sys.exit(1)

    all_ok = True
    for fp in files:
        if not upload_one(set_id, fp):
            all_ok = False

    if all_ok:
        print(f"\nDone. {len(files)} Watch screenshots uploaded.")
    else:
        print("\nSome uploads failed — check ASC web UI.")


if __name__ == "__main__":
    main()
