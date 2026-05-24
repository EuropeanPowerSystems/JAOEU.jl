#!/usr/bin/env julia
# record_fb_domain_slice.jl
# =========================
#
# Snapshot one MTU's Core flow-based domain — the presolved CNECs plus the
# shadow-priced active constraints — as a small JSON fixture for the
# 2D-projection tutorial under docs/.
#
# Usage:
#     julia --project scripts/record_fb_domain_slice.jl                 # default 2024-09-01 22:00 UTC
#     julia --project scripts/record_fb_domain_slice.jl 2025-03-15T00:00
#
# Output: docs/src/assets/fb_domain_slice_<DATETIME>.json with fields
#   target_mtu_utc, hubs (sorted PTDF keys), constraints (per-CNEC),
#   active (sub-set whose cneName appears in shadow_prices).

using Pkg
let env = joinpath(first(DEPOT_PATH), "environments", "jaoeu-scripts")
    Pkg.activate(env; io = devnull)
    for pkg in ("JSON3",)
        Base.find_package(pkg) === nothing && Pkg.add(pkg; io = devnull)
    end
end

using Dates
using JSON3

Pkg.activate(normpath(joinpath(@__DIR__, "..")); io = devnull)
using JAOEU

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const ASSETS_DIR = joinpath(REPO_ROOT, "docs", "src", "assets")

function main(argv)
    mtu_str = isempty(argv) ? "2024-09-01T22:00" : argv[1]
    mtu_start = DateTime(mtu_str)
    mtu_end = mtu_start + Hour(1)
    println(
        "Recording FB domain slice for MTU ",
        mtu_start, " → ", mtu_end, " UTC"
    )

    client = PublicationToolClient()

    # 1. Presolved final domain (the non-redundant CNECs)
    env, _ = final_domain(client, mtu_start, mtu_end)
    all_rows = rows(env)
    presolved = filter(r -> get(r, "presolved", false) === true, all_rows)
    println("  CNECs: ", length(all_rows), " total, ", length(presolved), " presolved")

    # 2. Active constraints from shadow_prices for the same MTU
    api = publicationtool_core_da_api(client)
    env_sp, _ = JAOEU.JAOEUAPI.publicationtool_core_da_shadow_prices(
        api, to_zoned_utc(mtu_start), to_zoned_utc(mtu_end),
    )
    sp_rows = rows(env_sp)
    println("  Active constraints (shadow-priced): ", length(sp_rows))

    # Build a name → shadowPrice map. The CNEC-level granularity is
    # enough for the visualisation (the same line can be binding under
    # multiple contingencies; we highlight all rows that share the
    # name).
    active_price = Dict{String, Float64}()
    for r in sp_rows
        name = String(get(r, "cnecName", ""))
        isempty(name) && continue
        active_price[name] = Float64(get(r, "shadowPrice", 0.0))
    end

    # 3. Project to a per-CNEC compact record. We keep all `ptdf_*` and
    # only the metadata columns the tutorial actually reads.
    sample = first(presolved)
    hubs = sort([String(k) for k in keys(sample) if startswith(String(k), "ptdf_")])

    # Coerce nullable JSON cells. A missing PTDF is "no declared
    # sensitivity" (= 0); a missing contName/tso surfaces as "".
    _f(x, default = 0.0) = x === nothing ? default : Float64(x)
    _s(x) = x === nothing ? "" : String(x)
    function row_record(r)
        name = String(get(r, "cneName", ""))
        return Dict(
            "cneName" => name,
            "contName" => _s(get(r, "contName", "")),
            "tso" => _s(get(r, "tso", "")),
            "ram" => _f(get(r, "ram", 0.0)),
            "ptdfs" => Dict(h => _f(get(r, h, 0.0)) for h in hubs),
            "active" => haskey(active_price, name),
            "shadowPrice" => get(active_price, name, nothing),
        )
    end

    fixture = Dict(
        "target_mtu_utc" => string(mtu_start) * "Z",
        "hubs" => hubs,
        "constraints" => [row_record(r) for r in presolved],
    )

    mkpath(ASSETS_DIR)
    ts = replace(string(mtu_start), ':' => '_')
    out = joinpath(ASSETS_DIR, "fb_domain_slice_$(ts).json")
    open(out, "w") do io
        JSON3.pretty(io, fixture)
    end
    println("  Wrote ", out, " (", filesize(out), " bytes)")

    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
