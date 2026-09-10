# frozen_string_literal: true

require "test_helper"

class RouteTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
    @gpx_path = Rails.root.join("test/fixtures/files/exploration.gpx")
    @named_gpx_path = Rails.root.join("test/fixtures/files/named_route.gpx")
  end

  # ---- validations -------------------------------------------------------

  test "requires a title" do
    route = @user.routes.build(source: "upload", title: "")
    assert_not route.valid?
    assert_includes route.errors[:title], "can't be blank"
  end

  test "caps the title at 200 characters" do
    assert_not @user.routes.build(source: "upload", title: "a" * 201).valid?
    assert @user.routes.build(source: "upload", title: "a" * 200).valid?
  end

  test "only accepts known sources" do
    route = @user.routes.build(source: "strava", title: "Ride")
    assert_not route.valid?
    assert_includes route.errors[:source], "is not included in the list"
  end

  test "only accepts known tiers" do
    route = @user.routes.build(source: "upload", title: "Ride", tier: "Impossible")
    assert_not route.valid?
    assert_includes route.errors[:tier], "is not included in the list"
  end

  # ---- source predicates ---------------------------------------------------

  test "google_drive? and upload? reflect the route source" do
    drive_route = @user.routes.build(source: "google_drive", title: "Drive route")
    uploaded_route = @user.routes.build(source: "upload", title: "Uploaded route")

    assert_predicate drive_route, :google_drive?
    assert_not_predicate drive_route, :upload?
    assert_predicate uploaded_route, :upload?
    assert_not_predicate uploaded_route, :google_drive?
  end

  # ---- parse_gpx! --------------------------------------------------------

  test "parse_gpx! fills stats and track svg while keeping an existing title" do
    route = @user.routes.create!(source: "upload", title: "exploration")
    route.gpx_file.attach(io: File.open(@gpx_path), filename: "exploration.gpx", content_type: "application/gpx+xml")

    route.parse_gpx!
    route.reload

    assert_operator route.distance, :>, 0
    assert_operator route.distance, :<, 5_000
    assert_equal 1_800, route.duration
    assert_in_delta 50.0, route.elevation_gain, 0.01
    assert_in_delta 30.0, route.elevation_loss, 0.01
    assert_in_delta 100.0, route.min_elevation, 0.01
    assert_in_delta 150.0, route.max_elevation, 0.01
    assert_equal "exploration", route.title
    assert_track_svg route.track_svg
  end

  test "parse_gpx! falls back to the gpx metadata name when the title is blank" do
    route = @user.routes.create!(source: "upload", title: "provisional")
    route.gpx_file.attach(io: File.open(@named_gpx_path), filename: "alpine-loop.gpx", content_type: "application/gpx+xml")
    route.title = nil

    route.parse_gpx!

    assert_equal "Alpine Loop", route.title
  end

  test "parse_gpx! falls back to the filename when neither title nor metadata name is present" do
    route = @user.routes.create!(source: "upload", title: "provisional")
    route.gpx_file.attach(io: File.open(@gpx_path), filename: "exploration.gpx", content_type: "application/gpx+xml")
    route.title = nil

    route.parse_gpx!

    assert_equal "exploration", route.title
  end

  test "parse_gpx! is a no-op without an attached gpx file" do
    route = @user.routes.create!(source: "upload", title: "Manual entry")

    route.parse_gpx!

    assert_equal "Manual entry", route.title
    assert_nil route.distance
  end

  private

  # The track thumbnail is an SVG path fitted into the 100x60 viewBox:
  # "M x,y L x,y ..." with every coordinate inside the box.
  def assert_track_svg(svg)
    assert_not_nil svg
    assert_match(/\AM[\d., ]+L[\d., ]+\z/, svg)

    svg.scan(/-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?/).each do |pair|
      x, y = pair.split(",").map(&:to_f)
      assert x.between?(0, Route::TRACK_SVG_VIEWBOX.split(" ")[2].to_f)
      assert y.between?(0, Route::TRACK_SVG_VIEWBOX.split(" ")[3].to_f)
    end
  end
end
