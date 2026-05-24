#!/usr/bin/env julia
# record_fb_domain_day.jl
# =======================
#
# Snapshot 24 MTUs (one trading day) of Core flow-based domain data,
# pre-projected onto a chosen pair of bilateral exchange axes. Per-MTU
# we keep just the (a, b, c) triples — enough to render the polytope's
# 2D slice — so the fixture stays small even with 24 hours × ~100
# presolved CNECs.
#
# Usage:
#     julia --project scripts/record_fb_domain_day.jl                    # 2024-09-02
#     julia --project scripts/record_fb_domain_day.jl 2025-03-15
#
# Output: docs/src/assets/fb_domain_day_<DATE>.json. The chosen axes
# are baked in (DE → FR, DE → NL) — edit `X_HUB` / `Y_HUB` below to
# change them.

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
const SLACK = "ptdf_DE"
const X_HUB = "ptdf_FR"
const Y_HUB = "ptdf_NL"

function project(r)
    a = Float64(r[X_HUB]) - Float64(r[SLACK])
    b = Float64(r[Y_HUB]) - Float64(r[SLACK])
    return (a, b, Float64(r["ram"]))
end

function pull_mtu(client, mtu_start)
    mtu_end = mtu_start + Hour(1)
    env, _ = final_domain(client, mtu_start, mtu_end)
    presolved = filter(r -> get(r, "presolved", false) === true, rows(env))
    return [project(r) for r in presolved]
end

function main(argv)
    target = isempty(argv) ? Date("2024-09-02") : Date(argv[1])
    # CET-aligned trading day: 24 hours starting at <target-1>T22:00Z
    t0 = DateTime(target - Day(1), Time(22, 0))
    println(
        "Recording 24 MTUs for trading day ", target,
        " (UTC ", t0, " → ", t0 + Day(1), ")"
    )
    println("  axes: ", X_HUB[6:end], " / ", Y_HUB[6:end], " slack=", SLACK[6:end])

    client = PublicationToolClient()
    mtus = []
    for h in 0:23
        mtu_start = t0 + Hour(h)
        triples = pull_mtu(client, mtu_start)
        push!(
            mtus, Dict(
                "mtu_utc" => string(mtu_start) * "Z",
                "hour_utc" => h,
                "n_presolved" => length(triples),
                # Flatten triples into three parallel arrays so JSON3 emits
                # a compact two-line layout per MTU.
                "a" => Float64[t[1] for t in triples],
                "b" => Float64[t[2] for t in triples],
                "c" => Float64[t[3] for t in triples],
            )
        )
        println("  h=", lpad(h, 2), "  CNECs=", length(triples))
    end

    fixture = Dict(
        "target_day" => string(target),
        "x_hub" => X_HUB,
        "y_hub" => Y_HUB,
        "slack_hub" => SLACK,
        "mtus" => mtus,
    )

    mkpath(ASSETS_DIR)
    out = joinpath(ASSETS_DIR, "fb_domain_day_$(target).json")
    open(out, "w") do io
        JSON3.pretty(io, fixture)
    end
    println("Wrote ", out, " (", filesize(out), " bytes)")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
