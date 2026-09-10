-- 2026-09-10  Markets and hedge positions.
--
-- The database has never held a price it did not pay itself. This adds the
-- minimum needed to mark cattle to market and to answer "how much of what we
-- expect to sell in October is covered?".
--
--   market_quotes      one settle per (day, instrument, contract month)
--   positions          futures, options, LRP and forwards in ONE table
--   position_lot_links which lots a position covers (many-to-many)
--   hedge_coverage_by_month (view)  the question above, answered
--
-- Touches no existing table. Three new tables, one new view, one immutable
-- helper function.
--
-- Idempotent: IF NOT EXISTS throughout, guarded constraint adds, CREATE OR
-- REPLACE on the view and function.
-- Paste into the SQL editor WITHOUT the begin/commit lines.
begin;

-- =====================================================================
-- UNITS - read this before touching any price column in this file
--
-- CME quotes feeder and live cattle in US CENTS PER POUND. 325.725 means
-- 325.725 cents/lb, which is the same number as $325.725 per cwt and is
-- what the trade says out loud ("cattle traded three and a quarter").
-- Corn is US cents per BUSHEL.
--
-- Every price column here is stored AS QUOTED, so `settle`, `strike`,
-- `entry_price`, `exit_price` and `coverage_price` are all cents/lb for
-- cattle. `premium` is DOLLARS PER HEAD, because that is how an LRP
-- endorsement is billed.
--
-- This is deliberately the same convention as `lots.target_sale_cwt`,
-- which is $/lb despite its name and is multiplied by a weight in pounds.
-- Do not "helpfully" convert one without the other.
-- =====================================================================

-- =====================================================================
-- 1. market_quotes
-- =====================================================================
create table if not exists public.market_quotes (
    id             uuid primary key default gen_random_uuid(),
    quote_date     date        not null,
    instrument     text        not null,
    contract_month date        not null,
    settle         numeric     not null,
    source         text        not null,
    created_at     timestamptz not null default now()
);

do $$
begin
    if not exists (select 1 from pg_constraint
                   where conname='market_quotes_instrument_check'
                     and conrelid='public.market_quotes'::regclass) then
        alter table public.market_quotes add constraint market_quotes_instrument_check
            check (instrument = any (array['feeder_cattle','live_cattle','corn']));
    end if;

    -- A contract month IS a month. Storing the 15th would split one contract
    -- across two keys and the upsert would stop being idempotent.
    if not exists (select 1 from pg_constraint
                   where conname='market_quotes_contract_month_check'
                     and conrelid='public.market_quotes'::regclass) then
        alter table public.market_quotes add constraint market_quotes_contract_month_check
            check (extract(day from contract_month) = 1);
    end if;

    -- A zero settle is a parse failure wearing a number's clothes. Refuse it
    -- here so a bad ingestion run fails loudly instead of quietly marking the
    -- herd to nothing.
    if not exists (select 1 from pg_constraint
                   where conname='market_quotes_settle_check'
                     and conrelid='public.market_quotes'::regclass) then
        alter table public.market_quotes add constraint market_quotes_settle_check
            check (settle > 0);
    end if;

    if not exists (select 1 from pg_constraint
                   where conname='market_quotes_uniq'
                     and conrelid='public.market_quotes'::regclass) then
        alter table public.market_quotes add constraint market_quotes_uniq
            unique (quote_date, instrument, contract_month);
    end if;
end $$;

-- "What is the latest quote for the October board?" is the only read this
-- table gets from the app, and the unique index leads on quote_date.
create index if not exists market_quotes_curve_idx
    on public.market_quotes (instrument, contract_month, quote_date desc);

comment on table public.market_quotes is
    'One settlement per (quote_date, instrument, contract_month). Cattle prices are US cents per pound = $/cwt; corn is cents per bushel. `source` records where the number came from and is never blank.';
comment on column public.market_quotes.settle is
    'AS QUOTED. Cattle: cents per lb (= $/cwt). Corn: cents per bushel.';
comment on column public.market_quotes.source is
    'Provenance of this number, e.g. yahoo_chart:GFV26.CME. Not an official CME settlement unless it says so.';

