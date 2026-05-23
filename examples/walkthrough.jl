# JAOEU.jl — end-to-end walkthrough.
#
# Hits the public surface of the package against the live JAO APIs.
#
# Publication Tool calls are anonymous (no token needed). OWSMP auction
# calls require an API key — resolved from `ENV["JAO_OWSMP_API_KEY"]`
# first, then `token.txt` at the repo root (gitignored). When neither
# is set, OWSMP sections are skipped with a note and the rest of the
# script runs unchanged.

using JAOEU
using Dates
using Statistics: mean, extrema

# ──── tiny presentation helpers ───────────────────────────────────────────

section(title) = (
    println();
    printstyled(
        "══ ", title, " ", "═"^max(2, 70 - length(title)), "\n";
        color = :cyan, bold = true,
    )
)
subhead(label) = printstyled("  ▸ ", label, "\n"; color = :light_blue)
note(msg) = printstyled("    · ", msg, "\n"; color = :light_black)
warn(msg) = printstyled("    ⚠ ", msg, "\n"; color = :yellow)

# Format one record's value compactly.
_cell(x::Real) = string(round(x; digits = 3))
_cell(x) = string(x)

# Show the first `n` records of a JSON `data` array as a small aligned
# table. Each record is a `JSON.Object{String, Any}`; columns are the
# keys of the first row.
function preview(records; n::Int = 3, label::AbstractString = "rows")
    isempty(records) && (note("(no $label returned)"); return records)
    cols = collect(keys(first(records)))
    head = collect(Iterators.take(records, n))
    formatted = [[_cell(get(r, c, "")) for c in cols] for r in head]
    headers = String.(cols)
    widths = [
        max(
                length(headers[i]),
                maximum(length(row[i]) for row in formatted; init = 0)
            )
            for i in eachindex(cols)
    ]
    sep = "  "
    printstyled(
        "    first $n of $(length(records)) $label:\n"; color = :light_black,
    )
    printstyled(
        "    " * join((rpad(headers[i], widths[i]) for i in eachindex(cols)), sep) * "\n";
        color = :light_black, bold = true,
    )
    printstyled(
        "    " * join(("─"^widths[i] for i in eachindex(cols)), sep) * "\n";
        color = :light_black,
    )
    for row in formatted
        println("    " * join((rpad(row[i], widths[i]) for i in eachindex(cols)), sep))
    end
    return records
end

# Run `f()`, return its result or print a one-line error notice and
# return `nothing`. Keeps the walkthrough flowing when JAO is rate-
# limiting or returning unexpected statuses.
function try_call(f::Function, label::AbstractString)
    try
        return f()
    catch err
        warn("$label → $(typeof(err)): $(first(sprint(showerror, err), 200))")
        return nothing
    end
end

# ──── credential resolution ───────────────────────────────────────────────

function resolve_owsmp_key()
    tok = strip(get(ENV, "JAO_OWSMP_API_KEY", ""))
    isempty(tok) || return String(tok)
    fallback = joinpath(@__DIR__, "..", "token.txt")
    isfile(fallback) || return ""
    return strip(read(fallback, String))
end

const OWSMP_KEY = resolve_owsmp_key()

# ──── standard analysis window ────────────────────────────────────────────
# 2024-09-02 in CET (= 2024-09-01 22:00 UTC → 2024-09-02 22:00 UTC).
# One trading day. The market time unit for the domain probe is the
# first hour of that day in CET.

const T0 = DateTime("2024-09-01T22:00")
const T1 = DateTime("2024-09-02T22:00")
const MTU_START = T0
const MTU_END = DateTime("2024-09-01T23:00")

# ──────────────────────────────────────────────────────────────────────────
section("1. Publication Tool client + time helpers")

subhead("PublicationToolClient() — anonymous, no token needed")
const PT = PublicationToolClient()
note("client.base_url = $(PT.base_url)")

subhead("to_zoned_utc accepts DateTime / Date / ZonedDateTime")
note("DateTime → $(to_zoned_utc(T0))")
note("Date     → $(to_zoned_utc(Date(2024, 9, 2)))")

# ──────────────────────────────────────────────────────────────────────────
section("2. monitoring — publication deadlines for a business day")

records = try_call("monitoring(2024-09-01 → 02)") do
    env, _ = monitoring(PT, T0, T1)
    rows(env)
end

if records !== nothing
    preview(records; label = "monitoring records")
    statuses = unique(get(r, "status", "?") for r in records)
    note("status values in window: $(join(statuses, ", "))")
