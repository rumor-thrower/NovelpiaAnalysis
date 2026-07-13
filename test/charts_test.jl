@testset "Charts" begin
    html = Charts.barchart([1, 2], [356, 110]; title = "views")
    @test html isa Base.HTML
    @test occursin("<svg", html.content)

    empty_html = Charts.barchart(Int[], Int[])
    @test empty_html isa Base.HTML

    mktempdir() do dir
        outfile = joinpath(dir, "chart.svg")
        Charts.barchart([1, 2], [356, 110]; outfile = outfile)
        @test isfile(outfile)
    end

    # Negative and mixed-sign values must render valid (non-negative height,
    # in-bounds) rects rather than the pre-fix negative-height/off-canvas bug.
    _rect_attrs(svg) = [
        m.captures for m in eachmatch(
            r"<rect x=\"(-?\d+)\" y=\"(-?\d+)\" width=\"(-?\d+)\" height=\"(-?\d+)\"",
            svg,
        )
    ]

    # Every rect must have positive width and non-negative height.
    function valid_rects(html, n)
        rects = _rect_attrs(html.content)
        @test length(rects) == n
        for (_, _, w, h) in rects
            @test parse(Int, w) > 0
            @test parse(Int, h) >= 0
        end
        rects
    end

    valid_rects(Charts.barchart(["a", "b"], [-1.0, -2.0]), 2)

    mixed_html = Charts.barchart(["a", "b", "c"], [-10.0, 20.0, -5.0])
    rects = valid_rects(mixed_html, 3)
    # The positive bar's rect must extend strictly above the baseline shared
    # by the two negative bars' (equal) top y-coordinates.
    ys = [parse(Int, r[2]) for r in rects]
    @test ys[2] < ys[1] == ys[3]

    color_a, color_b = "#4e79a7", "#f28e2b"
    legend_html = Charts.barchart(
        ["a", "b"],
        [1, 2];
        colors = [color_a, color_b],
        legend = [("A", color_a), ("B", color_b)],
    )
    in_legend = occursin(legend_html.content)
    @test in_legend("translate(")
    @test in_legend(">A</text>")
    @test in_legend(">B</text>")
end

@testset "Charts x-axis label containment" begin
    # Regression: `rotate_labels = true` anchored every label at a fixed
    # `y = H - 38` in a fixed-height SVG and leaned on `overflow:visible` to
    # paint the overhang. Rotated -45° from an `end` anchor a label runs down
    # and to the left, so long labels (and the first bar's, always) painted
    # outside the viewport and got clipped by the notebook's cell box.
    # Labels now size the SVG, so their boxes must land inside it.

    # Widths come from the renderer's own em model. What's under test is the
    # padding arithmetic around it, which `corners` re-derives from the SVG.

    # Every x-axis <text>: anchor, rotation, and its stacked tspan lines.
    function axis_labels(svg)
        re =
            r"<text x=\"(-?\d+)\" y=\"(-?\d+)\" text-anchor=\"(\w+)\" font-size=\"(\d+)\" ?(transform=\"rotate\(-45[^\"]*\")?>((?:<tspan.*?</tspan>)+)</text>"
        [
            (
                x = parse(Int, m[1]),
                y = parse(Int, m[2]),
                anchor = m[3],
                fs = parse(Int, m[4]),
                rotated = !isnothing(m[5]),
                lines = [t[1] for t in eachmatch(r"<tspan[^>]*>(.*?)</tspan>", m[6])],
            ) for m in eachmatch(re, svg)
        ]
    end

    # Corners of a label's text block in user space, after any rotation.
    function corners(l)
        w = Charts._line_px(join(l.lines, '\n'), l.fs)
        offset = if l.anchor == "end"
            w
        elseif l.anchor == "middle"
            w / 2
        else
            0
        end
        x1 = l.x - offset
        top, bot = l.y - l.fs, l.y + length(l.lines) * (l.fs + 3)
        pts = [(x1, top), (x1 + w, top), (x1, bot), (x1 + w, bot)]
        l.rotated || return pts
        map(pts) do (px, py)
            c, s = cospi(-0.25), sinpi(-0.25)  # rotate(-45) about the anchor
            dx, dy = px - l.x, py - l.y  # offset from the anchor, pre-rotation
            (l.x + dx * c - dy * s, l.y + dx * s + dy * c)
        end
    end

    function viewport(svg)
        m = match(r"<svg[^>]*width=\"(\d+)\" height=\"(\d+)\"", svg)
        parse(Int, m[1]), parse(Int, m[2])
    end

    function contained(svg)
        labels = axis_labels(svg)
        @test !isempty(labels)  # a regex that matches nothing proves nothing
        in_bounds = let (W, H) = viewport(svg)
            ((px, py),) -> -0.5 <= px <= W + 0.5 && -0.5 <= py <= H + 0.5
        end
        all(l -> all(in_bounds, corners(l)), labels)
    end
    bc(args...; kwargs...) = Charts.barchart(args...; kwargs...).content
    contained_barchart(args...; kwargs...) = contained(bc(args...; kwargs...))

    group = ["완결\n중앙값", "완결\n기하평균", "연재\n중앙값", "연재\n기하평균"]
    long_tag = ["현대판타지 로맨스 대하소설\n(n=1234)", "회귀\n(n=88)", "TS\n(n=9)"]
    gvals = [1200.0, 800.0, 950.0, 600.0]

    # The two shapes that actually broke: multi-line CJK labels, rotated.
    @test contained_barchart(group, gvals; rotate_labels = true)
    @test contained_barchart(
        long_tag,
        [3.1, 2.0, 1.4];
        rotate_labels = true,
        bold_values = true,
    )
    # …and the shapes that already worked, which must keep working.
    @test contained_barchart(string.(1:12), float.(1:12); rotate_labels = true)
    @test contained_barchart(group, gvals)
    @test contained_barchart(["a", "b"], [1.0, 2.0])
    @test contained_barchart(["x\ny", "z"], [-5.0, missing]; rotate_labels = true)
    @test contained_barchart(
        ["긴이름하나", "b"],
        [1.0, 2.0];
        width = 400,
        legend = [("중앙값", "#111")],
    )

    # A rotated chart reserves room below `height` and left of the bars,
    # rather than drawing labels over the bars or off-canvas.
    long_tag_at_280(; kwargs...) = bc(long_tag, [3.1, 2.0, 1.4]; height = 280, kwargs...)
    plain = long_tag_at_280()
    rot = long_tag_at_280(; rotate_labels = true)
    @test last(viewport(rot)) > last(viewport(plain)) > 280
    @test first(viewport(rot)) > first(viewport(plain))

    single_bar(label) = bc([label], [1.0])

    # `\n` becomes stacked <tspan> lines, not a literal newline in one run.
    two_line = single_bar("완결\n중앙값")
    @test occursin(">완결</tspan>", two_line)
    @test occursin(">중앙값</tspan>", two_line)
    @test !occursin("완결\n중앙값", two_line)

    # Each line is escaped exactly once (the bar loop no longer pre-escapes).
    esc = single_bar("a & b<c")
    @test occursin(">a &amp; b&lt;c</tspan>", esc)
    @test !occursin("&amp;amp;", esc)
end
