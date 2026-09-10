// market-quotes-sync
//
// Pulls daily settlement prices for the listed CME contract months into
// public.market_quotes. Runs on a schedule (pg_cron -> pg_net) and can be
// invoked by hand with a date range to backfill.
//
// SOURCE, AND WHAT IT IS NOT
// Yahoo's chart API. Free, no key, and carries one series per LISTED
// contract month (GFV26.CME = feeder cattle, Oct 2026), which is exactly
// the grain market_quotes stores. What it gives is the session's CLOSE,
// which is not CME's official settlement - settlements are a licensed
// product. Every row records source as `yahoo_chart:<symbol>` and never
// claims otherwise.
//
// KNOWN LIMIT: Yahoo drops a contract once it expires (GFH26.CME already
// 404s), so a backfill only reaches as far back as the CURRENTLY LISTED
// contracts have traded.
//
// UNITS: stored exactly as quoted. Cattle are US cents per pound, the same
// number as dollars per hundredweight. Corn is cents per bushel.

import { createClient } from "jsr:@supabase/supabase-js@2";

const MONTH_CODE: Record<string, number> = {
  F: 1, G: 2, H: 3, J: 4, K: 5, M: 6, N: 7, Q: 8, U: 9, V: 10, X: 11, Z: 12,
};

// Which months each product actually lists, and how Yahoo spells the symbol.
// Asking for a month a product does not list (GFZ26 - there is no December
// feeder contract) returns 404, so the lists are not cosmetic.
const PRODUCTS: Record<string, { root: string; suffix: string; months: string[] }> = {
  feeder_cattle: { root: "GF", suffix: ".CME", months: ["F", "H", "J", "K", "Q", "U", "V", "X"] },
  live_cattle:   { root: "LE", suffix: ".CME", months: ["G", "J", "M", "Q", "V", "Z"] },
  corn:          { root: "ZC", suffix: ".CBT", months: ["H", "K", "N", "U", "Z"] },
};

const YAHOO = "https://query1.finance.yahoo.com/v8/finance/chart";
const UA = "Mozilla/5.0 (compatible; JFR-Ranch-market-sync/1.0)";

function isoDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/** The next `count` listed contract months for a product, starting at `from`. */
function listedMonths(instrument: string, from: Date, count: number) {
  const p = PRODUCTS[instrument];
  const out: { code: string; year: number; month: number }[] = [];
  let y = from.getUTCFullYear();
  let m = from.getUTCMonth() + 1;
  for (let i = 0; i < 60 && out.length < count; i++) {
    const code = Object.keys(MONTH_CODE).find((c) => MONTH_CODE[c] === m);
    if (code && p.months.includes(code)) out.push({ code, year: y, month: m });
    m++;
    if (m > 12) { m = 1; y++; }
  }
  return out;
}

function symbolFor(instrument: string, code: string, year: number): string {
  const p = PRODUCTS[instrument];
  return `${p.root}${code}${String(year).slice(-2)}${p.suffix}`;
}

/**
 * A daily bar's timestamp sits at midnight in the EXCHANGE's timezone, so the
 * calendar date has to be read in that zone. Adding a fixed offset would land
 * on the wrong day across a DST change - midnight minus an hour is the
 * previous date - so this formats per-timestamp instead.
 */
function exchangeDate(tsSeconds: number, tz: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date(tsSeconds * 1000)); // en-CA formats as YYYY-MM-DD
}

type Row = {
  quote_date: string;
  instrument: string;
  contract_month: string;
  settle: number;
  source: string;
};

type SymbolResult = {
  symbol: string;
  instrument: string;
  contract_month: string;
  status: "ok" | "not_listed" | "no_data" | "error";
  rows: number;
  detail?: string;
};

async function fetchSymbol(
  instrument: string,
  code: string,
  year: number,
  month: number,
  fromTs: number,
  toTs: number,
): Promise<{ rows: Row[]; result: SymbolResult }> {
  const symbol = symbolFor(instrument, code, year);
  const contract_month = `${year}-${String(month).padStart(2, "0")}-01`;
  const base: SymbolResult = { symbol, instrument, contract_month, status: "ok", rows: 0 };
  const url = `${YAHOO}/${encodeURIComponent(symbol)}?period1=${fromTs}&period2=${toTs}&interval=1d`;

  let res: Response;
  try {
    res = await fetch(url, { headers: { "User-Agent": UA } });
  } catch (e) {
    return { rows: [], result: { ...base, status: "error", detail: String(e) } };
  }

  // An expired or never-listed contract is a 404. Expected and non-fatal: it
  // means "no such board", not "the source is down".
  if (res.status === 404) return { rows: [], result: { ...base, status: "not_listed" } };
  if (!res.ok) return { rows: [], result: { ...base, status: "error", detail: `HTTP ${res.status}` } };

  let body: any;
  try {
    body = await res.json();
  } catch (e) {
    return { rows: [], result: { ...base, status: "error", detail: `unparseable JSON: ${e}` } };
  }

  if (body?.chart?.error) {
    return { rows: [], result: { ...base, status: "error", detail: JSON.stringify(body.chart.error) } };
  }
  const result = body?.chart?.result?.[0];
  if (!result) return { rows: [], result: { ...base, status: "error", detail: "no result block" } };

  const stamps: number[] = result.timestamp ?? [];
  const closes: (number | null)[] = result.indicators?.quote?.[0]?.close ?? [];
  const tz: string = result.meta?.exchangeTimezoneName ?? "America/Chicago";

  if (!stamps.length) return { rows: [], result: { ...base, status: "no_data" } };

  // One row per session that actually printed a number. A null close is a day
  // the board did not trade; it is skipped, never carried forward from the
  // previous session and never interpolated. A guessed price here would be
  // indistinguishable from a real one downstream.
  const byDate = new Map<string, number>();
  for (let i = 0; i < stamps.length; i++) {
    const c = closes[i];
    if (c === null || c === undefined || !Number.isFinite(c) || c <= 0) continue;
    // Yahoo can repeat the final bar as an in-progress session; last wins.
    byDate.set(exchangeDate(stamps[i], tz), c);
  }

  const rows: Row[] = [...byDate.entries()].map(([quote_date, settle]) => ({
    quote_date, instrument, contract_month, settle,
    source: `yahoo_chart:${symbol}`,
  }));

  return { rows, result: { ...base, status: rows.length ? "ok" : "no_data", rows: rows.length } };
}

