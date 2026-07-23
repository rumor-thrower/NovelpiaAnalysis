"""
    _ols_slope(x, y) -> Union{Missing, Float64}

Ordinary-least-squares slope of `y` on `x`. `missing` if fewer than two points
remain after dropping any pair with a `missing` value, or if `x` is constant
(zero variance, undefined slope).
"""
function _ols_slope(x, y)
    # Both loops skip any pair carrying a `missing` and widen the rest to
    # `Float64` inline. Masking the inputs into `disallowmissing` copies first
    # would read more directly, but it allocates five temporaries per call, and
    # `chapter_decline_slopes` calls this once per chapter.
    n = 0
    sx = 0.0
    sy = 0.0
    for (xi, yi) in zip(x, y)
        (ismissing(xi) || ismissing(yi)) && continue
        n += 1
        sx += Float64(xi)
        sy += Float64(yi)
    end
    n < 2 && return missing
    x̄ = sx / n
    ȳ = sy / n
    # The normal-equation slope Σ(x-x̄)(y-ȳ) / Σ(x-x̄)². The centering must happen
    # before the multiply: the algebraically equal Σx² - (Σx)²/n form cancels
    # catastrophically once x is large relative to its spread, and `charts.jl`'s
    # unlogged fit passes raw view counts, which reach into the millions.
    sxx = 0.0
    sxy = 0.0
    for (xi, yi) in zip(x, y)
        (ismissing(xi) || ismissing(yi)) && continue
        dx = Float64(xi) - x̄
        sxx += dx * dx
        sxy += dx * (Float64(yi) - ȳ)
    end
    iszero(sxx) ? missing : sxy / sxx
end

"""
    chapter_decline_slopes(df) -> DataFrame

One row per chapter (requires `chapter_no`, `chapter_length`, and `count_view`
columns — see [`Frames.add_chapters!`](@ref) and
[`Frames.add_chapter_length!`](@ref)), with columns `chapter_no`,
`chapter_length`, and `slope`: the OLS slope of `count_view` against
within-chapter episode position (1, 2, 3, …).

`slope` is `missing` for chapters with fewer than two episodes, or fewer than
two non-missing `count_view` values (no trend is definable). A negative slope
means views declined episode-over-episode within that chapter.
"""
function chapter_decline_slopes(df)
    combine(
        groupby(df, [:chapter_no, :chapter_length]),
        :count_view => (v -> _ols_slope(1:length(v), v)) => :slope,
    )
end

"""
    usable_chapters(chapters) -> DataFrame

Chapters whose `slope` is defined — the subset the correlations are scored over.
"""
usable_chapters(chapters) = subset(chapters, :slope => ByRow(!ismissing))

"""
    _correlation_undefined(chapters) -> Bool

Whether a length-vs-slope correlation is undefined over `chapters`: fewer than two
chapters to correlate, or zero variance in `chapter_length` or `slope` (either
constant makes Pearson's denominator zero, so `cor` would return `NaN` rather
than a correlation).
"""
_correlation_undefined(chapters) =
    nrow(chapters) < 2 ||
    iszero(var(chapters.chapter_length)) ||
    iszero(var(chapters.slope))

"""
    ChapterLengthDeclineCorrelation

Result of [`chapter_length_decline_correlation`](@ref): the Pearson
correlation alongside the per-chapter DataFrame it was computed over.
"""
struct ChapterLengthDeclineCorrelation
    pearson::Union{Float64,Missing}
    chapters::DataFrame
end

"""
    chapter_length_decline_correlation(df) -> ChapterLengthDeclineCorrelation

Pearson correlation (via `Statistics.cor`) between `chapter_length` and the
within-chapter view-decline `slope` across chapters (see
[`chapter_decline_slopes`](@ref)), alongside the per-chapter DataFrame used to
compute it.

Returns a [`ChapterLengthDeclineCorrelation`](@ref). Chapters with a `missing`
slope are excluded from the correlation first (but are still present in
`chapters`). `pearson` is `missing` if fewer than two chapters remain, or if
`chapter_length` or `slope` is constant across all remaining chapters.

A negative correlation supports the hypothesis that longer chapters
(episode 장편화) accelerate view-count decline.
"""
function chapter_length_decline_correlation(df)
    chapters = chapter_decline_slopes(df)
    usable = usable_chapters(chapters)
    pearson =
        _correlation_undefined(usable) ? missing : cor(usable.chapter_length, usable.slope)
    ChapterLengthDeclineCorrelation(pearson, chapters)
