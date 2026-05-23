#!/usr/bin/env julia
# build_openapi.jl
# ================
#
# Synthesize an OpenAPI 3.1 spec for the Joint Allocation Office (JAO)
# JSON REST surface from a declarative endpoint table. Run from the
# package root:
#
#     julia scripts/build_openapi.jl
#
# Outputs: `spec/openapi.json` (consumed by `gen/regenerate.jl`) plus a
# human-readable `spec/openapi.yaml` mirror.
#
# Why a hand-curated table (vs ENTSOE.jl's Postman→OpenAPI converter):
# JAO publishes neither an OpenAPI spec nor a Postman collection. The
# Publication Tool runs ASP.NET Core with Swashbuckle disabled, the
# Utility Tool only exposes SOAP/WSDL, and the auctions API ships a
# 6-page PDF as its sole reference. We materialize the surface here, in
# one place, so codegen, docs, and tests share a single source of truth.
# Sources: the open-source `jao-py` client (github.com/fboerman/jao-py)
# for the Publication Tool, and `API_User_Guide_v1.0.pdf` for OWSMP.
#
# To extend: append entries to `ENDPOINT_TABLE`. The script collapses
# duplicate `path + method` keys automatically and assigns one
# operationId per row. To wire in a new platform (e.g. Nordic,
# Intraday, Italy North), add a server entry to `SERVER_REGISTRY` and
# tag each new endpoint with its server key — the client's
# `pre_request_hook` collapses the synthetic path back to the right
# real URL at request time.

using Pkg
let env = joinpath(first(DEPOT_PATH), "environments", "jaoeu-scripts")
    Pkg.activate(env; io = devnull)
    for pkg in ("JSON3", "YAML", "OrderedCollections")
        Base.find_package(pkg) === nothing && Pkg.add(pkg; io = devnull)
    end
end

using JSON3, YAML, OrderedCollections

# ---- server registry -----------------------------------------------------
#
# Synthetic-path prefix → real base URL. The client's pre_request_hook
# strips the prefix and prepends the real URL before hitting the wire.

const SERVER_REGISTRY = OrderedDict{String, NamedTuple}(
    "publicationtool_core_da" => (
        prefix = "/publicationtool/core",
        base_url = "https://publicationtool.jao.eu/core/api",
        # /data/<op> for normal operations, /system/<op> for `monitoring`.
        # The hook reads the synthetic path's third segment to decide.
    ),
    "publicationtool_nordic_da" => (
        prefix = "/publicationtool/nordic",
        base_url = "https://publicationtool.jao.eu/nordic/api",
        # Same /data and /system segments as Core. Disables several Core
        # endpoints (allocationConstraint, netPos, lta, alphaFactor,
        # priceSpread, scheduledExchanges); adds fbDomainShadowPrice;
        # renames d2CF → cgmForeCast and Presolved filter key →
        # NonRedundant.
    ),
    "publicationtool_italynorth" => (
        prefix = "/publicationtool/ibwt",
        base_url = "https://publicationtool.jao.eu/ibwt/api",
        # `CCR_*` for day-ahead, `CCR_id*` for intraday. Operations live
        # under /data/. No /system/ surface used here.
    ),
    "publicationtool_coreid" => (
        prefix = "/publicationtool/coreID",
        base_url = "https://publicationtool.jao.eu/coreID/api",
        # CoreID intraday — endpoints prefixed `IDCC{a,b,c,d}_` or
        # `ID{N}_` depending on whether this is the continuous-clearing
        # (CC) or auction-clearing (IDA) flavour. For v0 we expose the
        # `IDCCa_` set only; extend `_INTRADAY_VARIANTS` below to wire
        # in the other versions.
    ),
    "owsmp" => (
        prefix = "/owsmp",
        base_url = "https://api.jao.eu/OWSMP",
    ),
)

# Intraday variants — each entry expands the IDCC/IDA endpoint set onto
# a unique tag + path prefix. Add more by appending here; the table
# expansion below picks them up automatically.
const _INTRADAY_VARIANTS = [
    (
        label = "a", endpoint_prefix = "IDCCa_", op_id_part = "idcc_a",
        tag = "PublicationToolCoreIDCCa",
        summary_suffix = "Core CCR intraday continuous clearing (window A)",
    ),
    # Uncomment to wire in additional variants:
    # (label = "b", endpoint_prefix = "IDCCb_", op_id_part = "idcc_b",
    #  tag = "PublicationToolCoreIDCCb", summary_suffix = "Core CCR intraday CC (window B)"),
    # (label = "c", endpoint_prefix = "IDCCc_", op_id_part = "idcc_c",
    #  tag = "PublicationToolCoreIDCCc", summary_suffix = "Core CCR intraday CC (window C)"),
    # (label = "d", endpoint_prefix = "IDCCd_", op_id_part = "idcc_d",
    #  tag = "PublicationToolCoreIDCCd", summary_suffix = "Core CCR intraday CC (window D)"),
    # (label = "1", endpoint_prefix = "ID1_", op_id_part = "ida_1",
    #  tag = "PublicationToolCoreIDA1", summary_suffix = "Core CCR intraday auctions (round 1)"),
]

