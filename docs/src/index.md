```@meta
CurrentModule = JAOEU
```

# JAOEU.jl

Documentation for [JAOEU.jl](https://github.com/EuropeanPowerSystems/JAOEU.jl).

A Julia REST/JSON API wrapper scaffolded with
[OpenAPITemplate.jl](https://github.com/langestefan/OpenAPITemplate.jl).

## Quick start

```julia
using JAOEU

client = Client("https://api.example.com"; auth = BearerToken(ENV["JAOEU_TOKEN"]))
```

See the [Getting Started](getting_started.md) guide for a worked example, or
the [Julia API Reference](julia_reference.md) for the full surface.
