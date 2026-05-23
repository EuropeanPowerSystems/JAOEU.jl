# Julia API Reference

```@meta
CurrentModule = JAOEU
```

## JAO clients

```@docs
PublicationToolClient
OwsmpClient
publicationtool_core_da_api
publicationtool_nordic_da_api
publicationtool_italynorth_api
publicationtool_coreid_cc_a_api
owsmp_auctions_api
```

## Time helpers

```@docs
to_zoned_utc
```

## Named query wrappers

```@docs
monitoring
net_position
final_domain
auction_corridors
auction_horizons
auction_results
```

## Response unwrappers

```@docs
rows
total_rows
```

## Generic Client

```@docs
Client
```

## Auth

```@docs
Auth
NoAuth
BearerToken
APIKey
BasicAuth
resolve_credentials
JAOEU.apply!
JAOEU.build_pre_request_hook
```

## Errors

```@docs
APIError
NetworkError
ClientError
ServerError
AuthError
RateLimitError
TimeoutError
check_response
JAOEU.parse_retry_after
```

## Reliability

```@docs
RetryPolicy
with_retry
JAOEU.is_retryable
JAOEU.backoff_delay
TokenBucket
acquire!
with_rate_limit
with_timeout
with_logging
redact_headers
DefaultMiddleware
default_middleware
with_defaults
```

## Pagination

```@docs
paginate_cursor
paginate_offset
paginate_pagenum
```

## Pretty printing

```@docs
Base.show(::IO, ::MIME"text/plain", ::T) where T <: OpenAPI.APIModel
```
