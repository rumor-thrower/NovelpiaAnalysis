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
    max_v = isempty(present) ? 0.0 : max(maximum(present), 0.0)  # extends the baseline up
    min_v = isempty(present) ? 0.0 : min(minimum(present), 0.0)  # extends the baseline down
    span = max_v - min_v
    span = ifelse(iszero(span), 1.0, span)
    color_at(i) = colors isa AbstractString ? colors : colors[i]

    # `height` sizes the plot area; the room x-axis labels need is measured from
    # the labels themselves and added below it, so long or rotated labels extend
    # the drawing rather than spilling out of it.
    label_fs = ifelse(rotate_labels, 11, 12)
    strs = [string(l) for l in labels]
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

    # `dy` inside a rotated <text> runs along the rotated normal, so stacked
    # lines separate correctly in both the rotated and horizontal cases.
    tspans(label, anchor_x) = join((
        "<tspan x=\"$anchor_x\" dy=\"$(ifelse(isone(i), 0, line_h))\">$(_svg_text(line))</tspan>"
        for (i, line) in enumerate(split(label, '\n'))
    ),)
    rotated_label(cx, label) = (
        "  <text x=\"$cx\" y=\"$axis_y\" text-anchor=\"end\" ",
        "font-size=\"$label_fs\" ",
        "transform=\"rotate(-45 $cx $axis_y)\">$(tspans(label, cx))</text>\n",
    )
    horizontal_label(cx, label) = (
        "  <text x=\"$cx\" y=\"$(axis_y + label_fs)\" text-anchor=\"middle\" ",
        "font-size=\"$label_fs\">$(tspans(label, cx))</text>\n",
    )

    rects = IOBuffer()
    for (i, v) in enumerate(vals)
        h = ismissing(v) ? 0 : round(Int, abs(v) * px_per_unit)
        x = x0 + (i - 1) * step
        cx = x + (bw ÷ 2)
        bar_top = baseline_y - ifelse(ismissing(v) || v >= 0, h, 0)
        label = strs[i]                               # `tspans` escapes each line

        print(rects, "<g>\n")
        print(
            rects,
            "  <rect x=\"$x\" y=\"$bar_top\" width=\"$(bw-3)\" height=\"$h\" ",
            "fill=\"$(color_at(i))\" rx=\"2\"/>\n",
        )
        print(
            rects,
            (rotate_labels ? rotated_label(cx, label) : horizontal_label(cx, label))...,
        )
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

    legend_svg = ""
    if !isnothing(legend)
        parts = String[]
        for (i, (l, c)) in enumerate(legend)
            push!(
                parts,
                "<g transform=\"translate($(W-130+i*55),12)\">" *
                "<rect width=\"12\" height=\"12\" fill=\"$c\" rx=\"2\"/>" *
                "<text x=\"16\" y=\"10\" font-size=\"11\">$(_svg_text(l))</text></g>",
            )
        end
        legend_svg = join(parts, "\n")
    end

    svg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$W\" height=\"$H\" " *
        "style=\"font-family:sans-serif;max-width:100%\">\n" *
        legend_svg *
        "\n" *
        String(take!(rects)) *
        "</svg>"

    isnothing(outfile) || write(outfile, svg)

    head =
        isnothing(title) ? "" :
        "<h4 style=\"font-family:sans-serif;margin:8px 0\">$(_svg_text(title))</h4>"
    HTML("<div>$head$svg</div>")
end

end # module Charts
