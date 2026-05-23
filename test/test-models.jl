using JAOEU
using OpenAPI
using Test

@testset "Generated module surface" begin
    @test isdefined(JAOEU, :JAOEUAPI)
    api_mod = getfield(JAOEU, :JAOEUAPI)
    public = filter(n -> n !== :JAOEUAPI, names(api_mod; all = false))
    @test !isempty(public)
end

@testset "API model types" begin
    api_mod = getfield(JAOEU, :JAOEUAPI)
    model_types = [
        getfield(api_mod, n) for n in names(api_mod; all = false)
            if isdefined(api_mod, n) &&
            getfield(api_mod, n) isa Type &&
            getfield(api_mod, n) !== api_mod &&
            getfield(api_mod, n) <: OpenAPI.APIModel
    ]
    @test !isempty(model_types)
    for T in model_types
        @test_nowarn try
            T()
        catch e
            e isa Union{ArgumentError, MethodError, UndefKeywordError} || rethrow()
        end
    end
end

@testset "API set types accept Client" begin
    api_mod = getfield(JAOEU, :JAOEUAPI)
    api_sets = [
        getfield(api_mod, n) for n in names(api_mod; all = false)
            if isdefined(api_mod, n) &&
            getfield(api_mod, n) isa Type &&
            getfield(api_mod, n) <: OpenAPI.APIClientImpl
    ]
    @test !isempty(api_sets)
    inner = OpenAPI.Clients.Client("https://example.test")
    for T in api_sets
        @test T(inner) isa T
    end
end