-- =====================================================================
-- 2. positions - futures, options, LRP and forwards in one table
--
--    One table rather than four because every one of them answers the same
--    question ("how many pounds, in which month, at what price") and the
--    coverage view has to add them together. Four tables would mean four
--    joins and four chances for one of them to be forgotten.
--
--    The cost of one table is that most columns are nullable, so the
--    per-type CHECKs below are the whole integrity story. Each names the
--    fields its type cannot do without.
-- =====================================================================
create table if not exists public.positions (
    id              uuid primary key default gen_random_uuid(),
    position_type   text        not null,
    instrument      text,
    contract_month  date,
    side            text,
    option_type     text,
    contracts       numeric,
    head            integer,
    lb_per_head     numeric,
    total_lb        numeric,
    strike          numeric,
    entry_price     numeric,
    coverage_price  numeric,
    premium         numeric,
    trade_date      date        not null,
    end_date        date,
    counterparty    text,
    account         text,
    status          text        not null default 'open',
    exit_price      numeric,
    exit_date       date,
    notes           text,
    created_at      timestamptz not null default now(),
    created_by      uuid        default auth.uid() references auth.users(id)
);

do $$
declare
    v_name text;
begin
    -- Drop and re-add every CHECK so a re-run reconciles a hand-edited
    -- constraint rather than skipping it because the NAME happened to exist.
    foreach v_name in array array[
        'positions_type_check','positions_instrument_check','positions_side_check',
        'positions_option_type_check','positions_status_check','positions_month_check',
        'positions_futures_fields','positions_option_fields','positions_lrp_fields',
        'positions_forward_fields','positions_quantified_check','positions_closed_check',
        'positions_contracts_check','positions_head_check'
    ] loop
        if exists (select 1 from pg_constraint
                   where conname = v_name and conrelid='public.positions'::regclass) then
            execute format('alter table public.positions drop constraint %I', v_name);
        end if;
    end loop;

    alter table public.positions add constraint positions_type_check
        check (position_type = any (array[
            'futures','option','lrp','forward_sale','forward_purchase']));

    alter table public.positions add constraint positions_instrument_check
        check (instrument is null or instrument = any (array[
            'feeder_cattle','live_cattle','corn']));

    alter table public.positions add constraint positions_side_check
        check (side is null or side = any (array['long','short']));

    -- A put and a call are opposite exposures, so an option row without one
    -- cannot be scored as coverage. `option_type` is the ONE column added
    -- beyond the specified list, for that reason.
    alter table public.positions add constraint positions_option_type_check
        check ((option_type is null or option_type = any (array['put','call']))
               and (option_type is null or position_type = 'option'));

    alter table public.positions add constraint positions_status_check
        check (status = any (array['open','closed','expired']));

    alter table public.positions add constraint positions_month_check
        check (contract_month is null or extract(day from contract_month) = 1);

    alter table public.positions add constraint positions_contracts_check
        check (contracts is null or contracts > 0);

    alter table public.positions add constraint positions_head_check
        check (head is null or head > 0);

    -- ---- what each type cannot do without ---------------------------
    alter table public.positions add constraint positions_futures_fields
        check (position_type <> 'futures' or (
            instrument     is not null and
            contract_month is not null and
            side           is not null and
            contracts      is not null));

    alter table public.positions add constraint positions_option_fields
        check (position_type <> 'option' or (
            instrument     is not null and
            contract_month is not null and
            side           is not null and
            option_type    is not null and
            contracts      is not null and
            strike         is not null));

    -- An LRP endorsement is head, a coverage price and an end date. There is
    -- no contract month and no side; it is insurance, not a trade.
    alter table public.positions add constraint positions_lrp_fields
        check (position_type <> 'lrp' or (
            coverage_price is not null and
            head           is not null and
            end_date       is not null));

    alter table public.positions add constraint positions_forward_fields
        check (position_type not in ('forward_sale','forward_purchase') or (
            entry_price is not null and
            end_date    is not null));

    -- The SUM()-ignores-NULL trap, closed at the door. A position whose
    -- pounds cannot be derived would drop silently out of the coverage view
    -- and read as "not hedged" while the hedge sat right there. Futures and
    -- options get their pounds from the contract size; everything else has
    -- to carry them.
    alter table public.positions add constraint positions_quantified_check
        check (position_type in ('futures','option')
               or total_lb is not null
               or (head is not null and lb_per_head is not null));

    -- Closing is an event with a date. Without this a position can read
    -- 'closed' with nothing saying when, and it silently leaves the
    -- coverage view with no audit trail.
    alter table public.positions add constraint positions_closed_check
        check (status <> 'closed' or exit_date is not null);
