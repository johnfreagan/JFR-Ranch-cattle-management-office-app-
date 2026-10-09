# Cleanup playbook

A systematic pass over the office app (`index.html`, about 41k lines and 819
top-level functions) and the field app (`field-app/app.js`, about 4k lines) to
make the code clean and tight without changing what it does. Written
2026-10-09.

## Guardrails

- **No writes to the production database for the whole project.** Code
  cleanup never needs one. Anything that would need a database change goes on
  a list for John to approve, under the normal CLAUDE.md rules.
- **One slice per branch, one PR per slice**, about 300 diff lines at most.
- **Review, verify and fix are separate sessions.** A review session never
  edits code.
- **One finding per commit**, so a bad change reverts on its own.
- **Every commit is checked:** `node scripts/validate.js index.html`, then the
  harnesses the slice touches, diffed against the baseline in
  `docs/cleanup/baseline/`.
- **Green slices first, red last.** A red slice gets harness coverage before
  anyone touches it.
- **Never:** rename a function, reformat, churn whitespace, change a query's
  columns, filters or RPC calls (unless that is the finding), or delete code
  without John's OK.

## Phases

| Phase | What | Output |
|---|---|---|
| 0 | Baseline: run validate and every harness, save outputs as golden; list every function with its call sites, including `onclick` strings | `docs/cleanup/baseline/` |
| 1 | Map: split `index.html` into 20–30 slices with line range, functions, tables/RPCs, harness coverage, risk tier | `docs/cleanup/map.md` |
| 2 | Slice loop, green → yellow → red: review → verify → fix → check → PR | one PR per slice |
| 3 | Cross-cutting sweeps: duplicate helpers, swallowed errors, `ranchToday`, crew dollars, `tagToInt`, dead code | one PR per sweep |
| 4 | Field app (`app.js`): same loop; bump `CACHE_VERSION` and the `?v=` strings together | PRs |
| 5 | Database audit, read-only: views and functions against `docs/sql`, advisors, `rls_verify` | findings only; John approves fixes |
| 6 | Docs sync: `OPEN-ITEMS.md`, `conventions.md` | PR |

Risk tiers:

- **Red:** head math, sales, deaths, moves, costs and COG, medicine FIFO,
  RLS and roles, withdrawal.
- **Yellow:** forms that write data.
- **Green:** display only, reports, styling, help.

## Pace

- Green slices: about one per session.
- Red slices: P5, then P2–P4; John tests the PR on his phone before merge.
- If a verify pass rejects more than half of a slice's findings, stop and
  tighten the review prompt before going on.

## Prompts

### Preamble (top of every session)

```
Read CLAUDE.md and the docs it points to for this area. Rules for this session:
no writes to the production database (read-only queries are fine); no renames,
no reformatting, no whitespace churn; never change a query's columns, filters
or RPC calls unless that is the finding; don't delete anything. List suspects
for me instead. After every edit run node scripts/validate.js index.html and
the harnesses named in docs/cleanup/map.md for this slice. Compare against
docs/cleanup/baseline/ and show me any difference.
```

### P0 Baseline

```
Create branch cleanup/baseline. Run node scripts/validate.js index.html and
every harness in scripts/ (read each one's header for how to run it). Save
each output to docs/cleanup/baseline/<harness>.txt. Write
docs/cleanup/baseline/functions.md: every top-level function in index.html and
field-app/app.js with its line number, and every place it is called from,
including onclick/oninput strings, template literals, setTimeout strings and
the field app. Flag duplicate names and functions with zero callers (just
flag them; this is not a delete list). Don't edit any code. Commit and push.
```

### P1 Map

```
Read-only. Split index.html into 20–30 slices along its existing section
markers. Write docs/cleanup/map.md with a table: slice, line range,
functions, tables/views/RPCs it touches, harness coverage (which harness
cases exercise it), and risk tier (red = head math, sales, deaths, moves,
costs/COG, FIFO, RLS/roles, withdrawal; yellow = writes data; green =
display only). Order the slices green first. Don't edit any code.
```

### P2 Review a slice (no edits)

```
Review slice <N> (lines <a>–<b>) of index.html. Look for: real bugs,
swallowed errors, null/undefined risks, race conditions (double-tap saves,
stale reloads), duplicate logic that has a twin elsewhere in the file (give
the line), needless nesting, and breaks of CLAUDE.md rules. For each finding
give: line, severity, a concrete failure scenario (what input or state leads
to what wrong result), and the smallest fix as a diff. If it's only a guess,
say so. "No findings" is a fine answer. If a simplification would break a
CLAUDE.md rule, don't propose it. Write the result to
docs/cleanup/slice-<N>-findings.md. Don't edit index.html.
```

### P3 Verify (fresh session, adversarial)

```
Here is docs/cleanup/slice-<N>-findings.md. Try to disprove each finding
against the actual code and the callers listed in
docs/cleanup/baseline/functions.md. Mark each one CONFIRMED, PLAUSIBLE or
REJECTED with your reason. For every confirmed fix, check whether it changes
anything a user would see or anything sent to Supabase. Update the file.
Don't edit any code.
```

### P4 Apply

```
Branch cleanup/slice-<N>. Apply only the CONFIRMED findings in
docs/cleanup/slice-<N>-findings.md, one commit per finding. After each one,
run validate and the slice's harnesses and diff them against the baseline.
If any output changes and the finding didn't predict it, revert that commit
and note it in the file. When done, open a PR listing each finding, its
commit and the check results.
```

### P5 Red slice: add a test first

```
Before reviewing slice <N> (red), add harness cases to
scripts/office-tap-harness (fake.js/fixtures.js) for its main save paths and
their failure paths. Each case should print the exact RPC calls and payloads.
Save the output as the new baseline for this slice. Change nothing in
index.html. Open that as its own PR.
```

### P6 Sweep (Phase 3, one topic per run)

```
Sweep the whole of index.html for <topic>: [catch blocks that swallow errors
| use of new Date()/today outside ranchToday() | money shown on screens a
crew user can reach | tag compares that skip tagToInt() | helpers
duplicated 2+ times]. List every hit with its line, whether it's a real
problem, and the fix. For duplicates: propose one shared helper, show every
call site, and don't apply it. Write docs/cleanup/sweep-<topic>.md.
```

### P7 Dead code

```
From docs/cleanup/baseline/functions.md, take the functions with zero
callers. For each one, search index.html, field-app/, tally-book/, scripts/,
supabase/ and docs/sql for its name as a plain string. Classify each:
truly dead / called dynamically / unsure. Delete nothing. Give John the list
to approve.
```

## Progress

| Step | Status | Notes |
|---|---|---|
| Playbook | done 2026-10-09 | |
| P0 Baseline | done 2026-10-09 | 10 of 12 runs green; 2 harnesses broken before cleanup; pb-feed not runnable here. See `baseline/README.md` |
| P1 Map | | |
