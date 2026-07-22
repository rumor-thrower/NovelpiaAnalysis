"""
    Frames

Derived columns computed over the episode DataFrame returned by `Load.read_episodes`.
"""
module Frames

using DataFrames

export add_retention!,
    add_cumulative_views!,
    add_view_diff!,
    rising_episodes,
    add_chapters!,
    chapter_base,
    chapter_base_no_serial,
    chapter_base_prefix,
    chapter_base_episode_numbered,
    add_chapter_length!

"""
    add_retention!(df) -> df

Adds a `retention` column: each episode's `count_view` divided by episode 1's
`count_view`, ordered by `episode_no`. Rounded to two decimals, since every
consumer of it is a display. `missing` propagates through division.
"""
function add_retention!(df)
    sort!(df, :episode_no)
    first_view = isempty(df.count_view) ? missing : first(df.count_view)
    df.retention = round.(df.count_view ./ first_view; digits = 2)
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

# A leading *global episode serial*, as opposed to chapter numbering: a run of
# digits followed by ". " (optionally zero-padded, e.g. "001. ", "012. ") at the
# very start of the title. Unlike chapter numbering ("3화", "#04_", "S1."), this
# form increments every episode regardless of chapter, so it must be stripped
# before comparing titles — otherwise every episode looks like a new chapter.
const _SERIAL_PREFIX = r"^\d+\.\s+"

"""
    chapter_base_no_serial(title) -> String

Like [`chapter_base`](@ref), but additionally strips a leading *global episode
serial* — a zero-padded number followed by `". "` (e.g. `"012. "`) — before
computing the base. Use this instead of `chapter_base` for novels whose titles
are numbered by episode rather than by chapter (e.g. `"012. 뱀파이어 형사"`,
`"013. 뱀파이어 형사"`, both reducing to `"뱀파이어 형사"`), where `chapter_base`
alone would treat every episode as its own chapter. `missing` passes through.
"""
chapter_base_no_serial(::Missing) = missing
chapter_base_no_serial(title::AbstractString) =
    chapter_base(replace(title, _SERIAL_PREFIX => ""))

# The delimiter between a leading chapter marker ("1장", "최종장", "천기누설(IF)#1")
# and the per-episode subtitle that follows it, for novels where the subtitle
# changes on every single episode rather than repeating or carrying a trailing
# part marker. Split on the first dash only: subtitles routinely contain their
# own dashes, so a greedy/last-dash split would cut into the subtitle instead.
const _LEADING_PREFIX_DELIM = r"-.*$"

"""
    chapter_base_prefix(title) -> String

Like [`chapter_base`](@ref), but for novels whose titles are a leading chapter
marker followed by a per-episode subtitle that changes every episode (e.g.
`"1장-탈출 성공?!"`, `"1장-점 한번 보고 가시죠"`, both reducing to `"1장"`), where
`chapter_base` alone would treat every episode as its own chapter since the
titles never repeat and carry no trailing part marker. Keeps everything before
the *first* `-` (subtitles may contain their own dashes) and trims surrounding
whitespace; a title with no dash is returned unchanged (trimmed). `missing`
passes through.
"""
chapter_base_prefix(::Missing) = missing
chapter_base_prefix(title::AbstractString) =
    strip(replace(title, _LEADING_PREFIX_DELIM => ""))

# A leading *episode* number (as opposed to a chapter serial like `_SERIAL_PREFIX`):
# a run of digits followed by "화" (optionally " - " or " – ", ASCII or en-dash) at
# the very start of the title, e.g. "1화 - ", "47화 – ". Every episode increments
# this regardless of chapter, so — like `_SERIAL_PREFIX` — it must be stripped
# before comparing titles.
const _EPISODE_NO_PREFIX = r"^\d+화\s*[-–]?\s*"

