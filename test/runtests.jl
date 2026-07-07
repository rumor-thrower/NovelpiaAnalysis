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

    @testset "Frames.add_chapters!" begin
        # chapter_base strips trailing part markers (ASCII/full-width parens, `- N`,
        # `#N`, and spacing variants) but keeps leading chapter numbering and bare titles.
        @test Frames.chapter_base("각성(1)") == "각성"
        @test Frames.chapter_base("각성 (3)") == "각성"
        @test Frames.chapter_base("각성（2）") == "각성"
        @test Frames.chapter_base("수련 - 2") == "수련"
        @test Frames.chapter_base("수련 -3") == "수련"
        @test Frames.chapter_base("결전 #1") == "결전"
        @test Frames.chapter_base("여담") == "여담"
        @test Frames.chapter_base("3. 다시 몬드(1)") == "3. 다시 몬드"  # leading number kept
        @test Frames.chapter_base("#04_보더 타운(3)") == "#04_보더 타운"
        @test ismissing(Frames.chapter_base(missing))

        episodes = Load.read_episodes(FIXTURES, 777)
        Frames.add_chapters!(episodes)
        # 6 chapters: 프롤로그 | 각성(×3) | 수련(×3) | 결전(×2) | 여담(×2 bare repeat) |
        # 각성 again (reappearing base is a NEW chapter, not merged with the first).
        @test episodes.chapter_no == [1, 2, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6]
        @test maximum(episodes.chapter_no) == 6
        @test unique(episodes.chapter_title[episodes.chapter_no .== 2]) == ["각성"]
        @test episodes.chapter_title[end] == "각성"          # ch6 base equals ch2 base
        @test episodes.chapter_no[end] == 6                  # but is a distinct chapter
        # chapter_no is constant within a chapter and strictly increases across them.
        @test issorted(episodes.chapter_no)
        @test allunique(unique(episodes.chapter_no))

        # A missing title never merges with either neighbour.
        m = DataFrame(episode_no = 1:3, title = ["A", missing, "A"])
        Frames.add_chapters!(m)
        @test m.chapter_no == [1, 2, 3]
        @test ismissing(m.chapter_title[2])

        # Empty frame gets empty columns rather than erroring.
        e = DataFrame(episode_no = Int[], title = String[])
        Frames.add_chapters!(e)
        @test nrow(e) == 0
        @test hasproperty(e, :chapter_no) && hasproperty(e, :chapter_title)
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
