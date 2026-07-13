@testset "Frames" begin
    episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
    Frames.add_retention!(episodes)
    @test episodes.retention == episodes.count_view ./ first(episodes.count_view)
    @test isone(first(episodes.retention))

    Frames.add_cumulative_views!(episodes)
    @test episodes.cumulative_views == cumsum(episodes.count_view)

    Frames.add_view_diff!(episodes)
    @test ismissing(first(episodes.view_diff))
    @test episodes.view_diff[2:end] == diff(episodes.count_view)

    rising = Frames.rising_episodes(episodes)
    @test nrow(rising) == count(>(0), skipmissing(episodes.view_diff))
    @test all(rising.view_diff .> 0)
end

@testset "Frames.add_chapters!" begin
    # chapter_base strips trailing part markers (ASCII/full-width parens, `- N`,
    # `#N`, and spacing variants) but keeps leading chapter numbering and bare titles.
    chapter_base = Frames.chapter_base
    @test chapter_base("각성(1)") == "각성"
    @test chapter_base("각성 (3)") == "각성"
    @test chapter_base("각성（2）") == "각성"
    @test chapter_base("수련 - 2") == "수련"
    @test chapter_base("수련 -3") == "수련"
    @test chapter_base("결전 #1") == "결전"
    @test chapter_base("여담") == "여담"
    @test chapter_base("3. 다시 몬드(1)") == "3. 다시 몬드"  # leading number kept
    @test chapter_base("#04_보더 타운(3)") == "#04_보더 타운"
    @test ismissing(chapter_base(missing))

    episodes = Load.read_episodes(FIXTURES, 777)
    Frames.add_chapters!(episodes)
    # 6 chapters: 프롤로그 | 각성(×3) | 수련(×3) | 결전(×2) | 여담(×2 bare repeat) |
    # 각성 again (reappearing base is a NEW chapter, not merged with the first).
    @test episodes.chapter_no == [1, 2, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6]
    @test maximum(episodes.chapter_no) == 6
    @test unique(episodes.chapter_title[episodes.chapter_no .== 2]) == ["각성"]
    @test episodes.chapter_title[end] == "각성"          # ch6 base equals ch2 base
    @test episodes.chapter_no[end] == 6                  # but is a distinct chapter
    # chapter_no is constant within a chapter and strictly increases across them.
    @test issorted(episodes.chapter_no)

    # A missing title never merges with either neighbour.
    m = DataFrame(episode_no = 1:3, title = ["A", missing, "A"])
    Frames.add_chapters!(m)
    @test m.chapter_no == [1, 2, 3]
    @test ismissing(m.chapter_title[2])

    # Empty frame gets empty columns rather than erroring.
    e = DataFrame(episode_no = Int[], title = String[])
    Frames.add_chapters!(e)
    @test isempty(e)
    @test hasproperty(e, :chapter_no) && hasproperty(e, :chapter_title)
end

@testset "Frames.chapter_base_no_serial" begin
    # Strips a leading global episode serial ("012. ") before delegating to
    # chapter_base, so same-chapter episodes numbered per-episode (not
    # per-chapter) collapse to the same base.
    base_no_serial = Frames.chapter_base_no_serial
    @test base_no_serial("012. 뱀파이어 형사") == "뱀파이어 형사"
    @test base_no_serial("013. 뱀파이어 형사") == "뱀파이어 형사"
    @test base_no_serial("001. 능력 각성") == "능력 각성"
    # Still strips trailing part markers same as chapter_base.
    @test base_no_serial("012. 각성(1)") == "각성"
    # A bare chapter-numbering prefix (no global serial) is also consumed —
    # this is the intended behavioural difference from chapter_base, which
    # keeps it. Callers pick whichever base_fn matches their novel's titling.
    @test base_no_serial("3. 다시 몬드(1)") == "다시 몬드"
    @test ismissing(base_no_serial(missing))

    # Regression: a novel titled with a leading global episode serial (e.g.
    # "012. 뱀파이어 형사", "013. 뱀파이어 형사" — the number increments every
    # episode, not every chapter). With the default chapter_base, the serial
    # makes every episode look like a new chapter; chapter_base_no_serial
    # strips it first so same-chapter episodes collapse together.
    episodes = DataFrame(
        episode_no = 1:5,
        title = [
            "001. 능력 각성",
            "002. 뱀파이어 형사",
            "003. 뱀파이어 형사",
            "004. 뱀파이어 형사",
            "005. 영천류",
        ],
    )
    Frames.add_chapters!(episodes; base_fn = Frames.chapter_base_no_serial)
    @test episodes.chapter_no == [1, 2, 2, 2, 3]
    @test episodes.chapter_title ==
          ["능력 각성", "뱀파이어 형사", "뱀파이어 형사", "뱀파이어 형사", "영천류"]

    # Without stripping the serial, the same data falls into one chapter per
    # episode (the bug this was written to fix).
    default_grouped = DataFrame(episode_no = 1:5, title = episodes.title)
    Frames.add_chapters!(default_grouped)
    @test default_grouped.chapter_no == [1, 2, 3, 4, 5]
end

@testset "Frames.add_chapter_length!" begin
    episodes = Load.read_episodes(FIXTURES, 777)
    Frames.add_chapters!(episodes)
    Frames.add_chapter_length!(episodes)
    # Same chapter sizes as the add_chapters! testset: 1,3,3,2,2,1
    @test episodes.chapter_length == [1, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 1]
    @test episodes.chapter_length[episodes.chapter_no .== 2] == fill(3, 3)

    e = DataFrame(episode_no = Int[], title = String[])
    Frames.add_chapters!(e)
    Frames.add_chapter_length!(e)
    @test isempty(e)
    @test hasproperty(e, :chapter_length)
end
