using JAOEU
using Test

# Aqua and JET are scaffolded into test/Project.toml by default. To drop them:
#   pkg> activate test
#   pkg> rm Aqua JET
# The detect-and-skip below makes that graceful (no test failure).

let aqua_id = Base.identify_package("Aqua")
    if aqua_id === nothing
        @info "Aqua not installed; skipping. `pkg> add Aqua@0.8` in `test/` to enable."
    else
        Aqua = Base.require(aqua_id)
        @testset "Aqua" begin
            # `Base.require` advances the world; without `invokelatest` Julia
            # 1.12 refuses to dispatch to a method whose world is newer than
            # the call site's.
            Base.invokelatest(Aqua.test_all, JAOEU;
                ambiguities = false, stale_deps = false)
        end
    end
end

if v"1.12" <= VERSION < v"1.13"
    let jet_id = Base.identify_package("JET")
        if jet_id === nothing
            @info "JET not installed; skipping. `pkg> add JET@0.11` in `test/` to enable."
        else
            JET = Base.require(jet_id)
            @testset "JET" begin
                Base.invokelatest(JET.test_package, JAOEU;
                    target_modules = (JAOEU,))
            end
        end
    end
else
    @info "JET tests require Julia 1.12; skipping on $VERSION."
end