end

# ──────────────────────────────────────────────────────────────────────────
section("3. net_position — Core day-ahead net positions per zone")

np_records = try_call("net_position(2024-09-02 CET day)") do
    env, _ = net_position(PT, T0, T1)
    rows(env)
end

if np_records !== nothing && !isempty(np_records)
    preview(np_records; n = 2, label = "MTU rows")
    # Each row carries dateTimeUtc plus hub_* columns. Pull out the hubs
    # from the first row to show the zone coverage.
    first_row = first(np_records)
    hubs = sort([k for k in keys(first_row) if startswith(k, "hub_")])
    note("$(length(hubs)) zone columns: $(join(first.(hubs, 8), ", "))")
    note("$(length(np_records)) MTUs returned (expected 24 for one day)")
end

# ──────────────────────────────────────────────────────────────────────────
section("4. final_domain — flow-based domain with two-phase pagination")

subhead("Phase 1 — probe with the call (jao-py uses take=0 for this)")
domain_env = try_call("final_domain for one MTU") do
    env, _ = final_domain(PT, MTU_START, MTU_END)
    env
end

if domain_env !== nothing
    total = total_rows(domain_env)
    returned = length(rows(domain_env))
    note("totalRowsWithFilter = $total")
    note("rows returned in this page = $returned")

    if returned > 0
        sample = first(rows(domain_env))
        cnec_keys = sort([k for k in keys(sample) if !startswith(k, "ptdf_")])
        ptdf_keys = sort([k for k in keys(sample) if startswith(k, "ptdf_")])
        note("each CNEC record has $(length(cnec_keys)) metadata + $(length(ptdf_keys)) ptdf_* columns")
        cnec_name = get(sample, "cnecName", "(no cnecName)")
        ram = get(sample, "ram", nothing)
        ram === nothing ||
            note("first CNEC: $cnec_name  RAM=$(_cell(ram))")
    end
end

# ──────────────────────────────────────────────────────────────────────────
section("5. Dropping into the generated layer for endpoints without wrappers")

subhead("publicationtool_core_da_shadow_prices — no wrapper yet")
api = publicationtool_core_da_api(PT)
shadow_env = try_call("shadow_prices(2024-09-02)") do
    env, _ = JAOEU.JAOEUAPI.publicationtool_core_da_shadow_prices(
        api, to_zoned_utc(T0), to_zoned_utc(T1),
    )
    env
end

shadow_env === nothing ||
    note("$(length(rows(shadow_env))) active-constraint records in window")

# ──────────────────────────────────────────────────────────────────────────
section("6. OWSMP auctions — gated on token.txt / JAO_OWSMP_API_KEY")

if isempty(OWSMP_KEY)
    warn("no OWSMP key found — skipping OWSMP sections")
    note("To enable: set ENV[\"JAO_OWSMP_API_KEY\"] or write a key to")
    note("$(joinpath(@__DIR__, "..", "token.txt"))")
    note("Get one from helpdesk@jao.eu (subject `[API] Token Request`)")
else
    note("OWSMP key found (length $(length(OWSMP_KEY))) — running OWSMP sections")

    subhead("OwsmpClient + auction_horizons (smallest call to verify auth)")
    horizons = try_call("auction_horizons") do
        owsmp = OwsmpClient(OWSMP_KEY)
        result, _ = auction_horizons(owsmp)
        result
    end
    horizons === nothing ||
        note("horizons: $(horizons)")

    subhead("auction_corridors (lists all wrapper corridors)")
    corridors = try_call("auction_corridors") do
        owsmp = OwsmpClient(OWSMP_KEY)
        result, _ = auction_corridors(owsmp)
        result
    end
    if corridors !== nothing
        note("$(length(corridors)) corridors")
        if !isempty(corridors)
            # Each entry is a JSON object; show the first few `value`s.
            head = collect(Iterators.take(corridors, 5))
            values = [get(c, "value", c) for c in head]
            note("first 5: $(join(values, ", "))")
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────
section("Done.")

printstyled(
    """
    Next steps:
      - ?net_position, ?final_domain, ?monitoring  for the named wrappers
      - JAOEU.JAOEUAPI.<tab>  for the full generated surface (23 ops)
      - using DataFrames; DataFrame(rows(env))     for tabular handling
      - scripts/build_openapi.jl to extend the endpoint table (Nordic,
        intraday, Italy North can all be added there)
    """; color = :light_black,
)
