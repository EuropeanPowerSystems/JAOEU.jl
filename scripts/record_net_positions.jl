#!/usr/bin/env julia
# record_net_positions.jl
# =======================
#
# Pull one trading day's Core day-ahead net positions from the JAO
# Publication Tool (anonymous) and write a small JSON fixture to
# `docs/src/assets/net_positions_<DATE>.json` so the docs build can
# render the EU map offline.
#
# Re-run with a fresh date when you want the fixture to update; the
# tutorial reads whichever file ships at the path set in its preamble.
#
# Usage:
#     julia --project scripts/record_net_positions.jl                 # default 2024-09-02
#     julia --project scripts/record_net_positions.jl 2025-03-15      # any CET trading day

using Pkg
let env = joinpath(first(DEPOT_PATH), "environments", "jaoeu-scripts")
    Pkg.activate(env; io = devnull)
    for pkg in ("JSON3",)
        Base.find_package(pkg) === nothing && Pkg.add(pkg; io = devnull)
    end
end

using Dates
using JSON3

# Activate the package env so `using JAOEU` resolves to the local checkout.
Pkg.activate(normpath(joinpath(@__DIR__, "..")); io = devnull)
using JAOEU

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const ASSETS_DIR = joinpath(REPO_ROOT, "docs", "src", "assets")

# Bidding-zone → ISO 3166-1 alpha-2 country code(s).
# Most Core zones map 1-to-1. DE is the unified Germany–Luxembourg
# bidding zone (DE_LU) — when rendering the map we colour both country
# polygons with the same value. ALBE / ALDE are the virtual Belgian-
# Luxembourg hubs created for advanced hybrid coupling; they have no
# geographic footprint, so we skip them on the map but keep them in the
# fixture so anyone consuming it sees the complete data.
const ZONE_TO_ISO2 = Dict{String, Vector{String}}(
    "hub_AT" => ["AT"],
    "hub_BE" => ["BE"],
    "hub_CZ" => ["CZ"],
    "hub_DE" => ["DE", "LU"],
    "hub_FR" => ["FR"],
    "hub_HR" => ["HR"],
    "hub_HU" => ["HU"],
    "hub_NL" => ["NL"],
    "hub_PL" => ["PL"],
    "hub_RO" => ["RO"],
    "hub_SI" => ["SI"],
    "hub_SK" => ["SK"],
    # Virtual hubs — present in the response, no map footprint.
    "hub_ALBE" => String[],
    "hub_ALDE" => String[],
)

# Parse a `YYYY-MM-DD` trading day argument. ENTSO-E/JAO are CET-aligned
# (Europe/Amsterdam), so the day is the 24-hour window from
# `<day-1>T22:00Z` (= 00:00 CET) through `<day>T22:00Z` (= 00:00 CET
# next day). We don't bother with explicit time-zone handling here —
# the docs only need a single day and CET is a fine approximation for
# the visual.
function trading_window(arg::AbstractString)
    target = Date(arg)
    return (
        target,
        DateTime(target - Day(1), Time(22, 0)),
        DateTime(target, Time(22, 0)),
    )
end

function main(argv)
    target_arg = isempty(argv) ? "2024-09-02" : argv[1]
    target_day, t0, t1 = trading_window(target_arg)
    println(
        "Recording Core day-ahead net positions for ", target_day,
        " (UTC window ", t0, " → ", t1, ")"
    )

    client = PublicationToolClient()
    env, _ = net_position(client, t0, t1)
    records = rows(env)
    println("Received ", length(records), " MTU rows")
    isempty(records) && error("Empty response — pick a published trading day.")

    # Collect zone keys in stable order and build per-zone series. We
    # preserve the raw `dateTimeUtc` strings so the tutorial can show
    # them as-is without re-deriving timestamps.
    timestamps = String[get(r, "dateTimeUtc", "") for r in records]
    zone_keys = sort(
        [
            String(k) for k in keys(first(records))
                if startswith(String(k), "hub_")
        ]
    )

    series = Dict{String, Vector{Union{Float64, Nothing}}}()
    for k in zone_keys
        col = Union{Float64, Nothing}[
            get(r, k, nothing) === nothing ? nothing :
                Float64(get(r, k, 0.0)) for r in records
        ]
        series[k] = col
    end

    fixture = Dict(
        "target_day" => string(target_day),
        "from_utc" => string(t0) * "Z",
        "to_utc" => string(t1) * "Z",
        "timestamps" => timestamps,
        "zones" => [
            Dict(
                    "key" => k,
                    "iso2" => get(ZONE_TO_ISO2, k, String[]),
                    "values" => series[k],
                ) for k in zone_keys
        ],
    )

    mkpath(ASSETS_DIR)
    out = joinpath(ASSETS_DIR, "net_positions_$(target_day).json")
    open(out, "w") do io
        JSON3.pretty(io, fixture)
    end
    println("Wrote ", out, " (", filesize(out), " bytes)")

    # Sanity: report range so the tutorial colour-scale can be picked
    # without surprises.
    flat = Float64[v for col in values(series) for v in col if v !== nothing]
    isempty(flat) || println(
        "Net-position range: ",
        round(minimum(flat); digits = 1), " … ",
        round(maximum(flat); digits = 1), " MW"
    )
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
