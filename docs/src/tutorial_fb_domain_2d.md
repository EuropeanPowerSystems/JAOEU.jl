```@meta
CurrentModule = JAOEU
```

# Tutorial: visualising the flow-based domain in 2D

The Core CCR flow-based market coupling clears against a polytope in
14-dimensional net-position space. Each presolved CNEC contributes one
half-plane `Σ ptdfₖ · ΔNPₖ ≤ RAM`, and the feasible set is their
intersection. Twelve dimensions are too many to draw, but we can project
onto any pair of bilateral exchange axes — DE→FR on x, DE→NL on y is the
classic FBMC view.

The data comes from a fixture committed at
`docs/src/assets/fb_domain_slice_2024-09-01T22_00_00.json`, produced by
`scripts/record_fb_domain_slice.jl` (one MTU's presolved CNECs +
shadow-priced active constraints).

## Loading the slice

```@example fbdom
using JSON, JAOEU
const FIXTURE = joinpath(pkgdir(JAOEU), "docs", "src", "assets",
                         "fb_domain_slice_2024-09-01T22_00_00.json")
slice = JSON.parsefile(FIXTURE)
(target = slice["target_mtu_utc"],
 n_cnecs = length(slice["constraints"]),
 n_active = count(c -> c["active"], slice["constraints"]))
```

## Projecting to bilateral exchanges

Pick two zones to vary against DE (the slack hub):

```@example fbdom
const SLACK = "ptdf_DE"
const X_HUB = "ptdf_FR"     # x-axis: DE → FR exchange (MW)
const Y_HUB = "ptdf_NL"     # y-axis: DE → NL exchange (MW)
```

Increasing the DE→FR exchange by `x` MW (with all other hubs held at
zero net-position change) means `ΔNP_FR = +x`, `ΔNP_DE = −x`. The same
trick on y for NL. Plugging into `Σ ptdfₖ · ΔNPₖ ≤ RAM`:

```math
\underbrace{(\mathrm{ptdf}_\mathrm{FR} - \mathrm{ptdf}_\mathrm{DE})}_{a}\,x
+ \underbrace{(\mathrm{ptdf}_\mathrm{NL} - \mathrm{ptdf}_\mathrm{DE})}_{b}\,y
\le \underbrace{\mathrm{RAM}}_{c}
```

Each CNEC becomes one `(a, b, c)` triple:

```@example fbdom
function ab(constraint)
    p = constraint["ptdfs"]
    a = p[X_HUB] - p[SLACK]
    b = p[Y_HUB] - p[SLACK]
    return (a, b, constraint["ram"])
end

abcs = ab.(slice["constraints"])
length(abcs)
```

## Vertex enumeration

A 2D feasible region is a convex polygon. Its vertices are intersections
of constraint pairs that satisfy every other constraint. With 109
presolved CNECs the pairwise loop is small enough to do directly.

```@example fbdom
function intersect_pair((a1, b1, c1), (a2, b2, c2))
    det = a1 * b2 - a2 * b1
    abs(det) < 1e-9 && return nothing       # parallel
    x = (b2 * c1 - b1 * c2) / det
    y = (a1 * c2 - a2 * c1) / det
    return (x, y)
end

function feasible_polygon(abcs; tol = 1e-3)
    verts = NTuple{2, Float64}[]
    n = length(abcs)
    for i in 1:n, j in (i + 1):n
        p = intersect_pair(abcs[i], abcs[j])
        p === nothing && continue
        x, y = p
        # Reject if any other constraint is violated
        ok = true
        for k in 1:n
            (k == i || k == j) && continue
            a, b, c = abcs[k]
            if a * x + b * y > c + tol
                ok = false; break
            end
        end
        ok && push!(verts, (x, y))
    end
    # Sort by angle around centroid
    cx = sum(first, verts) / length(verts)
    cy = sum(last, verts) / length(verts)
    sort!(verts; by = p -> atan(p[2] - cy, p[1] - cx))
    return verts
end

poly = feasible_polygon(abcs)
length(poly)
```

That's the number of vertices on the projected polytope's boundary.

## Plotting

Two layers — the "fan" of presolved constraints in dark grey, and the
feasible-region polygon traced in red dashed line on top.

