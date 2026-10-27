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

  # ---- public visibility (Phase 9 share) -----------------------------------

  test "publicly_viewable? is true for a route scheduled on a public calendar" do
    @user.update!(calendar_public: true)
    route = @user.routes.create!(source: "upload", title: "Shared loop")
    @user.calendar_entries.create!(route: route, scheduled_on: Date.current + 2,
                                   start_time: "08:00", end_time: "09:00")

    assert_predicate route, :publicly_viewable?
  end

  test "publicly_viewable? is false while the owner's calendar is private" do
    route = @user.routes.create!(source: "upload", title: "Private loop")
    @user.calendar_entries.create!(route: route, scheduled_on: Date.current + 2,
                                   start_time: "08:00", end_time: "09:00")

    assert_not_predicate route, :publicly_viewable?
  end

  test "publicly_viewable? is false for an unscheduled library route even on a public calendar" do
    @user.update!(calendar_public: true)
    route = @user.routes.create!(source: "upload", title: "Shelf loop")

    assert_not_predicate route, :publicly_viewable?
  end

  test "publicly_viewable? flips false when the ride is unscheduled" do
    @user.update!(calendar_public: true)
    route = @user.routes.create!(source: "upload", title: "Shared loop")
    entry = @user.calendar_entries.create!(route: route, scheduled_on: Date.current + 2,
                                           start_time: "08:00", end_time: "09:00")

    assert_predicate route, :publicly_viewable?
    entry.destroy!
    assert_not_predicate route.reload, :publicly_viewable?
  end

  # ---- parse_gpx! --------------------------------------------------------

  test "parse_gpx! fills stats while keeping an existing title" do
    route = @user.routes.create!(source: "upload", title: "exploration")
    route.gpx_file.attach(io: File.open(@gpx_path), filename: "exploration.gpx", content_type: "application/gpx+xml")

    route.parse_gpx!
    route.reload

    assert_operator route.distance, :>, 0
    assert_operator route.distance, :<, 5_000
    assert_equal 1_800, route.duration
    # The 3-point track is shorter than the 5-point smoothing window, so
    # every smoothed elevation collapses to the series mean (123.33) — the
    # once-raw deltas (100 -> 150 -> 120) flatten to zero gain/loss. Min/max
    # altitude stay on the raw readings.
    assert_in_delta 0.0, route.elevation_gain, 0.01
    assert_in_delta 0.0, route.elevation_loss, 0.01
    assert_in_delta 100.0, route.min_elevation, 0.01
    assert_in_delta 150.0, route.max_elevation, 0.01
    assert_equal "exploration", route.title
    # No Mapbox token in the test env: the thumb fetch is a silent no-op (no
    # network, no raise) and the route keeps its fallback icon. The attach
    # path is covered separately with a stubbed fetch.
    assert_not route.static_map.attached?
  end

  test "parse_gpx! attaches the static map thumb when the render is fetchable" do
    with_mapbox_stubbed do
      route = @user.routes.create!(source: "upload", title: "Thumb ride")
      route.gpx_file.attach(io: File.open(@gpx_path), filename: "exploration.gpx", content_type: "application/gpx+xml")

      route.parse_gpx!
      route.reload

      assert route.static_map.attached?
      assert_equal "image/png", route.static_map.content_type
      assert_equal "static-map.png", route.static_map.filename.to_s
      assert_equal STATIC_MAP_PNG_STUB, route.static_map.download
    end
  end

  test "generate_static_map! backfills a thumb from the attached gpx without touching stats" do
    route = @user.routes.create!(source: "upload", title: "Old route", duration: 22_500)
    route.gpx_file.attach(io: File.open(@gpx_path), filename: "exploration.gpx", content_type: "application/gpx+xml")

    with_mapbox_stubbed do
      route.generate_static_map!
    end
    route.reload

    assert route.static_map.attached?
    # Thumb-only backfill contract: a duration edited by hand on the detail
    # page survives (a parse_gpx! re-run would have overwritten it with 1800).
    assert_equal 22_500, route.duration
  end

  test "generate_static_map! is idempotent and never re-attaches" do
    route = @user.routes.create!(source: "upload", title: "Old route")
    route.gpx_file.attach(io: File.open(@gpx_path), filename: "exploration.gpx", content_type: "application/gpx+xml")

    with_mapbox_stubbed do
      route.generate_static_map!
      blob_id = route.static_map.blob.id
      route.generate_static_map!

      assert_equal blob_id, route.static_map.blob.id
    end
  end

  test "generate_static_map! is a no-op without a gpx file" do
    route = @user.routes.create!(source: "upload", title: "Manual entry")

    with_mapbox_stubbed do
      route.generate_static_map!
    end

    assert_not route.static_map.attached?
  end

  test "parse_gpx! smooths GPS jitter before summing elevation gain and loss" do
    route = @user.routes.create!(source: "upload", title: "Noisy climb")
    # 40 points climbing a steady 1 m per point with ±3 m alternating GPS
    # jitter — the noisy real-world profile that delta-summing the raw
    # series turns into phantom climb/descent.
    elevations = 40.times.map { |i| 100 + i + (i.even? ? 3 : -3) }
    route.gpx_file.attach(io: StringIO.new(gpx_with_elevations(elevations)),
                          filename: "noisy-climb.gpx", content_type: "application/gpx+xml")

    route.parse_gpx!
    route.reload

    # What the old, unsmoothed math would have reported for this track
    raw_gain = elevations.each_cons(2).sum { |a, b| [ b - a, 0 ].max }
    raw_loss = elevations.each_cons(2).sum { |a, b| [ a - b, 0 ].max }
    assert_operator raw_gain, :>, 120
    assert_operator raw_loss, :>, 90
    # Smoothed: gain hugs the true 39 m climb, the jitter-driven loss nearly
    # vanishes, while min/max altitude stay on the raw readings.
    assert_in_delta 39.0, route.elevation_gain, 3.0
    assert_operator route.elevation_loss, :<, 5.0
    assert_in_delta elevations.min, route.min_elevation, 0.01
    assert_in_delta elevations.max, route.max_elevation, 0.01
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

  # ---- moving pace + duration (Phase 6 detail page) ------------------------

  test "moving_pace divides distance by duration (km/h)" do
    route = @user.routes.build(source: "upload", title: "Ride", distance: 30, duration: 3_600)
    assert_in_delta 30.0, route.moving_pace, 0.01

    route = @user.routes.build(source: "upload", title: "Ride", distance: 45, duration: 5_400)
    assert_in_delta 30.0, route.moving_pace, 0.01
  end

  test "moving_pace is nil without distance or duration" do
    assert_nil @user.routes.build(source: "upload", title: "Ride").moving_pace
    assert_nil @user.routes.build(source: "upload", title: "Ride", duration: 3_600).moving_pace
    assert_nil @user.routes.build(source: "upload", title: "Ride", distance: 30).moving_pace
  end

  test "duration must be a positive whole number of seconds" do
    route = @user.routes.build(source: "upload", title: "Ride")
    assert_predicate route, :valid? # duration stays optional

    route.duration = -100
    assert_not route.valid?
    route.duration = 1.5
    assert_not route.valid?
    route.duration = 1_800
    assert_predicate route, :valid?
    route.duration = 0
    assert_predicate route, :valid?
    route.duration = nil
    assert_predicate route, :valid?
  end

  test "moving_duration falls back to one hour for zero or nil durations" do
    assert_equal 1_800, @user.routes.build(source: "upload", title: "Ride", duration: 1_800).moving_duration
    assert_equal Route::DEFAULT_MOVING_DURATION,
                 @user.routes.build(source: "upload", title: "Ride", duration: nil).moving_duration
    assert_equal Route::DEFAULT_MOVING_DURATION,
                 @user.routes.build(source: "upload", title: "Ride", duration: 0).moving_duration
  end

  private

  # Minimal GPX document whose single track carries the given elevations,
  # one trackpoint per reading a minute apart along a short line.
  def gpx_with_elevations(elevations)
    trackpoints = elevations.each_with_index.map do |ele, i|
      stamp = format("%02d", i)
      <<~POINT.squish
        <trkpt lat="47.37#{stamp}" lon="8.54#{stamp}">
          <ele>#{ele}</ele>
          <time>2026-09-09T08:#{stamp}:00Z</time>
        </trkpt>
      POINT
    end.join

    <<~GPX
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1" creator="explorer-test-suite" xmlns="http://www.topografix.com/GPX/1/1">
        <trk>
          <trkseg>
            #{trackpoints}
          </trkseg>
        </trk>
      </gpx>
    GPX
  end
end
