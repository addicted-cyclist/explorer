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
    assert_equal [ @road.id ], matching_ids(sport_type: "road")
    assert_equal [ @gravel.id ], matching_ids(sport_type: "gravel")
    assert_equal [ @mtb.id, @mtb_abbrev.id ].sort, matching_ids(sport_type: "mtb")
  end

  test "unrelated sports fall out of a category filter" do
    assert_not_includes matching_ids(sport_type: "road"), @hike.id
    assert_not_includes matching_ids(sport_type: "mtb"), @gravel.id
  end

  test "distance range keeps routes inside the window and drops unmeasured ones" do
    assert_equal [ @gravel.id ], matching_ids(distance_min: 50)
    assert_equal [ @road.id, @mtb.id, @mtb_abbrev.id, @hike.id ].sort,
                 matching_ids(distance_max: 50)
    assert_equal [ @road.id, @mtb.id, @mtb_abbrev.id ].sort,
                 matching_ids(distance_min: 20, distance_max: 50)
  end

  test "elevation cap is inclusive" do
    assert_equal [ @mtb.id, @mtb_abbrev.id, @hike.id ].sort,
                 matching_ids(elevation_max: 700)
    assert_equal [ @road.id, @gravel.id, @mtb.id, @mtb_abbrev.id, @hike.id ].sort,
                 matching_ids(elevation_max: 1500)
  end

  test "duration range filters in seconds, bounds inclusive" do
    assert_equal [ @road.id, @gravel.id, @hike.id ].sort,
                 matching_ids(duration_min: 7000)
    assert_equal [ @mtb.id, @mtb_abbrev.id ].sort,
                 matching_ids(duration_max: 7000)
    assert_equal [ @mtb.id, @mtb_abbrev.id ].sort,
                 matching_ids(duration_min: 5000, duration_max: 7000)
  end

  test "no filters returns the scope untouched, unmeasured routes included" do
    assert_equal 6, Map::RouteFinder.call(@user.routes, filters: {}).count
  end

  test "unknown filter keys are ignored" do
    assert_equal 6, Map::RouteFinder.call(
      @user.routes, filters: { user_id: 99_999, tier: "Hard" }
    ).count
  end

  private

  def matching_ids(filters)
    Map::RouteFinder.call(@user.routes, filters: filters).order(:id).pluck(:id)
  end
end
