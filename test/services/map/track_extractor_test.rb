# frozen_string_literal: true

require "test_helper"

# Unit tests for the fast GPX point extractor behind the Map page's stored
# geometry (app/services/map/track_extractor.rb): [lon, lat, ele] triplets in
# document order, rounding applied at the source, ele-less points carrying
# nil, and malformed input raising ParseError — never a silent 0,0 coordinate.
class Map::TrackExtractorTest < ActiveSupport::TestCase
  test "extracts [lon, lat, ele] triplets in document order from the fixture" do
    points = Map::TrackExtractor.extract(Rails.root.join("test/fixtures/files/exploration.gpx"))

    assert_equal [ [ 8.5417, 47.3769, 100.0 ], [ 8.5427, 47.3779, 150.0 ], [ 8.5437, 47.3789, 120.0 ] ],
                 points
  end

  test "reads an open IO as well as a path" do
    path = Rails.root.join("test/fixtures/files/exploration.gpx")
    from_path = Map::TrackExtractor.extract(path)
    from_file = path.open { |file| Map::TrackExtractor.extract(file) }
    from_string_io = Map::TrackExtractor.extract(StringIO.new(path.read))

    assert_equal from_path, from_file
    assert_equal from_path, from_string_io
  end

  test "rounds lon/lat to 5 decimals and elevation to 1 at the source" do
    points = extract(<<~POINT)
      <trkpt lat="47.37691234567" lon="8.54179876543">
        <ele>100.04</ele>
      </trkpt>
    POINT

    assert_equal [ [ 8.5418, 47.37691, 100.0 ] ], points
  end

  test "ele-less trackpoints carry nil elevation and still draw" do
    points = extract(<<~POINTS)
      <trkpt lat="47.3769" lon="8.5417"/>
      <trkpt lat="47.3779" lon="8.5427">
        <time>2026-09-09T08:15:00Z</time>
      </trkpt>
    POINTS

    assert_equal [ [ 8.5417, 47.3769, nil ], [ 8.5427, 47.3779, nil ] ], points
  end

  test "skips trackpoints without usable coordinates instead of emitting 0,0" do
    points = extract(<<~POINTS)
      <trkpt lat="47.3769" lon="8.5417"><ele>100</ele></trkpt>
      <trkpt><ele>10</ele></trkpt>
      <trkpt lat="" lon=""><ele>20</ele></trkpt>
    POINTS

    assert_equal [ [ 8.5417, 47.3769, 100.0 ] ], points
  end

  test "waypoints and routes never contribute points" do
    points = extract(<<~INNER)
      <wpt lat="47.0000" lon="8.0000"><ele>999</ele></wpt>
      <trk>
        <trkseg>
          <trkpt lat="47.3769" lon="8.5417"><ele>100</ele></trkpt>
        </trkseg>
      </trk>
      <rte>
        <rtept lat="47.5000" lon="8.5000"><ele>888</ele></rtept>
      </rte>
    INNER

    assert_equal [ [ 8.5417, 47.3769, 100.0 ] ], points
  end

  test "a waypoint elevation never bleeds into the following trackpoint" do
    points = extract(<<~INNER)
      <wpt lat="47.0000" lon="8.0000"><ele>999</ele></wpt>
      <trk>
        <trkseg>
          <trkpt lat="47.3769" lon="8.5417"/>
        </trkseg>
      </trk>
    INNER

    assert_equal [ [ 8.5417, 47.3769, nil ] ], points
  end

  test "prefixed-namespace documents still match their trackpoints" do
    points = Map::TrackExtractor.extract(<<~GPX)
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx xmlns:gpxx="http://www.topografix.com/GPX/1/1" version="1.1">
        <gpxx:trk>
          <gpxx:trkseg>
            <gpxx:trkpt lat="47.3769" lon="8.5417"><gpxx:ele>100</gpxx:ele></gpxx:trkpt>
          </gpxx:trkseg>
        </gpxx:trk>
      </gpx>
    GPX

    assert_equal [ [ 8.5417, 47.3769, 100.0 ] ], points
  end

  test "a document without trackpoints yields an empty array" do
    assert_empty extract("<metadata><name>Empty ride</name></metadata>")
  end

  test "malformed XML raises ParseError" do
    error = assert_raises(Map::TrackExtractor::ParseError) do
      Map::TrackExtractor.extract("<gpx><trk><trkseg>")
    end

    assert_match(/extraction failed/, error.message)
  end

  private

  def extract(inner)
    Map::TrackExtractor.extract(gpx_document(inner))
  end

  def gpx_document(inner)
    <<~GPX
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1" creator="explorer-test-suite" xmlns="http://www.topografix.com/GPX/1/1">
        #{inner}
      </gpx>
    GPX
  end
end