end $$;

create index if not exists positions_status_idx    on public.positions (status, trade_date desc);
create index if not exists positions_month_idx     on public.positions (contract_month);

comment on table public.positions is
    'Futures, options, LRP endorsements and cash forwards in one table. Per-type CHECK constraints name the fields each kind requires. Prices are as quoted (cattle: cents/lb = $/cwt); premium is $/head.';
comment on column public.positions.option_type is
    'put | call. Required for options - a long put and a long call are opposite exposures and coverage cannot be scored without it.';
comment on column public.positions.total_lb is
    'Pounds this position covers. Authoritative when set; otherwise derived from contracts x contract size, or head x lb_per_head.';
comment on column public.positions.premium is
    'DOLLARS PER HEAD (LRP producer premium), not cents/lb.';

-- =====================================================================
-- 3. position_lot_links
--    A position may cover several lots; a lot may be covered by several
--    positions. The same pair twice is a typo, not a second allocation.
-- =====================================================================
create table if not exists public.position_lot_links (
    id             uuid primary key default gen_random_uuid(),
    position_id    uuid not null references public.positions(id) on delete cascade,
    lot_id         uuid not null references public.lots(id),
    lb_allocated   numeric,
    head_allocated integer,
    created_at     timestamptz not null default now()
);

do $$
begin
    if not exists (select 1 from pg_constraint
                   where conname='position_lot_links_uniq'
                     and conrelid='public.position_lot_links'::regclass) then
        alter table public.position_lot_links add constraint position_lot_links_uniq
            unique (position_id, lot_id);
    end if;
end $$;

create index if not exists position_lot_links_lot_idx on public.position_lot_links (lot_id);

comment on table public.position_lot_links is
    'Which lots a position covers. ON DELETE CASCADE from positions (a link has no meaning without its position); RESTRICT against lots, which are audit history.';

-- =====================================================================
-- 4. Contract sizes, defined once
--
--    Feeder cattle 50,000 lb, live cattle 40,000 lb. Corn is 5,000
--    BUSHELS and returns NULL on purpose: corn is an input hedge and must
--    never add pounds to cattle sale coverage.
-- =====================================================================
create or replace function public.futures_contract_lb(p_instrument text)
returns numeric
language sql
immutable
set search_path to 'public'
as $function$
    select case p_instrument
             when 'feeder_cattle' then 50000::numeric
             when 'live_cattle'   then 40000::numeric
             else null::numeric
           end;
$function$;

comment on function public.futures_contract_lb(text) is
    'Deliverable pounds per futures contract. NULL for corn (5,000 bushels), so an input hedge can never be counted as cattle sale coverage.';

