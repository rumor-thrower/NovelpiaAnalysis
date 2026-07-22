@testset "Frames" begin
    episodes = Load.read_episodes(FIXTURES, NOVEL_NO)

    @testset "add_retention!" begin
        Frames.add_retention!(episodes)
        @test episodes.retention ==
              round.(episodes.count_view ./ first(episodes.count_view); digits = 2)
        @test isone(first(episodes.retention))
    end

    @testset "add_cumulative_views!" begin
        Frames.add_cumulative_views!(episodes)
        @test episodes.cumulative_views == cumsum(episodes.count_view)
    end

    @testset "add_view_diff!" begin
        Frames.add_view_diff!(episodes)
        @test ismissing(first(episodes.view_diff))
        @test episodes.view_diff[2:end] == diff(episodes.count_view)
    end

    @testset "rising_episodes" begin
        rising = Frames.rising_episodes(episodes)
        @test nrow(rising) == count(>(0), skipmissing(episodes.view_diff))
        @test all(rising.view_diff .> 0)
    end
end

@testset "Frames.add_chapters!" begin
    @testset "chapter_base" begin
        # chapter_base strips trailing part markers (ASCII/full-width parens, `- N`,
        # `#N`, and spacing variants) but keeps leading chapter numbering and bare titles.
        chapter_base = Frames.chapter_base
        @testset "parenthesised part markers (ASCII and full-width)" begin
            @test chapter_base("각성(1)") == "각성"
            @test chapter_base("각성 (3)") == "각성"
            @test chapter_base("각성（2）") == "각성"
        end

        @testset "dash and hash part markers" begin
            @test chapter_base("수련 - 2") == "수련"
            @test chapter_base("수련 -3") == "수련"
            @test chapter_base("결전 #1") == "결전"
        end

        @testset "bare titles and leading chapter numbering kept" begin
            @test chapter_base("여담") == "여담"
            @test chapter_base("3. 다시 몬드(1)") == "3. 다시 몬드"  # leading number kept
            @test chapter_base("#04_보더 타운(3)") == "#04_보더 타운"
        end

        @test ismissing(chapter_base(missing))
    end

    @testset "groups a real novel into chapters" begin
        episodes = Load.read_episodes(FIXTURES, 777)
        Frames.add_chapters!(episodes)
        # 6 chapters: 프롤로그 | 각성(×3) | 수련(×3) | 결전(×2) | 여담(×2 bare repeat) |
        # 각성 again (reappearing base is a NEW chapter, not merged with the first).
        @test episodes.chapter_no ==
              vcat(fill(1, 1), fill(2, 3), fill(3, 3), fill(4, 2), fill(5, 2), fill(6, 1))
        @test unique!(episodes.chapter_title[episodes.chapter_no .== 2]) == ["각성"]
        @test episodes.chapter_title[end] == "각성"          # ch6 base equals ch2 base
        @test episodes.chapter_no[end] == 6                  # but is a distinct chapter
        # chapter_no is constant within a chapter and strictly increases across them.
        @test issorted(episodes.chapter_no)
    end

    @testset "missing title never merges with either neighbour" begin
        m = DataFrame(episode_no = 1:3, title = ["A", missing, "A"])
        Frames.add_chapters!(m)
        @test m.chapter_no == 1:3
        @test ismissing(m.chapter_title[2])
    end

    @testset "empty frame gets empty columns rather than erroring" begin
        e = DataFrame(episode_no = Int[], title = String[])
        Frames.add_chapters!(e)
        @test isempty(e)
        @test hasproperty(e, :chapter_no) && hasproperty(e, :chapter_title)
    end
end

@testset "Frames.chapter_base_no_serial" begin
    @testset "chapter_base_no_serial" begin
        # Strips a leading global episode serial ("012. ") before delegating to
        # chapter_base, so same-chapter episodes numbered per-episode (not
        # per-chapter) collapse to the same base.
        base_no_serial = Frames.chapter_base_no_serial
        @testset "leading global episode serial" begin
            @test base_no_serial("012. 뱀파이어 형사") == "뱀파이어 형사"
            @test base_no_serial("013. 뱀파이어 형사") == "뱀파이어 형사"
            @test base_no_serial("001. 능력 각성") == "능력 각성"
        end

        # Still strips trailing part markers same as chapter_base.
        @test base_no_serial("012. 각성(1)") == "각성"

        @testset "space after the dot is optional" begin
            # (some novels omit it, some mix both forms within the same title list).
            @test base_no_serial("5.눈먼 신도들") == "눈먼 신도들"
            @test base_no_serial("1.첫만남") == "첫만남"
        end

        # A bare chapter-numbering prefix (no global serial) is also consumed —
        # this is the intended behavioural difference from chapter_base, which
        # keeps it. Callers pick whichever base_fn matches their novel's titling.
        @test base_no_serial("3. 다시 몬드(1)") == "다시 몬드"

        @test ismissing(base_no_serial(missing))
    end

    @testset "regression: leading global episode serial collapses to one chapter" begin
        # A novel titled with a leading global episode serial (e.g.
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
        @test episodes.chapter_no == vcat(fill(1, 1), fill(2, 3), fill(3, 1))
        @test episodes.chapter_title ==
              ["능력 각성", "뱀파이어 형사", "뱀파이어 형사", "뱀파이어 형사", "영천류"]

        # Without stripping the serial, the same data falls into one chapter per
        # episode (the bug this was written to fix).
        default_grouped = DataFrame(episode_no = 1:5, title = episodes.title)
        Frames.add_chapters!(default_grouped)
        @test default_grouped.chapter_no == 1:5
    end
