#!/usr/bin/env python3
"""
CLI Pulse v1.11.0 — ASC metadata + submit.

Adapted from submit_v1_10_8.py. Same idempotent ASC client — handles the
"version exists / WAITING_FOR_REVIEW / re-bind build" state machine.

v1.11.0 ships the iter1–iter20 series:
  - iter8: APNs push pre-auth + URL scheme registration
  - iter9: Google OAuth state fix, iOS sync gate drop, provider banner
  - iter10–iter19: pre-release polish (delete account inline, login
    escape, footer, mode picker, local mode, welcome mode-choice)
  - iter20: Remote Approvals follow-ups + decide idempotency

Backend migrate_v0.34 already applied separately. No edge function redeploy.

Safe to re-run: every step is idempotent against whatever state ASC is in.
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

TARGET_VERSION = "1.11.0"
TARGET_BUILD = "44"

WHATS_NEW_EN = """v1.11.0 — major sign-in, onboarding, and reliability polish:

Sign-in & accounts:
- Google / GitHub sign-in: fixed "OAuth state parameter is invalid" error that blocked sign-in on real device.
- Login screen: clearer Email Code vs Password modes — buttons no longer flip labels based on whether the password field is empty.
- Delete Account: now reliably surfaces server errors (token expired, network failures) with a clear alert, instead of silently signing you out while leaving your account intact server-side.
- Sign-out flow now properly clears Remote Approvals and push-token state, so account-switching on the same device works cleanly without an app relaunch.

Onboarding (Mac):
- Top-right close button on every onboarding step + "Skip for now" on the Sign In step. No more being trapped on the Welcome screen.
- After delete-account or sign-out: lands on Settings (Sign-In form) instead of an empty Overview, with bottom Quit button on every signed-out screen.

Local mode (Mac):
- New "Use local mode" option for users who want collector data without an account. Tracks AI tool usage on this Mac only, never uploaded.
- Welcome screen now offers a clear pick: "Sign in to sync" vs "Use local mode".
- Local Mode guide card on Overview explains what's happening and how to switch to cloud sync later.

Cross-device sync (iPhone):
- Fixed: iPhone Dashboard could show "Waiting for data" forever even when the Mac was actively collecting. Same-account users now see their Mac data automatically — no manual device pairing needed.

Provider banner (free plan):
- Fresh free-plan users no longer see "Disabled 23 providers" warnings on first launch. The plan-limit banner now only fires when actively-used providers genuinely exceed the limit.

Remote Approvals hardening:
- Concurrent decide on two devices no longer surfaces a raw database error — clean "Request already decided" message instead.
- Closed several push-token registration races during sign-in / sign-out.

