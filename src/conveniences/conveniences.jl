# Hand-written ergonomic layer on top of `JAOEU.JAOEUAPI` (the generated
# code). Safe across `gen/regenerate.jl` runs — that script only rewrites
# `src/api/`. Anything in this directory survives.

include("client.jl")
include("period.jl")
include("parsing.jl")
include("queries.jl")

export PublicationToolClient, OwsmpClient
export publicationtool_core_da_api, publicationtool_nordic_da_api,
    publicationtool_italynorth_api, publicationtool_coreid_cc_a_api,
    owsmp_auctions_api
export to_zoned_utc
export rows, total_rows
export net_position, final_domain, monitoring
export auction_corridors, auction_horizons, auction_results
