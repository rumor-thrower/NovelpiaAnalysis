"""
    Frames

Derived columns computed over the episode DataFrame returned by `Load.read_episodes`.
"""
module Frames

using DataFrames

export add_retention!, add_cumulative_views!, add_view_diff!, rising_episodes,
    add_chapters!, chapter_base

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

# Trailing "part-of-chapter" markers observed across a survey of Novelpia titles.
# A chapter (단원) is authored as several consecutive episodes sharing a base title,
# with the within-chapter position appended in one of these shapes (each allowing
# surrounding whitespace, and parens either ASCII or full-width):
#   (2)  （2）  " (2)"  "- 2"  "-2"  "#2"
# Leading numbering that identifies the chapter itself — "3화", "2.", "#04_", "S1." —
# is intentionally NOT stripped: it is part of the base title and is exactly what
# separates one chapter from the next.
const _PART_MARKER = r"\s*(?:[\(（]\s*\d+\s*[\)）]|[-#]\s*\d+)\s*$"

"""
    chapter_base(title) -> String

The chapter-grouping key for an episode `title`: the title with any trailing
within-chapter part marker (`(2)`, `- 2`, `#2`, and full-width/spacing variants)
removed and surrounding whitespace trimmed. Titles carrying no marker — including
bare titles repeated verbatim across a chapter — are returned trimmed but otherwise
unchanged. `missing` passes through.
"""
chapter_base(::Missing) = missing
chapter_base(title::AbstractString) = strip(replace(title, _PART_MARKER => ""))

"""
    add_chapters!(df) -> df

Groups episodes into chapters (단원) and adds two columns, ordered by `episode_no`:

- `chapter_no::Int` — 1-based chapter index; equal for every episode in a chapter.
- `chapter_title::String` — the chapter's base title (see [`chapter_base`](@ref)).

Episodes are grouped into maximal *consecutive* runs sharing the same
[`chapter_base`](@ref): the run breaks whenever the base title changes, so a base
title that reappears later (after an intervening chapter) starts a fresh chapter
rather than merging non-adjacent episodes. A `missing` title forms a base of its
own and never merges with a neighbour. An empty frame gets empty columns.
"""
function add_chapters!(df)
    sort!(df, :episode_no)
    n = nrow(df)
    chapter_no = Vector{Int}(undef, n)
    chapter_title = Vector{Union{Missing,String}}(undef, n)
    prev_base = nothing
    current = 0
    for i in 1:n
        base = chapter_base(df.title[i])
        # A new run starts on the first row, on any change of base title, and around
        # every `missing` (which is never equal to anything, itself included).
        if i == 1 || ismissing(base) || ismissing(prev_base) || base != prev_base
            current += 1
        end
        chapter_no[i] = current
        chapter_title[i] = base
        prev_base = base
    end
    df.chapter_no = chapter_no
    df.chapter_title = chapter_title
    df
end

end # module Frames
