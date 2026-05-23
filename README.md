# JAOEU.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://EuropeanPowerSystems.github.io/JAOEU.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://EuropeanPowerSystems.github.io/JAOEU.jl/dev/)
[![Build Status](https://github.com/EuropeanPowerSystems/JAOEU.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/EuropeanPowerSystems/JAOEU.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Documentation](https://github.com/EuropeanPowerSystems/JAOEU.jl/actions/workflows/Documentation.yml/badge.svg?branch=main)](https://github.com/EuropeanPowerSystems/JAOEU.jl/actions/workflows/Documentation.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/EuropeanPowerSystems/JAOEU.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/EuropeanPowerSystems/JAOEU.jl)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![tested with JET.jl](https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a)](https://github.com/aviatesk/JET.jl)

A Julia client for the [Joint Allocation Office](https://www.jao.eu) REST
APIs — flow-based market coupling on the **Core CCR**, **Nordic CCR**,
**Italy North CCR**, and **Core CCR Intraday** platforms, plus the
**OWSMP** explicit-auction surface. Wraps 58 operations across 5 platforms,
generated from an OpenAPI 3.1 spec that this repo synthesizes from the
open-source [`jao-py`](https://github.com/fboerman/jao-py) and the
official [OWSMP PDF](https://www.jao.eu/sites/default/files/2021-05/API_User_Guide_v1.0.pdf).

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/EuropeanPowerSystems/JAOEU.jl")
```

JAOEU.jl is not yet registered in the General registry. End users only
need Julia 1.10+; the OpenAPI codegen and its Java/Node toolchain are
maintainer-only and never run at install time.

## Quickstart

Every snippet below is copy-pasteable and runs against the live JAO APIs.
Publication Tool calls are **anonymous** — no token needed. The OWSMP
section is gated on an API key (see [Obtaining a token](#obtaining-an-owsmp-token)).

Both response envelopes (`DataEnvelope`, `DomainEnvelope`) implement
the [Tables.jl](https://github.com/JuliaData/Tables.jl) interface, so
`DataFrame(env)`, `StructArrays.StructArray(env)`, `CSV.write(io, env)`
and friends work directly — no manual unwrapping. Reach for `rows(env)`
only when you want the raw `JSON.Object` array.

### 1. Publication monitoring (anonymous)

What was published, when, for a given business day. Smallest call we make
and the gentlest smoke test:

```julia
using JAOEU, Dates, DataFrames

client = PublicationToolClient()
env, _ = monitoring(client,
    DateTime("2024-09-01T00:00"),
    DateTime("2024-09-02T00:00"),
)
df = DataFrame(env)
@show size(df)                                          # → (32, 7)
df[1, [:businessDayUtc, :page, :status]]
```

Columns: `id`, `businessDayUtc`, `deadline`, `page` (the computation
stage — `Initial Computation`, `Pre-Final`, `Final`, …), `status`,
`lastModifiedOn`, `followUpActionInitiated`.

### 2. Net positions per bidding zone (anonymous)

One row per market time unit (24 hourly rows for a trading day), one
column per Core hub. Positive means net export, negative means net import:

```julia
using JAOEU, Dates, DataFrames

client = PublicationToolClient()
env, _ = net_position(client,
    DateTime("2024-09-01T22:00"),     # 2024-09-02 00:00 CET
    DateTime("2024-09-02T22:00"),
)
df = DataFrame(env)
@show size(df)                                          # → (24, 16)
@show round(Int, df.hub_NL[1])                          # → -437
@show round(Int, df.hub_DE[1])                          # → 3475
```

Hub columns for Core: `hub_AT, hub_BE, hub_CZ, hub_DE, hub_FR, hub_HR,
hub_HU, hub_NL, hub_PL, hub_RO, hub_SI, hub_SK` plus the two virtual
hubs `hub_ALBE` / `hub_ALDE`.

### 3. Full flow-based domain (anonymous)

The CNECs + PTDFs that *produced* those net positions. One MTU has ~12 k
rows (each row carries 38 metadata fields and 15 `ptdf_*` columns):

```julia
using JAOEU, Dates, DataFrames

client = PublicationToolClient()
env, _ = final_domain(client,
    DateTime("2024-09-01T22:00"),
    DateTime("2024-09-01T23:00"),
)
@show total_rows(env)                                   # → 11774
df = DataFrame(env)
@show size(df)                                          # → (11774, 53)
@show count(startswith("ptdf_"), names(df))             # → 15
```

For multi-MTU windows the response is paginated — call the generated
layer (`JAOEU.JAOEUAPI.publicationtool_core_da_final_computation`) with
`take = 0` to read the count, then page in 5000-row chunks.

### 4. OWSMP auction corridors (needs token)

Once you have a token (see below), enumerate the corridors usable by
[`auction_results`](https://EuropeanPowerSystems.github.io/JAOEU.jl/dev/julia_reference/#JAOEU.auction_results):

```julia
using JAOEU

owsmp = OwsmpClient(ENV["JAO_OWSMP_API_KEY"])
corridors, _ = auction_corridors(owsmp)
@show length(corridors)                              # → 121
[c["value"] for c in corridors[1:5]]                 # → ["IT-CH", "HU-SK", "ES-PT", "FR-IT", "SK-CZ"]
```

## Obtaining an OWSMP token

The **Publication Tool** APIs (`monitoring`, `net_position`,
`final_domain`, all CCR endpoints) are anonymous — the SPA embeds a
public Guest bearer and the server accepts unauthenticated GETs. You can
skip this section if you only need flow-based data.

The **OWSMP auctions** API requires per-user authentication. To obtain a
token:

1. Visit [`jao.eu/page-api/market-data`](https://www.jao.eu/page-api/market-data)
   and click **Request Token**.
2. On the form at [`/get-token`](https://www.jao.eu/get-token), fill in the required fields and submit.
3. JAO issues a UUID token, usually this arrives immediately after confirming your email.
4. **Store the token.** JAOEU.jl reads it from `ENV["JAO_OWSMP_API_KEY"]`.
   For an interactive session:

   ```bash
   export JAO_OWSMP_API_KEY=00000000-0000-0000-0000-000000000000
   ```

The token is sent on every OWSMP request as the `AUTH_API_KEY` header
(JAOEU.jl does this for you via `OwsmpClient(api_key)`). Treat it as a
secret: do not commit it, do not paste it into public chat, and rotate
it via the same form if it leaks.

## Platform coverage

| Platform | Constructor | Endpoints | Auth |
| --- | --- | --- | --- |
| Publication Tool — Core day-ahead | `PublicationToolClient()` | 18 | anonymous |
| Publication Tool — Nordic day-ahead | `PublicationToolClient()` | 12 | anonymous |
| Publication Tool — Italy North (DA + ID) | `PublicationToolClient()` | 8 | anonymous |
| Publication Tool — Core CCR Intraday (variant A) | `PublicationToolClient()` | 15 | anonymous |
| OWSMP explicit auctions | `OwsmpClient(api_key)` | 5 | `AUTH_API_KEY` header |

A single `PublicationToolClient()` works for all four Publication Tool
platforms — the routing hook in `src/conveniences/client.jl` rewrites
each call to the right host based on the OpenAPI synthetic prefix. The
Intraday CC/IDA variants B, C, D, ID1, … are a 5-line addition in
`scripts/build_openapi.jl#_INTRADAY_VARIANTS` followed by
`gen/regenerate.jl`.

The legacy SOAP **Utility Tool** (`utilitytool.jao.eu`) is intentionally
out of scope — `jao-py` marks it deprecated, and SOAP doesn't fit the
OpenAPI codegen pipeline.

## Architecture

Three stacked layers:

- **`src/api/`** — generated by [OpenAPI Generator](https://openapi-generator.tech/)'s
  `julia-client` from `spec/openapi.json`. Committed as plain Julia.
  Refreshed via `gen/regenerate.jl`. Never touched at end-user runtime;
  end users do not need Java or Node.
- **`src/client/`** — hand-written reliability overlay: `Client` struct,
  composable middleware, typed `APIError` hierarchy, retry / rate-limit /
  timeout. Scaffolded by [OpenAPITemplate.jl](https://github.com/langestefan/OpenAPITemplate.jl).
- **`src/conveniences/`** — JAO-specific layer: `PublicationToolClient` /
  `OwsmpClient` constructors, the synthetic-prefix routing hook, named
  query wrappers (`monitoring`, `net_position`, `final_domain`,
  `auction_corridors`, …), `to_zoned_utc`, `rows` / `total_rows`.

`spec/openapi.json` itself is synthesized — JAO publishes neither an
OpenAPI spec nor a Postman collection. `scripts/build_openapi.jl` reads
a declarative endpoint table (sourced from `jao-py` + the OWSMP PDF)
and emits OpenAPI 3.1.

## Documentation

The full docs site (auto-deployed from `main`) lives at
[EuropeanPowerSystems.github.io/JAOEU.jl/dev/](https://EuropeanPowerSystems.github.io/JAOEU.jl/dev/).
Highlights:

- [Quickstart tutorial](https://EuropeanPowerSystems.github.io/JAOEU.jl/dev/tutorial/) —
  monitoring, net positions, and the flow-based domain across one
  trading day.
- [Net positions on a European map](https://EuropeanPowerSystems.github.io/JAOEU.jl/dev/tutorial_net_positions_map/) —
  GeoMakie rendering of the 12 Core zones across 24 MTUs.
- [Julia API reference](https://EuropeanPowerSystems.github.io/JAOEU.jl/dev/julia_reference/) —
  every exported name with its docstring.
- [Interactive REST browser](https://EuropeanPowerSystems.github.io/JAOEU.jl/dev/api/) —
  `vitepress-openapi` rendering of `spec/openapi.json`, with try-it-out.

To build the docs locally:

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

## Maintainer notes

### Regenerating the spec + generated code

The spec is synthesized locally (no upstream URL to drift against):

```bash
# 1. Edit ENDPOINT_TABLE / SERVER_REGISTRY in scripts/build_openapi.jl
# 2. Rebuild spec/openapi.{json,yaml}
julia scripts/build_openapi.jl

# 3. Re-run codegen against the new spec
julia --project gen/regenerate.jl
```

`gen/regenerate.jl` requires Java 11+ and Node 18+. End users never need
either — `src/api/` ships as plain Julia. The pinned generator version
lives in `gen/openapi-config.json`.

### Reliability stack

Compose retry / rate-limit / timeout / logging around any call (OWSMP's
rate limit is 100 req/min — wrap batch jobs in a `TokenBucket`):

```julia
result = with_defaults(;
    retry      = RetryPolicy(; max_attempts = 5, base_delay = 0.5),
    rate_limit = TokenBucket(; rate = 1.5, burst = 5.0),   # OWSMP: ≤100/min
    timeout    = 30.0,
) do
    auction_corridors(owsmp)
end
```

Default `RetryPolicy()` honours `Retry-After` headers and retries on
`408`/`429`/`5xx`. Set any layer to `nothing` to disable it.

### Errors

Every non-2xx response is mapped to a typed exception by `check_response`:

| Status | Type |
| --- | --- |
| 401 / 403 | `AuthError` |
| 408 / 429 | `RateLimitError` (parses `Retry-After`) |
| Other 4xx | `ClientError` |
| 5xx | `ServerError` |
| Network / DNS / TLS | `NetworkError` (wraps cause) |
| Timeout | `TimeoutError(:connect \| :read \| :total)` |

The OpenAPI client also surfaces `200 OK` responses that *contain* a
problem detail as a typed `ProblemDetails` instead of the success
schema; check `typeof(env)` if you suspect an empty / malformed page.

### Acknowledgements

- [`jao-py`](https://github.com/fboerman/jao-py) (Frank Boerman) — the
  authoritative reference for the Publication Tool API surface, mined
  directly to populate `ENDPOINT_TABLE`.
- [`OpenAPITemplate.jl`](https://github.com/langestefan/OpenAPITemplate.jl) —
  PkgTemplates plugin that produces the scaffold, including
  `src/client/` and the docs site.
