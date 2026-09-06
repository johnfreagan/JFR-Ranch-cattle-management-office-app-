-- =====================================================================
-- Bunk calling the SDSU way (2026-09-06, John): 0 / ½ / 1 / 2 / 3 scores,
-- dry matter and expected DMI on the ration, bump rules in settings
-- =====================================================================
-- Source: SDSU Extension "Feed Bunk Management" (Pritchard's 4-point
-- system). Score 0 = no feed left; ½ = scattered feed, bunk bottom mostly
-- showing; 1 = thin uniform layer about a kernel deep; 2 = 25-50% of the
-- delivery left; 3 = more than half left, crown disturbed. Goal: 0 most
-- days, ½ three or four days in ten. Increase 0.25-0.75 lb DM at a time,
-- not more often than every 3-5 days once cattle are on feed.
--
-- John's rule on top: bump harder while a pen is below the ration's
-- expected dry-matter intake, slower once it is eating it. The feed app
-- suggests the day's lb/hd from these numbers and records what it
-- suggested beside what was called, so an override is visible later.
--
-- Apply in the Supabase SQL editor. Idempotent.
-- =====================================================================

-- 1. Scores gain the half. numeric(2,1) so ½ stores as 0.5.
ALTER TABLE public.bunk_reads DROP CONSTRAINT IF EXISTS bunk_reads_bunk_score_check;
ALTER TABLE public.bunk_reads ALTER COLUMN bunk_score TYPE numeric(2,1) USING bunk_score::numeric(2,1);
ALTER TABLE public.bunk_reads ADD CONSTRAINT bunk_reads_bunk_score_check
    CHECK (bunk_score IS NULL OR bunk_score IN (0, 0.5, 1, 2, 3));

-- What the app suggested and why, beside what was called.
ALTER TABLE public.bunk_reads
    ADD COLUMN IF NOT EXISTS suggested_lb_per_head numeric,
    ADD COLUMN IF NOT EXISTS clean_days integer,
    ADD COLUMN IF NOT EXISTS suggest_note text;

-- 2. The ration knows its dry matter and the intake it should reach.
ALTER TABLE public.rations
    ADD COLUMN IF NOT EXISTS dry_matter_pct numeric
        CHECK (dry_matter_pct IS NULL OR (dry_matter_pct > 0 AND dry_matter_pct <= 100)),
    ADD COLUMN IF NOT EXISTS expected_dmi_lb numeric
        CHECK (expected_dmi_lb IS NULL OR expected_dmi_lb > 0);

-- 3. Bump rules, ranch-wide, SDSU defaults. Office edits them on screen.
ALTER TABLE public.ranch_settings
    ADD COLUMN IF NOT EXISTS bunk_fast_days integer NOT NULL DEFAULT 2 CHECK (bunk_fast_days >= 1),
    ADD COLUMN IF NOT EXISTS bunk_fast_bump_lb_dm numeric NOT NULL DEFAULT 0.75 CHECK (bunk_fast_bump_lb_dm >= 0),
    ADD COLUMN IF NOT EXISTS bunk_slow_days integer NOT NULL DEFAULT 3 CHECK (bunk_slow_days >= 1),
    ADD COLUMN IF NOT EXISTS bunk_slow_bump_lb_dm numeric NOT NULL DEFAULT 0.5 CHECK (bunk_slow_bump_lb_dm >= 0),
    ADD COLUMN IF NOT EXISTS bunk_cut2_lb_dm numeric NOT NULL DEFAULT 0.5 CHECK (bunk_cut2_lb_dm >= 0),
    ADD COLUMN IF NOT EXISTS bunk_cut3_lb_dm numeric NOT NULL DEFAULT 1.0 CHECK (bunk_cut3_lb_dm >= 0);

DO $verify$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='bunk_reads' AND column_name='bunk_score' AND data_type='numeric') THEN
        RAISE EXCEPTION 'bunk_score is not numeric';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='rations' AND column_name='expected_dmi_lb') THEN
        RAISE EXCEPTION 'rations.expected_dmi_lb missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='ranch_settings' AND column_name='bunk_cut3_lb_dm') THEN
        RAISE EXCEPTION 'ranch_settings bunk rules missing';
    END IF;
    RAISE NOTICE 'bunk_scoring: OK';
END
$verify$;
