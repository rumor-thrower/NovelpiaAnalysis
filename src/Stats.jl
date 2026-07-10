"""
    Stats

Summary statistics and conditional-ratio helpers over episode/review DataFrames.
"""
module Stats

using DataFrames, Statistics

export summary,
    conditional_ratio,
    chapter_decline_slopes,
    chapter_length_decline_correlation,
    spearman_cor,
    chapter_length_decline_leverage

"""
    summary(episodes) -> NamedTuple

Summary statistics over an episode DataFrame: episode count, free/paid split,
total/median/max views, and first-to-last retention (last `count_view` divided
by the first, `missing` if either is unavailable).
"""
function summary(episodes)
    views = skipmissing(episodes.count_view) |> collect
    n = nrow(episodes)
    free_count = count(episodes.is_free)
    first_last_retention = if isempty(views) || nrow(episodes) == 0
        missing
    else
        first_view = episodes.count_view[1]
        last_view = episodes.count_view[end]
        (ismissing(first_view) || ismissing(last_view) || iszero(first_view)) ?
        missing : last_view / first_view
    end
    (
        episode_count = n,
        free_count = free_count,
        paid_count = n - free_count,
        total_views = isempty(views) ? missing : sum(views),
        median_views = isempty(views) ? missing : median(views),
        max_views = isempty(views) ? missing : maximum(views),
        first_last_retention = first_last_retention,
    )
end

"""
    conditional_ratio(df, condition) -> Tuple{Float64, DataFrame}

Fraction of rows in `df` matching `condition` (a column-selector pair or vector
of pairs, as accepted by `DataFrames.subset`), alongside the matching subframe.
Returns `(0.0, empty_subframe)` for an empty `df` rather than dividing by zero.
"""
function conditional_ratio(df, condition)
    conditions = condition isa Pair ? [condition] : condition
    matched = subset(df, conditions...)
    total = nrow(df)
    ratio = iszero(total) ? 0.0 : nrow(matched) / total
    (ratio, matched)
end

"""
    _ols_slope(x, y) -> Union{Missing, Float64}

Ordinary-least-squares slope of `y` on `x`. `missing` if fewer than two points
remain after dropping any pair with a `missing` value, or if `x` is constant
(zero variance, undefined slope).
"""
function _ols_slope(x, y)
    keep = .!ismissing.(x) .& .!ismissing.(y)
    # `keep` masks out every `missing` in both inputs, so the survivors carry none;
    # `disallowmissing` narrows the element type to match, which keeps the OLS
    # arithmetic below type-stable (a lingering `Missing` in the element type would
    # otherwise widen `ybar` and the returned slope to `Any`).
    xs = Float64.(disallowmissing(x[keep]))
    ys = Float64.(disallowmissing(y[keep]))
    length(xs) < 2 && return missing
    xbar = mean(xs)
    ybar = mean(ys)
    denom = sum((xs .- xbar) .^ 2)
    iszero(denom) ? missing : sum((xs .- xbar) .* (ys .- ybar)) / denom
end

"""
    chapter_decline_slopes(df) -> DataFrame

One row per chapter (requires `chapter_no`, `chapter_length`, and `count_view`
columns — see [`Frames.add_chapters!`](@ref) and
[`Frames.add_chapter_length!`](@ref)), with columns `chapter_no`,
`chapter_length`, and `slope`: the OLS slope of `count_view` against
within-chapter episode position (1, 2, 3, …).

`slope` is `missing` for chapters with fewer than two episodes, or fewer than
two non-missing `count_view` values (no trend is definable). A negative slope
means views declined episode-over-episode within that chapter.
"""
function chapter_decline_slopes(df)
    combine(
        groupby(df, [:chapter_no, :chapter_length]),
        :count_view => (v -> _ols_slope(1:length(v), v)) => :slope,
    )
end

"""
    chapter_length_decline_correlation(df) -> Tuple{Union{Missing, Float64}, DataFrame}

Pearson correlation (via `Statistics.cor`) between `chapter_length` and the
within-chapter view-decline `slope` across chapters (see
[`chapter_decline_slopes`](@ref)), alongside the per-chapter DataFrame used to
compute it. Chapters with a `missing` slope are excluded first. `missing` is
returned instead of a correlation if fewer than two chapters remain, or if
`chapter_length` is constant across all remaining chapters.

A negative correlation supports the hypothesis that longer chapters
(episode 장편화) accelerate view-count decline.
"""
function chapter_length_decline_correlation(df)
    chapters = chapter_decline_slopes(df)
    usable = subset(chapters, :slope => x -> .!ismissing.(x))
    correlation =
        (nrow(usable) < 2 || iszero(var(usable.chapter_length))) ? missing :
        cor(float.(usable.chapter_length), float.(usable.slope))
    (correlation, chapters)
end

"""
    spearman_cor(x, y) -> Float64

Spearman rank correlation: Pearson's [`Statistics.cor`](@ref) applied to the
ranks of `x` and `y`. Ranks come from `sortperm(sortperm(·))`, which breaks ties
by original position rather than averaging them (`competerank`-style average
ranks aren't needed for a robustness cross-check, and this avoids a `StatsBase`
dependency).

Being rank-based, it is far less sensitive than Pearson to a handful of extreme
values, so a large Pearson/Spearman gap is itself the tell that the Pearson value
is outlier-driven.
"""
function spearman_cor(x, y)
    rank(v) = sortperm(sortperm(collect(v)))
    cor(float.(rank(x)), float.(rank(y)))
end

"""
    chapter_length_decline_leverage(chapters; long_chapter_cutoff, drop_long_chapters=false)
        -> NamedTuple

Leverage analysis over the per-chapter DataFrame from
[`chapter_length_decline_correlation`](@ref) (or [`chapter_decline_slopes`](@ref)):
recomputes the length-vs-decline correlation on a subset and reports it alongside
a rank correlation and chapter counts, so a few very long (typically
post-completion side-story) chapters can't define the regression line by
themselves.

Chapters with a `missing` slope are dropped first (the `usable` set). `long`
chapters are those longer than `long_chapter_cutoff` episodes. When
`drop_long_chapters` is `true` the correlations are computed over just the
chapters at or below the cutoff; otherwise over the full `usable` set.

Returns `(; pearson, spearman, usable_n, long_n, scored_n)`. `pearson` and
`spearman` are `missing` when fewer than two chapters are scored or their
`chapter_length` is constant (undefined correlation).
"""
function chapter_length_decline_leverage(
    chapters;
    long_chapter_cutoff,
    drop_long_chapters = false,
)
    usable = subset(chapters, :slope => x -> .!ismissing.(x))
    long = subset(usable, :chapter_length => l -> l .> long_chapter_cutoff)
    scored =
        drop_long_chapters ?
        subset(usable, :chapter_length => l -> l .<= long_chapter_cutoff) : usable
    undefined = nrow(scored) < 2 || iszero(var(scored.chapter_length))
    pearson = undefined ? missing : cor(float.(scored.chapter_length), float.(scored.slope))
    spearman = undefined ? missing : spearman_cor(scored.chapter_length, scored.slope)
    (
        pearson = pearson,
        spearman = spearman,
        usable_n = nrow(usable),
        long_n = nrow(long),
        scored_n = nrow(scored),
    )
end

end # module Stats