```@example fbdom
using CairoMakie
CairoMakie.activate!(type = "png")

# Pick a generous plot window so we see the full fan
const LIM = 9000.0
xs = range(-LIM, LIM; length = 2)

function line_y(a, b, c)
    if abs(b) < 1e-12
        # Vertical-ish constraint; clamp by x and let it run vertically
        x0 = c / a
        return (Float64[x0, x0], Float64[-LIM, LIM])
    else
        ys = @. (c - a * xs) / b
        return (collect(xs), collect(ys))
    end
end

fig = Figure(size = (760, 740))
Label(fig[0, 1],
    "Core flow-based domain — $(slice["target_mtu_utc"])";
    fontsize = 16, font = :bold, padding = (0, 0, 6, 0))
ax = Axis(fig[1, 1];
    xlabel = "DE → FR exchange (MW)",
    ylabel = "DE → NL exchange (MW)",
    limits = ((-LIM, LIM), (-LIM, LIM)),
    aspect = DataAspect(),
)
hlines!(ax, [0]; color = (:black, 0.3), linewidth = 0.5)
vlines!(ax, [0]; color = (:black, 0.3), linewidth = 0.5)

# Layer 1 — fan of every presolved constraint
for (a, b, c) in abcs
    xv, yv = line_y(a, b, c)
    lines!(ax, xv, yv; color = (:grey25, 0.45), linewidth = 0.6)
end

# Layer 2 — feasible polygon outline (closed)
if !isempty(poly)
    px = [p[1] for p in poly]; push!(px, poly[1][1])
    py = [p[2] for p in poly]; push!(py, poly[1][2])
    lines!(ax, px, py;
        color = (:crimson, 0.9), linewidth = 2.2, linestyle = :dash)
    scatter!(ax, [p[1] for p in poly], [p[2] for p in poly];
        color = :crimson, markersize = 7, strokecolor = :white, strokewidth = 1)
end

Legend(fig[1, 2],
    [LineElement(color = (:grey25, 0.7), linewidth = 1),
     LineElement(color = :crimson, linewidth = 2.2, linestyle = :dash)],
    ["presolved CNEC ($(length(abcs)))", "feasible polygon"];
    framevisible = true, halign = :left, valign = :top,
    margin = (8, 8, 8, 8),
)
colsize!(fig.layout, 2, Auto(0.25))
fig
```

Reading the picture:

- The grey lines are every presolved CNEC dragged into the DE→FR /
  DE→NL plane. Each line is `(a, b, c)`; constraints sweep close to
  parallel for CNECs that have similar PTDF ratios between France and
  the Netherlands. Most of the 109 presolved lines sit far outside the
  ±9000 MW window because they're non-binding in this 2D direction —
  only the dozen-or-so visible ones constrain trade along the FR / NL
  axes.
- The red dashed polygon is the *2D feasible set* — every point on or
  inside it can be realised by trading along DE-FR and DE-NL while
  holding every other Core zone at its reference net position. The
  polygon's vertices are intersections of pairs of constraint lines
  that satisfy every other constraint.

## How the polytope evolves over a day

A single MTU's domain is only one frame of a 24-frame slideshow.
Demand swings, generation shifts, and TSO validation reductions all
reshape the polytope hour-to-hour. The recorder
`scripts/record_fb_domain_day.jl` snapshots all 24 hours of a trading
day, pre-projected onto the same DE→FR / DE→NL axes, and saves them as
a single JSON file (~250 KB).

```@example fbdom
day = JSON.parsefile(joinpath(pkgdir(JAOEU), "docs", "src", "assets",
                              "fb_domain_day_2024-09-02.json"))
(target_day = day["target_day"],
 n_mtus = length(day["mtus"]),
 cnec_range = extrema(m["n_presolved"] for m in day["mtus"]))
```

For each MTU we compute the projected polygon with the same vertex-
enumeration helper, then overlay them with a colour gradient keyed on
the hour:

```@example fbdom
function polygon_from_abc(a, b, c; tol = 1e-3)
    n = length(a)
    verts = NTuple{2, Float64}[]
    for i in 1:n, j in (i + 1):n
        det = a[i] * b[j] - a[j] * b[i]
        abs(det) < 1e-9 && continue
        x = (b[j] * c[i] - b[i] * c[j]) / det
        y = (a[i] * c[j] - a[j] * c[i]) / det
        ok = true
        for k in 1:n
            (k == i || k == j) && continue
            if a[k] * x + b[k] * y > c[k] + tol; ok = false; break; end
        end
        ok && push!(verts, (x, y))
    end
    isempty(verts) && return verts
    cx = sum(first, verts) / length(verts)
    cy = sum(last, verts) / length(verts)
    sort!(verts; by = p -> atan(p[2] - cy, p[1] - cx))
    return verts
end

polys = [(m["hour_utc"], polygon_from_abc(m["a"], m["b"], m["c"]))
         for m in day["mtus"]]
[(h, length(v)) for (h, v) in polys[1:6]]
```

```@example fbdom
cmap = Makie.cgrad(:viridis, 24; categorical = true)

fig_day = Figure(size = (820, 760))
Label(fig_day[0, 1],
    "Core FB domain — $(day["target_day"]) (all 24 MTUs)";
    fontsize = 16, font = :bold, padding = (0, 0, 6, 0))
ax_day = Axis(fig_day[1, 1];
    xlabel = "DE → FR exchange (MW)",
    ylabel = "DE → NL exchange (MW)",
    limits = ((-LIM, LIM), (-LIM, LIM)),
    aspect = DataAspect())
hlines!(ax_day, [0]; color = (:black, 0.3), linewidth = 0.5)
vlines!(ax_day, [0]; color = (:black, 0.3), linewidth = 0.5)
for (h, verts) in polys
    isempty(verts) && continue
    px = [p[1] for p in verts]; push!(px, verts[1][1])
    py = [p[2] for p in verts]; push!(py, verts[1][2])
    lines!(ax_day, px, py; color = cmap[h + 1], linewidth = 1.3)
end
Colorbar(fig_day[1, 2];
    colormap = :viridis, colorrange = (0, 23),
    label = "hour UTC", height = Relative(0.85), width = 14)
colgap!(fig_day.layout, 8)
fig_day
```

