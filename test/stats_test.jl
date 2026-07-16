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
    last_views = 50

    zero_first = views_summary((0, last_views))
    @test ismissing(zero_first.first_last_retention)
    @test zero_first.total_views == last_views

    missing_first = views_summary((missing, last_views))
    @test ismissing(missing_first.first_last_retention)
    @test missing_first.total_views == last_views
    @test missing_first.max_views == last_views

    # A zero ratio is ambiguous on its own: `total` is what separates "no rows
    # to match" (undefined) from "rows existed, none matched" (a real zero).
    for (df, expected_ratio, expected_matched, expected_total) in (
        (episodes, 1, 2, 2),
        (DataFrame(is_free = Bool[]), 0, 0, 0),
        (DataFrame(is_free = falses(3)), 0, 0, 3),
    )
        (; ratio, matched, total) = Stats.conditional_ratio(df, :is_free => identity)
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
        chapter_no = vcat(fill(1, 2), fill(2, 3), fill(3, 4)),
        count_view = [100, 90, 100, 80, 60, 100, 70, 40, 10],
    )
    Frames.add_chapter_length!(df)
    @test df.chapter_length == vcat(fill(2, 2), fill(3, 3), fill(4, 4))

    chapter_length_decline_correlation = Stats.chapter_length_decline_correlation

    chapters = Stats.chapter_decline_slopes(df)
    @test nrow(chapters) == 3
    @test sort(chapters.chapter_length) == [2, 3, 4]
    by_length = Dict(r.chapter_length => r.slope for r in eachrow(chapters))
    @test by_length[2] ≈ -10
    @test by_length[3] ≈ -20
    @test by_length[4] ≈ -30

    corr = chapter_length_decline_correlation(df)
    @test corr.chapters == chapters
    @test corr.pearson ≈ -1.0  # longer chapters decline strictly faster here

    # A single-episode chapter yields a missing slope and is excluded from
    # the correlation, rather than erroring.
    single = DataFrame(episode_no = [1], chapter_no = [1], count_view = [50])
    Frames.add_chapter_length!(single)
    single_chapters = Stats.chapter_decline_slopes(single)
    @test ismissing(only(single_chapters.slope))
    @test ismissing(chapter_length_decline_correlation(single).pearson)

    # A constant slope across chapters of varying length has zero variance,
    # so the correlation is undefined: `missing`, not `cor`'s NaN.
    # ch1 (length 2): 100 -> 90, ch2 (length 3): 50 -> 40 -> 30 (both slope -10)
    flat = DataFrame(
        episode_no = 1:5,
        chapter_no = vcat(fill(1, 2), fill(2, 3)),
        count_view = [100, 90, 50, 40, 30],
    )
    Frames.add_chapter_length!(flat)
    @test ismissing(chapter_length_decline_correlation(flat).pearson)
    flat_lev = Stats.chapter_length_decline_leverage(
        Stats.chapter_decline_slopes(flat);
        long_chapter_cutoff = 5,
    )
    @test ismissing(flat_lev.pearson)
    @test ismissing(flat_lev.spearman)
    @test flat_lev.scored_n == 2
end

@testset "Stats.spearman_cor" begin
    spearman_cor = Stats.spearman_cor
    # Perfectly monotone (but nonlinear) x/y -> Spearman is exactly ±1 while
    # Pearson is not, which is the whole point of the rank correlation.
    x = 1:5
    y = (1:5) .^ 2  # strictly increasing, convex
    @test spearman_cor(x, y) ≈ 1.0
    @test spearman_cor(x, reverse(y)) ≈ -1.0
    # Robustness: an extreme x-outlier that preserves the rank order leaves
    # Spearman at exactly 1.0, where Pearson would be dragged toward it.
    xo = [(1:4)..., 100]
    yo = 1:5
    @test spearman_cor(xo, yo) ≈ 1.0
    # Too few pairs for a correlation to vary: `cor` would throw on the empty
    # sample and return NaN on the single pair, so both report `missing`.
    @test ismissing(spearman_cor(Int[], Int[]))
    @test ismissing(spearman_cor([1], [1]))
    # Two pairs are enough, even all-tied ones: ranking breaks ties by
    # position, so the ranks vary and the correlation is defined.
    @test spearman_cor([7, 7], [7, 7]) ≈ 1.0
end

@testset "Stats.chapter_length_decline_leverage" begin
    # Reuse the clean -1.0 correlation novel from above (ch lengths 2,3,4,
    # slopes -10,-20,-30) and add one very long side-story chapter whose slope
    # bucks the trend, to exercise the drop-long path.
    df = DataFrame(
        episode_no = 1:15,
        chapter_no = vcat(fill(1, 2), fill(2, 3), fill(3, 4), fill(4, 6)),
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
            (10:10:60)...,
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
    one = subset(chapters, :chapter_length => ByRow(==(2)))
    lev = Stats.chapter_length_decline_leverage(one; long_chapter_cutoff = 5)
    @test ismissing(lev.pearson)
    @test ismissing(lev.spearman)
    @test isone(lev.scored_n)
end
