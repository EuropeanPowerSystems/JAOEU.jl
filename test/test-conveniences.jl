using JAOEU
using JAOEU.JAOEUAPI: DataEnvelope, DomainEnvelope,
    PublicationToolCoreDAApi, PublicationToolNordicDAApi,
    PublicationToolItalyNorthApi, PublicationToolCoreIDCCaApi,
    OwsmpAuctionsApi
using OpenAPI: OpenAPI
using Dates: DateTime, Date
using TimeZones: ZonedDateTime, FixedTimeZone, astimezone
using Tables: Tables
using Test

# ── client.jl: per-platform constructors + the routing hook ──────────────

@testset "PublicationToolClient — anonymous" begin
    c = PublicationToolClient()
    @test c isa JAOEU.Client
    @test c.auth isa JAOEU.NoAuth
    @test c.base_url == JAOEU.PUBLICATIONTOOL_CORE_BASE
    @test c.inner isa OpenAPI.Clients.Client
end

@testset "PublicationToolClient — explicit bearer" begin
    c = PublicationToolClient(; bearer = "test-token-xyz")
    @test c.auth isa JAOEU.BearerToken
    @test c.auth.token == "test-token-xyz"
end

@testset "OwsmpClient — API key wired into auth strategy" begin
    c = OwsmpClient("00000000-0000-0000-0000-000000000000")
    @test c isa JAOEU.Client
    @test c.auth isa JAOEU.APIKey
    @test c.auth.header == "AUTH_API_KEY"
    @test c.auth.key == "00000000-0000-0000-0000-000000000000"
    @test c.base_url == JAOEU.OWSMP_BASE
end

@testset "Per-platform API binding accessors" begin
    pt = PublicationToolClient()
    @test publicationtool_core_da_api(pt) isa PublicationToolCoreDAApi
    @test publicationtool_nordic_da_api(pt) isa PublicationToolNordicDAApi
    @test publicationtool_italynorth_api(pt) isa PublicationToolItalyNorthApi
    @test publicationtool_coreid_cc_a_api(pt) isa PublicationToolCoreIDCCaApi

    ow = OwsmpClient("k")
    @test owsmp_auctions_api(ow) isa OwsmpAuctionsApi
end

@testset "_strip_synthetic_prefix — each platform rewrites to its real host" begin
    strip = JAOEU._strip_synthetic_prefix

    # Core DA
    @test strip("https://publicationtool.jao.eu/core/api/publicationtool/core/data/finalComputation") ==
        "https://publicationtool.jao.eu/core/api/data/finalComputation"
    @test strip("https://publicationtool.jao.eu/core/api/publicationtool/core/system/monitoring?FromUtc=x") ==
        "https://publicationtool.jao.eu/core/api/system/monitoring?FromUtc=x"

    # Nordic
    @test strip("https://publicationtool.jao.eu/core/api/publicationtool/nordic/data/fbDomainShadowPrice") ==
        "https://publicationtool.jao.eu/nordic/api/data/fbDomainShadowPrice"

    # Italy North
    @test strip("https://publicationtool.jao.eu/core/api/publicationtool/ibwt/data/CCR_cnecInfo") ==
        "https://publicationtool.jao.eu/ibwt/api/data/CCR_cnecInfo"

    # CoreID — must match before /core (longer prefix wins)
    @test strip("https://publicationtool.jao.eu/core/api/publicationtool/coreID/data/IDCCa_intradayAtc") ==
        "https://publicationtool.jao.eu/coreID/api/data/IDCCa_intradayAtc"

    # OWSMP — host swap too
    @test strip("https://api.jao.eu/OWSMP/owsmp/getauctions?corridor=X") ==
        "https://api.jao.eu/OWSMP/getauctions?corridor=X"

    # No synthetic prefix → fallthrough preserves the URL
    @test strip("https://example.test/already/clean") ==
        "https://example.test/already/clean"
end

@testset "_routing_hook — three-arg form rewrites path and applies auth" begin
    hook = JAOEU._routing_hook(JAOEU.APIKey("secret"; header = "AUTH_API_KEY"))
    headers = Dict{String, String}()
    url_in = "https://api.jao.eu/OWSMP/owsmp/getcorridors"
    url_out, _, headers_out = hook(url_in, nothing, headers)
    @test url_out == "https://api.jao.eu/OWSMP/getcorridors"
    @test headers_out["AUTH_API_KEY"] == "secret"

    # The Ctx-form is a pass-through — sanity check the dispatch exists.
    ctx_sentinel = (resource = "x",)
    @test hook(ctx_sentinel) === ctx_sentinel
end

# ── period.jl: to_zoned_utc method coverage ──────────────────────────────

@testset "to_zoned_utc accepts DateTime / Date / ZonedDateTime" begin
    dt = DateTime("2024-09-01T22:00")
    @test to_zoned_utc(dt) isa ZonedDateTime
    @test to_zoned_utc(dt) == ZonedDateTime(dt, JAOEU._UTC)

    @test to_zoned_utc(Date(2024, 9, 2)) ==
        ZonedDateTime(DateTime(2024, 9, 2, 0, 0), JAOEU._UTC)

    cet = FixedTimeZone("CET", 3600)
    z = ZonedDateTime(DateTime("2024-09-02T00:00"), cet)
    coerced = to_zoned_utc(z)
    @test coerced isa ZonedDateTime
    @test coerced.timezone == JAOEU._UTC
    @test DateTime(coerced) == DateTime("2024-09-01T23:00")   # CET → UTC shift
