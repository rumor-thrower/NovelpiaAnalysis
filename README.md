# NovelpiaAnalysis.jl

Analysis layer for Novelpia web-novel data — ingestion of `npia export` output,
DataFrame shaping, summary statistics, and chart rendering. Built on top of the
Rust [`novelpia_api`](https://github.com/rumor-thrower/novelpia_api) / `npia` CLI.

## Submodules

- `Load` — reads an `npia export` output directory into typed DataFrames
- `Frames` — derived columns (per-episode retention, cumulative views)
- `Stats` — summary statistics and conditional-ratio helpers
- `Charts` — shared SVG bar-chart renderer for analysis notebooks

## Installation

Not registered in the General registry. There is no package-level dependency on
the Rust side — the only coupling is the on-disk file contract produced by
`npia export`:

```julia
using Pkg
Pkg.add(url = "https://github.com/rumor-thrower/NovelpiaAnalysis.jl")
```

## Usage

```julia
using NovelpiaAnalysis

# `dir` holds novel_<N>_episodes.csv / _reviews.csv / _manifest.json
# produced by: npia export --novel 127306 --out dir
data = Load.load("dir", 127306)

Frames.add_retention!(data.episodes)
Frames.add_cumulative_views!(data.episodes)

Stats.summary(data.episodes)
Charts.barchart(data.episodes.episode_no, data.episodes.count_view; title = "Views by episode")
```

## License

[MIT](LICENSE) — © 2026 rumor-thrower.
