# JAO routes one logical API onto several physically distinct hosts: the
# Publication Tool's Core, Nordic, Italy North, and CoreID Intraday
# platforms (each at its own subdomain path, all anonymous bearer), plus
# OWSMP for auctions (`AUTH_API_KEY` header, bare-array JSON). The
# OpenAPI spec keeps them in a single file under synthetic path prefixes
# (`/publicationtool/<platform>/...`, `/owsmp/...`) so codegen produces
# one Julia function per logical query. The routing hook below rewrites
# the synthetic prefix into the platform's real base URL at request
# time, so one `PublicationToolClient` can call across all four PT
# platforms; OWSMP is constructed separately for its different auth.

using OpenAPI: OpenAPI

using .JAOEUAPI: PublicationToolCoreDAApi, PublicationToolNordicDAApi,
    PublicationToolItalyNorthApi, PublicationToolCoreIDCCaApi,
    OwsmpAuctionsApi

const PUBLICATIONTOOL_CORE_BASE = "https://publicationtool.jao.eu/core/api"
const PUBLICATIONTOOL_NORDIC_BASE = "https://publicationtool.jao.eu/nordic/api"
const PUBLICATIONTOOL_ITALYNORTH_BASE = "https://publicationtool.jao.eu/ibwt/api"
const PUBLICATIONTOOL_COREID_BASE = "https://publicationtool.jao.eu/coreID/api"
const OWSMP_BASE = "https://api.jao.eu/OWSMP"

# Synthetic-prefix → real base URL. The `OpenAPI.Clients.Ctx`
# constructor concatenates `client.root + resource`, so by the time the
# pre_request_hook fires we get a URL with `client.root` prepended to
# the synthetic prefix. We can't just strip the prefix (that would
# leave the wrong host for any operation outside the platform the
# client was constructed for), so we look up the prefix's real base
# URL and replace everything from the URL's start through the end of
# the prefix. One `PublicationToolClient` can then call across all
# four PT platforms; only OWSMP needs its own client (different auth).
#
# Ordered by descending prefix specificity: `/publicationtool/coreID`
# must come before `/publicationtool/core` or the substring would
# match. Treat this list as ordered tuples, not a dict.
const _PLATFORM_REGISTRY = (
    ("/publicationtool/coreID", PUBLICATIONTOOL_COREID_BASE),
    ("/publicationtool/nordic", PUBLICATIONTOOL_NORDIC_BASE),
    ("/publicationtool/ibwt", PUBLICATIONTOOL_ITALYNORTH_BASE),
    ("/publicationtool/core", PUBLICATIONTOOL_CORE_BASE),
    ("/owsmp", OWSMP_BASE),
)

"""
    _strip_synthetic_prefix(url) -> String

Rewrite the resolved URL so it points at the right JAO host for its
operation. The OpenAPI spec mounts every operation under a synthetic
prefix (e.g. `/publicationtool/nordic`); this hook swaps the prefix
plus the inner client's `root` for the platform's real base URL.
Operates on the full URL string the OpenAPI client passes to the
stage-2 hook (`<client.root><synthetic prefix><endpoint>?<query>`).
"""
function _strip_synthetic_prefix(url::AbstractString)
    for (prefix, base) in _PLATFORM_REGISTRY
        idx = findfirst(prefix, url)
        idx === nothing && continue
        return string(base, SubString(url, last(idx) + 1))
    end
    return String(url)
end

# Two-stage pre_request_hook: stage 1 is a pass-through (Ctx is immutable,
# so we can't rewrite the resource there), stage 2 applies the
# platform-specific Auth and rewrites the assembled URL to the right host.
function _routing_hook(auth::Auth)
    hook(ctx) = ctx
    function hook(resource::AbstractString, body, headers::Dict{String, String})
        apply!(auth, headers)
        return _strip_synthetic_prefix(resource), body, headers
    end
    return hook
end

