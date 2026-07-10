"""
    Load

Reads an `npia export` output directory into typed DataFrames.

`npia export --novel <N> --out <DIR>` writes three files under `<DIR>/<N>/`:
- `episodes.csv`  — one row per episode (metadata + real view count merged)
- `reviews.csv`   — one row per review
- `manifest.json` — counts and file list for light integrity checking

The Rust API is reverse-engineered and may drift, so parsing here is defensive:
missing/empty cells become `missing` rather than raising, and reviews are read with
whatever columns are present instead of a pinned schema.
"""
module Load

using CSV, DataFrames, JSON3, Dates

export Manifest, read_manifest, read_episodes, read_reviews, load

"""
    Manifest

Mirrors `manifest.json` written by `npia export`.
"""
struct Manifest
    novel_no::Int
    exported_at::String
    sort::String
    episode_count::Int
    view_count_rows::Int
    review_count::Int
    files::Vector{String}
end

_novel_dir(dir, novel_no) = joinpath(dir, string(novel_no))
_episodes_path(dir, novel_no) = joinpath(_novel_dir(dir, novel_no), "episodes.csv")
_reviews_path(dir, novel_no) = joinpath(_novel_dir(dir, novel_no), "reviews.csv")
_manifest_path(dir, novel_no) = joinpath(_novel_dir(dir, novel_no), "manifest.json")

"""
    read_manifest(dir, novel_no) -> Manifest

Reads `<dir>/<novel_no>/manifest.json`.
"""
function read_manifest(dir, novel_no)
    path = _manifest_path(dir, novel_no)
    isfile(path) || error("manifest not found: $path")
    j = JSON3.read(read(path, String))
    Manifest(
        j.novel_no,
        j.exported_at,
        j.sort,
        j.episode_count,
        j.view_count_rows,
        j.review_count,
        collect(String, j.files),
    )
end

# npia's `reg_date` is written as "YY.MM.DD" (2-digit year), not ISO 8601.
# `dateformat"yy.mm.dd"` parses the 2-digit year literally (23 -> year 23), so the
# century is added explicitly; Novelpia has no 20th-century content to disambiguate.
function _parse_reg_date(s::Union{Missing,AbstractString})
    ismissing(s) && return missing
    isempty(s) && return missing
    Date(s, dateformat"yy.mm.dd") + Year(2000)
end

"""
    read_episodes(dir, novel_no) -> DataFrame

Reads `<dir>/<novel_no>/episodes.csv` with typed columns:
`episode_no::Int`, `title::String`, `is_free::Bool`, `is_adult::Bool`,
`reg_date::Union{Date,Missing}`, `count_view::Union{Int,Missing}`.

A novel with zero episodes (e.g. deleted from Novelpia) writes a completely
empty `episodes.csv` — no header row at all — so `CSV.read` yields a
0-row/0-column frame. That case is normalized to the same empty-but-typed
schema as a populated file, so downstream code (e.g. `Frames` functions
sorting by `:episode_no`) doesn't need to special-case it.
"""
function read_episodes(dir, novel_no)
    path = _episodes_path(dir, novel_no)
    isfile(path) || error("episodes file not found: $path")
    df = CSV.read(path, DataFrame; missingstring = "")
    if iszero(ncol(df))
        return DataFrame(
            count_view = Union{Int,Missing}[],
            episode_no = Int[],
            is_adult = Bool[],
            is_free = Bool[],
            reg_date = Union{Date,Missing}[],
            title = String[],
        )
    end
    df.reg_date = _parse_reg_date.(df.reg_date)
    df
end

"""
    read_reviews(dir, novel_no) -> DataFrame

Reads `<dir>/<novel_no>/reviews.csv` permissively — whatever columns are present
are kept as-is, since the review schema is not pinned by this package.
"""
function read_reviews(dir, novel_no)
    path = _reviews_path(dir, novel_no)
    isfile(path) || error("reviews file not found: $path")
    CSV.read(path, DataFrame; missingstring = "")
end

"""
    load(dir, novel_no) -> NamedTuple{(:manifest, :episodes, :reviews)}

Convenience one-call ingestion of an `npia export` output directory.
"""
function load(dir, novel_no)
    (
        manifest = read_manifest(dir, novel_no),
        episodes = read_episodes(dir, novel_no),
        reviews = read_reviews(dir, novel_no),
    )
end

end # module Load
