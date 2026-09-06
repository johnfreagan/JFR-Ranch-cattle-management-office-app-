-- =====================================================================
-- Bunk cuts become PERCENTAGES (2026-09-06, John: "I want to cut
-- percentages, 3 usually means a big cut")
-- =====================================================================
-- Bumps stay in pounds of dry matter - SDSU's 0.25-0.75 lb DM band is
-- written that way, and a bump is about closing a gap to a target intake
-- that is itself in pounds. A CUT is different: it is a proportional
-- pull-back from what the pen was offered, and half a pound off a pen
-- eating 16 lb DM is a 3% trim nobody would notice, while the same half
-- pound off starter cattle eating 7 is twice the cut. A percent stays
-- right as the ration steps up and the cattle grow.
--
-- Defaults: score 2 (25-50% left) -10%, score 3 (over half left) -25%.
-- The old lb-DM columns are LEFT IN PLACE, unread, as the audit of what
-- the rules were before today. Nothing recomputes: a call already saved
-- keeps the number it was called at.
--
-- Apply in the Supabase SQL editor. Idempotent.
-- =====================================================================

ALTER TABLE public.ranch_settings
    ADD COLUMN IF NOT EXISTS bunk_cut2_pct numeric NOT NULL DEFAULT 10
        CHECK (bunk_cut2_pct >= 0 AND bunk_cut2_pct <= 90),
    ADD COLUMN IF NOT EXISTS bunk_cut3_pct numeric NOT NULL DEFAULT 25
        CHECK (bunk_cut3_pct >= 0 AND bunk_cut3_pct <= 90);

COMMENT ON COLUMN public.ranch_settings.bunk_cut2_pct IS
    'Bunk score 2 (25-50% left): cut this percent off yesterday''s lb/hd call.';
COMMENT ON COLUMN public.ranch_settings.bunk_cut3_pct IS
    'Bunk score 3 (over half left): cut this percent off yesterday''s lb/hd call.';
COMMENT ON COLUMN public.ranch_settings.bunk_cut2_lb_dm IS
    'Superseded 2026-09-06 by bunk_cut2_pct. Kept as the audit of the old rule; not read.';
COMMENT ON COLUMN public.ranch_settings.bunk_cut3_lb_dm IS
    'Superseded 2026-09-06 by bunk_cut3_pct. Kept as the audit of the old rule; not read.';

DO $verify$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'ranch_settings'
       AND column_name IN ('bunk_cut2_pct', 'bunk_cut3_pct');
    IF n <> 2 THEN RAISE EXCEPTION 'bunk cut percent columns missing (found %)', n; END IF;
    RAISE NOTICE 'bunk_cut_pct: OK';
END
$verify$;