The polygon stretches and contracts depending on hour-of-day. Some
hours admit a much wider range of bilateral DE→FR exchanges than
others — what looks like rotation comes from individual TSOs tightening
or relaxing CNECs around their daily operating envelope. Late-night
hours typically give the largest 2D slice (demand is low, so RAM is
fattest); midday solar peaks tend to introduce extra binding
constraints that pull the boundary inward.

## A different axis pair — the eastern border

The DE→FR / DE→NL slice is the canonical Western-European view. The
exact same machinery works for any pair of zones by changing the
projection constants. Here's the Polish-Czech axis (Eastern
slice), reusing the single-MTU fixture:

```@example fbdom
function project(cs; slack, x_hub, y_hub)
    out = NTuple{3, Float64}[]
    for c in cs
        p = c["ptdfs"]
        push!(out, (p[x_hub] - p[slack], p[y_hub] - p[slack], c["ram"]))
    end
    return out
end

abcs_east = project(slice["constraints"];
                    slack = "ptdf_DE", x_hub = "ptdf_PL", y_hub = "ptdf_CZ")
poly_east = polygon_from_abc([t[1] for t in abcs_east],
                             [t[2] for t in abcs_east],
                             [t[3] for t in abcs_east])
length(poly_east)
```

```@example fbdom
function plot_slice(abcs, poly; xlab, ylab, title)
    fig = Figure(size = (760, 740))
    Label(fig[0, 1]; text = title, fontsize = 16, font = :bold,
          padding = (0, 0, 6, 0))
    ax = Axis(fig[1, 1]; xlabel = xlab, ylabel = ylab,
              limits = ((-LIM, LIM), (-LIM, LIM)), aspect = DataAspect())
    hlines!(ax, [0]; color = (:black, 0.3), linewidth = 0.5)
    vlines!(ax, [0]; color = (:black, 0.3), linewidth = 0.5)
    for (a, b, c) in abcs
        xv, yv = line_y(a, b, c)
        lines!(ax, xv, yv; color = (:grey25, 0.45), linewidth = 0.6)
    end
    if !isempty(poly)
        px = [p[1] for p in poly]; push!(px, poly[1][1])
        py = [p[2] for p in poly]; push!(py, poly[1][2])
        lines!(ax, px, py; color = (:crimson, 0.9),
               linewidth = 2.2, linestyle = :dash)
        scatter!(ax, [p[1] for p in poly], [p[2] for p in poly];
                 color = :crimson, markersize = 7,
                 strokecolor = :white, strokewidth = 1)
    end
    return fig
end

plot_slice(abcs_east, poly_east;
           xlab = "DE → PL exchange (MW)",
           ylab = "DE → CZ exchange (MW)",
           title = "Core FB domain (eastern slice) — $(slice["target_mtu_utc"])")
```

Different border pair, different polygon. The eastern slice is
typically tighter than the western one because the Czech-German
interconnection has the lowest line ratings in the CCR — relatively
small bilateral exchanges saturate the binding CNECs around the
DE/CZ/PL triangle.

## Changing the slack hub

The "slack" hub is the zone whose net-position change absorbs the sum
of all other changes. Picking DE as slack made sense for a German-
centric trade narrative, but every other Core zone is a legitimate
choice. Here's the same single-MTU domain with the Netherlands as the
slack, projected onto DE→? / FR→? axes:

```@example fbdom
abcs_nlslack = project(slice["constraints"];
                       slack = "ptdf_NL", x_hub = "ptdf_DE", y_hub = "ptdf_FR")
poly_nlslack = polygon_from_abc([t[1] for t in abcs_nlslack],
                                [t[2] for t in abcs_nlslack],
                                [t[3] for t in abcs_nlslack])
plot_slice(abcs_nlslack, poly_nlslack;
           xlab = "NL → DE exchange (MW)",
           ylab = "NL → FR exchange (MW)",
           title = "Core FB domain (NL slack) — $(slice["target_mtu_utc"])")
```

Switching the slack rotates and reshapes the polytope; physically it's
the same N-dimensional polytope, just viewed from a different
linear-subspace projection. The vertex count typically changes too —
the slack choice controls which CNECs end up parallel in 2D and
therefore which intersections are admissible vertices.

## Where to next

- The [European net-positions tutorial](tutorial_net_positions_map.md)
  shows the *outcome* of the clearing on a geographic map; this
  tutorial shows the *constraint set* it had to clear against.
- For a different trading day, re-run `scripts/record_fb_domain_slice.jl`
  and `scripts/record_fb_domain_day.jl` with the date argument — they
  pull live data and rewrite the JSON fixtures in `docs/src/assets/`.
- Both recorders pull from the live Publication Tool anonymously — no
  token needed.
