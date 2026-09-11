-- 2026-09-11  Ranch-level non-feed cost of gain, $/head-day.
-- Decision: docs/cog-design-decisions.md section 4. The feed boundary
-- (feed_direct_from = 2026-09-01) charges actual feed beside a NON-FEED rate
-- on the days after it; every lot's own rate was NULL, so the boundary had
-- never run. One ranch default, overridable per lot on the closeout, excludes
-- labor (its own line) and feed. $0.50 is a PLACEHOLDER until the ledger
-- gives a real figure; the note says so and the closeout hint shows it.
-- Applied through the connector 2026-09-11. Idempotent.
alter table ranch_settings add column if not exists nonfeed_cog_per_day numeric;
alter table ranch_settings add column if not exists nonfeed_cog_note text;
update ranch_settings
   set nonfeed_cog_per_day = 0.50,
       nonfeed_cog_note = 'placeholder set 2026-09-11: pasture, mineral, fuel and overhead per head-day, excludes labor and feed; replace with the ledger figure',
       updated_at = now()
 where nonfeed_cog_per_day is null;