# ---- parameter library ---------------------------------------------------
#
# Reusable parameter definitions referenced by `params:` lists below. Each
# entry produces one OpenAPI Parameter Object. `required` defaults to
# `false` if omitted.

const PARAM_LIB = Dict{Symbol, NamedTuple}(
    # Publication Tool — "domain" shape (paginated, hourly slice).
    :from_utc_iso => (
        name = "FromUtc", in = "query", required = true,
        schema = (type = "string", format = "date-time"),
        description = "Inclusive start of the market time unit, ISO 8601 UTC " *
            "(e.g. `2024-09-01T22:00:00Z`).",
    ),
    :to_utc_iso => (
        name = "ToUtc", in = "query", required = true,
        schema = (type = "string", format = "date-time"),
        description = "Exclusive end of the market time unit, ISO 8601 UTC. " *
            "Typically `FromUtc + 1h` for domain queries.",
    ),
    :skip => (
        name = "Skip", in = "query", required = false,
        schema = (type = "integer", minimum = 0, default = 0),
        description = "Pagination offset (rows to skip).",
    ),
    :take => (
        name = "Take", in = "query", required = false,
        schema = (type = "integer", minimum = 0, default = 5000),
        description = "Page size. Use `0` first to read `totalRowsWithFilter`, " *
            "then paginate. jao-py uses 5000.",
    ),
    :filter_json => (
        name = "Filter", in = "query", required = false,
        schema = (type = "string",),
        description = "JSON-encoded filter object. Common keys: `CnecName` " *
            "(string), `Contingency` (string), `Presolved` (bool), `Tso` " *
            "(array of EIC codes). Example: `{\"Presolved\":true}`.",
    ),

    # Publication Tool — "fromto" shape (date range, per-day chunked).
    :from_utc_z => (
        name = "FromUtc", in = "query", required = true,
        schema = (type = "string", format = "date-time"),
        description = "Inclusive start of the requested window, ISO 8601 UTC " *
            "with millisecond precision (`yyyy-MM-ddTHH:mm:ss.000Z`). " *
            "Practical limit: two days per call; DST boundaries may force " *
            "single-day chunks.",
    ),
    :to_utc_z => (
        name = "ToUtc", in = "query", required = true,
        schema = (type = "string", format = "date-time"),
        description = "Exclusive end of the requested window, ISO 8601 UTC " *
            "with millisecond precision (`yyyy-MM-ddTHH:mm:ss.000Z`).",
    ),

    # OWSMP — auctions API.
    :owsmp_corridor => (
        name = "corridor", in = "query", required = true,
        schema = (type = "string",),
        description = "Corridor identifier. Enumerate via `getcorridors`.",
    ),
    :owsmp_corridor_opt => (
        name = "corridor", in = "query", required = false,
        schema = (type = "string",),
        description = "Optional corridor filter.",
    ),
    :owsmp_horizon => (
        name = "horizon", in = "query", required = true,
        schema = (
            type = "string",
            enum = ["Yearly", "Monthly", "Weekly", "Daily", "Intraday"],
        ),
        description = "Auction horizon. Enumerate via `gethorizons`.",
    ),
    :owsmp_fromdate => (
        name = "fromdate", in = "query", required = true,
        schema = (type = "string", format = "date"),
        description = "Inclusive start date, `YYYY-MM-DD`.",
    ),
    :owsmp_todate => (
        name = "todate", in = "query", required = false,
        schema = (type = "string", format = "date"),
        description = "Inclusive end date, `YYYY-MM-DD`. Omit for `Yearly` " *
            "horizon (server ignores it). Max 31-day window.",
    ),
    :owsmp_shadow => (
        name = "shadow", in = "query", required = false,
        schema = (type = "integer", enum = [0, 1], default = 0),
        description = "Set to `1` to include shadow auction results.",
    ),
    :owsmp_auctionid => (
        name = "auctionid", in = "query", required = true,
        schema = (type = "string",),
        description = "Auction identifier, e.g. " *
            "`<CORRIDOR>-M-BASE-------YYMM01-01` for a monthly base auction.",
    ),
)

# ---- response schemas ----------------------------------------------------
#
# Two response shapes recur across Publication Tool: the paginated
# "domain" envelope (`totalRowsWithFilter` + `data[]`) and the bare
# `{ data: [] }` form used by the "fromto" endpoints. OWSMP returns
# raw arrays.

