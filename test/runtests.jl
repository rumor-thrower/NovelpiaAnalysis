using Test
using NovelpiaAnalysis
using DataFrames
using Dates

const FIXTURES = joinpath(@__DIR__, "fixtures")
const NOVEL_NO = 127306

# With no ARGS, run the whole suite as below. Otherwise run only the named
# files, given as paths relative to this directory:
#   julia --project=test -e 'push!(LOAD_PATH, "."); include("test/runtests.jl")' stats_test.jl
# Aqua lints the package as a whole rather than any one file, so it runs only
# in the full suite.
if isempty(ARGS)
    @testset "NovelpiaAnalysis" begin
        include("load_test.jl")
        include("frames_test.jl")
        include("stats_test.jl")
        include("charts_test.jl")
    end

    @testset "Aqua" begin
        using Aqua
        Aqua.test_all(NovelpiaAnalysis; ambiguities = false)
    end
else
    @testset "selected" begin
        for file in ARGS
            include(joinpath(@__DIR__, file))
        end
    end
end
