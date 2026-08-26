# Handoff spec — template

Copy this into `HANDOFF.md` (or `docs/handoff-<topic>.md` for a second stream of
work) when a piece of work will outlive the session that started it. It is a
working note for picking up in-flight work — **not** app documentation, and not
a place for standing rules.

`HANDOFF.md` in this repo is the worked example. Read it alongside this template.

---

## How to write one

**Precedence.** `CLAUDE.md` holds the standing rules and takes precedence over
any handoff. A handoff records *this piece of work*: what was decided, what
broke, what is left. When something in a handoff hardens into a permanent rule,
move it to `CLAUDE.md` (or `docs/architecture.md` for the reasoning) and leave
the handoff pointing at it. Do not restate rules — a second copy is a copy that
goes stale.

**Split the three kinds of content.** They rot at different rates:

| kind | goes in |
|---|---|
| standing rules | `CLAUDE.md` |
| why a rule exists, and what broke | `docs/architecture.md` |
| known gaps, deliberately not done | `docs/OPEN-ITEMS.md` |
| this piece of work, in flight | the handoff |

**Name the commit.** Every claim about what is live cites a SHA. "Live on `main`"
without one cannot be checked six weeks later.

**Record divergences, not just outcomes.** When the build diverged from the
design, the divergence is the load-bearing part — it is the thing the next person
would otherwise re-derive the hard way. Keep the original design text and call
the divergence out *inline*, marked deliberate or corrected. Do not quietly
rewrite the design to match what shipped.

**Say what was verified, and how.** "Verified by diff, not assumed." "Reproduced
both ways before and after the fix." An unverified claim should say so.

**Say what is still unexercised.** Built, tested against a replica, and never run
on production data is a different state from done, and the difference matters.

**Strike through finished steps** rather than deleting them, with the date and
the SHA. The history of what was decided is the point.

**Record what was ruled out and why**, not only what was chosen. Otherwise the
next session re-proposes it.

---

## Template

```markdown
# Handoff — {topic}

**Last updated:** {YYYY-MM-DD} ({one line: what state the work is in})

**Open items live in `docs/OPEN-ITEMS.md`** — read that first for what still
needs doing. This file is the narrative of how things got here.

Working note for picking up in-flight work, not app code. Read alongside
`CLAUDE.md`, which holds the standing business rules and schema landmines and
takes precedence over anything here.

---

## Core goal

{One paragraph: what this work is for, and how you know it is finished.
If a secondary goal emerged mid-flight, say so — that is usually where the
surprises are.}

{Table of the moving parts, if there is more than one repo/app/backend:}

| | Repo | Backend |
|---|---|---|
| {thing} | `{owner/repo}` | {what it talks to} |

---

## Current status

### Live on {repo} `{branch}`

- **`{sha}`** — {what it changed, and anything non-obvious about how it works}.
- **`{sha}`** — {…}

{State explicitly what was NOT changed, and how you know: "byte-identical
across both commits — verified by diff, not assumed."}

{Live URL, and whether it has been confirmed on a real device, by whom, when.}

### Things that broke on the way and are worth not repeating

- **{The symptom, in bold.}** {What actually caused it, the fix, and — if the
  tests missed it — why they missed it.}

---

## Key decisions

### Made

- **{Decision}** — chosen over {alternatives}. {Why. Who agreed, if it was
  John's call.}

### Ruled out / corrected mid-flight

- **{Thing that turned out to be wrong.}** {Why it does not work, and where it
  is corrected. If the original plan said otherwise, say that plainly.}

---

## Critical technical findings

- **{Finding.}** {Evidence — file and line, or a query result. Whether it is
  pre-existing or introduced. Whether it is a regression or expected.}

---

## Active constraints

### From `CLAUDE.md` — non-negotiable

{Only the ones this work actually touches. Point at CLAUDE.md; do not restate
the whole file.}

### Process

- Designated branch in each repo: `{branch}`. {Which repos have permission to
  push to `main`, and which do not — say who gave it and when.}
- `git push -u origin <branch>`, retrying up to 4× with exponential backoff.
- No PRs unless asked.

### Tone (owner preference)

Terse and decisive. Offer A/B/C with a recommendation ("my vote"). Ask before
building anything significant; push back on scope creep. For data issues:
investigate and show findings first, propose the fix, wait for approval. Never
delete data unprompted.

---

## Next immediate steps

1. ~~{Done step}~~ — ✅ done, `{sha}` / {date}.
2. **{Outstanding step.}** *Outstanding.* {Who does it — John in the GitHub UI,
   or the next session. If it is gated on a date or on something John must
   supply, say which and why.}

{What is next on the roadmap once this closes, and what it is blocked on.}

---

## {Design section, if the work had one} — BUILT / IN PROGRESS

**This section was the design; it is now the record of what shipped.** Where the
build diverged from the plan, the divergence is called out inline — those
divergences are the load-bearing part. The operational rules live in `CLAUDE.md`
under "{section}"; that file takes precedence.

{Shape diagram, table definitions, mapping tables, landmines — whatever the
design needed. Keep the original text; annotate the divergences.}

### Verification — what actually happened

{Real data, real numbers, real dates. What passed, on which lots, with which
totals. Then:}

**Still unexercised on production data:** {…}
```

---

## Checklist before handing off

- [ ] Every "live" claim cites a SHA
- [ ] Every divergence from the design is called out inline and marked
      deliberate or corrected
- [ ] What was verified says how it was verified
- [ ] What is still unexercised on production data is named
- [ ] Finished steps are struck through with dates, not deleted
- [ ] Anything that hardened into a rule has moved to `CLAUDE.md`, and the
      reasoning to `docs/architecture.md`
- [ ] Anything deliberately not done has moved to `docs/OPEN-ITEMS.md`
- [ ] Nothing in here restates a rule that already lives in `CLAUDE.md`
