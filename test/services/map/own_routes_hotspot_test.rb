# frozen_string_literal: true

require "test_helper"

# The server-side "most-ridden place" (technote.MYMAP-FEATURE.md §3.1/§3.2):
# every parsed route's bounds-box center is one vote, the best-attended
# route's 5 km neighbourhood wins, and its union box comes back as
# [w, s, e, n] for the map's initial viewport and the heart control. Own
# routes load per viewport now, so the scan must happen server-side.
class Map::OwnRoutesHotspotTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
  end

  test "returns nil when the rider has no parsed routes" do
    @user.routes.create!(source: "upload", title: "Unparsed")

    assert_nil Map::OwnRoutesHotspot.bounds(@user.routes)
  end

  test "a lone route anchors itself — its own box comes back" do
    boxed_route("Solo ride", 8.0, 47.0, 8.5, 47.5)

    assert_equal [ 8.0, 47.0, 8.5, 47.5 ],
                 Map::OwnRoutesHotspot.bounds(@user.routes)
  end

  test "a tight cluster beats a distant long tour and unions the group's boxes" do
    # Two short city rides ~4 km apart — one hotspot …
    boxed_route("City ride 1", 8.50, 47.30, 8.52, 47.32)
    boxed_route("City ride 2", 8.53, 47.33, 8.55, 47.35)
    # … and one alpine tour roughly 120 km away.
    boxed_route("Long tour", 9.80, 46.50, 9.90, 46.60)

    assert_equal [ 8.50, 47.30, 8.55, 47.35 ],
                 Map::OwnRoutesHotspot.bounds(@user.routes)
  end

  test "the route with the most neighbours anchors the group" do
    # A 3-route chain: the middle ride sits within 5 km of both ends while
    # the ends are ~6 km apart — the middle one anchors, and the union spans
    # all three boxes.
    boxed_route("West end", 8.00, 47.00, 8.01, 47.01)
    boxed_route("Middle", 8.03, 47.02, 8.04, 47.03)
    boxed_route("East end", 8.06, 47.04, 8.07, 47.05)

    assert_equal [ 8.00, 47.00, 8.07, 47.05 ],
                 Map::OwnRoutesHotspot.bounds(@user.routes)
  end

  test "ties resolve to the first route (stable :id order)" do
    first = boxed_route("First spot", 8.0, 47.0, 8.1, 47.1)
    boxed_route("Far spot", 0.0, 10.0, 0.1, 10.1)

    # Two lone routes, no group anywhere: the earlier :id wins the anchor.
    assert_equal [ first.min_lon, first.min_lat, first.max_lon, first.max_lat ],
                 Map::OwnRoutesHotspot.bounds(@user.routes)
  end

  private

  # A route with usable bounds columns — exactly what the hotspot scan
  # reads. No GPX attachment needed: the query touches the bounds columns
  # only.
  def boxed_route(title, west, south, east, north)
    @user.routes.create!(source: "upload", title: title,
                         min_lon: west, min_lat: south, max_lon: east, max_lat: north)
  end
end
