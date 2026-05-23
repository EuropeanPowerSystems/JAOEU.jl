```@meta
CurrentModule = JAOEU
```

# Tutorial: one trading day, three views

This walkthrough exercises the Publication Tool surface against one trading day. We start with the **publication monitoring** record (smallest call, gentlest smoke test), then pull the **net positions** for the same day, and finally the full **flow-based domain** for one MTU.

Everything here is anonymous — no token is needed. The Publication Tool embeds a Guest bearer in its SPA and accepts unauthenticated requests for all read endpoints.

## A client and a time window

```@example tutorial
using JAOEU
using Dates

client = PublicationToolClient()

# 2024-09-02 in CET — 22:00 UTC the previous day through 22:00 UTC.
# JAO's business day is Europe/Amsterdam-aligned.
t0 = DateTime("2024-09-01T22:00")
t1 = DateTime("2024-09-02T22:00")

client
```

`PublicationToolClient` is a thin wrapper around the package's [`Client`](@ref) configured with the right base URL (`https://publicationtool.jao.eu/core/api`) and a routing `pre_request_hook` that strips the synthetic OpenAPI prefix from each request. Time arguments accept `DateTime`, `Date`, or `ZonedDateTime` via [`to_zoned_utc`](@ref); plain `DateTime` is treated as UTC.

## 1. Publication monitoring

The `monitoring` endpoint reports when each computation stage finishes for a given business day. It's the cheapest call we make — a few KB per response — and the easiest sanity check.

```@example tutorial
env, _ = monitoring(client, t0, t1)
n_records = length(rows(env))
n_records
```

`monitoring` returns a `(DataEnvelope, ApiResponse)` tuple. [`rows`](@ref) unwraps the `data` field; what comes back is a `Vector{JSON.Object{String, Any}}` — each entry behaves like a `Dict{String, Any}`.

```@example tutorial
first(rows(env))
```

Stage names live in the `page` field — `Initial Computation (Virgin Domain)`, `Pre-Final Computation`, `Final Computation`, plus a half-dozen validations. The publication `status` is usually `Received` for any day published in the last few years; `Pending` shows up on the current day in real time.

```@example tutorial
stages = unique(get(r, "page", "(unknown)") for r in rows(env))
length(stages)
```

## 2. Net positions per zone

[`net_position`](@ref) returns one row per market time unit (one hour for day-ahead) with a column per Core bidding-zone hub.

```@example tutorial
env_np, _ = net_position(client, t0, t1)
records = rows(env_np)
(n_mtus = length(records), zone_columns = sort([k for k in keys(first(records)) if startswith(k, "hub_")]))
```

The 12 physical zones plus 2 virtual hubs (`ALBE`, `ALDE`) cover the Core CCR perimeter. The values are signed MW — positive means the zone is exporting net, negative means importing.

```@example tutorial
# Net position of the Netherlands hour by hour
[(hour = i - 1,
  NL_MW = round(Int, get(r, "hub_NL", 0)))
 for (i, r) in enumerate(records)]
```

```@example tutorial
# Day-totals per zone, sorted by absolute size
zone_keys = sort([k for k in keys(first(records)) if startswith(k, "hub_")])
totals = [(zone = replace(k, "hub_" => ""),
           total_MWh = round(Int, sum(get(r, k, 0) for r in records)))
          for k in zone_keys]
sort!(totals, by = t -> -abs(t.total_MWh))
totals
```

A single number summary: France was the biggest net exporter, Belgium the biggest net importer (typical for a late-summer trading day with French nuclear running and Belgian thermal recovering from summer maintenance).

## 3. The flow-based domain

[`final_domain`](@ref) is where the *constraints* behind those net positions live. Each row is one critical network element / contingency (CNEC) with its remaining available margin (RAM) and one PTDF per hub column. Each MTU has thousands of CNECs.

```@example tutorial
# Pick one MTU — the first hour of the trading day.
mtu_start = t0
mtu_end   = DateTime("2024-09-01T23:00")
env_dom, _ = final_domain(client, mtu_start, mtu_end)

(rows_returned = length(rows(env_dom)),
 totalRowsWithFilter = total_rows(env_dom))
```

The server reports the same number for both — the response is not actually paginated for a single-MTU window. For multi-MTU pulls or wide filters, the two-phase pattern still applies: issue with `take = 0` first, read `totalRowsWithFilter`, then page in 5000-row chunks (the size jao-py uses).

```@example tutorial
sample = first(rows(env_dom))
ptdf_keys = sort([k for k in keys(sample) if startswith(k, "ptdf_")])
meta_keys = sort([k for k in keys(sample) if !startswith(k, "ptdf_")])
(metadata_columns = length(meta_keys),
 ptdf_columns = length(ptdf_keys))
```

The metadata describes the network element: line ID, voltage, the contingency it's monitored under, RAM, FMax, etc. The PTDF columns are the per-hub injection sensitivities — what fraction of a 1 MW injection at hub X shows up as flow on this line.

```@example tutorial
# A peek at one CNEC's PTDFs, sorted by magnitude. Some PTDFs come
# back as `null` (no sensitivity to a zone for this CNEC) — coerce
# those to zero for the sort.
_ptdf(v) = v === nothing ? 0.0 : Float64(v)
ptdfs = sort(
    [(hub = replace(k, "ptdf_" => ""),
      ptdf = round(_ptdf(get(sample, k, nothing)); digits = 3))
     for k in ptdf_keys];
    by = p -> -abs(p.ptdf),
)
ptdfs[1:min(6, end)]
```

## 4. Dropping into the generated layer

The named wrappers cover the most-used endpoints. For everything else, reach into `JAOEU.JAOEUAPI`:

```@example tutorial
api = publicationtool_core_da_api(client)
env_shadow, _ = JAOEU.JAOEUAPI.publicationtool_core_da_shadow_prices(
    api, to_zoned_utc(t0), to_zoned_utc(t1),
)
length(rows(env_shadow))
```

Shadow prices show which CNECs were binding in the market clearing and what they cost in EUR/MWh on each side. With 95 active constraints across 24 MTUs, the Core domain was modestly congested that day.

## Where to next

- For a visual take on the same net-position data, jump to the [European map tutorial](tutorial_net_positions_map.md).
- The [`final_domain`](@ref), [`net_position`](@ref), and [`monitoring`](@ref) docstrings list every keyword they accept.
- Tab-complete `JAOEU.JAOEUAPI.` in the REPL to discover all 23 generated functions.
- Extend `scripts/build_openapi.jl`'s `ENDPOINT_TABLE` to cover Nordic, Intraday CC/IDA, or Italy North — each is a different `server` entry away.