Deno.serve(async (req: Request) => {
  const started = Date.now();
  let params: any = {};
  if (req.method === "POST") {
    try { params = await req.json(); } catch { params = {}; }
  } else {
    params = Object.fromEntries(new URL(req.url).searchParams);
  }

  const instruments: string[] = Array.isArray(params.instruments) && params.instruments.length
    ? params.instruments
    : (typeof params.instruments === "string" ? params.instruments.split(",") : ["feeder_cattle"]);

  for (const i of instruments) {
    if (!PRODUCTS[i]) {
      return new Response(JSON.stringify({ ok: false, error: `unknown instrument "${i}"` }),
        { status: 400, headers: { "Content-Type": "application/json" } });
    }
  }

  const monthsAhead = Number(params.months ?? 8);
  const today = new Date();
  // Default window is the last 8 days, not just today: it costs one request
  // per contract either way and closes any gap left by a failed run or a
  // holiday, which a today-only job would leave open forever.
  const to = params.to ? new Date(`${params.to}T00:00:00Z`) : today;
  const from = params.from
    ? new Date(`${params.from}T00:00:00Z`)
    : new Date(to.getTime() - 8 * 86400000);

  if (isNaN(from.getTime()) || isNaN(to.getTime())) {
    return new Response(JSON.stringify({ ok: false, error: "from/to must be YYYY-MM-DD" }),
      { status: 400, headers: { "Content-Type": "application/json" } });
  }
  if (from > to) {
    return new Response(JSON.stringify({ ok: false, error: "from is after to" }),
      { status: 400, headers: { "Content-Type": "application/json" } });
  }

  // Pad the window so the first and last sessions fall inside it.
  const fromTs = Math.floor(from.getTime() / 1000) - 86400;
  const toTs = Math.floor(to.getTime() / 1000) + 86400;

  const allRows: Row[] = [];
  const results: SymbolResult[] = [];

  for (const instrument of instruments) {
    // Contract months are generated FORWARD from today, never from `from`:
    // those are the boards still listed, and an expired one 404s. A backfill
    // therefore reaches back through the history of today's contracts.
    for (const m of listedMonths(instrument, today, monthsAhead)) {
      const { rows, result } = await fetchSymbol(instrument, m.code, m.year, m.month, fromTs, toTs);
      results.push(result);
      allRows.push(...rows);
    }
  }

  const errors = results.filter((r) => r.status === "error");

  // The source being unavailable is not a data event. Write nothing, say so,
  // exit cleanly - a half-written curve is worse than yesterday's curve.
  if (errors.length && allRows.length === 0) {
    console.error("market-quotes-sync: source unavailable, nothing written", JSON.stringify(errors));
    return new Response(JSON.stringify({
      ok: false, reason: "source_unavailable", rows_upserted: 0, errors,
    }), { status: 502, headers: { "Content-Type": "application/json" } });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Idempotent by construction: the unique key is (quote_date, instrument,
  // contract_month), so a re-run of the same day overwrites its own rows and a
  // re-run of a backfill is a no-op. `settle` is updated rather than ignored,
  // so a revised close corrects itself.
  let upserted = 0;
  const CHUNK = 500;
  for (let i = 0; i < allRows.length; i += CHUNK) {
    const chunk = allRows.slice(i, i + CHUNK);
    const { error } = await supabase
      .from("market_quotes")
      .upsert(chunk, { onConflict: "quote_date,instrument,contract_month" });
    if (error) {
      console.error("market-quotes-sync: upsert failed", error.message);
      return new Response(JSON.stringify({
        ok: false, reason: "write_failed", detail: error.message,
        rows_upserted: upserted, errors,
      }), { status: 500, headers: { "Content-Type": "application/json" } });
    }
    upserted += chunk.length;
  }

  const summary = {
    ok: true,
    from: isoDate(from),
    to: isoDate(to),
    instruments,
    rows_upserted: upserted,
    contracts_ok: results.filter((r) => r.status === "ok").length,
    contracts_not_listed: results.filter((r) => r.status === "not_listed").length,
    contracts_no_data: results.filter((r) => r.status === "no_data").length,
    errors,
    ms: Date.now() - started,
  };
  console.log("market-quotes-sync:", JSON.stringify(summary));
  return new Response(JSON.stringify({ ...summary, contracts: results }), {
    headers: { "Content-Type": "application/json" },
  });
});
