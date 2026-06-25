#!/usr/bin/env python3
"""
CLI Pulse v1.32.2 — ASC metadata + submit (maintenance / R0 groundwork, gated-OFF).

Copy of submit_v1_31_0.py (same proven, idempotent ASC API flow). Only
TARGET_VERSION / TARGET_BUILD / WHATS_NEW_* / REVIEW_NOTES changed.

v1.32.2 bundles: the macOS managed-session terminal 1:1 train, the
Gemini/Antigravity per-model quota collector, the watchOS per-provider ring
colors + legend, and iOS pre-release fixes (high-risk swarm-approval gating,
OAuth anchor robustness).

Per platform (iOS + macOS), idempotent / safe to re-run:
  1. (prep) Cancel any WAITING_FOR_REVIEW / IN_REVIEW submission so
     versions become editable.
  2. (prep) Find/rename/create an editable 1.32.2 appStoreVersion.
  3. (prep) Wait for build 81 -> processingState=VALID, then bind it.
  4. (prep) PATCH whatsNew for en-US, zh-Hans, ja, ko, es-ES.
  5. (prep) Set App Review notes.
  6. (submit) Create reviewSubmission + item, PATCH submitted=true.

Usage:
  submit_v1_32_2.py prep   [IOS MAC_OS]   # steps 1-5, no submit
  submit_v1_32_2.py submit [IOS MAC_OS]   # step 6 only
  submit_v1_32_2.py all    [IOS MAC_OS]   # 1-6
"""
import jwt
import time
import requests
import os
import sys

API_KEY_ID = "DMMFP6XTXX"
API_ISSUER = "c5671c11-49ec-47d9-bd38-5e3c1a249416"
API_KEY_PATH = os.path.expanduser(
    "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_DMMFP6XTXX.p8"
)
APP_ID = "6761163709"
BASE = "https://api.appstoreconnect.apple.com/v1"

TARGET_VERSION = "1.32.2"
TARGET_BUILD = "81"

# v1.32.2 What's New per locale. No backticks anywhere — Apple's What's
# New field rejects them per feedback_asc_release_workflow.

WHATS_NEW_EN = """v1.32.2

- Under-the-hood reliability improvements and groundwork for upcoming features.
- Fixes and refinements throughout."""

WHATS_NEW_ZH_HANS = """v1.32.2

- 底层可靠性优化,并为即将推出的功能打好基础。
- 多项修复与优化。"""

WHATS_NEW_JA = """v1.32.2

- 内部の信頼性を改善し、今後の機能に向けた基盤を整えました。
- その他の修正と改善。"""

WHATS_NEW_KO = """v1.32.2

- 내부 안정성을 개선하고 향후 기능을 위한 기반을 마련했습니다.
- 여러 수정 및 개선."""

WHATS_NEW_ES_ES = """v1.32.2

- Mejoras internas de fiabilidad y preparación para próximas funciones.
- Correcciones y mejoras en general."""

WHATS_NEW_BY_LOCALE = {
    "en-US":   WHATS_NEW_EN,
    "zh-Hans": WHATS_NEW_ZH_HANS,
    "ja":      WHATS_NEW_JA,
    "ko":      WHATS_NEW_KO,
    "es-ES":   WHATS_NEW_ES_ES,
}

# App Review notes — v1.32.2.
REVIEW_NOTES = (
    "This is a maintenance update: under-the-hood reliability improvements and "
    "internal groundwork for an upcoming secure remote-terminal feature that is "
    "NOT yet user-visible (disabled by default; it changes no current behavior). "
    "No new entitlements, background modes, or capabilities were added. No demo "
    "account or special hardware is required to review; on Mac the app also works "
    "in local mode without an account. Externally it behaves like the approved "
    "prior version. Thank you for the review."
)

with open(API_KEY_PATH) as f:
    _KEY = f.read()


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": API_ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        _KEY, algorithm="ES256", headers={"kid": API_KEY_ID},
    )


def hdr():
    return {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}


def req(method, path, data=None):
    fn = {"get": requests.get, "post": requests.post, "patch": requests.patch}[method]
    r = fn(f"{BASE}{path}", headers=hdr(), json=data)
    if r.status_code >= 400:
        print(f"  {method.upper()} {path} -> {r.status_code}")
        try:
            for e in r.json().get("errors", []):
                print(f"    {e.get('title')}: {e.get('detail')}")
        except Exception:
            print(f"    {r.text[:400]}")
        return None
    return r.json() if r.content else {}


def get(path): return req("get", path)
def post(path, data): return req("post", path, data)
def patch(path, data): return req("patch", path, data)