const RESPONSE_SCHEMAS = OrderedDict{String, Any}(
    "DomainEnvelope" => OrderedDict{String, Any}(
        "type" => "object",
        "properties" => OrderedDict{String, Any}(
            "totalRowsWithFilter" => OrderedDict{String, Any}(
                "type" => "integer",
                "description" => "Total rows matching the filter, ignoring " *
                    "pagination. Issue the first call with `Take=0` to " *
                    "read this without transferring data.",
            ),
            "data" => OrderedDict{String, Any}(
                "type" => "array",
                "items" => OrderedDict{String, Any}("type" => "object"),
                "description" => "Records for the requested page. Shape " *
                    "depends on the endpoint; CNEC records include " *
                    "`dateTimeUtc`, `cnecName`, `contingencies[]`, and a " *
                    "set of `ptdf_<HUB>` columns.",
            ),
        ),
        "required" => ["data"],
    ),
    "DataEnvelope" => OrderedDict{String, Any}(
        "type" => "object",
        "properties" => OrderedDict{String, Any}(
            "data" => OrderedDict{String, Any}(
                "type" => "array",
                "items" => OrderedDict{String, Any}("type" => "object"),
                "description" => "Records for the requested time window. " *
                    "Each row carries `dateTimeUtc` plus endpoint-specific " *
                    "fields (e.g. `hub_<ZONE>` for net positions, " *
                    "`border_<FROM>_<TO>` for exchange-shaped data).",
            ),
        ),
        "required" => ["data"],
    ),
    "ProblemDetails" => OrderedDict{String, Any}(
        "type" => "object",
        "description" => "RFC 7807 problem detail returned on 4xx/5xx by " *
            "the Publication Tool's ASP.NET Core middleware.",
        "properties" => OrderedDict{String, Any}(
            "type" => OrderedDict{String, Any}("type" => "string"),
            "title" => OrderedDict{String, Any}("type" => "string"),
            "status" => OrderedDict{String, Any}("type" => "integer"),
            "detail" => OrderedDict{String, Any}("type" => "string"),
            "instance" => OrderedDict{String, Any}("type" => "string"),
            "errors" => OrderedDict{String, Any}(
                "type" => "object",
                "additionalProperties" => OrderedDict{String, Any}(
                    "type" => "array",
                    "items" => OrderedDict{String, Any}("type" => "string"),
                ),
            ),
        ),
    ),
    "AuctionResult" => OrderedDict{String, Any}(
        "type" => "object",
        "description" => "One auction with nested `results[]` and " *
            "`products[]` (offered/allocated/requested capacity, ATC, " *
            "auction price, bid-gate times).",
        "additionalProperties" => true,
    ),
)

# ---- endpoint table ------------------------------------------------------
#
# One entry per logical operation. Adding a row produces one Julia
# function under the matching tag.

