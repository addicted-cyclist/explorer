# frozen_string_literal: true

require "test_helper"

# Unit tests for the "Find new routes" filter engine (Map::RouteFinder):
# sport categories match free-text sport_type values case-insensitively,
# numeric ranges are inclusive, and routes with NULL stats drop out of an
# active comparison — while a filter-free call returns the scope untouched
# and unknown filter keys are dropped (no arbitrary column filters).
class Map::RouteFinderTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
    @road = @user.routes.create!(source: "upload", title: "Road ride",
                                 sport_type: "Road Cycling", distance: 48.4,
                                 elevation_gain: 820.0, duration: 7200)
    @gravel = @user.routes.create!(source: "upload", title: "Gravel grind",
                                   sport_type: "Gravel 50k", distance: 92.0,
                                   elevation_gain: 1500.0, duration: 14_400)
    @mtb = @user.routes.create!(source: "upload", title: "Mountain singletrack",
                                sport_type: "Mountain biking", distance: 25.0,
                                elevation_gain: 400.0, duration: 5400)
    @mtb_abbrev = @user.routes.create!(source: "upload", title: "MTB shuttle",
                                       sport_type: "MTB", distance: 30.0,
                                       elevation_gain: 600.0, duration: 6300)
    @hike = @user.routes.create!(source: "upload", title: "Hike",
                                 sport_type: "Hike", distance: 12.0,
                                 elevation_gain: 300.0, duration: 10_800)
    @unmeasured = @user.routes.create!(source: "upload", title: "Not parsed yet")
  end

  test "sport categories match their free-text values case-insensitively" do
    # @unmeasured has a blank sport_type, which the UI labels "Road bike" —
    # so it IS a road match now (see the blank-sport_type tests below).
    assert_equal ids(@road, @unmeasured), matching_ids(sport_type: "road")
    assert_equal ids(@gravel), matching_ids(sport_type: "gravel")
    assert_equal ids(@mtb, @mtb_abbrev), matching_ids(sport_type: "mtb")
  end

  # Regression: a route with a BLANK sport_type renders as "Road bike" in the
  # UI (RoutesHelper#sport_type_label / map drawer fallback). Before this
  # contract the badge and the filter disagreed — only the handful of routes
  # literally containing "road" matched, so the map showed 27 routes badged
  # "Road bike" but returned 9 under the Road filter.
  test "blank sport_type matches the default category, like its badge says" do
    blank = @user.routes.create!(source: "upload", title: "No sport", sport_type: "")
    nil_sport = @user.routes.create!(source: "upload", title: "Nil sport")

    road = matching_ids(sport_type: "road")
    assert_includes road, blank.id
    assert_includes road, nil_sport.id
    assert_includes road, @unmeasured.id
  end

  test "blank sport_type does not leak into non-default categories" do
    blank = @user.routes.create!(source: "upload", title: "No sport", sport_type: "")

    assert_not_includes matching_ids(sport_type: "gravel"), blank.id
    assert_not_includes matching_ids(sport_type: "gravel"), @unmeasured.id
    assert_not_includes matching_ids(sport_type: "mtb"), @unmeasured.id
  end

  test "the default category is declared exactly once in SPORT_CATEGORIES" do
    defaults = Map::RouteFinder::SPORT_CATEGORIES.select { |_, c| c[:default] }.keys

    assert_equal 1, defaults.size
    assert_equal "road", Map::RouteFinder::SPORT_DEFAULT_CATEGORY
  end

  test "a hybrid sport_type matches every category it names" do
    hybrid = @user.routes.create!(source: "upload", title: "Hybrid",
                                  sport_type: "Road/Gravel")

    assert_includes matching_ids(sport_type: "road"), hybrid.id
    assert_includes matching_ids(sport_type: "gravel"), hybrid.id
    assert_not_includes matching_ids(sport_type: "mtb"), hybrid.id
  end

  test "unrelated sports fall out of a category filter" do
    assert_not_includes matching_ids(sport_type: "road"), @hike.id
    assert_not_includes matching_ids(sport_type: "mtb"), @gravel.id
  end

  test "distance range keeps routes inside the window and drops unmeasured ones" do
    assert_equal ids(@gravel), matching_ids(distance_min: 50)
    assert_equal ids(@road, @mtb, @mtb_abbrev, @hike), matching_ids(distance_max: 50)
    assert_equal ids(@road, @mtb, @mtb_abbrev),
                 matching_ids(distance_min: 20, distance_max: 50)
  end

  test "elevation cap is inclusive" do
    assert_equal ids(@mtb, @mtb_abbrev, @hike), matching_ids(elevation_max: 700)
    assert_equal ids(@road, @gravel, @mtb, @mtb_abbrev, @hike),
                 matching_ids(elevation_max: 1500)
  end

  test "duration range filters in seconds, bounds inclusive" do
    assert_equal ids(@road, @gravel, @hike), matching_ids(duration_min: 7000)
    assert_equal ids(@mtb, @mtb_abbrev), matching_ids(duration_max: 7000)
    assert_equal ids(@mtb, @mtb_abbrev),
                 matching_ids(duration_min: 5000, duration_max: 7000)
  end

  test "no filters returns the scope untouched, unmeasured routes included" do
    assert_equal 6, Map::RouteFinder.call(@user.routes, filters: {}).count
  end

  # #6: the safety property is "unknown keys never reach the query", proven by
  # inspecting the SQL AND by a real filter still applying — not merely "the
  # count didn't move".
  test "unknown filter keys are rejected, never silently applied" do
    assert_raises(ArgumentError) do
      Map::RouteFinder.call(@user.routes, filters: { user_id: 99_999 })
    end
  end

  test "a real filter still applies alongside a rejected key" do
    # The base scope (@user.routes) legitimately carries its own user_id
    # ownership clause — what must never appear is a user_id constraint
    # smuggled in from the FILTERS. Assert the distance bound landed and that
    # the filter hash rejected the extra key before touching the query.
    assert_raises(ArgumentError) do
      Map::RouteFinder.call(@user.routes, filters: { distance_min: 50, user_id: 1 })
    end
    assert_equal ids(@gravel), matching_ids(distance_min: 50)
  end

  private

  def matching_ids(filters)
    Map::RouteFinder.call(@user.routes, filters: filters).order(:id).pluck(:id)
  end

  # Expected ids for +routes+, in the SAME order matching_ids returns them
  # (creation order == id order for these fixtures). Keeps assertions free of
  # scattered `.sort` calls — the ordering under test is the query's, not the
  # expectation's.
  def ids(*routes)
    routes.map(&:id)
  end
end
