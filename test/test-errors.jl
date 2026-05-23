using JAOEU
using Test

@testset "Error type hierarchy" begin
    @test JAOEU.NetworkError(ErrorException("dns")) isa JAOEU.APIError
    @test JAOEU.ClientError(404, "not found") isa JAOEU.APIError
    @test JAOEU.ServerError(500, "boom") isa JAOEU.APIError
    @test JAOEU.AuthError(401, "nope") isa JAOEU.APIError
    @test JAOEU.RateLimitError(; retry_after = 5.0) isa JAOEU.APIError
    @test JAOEU.TimeoutError(:read) isa JAOEU.APIError
end

@testset "parse_retry_after" begin
    @test JAOEU.parse_retry_after("5") == 5.0
    @test JAOEU.parse_retry_after(" 12 ") == 12.0
    @test JAOEU.parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT") === nothing
    @test JAOEU.parse_retry_after("") === nothing
    @test JAOEU.parse_retry_after(nothing) === nothing
end

@testset "check_response 2xx returns nothing" begin
    for s in (200, 201, 204, 299)
        @test JAOEU.check_response(s, "") === nothing
    end
end

@testset "check_response classifies by status" begin
    @test_throws JAOEU.AuthError JAOEU.check_response(401, "")
    @test_throws JAOEU.AuthError JAOEU.check_response(403, "")
    @test_throws JAOEU.ClientError JAOEU.check_response(404, "missing")
    @test_throws JAOEU.ServerError JAOEU.check_response(503, "")
    @test_throws JAOEU.ClientError JAOEU.check_response(600, "weird")
end

@testset "check_response 429 surfaces RateLimitError" begin
    headers = Dict("Retry-After" => "7")
    err = try
        JAOEU.check_response(429, "", headers)
        nothing
    catch e
        e
    end
    @test err isa JAOEU.RateLimitError
    @test err.retry_after == 7.0
end
