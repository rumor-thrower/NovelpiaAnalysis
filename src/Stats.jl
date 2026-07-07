"""
    Stats

Summary statistics and conditional-ratio helpers over episode/review DataFrames.
"""
module Stats

using DataFrames, Statistics

export summary,
    conditional_ratio, chapter_decline_slopes, chapter_length_decline_correlation

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
    xs = float.(x[keep])
    ys = float.(y[keep])
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

end # module Stats
