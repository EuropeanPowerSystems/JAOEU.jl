```@meta
CurrentModule = JAOEU
```

# Tutorial: net positions on a European map

This tutorial paints one trading day's **Core CCR day-ahead net positions** onto a map of Europe. Each of the 12 Core bidding zones is coloured by its hourly net position in MW — positive means the zone exports, negative means it imports.

The data was pulled once with the live API ([`net_position`](@ref) for 2024-09-02 CET) and committed as a small JSON fixture at `docs/src/assets/net_positions_2024-09-02.json`. The recorder that produced it is `scripts/record_net_positions.jl`; re-run it with any other trading day to refresh.

## Loading the fixture

```@example npmap
using JAOEU
using JSON

const FIXTURE = joinpath(
    pkgdir(JAOEU), "docs", "src", "assets", "net_positions_2024-09-02.json",
)
data = JSON.parsefile(FIXTURE)
(target_day = data["target_day"],
 n_zones = length(data["zones"]),
 n_mtus = length(data["timestamps"]))
```

Each entry in `zones` is `{key, iso2, values}`. `iso2` is a list of ISO 3166-1 alpha-2 country codes that the zone covers on the map — `hub_DE` covers both `DE` and `LU` because they share the unified DE-LU bidding zone. The virtual hubs `ALBE` / `ALDE` have empty `iso2` lists; we keep them in the fixture for completeness but don't render them.

A peek at one entry — Netherlands, hour by hour (MW):

```@example npmap
nl = data["zones"][findfirst(z -> z["key"] == "hub_NL", data["zones"])]
[(hour = i - 1, MW = round(Int, nl["values"][i])) for i in 1:length(nl["values"])]
```

## Setting up the map

