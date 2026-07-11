#!/usr/bin/env python3
# Independent spec oracle for the Pulse Cat M1 ruleset. Generates
# PetGoldenVectors.json with computed expectations. If the Swift PetEngine
# matches this, both match the plan §1.2 spec.
import json, datetime

RULESET_VERSION = 1
WEIGHT_TABLE_VERSION = 1
WINDOW_DAYS = 7
MIN_ACTIVE = 3
ACTIVE_MIN_TOKENS = 20_000
ACTIVE_MIN_MSGS = 5
DOM_PCT = 55
BURST_TOP = 3
BURST_PCT = 60
MIN_DAYS_BETWEEN = 7

# provider -> (family, micro-USD/Mtok weight)  [defaultCostRate*1000*1e6, clamp 0.5..30 $/Mtok]
PROV = {
    "Claude":       ("anthropic", 3_000_000),
    "Codex":        ("openai",    2_000_000),
    "OpenAI Admin": ("openai",    1_000_000),
    "Gemini":       ("google",    1_000_000),
    "Vertex AI":    ("google",    3_000_000),
    "Cursor":       ("other",     2_000_000),
    "Ollama":       ("other",       500_000),
}

def dkey(d): return d.strftime("%Y-%m-%d")
def parse(k): return datetime.date.fromisoformat(k)
def shift(k, n): return dkey(parse(k) + datetime.timedelta(days=n))

def window_keys(today):
    t = parse(today)
    return [dkey(t - datetime.timedelta(days=i)) for i in range(WINDOW_DAYS-1, -1, -1)]

def resolve_form(dom, tempo):
    if dom == "anthropic": return "loaf" if tempo == "steady" else "polite"
    if dom == "openai":    return "smash" if tempo == "steady" else "pop"
    if dom == "google":    return "long"
    return "huh"   # other / None

def usable(u):
    # Mirror M0 ingest: only .high/.medium enter the ledger; .low
    # (quota-snapshot / unavailable) is rejected entirely — contributes nothing.
    return (u.get("confidence","high") != "low")

def profile(days, today):
    keys = window_keys(today)
    # per-day totals (low-confidence providers never entered the ledger)
    active = []
    day_tokens = {}
    for k in keys:
        toks = sum(u.get("tokens",0) for u in days.get(k,{}).values() if usable(u))
        msgs = sum(u.get("messages",0) for u in days.get(k,{}).values() if usable(u))
        day_tokens[k] = toks
        if toks >= ACTIVE_MIN_TOKENS or msgs >= ACTIVE_MIN_MSGS:
            active.append(k)
    # family weighted scores
    fam_score = {}
    for k in keys:
        for prov, u in days.get(k,{}).items():
            if not usable(u): continue
            fam, w = PROV.get(prov, ("other", 500_000))
            fam_score[fam] = fam_score.get(fam,0) + max(0,u.get("tokens",0))*w
    total = sum(fam_score.values())
    qualified = (len(active) >= MIN_ACTIVE) and (total > 0)
    # dominant: max weighted score whose share >= 55% (integer cross-mult), ties by family name desc
    dom = None
    if total > 0:
        # highest weighted score; ties broken by SMALLEST family name (matches
        # Swift max(by:)). Ties can never reach ≥55% so this never changes a verdict.
        top = sorted(fam_score.items(), key=lambda kv: (-kv[1], kv[0]))[0]
        # ".other"-dominant -> Mixed (no named vendor verdict); dom stays None.
        if top[0] != "other" and top[1]*100 >= total*DOM_PCT:
            dom = top[0]
    # tempo
    toks_sorted = sorted(day_tokens.values(), reverse=True)
    top3 = sum(toks_sorted[:BURST_TOP]); tt = sum(toks_sorted)
    burst = tt > 0 and top3*100 >= tt*BURST_PCT
    tempo = "burst" if burst else "steady"
    form = resolve_form(dom, tempo)
    egg = min(len(active), 3)
    return dict(qualified=qualified, dominantFamily=dom, tempo=tempo,
               resolvedForm=form, eggStage=egg, activeDays=len(active))

def timing_allows(last, today):
    if last is None: return True
    return today >= shift(last, MIN_DAYS_BETWEEN)

def evaluate(days, today, owned, last):
    p = profile(days, today)
    ta = timing_allows(last, today)
    form = p["resolvedForm"]
    owns = form in owned
    should = p["qualified"] and ta and not owns
    already = p["qualified"] and ta and owns
    return dict(qualified=p["qualified"], timingAllows=ta,
                dominantFamily=p["dominantFamily"], tempo=p["tempo"],
                resolvedForm=form, shouldHatch=should,
                hatchedForm=(form if should else None),
                alreadyOwned=already, eggStage=p["eggStage"])

