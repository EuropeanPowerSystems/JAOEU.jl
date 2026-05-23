using JAOEU
using OpenAPI
using Test

@testset "Client construction" begin
    c = JAOEU.Client("https://example.test/api")
    @test c isa JAOEU.Client
    @test c.base_url == "https://example.test/api"
    @test c.auth isa JAOEU.NoAuth
    @test c.inner isa OpenAPI.Clients.Client
end

@testset "Client with auth" begin
    c = JAOEU.Client("https://example.test"; auth = JAOEU.BearerToken("abc"))
    @test c.auth isa JAOEU.BearerToken
    @test c.auth.token == "abc"
end
