"""
    Stats

Summary statistics and conditional-ratio helpers over episode/review DataFrames.
"""
module Stats

using DataFrames, Statistics

export summary, conditional_ratio

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

end # module Stats
