#!/usr/bin/env python3
"""
Performance Beef API probe - read-only, writes nothing, stores nothing.

Settles the three questions Phase 3 depends on, against the known
36-27 Group Invoice for Aug 17-26 2026:

    as-fed pounds   must be 69,510   (60,881 would mean feed[].weight is DRY MATTER)
    head-days       must be 3,756
    feed[].name     must be commodities, not ration components

Credentials are read from a FILE or the environment - never from the command
line (argv is visible to every process on the machine via ps).

    python3 scripts/pb_probe.py ~/Desktop/pb-creds.json
    PB_CREDS_FILE=~/Desktop/pb-creds.json python3 scripts/pb_probe.py
    export PB_CLIENT_ID=... PB_CLIENT_SECRET=... ; python3 scripts/pb_probe.py

The file may be any of:

    {"client_id": "...", "client_secret": "..."}     JSON pair  -> exchanges for a token
    {"access_token": "..."}                          JSON token -> used directly
    PB_CLIENT_ID=...                                 .env style
    PB_CLIENT_SECRET=...
    eyJhbGciOi...                                    a bare bearer token on one line

Nothing from the file is ever printed, logged, or written anywhere.
"""
import json, os, re, sys, urllib.error, urllib.parse, urllib.request
from collections import defaultdict

BASE       = "https://performancebeef.com"
START, END = "2026-08-17", "2026-08-26"
GROUP      = "36-27"
EXPECT_LB, EXPECT_HD = 69510, 3756

CID_KEYS   = ("client_id", "pb_client_id", "clientid")
SEC_KEYS   = ("client_secret", "pb_client_secret", "clientsecret")
TOK_KEYS   = ("access_token", "token", "bearer", "bearer_token", "pb_token")


