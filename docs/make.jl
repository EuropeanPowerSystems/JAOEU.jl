using Documenter, DocumenterVitepress
using JAOEU

const SPEC_SRC = joinpath(pkgdir(JAOEU), "spec", "openapi.json")
const HAS_SPEC = isfile(SPEC_SRC)

# Bundle the committed OpenAPI spec into Vitepress's `public/` so the
# vitepress-openapi components can fetch it from the deployed site.
#
# Only write when the content actually differs from what's already
# there. `cp(...; force=true)` would unconditionally bump the
# destination's mtime — and the destination lives inside `docs/src/`,
# which `LiveServer.servedocs()` watches. A no-op rewrite would
# trigger a rebuild, which would rewrite, which would re-trigger,
# which is an infinite-build loop.
if HAS_SPEC
    SPEC_DST = joinpath(@__DIR__, "src", "public", "openapi.json")
    mkpath(dirname(SPEC_DST))
    if !isfile(SPEC_DST) || read(SPEC_SRC) != read(SPEC_DST)
        cp(SPEC_SRC, SPEC_DST; force = true)
    end
end

# The per-tag REST reference pages live as committed source under
# `docs/src/api/<Tag>.md` — written once at scaffold time by
# OpenAPITemplate's `VitepressDocs` plugin, refreshed by
# `gen/regenerate.jl` when the spec changes. We don't regenerate them on
# every docs build (would churn files in a source tree). Just glob them.
function _api_pages(api_dir::AbstractString)
    isdir(api_dir) || return Any[]
    pages = Any[]
    for file in sort!(readdir(api_dir))
        endswith(file, ".md") || continue
        file == "index.md" && continue   # hand-written REST overview
        title = titlecase(splitext(file)[1])
        push!(pages, title => "api/$file")
    end
    return pages
end

const API_PAGES = _api_pages(joinpath(@__DIR__, "src", "api"))

const PAGES = Any[
    "Home" => "index.md",
    "Getting Started" => "getting_started.md",
    "Tutorials" => Any[
        "One trading day, three views" => "tutorial.md",
        "Net positions on a European map" => "tutorial_net_positions_map.md",
        "Flow-based domain in 2D" => "tutorial_fb_domain_2d.md",
    ],
    "Guides" => Any[
        "Recorded HTTP tests" => "cassette_testing.md",
    ],
    "Julia API Reference" => "julia_reference.md",
]
if HAS_SPEC
    # The Julia-side counterpart to the REST browser: every name codegen
    # emitted, with whatever docstrings it attached. Only present when
    # there is a spec (and therefore a `src/api/` tree).
    push!(PAGES, "Generated Reference" => "generated_reference.md")
end
if !isempty(API_PAGES)
    push!(
        PAGES, "REST API Reference" => Any[
            "Overview" => "api/index.md",
            API_PAGES...,
        ]
    )
end

makedocs(;
    modules = [JAOEU],
    sitename = "JAOEU.jl",
    authors = "EuropeanPowerSystems",
    format = MarkdownVitepress(;
        repo = "github.com/EuropeanPowerSystems/JAOEU.jl",
        devbranch = "main",
        devurl = "dev",
        build_vitepress = true,
    ),
    pages = PAGES,
    warnonly = true,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/EuropeanPowerSystems/JAOEU.jl",
    devbranch = "main",
    push_preview = true,
)