# ---- helpers to build day maps ----
def spread(prov, daykeys, tokens, msgs=0, conf=None):
    """usage dict for one provider across daykeys"""
    out = {}
    for k in daykeys:
        u = {"tokens": tokens}
        if msgs: u["messages"] = msgs
        if conf: u["confidence"] = conf
        out.setdefault(k, {})[prov] = u
    return out

def merge(*maps):
    r = {}
    for m in maps:
        for k, provs in m.items():
            r.setdefault(k, {}).update(provs)
    return r

T = "2026-07-11"
W = window_keys(T)         # 07-05 .. 07-11
d = lambda i: W[i]         # index into window, 0=oldest

cases = []
def add(name, days, today=T, owned=None, last=None):
    owned = owned or []
    cases.append(dict(name=name, todayKey=today, ownedForms=owned,
                      lastHatchDayKey=last, days=days, expect=evaluate(days, today, owned, last)))

# 1 anthropic steady -> loaf (7 days 20k)
add("anthropic_steady_loaf", spread("Claude", W, 20_000, msgs=10))
# 2 anthropic burst -> polite (3 concentrated days)
add("anthropic_burst_polite", spread("Claude", [d(4),d(5),d(6)], 100_000, msgs=10))
# 3 openai steady -> smash
add("openai_steady_smash", spread("Codex", W, 20_000))
# 4 openai burst -> pop
add("openai_burst_pop", spread("Codex", [d(4),d(5),d(6)], 100_000))
# 5 google steady -> long (medium cloud)
add("google_steady_long", spread("Gemini", W, 20_000, conf="medium"))
# 6 google burst -> long (catch-all: tempo ignored)
add("google_burst_long", spread("Gemini", [d(4),d(5),d(6)], 100_000, conf="medium"))
# 7 mixed no-dominant -> huh (even claude/codex/gemini)
add("mixed_no_dominant_huh",
    merge(spread("Claude", W, 20_000), spread("Codex", W, 20_000),
          spread("Gemini", W, 20_000, conf="medium")))
# 8 other-dominant -> huh (cursor only)
add("other_dominant_huh", spread("Cursor", W, 30_000))
# 9 owned-form week -> no hatch, alreadyOwned
add("owned_form_waits", spread("Claude", W, 20_000, msgs=10), owned=["loaf"])
# 10 unqualified (2 active days) -> no hatch
add("unqualified_two_days", spread("Claude", [d(5),d(6)], 30_000))
# 11 timing blocks (last hatch 3 days ago)
add("timing_blocks_recent_hatch", spread("Claude", W, 20_000), last=shift(T,-3))
# 12 timing allows exactly 7 days
add("timing_allows_exactly_7d", spread("Claude", W, 20_000), last=shift(T,-7))
# 13 clock rollback (last hatch in the future)
add("clock_rollback_no_hatch", spread("Claude", W, 20_000), last=shift(T,9))
# 14 DST spring-forward window (ending 2026-03-09), 6 steady days
Tdst = "2026-03-09"; Wd = window_keys(Tdst)
add("dst_spring_forward_loaf", spread("Claude", Wd[1:], 25_000), today=Tdst)  # 6 days
# 15 messages-only (0 weighted tokens) -> NOT qualified even at 3 active days
add("messages_only_not_qualified",
    {d(4):{"Claude":{"tokens":0,"messages":10}},
     d(5):{"Claude":{"tokens":0,"messages":10}},
     d(6):{"Claude":{"tokens":0,"messages":10}}})
# 16 empty ledger -> not qualified, egg idle
add("empty_ledger_idle", {})
# 17 dominance boundary exactly 55% -> dominant anthropic
#   anthropic weighted 33e9, total 60e9 -> 55%. Claude 11000/day*3e6, Gemini 27000/day*1e6, 3 days.
add("dominance_exactly_55_anthropic",
    merge(spread("Claude", [d(4),d(5),d(6)], 11_000, msgs=10),
          spread("Gemini", [d(4),d(5),d(6)], 27_000, conf="medium")))
# 18 dominance just under 55% -> mixed huh
#   Claude 10900/day*3e6=32.7e9, Gemini 27000*1e6=27e9, total 59.7e9 -> 54.77% <55
add("dominance_just_under_55_huh",
    merge(spread("Claude", [d(4),d(5),d(6)], 10_900, msgs=10),
          spread("Gemini", [d(4),d(5),d(6)], 27_000, conf="medium")))
