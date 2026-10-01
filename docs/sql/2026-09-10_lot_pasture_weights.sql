-- 2026-09-10  What each pasture weighed, standing beside what is in it.
--
-- John, 2026-09-10: "stand visible at least as a note ... the time this
-- matters is in the growyard phase and cattle when we get closer to shipping
-- to have an accurate weight because different pastures perform differently
-- some years."
--
-- That answer narrows the problem in two ways worth writing down, because it
-- is what makes this safe when a general per-pasture anchor was not
-- (see docs/weight-estimation-design.md):
--
-- 1. The horizon is SHORT. A weighing taken a fortnight before shipping does
--    not have months to drift onto the wrong animals.
-- 2. Near shipping the PASTURE number is the one that gets used - trucks load
--    off pastures. The lot average is a closeout figure.
--
-- So this is a NOTE, not an anchor. It moves no projection, no cost and no
-- head. `lot_projected_weight()` is untouched, and a pasture weighing still
-- carries `applies_to='pasture'` and still anchors nothing. What changes is
-- that the number stops being invisible.
--
-- The staleness columns are the whole honesty of it. A weighing describes the
-- ANIMALS that were on the scale, not the pasture, so the moment head come or
-- go it is describing a group that no longer stands there. Rather than let it
-- decay silently, the view reports both signals and the screen turns amber.
--
-- Verified 2026-09-10 against 36-27, inserted and rolled back in one
-- transaction: pasture 3 at 76 hd read 480.0 gross / 465.6 booked, +38.0 vs
-- the lot's 427.6, and lot_status.projected_current_weight stayed 427.55 with
-- adg_source 'assumed' throughout. A 60-of-76 weighing set head_changed, and a
-- pasture whose cattle moved in on 9 Sep against a 1 Sep weighing set
-- moved_in_since.
--
-- Paste into the SQL editor WITHOUT the begin/commit lines.
begin;

create or replace view public.lot_pasture_weights
with (security_invoker = true) as
with sessions as (
    -- One weighing is one weigh_session_id (several scale drafts), summed
    -- back up - the same rule lot_weight_anchor follows. A sale or an
    -- individual weight is never a statement about the pasture.
    select w.lot_id,
           w.pasture_id,
           coalesce(w.weigh_session_id::text, 'd:' || w.weigh_date::text) as session_key,
           w.weigh_date,
           sum(w.head_weighed)      as head_weighed,
           sum(w.total_weight_lb)   as booked_lb,
           sum(w.gross_weight_lb)   as gross_lb,
           min(w.coverage)          as coverage,
           min(w.applies_to)        as applies_to,
           max(w.created_at)        as last_recorded_at
      from public.weights w
     where w.pasture_id is not null
       and w.weigh_date <= public.ranch_today()
       and w.weight_type <> all (array['sale','individual'])
     group by w.lot_id, w.pasture_id,
              coalesce(w.weigh_session_id::text, 'd:' || w.weigh_date::text),
              w.weigh_date
    having sum(w.head_weighed) > 0
       and sum(w.total_weight_lb) > 0
), newest as (
    select distinct on (s.lot_id, s.pasture_id) s.*
      from sessions s
     order by s.lot_id, s.pasture_id, s.weigh_date desc, s.last_recorded_at desc
)
select
    a.lot_id,
    a.pasture_id,
    a.head_count                                        as head_now,
    a.moved_in,
    n.weigh_date,
    n.head_weighed,
    n.coverage,
    round(n.booked_lb / n.head_weighed, 1)              as avg_booked_lb,
    case when n.gross_lb is not null and n.gross_lb > 0
         then round(n.gross_lb / n.head_weighed, 1) end as avg_gross_lb,
    case when n.weigh_date is not null
         then greatest(public.ranch_today() - n.weigh_date, 0) end as days_since,
    -- The lot's own estimate for the same day, so the note can say how far
    -- this pasture is off the lot average rather than making the reader hold
    -- two screens in their head.
    round(public.lot_projected_weight(a.lot_id, public.ranch_today()), 1) as lot_projected_lb,
    case when n.weigh_date is not null
         then round((n.booked_lb / n.head_weighed)
                    - public.lot_projected_weight(a.lot_id, public.ranch_today()), 1) end
                                                        as vs_lot_lb,
    -- Staleness. Either of these means the weighing is describing a group
    -- that is not what stands here now.
    (n.weigh_date is not null and n.head_weighed <> a.head_count) as head_changed,
    (n.weigh_date is not null and a.moved_in > n.weigh_date)      as moved_in_since
  from public.lot_pasture_assignments a
  left join newest n
    on n.lot_id = a.lot_id and n.pasture_id = a.pasture_id
 where a.moved_out is null;

comment on view public.lot_pasture_weights is
    'The most recent weighing covering each pasture a lot currently stands in, beside the head standing there now. A NOTE, never an anchor - it moves no projection, cost or head. head_changed / moved_in_since say when the weighing describes animals that are no longer the ones in that pasture.';

revoke all on public.lot_pasture_weights from public, anon;
grant select on public.lot_pasture_weights to authenticated, service_role;

do $verify$
DECLARE v_txt text; v_n integer;
BEGIN
    SELECT COALESCE(reloptions::text,'') INTO v_txt
      FROM pg_class WHERE oid='public.lot_pasture_weights'::regclass;
    IF v_txt NOT LIKE '%security_invoker=true%' THEN
        RAISE EXCEPTION 'lot_pasture_weights is not security_invoker: %', v_txt;
    END IF;
    IF has_table_privilege('anon','public.lot_pasture_weights','SELECT') THEN
        RAISE EXCEPTION 'anon can read lot_pasture_weights.';
    END IF;

    -- One row per OPEN assignment, no more and no fewer: this view must not
    -- invent or drop a pasture just because nobody has weighed it.
    SELECT count(*) INTO v_n FROM public.lot_pasture_assignments WHERE moved_out IS NULL;
    IF (SELECT count(*) FROM public.lot_pasture_weights) <> v_n THEN
        RAISE EXCEPTION 'lot_pasture_weights has % rows against % open assignments.',
            (SELECT count(*) FROM public.lot_pasture_weights), v_n;
    END IF;

    -- It is a note. Nothing here may have moved a projection.
    IF EXISTS (SELECT 1 FROM public.lot_status
                WHERE adg_source IS NULL AND projected_current_weight IS NOT NULL) THEN
        RAISE EXCEPTION 'A projected weight lost its provenance.';
    END IF;

    RAISE NOTICE 'lot_pasture_weights: % open assignments, % carrying a weighing.',
        v_n, (SELECT count(*) FROM public.lot_pasture_weights WHERE weigh_date IS NOT NULL);
END
$verify$;

commit;
