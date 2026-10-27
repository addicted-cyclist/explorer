# frozen_string_literal: true

require "test_helper"

# Unit tests for the Mapbox::StaticImage service behind the route thumbs.
# The payload cases pin the GeoJSON LineString overlay — exact [lon, lat]
# coordinates with SimpleStyle stroke properties (the path/polyline overlay
# was dropped: Mapbox 422'd even its own documented examples).
class Mapbox::StaticImageTest < ActiveSupport::TestCase
  test "line_geojson builds a SimpleStyle LineString Feature in [lon, lat] order" do
    payload = Mapbox::StaticImage.send(:line_geojson, [ [ -120.2, 38.5 ], [ -120.95, 40.7 ] ])

    assert_equal '{"type":"Feature","properties":{"stroke":"#e11d48","stroke-width":8},' \
                 '"geometry":{"type":"LineString","coordinates":[[-120.2,38.5],[-120.95,40.7]]}}', payload
  end

  test "build_url renders the documented static images request shape" do
    with_mapbox_stubbed do
      url = Mapbox::StaticImage.send(:build_url, [ [ -120.2, 38.5 ], [ -120.95, 40.7 ] ])

      # 2x outdoors render with an auto fit, a GeoJSON overlay in the app's
      # track color percent-encoded to survive its quotes/braces/# ("#" ->
      # %23), and the token + auto-fit padding (CSS vertical,horizontal) as
      # query parameters.
      payload = '{"type":"Feature","properties":{"stroke":"#e11d48","stroke-width":8},' \
                '"geometry":{"type":"LineString","coordinates":[[-120.2,38.5],[-120.95,40.7]]}}'
      expected = "https://api.mapbox.com/styles/v1/mapbox/outdoors-v12/static/" \
                 "geojson(#{ERB::Util.url_encode(payload)})/auto/720x240@2x" \
                 "?access_token=test-token&padding=40%2C86"

      assert_equal expected, url
    end
  end

  test "downsample keeps the track ends and caps the point count" do
    coords = (0...1000).map { |i| [ i * 0.001, i * 0.001 ] }
    sampled = Mapbox::StaticImage.send(:downsample, coords)

    assert_operator sampled.size, :<=, Mapbox::StaticImage::MAX_POINTS
    assert_equal coords.first, sampled.first
    assert_equal coords.last, sampled.last
    # Small tracks pass through untouched (same object, no defensive copy).
    small = coords.first(5)
    assert_same small, Mapbox::StaticImage.send(:downsample, small)
  end

  test "attachable requires at least two points" do
    with_mapbox_stubbed do
      assert_nil Mapbox::StaticImage.attachable(nil)
      assert_nil Mapbox::StaticImage.attachable([])
      assert_nil Mapbox::StaticImage.attachable([ [ 8.54, 47.37 ] ])
    end
  end

  test "attachable returns nil without a token, without ever fetching" do
    with_mapbox_stubbed(token: false) do
      assert_nil Mapbox::StaticImage.access_token
      assert_nil Mapbox::StaticImage.attachable([ [ 8.54, 47.37 ], [ 8.55, 47.38 ] ])
    end
  end

  test "attachable returns nil when the render request fails" do
    with_mapbox_stubbed(bytes: nil) do
      assert_nil Mapbox::StaticImage.attachable([ [ 8.54, 47.37 ], [ 8.55, 47.38 ] ])
    end
  end

  test "attachable wraps the fetched render in an Active Storage attachable" do
    with_mapbox_stubbed do
      attachable = Mapbox::StaticImage.attachable([ [ 8.54, 47.37 ], [ 8.55, 47.38 ] ])

      assert_equal "image/png", attachable[:content_type]
      assert_equal "static-map.png", attachable[:filename].to_s
      assert_equal STATIC_MAP_PNG_STUB, attachable[:io].read
    end
  end
end
