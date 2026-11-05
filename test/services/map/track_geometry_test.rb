# frozen_string_literal: true

require "test_helper"

# Unit tests for the stored map-geometry derivation (app/services/map/
# track_geometry.rb): the drawn line resamples evenly by DISTANCE — never by
# recording index, which inherits the device's density quirks — the vertex
# budget is capped, route ends always survive, and undrawable tracks yield
# nil geometry values while the hash itself always returns.
class Map::TrackGeometryTest < ActiveSupport::TestCase
  test "downsample spreads vertices evenly by distance, not by recording density" do
    # 700 points: a dense 600-point cluster covering only ~5% of the track's
    # ground distance (a device waiting at the start), then 100 points spread
    # across the remaining ~95%. Sampling by index gives that head ~86% of
    # the vertices and starves the rest of the line.
    points = 600.times.map { |i| [ 8.0, 47.0 + i * 0.0000083, 100.0 ] } +
             100.times.map { |i| [ 8.0, 47.00498 + i * 0.0009, 100.0 ] }

    sampled = Map::TrackGeometry.downsample(points)

    assert_operator sampled.size, :<=, Map::TrackGeometry::MAX_POINTS
    assert_equal points.first, sampled.first
    assert_equal points.last, sampled.last

    head_share = sampled.count { |_, lat, _| lat <= 47.00498 }.to_f / sampled.size
    assert_operator head_share, :>=, 0.02, "the dense head lost all its vertices"
    assert_operator head_share, :<, 0.3,
                    "vertices cluster where the recording was dense (index-sampling regression)"
    # Even by ground distance: consecutive vertex gaps stay within one order
    # of magnitude of each other (index-sampling's dense head vs sparse tail
    # spans two). The tail's own 100m input spacing is the floor here — a
    # subset resampler never invents vertices, so the budget may come in
    # under MAX_POINTS when the recording is sparser than the even share.
    gaps = sampled.each_cons(2).map do |(lon1, lat1), (lon2, lat2)|
      Map::TrackGeometry.haversine_m([ lon1, lat1 ], [ lon2, lat2 ])
    end
    assert_operator gaps.max, :<=, gaps.min * 6
  end

  test "downsample keeps short tracks verbatim" do
    points = [ [ 8.5417, 47.3769, 100.0 ], [ 8.5427, 47.3779, 150.0 ], [ 8.5437, 47.3789, 120.0 ] ]

    assert_equal points, Map::TrackGeometry.downsample(points)
  end

  test "downsample fills the vertex budget and keeps the ends on long tracks" do
    points = 2000.times.map { |i| [ 8.0, 47.0 + i * 0.001, i.to_f ] }

    sampled = Map::TrackGeometry.downsample(points)

    assert_equal Map::TrackGeometry::MAX_POINTS, sampled.size
    assert_equal points.first, sampled.first
    assert_equal points.last, sampled.last
  end

  test "downsample degrades a zero-distance track to its ends" do
    # A device parked at one spot: every point identical, zero ground
    # distance — nothing to distribute, so only the ends survive.
    points = Array.new(500) { [ 8.5417, 47.3769, 100.0 ] }

    sampled = Map::TrackGeometry.downsample(points)

    assert_equal [ points.first, points.last ], sampled
  end

  test "build returns nil geometry values for undrawable tracks" do
    assert_equal({ "coordinates" => nil, "profile" => nil }, Map::TrackGeometry.build([]))
    assert_equal({ "coordinates" => nil, "profile" => nil },
                 Map::TrackGeometry.build([ [ 8.5417, 47.3769, 100.0 ] ]))
  end

  test "build caps the line and the profile chart on a long elevated track" do
    points = 2000.times.map { |i| [ 8.0, 47.0 + i * 0.001, (100 + i).to_f ] }

    geometry = Map::TrackGeometry.build(points)

    assert_equal Map::TrackGeometry::MAX_POINTS, geometry["coordinates"].size
    assert_operator geometry["profile"].size, :<=, Map::TrackGeometry::PROFILE_BUCKETS
    assert_in_delta 100.0, geometry["profile"].first[1], 0.01
    assert_in_delta 2099.0, geometry["profile"].last[1], 0.01
    geometry["profile"].each_cons(2) { |(d1, _), (d2, _)| assert_operator d2, :>=, d1 }
  end
end