Thanks for the bug reports!"""

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


# ─── 2. Find or create an editable 1.10.7 appStoreVersion per platform ───
def ensure_version(platform_label):
    """Return (version_id, current_versionString). Creates or renames as needed."""
    print(f"\n[2] Ensuring {platform_label} appStoreVersion = {TARGET_VERSION}...")
    r = get(f"/apps/{APP_ID}/appStoreVersions?filter[platform]={platform_label}&limit=10") or {}

    editable_states = {
        "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
        "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_EXPORT_COMPLIANCE",
        "DEVELOPER_REMOVED_FROM_SALE"
    }

    # Look for an existing 1.10.7
    for v in r.get("data", []):
        vs = v["attributes"]["versionString"]
        state = v["attributes"]["appStoreState"]
        if vs == TARGET_VERSION:
            print(f"   found existing {TARGET_VERSION} id={v['id']} state={state}")
            return v["id"], vs

    # Otherwise, reuse an editable older version by renaming it
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

    # Nothing editable — create a fresh version
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


# ─── 3. Wait for build 41 to be VALID, then bind it ──────────────────────
def bind_build(version_id, platform_label):
    print(f"\n[3] Binding build {TARGET_BUILD} to {platform_label}...")
    wanted_plat = platform_label
    for attempt in range(40):  # ~20 min
        r = get(f"/builds?filter[app]={APP_ID}&filter[preReleaseVersion.platform]={wanted_plat}&sort=-uploadedDate&limit=10") or {}
        found = None
        states = []
        for b in r.get("data", []):
            bv = b["attributes"].get("version")
            proc = b["attributes"].get("processingState")
            ver_rel = (b.get("relationships", {}).get("preReleaseVersion", {})
                       .get("data") or {})
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
            else:
                print(f"   !! bind failed on build {found}")
                return False
        print(f"   waiting for build {TARGET_BUILD} to process... ({attempt+1}/40) seen={states[:5]}")
        time.sleep(30)
    print(f"   !! build {TARGET_BUILD} never reached VALID on {platform_label}")
    return False


# ─── 4. Patch en-US whatsNew ─────────────────────────────────────────────
def patch_whats_new(version_id, platform_label):
    print(f"\n[4] Patching {platform_label} en-US whatsNew...")
    r = get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations") or {}
    for loc in r.get("data", []):
        if loc["attributes"]["locale"] == "en-US":
            upd = patch(f"/appStoreVersionLocalizations/{loc['id']}", {
                "data": {"type": "appStoreVersionLocalizations", "id": loc["id"],
                         "attributes": {"whatsNew": WHATS_NEW_EN}}
            })
            if upd is not None:
                print(f"   whatsNew set on loc {loc['id']}")
                return True
    print("   !! no en-US localization found")
    return False


# ─── 5. Submit for review ────────────────────────────────────────────────
def submit_for_review(platform_label, version_id):
    print(f"\n[5] Submitting {platform_label} for review...")
    # Re-use an existing READY submission if one exists for this platform
    existing = get(f"/apps/{APP_ID}/reviewSubmissions?filter[platform]={platform_label}") or {}
    sub_id = None
    for sub in existing.get("data", []):
        if sub["attributes"]["state"] == "READY_FOR_REVIEW":
            sub_id = sub["id"]
            print(f"   reusing READY_FOR_REVIEW submission {sub_id}")
            break
    if sub_id is None:
        resp = post("/reviewSubmissions", {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": platform_label},
                "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}
            }
        })
        if resp is None:
            return False
        sub_id = resp["data"]["id"]
        print(f"   created submission {sub_id}")

    # Ensure the version is on the submission as a reviewSubmissionItem
    items = get(f"/reviewSubmissions/{sub_id}/items") or {}
    already = any(
        (it.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") == version_id
        for it in items.get("data", [])
    )
    if not already:
        resp = post("/reviewSubmissionItems", {
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                }
            }
        })
        if resp is None:
            return False
        print(f"   added version {version_id} to submission")

    # Flip submitted=true
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
    platforms = sys.argv[1:] or ["IOS", "MAC_OS"]
    print(f"== CLI Pulse {TARGET_VERSION} build {TARGET_BUILD} ASC submit ==")
    print(f"   platforms: {platforms}")

    # Sanity check connectivity
    r = get(f"/apps/{APP_ID}")
    if not r:
        print("!! cannot reach App Store Connect")
        sys.exit(1)
    print(f"   app: {r['data']['attributes']['name']}")

    # One-time cancel pass before we touch version metadata
    cancel_pending_reviews()
    time.sleep(5)

    failures = []
    for plat in platforms:
        print(f"\n=== {plat} ===")
        vid, _ = ensure_version(plat)
        if vid is None:
            failures.append(f"{plat}: no version")
            continue
        if not bind_build(vid, plat):
            failures.append(f"{plat}: build bind failed")
            continue
        if not patch_whats_new(vid, plat):
            failures.append(f"{plat}: whatsNew patch failed (continuing)")
        if not submit_for_review(plat, vid):
            failures.append(f"{plat}: submit failed")

    print("\n=== Done ===")
    if failures:
        for f in failures:
            print(f"   !! {f}")
        sys.exit(2)
    print("   all platforms submitted")


if __name__ == "__main__":
    main()