const ENDPOINT_TABLE = NamedTuple[
    # ──── Publication Tool — Core Day-Ahead (shape A: paginated domain) ────
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/finalComputation", op_id = "publicationtool_core_da_final_computation",
        tag = "PublicationToolCoreDA", summary = "Final flow-based domain (CNECs + PDFFs)",
        description = "Final computation of the Core CCR flow-based domain " *
            "for the requested market time unit: critical network elements, " *
            "their contingencies, RAMs, and PDFFs per bidding-zone hub. " *
            "Paginate via `Skip`/`Take`; use `Filter` to narrow by CNEC, TSO, " *
            "or presolved state.",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/preFinalComputation", op_id = "publicationtool_core_da_prefinal_computation",
        tag = "PublicationToolCoreDA", summary = "Pre-final flow-based domain",
        description = "Pre-final computation result, prior to TSO validation " *
            "reductions. Same shape as `finalComputation`.",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/initialComputation", op_id = "publicationtool_core_da_initial_computation",
        tag = "PublicationToolCoreDA", summary = "Initial flow-based domain",
        description = "Initial CCM output, before any validation. Same " *
            "shape as `finalComputation`.",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),

    # ──── Publication Tool — Core Day-Ahead (shape B: date-range) ────
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/netPos", op_id = "publicationtool_core_da_net_position",
        tag = "PublicationToolCoreDA", summary = "Net positions per bidding zone",
        description = "Net position per Core CCR bidding zone, one row per " *
            "MTU. Columns: `dateTimeUtc` plus `hub_<ZONE>` (e.g. `hub_DE`, " *
            "`hub_FR`). Special-case: jao-py renames `DE` → `DE_LU`.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/shadowPrices", op_id = "publicationtool_core_da_shadow_prices",
        tag = "PublicationToolCoreDA", summary = "Active constraints with shadow prices",
        description = "Critical branch-contingency pairs (CB/CO) that were " *
            "binding in the market clearing, with their shadow prices.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/lta", op_id = "publicationtool_core_da_lta",
        tag = "PublicationToolCoreDA", summary = "Long-term allocations",
        description = "Long-term capacity allocations (yearly/monthly) " *
            "applicable to the requested window.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/validationReductions", op_id = "publicationtool_core_da_validation_reductions",
        tag = "PublicationToolCoreDA", summary = "TSO validation reductions",
        description = "Per-TSO reductions applied during validation. Note: " *
            "some rows carry `tso == \"CBCO\"`; jao-py filters those out " *
            "as malformed.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/maxExchanges", op_id = "publicationtool_core_da_max_exchanges",
        tag = "PublicationToolCoreDA", summary = "Maximum bilateral exchanges per border",
        description = "Per-border max bilateral exchange limits in MW. " *
            "Columns: `dateTimeUtc` plus `border_<FROM>_<TO>`.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/maxNetPos", op_id = "publicationtool_core_da_max_net_positions",
        tag = "PublicationToolCoreDA", summary = "Min/max net positions per zone",
        description = "Per-zone min and max net-position bounds in MW.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/allocationConstraint", op_id = "publicationtool_core_da_allocation_constraint",
        tag = "PublicationToolCoreDA", summary = "Allocation constraints (up/down per zone)",
        description = "External allocation constraints imposed on the " *
            "flow-based domain (up and down per zone).",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/spanningDefaultFBP", op_id = "publicationtool_core_da_spanning_default_fbp",
        tag = "PublicationToolCoreDA", summary = "Default-FBP status flag",
        description = "Indicator: did the day fall back to the spanning " *
            "default flow-based parameters?",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/priceSpread", op_id = "publicationtool_core_da_price_spread",
        tag = "PublicationToolCoreDA", summary = "Day-ahead price spreads per border",
        description = "Day-ahead price spread per border, derived from " *
            "SDAC clearing prices.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/scheduledExchanges", op_id = "publicationtool_core_da_scheduled_exchanges",
        tag = "PublicationToolCoreDA", summary = "Scheduled exchanges per border",
        description = "Per-border scheduled exchanges in MW.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/alphaFactor", op_id = "publicationtool_core_da_alpha_factor",
        tag = "PublicationToolCoreDA", summary = "Alpha factor per zone",
        description = "Per-zone alpha factor used in advanced hybrid coupling.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/d2CF", op_id = "publicationtool_core_da_d2cf",
        tag = "PublicationToolCoreDA", summary = "D-2 congestion forecast",
        description = "D-2 congestion forecast (Nordic variant: " *
            "`cgmForeCast`).",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/refprog", op_id = "publicationtool_core_da_refprog",
        tag = "PublicationToolCoreDA", summary = "Reference programs",
        description = "Reference programs feeding the flow-based " *
            "computation.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_core_da", segment = "data",
        path = "/congestionIncome", op_id = "publicationtool_core_da_congestion_income",
        tag = "PublicationToolCoreDA", summary = "Congestion income per border",
        description = "Day-ahead congestion rent per border, in EUR.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),

    # ──── Publication Tool — Core Day-Ahead (shape B, system path) ────
    (
        server = "publicationtool_core_da", segment = "system",
        path = "/monitoring", op_id = "publicationtool_core_da_monitoring",
        tag = "PublicationToolCoreDA", summary = "Process monitoring (deadlines, publication times)",
        description = "Process monitoring records — `businessDayUtc`, " *
            "`deadline`, `lastModifiedOn`. Note: served from `/system/` " *
            "rather than `/data/` on the Publication Tool host.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),

    # ──── Publication Tool — Nordic Day-Ahead ────
    #
    # Subset of Core DA: omits allocationConstraint, netPos, lta,
    # alphaFactor, priceSpread, scheduledExchanges; adds
    # fbDomainShadowPrice (Shape A — paginated active-constraint domain);
    # renames d2CF → cgmForeCast. Filter JSON uses `NonRedundant`
    # instead of `Presolved`.
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/finalComputation", op_id = "publicationtool_nordic_da_final_computation",
        tag = "PublicationToolNordicDA", summary = "Final Nordic FB domain (CNECs + PTDFs)",
        description = "Final computation of the Nordic flow-based domain.",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/preFinalComputation", op_id = "publicationtool_nordic_da_prefinal_computation",
        tag = "PublicationToolNordicDA", summary = "Pre-final Nordic FB domain",
        description = "Pre-final Nordic flow-based domain, before TSO validation reductions.",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/initialComputation", op_id = "publicationtool_nordic_da_initial_computation",
        tag = "PublicationToolNordicDA", summary = "Initial Nordic FB domain",
        description = "Initial Nordic FB domain output prior to validation.",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/fbDomainShadowPrice", op_id = "publicationtool_nordic_da_fb_domain_shadow_price",
        tag = "PublicationToolNordicDA", summary = "Nordic active-constraint shadow prices",
        description = "Per-CNEC shadow prices for the binding Nordic active constraints (Shape A — paginated).",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/validationReductions", op_id = "publicationtool_nordic_da_validation_reductions",
        tag = "PublicationToolNordicDA", summary = "Nordic TSO validation reductions",
        description = "Per-TSO Nordic validation reductions.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/maxExchanges", op_id = "publicationtool_nordic_da_max_exchanges",
        tag = "PublicationToolNordicDA", summary = "Nordic max bilateral exchanges",
        description = "Per-border max bilateral exchange limits in the Nordic CCR.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/maxNetPos", op_id = "publicationtool_nordic_da_max_net_positions",
        tag = "PublicationToolNordicDA", summary = "Nordic min/max net positions per zone",
        description = "Per-zone min and max net-position bounds for Nordic zones.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/spanningDefaultFBP", op_id = "publicationtool_nordic_da_spanning_default_fbp",
        tag = "PublicationToolNordicDA", summary = "Nordic default-FBP status",
        description = "Nordic default flow-based parameters fallback indicator.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/cgmForeCast", op_id = "publicationtool_nordic_da_cgm_forecast",
        tag = "PublicationToolNordicDA", summary = "Nordic CGM forecast (Nordic d2CF alias)",
        description = "Common Grid Model forecast — Nordic naming for the Core-side `d2CF` endpoint.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/refprog", op_id = "publicationtool_nordic_da_refprog",
        tag = "PublicationToolNordicDA", summary = "Nordic reference programs",
        description = "Reference programs feeding the Nordic flow-based computation.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "data",
        path = "/congestionIncome", op_id = "publicationtool_nordic_da_congestion_income",
        tag = "PublicationToolNordicDA", summary = "Nordic congestion income per border",
        description = "Nordic day-ahead congestion rent per border (EUR).",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_nordic_da", segment = "system",
        path = "/monitoring", op_id = "publicationtool_nordic_da_monitoring",
        tag = "PublicationToolNordicDA", summary = "Nordic publication monitoring",
        description = "Process monitoring records for the Nordic CCR — served from `/system/`.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),

    # ──── Publication Tool — Italy North CCR (BWT) ────
    #
    # `CCR_*` for day-ahead, `CCR_id*` for intraday. Both flavours sit
    # under the same `/data/` segment and share the same parameter
    # shape as Core's Shape B endpoints.
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_cnecInfo", op_id = "publicationtool_italynorth_da_cnec_info",
        tag = "PublicationToolItalyNorth", summary = "Italy North day-ahead CNECs",
        description = "Italy North day-ahead critical network elements and contingencies.",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_idCnecInfo", op_id = "publicationtool_italynorth_id_cnec_info",
        tag = "PublicationToolItalyNorth", summary = "Italy North intraday CNECs",
        description = "Italy North intraday CNECs (same shape as DA).",
        params = [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json],
        response_schema = "DomainEnvelope",
    ),
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_forecasted", op_id = "publicationtool_italynorth_da_forecasted",
        tag = "PublicationToolItalyNorth", summary = "Italy North day-ahead grid forecasts",
        description = "Italy North forecasted grid status for the DA timeframe.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_idForecasted", op_id = "publicationtool_italynorth_id_forecasted",
        tag = "PublicationToolItalyNorth", summary = "Italy North intraday grid forecasts",
        description = "Italy North intraday-timeframe forecasted grid status.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_FinalTtcNtc", op_id = "publicationtool_italynorth_da_final_ttc_ntc",
        tag = "PublicationToolItalyNorth", summary = "Italy North day-ahead final TTC/NTC",
        description = "Final TTC and NTC values published for the Italy North day-ahead window.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_idFinalTtcNtc", op_id = "publicationtool_italynorth_id_final_ttc_ntc",
        tag = "PublicationToolItalyNorth", summary = "Italy North intraday final TTC/NTC",
        description = "Final TTC and NTC values for the Italy North intraday window.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_allocationConstraint", op_id = "publicationtool_italynorth_da_allocation_constraint",
        tag = "PublicationToolItalyNorth", summary = "Italy North day-ahead allocation constraints",
        description = "Allocation constraints applied to the Italy North day-ahead allocation.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),
    (
        server = "publicationtool_italynorth", segment = "data",
        path = "/CCR_idAllocationConstraint", op_id = "publicationtool_italynorth_id_allocation_constraint",
        tag = "PublicationToolItalyNorth", summary = "Italy North intraday allocation constraints",
        description = "Allocation constraints applied to the Italy North intraday allocation.",
        params = [:from_utc_z, :to_utc_z],
        response_schema = "DataEnvelope",
    ),

    # ──── Publication Tool — Core CCR Intraday (CC + IDA variants) ────
    #
    # All variants share the endpoint set below; the per-variant prefix
    # (`IDCCa_`, `IDCCb_`, …, `ID1_`, …) is added in the build loop
    # from `_INTRADAY_VARIANTS`. Disabled for intraday: `lta`,
    # `spanningDefaultFBP`, `shadowPrices`, `alphaFactor`. `monitoring`
    # is served from `/system/` *without* the variant prefix and is
    # therefore declared once under Core DA, not here.
    # (entries below are expanded per variant inside `build_spec`)
    # ── INTRADAY_VARIANT_EXPANSION_POINT ──

    # ──── OWSMP — Auctions API ────
    (
        server = "owsmp",
        path = "/getcorridors", op_id = "owsmp_get_corridors",
        tag = "OwsmpAuctions", summary = "List corridors",
        description = "Enumerate corridor identifiers usable for " *
            "`getauctions`/`getcurtailment`.",
        params = Symbol[],
        response_schema = nothing,
    ),
    (
        server = "owsmp",
        path = "/gethorizons", op_id = "owsmp_get_horizons",
        tag = "OwsmpAuctions", summary = "List auction horizons",
        description = "Enumerate horizon values — `Yearly`, `Monthly`, " *
            "`Weekly`, `Daily`, `Intraday`.",
        params = Symbol[],
        response_schema = nothing,
    ),
    (
        server = "owsmp",
        path = "/getauctions", op_id = "owsmp_get_auctions",
        tag = "OwsmpAuctions", summary = "Auction results",
        description = "Auction results for a corridor / horizon over a date " *
            "range (max 31 days). Each entry includes nested `results[]` " *
            "and `products[]` carrying offered/allocated/requested capacity, " *
            "ATC, auction price, and bid-gate timestamps. Omit `todate` " *
            "for the `Yearly` horizon (server ignores it).",
        params = [
            :owsmp_corridor, :owsmp_horizon, :owsmp_fromdate,
            :owsmp_todate, :owsmp_shadow,
        ],
        response_schema = nothing,
    ),
    (
        server = "owsmp",
        path = "/getbids", op_id = "owsmp_get_bids",
        tag = "OwsmpAuctions", summary = "Bids for a specific auction",
        description = "Bid-level records for one auction (identified by " *
            "`auctionid`, e.g. `<CORRIDOR>-M-BASE-------YYMM01-01`).",
        params = [:owsmp_auctionid],
        response_schema = nothing,
    ),
    (
        server = "owsmp",
        path = "/getcurtailment", op_id = "owsmp_get_curtailment",
        tag = "OwsmpAuctions", summary = "Curtailment records for a corridor",
        description = "Curtailment events on a corridor over a date range. " *
            "Records carry `curtailmentPeriodStart`/`curtailmentPeriodStop`.",
        params = [:owsmp_corridor, :owsmp_fromdate, :owsmp_todate],
        response_schema = nothing,
    ),
]

