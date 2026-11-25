# frozen_string_literal: true

module Planner
  # Persistence for the Route Planner (technote.ROUTE-DRAW.md §6.1/§9): takes
  # the editor state the frontend holds (RWs, POIs, profile, per-segment
  # calculated geometry) and turns it into a first-class Route — the same
  # record shape an uploaded GPX produces — inside ONE transaction.
  #
  # Trust boundary: the geometry arrives from the client, but every request
  # during editing went through Rails (PlannerController →
  # Routing::BrouterClient), so the payload is a replay of server-computed
  # segments, not free-form client art. The saver therefore validates the
  # structure it cannot trust: segment count must match the RW sequence
  # (loop closing segment included) and every segment must START and END at
  # its boundary waypoints within ENDPOINT_TOLERANCE_M. Stats, bounding box,
  # map geometry and the GPX attachment are recomputed server-side from the
  # geometry — never taken on faith (§6.1: validate, persist, update stats,
  # generate GPX).
  class RouteSaver
    # Raised with the human-readable error list; PlannerController maps it
    # to a 422 the planner surfaces as a toast.
    class ValidationError < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super(errors.first)
      end
    end

    MAX_WAYPOINTS = 100
    MAX_POIS = 100
    MAX_SEGMENT_POINTS = 20_000
    # Snap tolerance for the "segment starts/ends at its boundary RW" check:
    # BRouter snaps requests to the road network, so the first/last geometry
    # points sit near — not exactly at — the RW coordinates.
    ENDPOINT_TOLERANCE_M = 150.0

    class << self
      def call(user:, route:, state:)
        new(user: user, route: route, state: state).call
      end
    end

    def initialize(user:, route:, state:)
      @user = user
      @route = route
      @raw = state
    end

    def call
      normalize
      validate
      persist
    end

    private

    # ---- normalize ---------------------------------------------------------

    def normalize
      @title = raw_string("title").presence || "Untitled Route"
      @title = @title[0, 200]
      @profile = raw_string("profile")
      @loop = raw["loop"] == true
      # Waypoints arrive as {lat, lon} objects (the editor's payload shape);
      # [lat, lon] pairs are accepted too for robustness.
      @waypoints = array_at("waypoints").filter_map do |point|
        coords = point.is_a?(Hash) ? [ point["lat"], point["lon"] ] : point
        point_pair(coords)
      end
      # §12: shaping points are gone from the model. Any legacy key in the
      # payload is ignored outright — its points were constraints, and the
      # only truthful place for a constraint now is a plotted waypoint.
      @pois = array_at("pois").filter_map { |raw_poi| normalize_poi(raw_poi) }
      @segments = array_at("segments").filter_map do |raw_segment|
        next unless raw_segment.is_a?(Hash)

        points = array_at("points", root: raw_segment).filter_map do |coordinate|
          next unless coordinate.is_a?(Array) && coordinate.size >= 2 &&
                      coordinate[0..1].all? { |value| value.is_a?(Numeric) }

          ele = coordinate[2].is_a?(Numeric) ? coordinate[2].to_f : nil
          [ coordinate[0].to_f, coordinate[1].to_f, ele ]
        end
        next if points.size < 2

        { points: points, time_s: numeric_or_nil(raw_segment["time_s"]) }
      end
    end

    def normalize_poi(raw_poi)
      return unless raw_poi.is_a?(Hash)

      lat, lon = point_pair([ raw_poi["lat"], raw_poi["lon"] ])
      return if lat.nil?

      title = raw_poi["title"].to_s.strip
      {
        lat: lat, lon: lon,
        title: title[0, 200].presence,
        description: raw_poi["description"].to_s.strip.presence,
        external_url: sanitize_url(raw_poi["external_url"].to_s.strip),
        image_signed_id: raw_poi["image_signed_id"].presence,
        waypoint_index: integer_or_nil(raw_poi["waypoint_index"])
      }
    end

    # [lat, lon] pair from arbitrary input, or nil — never a crash.
    def point_pair(pair)
      return nil unless pair.is_a?(Array) && pair.size == 2 && pair.all? { |v| v.is_a?(Numeric) }

      lat = pair[0].to_f
      lon = pair[1].to_f
      return nil unless lat.between?(-90.0, 90.0) && lon.between?(-180.0, 180.0)

      [ lat, lon ]
    end

    def numeric_or_nil(value)
      return nil unless value.is_a?(Numeric) && value >= 0

      value.to_f
    end

    # Strict integer coercion: nil for anything that is not a whole number,
    # so absent references never collapse onto index 0.
    def integer_or_nil(value)
      return nil unless value.is_a?(Numeric) && value >= 0 && value.to_i == value

      value.to_i
    end

    # Only http(s) URLs survive; anything else (javascript:, data:, garbage)
    # is dropped rather than stored next to a clickable link.
    def sanitize_url(url)
      return nil if url.blank? || url.length > 1024

      parsed = URI.parse(url)
      parsed.is_a?(URI::HTTP) && parsed.host.present? ? url : nil
    rescue URI::InvalidURIError
      nil
    end

    def raw_string(key)
      value = raw[key]
      value.is_a?(String) ? value.strip : ""
    end

    def array_at(key, root: nil)
      source = root || raw
      value = source[key]
      value.is_a?(Array) ? value : []
    end

    attr_reader :raw

    # ---- persist -----------------------------------------------------------

    def persist
      points = @segments.flat_map { |segment| segment[:points] }
      stats = Map::ElevationStats.stats(points)
      duration = @segments.filter_map { |segment| segment[:time_s] }.sum
      route = target_route

      Route.transaction do
        route.assign_attributes(
          user: @user,
          title: @title,
          source: "drawn",
          routing_profile: @profile,
          sport_type: @profile,
          distance: (Map::TrackGeometry.cumulative_distance_m(points).last / 1000.0).round(3),
          duration: duration.positive? ? duration.round : nil
        )
        route.assign_attributes(
          elevation_gain: stats[:gain], elevation_loss: stats[:loss],
          min_elevation: stats[:min], max_elevation: stats[:max]
        )
        route.assign_attributes(Route.map_bounds_from(points))
        # The drawn line the map renders and the planner reopens (§9:
        # calculated geometry persisted; GPX generated from it, never the
        # sole source of truth).
        route.planner_geometry = {
          "profile" => @profile,
          "loop" => @loop,
          "segments" => @segments.map do |segment|
            { "points" => segment[:points], "time_s" => segment[:time_s] }
          end
        }
        route.map_geometry = Map::TrackGeometry.build(points)

        # Replace the collections wholesale: the editor state is the full
        # truth of this save (§6.1), and ids inside it are client-local.
        route.routing_waypoints.destroy_all
        route.pois.destroy_all

        waypoint_rows = @waypoints.each_with_index.map do |(lat, lon), index|
          RoutingWaypoint.new(route: route, lat: lat, lon: lon, position: index)
        end
        waypoint_rows.each(&:save!)
        @pois.each do |poi|
          row = RoutePoi.create!(
            route: route,
            routing_waypoint: poi[:waypoint_index] && waypoint_rows[poi[:waypoint_index]],
            lat: poi[:lat], lon: poi[:lon], title: poi[:title],
            description: poi[:description], external_url: poi[:external_url]
          )
          attach_poi_image(row, poi[:image_signed_id])
        end

        attach_gpx(route, points)
        # The old thumbnail no longer matches the edited geometry — drop it
        # so the client's thumbnail capture heals it after save.
        route.static_map.purge_later if route.static_map.attached?

        route.save!
      end

      # Reload before returning: the wholesale collection replacement ran on
      # the DB, and stale in-memory association caches must not leak to the
      # caller (the controller serializes ids from the real rows).
      route.reload
      route
    end

    def target_route
      return @route if @route

      @user.routes.build(source: "drawn", title: @title)
    end

    def attach_gpx(route, points)
      gpx = Map::GpxBuilder.build(title: @title, points: points)
      route.gpx_file.attach(
        io: StringIO.new(gpx),
        filename: "#{@title.parameterize.presence || 'route'}.gpx",
        content_type: "application/gpx+xml"
      )
    end

    # POI imagery arrives as a direct-upload signed id (the planner uploads
    # the file the moment the user picks it, then references it here). An
    # unfindable/expired/foreign blob is dropped, never fatal to the save.
    def attach_poi_image(poi_row, signed_id)
      return if signed_id.blank?

      blob = ActiveStorage::Blob.find_signed(signed_id)
      poi_row.image.attach(blob) if blob
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    # ---- validate ----------------------------------------------------------

    def validate
      errors = []
      unless Route::ROUTING_PROFILES.include?(@profile)
        errors << "Unknown routing profile."
      end
      unless @waypoints.size.between?(2, MAX_WAYPOINTS)
        errors << "A route needs between 2 and #{MAX_WAYPOINTS} waypoints."
      end

      errors.concat(validate_segments)
      errors << "Too many points of interest (max #{MAX_POIS})." if @pois.size > MAX_POIS

      @pois.each do |poi|
        index = poi[:waypoint_index]
        next if index.nil? || index < @waypoints.size

        errors << "A point of interest references a waypoint that does not exist."
        break
      end

      raise ValidationError, errors.uniq if errors.any?
    end

    def expected_segment_count
      @waypoints.size - 1 + (@loop ? 1 : 0)
    end

    def validate_segments
      errors = []
      if @segments.size != expected_segment_count
        errors << "Route geometry is incomplete — recalculate the route before saving."
        return errors
      end

      @segments.each_with_index do |segment, index|
        errors.concat(validate_segment(segment, index))
      end
      errors
    end

    # Segment +index+ runs from RW[index] to RW[index+1] — or, for the
    # closing segment of a loop, from the last RW back to the first (§5.6).
    # Its geometry must start and end within tolerance of those boundaries.
    def validate_segment(segment, index)
      from_waypoint, to_waypoint = segment_boundaries(index)
      errors = []
      errors << endpoint_error(index, "start") unless near_waypoint?(segment[:points].first, from_waypoint)
      errors << endpoint_error(index, "end") unless near_waypoint?(segment[:points].last, to_waypoint)
      errors << "Segment #{index + 1} is too long — split it with another waypoint." if segment[:points].size > MAX_SEGMENT_POINTS
      errors
    end

    def segment_boundaries(index)
      loop_closing = @loop && index == @waypoints.size - 1
      from_waypoint = @waypoints[index]
      to_waypoint = loop_closing ? @waypoints.first : @waypoints[index + 1]
      [ from_waypoint, to_waypoint ]
    end

    def near_waypoint?(point, waypoint)
      Map::TrackGeometry.haversine_m([ point[0], point[1] ], [ waypoint[1], waypoint[0] ]) <= ENDPOINT_TOLERANCE_M
    end

    def endpoint_error(index, side)
      "Segment #{index + 1} does not #{side} at its waypoints — recalculate before saving."
    end
  end
end