We use [GeoMakie](https://geo.makie.org/stable/) on top of [CairoMakie](https://docs.makie.org/stable/explanations/backends/cairomakie) to render static PNGs: country polygons (Natural Earth Admin-0 dataset, medium detail) projected with Lambert Conformal Conic and coloured by the per-zone net position. Label positions sit at the [pole of inaccessibility](https://en.wikipedia.org/wiki/Pole_of_inaccessibility) of each country's largest mainland ring — that puts the number in the visual centre even for fractal coastlines.

```@example npmap
using GeoMakie, CairoMakie
using GeoMakie: NaturalEarth
using GeoInterface
using Polylabel
using Proj

CairoMakie.activate!(type = "png")

countries_fc = NaturalEarth.naturalearth("admin_0_countries", 50)
length(countries_fc)
```

Build two lookups: an `ISO2 → values[24]` map (the DE-LU case fans out so we colour both country polygons), plus `ISO2 → zone short-label` for the *first* polygon of each zone (so each value gets exactly one annotation rather than one per polygon).

```@example npmap
np_by_iso = Dict{String, Vector{Float64}}()
label_for = Dict{String, String}()
for z in data["zones"]
    isempty(z["iso2"]) && continue
    short = replace(z["key"], "hub_" => "")
    series = Float64.(z["values"])
    for iso in z["iso2"]
        np_by_iso[iso] = series
    end
    label_for[first(z["iso2"])] = short
end
sort(collect(keys(np_by_iso)))
```

A small projection helper so country labels land sensibly:

```@example npmap
const PROJ_STR = "+proj=lcc +lat_1=35 +lat_2=65 +lat_0=50 +lon_0=10"
const TO_LCC   = Proj.Transformation(
    "+proj=longlat +datum=WGS84", PROJ_STR; always_xy = true,
)
const FROM_LCC = Proj.inv(TO_LCC)

function _ring_area(pts)
    n = length(pts); s = 0.0
    @inbounds for i in 1:n
        x1, y1 = pts[i]; x2, y2 = pts[mod1(i + 1, n)]
        s += x1 * y2 - x2 * y1
    end
    return abs(s) / 2
end

function label_lonlat(geom)
    sub_polys = GeoInterface.geomtrait(geom) isa GeoInterface.MultiPolygonTrait ?
        collect(GeoInterface.getgeom(geom)) : [geom]
    polys_pts = Vector{Vector{Tuple{Float64, Float64}}}()
    for sub in sub_polys
        ring = GeoInterface.getexterior(sub)
        push!(polys_pts,
            [TO_LCC(GeoInterface.x(p), GeoInterface.y(p))
             for p in GeoInterface.getgeom(ring)])
    end
    main = polys_pts[argmax(_ring_area.(polys_pts))]
    pole = polylabel(
        GeoInterface.Wrappers.Polygon([GeoInterface.Wrappers.LinearRing(main)]);
        rtol = 0.005,
    )
    lonlat = FROM_LCC(pole[1], pole[2])
    return (Float64(lonlat[1]), Float64(lonlat[2]))
end

function _country_iso2(feature)
    p = feature.properties
    for key in (:ISO_A2_EH, :ISO_A2)
        v = get(p, key, nothing)
        v === nothing && continue
        v isa AbstractString && v != "-99" && return String(v)
    end
    return ""
end

plotted_geoms   = []
plotted_iso     = String[]
plotted_centers = Tuple{Float64, Float64}[]
for feat in countries_fc
    iso = _country_iso2(feat)
    haskey(np_by_iso, iso) || continue
    push!(plotted_geoms, feat.geometry)
    push!(plotted_iso, iso)
    push!(plotted_centers, label_lonlat(feat.geometry))
end
length(plotted_iso)
```

## Peak hour, single map

Pick the hour where any zone hit its largest absolute net position — that's the most informative single snapshot. We render every European country in light grey as a backdrop, paint each Core zone with its hourly value, and label each polygon with the rounded MW.

```@example npmap
hours = 1:length(data["timestamps"])
peak_hour = argmax(
    [maximum(abs, [np_by_iso[iso][h] for iso in plotted_iso]) for h in hours]
)
peak_ts = data["timestamps"][peak_hour]

# Symmetric diverging scale around zero — RdBu reads as
# blue=importer / red=exporter at a glance.
const COLORMAP  = :RdBu
const NP_BOUND  = round(maximum(abs, [np_by_iso[iso][peak_hour] for iso in plotted_iso]) / 100) * 100
const NP_RANGE  = (-NP_BOUND, NP_BOUND)

fig = Figure(size = (960, 760))
Label(
    fig[0, 1:2],
    "Core day-ahead net positions — $peak_ts (hour $(peak_hour - 1) UTC)";
    fontsize = 17, font = :bold, padding = (0, 0, 6, 0),
)
ax = GeoAxis(fig[1, 1];
    dest = PROJ_STR,
    # Zoom in on Core CCR perimeter (roughly Iberia-to-Balkans width,
    # Mediterranean-to-North-Sea height). Wider European context drowns
    # the visualization in grey backdrop and makes the labels hard to
    # read.
    limits = ((-7, 28), (40, 57)),
    xgridvisible = false, ygridvisible = false,
)
hidedecorations!(ax)
for feat in countries_fc
    poly!(ax, feat.geometry;
        color = :grey88, strokecolor = :white, strokewidth = 0.4)
end
for (i, iso) in enumerate(plotted_iso)
    poly!(ax, plotted_geoms[i];
        color = np_by_iso[iso][peak_hour],
        colormap = COLORMAP, colorrange = NP_RANGE,
        strokecolor = :white, strokewidth = 0.6)
end
# Branch label colour per-zone: white text + dark halo on saturated
# polygons, black text + light halo on the pastel ones. Picking the
# threshold against `NP_BOUND` keeps the rule symmetric and self-
# scaling — change the colour scale and the labels follow.
for (i, iso) in enumerate(plotted_iso)
    haskey(label_for, iso) || continue
    val = np_by_iso[iso][peak_hour]
    intensity = abs(val) / NP_BOUND
    dark_bg = intensity > 0.35
    text!(ax, plotted_centers[i]...;
        text = "$(label_for[iso])\n$(round(Int, val))",
        align = (:center, :center),
        fontsize = 13, font = :bold,
        color = dark_bg ? :white : :black,
        strokewidth = 0.8,
        strokecolor = dark_bg ? :black : :white)
end
Colorbar(fig[1, 2];
    colormap = COLORMAP, colorrange = NP_RANGE,
    label = "Net position (MW)", height = Relative(0.85),
    width = 14,
)
colgap!(fig.layout, 8)
fig
```

The geographic structure of CWE flow-based coupling is visible at a glance: France (large positive number) is the day's biggest exporter, supplying the import-heavy zones to its north and east. Belgium and Romania pull the most power. The Czech Republic / Poland axis usually trades against Germany — this hour, the picture is more nuanced.

## 24-hour grid

For temporal structure, the same calculation across all 24 hours of the trading day. The shared colour scale keeps absolute values comparable across panels.

```@example npmap
fig2 = Figure(size = (1100, 1300))

for h in 1:24
    row = (h - 1) ÷ 4 + 1
    col = (h - 1) %  4 + 1
    ax = GeoAxis(fig2[row, col];
        dest = PROJ_STR,
        limits = ((-7, 28), (40, 57)),
        title = "h=$(h - 1) UTC",
        titlesize = 12,
        xgridvisible = false, ygridvisible = false,
    )
    hidedecorations!(ax)
    for feat in countries_fc
        poly!(ax, feat.geometry;
            color = :grey90, strokecolor = :white, strokewidth = 0.2)
    end
    for (i, iso) in enumerate(plotted_iso)
        poly!(ax, plotted_geoms[i];
            color = np_by_iso[iso][h],
            colormap = COLORMAP, colorrange = NP_RANGE,
            strokecolor = :white, strokewidth = 0.4)
    end
end

Colorbar(fig2[1:6, 5];
    colormap = COLORMAP, colorrange = NP_RANGE,
    label = "Net position (MW)", height = Relative(0.85))
fig2
```

You can read the daily cycle directly off the map: the late-evening hours show France and Germany unwinding their daytime exports as solar drops out; the early-morning hours show the Czech-Polish corridor turning more pronounced as base-load nuclear and coal stay running into low demand.

## Where to next

- The basic [quickstart tutorial](tutorial.md) covers `monitoring`, `net_position`, and `final_domain` without any plotting.
- To extend the fixture to other days, run `julia --project scripts/record_net_positions.jl 2025-03-15` — the tutorial reads whichever date is committed.
- A natural follow-up: render border-level scheduled exchanges as directed arrows between zone centroids, using [`JAOEUAPI.publicationtool_core_da_scheduled_exchanges`](@ref). The `border_<FROM>_<TO>` columns make that mostly a presentation exercise.
- For the full CNEC + PTDF picture (the *constraints* that produced these net positions), see [`final_domain`](@ref) and its `totalRowsWithFilter` pagination.