"""
    PublicationToolClient(; bearer = nothing) -> Client

Build a [`Client`](@ref) for the JAO Publication Tool — covers the
**Core day-ahead**, **Nordic day-ahead**, **Italy North**, and
**Core CCR Intraday (CoreID CC, variant A)** platforms via the
synthetic-prefix routing hook. The portal embeds an anonymous Guest
bearer in its SPA bundle; the API is effectively public, so `bearer`
defaults to `nothing` (no `Authorization` header sent). Pass a token
explicitly only if JAO has issued you one with elevated role.

Use the per-platform `*_api(client)` accessors to get a generated API
binding; the routing hook then dispatches each call to the correct
host based on its synthetic prefix.
"""
function PublicationToolClient(; bearer::Union{Nothing, AbstractString} = nothing)
    auth = bearer === nothing ? NoAuth() : BearerToken(String(bearer))
    # The inner client's `root` is just a placeholder — the routing hook
    # rewrites every URL based on its synthetic prefix. We set Core's
    # base URL so introspection / `client.base_url` shows something
    # sensible to the user.
    inner = OpenAPI.Clients.Client(
        PUBLICATIONTOOL_CORE_BASE;
        pre_request_hook = _routing_hook(auth),
    )
    return Client(inner, auth, PUBLICATIONTOOL_CORE_BASE)
end

"""
    OwsmpClient(api_key) -> Client

Build a [`Client`](@ref) for the OWSMP cross-border capacity auctions
API. `api_key` is sent on every request as the `AUTH_API_KEY` header.
Request a token from <https://www.jao.eu/page-api/market-data> via
"Request Token" — JAO issues a UUID after you submit the form and
accept the T&Cs.
"""
function OwsmpClient(api_key::AbstractString)
    auth = APIKey(String(api_key); header = "AUTH_API_KEY")
    inner = OpenAPI.Clients.Client(
        OWSMP_BASE;
        pre_request_hook = _routing_hook(auth),
    )
    return Client(inner, auth, OWSMP_BASE)
end

"""
    publicationtool_core_da_api(client) -> PublicationToolCoreDAApi

Build the generated low-level API binding for the Publication Tool's
Core day-ahead surface. Pass to any `publicationtool_core_da_*`
function (defined in `JAOEU.JAOEUAPI`).
"""
publicationtool_core_da_api(client::Client) =
    PublicationToolCoreDAApi(client.inner)

"""
    publicationtool_nordic_da_api(client) -> PublicationToolNordicDAApi

Build the generated low-level API binding for the Publication Tool's
Nordic day-ahead surface.
"""
publicationtool_nordic_da_api(client::Client) =
    PublicationToolNordicDAApi(client.inner)

"""
    publicationtool_italynorth_api(client) -> PublicationToolItalyNorthApi

Build the generated low-level API binding for the Publication Tool's
Italy North surface (both day-ahead `CCR_*` and intraday `CCR_id*`
endpoints).
"""
publicationtool_italynorth_api(client::Client) =
    PublicationToolItalyNorthApi(client.inner)

"""
    publicationtool_coreid_cc_a_api(client) -> PublicationToolCoreIDCCaApi

Build the generated low-level API binding for the Publication Tool's
Core CCR Intraday continuous-clearing surface (variant A). To wire in
variants B/C/D or the IDA flavours, extend `_INTRADAY_VARIANTS` in
`scripts/build_openapi.jl` and regenerate.
"""
publicationtool_coreid_cc_a_api(client::Client) =
    PublicationToolCoreIDCCaApi(client.inner)

"""
    owsmp_auctions_api(client) -> OwsmpAuctionsApi

Build the generated low-level API binding for the OWSMP auctions
surface. Pass to any `owsmp_*` function (defined in `JAOEU.JAOEUAPI`).
"""
owsmp_auctions_api(client::Client) = OwsmpAuctionsApi(client.inner)