end

@testset "Frames.chapter_base_prefix" begin
    @testset "chapter_base_prefix" begin
        # Keeps the leading chapter marker (up to the first `-`) and drops the
        # per-episode subtitle that follows it, unlike chapter_base which would
        # keep the whole (never-repeating) title and put every episode in its
        # own chapter.
        base_prefix = Frames.chapter_base_prefix
        @test base_prefix("1장-탈출 성공?!") == "1장"
        @test base_prefix("1장-점 한번 보고 가시죠") == "1장"
        @test base_prefix("최종장-그 후..1") == "최종장"

        # Subtitles may contain their own dash: split on the first one only.
        @test base_prefix("천기누설(IF)#1-신뢰의 대가1") == "천기누설(IF)#1"

        # No dash at all: returned unchanged (trimmed).
        @test base_prefix("무점살 완결 후기(를 빙자한 잡담)!+Q&A") ==
              "무점살 완결 후기(를 빙자한 잡담)!+Q&A"

        @test ismissing(base_prefix(missing))
    end

    @testset "regression: novel 97958 side-story splits a chapter run" begin
        # novel 97958, whose titles are "N장-<subtitle>" with a
        # distinct subtitle on every episode. Grouping with the default
        # chapter_base puts every episode in its own chapter, since no two
        # titles are ever equal and there's no trailing part marker to strip.
        episodes = Load.read_episodes(FIXTURES, 97958)
        Frames.add_chapters!(episodes; base_fn = Frames.chapter_base_prefix)
        @test first(episodes.chapter_no) == 1
        @test first(episodes.chapter_title) == "점쟁이는 자신의 미래를 볼 수 없다."
        # "1장" runs 9 consecutive episodes into a single chapter.
        @test count(==("1장"), episodes.chapter_title) == 9
        @test length(unique!(episodes.chapter_no[episodes.chapter_title .== "1장"])) == 1
        # An intervening side-story ("천기누설(IF)#1") splits the surrounding "2장"
        # run into two distinct chapters (consecutive-run semantics).
        two_jang_chapters =
            unique!(episodes.chapter_no[coalesce.(episodes.chapter_title .== "2장", false)])
        @test length(two_jang_chapters) == 2
        @test maximum(episodes.chapter_no) == 25
    end
end