# ---- builders ------------------------------------------------------------

function param_object(spec_param::NamedTuple)
    # Single-element NamedTuple traps: `(type = "string")` is parsed as
    # `"string"` in Julia. Caller must use `(type = "string",)`. The
    # generator's downstream consumer (openapi-generator) emits a cryptic
    # "schema is not of type `object`" — fail early with a clearer hint.
    spec_param.schema isa NamedTuple || error(
        "Parameter `$(spec_param.name)`: schema must be a NamedTuple, got " *
            "$(typeof(spec_param.schema)). Hint: single-key NamedTuples " *
            "need a trailing comma, e.g. `(type = \"string\",)`.",
    )
    out = OrderedDict{String, Any}(
        "name" => spec_param.name,
        "in" => spec_param.in,
        "required" => get(spec_param, :required, false),
        "schema" => _to_ordered(spec_param.schema),
    )
    desc = get(spec_param, :description, "")
    isempty(desc) || (out["description"] = desc)
    return out
end

# Convert a NamedTuple (recursively) to an OrderedDict so YAML/JSON
# output preserves key order. `enum`/`default` are passed through verbatim.
function _to_ordered(v::NamedTuple)
    out = OrderedDict{String, Any}()
    for (k, val) in pairs(v)
        out[String(k)] = _to_ordered(val)
    end
    return out
