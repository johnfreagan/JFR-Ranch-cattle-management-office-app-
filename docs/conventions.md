# Conventions

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

## The short rules (2026-09-27)

- Stocker (fiscal) year is July 1 to June 30, named for the year it ends (FY 2027 = Jul 2026 to Jun 2027).
- Tax year is calendar year, Jan 1 to Dec 31. Anything for the accountants or taxes uses the calendar year.
- The two don't line up; every report must say which year it uses.
- Retire a tag on death or sale when the tag is known.
- drug_off means the carcass was dragged out of the field.
- Withdrawal warns and lists the tags; it doesn't block.
- A tag is plain digits (no leading zero) or NT<n> for an untagged animal, numbered per lot; untagged records also set no_tag = true. Only digit tags are matched to lot_tags.
- D8: books head must equal pasture head.

## SQL conventions

- ALL migration/correction SQL must be idempotent (IF NOT EXISTS, guarded DO
  blocks that RAISE EXCEPTION if state isn't as expected).
- Any direct data correction APPENDS an audit note to the row's notes column
  (what changed, why, date).
- In RAISE NOTICE strings avoid bare `%` collisions; never nest $$ in DO blocks.
- Watch PL/pgSQL name collisions between loop variables and table aliases
  (use row_rec, rn — a FOR var named `r` once shadowed `ranches r`).
- Errors must never be silently swallowed — surface them to the user.
- `to_regclass()` resolves views and sequences too, not just tables. Check
  `relkind` before `ALTER TABLE`, or a view in a table list aborts the whole
  migration and silently leaves everything after it unprotected.

## App code conventions

- Vanilla JS, no framework, one <script> block. Supabase JS v2 via CDN.
  jsPDF + autotable via CDN for shareable PDFs.
- After ANY edit: validate the big script block parses (new Function) and
  that <div> open/close counts balance outside script/style. Ship only if both pass.
  There is no node on this machine — run `osascript -l JavaScript
  scripts/validate.jxa.js index.html`, which does both checks on JavaScriptCore.
- Tiles on lot detail use buildTileRows() row-style (label left, value right).
  **Every tile row is a drill-down** (2026-09-04): a row carries `drill`
  (a lot section name, `deaths`, or `receiving`) and `lotDrill()` routes
  one delegated click. `receiving` leaves the lot for Reports → Health →
  Receiving with the lot pre-picked via `processingReportPendingLot`.
  Closeout table rows and the remnant / gain tiles drill the same way
  (`.co-drill`); `input:calc_cog` style targets land on that assumption
  input, focused. A drill into Sales or Closeout is refused when the role's
  CSS hides that tab, so crew never opens a dollar section from a head tile.
  A drill that LEAVES the lot (Receiving report, feed cost) shows
  `#drillBackBar`, "← Back to lot 60X", which reopens the lot in the section
  you left. It is set AFTER the navigation because `clearAllNavActive()`
  clears it: leaving by the main nav means done with that lot.
- **Fresh Cattle is its own report** under Reports → Health (2026-09-04),
  `reportFreshView` / `initFreshCattleReport()`. It used to sit above
  Processing Cost on the Receiving page.
- **The lot page is one section per PROCESS** (John's sketch, 2026-09-04):
  Currently in · Purchases (invoices, unlinked load outs, tags) · Animal
  Health (doctoring, deaths) · Moves (moves, transfers, merge) · Sales ·
  Closeout · Audit log. `showLotSubtab()` switches; `LOT_SECTIONS` is the
  list; `'activity'` still maps to `current` for old call sites. **The
  section and scroll position survive a re-render of the SAME lot** — every
  action calls `showLotDetail(currentLot.id)`, and before this that threw
  you to the top of one long page after each death or invoice. Only opening
  a different lot starts at Currently in. **The audit log loads only when
  its section is opened** (`auditLogLoadedFor`); it is the heaviest read
  on the page and John's note says "only open if selected". Tab counts are
  read off the card counts the loaders already write (`refreshLotTabCounts`)
  rather than taught to ten loaders.
- **Break-even tiles divide by head SOLD, never by head still here.** The
  lot-header floor tile did `total_cost / (head_now × weight)` and read
  $27.16/lb on 60X's last 29 of 251 head; the closeout row and remnant
  block had the same shape. All three now use surviving head (`head_in −
  head_dead`, or `headSoldAtClose` in the projection).
- Modals: showModal()/hideModal(); alerts via showAlert(id, msg, type).
- Print/share pattern: window.open + document.write for print; jsPDF +
  navigator.share({files}) for textable PDFs, download fallback on desktop.

## Working style (owner preference)

- Terse, decisive. Offer A/B/C options with a recommendation ("my vote");
  he often replies "all your votes."
- Ask before building anything significant; push back on scope creep.
- Investigate before correcting: for data issues, query first, show findings,
  propose the fix, wait for approval. Never delete data on your own initiative.
- Production DB is the live books of a real ranch. Schema changes and data
  corrections require explicit approval before execution.

### Response style: caveman is the default (2026-09-14)

**Every session in this repo answers in caveman style by default.** The full
ruleset is `.claude/skills/caveman/SKILL.md` — a verbatim copy of the MIT
`caveman` skill (https://github.com/JuliusBrussee/caveman), vendored rather
than installed; `.claude/skills/caveman/SOURCE.md` says why, how to update it
and how to turn it off. Level **full**. Read the skill and apply it without
being asked.

Short version: drop articles, filler and pleasantries; fragments fine; no
tool-call narration; no decorative tables or emoji. Never drop a
not/never/no/only/except — a flipped meaning costs more than any token saved.
Never ADD a word to sound caveman; if the caveman phrasing is not shorter, use
plain. Numbers, units, column names, error strings and code blocks are exact
and untouched.

Three things it does NOT apply to, and they matter more here than the saving:

- **Anything that leaves the chat stays normal prose.** Commit messages, PR
  bodies, `CLAUDE.md`, `docs/`, SQL comments, `notes` audit text, issue text.
  The skill's own Boundaries section says this; it is repeated here because
  this repo's documentation IS the institutional memory.
- **The skill's Auto-Clarity carve-out is load-bearing here**, not decoration.
  It drops compression for security warnings, irreversible-action
  confirmations and multi-step sequences where dropped conjunctions could be
  misread. That is a description of every migration, every head-math
  correction and every "apply this to the live books" moment in this project.
  When in doubt on a destructive step, write it out.
- **Terse is not a shortcut past the rules above it.** Investigate before
  correcting — query first, show findings, propose, wait. Fewer words, same
  work.

Say "normal mode" or "stop caveman" to turn it off for a session.
