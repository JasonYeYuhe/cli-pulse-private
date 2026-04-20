#!/usr/bin/env python3
"""Create a reviewSubmission for iOS v1.9.2 and trigger submission
(equivalent to clicking "Add for Review" → "Submit to App Review" in the
ASC web UI).

Preconditions (verified manually before running):
  - All 4 subscriptions are APPROVED (already live from 1.9.1), so no IAP
    binding needs the web UI this cycle.
  - Build 30 is bound, What's New / all screenshots are in place.
"""
from __future__ import annotations
import sys, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from submit_ios_v192 import get, post, patch, APP_ID, IOS_VERSION_ID, requests, H, BASE_URL


def create_review_submission() -> str:
    print("Creating reviewSubmission (platform=IOS)…")
    r = post(
        "/reviewSubmissions",
        {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": "IOS"},
                "relationships": {
                    "app": {"data": {"type": "apps", "id": APP_ID}}
                },
            }
        },
    )
    rs_id = r["data"]["id"]
    print(f"  Created {rs_id} state={r['data']['attributes'].get('state')}")
    return rs_id


def add_item(rs_id: str) -> str:
    print("Adding appStoreVersion item…")
    r = post(
        "/reviewSubmissionItems",
        {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {
                        "data": {"type": "reviewSubmissions", "id": rs_id}
                    },
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": IOS_VERSION_ID}
                    },
                },
            }
        },
    )
    item_id = r["data"]["id"]
    print(f"  Added item {item_id}")
    return item_id


def submit(rs_id: str):
    print("Submitting for review…")
    # PATCH with submitted=true flips the state to SUBMITTED/WAITING_FOR_REVIEW.
    r = requests.patch(
        f"{BASE_URL}/reviewSubmissions/{rs_id}",
        headers=H(),
        json={
            "data": {
                "type": "reviewSubmissions",
                "id": rs_id,
                "attributes": {"submitted": True},
            }
        },
    )
    if r.status_code >= 400:
        print(f"  PATCH failed {r.status_code}: {r.text[:800]}")
        sys.exit(1)
    state = r.json()["data"]["attributes"].get("state")
    print(f"  Submission state: {state}")


def main():
    # Last-second sanity check
    v = get(f"/appStoreVersions/{IOS_VERSION_ID}")["data"]["attributes"]
    if v["appStoreState"] != "PREPARE_FOR_SUBMISSION":
        print(f"Version not ready: state={v['appStoreState']}")
        sys.exit(1)

    rs_id = create_review_submission()
    add_item(rs_id)
    submit(rs_id)

    # Re-read to confirm
    v = get(f"/appStoreVersions/{IOS_VERSION_ID}")["data"]["attributes"]
    print(f"\nFinal appStoreVersion state: {v['appStoreState']}")
    print("Done.")


if __name__ == "__main__":
    main()
