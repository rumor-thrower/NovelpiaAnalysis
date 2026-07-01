"""
    Frames

Derived columns computed over the episode DataFrame returned by `Load.read_episodes`.
"""
module Frames

using DataFrames

export add_retention!, add_cumulative_views!

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

end # module Frames
