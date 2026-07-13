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
    chapter_length_decline_leverage,
    usable_chapters

"""
    _view_aggregates(episodes, views) -> NamedTuple

Aggregate the view columns of `summary`: total/median/max over `views` (the
non-`missing` `count_view` values), plus first-to-last retention read off the
raw `episodes.count_view`.

All four fields are `missing` when `views` is empty — no `count_view` survived,
so no aggregate is defined. Retention is additionally `missing` when either
endpoint is `missing` or the first view is zero (an undefined ratio), even
though the aggregates over the surviving views remain well-defined.
"""
function _view_aggregates(episodes, views)
    isempty(views) && return (
        total_views = missing,
        median_views = missing,
        max_views = missing,
        first_last_retention = missing,
    )
    first_view = first(episodes.count_view)
    last_view = last(episodes.count_view)
    retention =
        (ismissing(first_view) || ismissing(last_view) || iszero(first_view)) ? missing :
        last_view / first_view
    (
        total_views = sum(views),
        median_views = median(views),
        max_views = maximum(views),
        first_last_retention = retention,
    )
end

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
    (
        episode_count = n,
        free_count = free_count,
        paid_count = n - free_count,
        _view_aggregates(episodes, views)...,
    )
end

"""
    conditional_ratio(df, condition) -> NamedTuple

Fraction of rows in `df` matching `condition` (a column-selector pair or vector
of pairs, as accepted by `DataFrames.subset`), alongside the matching subframe
and the row count the ratio was taken over.

Returns `(; ratio, matched, total)`. An empty `df` yields a `ratio` of `0.0`
rather than dividing by zero. That `0.0` is indistinguishable from a genuine
"none of the rows matched", so callers that need to tell "0% of nothing"
(undefined) from "0% of `n`" (a real zero) must branch on `total`, not on the
ratio.
"""
function conditional_ratio(df, condition)
    conditions = condition isa Pair ? [condition] : condition
    matched = subset(df, conditions...)
    total = nrow(df)
    ratio = iszero(total) ? 0.0 : nrow(matched) / total
    (; ratio, matched, total)
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
    # cov/var share the same 1/(n-1) correction, which cancels in the ratio, so
    # this is the plain normal-equation slope Σ(x-x̄)(y-ȳ) / Σ(x-x̄)².
    denom = var(xs)
    iszero(denom) ? missing : cov(xs, ys) / denom
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
    usable_chapters(chapters) -> DataFrame

Chapters whose `slope` is defined — the subset the correlations are scored over.
"""
usable_chapters(chapters) = subset(chapters, :slope => ByRow(!ismissing))

"""
    _correlation_undefined(chapters) -> Bool

Whether a length-vs-slope correlation is undefined over `chapters`: fewer than two
chapters to correlate, or zero variance in `chapter_length` or `slope` (either
constant makes Pearson's denominator zero, so `cor` would return `NaN` rather
than a correlation).
"""
_correlation_undefined(chapters) =
    nrow(chapters) < 2 ||
    iszero(var(chapters.chapter_length)) ||
    iszero(var(chapters.slope))

"""
    chapter_length_decline_correlation(df) -> NamedTuple

Pearson correlation (via `Statistics.cor`) between `chapter_length` and the
within-chapter view-decline `slope` across chapters (see
[`chapter_decline_slopes`](@ref)), alongside the per-chapter DataFrame used to
compute it.

Returns `(; pearson, chapters)`. Chapters with a `missing` slope are excluded
from the correlation first (but are still present in `chapters`). `pearson` is
`missing` if fewer than two chapters remain, or if `chapter_length` or `slope`
is constant across all remaining chapters.

A negative correlation supports the hypothesis that longer chapters
(episode 장편화) accelerate view-count decline.
"""
function chapter_length_decline_correlation(df)
    chapters = chapter_decline_slopes(df)
    usable = usable_chapters(chapters)
    pearson =
        _correlation_undefined(usable) ? missing : cor(usable.chapter_length, usable.slope)
    (; pearson, chapters)
end

"""
    spearman_cor(x, y) -> Union{Float64,Missing}

Spearman rank correlation: Pearson's [`Statistics.cor`](@ref) applied to the
ranks of `x` and `y`. Ranks come from `sortperm(sortperm(·))`, which breaks ties
by original position rather than averaging them (`competerank`-style average
ranks aren't needed for a robustness cross-check, and this avoids a `StatsBase`
dependency).

Being rank-based, it is far less sensitive than Pearson to a handful of extreme
values, so a large Pearson/Spearman gap is itself the tell that the Pearson value
is outlier-driven.

A rank correlation needs at least two pairs to vary, so fewer than two is
`missing`: `cor` would throw on an empty sample and return `NaN` for a single
pair. Two or more pairs always have a defined correlation, because ranking by
`sortperm(sortperm(·))` breaks ties by position and so always yields a
permutation of `1:n`, never a constant vector.
"""
function spearman_cor(x, y)
    rank(v) = sortperm(sortperm(collect(v)))
    length(x) < 2 && return missing
    cor(rank(x), rank(y))
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
`chapter_length` or `slope` is constant (undefined correlation — a rank
correlation over a constant `slope` would only echo the positional
tie-breaking of [`spearman_cor`](@ref), not a real trend).
"""
function chapter_length_decline_leverage(
    chapters;
    long_chapter_cutoff,
    drop_long_chapters = false,
)
    usable = usable_chapters(chapters)
    is_long = usable.chapter_length .> long_chapter_cutoff
    scored_rows = drop_long_chapters ? .!is_long : Colon()
    scored = view(usable, scored_rows, :)
    undefined = _correlation_undefined(scored)
    (
        pearson = undefined ? missing : cor(scored.chapter_length, scored.slope),
        spearman = undefined ? missing : spearman_cor(scored.chapter_length, scored.slope),
        usable_n = nrow(usable),
        long_n = count(is_long),
        scored_n = nrow(scored),
    )
end

end # module Stats
