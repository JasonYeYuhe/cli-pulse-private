#!/usr/bin/env python3
"""
Publish a CLI Pulse Android App Bundle (.aab) to Google Play via the
Play Developer API (androidpublisher v3).

Reusable across releases — pass the AAB, version name, track and release
notes. This is the automation whose ABSENCE let Play production lag six
versions behind Apple/DEVID (stuck at 1.27.0 / code 36 while the repo was
at 1.33.0 / code 49); run it every release to keep Play current.

Auth: a Play-publisher service-account JSON. Resolve order:
  1. --sa PATH
  2. $PLAY_SA_JSON
  3. ~/Library/Application Support/CLI-Pulse-Secrets/play-publisher-cli-pulse-2026-05-29.json

Flow (one atomic edit):
  insert edit -> upload bundle -> set <track> release (versionCodes=[code],
  releaseNotes) -> validate -> commit.

Usage:
  play_publish.py --aab app-release.aab --version-name 1.33.0 \
      --track production --notes-file notes_en.txt [--rollout 1.0] [--dry-run]

--rollout 1.0 (default) = full release (status "completed"). A fraction in
(0,1) does a staged rollout (status "inProgress", userFraction=frac).
--dry-run validates everything (uploads the bundle into the edit) but does
NOT commit — the edit is deleted, so nothing goes live.
"""
import argparse
import os
import sys

DEFAULT_SA = os.path.expanduser(
    "~/Library/Application Support/CLI-Pulse-Secrets/"
    "play-publisher-cli-pulse-2026-05-29.json"
)
PACKAGE = "com.clipulse.android"
SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def resolve_sa(arg):
    return arg or os.environ.get("PLAY_SA_JSON") or DEFAULT_SA


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--aab", required=True)
    ap.add_argument("--version-name", required=True)
    ap.add_argument("--track", default="production")
    ap.add_argument("--notes-file", help="release notes text file (en-US)")
    ap.add_argument("--notes-lang", default="en-US")
    ap.add_argument("--rollout", type=float, default=1.0,
                    help="1.0 = full (completed); 0<f<1 = staged (inProgress)")
    ap.add_argument("--sa")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    sa = resolve_sa(args.sa)
    if not os.path.isfile(sa):
        print(f"!! service account JSON not found: {sa}")
        sys.exit(1)
    if not os.path.isfile(args.aab):
        print(f"!! AAB not found: {args.aab}")
        sys.exit(1)

    notes = None
    if args.notes_file:
        with open(args.notes_file) as f:
            notes = f.read().strip()

    creds = service_account.Credentials.from_service_account_file(sa, scopes=SCOPES)
    svc = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)

    print(f"== Play publish {PACKAGE} -> track={args.track} "
          f"version={args.version_name} rollout={args.rollout} "
          f"{'(DRY RUN)' if args.dry_run else ''} ==")

    # Show current track state up front.
    probe = svc.edits().insert(packageName=PACKAGE, body={}).execute()
    peid = probe["id"]
    cur = svc.edits().tracks().get(packageName=PACKAGE, editId=peid, track=args.track).execute()
    print("  current", args.track, "releases:",
          [(r.get("name"), r.get("status"), r.get("versionCodes")) for r in cur.get("releases", [])])
    svc.edits().delete(packageName=PACKAGE, editId=peid).execute()

    # Real edit.
    edit = svc.edits().insert(packageName=PACKAGE, body={}).execute()
    eid = edit["id"]
    print("  edit:", eid)

    up = svc.edits().bundles().upload(
        packageName=PACKAGE, editId=eid,
        media_body=args.aab, media_mime_type="application/octet-stream",
    ).execute()
    code = up["versionCode"]
    print(f"  uploaded bundle -> versionCode {code}")

    release = {
        "name": args.version_name,
        "versionCodes": [str(code)],
    }
    if notes:
        release["releaseNotes"] = [{"language": args.notes_lang, "text": notes}]
    if args.rollout >= 1.0:
        release["status"] = "completed"
    else:
        release["status"] = "inProgress"
        release["userFraction"] = args.rollout

    svc.edits().tracks().update(
        packageName=PACKAGE, editId=eid, track=args.track,
        body={"track": args.track, "releases": [release]},
    ).execute()
    print(f"  set {args.track} release {args.version_name} codes=[{code}] status={release['status']}")

    # Validate the edit before committing (catches metadata/policy errors).
    svc.edits().validate(packageName=PACKAGE, editId=eid).execute()
    print("  edit validated OK")

    if args.dry_run:
        svc.edits().delete(packageName=PACKAGE, editId=eid).execute()
        print("  DRY RUN — edit deleted, nothing went live.")
        return

    committed = svc.edits().commit(packageName=PACKAGE, editId=eid).execute()
    print(f"  COMMITTED edit {committed['id']} — {args.version_name} (code {code}) "
          f"is now on the {args.track} track (Google review then rollout).")


if __name__ == "__main__":
    main()
