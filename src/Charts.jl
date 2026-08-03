"""
    Charts

Shared SVG bar-chart renderer for analysis notebooks.

A single `barchart` function absorbs four chart variants (solid color, per-bar
color, rotated labels, spaced bars) as keyword arguments. Returns `HTML` (for
inline Pluto display); if `outfile` is given, the same SVG is also written to
that path.
"""
module Charts

export barchart

_svg_text(s) =
    replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

# Rough advance width of `c` in em. CJK glyphs are full-width; Latin averages
# about half an em. Only used to reserve label space, so an approximation that
# never *under*-estimates is what matters.
_char_em(c::AbstractChar) = ifelse(
    c in 'ᄀ':'ᇿ' || c in '⺀':'鿿' || c in 'ꥠ':'꥿' || c in '가':'퟿' || c in '＀':'｠',
    1.0,
    0.55,
)

# Width in px of the longest line of `label` at `font_size`.
_line_px(label, font_size) =
    isempty(label) ? 0.0 :
    maximum(sum(_char_em, line; init = 0.0) for line in split(label, '\n')) * font_size

"""
    barchart(labels, vals; kwargs...) -> HTML

Draws an SVG bar chart with `labels` (x-axis) and `vals` (bar heights).
`vals` may include negative numbers: bars grow up from a zero baseline for
positive values and down from it for negative values: the baseline itself
shifts within the plot area to fit whichever mix of signs is present.

# Keyword arguments
- `colors`        : a single color string (applied to all bars) or a per-bar color
  vector. Defaults to `"#4e79a7"`.
- `vals` may also contain `missing` entries (e.g. episode 1's `view_diff` or a
  gap in `retention`); those bars are drawn with zero height and no value label.
- `title`         : `<h4>` title above the chart. `nothing` means no title.
- `width`,`height`: fixed dimensions if given. `width=nothing` (default) derives
  the width from the bar count. `height` sizes the *plot area*: the space the
  x-axis labels need is measured from the labels and added below it, so the
  rendered SVG is taller than `height` whenever labels are long or rotated.
- a label containing `\\n` is drawn as multiple stacked lines.
- `bar_w`         : width of a single bar slot in px. `nothing` (default) derives
  it from the overall width.
- `gap`           : extra spacing between bars in px. Defaults to `0`.
- `rotate_labels` : if `true`, rotates x-axis labels -45° (for long labels).
  Defaults to `false`.
- `bold_values`   : bolds the value label above each bar. Defaults to `false`.
- `legend`        : a vector of `(label, color)` tuples. If given, renders a
  legend in the top-right corner. Defaults to `nothing`.
- `outfile`       : if given, also writes the SVG to this path.
"""
# All pixel geometry for the plot: SVG canvas size, baseline, bar slots, and
# the label font/line metrics needed to place x-axis text. Kept independent of
# `vals`/`colors`/rendering so the layout math has a single, testable home.
function _bar_geometry(strs, n, min_v, max_v; width, height, bar_w, gap, rotate_labels)
    span = max_v - min_v
    span = ifelse(iszero(span), 1.0, span)

    # `height` sizes the plot area; the room x-axis labels need is measured from
    # the labels themselves and added below it, so long or rotated labels extend
    # the drawing rather than spilling out of it.
    label_fs = ifelse(rotate_labels, 11, 12)
    n_lines = maximum(count(==('\n'), s) + 1 for s in strs)
    longest = maximum(_line_px(s, label_fs) for s in strs)
    line_h = label_fs + 3

    (label_pad, left_pad) = let base_pad = n_lines * line_h + 12
        if rotate_labels
            # Anchored at `end` and rotated -45°, a label reaches `longest/√2` down
            # and to the left of its anchor; stacked lines add `n_lines` more.
            reach = longest / sqrt(2)
            reach_i = round(Int, reach)
            (reach_i + base_pad, reach_i + 8)
        else
            (base_pad, 0)
        end
    end

    H = height + label_pad
    bar_h = height - 100                              # vertical area occupied by bars
    px_per_unit = bar_h / span
    axis_y = height - 20                              # where x-axis labels start
    baseline_y = (height - 60) - round(Int, -min_v * px_per_unit)

    # Width: fixed `width` takes priority; otherwise derive from `bar_w`;
    # if neither is given, fall back to a default bar width.
    bw_default = isnothing(width) ? 28 : (width - 80) ÷ n
    bw = ifelse(isnothing(bar_w), bw_default, bar_w)
    W = ifelse(isnothing(width), 80 + (bw + gap) * n, width) + left_pad
    step = bw + gap
    x0 = 60 + left_pad                                # first bar's left edge

    (; H, W, px_per_unit, axis_y, baseline_y, bw, step, x0, label_fs, line_h)
end

