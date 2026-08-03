"""
    Stats

Summary statistics and conditional-ratio helpers over episode/review DataFrames.
"""
module Stats

using DataFrames, Statistics

export summary,
    conditional_ratio,
    chapter_decline_slopes,
    chapter_length_decline_correlation,
    spearman_cor,
    chapter_length_decline_leverage,
    usable_chapters,
    ViewAggregates,
    EpisodeSummary,
    ChapterDeclineLeverage,
    ChapterLengthDeclineCorrelation

include("stats/summary.jl")
include("stats/chapters.jl")

end # module Stats