end
_to_ordered(v::AbstractVector) = [_to_ordered(x) for x in v]
_to_ordered(v) = v

function build_path(entry::NamedTuple)
    server = SERVER_REGISTRY[entry.server]
    segment_suffix = haskey(entry, :segment) ? "/" * entry.segment : ""
    return server.prefix * segment_suffix * entry.path
end

function build_operation(entry::NamedTuple)
    params = [param_object(PARAM_LIB[p]) for p in entry.params]
    op = OrderedDict{String, Any}(
        "tags" => [entry.tag],
        "summary" => entry.summary,
        "operationId" => entry.op_id,
        "description" => entry.description,
        "parameters" => params,
    )

    if entry.server == "owsmp"
        # OWSMP requires the AUTH_API_KEY header on every operation.
        op["security"] = [OrderedDict{String, Any}("OwsmpApiKey" => String[])]
    else
        # Publication Tool — anonymous bearer extracted from the SPA;
        # required scheme but value is supplied by the client.
        op["security"] = [OrderedDict{String, Any}("PublicationToolBearer" => String[])]
    end

    success_schema = if entry.response_schema === nothing
        OrderedDict{String, Any}(
            "type" => "array",
            "items" => OrderedDict{String, Any}("type" => "object"),
        )
    else
        OrderedDict{String, Any}("\$ref" => "#/components/schemas/$(entry.response_schema)")
    end

    op["responses"] = OrderedDict{String, Any}(
        "200" => OrderedDict{String, Any}(
            "description" => "Successful response",
            "content" => OrderedDict{String, Any}(
                "application/json" => OrderedDict{String, Any}(
                    "schema" => success_schema,
                ),
            ),
        ),
        "400" => problem_response("Invalid request (e.g. malformed date range)."),
        "401" => problem_response("Missing or invalid credentials."),
        "404" => problem_response("Endpoint or data not found."),
        "429" => problem_response("Rate limited (>100 requests/minute on OWSMP)."),
        "500" => problem_response("Server error."),
    )
    return op
