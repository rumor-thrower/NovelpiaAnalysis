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
  the width from the bar count.
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

    H = height
    present = collect(skipmissing(vals))
    max_v = isempty(present) ? 0.0 : max(maximum(present), 0.0)  # extends the baseline up
    min_v = isempty(present) ? 0.0 : min(minimum(present), 0.0)  # extends the baseline down
    span = max_v - min_v
    span = iszero(span) ? 1.0 : span
    bar_h = H - 100                                   # vertical area occupied by bars
    baseline_y = (H - 60) - round(Int, -min_v / span * bar_h)
    color_at(i) = colors isa AbstractString ? colors : colors[i]

    # Width: fixed `width` takes priority; otherwise derive from `bar_w`;
    # if neither is given, fall back to a default bar width.
    bw = isnothing(bar_w) ? (isnothing(width) ? 28 : (width - 80) ÷ n) : bar_w
    W = isnothing(width) ? 80 + (bw + gap) * n : width
    step = bw + gap

    rotated_label(cx, label) = (
        "  <text x=\"$cx\" y=\"$(H-38)\" text-anchor=\"end\" ",
        "dominant-baseline=\"middle\" font-size=\"11\" ",
        "transform=\"rotate(-45 $cx $(H-38))\">$label</text>\n",
    )
    horizontal_label(cx, label) = (
        "  <text x=\"$cx\" y=\"$(H-32)\" text-anchor=\"middle\" ",
        "font-size=\"12\">$label</text>\n",
    )

    rects = IOBuffer()
    for (i, v) in enumerate(vals)
        h = ismissing(v) ? 0 : round(Int, abs(v) / span * bar_h)
        x = 60 + (i - 1) * step
        cx = x + (bw ÷ 2)
        bar_top = (ismissing(v) || v >= 0) ? baseline_y - h : baseline_y
        label = _svg_text(labels[i])

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
            vw = bold_values ? " font-weight=\"bold\"" : ""
            value_y = v >= 0 ? bar_top - 4 : bar_top + h + 12
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
        "style=\"font-family:sans-serif;overflow:visible\">\n" *
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
