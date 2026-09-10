-- 2026-09-10  Daily ingestion schedule for the market-quotes-sync edge function.
--
-- Companion to docs/sql/2026-09-10_markets_and_positions.sql and
-- supabase/functions/market-quotes-sync/index.ts.
--
-- NOTE FOR JOHN: this enables pg_cron and pg_net, the two extensions the
-- feed module's wave-3 "7am email" has been blocked on. They are now on, so
-- that work is unblocked as a side effect.
--
-- AUTH, and its limit: the function is deployed with verify_jwt = true, and
-- this job authenticates with the PUBLISHABLE (anon) key - the same key
-- already embedded in index.html. So the endpoint is not open to the world,
-- but anyone holding that public key could trigger a run. The blast radius
-- is a Yahoo fetch and an upsert of market quotes; it cannot reach any other
-- table, because the function writes only market_quotes and derives every
-- value from the fetched response. Tightening this properly means setting a
-- shared secret as an edge-function secret (dashboard) and checking it in
-- the handler - worth doing, needs John to set the secret.
--
-- Idempotent: cron.schedule() upserts by job name.
begin;

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- 23:30 UTC = 6:30pm CDT / 5:30pm CST, comfortably after the feeder cattle
-- close either side of a daylight-saving change. The function's default
-- window is the last 8 days, so a missed or mistimed run heals itself on the
-- next one rather than leaving a permanent hole in the curve. That is also
-- why this is not scheduled in ranch-local time: it does not need to be.
select cron.schedule(
    'market-quotes-sync-daily',
    '30 23 * * *',
    $job$
    select net.http_post(
        url := 'https://xpfmebdzcxorvwikfvtj.supabase.co/functions/v1/market-quotes-sync',
        body := '{"instruments":["feeder_cattle","live_cattle"],"months":8}'::jsonb,
        headers := jsonb_build_object(
            'Content-Type','application/json',
            'Authorization','Bearer <publishable key - see index.html>'),
        timeout_milliseconds := 120000);
    $job$
);

do $verify$
DECLARE
    v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM cron.job WHERE jobname = 'market-quotes-sync-daily' AND active;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'market-quotes-sync-daily is not scheduled (% active jobs by that name).', v_n;
    END IF;
    RAISE NOTICE 'market-quotes-sync scheduled daily at 23:30 UTC.';
END
$verify$;

commit;

-- =====================================================================
-- Backfill, run by hand once (2026-01-01 -> today, both cattle products):
--
--   select net.http_post(
--     url := '.../functions/v1/market-quotes-sync',
--     body := '{"from":"2026-01-01","to":"2026-09-10",
--               "instruments":["feeder_cattle","live_cattle"],"months":8}'::jsonb,
--     headers := ...);
--
-- Applied 2026-09-10: 2,391 rows, 16 contracts, no errors. A second
-- identical run left the count at 2,391 - the upsert is idempotent.
--
-- The reach of a backfill is limited by the source: Yahoo drops a contract
-- once it expires, so only contracts still on the board have history. Those
-- go back to 2025-08/2025-10, well before the first sale on the books
-- (2026-04-20), but a contract that has already expired cannot be recovered.
-- =====================================================================