def _walk(obj):
    """Yield every (lowercased key, string value) pair anywhere in a JSON blob."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str):
                yield str(k).strip().lower(), v.strip()
            else:
                yield from _walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk(v)


def load_credentials():
    """Return (client_id, client_secret, bearer_token). Never echoes any value."""
    cid = os.environ.get("PB_CLIENT_ID")
    sec = os.environ.get("PB_CLIENT_SECRET")
    tok = os.environ.get("PB_ACCESS_TOKEN")

    path = None
    if len(sys.argv) > 1:
        path = sys.argv[1]
    elif os.environ.get("PB_CREDS_FILE"):
        path = os.environ["PB_CREDS_FILE"]

    if path:
        path = os.path.expanduser(path)
        if not os.path.isfile(path):
            sys.exit(f"No such credentials file: {path}")
        mode = oct(os.stat(path).st_mode & 0o777)
        raw = open(path, encoding="utf-8-sig").read()
        pairs = {}

        try:                                    # shape 1 + 2: JSON
            pairs = dict(_walk(json.loads(raw)))
            shape = "JSON"
        except json.JSONDecodeError:            # shape 3: .env / bare token
            shape = "text"
            for line in raw.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                m = re.match(r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*[=:]\s*(.+)$', line)
                if m:
                    pairs[m.group(1).strip().lower()] = m.group(2).strip().strip(chr(34) + chr(39))
                elif len(line) > 20 and " " not in line and not tok:
                    tok = line                  # a bare token on its own line
                    shape = "bare token"

        cid = next((pairs[k] for k in CID_KEYS if pairs.get(k)), cid)
        sec = next((pairs[k] for k in SEC_KEYS if pairs.get(k)), sec)
        tok = next((pairs[k] for k in TOK_KEYS if pairs.get(k)), tok)

        print(f"Credentials file : {path}")
        print(f"  permissions    : {mode}" + ("   <-- chmod 600 this" if mode != '0o600' else ""))
        print(f"  parsed as      : {shape}")
        print(f"  client_id      : {'found (' + str(len(cid)) + ' chars)' if cid else 'not found'}")
        print(f"  client_secret  : {'found (' + str(len(sec)) + ' chars)' if sec else 'not found'}")
        print(f"  access_token   : {'found (' + str(len(tok)) + ' chars)' if tok else 'not found'}")
        print()

    if not tok and not (cid and sec):
        sys.exit("Need either an access_token, or both client_id and client_secret.\n"
                 "Pass a credentials file path, set PB_CREDS_FILE, or export "
                 "PB_CLIENT_ID / PB_CLIENT_SECRET.")
    return cid, sec, tok


cid, secret, bearer = load_credentials()


def post_token():
    body = json.dumps({"client_id": cid, "client_secret": secret}).encode()
    req = urllib.request.Request(BASE + "/api/consultant/tokens/", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["access_token"]


def get(token, path, **params):
    url = BASE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:400] or "(no body)"
        sys.exit(f"HTTP {e.code} on {path}\n{detail}")


def check(label, got, want):
    ok = abs(got - want) < 0.5
    print(f"  {'PASS' if ok else 'FAIL'}  {label}: {got:,.0f}   (expected {want:,})")
    return ok


if bearer:
    tok = bearer
    print("Using the access token from the file (not shown).")
    print("Note: PB tokens expire after 1 hour - if this 401s, the token is stale\n"
          "and you need the client_id/client_secret pair instead.\n")
else:
    print("Authenticating...")
    tok = post_token()
    print("  token acquired (not shown)\n")

# ---- who can this credential see -------------------------------------------
users = get(tok, "/api/consultant/users/")
if users.get("errors"):
    print("!! errors array on the users call:")
    print(json.dumps(users["errors"], indent=2))
yards = users.get("data", [])
print(f"Feedyards visible to this credential: {len(yards)}")
for y in yards:
    print(f"  {y.get('feedyard_id')}  {y.get('email')}")
if not yards:
    sys.exit("\nNo feedyards returned - the credential has no data access yet.")
yard = yards[0]["feedyard_id"]
print(f"\nProbing feedyard {yard}, {START} .. {END}\n")

# ---- pen history ------------------------------------------------------------
ph = get(tok, "/api/consultant/pen_history/",
         start_date=START, end_date=END, users=yard)

# A 200 can carry per-feedyard failures alongside data. Ignoring this array is
# how a lot silently stops eating.
if ph.get("errors"):
    print("!! errors array present on a 200 response:")
    print(json.dumps(ph["errors"], indent=2))
    print()

rows = [r for d in ph.get("data", []) for r in d.get("pen_history", [])]
print(f"pen_history rows returned: {len(rows)}")
if not rows:
    sys.exit("No rows - nothing further to check.")

mine = [r for r in rows if any(GROUP in str(g) for g in (r.get("groups") or []))]
print(f"rows whose groups include {GROUP}: {len(mine)}\n")
scope = mine or rows
if not mine:
    print(f"(no {GROUP} rows found - falling back to ALL rows, so the two")
    print(" totals below will not match the single-group invoice)\n")

units   = {r.get("weight_unit") for r in scope}
pens    = sorted({str(r.get("pen")) for r in scope})
dates   = sorted({str(r.get("date")) for r in scope})
groups  = sorted({str(g) for r in scope for g in (r.get("groups") or [])})
rations = sorted({str(r.get("ration")) for r in scope if r.get("ration")})

feed_lb = defaultdict(float)
for r in scope:
    for f in (r.get("feed") or []):
        feed_lb[str(f.get("name"))] += float(f.get("weight") or 0)

total_lb  = sum(feed_lb.values())
total_hd  = sum(float(r.get("head_count") or 0) for r in scope)
tw        = sum(float(r.get("total_weight") or 0) for r in scope)
dry       = sum(float((r.get("dry_weight") or {}).get("actual") or 0) for r in scope)

print(f"weight_unit values : {units}   <-- must be lb")
print(f"dates              : {len(dates)}  ({dates[0]} .. {dates[-1]})")
print(f"pens               : {', '.join(pens)}")
print(f"groups             : {', '.join(groups)}")
print(f"rations            : {', '.join(rations) or '(none)'}")

print(f"\nfeed[] line items ({len(feed_lb)} distinct names):")
for name, lb in sorted(feed_lb.items(), key=lambda kv: -kv[1]):
    print(f"  {lb:12,.1f} lb   {name}")

print("\nThe three checks:")
a = check("sum feed[].weight", total_lb, EXPECT_LB)
b = check("sum head_count   ", total_hd, EXPECT_HD)
if not a and abs(total_lb - 60881) < 200:
    print("        ^^ this is the DRY MATTER figure. feed[].weight is NOT as-fed;")
    print("           relieving bays with it would leave 12.4% phantom inventory.")

print("\nInternal consistency:")
print(f"  sum feed[].weight   {total_lb:12,.1f}")
print(f"  sum total_weight    {tw:12,.1f}   {'(agree)' if abs(tw-total_lb)<1 else '(DISAGREE - total_weight is something else)'}")
print(f"  sum dry_weight.act  {dry:12,.1f}", end="")
print(f"   = {dry/total_lb*100:.1f}% of as-fed   <-- ~87.6% confirms as-fed above" if total_lb else "")

multi = [g for r in scope if len(r.get("groups") or []) > 1 for g in [tuple(sorted(map(str, r["groups"])))]]
print(f"\nPen-days holding more than one group: {len(multi)}")
for combo in sorted(set(multi)):
    print(f"  {' + '.join(combo)}   <-- we split these by head-days ourselves")

print("\nc. Are the feed[] names commodities or ration components?")
print("   Read the line-item list above. Commodity names (Corn hopper bin,")
print("   Pennchlor 50G, Peanut Hulls) mean pen_history posts directly.")
