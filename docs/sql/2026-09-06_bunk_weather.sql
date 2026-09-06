-- =====================================================================
-- Bunk calling, round two (2026-09-06, John): intake as a percent of
-- estimated body weight, daily weather beside consumption, flags
-- =====================================================================
-- Expected dry-matter intake is a PERCENT OF BODY WEIGHT on the ration;
-- the app turns it into pounds from each lot's estimated weight today
-- (lot_status.projected_current_weight: weight in + target ADG x days on
-- feed), head-weighted over the lots in the pasture. So the target climbs
-- as the cattle grow, which is what a flat lb/hd could not do.
-- expected_dmi_lb stays as the fallback for a lot with no weights yet.
--
-- Weather: one row per day for the ranch, pulled by the feed app from
-- Open-Meteo (free, no key) at the barn each morning. Consumption gets
-- compared against it later; today it sits in the trend matrix beside
-- the score and the pounds delivered.
--
-- Apply in the Supabase SQL editor. Idempotent.
-- =====================================================================

ALTER TABLE public.rations
    ADD COLUMN IF NOT EXISTS expected_dmi_pct_bw numeric
        CHECK (expected_dmi_pct_bw IS NULL OR (expected_dmi_pct_bw > 0 AND expected_dmi_pct_bw <= 6));

ALTER TABLE public.bunk_reads
    ADD COLUMN IF NOT EXISTS est_weight_lb numeric,        -- head-weighted estimated weight used that morning
    ADD COLUMN IF NOT EXISTS expected_dmi_lb numeric,      -- the lb DM/hd target the caller worked against
    ADD COLUMN IF NOT EXISTS flags text[] NOT NULL DEFAULT '{}';   -- mud, sick_pull, waterer, storm

ALTER TABLE public.ranch_settings
    ADD COLUMN IF NOT EXISTS ranch_lat numeric NOT NULL DEFAULT 31.31,
    ADD COLUMN IF NOT EXISTS ranch_lon numeric NOT NULL DEFAULT -96.63;

CREATE TABLE IF NOT EXISTS public.daily_weather (
    weather_date   date PRIMARY KEY,
    high_f         numeric,
    low_f          numeric,
    precip_in      numeric,
    wind_max_mph   numeric,
    weather_code   integer,        -- WMO code as Open-Meteo reports it
    is_forecast    boolean NOT NULL DEFAULT false,
    source         text NOT NULL DEFAULT 'open-meteo',
    fetched_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.daily_weather ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS daily_weather_select ON public.daily_weather;
DROP POLICY IF EXISTS daily_weather_insert ON public.daily_weather;
DROP POLICY IF EXISTS daily_weather_update ON public.daily_weather;
DROP POLICY IF EXISTS daily_weather_delete ON public.daily_weather;
CREATE POLICY daily_weather_select ON public.daily_weather FOR SELECT USING (public.can_read_operational());
CREATE POLICY daily_weather_insert ON public.daily_weather FOR INSERT
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office','crew']));
CREATE POLICY daily_weather_update ON public.daily_weather FOR UPDATE
    USING (public.current_user_role() = ANY (ARRAY['owner','office','crew']))
    WITH CHECK (public.current_user_role() = ANY (ARRAY['owner','office','crew']));
CREATE POLICY daily_weather_delete ON public.daily_weather FOR DELETE USING (public.current_user_role() = 'owner');
GRANT SELECT, INSERT, UPDATE, DELETE ON public.daily_weather TO authenticated;
REVOKE ALL ON public.daily_weather FROM PUBLIC, anon;

DO $verify$
BEGIN
    IF to_regclass('public.daily_weather') IS NULL THEN RAISE EXCEPTION 'daily_weather missing'; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rations' AND column_name='expected_dmi_pct_bw') THEN
        RAISE EXCEPTION 'rations.expected_dmi_pct_bw missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='bunk_reads' AND column_name='flags') THEN
        RAISE EXCEPTION 'bunk_reads.flags missing';
    END IF;
    RAISE NOTICE 'bunk_weather: OK';
END
$verify$;