-- =====================================================================
-- 5. hedge_coverage_by_month
--
--    Expected pounds come from open lots with a target ship date; covered
--    pounds from open positions that PROTECT A SALE. What counts:
--      short futures, long puts, LRP, forward sales.
--    What does not: long futures, short puts, calls, forward purchases and
--    anything in corn - none of them put a floor under cattle we will sell.
--
--    Futures and options bucket on contract_month; LRP and forwards on the
--    month of end_date, which is the month the protection actually covers.
--
--    `positions_unquantified` should always be 0 - positions_quantified_check
--    makes it so - and is carried anyway, because a coverage number that
--    silently omits a position is worse than one that says it did.
--
--    **lb_expected is NULL until a lot carries `target_ship_weight`, and no
--    open lot carries one today.** Falling back to a projected weight was
--    considered and refused: a projection of TODAY's weight is not the
--    expected SALE weight, it is smaller, so using it would OVERSTATE
--    pct_covered - telling John he is better hedged than he is, which is the
--    one direction that costs money. So the view refuses to guess and
--    instead says why it is blank: `lots_missing_ship_weight` counts the
--    lots in that month with no target ship weight. Set those and the
--    percentage lights up with no code change.
-- =====================================================================
create or replace view public.hedge_coverage_by_month
with (security_invoker = true) as
with expected as (
    select date_trunc('month', l.target_ship_date)::date as sale_month,
           sum(ls.head_current)                          as head_expected,
           sum(ls.head_current * l.target_ship_weight)   as lb_expected,
           count(*) filter (where l.target_ship_weight is null)
                                                         as lots_missing_ship_weight
      from public.lots l
      join public.lot_status ls on ls.lot_id = l.id
     where l.closed_at is null
       and l.target_ship_date is not null
       and coalesce(l.is_test, false)     = false
       and coalesce(l.is_feed_pen, false) = false
       and ls.head_current > 0
     group by 1
), covered as (
    select date_trunc('month',
             case when p.position_type in ('futures','option')
                  then p.contract_month else p.end_date end)::date as sale_month,
           sum(coalesce(
                 p.total_lb,
                 p.contracts * public.futures_contract_lb(p.instrument),
                 p.head * p.lb_per_head))                          as lb_covered,
           count(*)                                                as positions_counted,
           count(*) filter (where coalesce(
                 p.total_lb,
                 p.contracts * public.futures_contract_lb(p.instrument),
                 p.head * p.lb_per_head) is null)                  as positions_unquantified
      from public.positions p
     where p.status = 'open'
       and coalesce(p.instrument, 'feeder_cattle') <> 'corn'
       and (
             (p.position_type = 'futures' and p.side = 'short')
          or (p.position_type = 'option'  and p.side = 'long' and p.option_type = 'put')
          or  p.position_type = 'lrp'
          or  p.position_type = 'forward_sale'
       )
       and case when p.position_type in ('futures','option')
                then p.contract_month else p.end_date end is not null
     group by 1
)
select
    coalesce(e.sale_month, c.sale_month)          as sale_month,
    e.head_expected,
    e.lb_expected,
    coalesce(c.lb_covered, 0)                     as lb_covered,
    coalesce(c.positions_counted, 0)              as positions_counted,
    coalesce(c.positions_unquantified, 0)         as positions_unquantified,
    case when e.lb_expected > 0
         then round(coalesce(c.lb_covered, 0) / e.lb_expected * 100, 1)
    end                                           as pct_covered,
    case when e.lb_expected is not null
         then e.lb_expected - coalesce(c.lb_covered, 0)
    end                                           as lb_open,
    -- APPENDED, not slotted in beside head_expected: CREATE OR REPLACE VIEW
    -- can only add columns at the END. Same rule that shaped lot_status.
    coalesce(e.lots_missing_ship_weight, 0)       as lots_missing_ship_weight
  from expected e
  full outer join covered c on c.sale_month = e.sale_month;

comment on view public.hedge_coverage_by_month is
    'Pounds expected to sell against pounds protected, by month. Only short futures, long puts, LRP and forward sales count as coverage; corn never does. lb_expected is NULL until a lot carries target_ship_weight - never estimated, because overstating coverage is the expensive direction - and lots_missing_ship_weight says how many lots are the reason. A month with positions but no expected pounds (or the reverse) still appears; the full outer join is deliberate.';

revoke all on public.market_quotes         from public, anon;
revoke all on public.positions             from public, anon;
revoke all on public.position_lot_links    from public, anon;
revoke all on public.hedge_coverage_by_month from public, anon;
grant select, insert, update, delete on public.market_quotes      to authenticated;
grant select, insert, update, delete on public.positions          to authenticated;
grant select, insert, update, delete on public.position_lot_links to authenticated;
grant select on public.hedge_coverage_by_month to authenticated;
grant all on public.market_quotes         to service_role;
grant all on public.positions             to service_role;
grant all on public.position_lot_links    to service_role;
grant select on public.hedge_coverage_by_month to service_role;

-- =====================================================================
-- 6. RLS - the shape every books table on this database already uses:
--    read through can_read_books(), write owner+office, delete owner only.
--    Copied from lot_transfers / supply_invoices / feed_price_variance
--    rather than invented.
--
--    The ingestion edge function writes as the SERVICE ROLE, which bypasses
--    RLS - it has no user and so no role in user_profiles. That is why
--    market_quotes needs no "robot" policy.
-- =====================================================================
alter table public.market_quotes      enable row level security;
alter table public.positions          enable row level security;
alter table public.position_lot_links enable row level security;

do $$
declare
    t text;
