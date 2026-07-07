using Test
using NovelpiaAnalysis
using DataFrames
using Dates

const FIXTURES = joinpath(@__DIR__, "fixtures")
const NOVEL_NO = 127306

@testset "NovelpiaAnalysis" begin
    @testset "Load" begin
        manifest = Load.read_manifest(FIXTURES, NOVEL_NO)
        @test manifest.novel_no == NOVEL_NO
        @test manifest.episode_count == 2
        @test manifest.review_count == 0
        @test manifest.files == ["novel_127306_episodes.csv", "novel_127306_reviews.csv"]

        episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
        @test nrow(episodes) == manifest.episode_count
        @test eltype(episodes.episode_no) == Int
        @test eltype(episodes.is_free) == Bool
        @test episodes.reg_date[1] == Date(2023, 3, 23)
        @test episodes.count_view == [356, 110]

        reviews = Load.read_reviews(FIXTURES, NOVEL_NO)
        @test nrow(reviews) == 0

        data = Load.load(FIXTURES, NOVEL_NO)
        @test data.manifest.novel_no == NOVEL_NO
        @test nrow(data.episodes) == 2
        @test nrow(data.reviews) == 0
    end

    @testset "Frames" begin
        episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
        Frames.add_retention!(episodes)
        @test episodes.retention == episodes.count_view ./ episodes.count_view[1]
        @test episodes.retention[1] == 1.0

        Frames.add_cumulative_views!(episodes)
        @test episodes.cumulative_views == cumsum(episodes.count_view)

        Frames.add_view_diff!(episodes)
        @test ismissing(episodes.view_diff[1])
        @test episodes.view_diff[2:end] == diff(episodes.count_view)

        rising = Frames.rising_episodes(episodes)
        @test nrow(rising) == count(x -> !ismissing(x) && x > 0, episodes.view_diff)
        @test all(rising.view_diff .> 0)
    end

    @testset "Stats" begin
        episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
        s = Stats.summary(episodes)
        @test s.episode_count == 2
        @test s.free_count == 2
        @test s.paid_count == 0
        @test s.total_views == 356 + 110
        @test s.max_views == 356

        ratio, matched = Stats.conditional_ratio(episodes, :is_free => identity)
        @test ratio == 1.0
        @test nrow(matched) == 2

        empty_df = DataFrame(is_free = Bool[])
        ratio0, matched0 = Stats.conditional_ratio(empty_df, :is_free => identity)
        @test ratio0 == 0.0
        @test nrow(matched0) == 0
    end

    @testset "Charts" begin
        html = Charts.barchart([1, 2], [356, 110]; title = "views")
        @test html isa Base.HTML
        @test occursin("<svg", html.content)

        empty_html = Charts.barchart(Int[], Int[])
        @test empty_html isa Base.HTML

        mktempdir() do dir
            outfile = joinpath(dir, "chart.svg")
            Charts.barchart([1, 2], [356, 110]; outfile = outfile)
            @test isfile(outfile)
        end
    end
end

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(NovelpiaAnalysis; ambiguities = false)
end
