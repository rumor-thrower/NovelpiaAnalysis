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
        @test iszero(manifest.review_count)
        @test manifest.files == ["episodes.csv", "reviews.csv"]

        episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
        @test nrow(episodes) == manifest.episode_count
        @test eltype(episodes.episode_no) == Int
        @test eltype(episodes.is_free) == Bool
        @test first(episodes.reg_date) == Date(2023, 3, 23)
        @test episodes.count_view == [356, 110]

        reviews = Load.read_reviews(FIXTURES, NOVEL_NO)
        @test isempty(reviews)

        data = Load.load(FIXTURES, NOVEL_NO)
        @test data.manifest.novel_no == NOVEL_NO
        @test nrow(data.episodes) == 2
        @test isempty(data.reviews)
    end

    @testset "Load deleted novel (empty episodes.csv)" begin
        # A novel removed from Novelpia (episode_count == 0) writes a
        # completely empty episodes.csv with no header row. read_episodes
        # normalizes this to the same typed-but-empty schema as a populated
        # file, so downstream Frames functions (sort! on :episode_no etc.)
        # don't need to special-case a columnless frame.
        manifest = Load.read_manifest(FIXTURES, 2)
        @test iszero(manifest.episode_count)

        episodes = Load.read_episodes(FIXTURES, 2)
        @test isempty(episodes)
        @test Set(names(episodes)) ==
              Set(["count_view", "episode_no", "is_adult", "is_free", "reg_date", "title"])
        @test eltype(episodes.episode_no) == Int
        @test eltype(episodes.is_free) == Bool

        Frames.add_retention!(episodes)
        Frames.add_cumulative_views!(episodes)
        Frames.add_view_diff!(episodes)
        Frames.add_chapters!(episodes)
        Frames.add_chapter_length!(episodes)
        @test isempty(episodes)

        data = Load.load(FIXTURES, 2)
        @test isempty(data.episodes)
        @test isempty(data.reviews)
    end

    @testset "Frames" begin
        episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
        Frames.add_retention!(episodes)
        @test episodes.retention == episodes.count_view ./ first(episodes.count_view)
        @test isone(first(episodes.retention))

        Frames.add_cumulative_views!(episodes)
        @test episodes.cumulative_views == cumsum(episodes.count_view)

        Frames.add_view_diff!(episodes)
        @test ismissing(first(episodes.view_diff))
        @test episodes.view_diff[2:end] == diff(episodes.count_view)

        rising = Frames.rising_episodes(episodes)
        @test nrow(rising) == count(>(0), skipmissing(episodes.view_diff))
        @test all(rising.view_diff .> 0)
    end

    @testset "Frames.add_chapters!" begin
        # chapter_base strips trailing part markers (ASCII/full-width parens, `- N`,
        # `#N`, and spacing variants) but keeps leading chapter numbering and bare titles.
        chapter_base = Frames.chapter_base
        @test chapter_base("각성(1)") == "각성"
        @test chapter_base("각성 (3)") == "각성"
        @test chapter_base("각성（2）") == "각성"
        @test chapter_base("수련 - 2") == "수련"
        @test chapter_base("수련 -3") == "수련"
        @test chapter_base("결전 #1") == "결전"
        @test chapter_base("여담") == "여담"
        @test chapter_base("3. 다시 몬드(1)") == "3. 다시 몬드"  # leading number kept
        @test chapter_base("#04_보더 타운(3)") == "#04_보더 타운"
        @test ismissing(chapter_base(missing))

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

        # A missing title never merges with either neighbour.
        m = DataFrame(episode_no = 1:3, title = ["A", missing, "A"])
        Frames.add_chapters!(m)
        @test m.chapter_no == [1, 2, 3]
        @test ismissing(m.chapter_title[2])

        # Empty frame gets empty columns rather than erroring.
        e = DataFrame(episode_no = Int[], title = String[])
        Frames.add_chapters!(e)
        @test isempty(e)
        @test hasproperty(e, :chapter_no) && hasproperty(e, :chapter_title)
    end

    @testset "Frames.chapter_base_no_serial" begin
        # Strips a leading global episode serial ("012. ") before delegating to
        # chapter_base, so same-chapter episodes numbered per-episode (not
        # per-chapter) collapse to the same base.
        base_no_serial = Frames.chapter_base_no_serial
        @test base_no_serial("012. 뱀파이어 형사") == "뱀파이어 형사"
        @test base_no_serial("013. 뱀파이어 형사") == "뱀파이어 형사"
        @test base_no_serial("001. 능력 각성") == "능력 각성"
        # Still strips trailing part markers same as chapter_base.
        @test base_no_serial("012. 각성(1)") == "각성"
        # A bare chapter-numbering prefix (no global serial) is also consumed —
        # this is the intended behavioural difference from chapter_base, which
        # keeps it. Callers pick whichever base_fn matches their novel's titling.
        @test base_no_serial("3. 다시 몬드(1)") == "다시 몬드"
        @test ismissing(base_no_serial(missing))

        # Regression: a novel titled with a leading global episode serial (e.g.
        # "012. 뱀파이어 형사", "013. 뱀파이어 형사" — the number increments every
        # episode, not every chapter). With the default chapter_base, the serial
        # makes every episode look like a new chapter; chapter_base_no_serial
        # strips it first so same-chapter episodes collapse together.
        episodes = DataFrame(
            episode_no = 1:5,
            title = [
                "001. 능력 각성",
                "002. 뱀파이어 형사",
                "003. 뱀파이어 형사",
                "004. 뱀파이어 형사",
                "005. 영천류",
            ],
        )
        Frames.add_chapters!(episodes; base_fn = Frames.chapter_base_no_serial)
        @test episodes.chapter_no == [1, 2, 2, 2, 3]
        @test episodes.chapter_title ==
              ["능력 각성", "뱀파이어 형사", "뱀파이어 형사", "뱀파이어 형사", "영천류"]

        # Without stripping the serial, the same data falls into one chapter per
        # episode (the bug this was written to fix).
        default_grouped = DataFrame(episode_no = 1:5, title = episodes.title)
        Frames.add_chapters!(default_grouped)
        @test default_grouped.chapter_no == [1, 2, 3, 4, 5]
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
        @test isempty(e)
        @test hasproperty(e, :chapter_length)
    end

    @testset "Stats" begin
        episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
        s = Stats.summary(episodes)
        @test s.episode_count == 2
        @test s.free_count == 2
        @test iszero(s.paid_count)
        @test s.total_views == 356 + 110
        @test s.max_views == 356

        @test s.median_views == (356 + 110) / 2
        @test s.first_last_retention == 110 / 356

        # `summary` reports every view aggregate as `missing` when no `count_view`
        # survives, whether the frame is empty or merely all-`missing`. The latter
        # is why the empty-`views` guard cannot be an `isempty(episodes)` check.
        views_summary(vs, free = trues(length(vs))) = Stats.summary(
            DataFrame(count_view = Union{Int,Missing}[vs...], is_free = collect(free)),
        )

        no_episodes = views_summary(())
        all_missing_views = views_summary((missing, missing), (true, false))

        for empty_case in (no_episodes, all_missing_views)
            @test ismissing(empty_case.total_views)
            @test ismissing(empty_case.median_views)
            @test ismissing(empty_case.max_views)
            @test ismissing(empty_case.first_last_retention)
        end
        @test iszero(no_episodes.episode_count)
        @test all_missing_views.episode_count == 2
        @test isone(all_missing_views.paid_count)

        # Retention alone is undefined when an endpoint is `missing` or the first
        # view is zero; the aggregates over the surviving views stay well-defined.
        zero_first = views_summary((0, 50))
        @test ismissing(zero_first.first_last_retention)
        @test zero_first.total_views == 50

        missing_first = views_summary((missing, 50))
        @test ismissing(missing_first.first_last_retention)
        @test missing_first.total_views == 50
        @test missing_first.max_views == 50

        # A zero ratio is ambiguous on its own: `total` is what separates "no rows
        # to match" (undefined) from "rows existed, none matched" (a real zero).
        for (df, expected_ratio, expected_matched, expected_total) in (
            (episodes, 1, 2, 2),
            (DataFrame(is_free = Bool[]), 0, 0, 0),
            (DataFrame(is_free = [false, false, false]), 0, 0, 3),
        )
            ratio, matched, total = Stats.conditional_ratio(df, :is_free => identity)
            @test ratio == expected_ratio
            @test nrow(matched) == expected_matched
            @test total == expected_total
        end
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

        # A constant slope across chapters of varying length has zero variance,
        # so the correlation is undefined: `missing`, not `cor`'s NaN.
        # ch1 (length 2): 100 -> 90, ch2 (length 3): 50 -> 40 -> 30 (both slope -10)
        flat = DataFrame(
            episode_no = 1:5,
            chapter_no = [1, 1, 2, 2, 2],
            count_view = [100, 90, 50, 40, 30],
        )
        Frames.add_chapter_length!(flat)
        cor_flat, _ = Stats.chapter_length_decline_correlation(flat)
        @test ismissing(cor_flat)
        flat_lev = Stats.chapter_length_decline_leverage(
            Stats.chapter_decline_slopes(flat);
            long_chapter_cutoff = 5,
        )
        @test ismissing(flat_lev.pearson)
        @test ismissing(flat_lev.spearman)
        @test flat_lev.scored_n == 2
    end

    @testset "Stats.spearman_cor" begin
        # Perfectly monotone (but nonlinear) x/y -> Spearman is exactly ±1 while
        # Pearson is not, which is the whole point of the rank correlation.
        x = [1, 2, 3, 4, 5]
        y = [1, 4, 9, 16, 25]  # strictly increasing, convex
        @test Stats.spearman_cor(x, y) ≈ 1.0
        @test Stats.spearman_cor(x, reverse(y)) ≈ -1.0
        # Robustness: an extreme x-outlier that preserves the rank order leaves
        # Spearman at exactly 1.0, where Pearson would be dragged toward it.
        xo = [1, 2, 3, 4, 100]
        yo = [1, 2, 3, 4, 5]
        @test Stats.spearman_cor(xo, yo) ≈ 1.0
        # Too few pairs for a correlation to vary: `cor` would throw on the empty
        # sample and return NaN on the single pair, so both report `missing`.
        @test ismissing(Stats.spearman_cor(Int[], Int[]))
        @test ismissing(Stats.spearman_cor([1], [1]))
        # Two pairs are enough, even all-tied ones: ranking breaks ties by
        # position, so the ranks vary and the correlation is defined.
        @test Stats.spearman_cor([7, 7], [7, 7]) ≈ 1.0
    end

    @testset "Stats.chapter_length_decline_leverage" begin
        # Reuse the clean -1.0 correlation novel from above (ch lengths 2,3,4,
        # slopes -10,-20,-30) and add one very long side-story chapter whose slope
        # bucks the trend, to exercise the drop-long path.
        df = DataFrame(
            episode_no = 1:15,
            chapter_no = [1, 1, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4],
            count_view = [
                100,
                90,
                100,
                80,
                60,
                100,
                70,
                40,
                10,
                # ch4: length 6, but a gently *rising* trend (positive slope)
                10,
                20,
                30,
                40,
                50,
                60,
            ],
        )
        Frames.add_chapter_length!(df)
        chapters = Stats.chapter_decline_slopes(df)

        # Default: all 4 usable chapters scored; one is "long" (> cutoff 5).
        full = Stats.chapter_length_decline_leverage(chapters; long_chapter_cutoff = 5)
        @test full.usable_n == 4
        @test isone(full.long_n)
        @test full.scored_n == 4
        # The long, positively-sloped chapter pulls the correlation off -1.0.
        @test full.pearson > -1.0

        # Dropping the long chapter restores the clean -1.0 (lengths 2,3,4 only).
        dropped = Stats.chapter_length_decline_leverage(
            chapters;
            long_chapter_cutoff = 5,
            drop_long_chapters = true,
        )
        @test dropped.scored_n == 3
        @test isone(dropped.long_n)
        @test dropped.pearson ≈ -1.0
        @test dropped.spearman ≈ -1.0

        # Fewer than two scored chapters -> missing, not an error.
        one = subset(chapters, :chapter_length => l -> l .== 2)
        lev = Stats.chapter_length_decline_leverage(one; long_chapter_cutoff = 5)
        @test ismissing(lev.pearson)
        @test ismissing(lev.spearman)
        @test isone(lev.scored_n)
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

        color_a, color_b = "#4e79a7", "#f28e2b"
        legend_html = Charts.barchart(
            ["a", "b"],
            [1, 2];
            colors = [color_a, color_b],
            legend = [("A", color_a), ("B", color_b)],
        )
        in_legend = occursin(legend_html.content)
        @test in_legend("translate(")
        @test in_legend(">A</text>")
        @test in_legend(">B</text>")
    end

    @testset "Charts x-axis label containment" begin
        # Regression: `rotate_labels = true` anchored every label at a fixed
        # `y = H - 38` in a fixed-height SVG and leaned on `overflow:visible` to
        # paint the overhang. Rotated -45° from an `end` anchor a label runs down
        # and to the left, so long labels (and the first bar's, always) painted
        # outside the viewport and got clipped by the notebook's cell box.
        # Labels now size the SVG, so their boxes must land inside it.

        # Widths come from the renderer's own em model. What's under test is the
        # padding arithmetic around it, which `corners` re-derives from the SVG.
        widest = Charts._line_px

        # Every x-axis <text>: anchor, rotation, and its stacked tspan lines.
        function axis_labels(svg)
            re =
                r"<text x=\"(-?\d+)\" y=\"(-?\d+)\" text-anchor=\"(\w+)\" font-size=\"(\d+)\" ?(transform=\"rotate\(-45[^\"]*\")?>((?:<tspan.*?</tspan>)+)</text>"
            [
                (
                    x = parse(Int, m[1]),
                    y = parse(Int, m[2]),
                    anchor = m[3],
                    fs = parse(Int, m[4]),
                    rotated = m[5] !== nothing,
                    lines = [t[1] for t in eachmatch(r"<tspan[^>]*>(.*?)</tspan>", m[6])],
                ) for m in eachmatch(re, svg)
            ]
        end

        # Corners of a label's text block in user space, after any rotation.
        function corners(l)
            w = widest(join(l.lines, '\n'), l.fs)
            x1 = l.anchor == "end" ? l.x - w : l.anchor == "middle" ? l.x - w / 2 : l.x
            top, bot = l.y - l.fs, l.y + length(l.lines) * (l.fs + 3)
            pts = [(x1, top), (x1 + w, top), (x1, bot), (x1 + w, bot)]
            l.rotated || return pts
            c, s = cospi(-0.25), sinpi(-0.25)  # rotate(-45) about the anchor
            [
                (
                    l.x + (px - l.x) * c - (py - l.y) * s,
                    l.y + (px - l.x) * s + (py - l.y) * c,
                ) for (px, py) in pts
            ]
        end

        function viewport(svg)
            m = match(r"<svg[^>]*width=\"(\d+)\" height=\"(\d+)\"", svg)
            parse(Int, m[1]), parse(Int, m[2])
        end

        function contained(svg)
            W, H = viewport(svg)
            labels = axis_labels(svg)
            @test !isempty(labels)  # a regex that matches nothing proves nothing
            all(
                -0.5 <= px <= W + 0.5 && -0.5 <= py <= H + 0.5 for l in labels for
                (px, py) in corners(l)
            )
        end
        bc(args...; kwargs...) = Charts.barchart(args...; kwargs...).content
        contained_barchart(args...; kwargs...) = contained(bc(args...; kwargs...))

        group = ["완결\n중앙값", "완결\n기하평균", "연재\n중앙값", "연재\n기하평균"]
        long_tag = ["현대판타지 로맨스 대하소설\n(n=1234)", "회귀\n(n=88)", "TS\n(n=9)"]
        gvals = [1200.0, 800.0, 950.0, 600.0]

        # The two shapes that actually broke: multi-line CJK labels, rotated.
        @test contained_barchart(group, gvals; rotate_labels = true)
        @test contained_barchart(
            long_tag,
            [3.1, 2.0, 1.4];
            rotate_labels = true,
            bold_values = true,
        )
        # …and the shapes that already worked, which must keep working.
        @test contained_barchart(string.(1:12), float.(1:12); rotate_labels = true)
        @test contained_barchart(group, gvals)
        @test contained_barchart(["a", "b"], [1.0, 2.0])
        @test contained_barchart(["x\ny", "z"], [-5.0, missing]; rotate_labels = true)
        @test contained_barchart(
            ["긴이름하나", "b"],
            [1.0, 2.0];
            width = 400,
            legend = [("중앙값", "#111")],
        )

        # A rotated chart reserves room below `height` and left of the bars,
        # rather than drawing labels over the bars or off-canvas.
        long_tag_at_280(; kwargs...) =
            bc(long_tag, [3.1, 2.0, 1.4]; height = 280, kwargs...)
        plain = long_tag_at_280()
        rot = long_tag_at_280(; rotate_labels = true)
        @test last(viewport(rot)) > last(viewport(plain)) > 280
        @test first(viewport(rot)) > first(viewport(plain))

        single_bar(label) = bc([label], [1.0])

        # `\n` becomes stacked <tspan> lines, not a literal newline in one run.
        two_line = single_bar("완결\n중앙값")
        @test occursin(">완결</tspan>", two_line)
        @test occursin(">중앙값</tspan>", two_line)
        @test !occursin("완결\n중앙값", two_line)

        # Each line is escaped exactly once (the bar loop no longer pre-escapes).
        esc = single_bar("a & b<c")
        @test occursin(">a &amp; b&lt;c</tspan>", esc)
        @test !occursin("&amp;amp;", esc)
    end
end

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(NovelpiaAnalysis; ambiguities = false)
end