# ─── 1. Cancel WAITING_FOR_REVIEW submissions so we can edit versions ────
def cancel_pending_reviews():
    print("[1] Cancelling any WAITING_FOR_REVIEW / IN_REVIEW submissions...")
    r = get(f"/apps/{APP_ID}/reviewSubmissions") or {}
    for sub in r.get("data", []):
        state = sub["attributes"]["state"]
        sub_id = sub["id"]
        plat = sub["attributes"].get("platform", "?")
        print(f"   submission {sub_id} platform={plat} state={state}")
        if state in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
            resp = patch(f"/reviewSubmissions/{sub_id}", {
                "data": {"type": "reviewSubmissions", "id": sub_id,
                         "attributes": {"canceled": True}}
            })
            if resp is not None:
                print(f"   canceled {sub_id}")


# ─── 2. Find or create an editable 1.32.2 appStoreVersion per platform ───
def ensure_version(platform_label):
    print(f"\n[2] Ensuring {platform_label} appStoreVersion = {TARGET_VERSION}...")
    r = get(f"/apps/{APP_ID}/appStoreVersions?filter[platform]={platform_label}&limit=10") or {}

    editable_states = {
        "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
        "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_EXPORT_COMPLIANCE",
        "DEVELOPER_REMOVED_FROM_SALE"
    }

    for v in r.get("data", []):
        vs = v["attributes"]["versionString"]
        state = v["attributes"]["appStoreState"]
        if vs == TARGET_VERSION:
            print(f"   found existing {TARGET_VERSION} id={v['id']} state={state}")
            return v["id"], vs

    for v in r.get("data", []):
        vs = v["attributes"]["versionString"]
        state = v["attributes"]["appStoreState"]
        if state in editable_states:
            print(f"   renaming editable version {vs} (state={state}) -> {TARGET_VERSION}")
            upd = patch(f"/appStoreVersions/{v['id']}", {
                "data": {"type": "appStoreVersions", "id": v["id"],
                         "attributes": {"versionString": TARGET_VERSION}}
            })
            if upd is not None:
                return v["id"], vs

    print(f"   creating a new {TARGET_VERSION} version")
    resp = post("/appStoreVersions", {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": platform_label, "versionString": TARGET_VERSION,
                           "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}
        }
    })
    if resp is None:
        print(f"   !! could not create {TARGET_VERSION} on {platform_label}")
        return None, None
    return resp["data"]["id"], None


# ─── 3. Wait for build 81 to be VALID, then bind it ──────────────────────
def bind_build(version_id, platform_label):
    print(f"\n[3] Binding build {TARGET_BUILD} to {platform_label}...")
    for attempt in range(40):  # ~20 min
        r = get(f"/builds?filter[app]={APP_ID}&filter[preReleaseVersion.platform]={platform_label}&sort=-uploadedDate&limit=10") or {}
        found = None
        states = []
        for b in r.get("data", []):
            bv = b["attributes"].get("version")
            proc = b["attributes"].get("processingState")
            states.append(f"{bv}/{proc}")
            if bv == TARGET_BUILD and proc == "VALID":
                found = b["id"]
                break
        if found:
            upd = patch(f"/appStoreVersions/{version_id}", {
                "data": {"type": "appStoreVersions", "id": version_id,
                         "relationships": {"build": {"data": {"type": "builds", "id": found}}}}
            })
            if upd is not None:
                print(f"   bound build {found}")
                return True
            print(f"   !! bind failed on build {found}")
            return False
        print(f"   waiting for build {TARGET_BUILD} to process... ({attempt+1}/40) seen={states[:5]}")
        time.sleep(30)
    print(f"   !! build {TARGET_BUILD} never reached VALID on {platform_label}")
    return False


# ─── 4. Patch whatsNew across every configured locale ───────────────────
def patch_whats_new(version_id, platform_label):
    print(f"\n[4] Patching {platform_label} whatsNew (multi-locale)...")
    r = get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations") or {}
    locs_seen, locs_patched, locs_unmapped = [], [], []
    for loc in r.get("data", []):
        code = loc["attributes"]["locale"]
        locs_seen.append(code)
        notes = WHATS_NEW_BY_LOCALE.get(code)
        if notes is None:
            locs_unmapped.append(code)
            continue
        upd = patch(f"/appStoreVersionLocalizations/{loc['id']}", {
            "data": {"type": "appStoreVersionLocalizations", "id": loc["id"],
                     "attributes": {"whatsNew": notes}}
        })
        if upd is not None:
            locs_patched.append(code)
            print(f"   whatsNew set on {code} (loc {loc['id']})")
    print(f"   summary: patched={locs_patched} unmapped={locs_unmapped} seen={locs_seen}")
    if "en-US" not in locs_patched:
        print("   !! en-US whatsNew patch did not succeed")
        return False
    return True


