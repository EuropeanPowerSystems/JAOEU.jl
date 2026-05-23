# Examples

Runnable walkthrough of `JAOEU.jl`'s public surface.

## Setup

```bash
# From the repo root — develop the local package into the examples env
julia --project=examples -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
```

## Run

```bash
julia --project=examples examples/walkthrough.jl
```

Publication Tool calls are anonymous, so the script runs end to end
without any credentials. OWSMP auction sections are gated on an API
key, resolved in this order:

1. `ENV["JAO_OWSMP_API_KEY"]`
2. `token.txt` at the repo root (single line, gitignored)

If neither is set, the OWSMP section logs a hint and skips itself —
the rest of the walkthrough still runs.

Request an OWSMP key from `helpdesk@jao.eu` with subject
`[API] Token Request` after accepting the T&Cs.

## What it covers

- `PublicationToolClient()` construction; `to_zoned_utc` coercion.
- `monitoring` — publication deadlines per business day (small, anonymous,
  ideal smoke check).
- `net_position` — Core day-ahead net positions per bidding zone.
- `final_domain` — flow-based CNECs + PDFFs with the two-phase
  `totalRowsWithFilter` pattern.
- Dropping into `JAOEU.JAOEUAPI` directly for endpoints without a named
  wrapper (`shadow_prices` as the example).
- `OwsmpClient` + `auction_horizons` / `auction_corridors` (when a key
  is available).
