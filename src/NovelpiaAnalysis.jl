"""
    NovelpiaAnalysis

Reusable analysis layer for Novelpia novel data.
The CSV/JSON files left on disk by the Rust `novelpia_api` (`npia export`) are the sole input —
this package does not perform scraping.

Submodules:
- [`Load`](@ref)  — reads `npia export` output directories into typed DataFrames
- [`Frames`](@ref) — computes derived columns (retention, cumulative view counts)
- [`Stats`](@ref)  — computes summary statistics and conditional ratios
- [`Charts`](@ref) — shared SVG bar chart renderer for experiment notebooks

# Example usage
```julia
using NovelpiaAnalysis

data = Load.load("export_dir", 127306)
Frames.add_retention!(data.episodes)
Stats.summary(data.episodes)
```

Chapter-level columns have an ordering dependency: `add_chapter_length!`
requires the `chapter_no` column added by [`Frames.add_chapters!`](@ref), so
`add_chapters!` must run first.
"""
module NovelpiaAnalysis

include("Load.jl")
include("Frames.jl")
include("Stats.jl")
include("Charts.jl")

using .Load, .Frames, .Stats, .Charts

export Load, Frames, Stats, Charts

end # module NovelpiaAnalysis