end

# ── parsing.jl: rows, total_rows, Tables.jl interface ────────────────────

# Build the envelopes from plain Dicts so we don't need a live API call.
const _SAMPLE_DATA_ROWS = Any[
    Dict{String, Any}(
        "dateTimeUtc" => "2024-09-01T22:00:00Z",
        "hub_DE" => 3475.3, "hub_NL" => -436.6,
    ),
    Dict{String, Any}(
        "dateTimeUtc" => "2024-09-01T23:00:00Z",
        "hub_DE" => 3443.0, "hub_NL" => -304.6,
    ),
]
const _SAMPLE_DOMAIN_ROWS = Any[
    Dict{String, Any}(
        "cneName" => "Line A", "ram" => 641.0,
        "ptdf_DE" => 0.42, "ptdf_NL" => -0.13,
    ),
    Dict{String, Any}(
        "cneName" => "Line B", "ram" => 220.0,
        "ptdf_DE" => 0.09, "ptdf_NL" => nothing,   # null PTDF → coalesce target
    ),
]

@testset "rows — unwraps env.data" begin
    env = DataEnvelope(); env.data = _SAMPLE_DATA_ROWS
    @test rows(env) === _SAMPLE_DATA_ROWS

    dom = DomainEnvelope(); dom.data = _SAMPLE_DOMAIN_ROWS
    @test rows(dom) === _SAMPLE_DOMAIN_ROWS

    # Empty / nothing data returns an empty vector, not throws
    empty_env = DataEnvelope()
    @test rows(empty_env) isa AbstractVector
    @test isempty(rows(empty_env))
end

@testset "total_rows — exposes paginated count" begin
    dom = DomainEnvelope()
    dom.data = _SAMPLE_DOMAIN_ROWS
    dom.totalRowsWithFilter = 11774
    @test total_rows(dom) == 11774
end

@testset "Tables.jl — DataEnvelope implements the columnar interface" begin
    env = DataEnvelope(); env.data = _SAMPLE_DATA_ROWS
    @test Tables.istable(DataEnvelope) === true
    @test Tables.istable(typeof(env)) === true
    @test Tables.columnaccess(DataEnvelope) === true

    cols = Tables.columns(env)
    schema = Tables.schema(cols)
    @test :hub_DE in schema.names
    @test :hub_NL in schema.names
    @test :dateTimeUtc in schema.names
    @test length(Tables.getcolumn(cols, :hub_DE)) == 2
end

@testset "Tables.jl — DomainEnvelope handles sparse PTDF columns" begin
    dom = DomainEnvelope(); dom.data = _SAMPLE_DOMAIN_ROWS
    @test Tables.istable(DomainEnvelope) === true

    cols = Tables.columns(dom)
    # dictcolumntable fills missing for absent keys — Line B's null
    # PTDF should round-trip as missing.
    ptdf_nl = collect(Tables.getcolumn(cols, :ptdf_NL))
    @test ptdf_nl[1] == -0.13
    @test ismissing(ptdf_nl[2]) || ptdf_nl[2] === nothing
end

@testset "Tables.jl — empty envelope yields a zero-row table" begin
    env = DataEnvelope()   # env.data === nothing
    cols = Tables.columns(env)
    @test Tables.rowcount(cols) == 0
end

# ── queries.jl: live Publication Tool calls ──────────────────────────────
#
# Each named wrapper is a 1-line proxy that constructs the platform's
# generated Api binding and forwards through `to_zoned_utc`. Coverage on
# these lines requires actually executing the call, which means hitting
# the live anonymous Publication Tool. Skip the section gracefully if
# the network is unreachable or JAO is down — the structure of the
# wrapper is already covered by the per-platform `*_api` accessor tests
# above, this block is the integration smoke test.

let
    client = PublicationToolClient()
    t0 = DateTime("2024-09-01T00:00")
    t1 = DateTime("2024-09-02T00:00")
    can_reach_jao = try
        # Cheapest call — monitoring is a few KB.
        monitoring(client, t0, t1)
        true
    catch err
        @info "Publication Tool unreachable — skipping queries.jl live tests" err = sprint(showerror, err)
        false
    end

    if can_reach_jao
        @testset "monitoring — live call returns rows" begin
            env, resp = monitoring(client, t0, t1)
            @test resp.raw.status == 200
            @test env isa DataEnvelope
            @test length(rows(env)) > 0
        end

        @testset "net_position — live call returns 24 MTUs of hub_* columns" begin
            env, resp = net_position(
                client,
                DateTime("2024-09-01T22:00"),
                DateTime("2024-09-02T22:00"),
            )
            @test resp.raw.status == 200
            data = rows(env)
            @test length(data) == 24
            @test any(k -> startswith(String(k), "hub_"), keys(first(data)))
        end

        @testset "final_domain — live call exposes total_rows" begin
            env, resp = final_domain(
                client,
                DateTime("2024-09-01T22:00"),
                DateTime("2024-09-01T23:00"),
            )
            @test resp.raw.status == 200
            @test env isa DomainEnvelope
            @test total_rows(env) isa Integer
            @test total_rows(env) > 0
        end
    end
end
