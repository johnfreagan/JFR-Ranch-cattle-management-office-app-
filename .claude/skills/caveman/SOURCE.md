# Provenance

`SKILL.md` in this directory is a **verbatim copy** of `skills/caveman/SKILL.md`
from https://github.com/JuliusBrussee/caveman — MIT licensed (the repo's
`skills/` tree is MIT; its engine/proxy directories are BSL-1.1 and are NOT
vendored here).

- Upstream commit: `15581d14007fd01fb3f132016741962f34936ca2` (2026-09-07)
- Upstream release: v2.6.0

## Why it is vendored rather than installed

Caveman also ships as a Claude Code plugin
(`claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman`).
Two reasons that path is not used here:

1. **The plugin's auto-activation hook runs `node`.** There is no node on the
   ranch Mac — see "App code conventions" in CLAUDE.md, which is why the
   `index.html` validator runs on JavaScriptCore via `osascript`. The hook
   would fail every session start.
2. **Plugins install per machine.** Claude Code on the web runs in a fresh
   throwaway container each session, so a plugin installed on the Mac is not
   there. A file committed to the repo is.

A copy in the repo is on for every session, on every machine, with no install
step and no network. The trade is that it does not auto-update.

## To update it

```bash
git clone --depth 1 https://github.com/JuliusBrussee/caveman.git /tmp/caveman
cp /tmp/caveman/skills/caveman/SKILL.md .claude/skills/caveman/SKILL.md
```

Then bump the commit and release lines above. Do not hand-edit `SKILL.md` — any
ranch-specific carve-out belongs in the **Response style** section of
`CLAUDE.md`, so this file stays a clean re-copy.

## To turn it off

Say "normal mode" or "stop caveman" in a session for a one-off. To retire it
for good, delete the **Response style** section from `CLAUDE.md`; the skill
then only runs when asked for by name.
