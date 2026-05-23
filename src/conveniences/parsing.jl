using .JAOEUAPI: DataEnvelope, DomainEnvelope

# Both Publication Tool response shapes wrap their payload in a `data`
# array of free-form objects (the JSON schema deliberately leaves columns
# loose since they differ per endpoint). For convenience-layer callers we
# unwrap to a plain `Vector{Any}` of rows; users can pass that straight
# into `DataFrame(rows)` or `StructArrays.StructArray(rows)`.

"""
    rows(env) -> Vector{Any}

Return the `data` array from a response envelope, unwrapping the JSON
shape so callers don't have to know whether they got a paginated
`DomainEnvelope` (`finalComputation` &c.) or a date-range `DataEnvelope`
(`netPos`, `monitoring`, …). Returns an empty vector if the field is
absent — the Publication Tool sometimes omits `data` entirely on
zero-row pages.

```julia
client = PublicationToolClient()
env, _ = JAOEU.publicationtool_core_da_net_position(
    publicationtool_core_da_api(client),
    to_zoned_utc(DateTime("2024-09-01T22:00")),
    to_zoned_utc(DateTime("2024-09-02T22:00")),
)
records = rows(env)        # Vector of NamedTuple-ish objects
```
"""
function rows(env::Union{DataEnvelope, DomainEnvelope})
    data = env.data
    data === nothing && return Any[]
    return data
end

"""
    total_rows(env::DomainEnvelope) -> Union{Int, Nothing}

Report `totalRowsWithFilter` from the paginated domain envelope so a
caller can plan their paging strategy. Use the two-phase pattern: issue
the first call with `take = 0` to read this number, then page through
with `take = 5000` (the size jao-py uses).
"""
total_rows(env::DomainEnvelope) = env.totalRowsWithFilter
