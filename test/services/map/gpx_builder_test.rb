# frozen_string_literal: true

require "test_helper"

# The GPX representation of drawn routes (technote.ROUTE-DRAW.md §9): the
# calculated geometry becomes a first-class GPX the existing machinery
# (detail page, embed, download, joins) reads like any uploaded ride.
class Map::GpxBuilderTest < ActiveSupport::TestCase
  test "builds a valid GPX 1.1 track with elevations" do
    gpx = Map::GpxBuilder.build(
      title: "Coastal Loop",
      points: [ [ 8.7100123, 49.4100123, 110.5 ], [ 8.712, 49.412, nil ], [ 8.714, 49.414, 130.0 ] ]
    )

    doc = Nokogiri::XML(gpx)
    doc.remove_namespaces!
    assert_equal "1.1", doc.at_xpath("//gpx")["version"]
    assert_equal "expl.pro", doc.at_xpath("//gpx")["creator"]
    assert_equal "Coastal Loop", doc.at_xpath("//trk/name").text
    assert_equal 3, doc.xpath("//trkpt").size
    first = doc.xpath("//trkpt").first
    assert_in_delta 49.4100123, first["lat"].to_f, 1e-7
    assert_in_delta 8.7100123, first["lon"].to_f, 1e-7
    assert_in_delta 110.5, doc.xpath("//trkpt/ele").first.text.to_f, 0.01
    # A point without elevation carries no <ele> element, not a fake one.
    assert_equal 2, doc.xpath("//trkpt/ele").size
  end

  test "escapes XML-unsafe titles and includes descriptions" do
    gpx = Map::GpxBuilder.build(
      title: "Heiderand & <Cliffs> \"Route\"",
      description: "Along the coast & back",
      points: [ [ 8.71, 49.41, 100.0 ], [ 8.712, 49.412, 110.0 ] ]
    )

    doc = Nokogiri::XML(gpx)
    doc.remove_namespaces!
    assert_equal 'Heiderand & <Cliffs> "Route"', doc.at_xpath("//trk/name").text
    assert_equal "Along the coast & back", doc.at_xpath("//metadata/desc").text
  end
end
