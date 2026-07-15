const FIXTURE_EPISODE_COUNT = 2
const DELETED_NOVEL_NO = 2

@testset "Load" begin
    manifest = Load.read_manifest(FIXTURES, NOVEL_NO)
    @test manifest.novel_no == NOVEL_NO
    @test manifest.episode_count == FIXTURE_EPISODE_COUNT
    @test iszero(manifest.review_count)
    @test manifest.files == ["episodes.csv", "reviews.csv"]

    episodes = Load.read_episodes(FIXTURES, NOVEL_NO)
    @test nrow(episodes) == manifest.episode_count
    @test eltype(episodes.episode_no) == Int
    @test eltype(episodes.is_free) == Bool
    @test first(episodes.reg_date) == Date(2023, 3, 23)
    @test episodes.count_view == [356, 110]

    reviews = Load.read_reviews(FIXTURES, NOVEL_NO)
    @test isempty(reviews)

    data = Load.load(FIXTURES, NOVEL_NO)
    @test data.manifest.novel_no == NOVEL_NO
    @test data.manifest.episode_count == FIXTURE_EPISODE_COUNT
    @test nrow(data.episodes) == data.manifest.episode_count
    @test isempty(data.reviews)
end

@testset "_parse_reg_date" begin
    @test Load._parse_reg_date(missing) === missing
    @test Load._parse_reg_date("") === missing
    @test Load._parse_reg_date("23.03.23") == Date(2023, 3, 23)
    @test Load._parse_reg_date("99.12.31") == Date(2099, 12, 31)
end

@testset "Load deleted novel (empty episodes.csv)" begin
    # A novel removed from Novelpia (episode_count == 0) writes a
    # completely empty episodes.csv with no header row. read_episodes
    # normalizes this to the same typed-but-empty schema as a populated
    # file, so downstream Frames functions (sort! on :episode_no etc.)
    # don't need to special-case a columnless frame.
    manifest = Load.read_manifest(FIXTURES, DELETED_NOVEL_NO)
    @test iszero(manifest.episode_count)

    episodes = Load.read_episodes(FIXTURES, DELETED_NOVEL_NO)
    @test isempty(episodes)
    @test Set(names(episodes)) ==
          Set(["count_view", "episode_no", "is_adult", "is_free", "reg_date", "title"])
    @test eltype(episodes.episode_no) == Int
    @test eltype(episodes.is_free) == Bool

    Frames.add_retention!(episodes)
    Frames.add_cumulative_views!(episodes)
    Frames.add_view_diff!(episodes)
    Frames.add_chapters!(episodes)
    Frames.add_chapter_length!(episodes)
    @test isempty(episodes)

    data = Load.load(FIXTURES, DELETED_NOVEL_NO)
    @test isempty(data.episodes)
    @test isempty(data.reviews)
end
