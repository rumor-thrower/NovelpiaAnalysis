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
        @test manifest.files == ["episodes.csv", "reviews.csv"]

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

    @testset "Frames.add_chapter_length!" begin
        episodes = Load.read_episodes(FIXTURES, 777)
        Frames.add_chapters!(episodes)
        Frames.add_chapter_length!(episodes)
        # Same chapter sizes as the add_chapters! testset: 1,3,3,2,2,1
        @test episodes.chapter_length == [1, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 1]
        @test episodes.chapter_length[episodes.chapter_no .== 2] == fill(3, 3)

        e = DataFrame(episode_no = Int[], title = String[])
        Frames.add_chapters!(e)
        Frames.add_chapter_length!(e)
        @test nrow(e) == 0
        @test hasproperty(e, :chapter_length)
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

    @testset "Stats.chapter_decline_slopes / chapter_length_decline_correlation" begin
        # Synthetic novel: 3 chapters, each with a perfectly linear within-chapter
        # trend, engineered so the decline rate scales with chapter length --
        # i.e. a clean case of the "episode 장편화 accelerates decline" hypothesis.
        # ch1 (length 2): 100 -> 90            (slope -10)
        # ch2 (length 3): 100 -> 80 -> 60       (slope -20)
        # ch3 (length 4): 100 -> 70 -> 40 -> 10 (slope -30)
        df = DataFrame(
            episode_no = 1:9,
            chapter_no = [1, 1, 2, 2, 2, 3, 3, 3, 3],
            count_view = [100, 90, 100, 80, 60, 100, 70, 40, 10],
        )
        Frames.add_chapter_length!(df)
        @test df.chapter_length == [2, 2, 3, 3, 3, 4, 4, 4, 4]

        chapters = Stats.chapter_decline_slopes(df)
        @test nrow(chapters) == 3
        @test sort(chapters.chapter_length) == [2, 3, 4]
        by_length = Dict(r.chapter_length => r.slope for r in eachrow(chapters))
        @test by_length[2] ≈ -10
        @test by_length[3] ≈ -20
        @test by_length[4] ≈ -30

        cor_val, chapters2 = Stats.chapter_length_decline_correlation(df)
        @test chapters2 == chapters
        @test cor_val ≈ -1.0  # longer chapters decline strictly faster here

        # A single-episode chapter yields a missing slope and is excluded from
        # the correlation, rather than erroring.
        single = DataFrame(episode_no = [1], chapter_no = [1], count_view = [50])
        Frames.add_chapter_length!(single)
        single_chapters = Stats.chapter_decline_slopes(single)
        @test ismissing(only(single_chapters.slope))
        cor_missing, _ = Stats.chapter_length_decline_correlation(single)
        @test ismissing(cor_missing)
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

        # Negative and mixed-sign values must render valid (non-negative height,
        # in-bounds) rects rather than the pre-fix negative-height/off-canvas bug.
        _rect_attrs(svg) = [
            m.captures for m in eachmatch(
                r"<rect x=\"(-?\d+)\" y=\"(-?\d+)\" width=\"(-?\d+)\" height=\"(-?\d+)\"",
                svg,
            )
        ]

        neg_html = Charts.barchart(["a", "b"], [-1.0, -2.0])
        for (x, y, w, h) in _rect_attrs(neg_html.content)
            @test parse(Int, w) > 0
            @test parse(Int, h) >= 0
        end

        mixed_html = Charts.barchart(["a", "b", "c"], [-10.0, 20.0, -5.0])
        rects = _rect_attrs(mixed_html.content)
        @test length(rects) == 3
        for (x, y, w, h) in rects
            @test parse(Int, h) >= 0
        end
        # The positive bar's rect must extend strictly above the baseline shared
        # by the two negative bars' (equal) top y-coordinates.
        ys = [parse(Int, r[2]) for r in rects]
        @test ys[2] < ys[1] == ys[3]
    end
end

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(NovelpiaAnalysis; ambiguities = false)
end
