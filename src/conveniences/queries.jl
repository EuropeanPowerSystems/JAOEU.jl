using Dates: Dates, DateTime, Date
using TimeZones: ZonedDateTime
using OpenAPI: OpenAPI

using .JAOEUAPI: PublicationToolCoreDAApi, OwsmpAuctionsApi,
    DataEnvelope, DomainEnvelope

# The generated functions live in JAOEUAPI and are re-exported by JAOEU;
# the wrappers here hide the two-step (build Api struct, call function)
# pattern and the manual `to_zoned_utc` coercion. Add a new wrapper
# whenever a common JAO query starts to feel ceremonial.

const _Period = Union{DateTime, Date, ZonedDateTime}

# ──── Publication Tool — Core day-ahead ───────────────────────────────────

"""
    net_position(client, from, to) -> (DataEnvelope, OpenAPI.Clients.ApiResponse)

Fetch Core CCR day-ahead net positions per bidding zone over `[from, to)`.
`from` / `to` may be `DateTime` (interpreted as UTC), `Date`, or
`ZonedDateTime`. Each record carries `dateTimeUtc` plus a `hub_<ZONE>`
column per zone (e.g. `hub_DE`, `hub_FR`).

```julia
client = PublicationToolClient()
env, _ = net_position(client, DateTime("2024-09-01T22:00"),
                              DateTime("2024-09-02T22:00"))
records = rows(env)
```
"""
function net_position(client::Client, from::_Period, to::_Period)
    api = publicationtool_core_da_api(client)
    return JAOEUAPI.publicationtool_core_da_net_position(
        api, to_zoned_utc(from), to_zoned_utc(to),
    )
end

"""
    final_domain(client, from, to) -> (DomainEnvelope, OpenAPI.Clients.ApiResponse)

Fetch the final Core CCR flow-based domain (CNECs + PDFFs) for the
market time unit `[from, to)`. Use the two-phase pattern for large
windows: issue with `take = 0` to read [`total_rows`](@ref), then
paginate via [`final_domain_page`](@ref).

The default call returns the first 5000 rows — matching jao-py's chunk
size — which is enough for any single MTU but not for cross-MTU pulls.
"""
function final_domain(client::Client, from::_Period, to::_Period)
    api = publicationtool_core_da_api(client)
    return JAOEUAPI.publicationtool_core_da_final_computation(
        api, to_zoned_utc(from), to_zoned_utc(to),
    )
end

"""
    monitoring(client, from, to) -> (DataEnvelope, OpenAPI.Clients.ApiResponse)

Fetch Publication Tool monitoring records (`businessDayUtc`, `deadline`,
`lastModifiedOn`) for the requested window. Useful for checking whether
a given business day's results have been published.
"""
function monitoring(client::Client, from::_Period, to::_Period)
    api = publicationtool_core_da_api(client)
    return JAOEUAPI.publicationtool_core_da_monitoring(
        api, to_zoned_utc(from), to_zoned_utc(to),
    )
end

# ──── OWSMP — auctions ────────────────────────────────────────────────────

"""
    auction_corridors(client) -> (Any, OpenAPI.Clients.ApiResponse)

Enumerate corridor identifiers usable for [`auction_results`](@ref) and
[`auction_curtailment`](@ref). Requires an OWSMP API key (see
[`OwsmpClient`](@ref)).
"""
function auction_corridors(client::Client)
    api = owsmp_auctions_api(client)
    return JAOEUAPI.owsmp_get_corridors(api)
end

"""
    auction_horizons(client) -> (Any, OpenAPI.Clients.ApiResponse)

Enumerate auction horizon values (`Yearly`, `Monthly`, `Weekly`,
`Daily`, `Intraday`).
"""
function auction_horizons(client::Client)
    api = owsmp_auctions_api(client)
    return JAOEUAPI.owsmp_get_horizons(api)
end

"""
    auction_results(client, corridor, horizon, fromdate; todate=nothing, shadow=false)

Fetch auction results for `corridor` over `[fromdate, todate]`. Pass
`todate = nothing` for the `Yearly` horizon (the server ignores it).
The window is capped at 31 days per call. Set `shadow = true` to
include shadow-auction results.
"""
function auction_results(
        client::Client,
        corridor::AbstractString,
        horizon::AbstractString,
        fromdate::Date;
        todate::Union{Nothing, Date} = nothing,
        shadow::Bool = false,
    )
    api = owsmp_auctions_api(client)
    return JAOEUAPI.owsmp_get_auctions(
        api, String(corridor), String(horizon), fromdate;
        todate = todate, shadow = shadow ? 1 : 0,
    )
end
