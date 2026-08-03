"""
    ViewAggregates

Aggregate view-count statistics for an episode DataFrame: total/median/max
over the non-`missing` `count_view` values, plus first-to-last retention read
off the raw `count_view` column.

All four fields are `missing` when no `count_view` survives (an empty frame or
one where every `count_view` is `missing`). `first_last_retention` is
additionally `missing` when either endpoint is `missing` or the first view is
zero (an undefined ratio), even though the other aggregates remain
well-defined.
"""
struct ViewAggregates
    total_views::Union{Int,Missing}
    median_views::Union{Float64,Missing}
    max_views::Union{Int,Missing}
    first_last_retention::Union{Float64,Missing}
end

"""
    _view_aggregates(episodes, views) -> ViewAggregates

Compute the `ViewAggregates` for `summary`. `views` is the non-`missing`
`count_view` values; `episodes.count_view` (with `missing`s intact) is used
for the first/last retention endpoints.
"""
function _view_aggregates(episodes, views)
    isempty(views) && return ViewAggregates(missing, missing, missing, missing)
    first_view = first(episodes.count_view)
    last_view = last(episodes.count_view)
    retention_undefined =
        ismissing(first_view) || ismissing(last_view) || iszero(first_view)
    retention = retention_undefined ? missing : last_view / first_view
    ViewAggregates(sum(views), median(views), maximum(views), retention)
end

"""
    EpisodeSummary

Summary statistics over an episode DataFrame: episode count, free/paid split,
and view aggregates (see [`ViewAggregates`](@ref)).

View-aggregate fields (`total_views`, `median_views`, `max_views`,
`first_last_retention`) are readable directly off an `EpisodeSummary`, e.g.
`s.total_views`, without going through `s.views`.
"""
struct EpisodeSummary
    episode_count::Int
    free_count::Int
    paid_count::Int
    views::ViewAggregates
end

function Base.getproperty(s::EpisodeSummary, name::Symbol)
    name in fieldnames(EpisodeSummary) && return getfield(s, name)
    getfield(getfield(s, :views), name)
end

"""
    summary(episodes) -> EpisodeSummary

Summary statistics over an episode DataFrame: episode count, free/paid split,
total/median/max views, and first-to-last retention (last `count_view` divided
by the first, `missing` if either is unavailable).
"""
function summary(episodes)
    views = skipmissing(episodes.count_view) |> collect
    n = nrow(episodes)
    free_count = count(episodes.is_free)
    EpisodeSummary(n, free_count, n - free_count, _view_aggregates(episodes, views))
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