# ─── 5. Set App Review notes ─────────────────────────────────────────────
def set_review_notes(version_id, platform_label):
    print(f"\n[5] Setting {platform_label} App Review notes...")
    r = get(f"/appStoreVersions/{version_id}/appStoreReviewDetail") or {}
    detail = r.get("data")
    if detail:
        did = detail["id"]
        upd = patch(f"/appStoreReviewDetails/{did}", {
            "data": {"type": "appStoreReviewDetails", "id": did,
                     "attributes": {"notes": REVIEW_NOTES,
                                    "demoAccountRequired": False}}
        })
        if upd is not None:
            print(f"   notes patched on existing reviewDetail {did}")
            return True
        print("   !! patch of existing reviewDetail failed")
        return False
    resp = post("/appStoreReviewDetails", {
        "data": {"type": "appStoreReviewDetails",
                 "attributes": {"notes": REVIEW_NOTES, "demoAccountRequired": False},
                 "relationships": {"appStoreVersion": {
                     "data": {"type": "appStoreVersions", "id": version_id}}}}
    })
    if resp is not None:
        print("   created reviewDetail with notes")
        return True
    print("   !! could not set review notes (non-fatal — set via ASC UI if needed)")
    return False


# ─── 6. Submit for review ────────────────────────────────────────────────
def submit_for_review(platform_label, version_id):
    print(f"\n[6] Submitting {platform_label} for review...")
    existing = get(f"/apps/{APP_ID}/reviewSubmissions?filter[platform]={platform_label}") or {}
    sub_id = None
    for sub in existing.get("data", []):
        if sub["attributes"]["state"] == "READY_FOR_REVIEW":
            sub_id = sub["id"]
            print(f"   reusing READY_FOR_REVIEW submission {sub_id}")
            break
    if sub_id is None:
        resp = post("/reviewSubmissions", {
            "data": {"type": "reviewSubmissions",
                     "attributes": {"platform": platform_label},
                     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}
        })
        if resp is None:
            return False
        sub_id = resp["data"]["id"]
        print(f"   created submission {sub_id}")

    items = get(f"/reviewSubmissions/{sub_id}/items") or {}
    already = any(
        (it.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") == version_id
        for it in items.get("data", [])
    )
    if not already:
        resp = post("/reviewSubmissionItems", {
            "data": {"type": "reviewSubmissionItems",
                     "relationships": {
                         "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                         "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}
        })
        if resp is None:
            return False
        print(f"   added version {version_id} to submission")

    resp = patch(f"/reviewSubmissions/{sub_id}", {
        "data": {"type": "reviewSubmissions", "id": sub_id,
                 "attributes": {"submitted": True}}
    })
    if resp is None:
        return False
    print(f"   submitted {sub_id} for review")
    return True


# ─── main ────────────────────────────────────────────────────────────────
def main():
    mode = (sys.argv[1] if len(sys.argv) > 1 else "all").lower()
    if mode not in ("prep", "submit", "all"):
        print("Usage: submit_v1_32_2.py [prep|submit|all] [IOS MAC_OS]")
        sys.exit(1)
    platforms = sys.argv[2:] or ["IOS", "MAC_OS"]
    print(f"== CLI Pulse {TARGET_VERSION} build {TARGET_BUILD} ASC {mode} ==")
    print(f"   platforms: {platforms}")

    r = get(f"/apps/{APP_ID}")
    if not r:
        print("!! cannot reach App Store Connect")
        sys.exit(1)
    print(f"   app: {r['data']['attributes']['name']}")

    if mode in ("prep", "all"):
        cancel_pending_reviews()
        time.sleep(5)

    failures = []
    for plat in platforms:
        print(f"\n=== {plat} ===")
        vid, _ = ensure_version(plat)
        if vid is None:
            failures.append(f"{plat}: no version")
            continue
        if mode in ("prep", "all"):
            if not bind_build(vid, plat):
                failures.append(f"{plat}: build bind failed")
                continue
            if not patch_whats_new(vid, plat):
                failures.append(f"{plat}: whatsNew patch failed (continuing)")
            if not set_review_notes(vid, plat):
                failures.append(f"{plat}: review-notes set failed (continuing)")
        if mode in ("submit", "all"):
            if not submit_for_review(plat, vid):
                failures.append(f"{plat}: submit failed")

    print("\n=== Done ===")
    if failures:
        for f in failures:
            print(f"   !! {f}")
        sys.exit(2)
    print(f"   {mode}: all platforms OK")


if __name__ == "__main__":
    main()
