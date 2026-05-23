using Tables: Tables
using .JAOEUAPI: DataEnvelope, DomainEnvelope

# Both Publication Tool response shapes wrap their payload in a `data`
# array of free-form JSON objects (the OpenAPI schema deliberately
# leaves the row shape loose — different endpoints carry different
# columns, and even within one endpoint the column set depends on
# which CCR zones / borders the request resolves to). We expose the
# envelope as a Tables.jl source so callers can hand it directly to
# `DataFrame`, `StructArray`, or any other Tables.jl consumer; `rows`
# is kept as a thin escape hatch for code that just wants the raw
# `JSON.Object` array.

"""
    rows(env) -> Vector

Return the raw `data` array from a response envelope (a vector of
`JSON.Object`-like dicts). Returns an empty vector if the field is
absent — the Publication Tool sometimes omits `data` entirely on
zero-row pages.

Prefer the Tables.jl interface for analysis — `DataFrame(env)` or
`StructArrays.StructArray(env)` work directly. Reach for `rows(env)`
when you need per-record dict access without column-unioning.
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

# ─── Tables.jl interface ──────────────────────────────────────────────────
#
# Both envelopes are columnar tables under `data`. Rows are JSON.Object
# (≡ `AbstractDict{String, Any}`); we delegate to
# `Tables.dictcolumntable`, which materializes the column-union and fills
# `missing` for absent keys. That makes the rare per-row null (e.g.
# PTDFs that aren't sensitive to a zone) handled correctly.

Tables.istable(::Type{<:Union{DataEnvelope, DomainEnvelope}}) = true
Tables.columnaccess(::Type{<:Union{DataEnvelope, DomainEnvelope}}) = true

function Tables.columns(env::Union{DataEnvelope, DomainEnvelope})
    data = env.data === nothing ? Any[] : env.data
    return Tables.columns(Tables.dictcolumntable(data))
end

# Row access falls out of column access via Tables.jl's default
# implementation, so callers can `for row in Tables.rows(env)` too.