begin
    foreach t in array array['market_quotes','positions','position_lot_links'] loop
        execute format('drop policy if exists %I on public.%I', t || '_select', t);
        execute format('drop policy if exists %I on public.%I', t || '_insert', t);
        execute format('drop policy if exists %I on public.%I', t || '_update', t);
        execute format('drop policy if exists %I on public.%I', t || '_delete', t);

        execute format(
            'create policy %I on public.%I for select using (public.can_read_books())',
            t || '_select', t);
        execute format(
            'create policy %I on public.%I for insert with check '
            '(public.current_user_role() = any (array[''owner'',''office'']))',
            t || '_insert', t);
        execute format(
            'create policy %I on public.%I for update using '
            '(public.current_user_role() = any (array[''owner'',''office''])) with check '
            '(public.current_user_role() = any (array[''owner'',''office'']))',
            t || '_update', t);
        execute format(
            'create policy %I on public.%I for delete using '
            '(public.current_user_role() = ''owner'')',
            t || '_delete', t);
    end loop;
end $$;

-- =====================================================================
-- VERIFY - raises rather than reporting a quiet success
-- =====================================================================
do $verify$
DECLARE
    t        text;
    v_txt    text;
    v_n      integer;
BEGIN
    -- RLS on, four policies each, nothing reachable by anon.
    FOREACH t IN ARRAY ARRAY['market_quotes','positions','position_lot_links'] LOOP
        IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.'||t)::regclass) THEN
            RAISE EXCEPTION 'RLS is not enabled on public.%', t;
        END IF;
        SELECT count(*) INTO v_n FROM pg_policies
         WHERE schemaname='public' AND tablename=t;
        IF v_n <> 4 THEN
            RAISE EXCEPTION 'public.% has % policies, expected 4 (select/insert/update/delete).', t, v_n;
        END IF;
        IF has_table_privilege('anon','public.'||t,'SELECT') THEN
            RAISE EXCEPTION 'anon can read public.% - the publishable key is public.', t;
        END IF;
    END LOOP;

    IF has_table_privilege('anon','public.hedge_coverage_by_month','SELECT') THEN
        RAISE EXCEPTION 'anon can read hedge_coverage_by_month.';
    END IF;

    -- The view must enforce RLS. CREATE OR REPLACE VIEW clears reloptions
    -- when the WITH clause is omitted.
    SELECT COALESCE(reloptions::text,'') INTO v_txt
      FROM pg_class WHERE oid='public.hedge_coverage_by_month'::regclass;
    IF v_txt NOT LIKE '%security_invoker=true%' THEN
        RAISE EXCEPTION 'hedge_coverage_by_month is not security_invoker: reloptions = %', v_txt;
    END IF;

    -- The per-type CHECKs actually exist.
    SELECT string_agg(c, ', ') INTO v_txt FROM unnest(ARRAY[
        'positions_futures_fields','positions_option_fields','positions_lrp_fields',
        'positions_forward_fields','positions_quantified_check','positions_closed_check'
    ]) AS c
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conname = c AND conrelid='public.positions'::regclass);
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'Missing per-type CHECK constraint(s): %.', v_txt;
    END IF;

    -- And they actually bite. A futures row with no side must be refused;
    -- if this INSERT succeeds the constraint is decoration.
    BEGIN
        INSERT INTO public.positions (position_type, instrument, contract_month, contracts, trade_date)
        VALUES ('futures','feeder_cattle', date '2026-10-01', 1, date '2026-09-10');
        RAISE EXCEPTION 'positions_futures_fields did not refuse a futures row with no side.';
    EXCEPTION WHEN check_violation THEN
        NULL;  -- refused, which is the point
    END;

    BEGIN
        INSERT INTO public.positions (position_type, coverage_price, head, end_date, trade_date)
        VALUES ('lrp', 300, 100, date '2026-11-01', date '2026-09-10');
        RAISE EXCEPTION 'positions_quantified_check did not refuse an LRP with no poundage.';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- Contract sizes.
    IF public.futures_contract_lb('feeder_cattle') <> 50000
       OR public.futures_contract_lb('live_cattle') <> 40000
       OR public.futures_contract_lb('corn') IS NOT NULL THEN
        RAISE EXCEPTION 'futures_contract_lb returns the wrong contract sizes.';
    END IF;

    RAISE NOTICE 'markets/positions verified: 3 tables x 4 policies, per-type CHECKs refuse bad rows, view is security_invoker, nothing granted to anon.';
END
$verify$;

commit;