# Like `_PART_MARKER`, but additionally tolerates a trailing "Fin" marker (and
# minor punctuation around it, e.g. "(5)  Fin", "(11) Fin", "Fin(?)") after the
# digit marker, observed on novels that annotate a chapter's last episode this
# way. Deliberately narrow: a marker followed by anything other than a bare
# "Fin" (any case) is left alone, since that's usually a real trailing subtitle
# fragment rather than an end-of-chapter annotation, and stripping it would risk
# merging episodes that don't actually belong to the same chapter.
const _PART_MARKER_FIN =
    r"\s*(?:[\(（]\s*\d+\s*[\)）]|[-#]\s*\d+)(?:\s*[Ff][Ii][Nn]\s*[)(?]*)?\s*$"

"""
    chapter_base_episode_numbered(title) -> String

Like [`chapter_base`](@ref), but for novels whose titles lead with an *episode*
number rather than a chapter number (e.g. `"1화 - 호텔 탐색"`, `"2화 - 호텔
탐색(2)"`, both reducing to `"호텔 탐색"`), where `chapter_base` alone would
treat every episode as its own chapter since the leading `N화` increments every
episode. Strips the leading `N화` marker (see [`chapter_base_no_serial`](@ref)
for the analogous leading-serial case), then strips a trailing part marker that
optionally carries a trailing "Fin" annotation (e.g. `"(5)  Fin"`) — untagged
trailing text after the marker is left in place rather than guessed at. `missing`
passes through.
"""
chapter_base_episode_numbered(::Missing) = missing
chapter_base_episode_numbered(title::AbstractString) =
    strip(replace(replace(title, _EPISODE_NO_PREFIX => ""), _PART_MARKER_FIN => ""))

"""
    add_chapters!(df; base_fn=chapter_base) -> df

Groups episodes into chapters (단원) and adds two columns, ordered by `episode_no`:

- `chapter_no::Int` — 1-based chapter index; equal for every episode in a chapter.
- `chapter_title::String` — the chapter's base title (per `base_fn`).

Episodes are grouped into maximal *consecutive* runs sharing the same base title,
as computed by `base_fn` (default [`chapter_base`](@ref); pass
[`chapter_base_no_serial`](@ref) for novels titled with a leading global episode
serial instead of chapter numbering, [`chapter_base_prefix`](@ref) for novels
whose per-episode subtitle changes every episode, or
[`chapter_base_episode_numbered`](@ref) for novels titled with a leading episode
number instead of a chapter number). The run breaks whenever the base title
changes, so a base title that reappears later (after an intervening chapter)
starts a fresh chapter rather than merging non-adjacent episodes. A `missing`
title forms a base of its own and never merges with a neighbour. An empty frame
gets empty columns.
"""
function add_chapters!(df; base_fn = chapter_base)
    sort!(df, :episode_no)
    # Compute every base title up front: this vectorizes the (regex-bearing) `base_fn`
    # work and, since `chapter_title` is exactly these bases, lets it be assigned
    # directly without a scratch vector.
    bases = base_fn.(df.title)
    # A new chapter run starts on the first row, on any change of base title, and
    # around every `missing` (never equal to anything, itself included); the 1-based
    # `chapter_no` is then the running count of those run-starts — a cumulative sum,
    # which is the only inherently sequential part (each row depends on the previous).
    starts_run(i) =
        i == 1 || ismissing(bases[i]) || ismissing(bases[i-1]) || bases[i] != bases[i-1]
    df.chapter_no = cumsum(starts_run.(eachindex(bases)))
    df.chapter_title = convert(Vector{Union{Missing,String}}, bases)
    df
end

"""
    add_chapter_length!(df) -> df

Adds a `chapter_length` column: the number of episodes in each row's chapter
(requires a `chapter_no` column, see [`add_chapters!`](@ref)), constant across
every episode of the same chapter. An empty frame gets an empty column.
"""
function add_chapter_length!(df)
    n = nrow(df)
    if iszero(n)
        df.chapter_length = Int[]
        return df
    end
    counts = combine(groupby(df, :chapter_no), nrow => :chapter_length)
    df.chapter_length =
        leftjoin(select(df, :chapter_no), counts; on = :chapter_no, order = :left).chapter_length
    df
end

end # module Frames
