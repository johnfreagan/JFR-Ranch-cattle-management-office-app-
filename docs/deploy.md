# Deploy

_Moved word for word from `CLAUDE.md` on 2026-09-27, when CLAUDE.md became a short index. Nothing here was rewritten; section dates are the dates the rules were written._

## Deploy

- The ONLY app file is `index.html` at repo root (~650KB). There is no build step.
- Deploy = commit + push to main. GitHub Pages auto-deploys in 1-3 min.
- After deploy, hard refresh (Cmd+Shift+R) to bypass cache.
- Supabase URL: https://xpfmebdzcxorvwikfvtj.supabase.co (publishable key is
  embedded in index.html — this is expected for this app).
  **Corollary: the key is public, so anything GRANTed to `anon` is public.**
  Embedding the key is fine; granting `anon` access to anything is not.
