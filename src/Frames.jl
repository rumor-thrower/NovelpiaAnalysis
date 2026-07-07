"""
    Frames

Derived columns computed over the episode DataFrame returned by `Load.read_episodes`.
"""
module Frames

using DataFrames

export add_retention!, add_cumulative_views!, add_view_diff!, rising_episodes

"""
    add_retention!(df) -> df

Adds a `retention` column: each episode's `count_view` divided by episode 1's
`count_view`, ordered by `episode_no`. `missing` propagates through division.
"""
function add_retention!(df)
    sort!(df, :episode_no)
    first_view = isempty(df.count_view) ? missing : first(df.count_view)
    df.retention = df.count_view ./ first_view
    df
end

"""
    add_cumulative_views!(df) -> df

Adds a `cumulative_views` column: the running sum of `count_view` ordered by
`episode_no`. `missing` cells are treated as `0` for accumulation purposes.
"""
function add_cumulative_views!(df)
    sort!(df, :episode_no)
    filled = coalesce.(df.count_view, 0)
    df.cumulative_views = cumsum(filled)
    df
end

"""
    add_view_diff!(df) -> df

Adds a `view_diff` column: the change in `count_view` versus the previous
episode (via `Base.diff`), ordered by `episode_no`. Episode 1 gets `missing`
since it has no predecessor; `missing` cells propagate through the diff.
"""
function add_view_diff!(df)
    sort!(df, :episode_no)
    df.view_diff = isempty(df.count_view) ? Int[] : [missing; diff(df.count_view)]
    df
end

"""
    rising_episodes(df) -> DataFrame

Subframe of episodes whose view count increased over the previous episode
(requires a `view_diff` column, see [`add_view_diff!`](@ref)). Rows with a
`missing` `view_diff` (episode 1, or missing `count_view` data) are excluded.
"""
function rising_episodes(df)
    subset(df, :view_diff => x -> coalesce.(x .> 0, false))
end

end # module Frames
