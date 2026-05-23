module JAOEU

using HTTP: HTTP
using JSON: JSON
using OpenAPI: OpenAPI

# Generated low-level surface — DO NOT EDIT, regenerate via gen/regenerate.jl
include("api/JAOEUAPI.jl")
using .JAOEUAPI

# Re-export every public name from the generated module so users don't have to
# qualify with `JAOEUAPI.`.
for n in names(JAOEUAPI; all = false)
    n === Symbol("JAOEUAPI") && continue
    @eval export $n
end

# Hand-written ergonomic surface
include("client/auth.jl")
include("client/errors.jl")
include("client/logging.jl")
include("client/retry.jl")
include("client/rate_limit.jl")
include("client/timeout.jl")
include("client/middleware.jl")
include("client/Client.jl")
include("client/pagination.jl")
include("client/show.jl")

export Client, Auth, NoAuth, BearerToken, APIKey, BasicAuth, resolve_credentials
export APIError, NetworkError, ClientError, ServerError, AuthError,
    RateLimitError, TimeoutError, check_response
export RetryPolicy, with_retry
export TokenBucket, acquire!, with_rate_limit
export with_timeout
export with_logging, redact_headers
export DefaultMiddleware, default_middleware, with_defaults
export paginate_cursor, paginate_offset, paginate_pagenum

# JAO-specific helpers (hand-written, untouched by codegen). Safe across
# `gen/regenerate.jl` runs — that script only rewrites `src/api/`.
include("conveniences/conveniences.jl")

end # module