end

function problem_response(desc::AbstractString)
    return OrderedDict{String, Any}(
        "description" => desc,
        "content" => OrderedDict{String, Any}(
            "application/problem+json" => OrderedDict{String, Any}(
                "schema" => OrderedDict{String, Any}(
                    "\$ref" => "#/components/schemas/ProblemDetails",
                ),
            ),
        ),
    )
end

# Endpoint set shared by every CoreID intraday variant — DA endpoints
# minus the ones jao-py marks as disabled (`lta`, `spanningDefaultFBP`,
# `shadowPrices`, `alphaFactor`) plus the intraday-specific
# `intradayAtc` / `intradayNtc`.
const _INTRADAY_ENDPOINT_TEMPLATES = [
    (
        suffix = "finalComputation", op_id = "final_computation",
        summary = "Final FB domain", shape = :domain,
    ),
    (
        suffix = "preFinalComputation", op_id = "prefinal_computation",
        summary = "Pre-final FB domain", shape = :domain,
    ),
    (
        suffix = "initialComputation", op_id = "initial_computation",
        summary = "Initial FB domain", shape = :domain,
    ),
    (
        suffix = "netPos", op_id = "net_position",
        summary = "Net positions per zone", shape = :range,
    ),
    (
        suffix = "validationReductions", op_id = "validation_reductions",
        summary = "TSO validation reductions", shape = :range,
    ),
    (
        suffix = "maxExchanges", op_id = "max_exchanges",
        summary = "Max bilateral exchanges per border", shape = :range,
    ),
    (
        suffix = "maxNetPos", op_id = "max_net_positions",
        summary = "Min/max net positions per zone", shape = :range,
    ),
    (
        suffix = "allocationConstraint", op_id = "allocation_constraint",
        summary = "Allocation constraints", shape = :range,
    ),
    (
        suffix = "priceSpread", op_id = "price_spread",
        summary = "Intraday price spreads", shape = :range,
    ),
    (
        suffix = "scheduledExchanges", op_id = "scheduled_exchanges",
        summary = "Scheduled exchanges per border", shape = :range,
    ),
    (
        suffix = "intradayAtc", op_id = "intraday_atc",
        summary = "Border intraday ATC", shape = :range,
    ),
    (
        suffix = "intradayNtc", op_id = "intraday_ntc",
        summary = "Border intraday NTC", shape = :range,
    ),
    (
        suffix = "d2CF", op_id = "d2cf",
        summary = "D-2 congestion forecast", shape = :range,
    ),
    (
        suffix = "refprog", op_id = "refprog",
        summary = "Reference programs", shape = :range,
    ),
    (
        suffix = "congestionIncome", op_id = "congestion_income",
        summary = "Congestion income per border", shape = :range,
    ),
]

function _intraday_entries()
    out = NamedTuple[]
    for variant in _INTRADAY_VARIANTS, t in _INTRADAY_ENDPOINT_TEMPLATES
        is_domain = t.shape == :domain
        push!(
            out, (
                server = "publicationtool_coreid",
                segment = "data",
                path = "/" * variant.endpoint_prefix * t.suffix,
                op_id = "publicationtool_$(variant.op_id_part)_" * t.op_id,
                tag = variant.tag,
                summary = t.summary,
                description = variant.summary_suffix * " — " * t.summary * ".",
                params = is_domain ?
                    [:from_utc_iso, :to_utc_iso, :skip, :take, :filter_json] :
                    [:from_utc_z, :to_utc_z],
                response_schema = is_domain ? "DomainEnvelope" : "DataEnvelope",
            )
        )
    end
    return out
end

