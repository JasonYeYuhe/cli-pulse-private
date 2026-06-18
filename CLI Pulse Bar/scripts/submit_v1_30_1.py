#!/usr/bin/env python3
"""
CLI Pulse v1.30.1 — ASC metadata + submit.

Copy of submit_v1_30_0.py (same proven, idempotent ASC API flow). Only
TARGET_VERSION / TARGET_BUILD / WHATS_NEW_* changed. v1.30.1 supersedes the
in-flight 1.30.0 (build 75, still WAITING_FOR_REVIEW) — the cancel->rename
prep flow turns the editable 1.30.0 version into 1.30.1 and binds build 76.

Because users upgrade 1.29.1 -> 1.30.1 (1.30.0 was never released), the
What's New still describes the 1.30.0 features AND adds the macOS detection
fixes shipped on top (Claude usage now detected after granting access;
companion CLI now detected when running).

Per platform (iOS + macOS), idempotent / safe to re-run:
  1. (prep) Cancel any WAITING_FOR_REVIEW / IN_REVIEW submission so
     versions become editable.
  2. (prep) Find/rename/create an editable 1.30.1 appStoreVersion.
  3. (prep) Wait for build 76 -> processingState=VALID, then bind it.
  4. (prep) PATCH whatsNew for en-US, zh-Hans, ja, ko, es-ES.
  5. (prep) Set App Review notes.
  6. (submit) Create reviewSubmission + item, PATCH submitted=true.

Usage:
  submit_v1_30_1.py prep   [IOS MAC_OS]   # steps 1-5, no submit
  submit_v1_30_1.py submit [IOS MAC_OS]   # step 6 only
  submit_v1_30_1.py all    [IOS MAC_OS]   # 1-6
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

TARGET_VERSION = "1.30.1"
TARGET_BUILD = "76"

# v1.30.1 What's New per locale. No backticks anywhere — Apple's What's
# New field rejects them per feedback_asc_release_workflow.

WHATS_NEW_EN = """v1.30.1 — see your usage pace at a glance.

- New pace markers on the quota bars show whether you are ahead of or behind your expected usage pace, with warning-threshold ticks.
- New per-provider usage history chart on iPhone and Mac visualizes your daily token usage over time.
- Usage-pace summaries throughout the app and on Apple Watch.
- Redesigned Apple Watch glance with dedicated Pulse, Quota, Live, and Alerts pages.
- Fixes on Mac: Claude usage is now detected right after you grant folder access, and the companion CLI is reliably recognized while it is running.
- Improved macOS reliability and responsiveness, plus widget refinements."""

WHATS_NEW_ZH_HANS = """v1.30.1 — 一眼看清你的用量节奏

- 配额条上新增节奏标记,显示你领先还是落后于预期用量节奏,并带有预警阈值刻度
- iPhone 与 Mac 新增各服务商用量历史图表,直观呈现每日 token 用量趋势
- 全应用及 Apple Watch 显示用量节奏摘要
- 重新设计的 Apple Watch 一览界面(Pulse / Quota / Live / Alerts 分页)
- Mac 端修复:授权文件夹访问后立即识别 Claude 用量;companion CLI 运行时可被稳定识别
- 提升 macOS 的稳定性与响应速度,并优化小组件"""

WHATS_NEW_JA = """v1.30.1 — 使用ペースをひと目で。

- クォータバーに新しいペースマーカーを追加。想定ペースに対して進んでいるか遅れているかを、警告しきい値の目盛りとともに表示します。
- iPhone と Mac にプロバイダ別の使用履歴グラフを追加し、日々のトークン使用量の推移を可視化します。
- アプリ全体および Apple Watch で使用ペースの概要を表示。
- Apple Watch のグランスを刷新(Pulse / Quota / Live / Alerts の各ページ)。
- Mac の修正:フォルダアクセスを許可した直後に Claude の使用量を検出し、コンパニオン CLI が実行中に確実に認識されるようになりました。
- macOS の信頼性と応答性を改善し、ウィジェットを調整しました。"""

WHATS_NEW_KO = """v1.30.1 — 사용 페이스를 한눈에.

- 할당량 막대에 새 페이스 마커를 추가하여 예상 사용 페이스보다 앞서는지 뒤처지는지 경고 임계값 눈금과 함께 표시합니다.
- iPhone과 Mac에 제공업체별 사용 기록 차트를 추가하여 일일 토큰 사용량 추이를 시각화합니다.
- 앱 전반과 Apple Watch에서 사용 페이스 요약을 표시합니다.
- Apple Watch 글랜스를 새롭게 디자인했습니다(Pulse / Quota / Live / Alerts 페이지).
- Mac 수정: 폴더 접근을 허용한 직후 Claude 사용량을 감지하고, 실행 중인 컴패니언 CLI를 안정적으로 인식합니다.
- macOS 안정성과 반응성을 개선하고 위젯을 다듬었습니다."""

WHATS_NEW_ES_ES = """v1.30.1 — tu ritmo de uso de un vistazo.

- Nuevos marcadores de ritmo en las barras de cuota que muestran si vas por delante o por detrás de tu ritmo de uso previsto, con marcas de umbral de aviso.
- Nuevo gráfico de historial de uso por proveedor en iPhone y Mac que visualiza el uso diario de tokens a lo largo del tiempo.
- Resúmenes del ritmo de uso en toda la app y en el Apple Watch.
- Vistazo del Apple Watch rediseñado con páginas dedicadas de Pulse, Quota, Live y Alerts.
- Correcciones en Mac: el uso de Claude se detecta justo después de conceder acceso a la carpeta, y la CLI complementaria se reconoce de forma fiable mientras se ejecuta.
- Mayor fiabilidad y capacidad de respuesta en macOS, además de mejoras en los widgets."""

WHATS_NEW_BY_LOCALE = {
    "en-US":   WHATS_NEW_EN,
    "zh-Hans": WHATS_NEW_ZH_HANS,
    "ja":      WHATS_NEW_JA,
    "ko":      WHATS_NEW_KO,
    "es-ES":   WHATS_NEW_ES_ES,
}

# App Review notes — v1.30.1 adds no new capabilities/entitlements.
REVIEW_NOTES = (
    "This update is additive UI and reliability work: usage-pace markers "
    "and a per-provider usage history chart on iPhone and Mac, a "
    "redesigned Apple Watch glance, and macOS responsiveness/stability "
    "fixes (Claude usage detection after granting folder access; companion "
    "CLI detection while running). No new capabilities, entitlements, or "
    "background modes were added. No demo account or special hardware is "
    "required to review; on Mac the app also works in local mode without an "
    "account. Externally it behaves like the approved prior version with "
    "these additive features. Thank you for the review."
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


# ─── 2. Find or create an editable 1.30.1 appStoreVersion per platform ───
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


# ─── 3. Wait for build 76 to be VALID, then bind it ──────────────────────
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
        print("Usage: submit_v1_30_1.py [prep|submit|all] [IOS MAC_OS]")
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
