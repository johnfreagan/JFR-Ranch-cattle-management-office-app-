-- Field counts and test weights — schema for the field app → approvals path.
--
-- Two new kinds of staged field entry ('count', 'weight'), and the shrink
-- model for a test weight.
--
-- Idempotent. Paste into the Supabase SQL editor WITHOUT begin/commit —
-- the editor swallows them and can report success having applied nothing.
--
-- Nothing in the books reads `weights` today: the table is empty and no view
-- or report consumes it. So this migration cannot move an existing number.

-- ---------------------------------------------------------------
-- 1. pending_field_entries accepts counts and weights
-- ---------------------------------------------------------------
do $$
begin
    if exists (select 1 from pg_constraint
               where conname = 'pfe_entry_type_check'
                 and conrelid = 'public.pending_field_entries'::regclass) then
        alter table public.pending_field_entries drop constraint pfe_entry_type_check;
    end if;

    alter table public.pending_field_entries
        add constraint pfe_entry_type_check
        check (entry_type = any (array['doctoring','move','count','weight']));
end $$;

-- ---------------------------------------------------------------
-- 2. The shrink model on `weights`
--
--    Store GROSS, the allowance, and the BOOKED weight separately. Actual
--    shrink has to calibrate on gross or each estimate's error compounds
--    into the next — the same rule the silage allowance follows.
--
--    total_weight_lb keeps its meaning as what the books use: the BOOKED
--    (shrunk) weight. gross_weight_lb is what came off the scale.
-- ---------------------------------------------------------------
alter table public.weights
    add column if not exists gross_weight_lb   numeric(10,2),
    add column if not exists shrink_pct        numeric(5,2),
    add column if not exists weigh_method      text,
    add column if not exists applies_to        text,
    add column if not exists pasture_id        uuid,
    add column if not exists weigh_session_id  uuid,
    add column if not exists draft_no          smallint;

do $$
begin
    -- Ground weights carry more fill than cattle that have been hauled, so
    -- they shrink harder: 3% off the ground, 2% hauled and weighed.
    if not exists (select 1 from pg_constraint
                   where conname = 'weights_weigh_method_check'
                     and conrelid = 'public.weights'::regclass) then
        alter table public.weights add constraint weights_weigh_method_check
            check (weigh_method is null or weigh_method = any (array['ground','hauled']));
    end if;

    -- Whether this sample stands for the pasture it came off, or for the
    -- whole lot. The office decides that at approval, not the cowboy.
    if not exists (select 1 from pg_constraint
                   where conname = 'weights_applies_to_check'
                     and conrelid = 'public.weights'::regclass) then
        alter table public.weights add constraint weights_applies_to_check
            check (applies_to is null or applies_to = any (array['pasture','lot']));
    end if;

    if not exists (select 1 from pg_constraint
                   where conname = 'weights_shrink_pct_check'
                     and conrelid = 'public.weights'::regclass) then
        alter table public.weights add constraint weights_shrink_pct_check
            check (shrink_pct is null or (shrink_pct >= 0 and shrink_pct < 50));
    end if;

    -- A shrink percentage with nothing to apply it to is meaningless, and
    -- booking MORE than came off the scale is always an error.
    if not exists (select 1 from pg_constraint
                   where conname = 'weights_gross_present_check'
                     and conrelid = 'public.weights'::regclass) then
        alter table public.weights add constraint weights_gross_present_check
            check (shrink_pct is null or gross_weight_lb is not null);
    end if;

    if not exists (select 1 from pg_constraint
                   where conname = 'weights_booked_le_gross_check'
                     and conrelid = 'public.weights'::regclass) then
        alter table public.weights add constraint weights_booked_le_gross_check
            check (gross_weight_lb is null or total_weight_lb <= gross_weight_lb);
    end if;

    if not exists (select 1 from pg_constraint
                   where conname = 'weights_pasture_id_fkey'
                     and conrelid = 'public.weights'::regclass) then
        alter table public.weights add constraint weights_pasture_id_fkey
            foreign key (pasture_id) references public.pastures(id);
    end if;
end $$;

-- One weighing is several scale drafts; weigh_session_id groups them so the
-- aggregate can be rebuilt and each drag stays visible underneath it.
create index if not exists weights_session_idx on public.weights (weigh_session_id);
create index if not exists weights_lot_date_idx on public.weights (lot_id, weigh_date desc);

comment on column public.weights.gross_weight_lb is
    'Raw off the scale, before shrink. Shrink calibrates on THIS, never on the booked weight.';
comment on column public.weights.shrink_pct is
    'True shrink set by the office at approval. Default 3 for ground, 2 for hauled.';
comment on column public.weights.total_weight_lb is
    'BOOKED weight = gross x (1 - shrink_pct/100). What any future calculation would read.';
comment on column public.weights.applies_to is
    'Whether the sample stands for the pasture it came off or the whole lot. Office decides at approval.';

-- ---------------------------------------------------------------
-- 3. Verify — raises rather than reporting a quiet success
-- ---------------------------------------------------------------
do $$
declare
    v_missing text;
    v_types   text;
begin
    select string_agg(c, ', ') into v_missing
    from unnest(array['gross_weight_lb','shrink_pct','weigh_method','applies_to',
                      'pasture_id','weigh_session_id','draft_no']) c
    where not exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='weights' and column_name=c);
    if v_missing is not null then
        raise exception 'weights is missing: %', v_missing;
    end if;

    select pg_get_constraintdef(oid) into v_types
    from pg_constraint
    where conname='pfe_entry_type_check' and conrelid='public.pending_field_entries'::regclass;
    if v_types is null or v_types not like '%count%' or v_types not like '%weight%' then
        raise exception 'pending_field_entries entry_type still refuses count/weight: %', coalesce(v_types,'(no constraint)');
    end if;

    -- pasture_check is the test-weight type and already existed; assert it
    -- rather than assume, because the app writes exactly that string.
    if (select pg_get_constraintdef(oid) from pg_constraint
        where conname='weights_weight_type_check' and conrelid='public.weights'::regclass)
       not like '%pasture_check%' then
        raise exception 'weights.weight_type does not allow pasture_check';
    end if;

    raise notice 'OK: counts and weights accepted; shrink model on weights in place.';
end $$;
