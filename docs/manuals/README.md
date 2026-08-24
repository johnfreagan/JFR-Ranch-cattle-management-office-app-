# Published manuals

The two HTML files here are the published versions of the guides, rendered as
Claude Artifacts:

- `admin-manual.html` — "Ranch Access Control"
  https://claude.ai/code/artifact/81a9b86a-497e-4f3f-adb2-8b396d7fa2bb
- `field-guide.html` — "Tracker Field Guide"
  https://claude.ai/code/artifact/6343cd1f-2237-4f14-89fe-9c7bf2e19088

Artifacts are private until shared from the page's share menu.

They are self-contained apart from Google Fonts (Bitter / Source Sans 3 /
JetBrains Mono), which is the one font host the Artifact CSP allows. Every
face has a real fallback stack, so they degrade cleanly if fonts do not load.

The SQL blocks in the admin manual carry copy buttons: Clipboard API first,
`execCommand` fallback, then select-the-text as a last resort.

`../USER-ADMIN-GUIDE.md` and `../FIELD-APP-GUIDE.md` hold the same content as
markdown. Content lives in two places on purpose — the markdown is what git
diffs readably and what a future session should read; the HTML is what gets
published and shared. **Change both, or the published page goes stale.**