@testset "Frames.chapter_base_episode_numbered" begin
    @testset "chapter_base_episode_numbered" begin
        # Strips a leading episode number ("1화 - ", "47화 – ") before delegating to
        # a chapter_base-like trailing-marker strip, so same-chapter episodes
        # numbered per-episode (not per-chapter) collapse to the same base.
        base_ep = Frames.chapter_base_episode_numbered
        @testset "leading episode number and en-dash prefix" begin
            @test base_ep("1화 - 호텔 탐색") == "호텔 탐색"
            @test base_ep("2화 - 호텔 탐색(2)") == "호텔 탐색"
            @test base_ep("47화 – 104호, 저주의 방") == "104호, 저주의 방"  # en-dash prefix
        end

        @testset "trailing Fin annotation after the part marker is also stripped" begin
            @test base_ep("10화 - 기묘한 가족 (5)  Fin") == "기묘한 가족"
            @test base_ep("218화 – 입시 명문 호텔고 Re (12) Fin(?)") ==
                  "입시 명문 호텔고 Re"
        end

        # No leading episode number: behaves like chapter_base.
        @test base_ep("프롤로그 - 이상한 꿈") == "프롤로그 - 이상한 꿈"

        # Trailing text after the marker that isn't a bare "Fin" is left alone —
        # deliberately conservative, since it's usually a real subtitle fragment.
        @test base_ep("1198화 - 수신제가치국평천하 (6) + 일부 추가.") ==
              "수신제가치국평천하 (6) + 일부 추가."

        @test ismissing(base_ep(missing))
    end

    @testset "regression: novel 102155 leading episode number collapses to one chapter" begin
        # novel 102155, titled "N화 - <subtitle>(±part marker)". With
        # the default chapter_base, the leading episode number makes every episode
        # look like a new chapter (chapter_base keeps leading numbering, since it's
        # normally what distinguishes chapters — but here it's per-episode, not
        # per-chapter). chapter_base_episode_numbered strips it first so
        # same-chapter episodes collapse together.
        episodes = Load.read_episodes(FIXTURES, 102155)
        Frames.add_chapters!(episodes; base_fn = Frames.chapter_base_episode_numbered)
        # Episodes 6-10 ("6화".."10화", incl. the "(5)  Fin"-suffixed 10화) are one
        # chapter: "101호, 저주의 방 - '기묘한 가족'".
        fin_chapter_no = episodes.chapter_no[findfirst(==(1179669), episodes.episode_no)]
        same_chapter_range =
            findfirst(==(1179669), episodes.episode_no):findfirst(
                ==(1181977),
                episodes.episode_no,
            )
        @test all(==(fin_chapter_no), episodes.chapter_no[same_chapter_range])
        @test episodes.chapter_title[first(same_chapter_range)] ==
              "101호, 저주의 방 - '기묘한 가족'"

        # Without stripping the leading episode number, the same data falls into
        # one chapter per episode (the bug this was written to fix).
        default_grouped = Load.read_episodes(FIXTURES, 102155)
        Frames.add_chapters!(default_grouped)
        @test length(unique(default_grouped.chapter_no[same_chapter_range])) ==
              length(same_chapter_range)
    end
end

@testset "Frames.chapter_base_trailing_num" begin
    @testset "chapter_base_trailing_num" begin
        # Strips a trailing bare number (just whitespace before it, no paren/dash/
        # hash), unlike chapter_base whose _PART_MARKER requires that punctuation.
        base_trailing = Frames.chapter_base_trailing_num
        @test base_trailing("마고열 1") == "마고열"
        @test base_trailing("마고열 12") == "마고열"
        @test base_trailing("나이트런 1") == "나이트런"

        # No trailing number: returned unchanged (trimmed).
        @test base_trailing("두 개의 기도") == "두 개의 기도"

        # A trailing parenthesised number is left alone — chapter_base already
        # handles that shape, and this function only targets the punctuation-free
        # form.
        @test base_trailing("각성(1)") == "각성(1)"

        @test ismissing(base_trailing(missing))
    end

    @testset "regression: bare trailing episode-within-chapter number collapses" begin
        # A novel that reuses the chapter title verbatim per episode,
        # appending only a bare episode-within-chapter number ("마고열 1", "마고열
        # 2", ...). With the default chapter_base, the trailing number carries no
        # recognized marker punctuation, so every episode looks like a new chapter.
        episodes = DataFrame(
            episode_no = 1:6,
            title = [
                "두 개의 기도",
                "나이트런 1",
                "나이트런 2",
                "나이트런 3",
                "메모라이즈 1",
                "메모라이즈 2",
            ],
        )
        Frames.add_chapters!(episodes; base_fn = Frames.chapter_base_trailing_num)
        @test episodes.chapter_no == vcat(fill(1, 1), fill(2, 3), fill(3, 2))
        @test episodes.chapter_title == [
            "두 개의 기도",
            "나이트런",
            "나이트런",
            "나이트런",
            "메모라이즈",
            "메모라이즈",
        ]

        # Without stripping the trailing number, the same data falls into one
        # chapter per episode (the bug this was written to fix).
        default_grouped = DataFrame(episode_no = 1:6, title = episodes.title)
        Frames.add_chapters!(default_grouped)
        @test default_grouped.chapter_no == 1:6
    end
end

@testset "Frames.add_chapter_length!" begin
    @testset "computes per-chapter episode counts" begin
        episodes = Load.read_episodes(FIXTURES, 777)
        Frames.add_chapters!(episodes)
        Frames.add_chapter_length!(episodes)
        # Same chapter sizes as the add_chapters! testset: 1,3,3,2,2,1
        @test episodes.chapter_length ==
              vcat(fill(1, 1), fill(3, 3), fill(3, 3), fill(2, 2), fill(2, 2), fill(1, 1))
        @test episodes.chapter_length[episodes.chapter_no .== 2] == fill(3, 3)
    end

    @testset "empty frame gets an empty column rather than erroring" begin
        e = DataFrame(episode_no = Int[], title = String[])
        Frames.add_chapters!(e)
        Frames.add_chapter_length!(e)
        @test isempty(e)
        @test hasproperty(e, :chapter_length)
    end
end