# 19 tempo boundary exactly 60% top-3 -> burst
#   6 days: three at 40k, three at ~13.3k -> messy. Use 5 days: 3@40k + 2@30k => top3=120k,total=180k=>66%.
#   For exactly 60: top3=X, total. 3 days@30k + 2 days@15k => top3=90k total=120k =>75%.
#   Want 60 exactly: top3=60,total=100 units. 3@20k=60k + spread 40k over >=1 more day but <=20k each
#   so they aren't in top3: 40k over 3 days ~13.3k. Use 3@20k + 3@ (40k/3) not integer.
#   Simpler: 3@20k=60k in top3 + 2 more days@20k => but then top3 could include those (all 20k).
#   Ties: top3 of six 20k-days = 60k, total=120k => 50%. Not 60.
#   Do 3@30k + 2@22.5k -> non int. Use 3@30k(top3=90k) + 3@20k => total=150k, top3=90k=>60% exactly!
add("tempo_exactly_60_burst",
    merge(spread("Claude", [d(4),d(5),d(6)], 30_000),
          spread("Claude", [d(1),d(2),d(3)], 20_000)))
# 20 tempo just under 60% -> steady
#   3@30k=90k top3 + 3@21k => total=90k+63k=153k, 90/153=58.8% <60 => steady
add("tempo_just_under_60_steady",
    merge(spread("Claude", [d(4),d(5),d(6)], 30_000),
          spread("Claude", [d(1),d(2),d(3)], 21_000)))
# 21 sparse: only 1 active day -> not qualified, egg crack1
add("sparse_one_active_day", spread("Claude", [d(6)], 30_000))
# 22 high+medium same family sum (codex high + openai-admin medium) -> openai
add("openai_high_plus_medium_admin",
    merge(spread("Codex", W, 15_000, msgs=6),
          spread("OpenAI Admin", W, 15_000, conf="medium")))
# 23 owned different form, new form hatches
add("owned_loaf_new_smash_hatches", spread("Codex", W, 20_000), owned=["loaf"])
# 24 free/local ollama enfranchised floor -> other -> huh (still hatches huh if unowned)
add("ollama_floor_other_huh", spread("Ollama", W, 30_000))
# 25 timezone travel: window includes frozen keys on both sides of a UTC-midnight
#   day boundary (same event bucketed to adjacent days in different TZs, per M0).
#   Engine profiles the frozen keys as distinct active days — no merge, no gap.
Ttrav = "2026-03-21"; Wt = window_keys(Ttrav)  # ...03-15..03-21
add("timezone_travel_frozen_keys",
    merge(spread("Claude", [Wt[2],Wt[3],Wt[4],Wt[5],Wt[6]], 22_000)), today=Ttrav)  # 5 steady days
# 26 steering: OpenAI-heavy first half, Anthropic-heavy second half — the whole
#   7-day window aggregates, and the heavier-weighted Anthropic steers the verdict.
add("steering_mid_week_to_anthropic",
    merge(spread("Codex",  [d(0),d(1),d(2)], 30_000),
          spread("Claude", [d(4),d(5),d(6)], 30_000)))
# 27 unavailable provider: a .low (quota-snapshot/unavailable) provider is IGNORED
#   (never enters history), so a huge low-confidence Gemini can't out-vote Claude.
add("unavailable_low_provider_ignored",
    merge(spread("Claude", W, 20_000, msgs=6),
          spread("Gemini", W, 500_000, conf="low")))
# 28 extreme-scale exactness: Claude/Codex/Gemini each 333_333_333_334 tokens on
#   3 days -> anthropic weighted exactly 50% (<55%) -> Mixed huh. A saturating
#   threshold compare would wrongly declare anthropic dominant; the exact 128-bit
#   ratio must not (Codex F1). (3 days -> burst.)
BIG = 333_333_333_334
add("extreme_scale_no_false_dominance",
    merge(spread("Claude", [d(4),d(5),d(6)], BIG),
          spread("Codex",  [d(4),d(5),d(6)], BIG),
          spread("Gemini", [d(4),d(5),d(6)], BIG)))

out = {"_generatedBy": "scripts/pet_golden_oracle.py — DO NOT hand-edit; regenerate + diff",
       "rulesetVersion": RULESET_VERSION, "weightTableVersion": WEIGHT_TABLE_VERSION,
       "cases": cases}
print(json.dumps(out, indent=2))