end

"""
    spearman_cor(x, y) -> Union{Float64,Missing}

Spearman rank correlation: Pearson's [`Statistics.cor`](@ref) applied to the
ranks of `x` and `y`. Ranks come from `sortperm(sortperm(·))`, which breaks ties
by original position rather than averaging them (`competerank`-style average
ranks aren't needed for a robustness cross-check, and this avoids a `StatsBase`
dependency).

Being rank-based, it is far less sensitive than Pearson to a handful of extreme
values, so a large Pearson/Spearman gap is itself the tell that the Pearson value
is outlier-driven.

A rank correlation needs at least two pairs to vary, so fewer than two is
`missing`: `cor` would throw on an empty sample and return `NaN` for a single
pair. Two or more pairs always have a defined correlation, because ranking by
`sortperm(sortperm(·))` breaks ties by position and so always yields a
permutation of `1:n`, never a constant vector.
"""
function spearman_cor(x, y)
    rank(v) = sortperm(sortperm(collect(v)))
    length(x) < 2 && return missing
    cor(rank(x), rank(y))
end

"""
    ChapterDeclineLeverage

Result of [`chapter_length_decline_leverage`](@ref): `pearson`/`spearman`
correlation of chapter length against decline slope, alongside the
usable/long/scored chapter counts the correlation was taken over.

Splats like a `NamedTuple` (`(; leverage..., other_field = x)` works), so
callers that merge it into a larger `NamedTuple` don't need to change.
"""
struct ChapterDeclineLeverage
    pearson::Union{Float64,Missing}
    spearman::Union{Float64,Missing}
    usable_n::Int
    long_n::Int
    scored_n::Int
end

Base.propertynames(::ChapterDeclineLeverage) =
    (:pearson, :spearman, :usable_n, :long_n, :scored_n)

function Base.iterate(lev::ChapterDeclineLeverage, state = 1)
    names = propertynames(lev)
    state > length(names) && return nothing
    (names[state] => getfield(lev, names[state]), state + 1)
end

"""
    chapter_length_decline_leverage(chapters; long_chapter_cutoff, drop_long_chapters=false)
        -> ChapterDeclineLeverage

Leverage analysis over the per-chapter DataFrame from
[`chapter_length_decline_correlation`](@ref) (or [`chapter_decline_slopes`](@ref)):
recomputes the length-vs-decline correlation on a subset and reports it alongside
a rank correlation and chapter counts, so a few very long (typically
post-completion side-story) chapters can't define the regression line by
themselves.

Chapters with a `missing` slope are dropped first (the `usable` set). `long`
chapters are those longer than `long_chapter_cutoff` episodes. When
`drop_long_chapters` is `true` the correlations are computed over just the
chapters at or below the cutoff; otherwise over the full `usable` set.

Returns a [`ChapterDeclineLeverage`](@ref). `pearson` and `spearman` are
`missing` when fewer than two chapters are scored or their `chapter_length`
or `slope` is constant (undefined correlation — a rank correlation over a
constant `slope` would only echo the positional tie-breaking of
[`spearman_cor`](@ref), not a real trend).
"""
function chapter_length_decline_leverage(
    chapters;
    long_chapter_cutoff,
    drop_long_chapters = false,
)
    usable = usable_chapters(chapters)
    is_long = usable.chapter_length .> long_chapter_cutoff
    scored_rows = drop_long_chapters ? .!is_long : Colon()
    scored = view(usable, scored_rows, :)
    pearson, spearman = if _correlation_undefined(scored)
        missing, missing
    else
        cor(scored.chapter_length, scored.slope),
        spearman_cor(scored.chapter_length, scored.slope)
    end
    ChapterDeclineLeverage(pearson, spearman, nrow(usable), count(is_long), nrow(scored))
end
