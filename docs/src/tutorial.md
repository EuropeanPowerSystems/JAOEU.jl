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
using DataFrames

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
df = DataFrame(env)
size(df)
```

`monitoring` returns a `(DataEnvelope, ApiResponse)` tuple. The envelope implements the Tables.jl interface, so `DataFrame(env)` works directly — no manual unwrapping. (For raw dict access, [`rows`](@ref) still returns the underlying `Vector{JSON.Object}`.)

```@example tutorial
df[1, [:businessDayUtc, :page, :status, :deadline]]
```

Stage names live in the `page` column — `Initial Computation (Virgin Domain)`, `Pre-Final Computation`, `Final Computation`, plus a half-dozen validations. The publication `status` is usually `Received` for any day published in the last few years; `Pending` shows up on the current day in real time.

```@example tutorial
unique(df.page)
```

## 2. Net positions per zone

[`net_position`](@ref) returns one row per market time unit (one hour for day-ahead) with a column per Core bidding-zone hub.

```@example tutorial
env_np, _ = net_position(client, t0, t1)
df_np = DataFrame(env_np)
(n_mtus = nrow(df_np),
 hubs = filter(startswith("hub_"), names(df_np)))
```

The 12 physical zones plus 2 virtual hubs (`ALBE`, `ALDE`) cover the Core CCR perimeter. The values are signed MW — positive means the zone is exporting net, negative means importing.

```@example tutorial
# Netherlands net position, hour by hour
[(hour = i - 1, NL_MW = round(Int, df_np.hub_NL[i])) for i in 1:nrow(df_np)]
```

```@example tutorial
# Day-totals per zone, sorted by absolute size
zone_cols = filter(startswith("hub_"), names(df_np))
totals = sort(
    [(zone = replace(c, "hub_" => ""), total_MWh = round(Int, sum(df_np[!, c])))
     for c in zone_cols];
    by = t -> -abs(t.total_MWh),
)
```

A single number summary: France was the biggest net exporter, Belgium the biggest net importer (typical for a late-summer trading day with French nuclear running and Belgian thermal recovering from summer maintenance).

## 3. The flow-based domain

[`final_domain`](@ref) is where the *constraints* behind those net positions live. Each row is one critical network element / contingency (CNEC) with its remaining available margin (RAM) and one PTDF per hub column. Each MTU has thousands of CNECs.

```@example tutorial
# Pick one MTU — the first hour of the trading day.
mtu_start = t0
mtu_end   = DateTime("2024-09-01T23:00")
env_dom, _ = final_domain(client, mtu_start, mtu_end)
df_dom = DataFrame(env_dom)

(rows_returned = nrow(df_dom),
 totalRowsWithFilter = total_rows(env_dom),
 columns = ncol(df_dom))
```

The server reports the same number for `rows_returned` and `totalRowsWithFilter` — the response is not paginated for a single-MTU window. For multi-MTU pulls or wide filters, the two-phase pattern still applies: drop into the generated layer with `take = 0` first, read `totalRowsWithFilter`, then page in 5000-row chunks (the size jao-py uses).

```@example tutorial
ptdf_cols = filter(startswith("ptdf_"), names(df_dom))
meta_cols = filter(!startswith("ptdf_"), names(df_dom))
(ptdf_columns = length(ptdf_cols), metadata_columns = length(meta_cols))
```

The metadata columns describe the network element: line ID, voltage, the contingency it's monitored under, RAM, FMax, etc. The PTDF columns are the per-hub injection sensitivities — what fraction of a 1 MW injection at hub X shows up as flow on this line.

```@example tutorial
# A peek at one CNEC's PTDFs, sorted by magnitude. Some PTDFs come
# back as `missing` (no sensitivity to a zone for this CNEC) —
# `coalesce` to zero for the sort.
ptdfs = sort(
    [(hub = replace(c, "ptdf_" => ""),
      ptdf = round(coalesce(df_dom[1, c], 0.0); digits = 3))
     for c in ptdf_cols];
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
