using Test
using NovelpiaAnalysis
using DataFrames
using Dates

const FIXTURES = joinpath(@__DIR__, "fixtures")
const NOVEL_NO = 127306

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
