#!/usr/bin/env python3
"""
CLI Pulse v1.21.0 — ASC metadata + submit.

What this does, per platform (iOS + macOS):
  1. Find the newest editable appStoreVersion. If it's on a prior
     versionString, bump to 1.21.0. If the only in-flight version is
     WAITING_FOR_REVIEW, cancel its reviewSubmission first.
  2. Wait for build 62 to reach processingState=VALID, then bind it.
  3. Patch every supported locale's whatsNew with the v1.21.0 release
     notes (en-US, zh-Hans, ja, ko, es-ES). Unlike submit_v1_12_0.py
     which only filled en-US, this script populates all five locales.
  4. Create a reviewSubmission + reviewSubmissionItem and PATCH
     submitted=true.

Safe to re-run: every step is idempotent against whatever state ASC is in.

Source-of-truth release-note text lives in
docs/release-notes/v1.21.0.md. If you tweak text there, update the
WHATS_NEW_* constants below to match before invoking this script.
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

TARGET_VERSION = "1.21.0"
TARGET_BUILD = "62"

# v1.21.0 What's New per locale. No backticks anywhere — Apple's
# What's New field rejects them per feedback_asc_release_workflow.

WHATS_NEW_EN = """v1.21.0 — smoother launch, sharper iPad routing, widget always fresh.

- Faster cold start: telemetry init moved off the launch thread on iOS and Mac.
- iPad: notification taps now reliably switch to the right tab.
- iOS home-screen widget refreshes every hour via silent push, even when the app is closed. Shows a "last updated" timestamp and a Smart Stack relevance score.
- Mac auto-update verifies the SHA-256 of downloaded DMGs without freezing the menu-bar popover.
- Receipt validation hardened to accept any current Apple Root CA chain — fixes a subset of TestFlight + sandbox receipts that were silently failing.
- Push tokens reconciled on every cold launch so notifications keep working after iOS reinstalls or reboots.
- Remote Control privacy consent dialog now reads cleanly in Simplified Chinese.
- Users with Traditional Chinese as their preferred system language now see Simplified Chinese throughout the app instead of falling back to English."""

WHATS_NEW_ZH_HANS = """v1.21.0 — 启动更快、iPad 路由更稳、小组件常新

- 启动更快(遥测初始化移出主线程)
- iPad:通知点击现在能可靠地切换到对应标签页
- iOS 主屏小组件即使在 App 未打开时也会通过静默推送每小时刷新一次,显示"最近更新"时间戳并接入 Smart Stack 相关度评分
- Mac 自动更新对下载的 DMG 计算 SHA-256 时不再卡顿菜单栏弹窗
- 收据验证现已覆盖 Apple 所有当前根 CA 链,修复了 TestFlight 与沙盒收据偶发的静默失败
- 每次冷启动重新核对 APNs 推送 token,iOS 重装或重启后通知不再悄悄失效
- "远程控制"隐私协议对话框现已提供完整中文版
- 系统首选语言为繁体中文的用户现在会看到简体中文界面,不再回落到英文"""

WHATS_NEW_JA = """v1.21.0 — 起動の高速化、iPad ルーティング改善、ウィジェットの自動更新

- 起動が高速化(テレメトリ初期化を起動スレッドから分離)
- iPad:通知タップが対応するタブに確実に遷移するように
- iOS ホーム画面ウィジェットは、アプリが閉じていてもサイレントプッシュで毎時更新。「最終更新」タイムスタンプと Smart Stack 関連度スコアを表示
- Mac の自動アップデート時、ダウンロードした DMG の SHA-256 検証でメニューバーがフリーズしなくなりました
- レシート検証が Apple の全ての現行ルート CA チェーンに対応(TestFlight・サンドボックスでの一部の検証失敗を解消)
- 起動のたびに APNs プッシュトークンを再同期。iOS 再インストール・再起動後も通知が動作
- リモートコントロールのプライバシー同意ダイアログを簡体字中国語に翻訳
- 言語設定が繁体字中国語のユーザーは、英語ではなく簡体字中国語の画面が表示されるように"""

WHATS_NEW_KO = """v1.21.0 — 빠른 실행, 정확한 iPad 라우팅, 항상 최신 위젯

- 실행 속도 향상(텔레메트리 초기화를 시작 스레드에서 분리)
- iPad: 알림 탭이 해당 탭으로 안정적으로 이동
- iOS 홈 화면 위젯이 앱을 닫은 상태에서도 사일런트 푸시로 매시간 갱신. "마지막 업데이트" 타임스탬프와 Smart Stack 관련도 점수 표시
- Mac 자동 업데이트의 DMG SHA-256 검증이 메뉴바 팝오버를 멈추지 않음
- 영수증 검증이 Apple 현재 루트 CA 체인을 모두 수용(TestFlight·샌드박스 영수증 일부 실패 수정)
- 실행할 때마다 APNs 푸시 토큰 재동기화. iOS 재설치·재부팅 후에도 알림 동작
- 원격 제어 개인정보 동의 다이얼로그가 중국어 간체로 번역됨
- 시스템 선호 언어가 중국어 번체인 사용자는 영어 대신 중국어 간체 UI 표시"""

WHATS_NEW_ES_ES = """v1.21.0 — arranque más rápido, mejor enrutamiento en iPad, widget siempre fresco.

- Arranque en frío más rápido (la telemetría ya no bloquea el hilo de lanzamiento).
- iPad: al pulsar una notificación ahora se cambia siempre a la pestaña correcta.
- El widget de pantalla de inicio en iOS se actualiza cada hora mediante notificaciones silenciosas, incluso con la app cerrada. Muestra marca de tiempo "última actualización" y puntuación de relevancia en Smart Stack.
- La verificación SHA-256 de actualizaciones DMG en Mac ya no bloquea el menú superior.
- La validación de recibos ahora acepta toda la cadena actual de CAs raíz de Apple — corrige fallos silenciosos en algunos recibos de TestFlight + sandbox.
- Los tokens de notificación push se reconcilian en cada arranque, manteniendo las notificaciones activas tras reinstalaciones o reinicios de iOS.
- El diálogo de consentimiento del Control Remoto ahora está traducido al chino simplificado.
- Los usuarios con chino tradicional como idioma preferido ahora ven la app en chino simplificado en lugar de inglés."""

# Locale -> What's New mapping. Keys are ASC's canonical locale codes
# (per /v1/appStoreVersionLocalizations responses). Any locale present
# on the version that is NOT in this map is left untouched (still shows
# whatever previously-localised text was there, or empty if new).
WHATS_NEW_BY_LOCALE = {
    "en-US":   WHATS_NEW_EN,
    "zh-Hans": WHATS_NEW_ZH_HANS,
    "ja":      WHATS_NEW_JA,
    "ko":      WHATS_NEW_KO,
    "es-ES":   WHATS_NEW_ES_ES,
}

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


# ─── 4. Patch whatsNew across every configured locale ───────────────────
def patch_whats_new(version_id, platform_label):
    print(f"\n[4] Patching {platform_label} whatsNew (multi-locale)...")
    r = get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations") or {}
    locs_seen = []
    locs_patched = []
    locs_unmapped = []
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
    # Require at least en-US to succeed — that's the ASC primary fallback.
    if "en-US" not in locs_patched:
        print("   !! en-US whatsNew patch did not succeed (other locales would fall back to it)")
        return False
    return True


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