# `dy` inside a rotated <text> runs along the rotated normal, so stacked
# lines separate correctly in both the rotated and horizontal cases.
_tspans(label, anchor_x, line_h) = join((
    "<tspan x=\"$anchor_x\" dy=\"$(ifelse(isone(i), 0, line_h))\">$(_svg_text(line))</tspan>"
    for (i, line) in enumerate(split(label, '\n'))
),)

function _axis_label_svg(cx, label, geo, rotate_labels)
    if rotate_labels
        "  <text x=\"$cx\" y=\"$(geo.axis_y)\" text-anchor=\"end\" " *
        "font-size=\"$(geo.label_fs)\" " *
        "transform=\"rotate(-45 $cx $(geo.axis_y))\">$(_tspans(label, cx, geo.line_h))</text>\n"
    else
        "  <text x=\"$cx\" y=\"$(geo.axis_y + geo.label_fs)\" text-anchor=\"middle\" " *
        "font-size=\"$(geo.label_fs)\">$(_tspans(label, cx, geo.line_h))</text>\n"
    end
end

# Renders every `<g>` bar group (rect + axis label + value label) into one SVG
# fragment string.
function _bars_svg(strs, vals, geo; color_at, rotate_labels, bold_values)
    rects = IOBuffer()
    for (i, v) in enumerate(vals)
        h = ismissing(v) ? 0 : round(Int, abs(v) * geo.px_per_unit)
        x = geo.x0 + (i - 1) * geo.step
        cx = x + (geo.bw ÷ 2)
        bar_top = geo.baseline_y - ifelse(ismissing(v) || v >= 0, h, 0)
        label = strs[i]                               # `_tspans` escapes each line

        print(rects, "<g>\n")
        print(
            rects,
            "  <rect x=\"$x\" y=\"$bar_top\" width=\"$(geo.bw-3)\" height=\"$h\" ",
            "fill=\"$(color_at(i))\" rx=\"2\"/>\n",
        )
        print(rects, _axis_label_svg(cx, label, geo, rotate_labels))
        if !ismissing(v)
            vw = ifelse(bold_values, " font-weight=\"bold\"", "")
            value_y = bar_top + ifelse(v >= 0, -4, h + 12)
            print(
                rects,
                "  <text x=\"$cx\" y=\"$value_y\" text-anchor=\"middle\" ",
                "font-size=\"11\" fill=\"#333\"$vw>$v</text>\n",
            )
        end
        print(rects, "</g>\n")
    end
    String(take!(rects))
end

# Wraps the legend + bar fragments in the outer `<svg>` element and, if
# `outfile` is given, writes it out as a side effect.
function _render_svg(geo, legend_svg, bars; outfile)
    svg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$(geo.W)\" height=\"$(geo.H)\" " *
        "style=\"font-family:sans-serif;max-width:100%\">\n" *
        legend_svg *
        "\n" *
        bars *
        "</svg>"
    isnothing(outfile) || write(outfile, svg)
    svg
end

# Wraps `svg` with an optional `<h4>` title into the final Pluto-displayable
# `HTML`.
function _wrap_html(svg, title)
    head =
        isnothing(title) ? "" :
        "<h4 style=\"font-family:sans-serif;margin:8px 0\">$(_svg_text(title))</h4>"
    HTML("<div>$head$svg</div>")
end

_legend_svg(::Nothing, W) = ""
_legend_svg(legend, W) = join(
    (
        "<g transform=\"translate($(W-130+i*55),12)\">" *
        "<rect width=\"12\" height=\"12\" fill=\"$c\" rx=\"2\"/>" *
        "<text x=\"16\" y=\"10\" font-size=\"11\">$(_svg_text(l))</text></g>" for
        (i, (l, c)) in enumerate(legend)
    ),
    "\n",
)

function barchart(
    labels,
    vals;
    colors = "#4e79a7",
    title = nothing,
    width = nothing,
    height = 280,
    bar_w = nothing,
    gap = 0,
    rotate_labels::Bool = false,
    bold_values::Bool = false,
    legend = nothing,
    outfile = nothing,
)
    n = length(labels)
    iszero(n) && return HTML("<p style='font-family:sans-serif'>no data</p>")

    present = collect(skipmissing(vals))
    min_v, max_v =
        isempty(present) ? (0.0, 0.0) :
        (min(minimum(present), 0.0), max(maximum(present), 0.0))  # extends baseline down/up
    color_at(i) = colors isa AbstractString ? colors : colors[i]
    strs = string.(labels)

    geo = _bar_geometry(strs, n, min_v, max_v; width, height, bar_w, gap, rotate_labels)
    bars = _bars_svg(strs, vals, geo; color_at, rotate_labels, bold_values)
    legend_svg = _legend_svg(legend, geo.W)

    svg = _render_svg(geo, legend_svg, bars; outfile)
    _wrap_html(svg, title)
end

end # module Charts