function build_spec()
    paths = OrderedDict{String, Any}()
    tags = String[]

    for entry in Iterators.flatten((ENDPOINT_TABLE, _intraday_entries()))
        path = build_path(entry)
        path_obj = get!(paths, path, OrderedDict{String, Any}())
        method = "get"
        haskey(path_obj, method) && error(
            "Duplicate operation: $method $path. Differentiate via path " *
                "or method.",
        )
        path_obj[method] = build_operation(entry)
        entry.tag in tags || push!(tags, entry.tag)
    end

    spec = OrderedDict{String, Any}(
        "openapi" => "3.1.0",
        "info" => OrderedDict{String, Any}(
            "title" => "Joint Allocation Office (JAO) REST API",
            "version" => "0.1.0",
            "description" => INFO_DESCRIPTION,
        ),
        # We expose every server in the registry so OpenAPI tools know all
        # real hosts. Operations live under synthetic prefixes; the client
        # collapses the prefix back to the matching `base_url` at request
        # time.
        "servers" => [
            OrderedDict{String, Any}(
                    "url" => srv.base_url,
                    "description" => "Real base URL for synthetic prefix " *
                    "`$(srv.prefix)` (collapsed by the client hook).",
                ) for (_, srv) in SERVER_REGISTRY
        ],
        "tags" => vcat(
            OrderedDict{String, Any}[
                OrderedDict{String, Any}(
                    "name" => "PublicationToolCoreDA",
                    "description" => "Core CCR day-ahead flow-based market " *
                        "coupling — domain, net positions, shadow prices, " *
                        "validations, monitoring.",
                ),
                OrderedDict{String, Any}(
                    "name" => "PublicationToolNordicDA",
                    "description" => "Nordic CCR day-ahead — subset of Core " *
                        "(no `lta`, `netPos`, `allocationConstraint`, " *
                        "`alphaFactor`, `priceSpread`, `scheduledExchanges`) " *
                        "plus `fbDomainShadowPrice`; `d2CF` renamed to " *
                        "`cgmForeCast`; filter key `NonRedundant` replaces " *
                        "`Presolved`.",
                ),
                OrderedDict{String, Any}(
                    "name" => "PublicationToolItalyNorth",
                    "description" => "Italy North CCR — `CCR_*` for " *
                        "day-ahead, `CCR_id*` for intraday. Smaller surface " *
                        "than Core (CNECs, forecasts, TTC/NTC, allocation " *
                        "constraints).",
                ),
            ],
            [
                OrderedDict{String, Any}(
                        "name" => v.tag,
                        "description" => v.summary_suffix * ". Endpoints carry " *
                        "the variant prefix `$(v.endpoint_prefix)`; the " *
                        "`monitoring` system endpoint is shared with Core " *
                        "(see PublicationToolCoreDA tag).",
                    ) for v in _INTRADAY_VARIANTS
            ],
            OrderedDict{String, Any}[
                OrderedDict{String, Any}(
                    "name" => "OwsmpAuctions",
                    "description" => "Explicit cross-border capacity " *
                        "auctions (OWSMP). API key required " *
                        "(`AUTH_API_KEY` header).",
                ),
            ],
        ),
        "paths" => paths,
        "components" => OrderedDict{String, Any}(
            "schemas" => RESPONSE_SCHEMAS,
            "securitySchemes" => OrderedDict{String, Any}(
                "PublicationToolBearer" => OrderedDict{String, Any}(
                    "type" => "http",
                    "scheme" => "bearer",
                    "description" => "Anonymous bearer token extracted " *
                        "from the SPA at " *
                        "`https://publicationtool.jao.eu/core/`. Role is " *
                        "`Guest`; the API is effectively public.",
                ),
                "OwsmpApiKey" => OrderedDict{String, Any}(
                    "type" => "apiKey",
                    "in" => "header",
                    "name" => "AUTH_API_KEY",
                    "description" => "Issued by JAO helpdesk " *
                        "(`helpdesk@jao.eu`, subject `[API] Token Request`) " *
                        "after accepting the T&Cs.",
                ),
            ),
        ),
    )
    return spec
end

const INFO_DESCRIPTION = """
Auto-generated by `scripts/build_openapi.jl` from a declarative endpoint
table. JAO publishes neither an OpenAPI spec nor a Postman collection;
this spec consolidates the surface mined from the `jao-py` open-source
client (Publication Tool) and the `API_User_Guide_v1.0.pdf` (OWSMP
auctions).

The Publication Tool runs ASP.NET Core with Swashbuckle disabled; its
errors are RFC 7807 `application/problem+json`. OWSMP returns bare JSON
arrays. The Utility Tool (SOAP/WSDL) is intentionally out of scope.

Operations live under SYNTHETIC paths (`/publicationtool/core/data/...`,
`/owsmp/...`) so OpenAPI's `path + method` key-uniqueness constraint is
satisfied while preserving one Julia function per logical query. The
generated client's `pre_request_hook` collapses the synthetic prefix back
to the real base URL listed under `servers` at request time.
"""

# ---- entrypoint ----------------------------------------------------------

function run_build(output_base::AbstractString)
    spec = build_spec()

    yaml_out = output_base * ".yaml"
    json_out = output_base * ".json"

    YAML.write_file(yaml_out, spec)
    open(json_out, "w") do io
        JSON3.pretty(io, JSON3.write(spec))
    end

    op_count = sum(length(v) for v in values(spec["paths"]))
    println("Wrote: ", yaml_out)
    println("Wrote: ", json_out)
    println("Operations: ", op_count, " across ", length(spec["paths"]), " paths")
    println("Tags: ", join(t["name"] for t in spec["tags"]), ", ")
    return nothing
end

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_OUTPUT = joinpath(REPO_ROOT, "spec", "openapi")

if abspath(PROGRAM_FILE) == @__FILE__
    output = length(ARGS) >= 1 ? ARGS[1] : DEFAULT_OUTPUT
    mkpath(dirname(output))
    run_build(output)
end
