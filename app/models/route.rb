class Route < ApplicationRecord
  belongs_to :user

  has_one_attached :gpx_file
  # Thumbnail: a real map crop with the route drawn on it, rendered by the
  # browser's hidden MapLibre instance (Step 2 — see
  # app/javascript/map/route_thumb_capture.js) and stored as a blob via
  # POST /routes/:id/static_map. Cards render it through the cacheable
  # /route_thumbs/:signed_id endpoint; routes without one (parsed before the
  # feature existed, or every capture attempt failed) show the fallback
  # route icon until a later visit heals them.
  has_one_attached :static_map
  has_many :calendar_entries, dependent: :destroy
  # Route planner collections (technote.ROUTE-DRAW.md §3/§9): RW, SP and
  # POIs stay three SEPARATE collections, each destroyed with the route.
  has_many :routing_waypoints, -> { order(:position) }, dependent: :destroy, inverse_of: :route
  has_many :shaping_points, -> { order(:segment_index, :position) }, dependent: :destroy, inverse_of: :route
  has_many :pois, class_name: "RoutePoi", dependent: :destroy, inverse_of: :route

  # Difficulty label shown as the primary badge on library cards
  TIERS = %w[Easy Moderate Hard Alpine].freeze

  # Routing profiles the planner can draw with (§4). Stored on the route so
  # reopening an existing route restores the previously selected profile.
  ROUTING_PROFILES = %w[road gravel mtb].freeze
  DEFAULT_ROUTING_PROFILE = "road"

  # Editor seeding for routes never drawn in the planner (uploads, imports):
  # the stored track is split into slices of at most this much ground
  # distance, with a Routing Waypoint seeded at every cut. A drag then only
  # ever recalculates its local slice — with a single start→finish segment,
  # dragging either end (on a loop the two sit close together) would rebuild
  # the whole ride into a small path. The waypoint count is capped, so very
  # long tracks stretch the spacing instead of flooding the map with markers.
  PLANNER_SEED_SEGMENT_M = 10_000.0
  PLANNER_SEED_MAX_WAYPOINTS = 25

  validates :title, presence: true, length: { maximum: 200 }
  validates :source, inclusion: { in: %w[upload google_drive drawn], allow_nil: true }
  validates :tier, inclusion: { in: TIERS, allow_nil: true }
  validates :sport_type, length: { maximum: 40 }, allow_nil: true
  validates :routing_profile, inclusion: { in: ROUTING_PROFILES, allow_nil: true }

  # Moving time in seconds, parsed from the GPX and editable on the detail
  # page (drives the derived moving pace — see #moving_pace).
  validates :duration, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }

  SOURCES = %w[upload google_drive drawn].freeze

  # Source predicates used by the library cards and import stats
  def google_drive?
    source == "google_drive"
  end

  def upload?
    source == "upload"
  end

  # Drawn in the Route Planner (technote.ROUTE-DRAW.md) — the GPX is
  # generated from the calculated geometry rather than uploaded.
  def drawn?
    source == "drawn"
  end

  # ---- Route planner (technote.ROUTE-DRAW.md) ------------------------------

  # The planner editor state for this route (§2.2: opening an existing route
  # loads geometry, RWs, SPs, POIs and the profile) — the exact JSON shape
  # the frontend planner boots from. Routes that have been through the
  # planner ship the persisted planner_geometry and their RW rows. Routes
  # that were never drawn (uploads, imports) have no planner collections —
  # their stored GPX track is split into editor slices with a Routing
  # Waypoint seeded at every cut, so the editor opens with the real line,
  # ready to edit: dragging any point only ever recalculates its local
  # slice.
  def planner_state
    geometry = planner_geometry.is_a?(Hash) ? planner_geometry : {}
    if drawn? || planner_geometry.is_a?(Hash)
      waypoints = routing_waypoints.map { |waypoint| { id: waypoint.id, lat: waypoint.lat, lon: waypoint.lon } }
      segments = Array(geometry["segments"]).map { |segment| segment["points"] }
    else
      waypoints, segments = seeded_editor_track
    end
    {
      route_id: id,
      title: title,
      profile: routing_profile || DEFAULT_ROUTING_PROFILE,
      loop: geometry["loop"].present?,
      waypoints: waypoints,
      shaping_points: shaping_points.map do |point|
        { id: point.id, segment_index: point.segment_index, position: point.position,
          lat: point.lat, lon: point.lon }
      end,
      pois: pois.map { |poi| poi_state(poi) },
      segments: segments
    }
  end

  # Editor geometry for a route never drawn in the planner (uploads,
  # imports): the stored GPX track downsampled to the saver's per-segment
  # limit (the editor hands the same geometry back on save, so nothing it
  # ships may exceed what the saver accepts), then split with a Routing
  # Waypoint seeded at every cut. The cuts are exact track points and
  # adjacent slices share them, so the union rebuilds the ride
  # byte-for-byte; on the next save the seeds become real waypoint rows
  # like any user-placed one (§6.1: the editor state is the full truth).
  def seeded_editor_track
    track = track_coordinates
    return [ [], [] ] if track.size < 2

    track = Map::TrackGeometry.downsample(track, Planner::RouteSaver::MAX_SEGMENT_POINTS)
    cuts = Map::TrackGeometry.split_indexes(
      track, max_segment_m: PLANNER_SEED_SEGMENT_M, max_segments: PLANNER_SEED_MAX_WAYPOINTS - 1
    )
    waypoints = cuts.map do |index|
      point = track[index]
      { id: nil, lat: point[1], lon: point[0] }
    end
    [ waypoints, cuts.each_cons(2).map { |from, to| track[from..to] } ]
  end

  def poi_state(poi)
    state = {
      id: poi.id, lat: poi.lat, lon: poi.lon,
      title: poi.title, description: poi.description,
      external_url: poi.external_url
    }
    # The cacheable blob URL only while an image is attached; the editor
    # keeps new uploads client-side until Save.
    state[:image_url] = rails_blob_path(poi.image) if poi.image.attached?
    state
  end

  def rails_blob_path(blob)
    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
  end


  # ---- Public visibility (Phase 9 share) ----------------------------------
  # A route scheduled on its owner's calendar is readable by anyone —
  # friends on /calendar/:username, and any stranger or guest holding the
  # share link — while the owner's calendar share is live. Unscheduled
  # library routes (and everything, once the share is switched off or the
  # ride is removed from the calendar) stay owner/friend-only.
  # RoutesController gates the detail page and GPX download on this.
  def publicly_viewable?
    user.calendar_public? && calendar_entries.exists?(user_id: user_id)
  end

  # ---- Map page (technote.MYMAP-FEATURE.md) -------------------------------
  # Routes that are public under the Phase 9 share rules — the same contract
  # as #publicly_viewable? expressed in SQL, so MapsController can select
  # other users' public routes for the viewport query without loading any
  # private library rows. A route is public when its owner's calendar share
  # is live AND the route is scheduled on that owner's own calendar.
  scope :publicly_visible, lambda {
    joins(:user)
      .where(users: { calendar_public: true })
      .where(<<~SQL.squish)
        EXISTS (
          SELECT 1 FROM calendar_entries ce
          WHERE ce.route_id = routes.id AND ce.user_id = routes.user_id
        )
      SQL
  }

  # Routes the map can actually draw: a GPX is attached and the bounding box
  # was captured by the parse (backfill task covers routes parsed before the
  # columns existed). NULL bounds drop out of the viewport comparisons below
  # on their own; the explicit joins keep the intent obvious.
  scope :with_track, lambda {
    joins(:gpx_file_attachment).where.not(min_lat: nil)
  }

  # Geographic-viewport intersection for the map's public-routes query
  # (§5.1): the route's bounding box overlaps the requested rect. Latitudes
  # always use the plain overlap test; longitudes branch because MapLibre
  # bounds may cross the antimeridian (west > east, e.g. 175 → -170), which
  # no single AND-clause can match. West/east may exceed ±180 after the
  # client's wrap normalization — such views stay over-inclusive, never
  # under-inclusive, so no route can be wrongly hidden. Pairs with LIMIT in
  # the controller (§5: never return the whole public collection).
  scope :intersecting_viewport, lambda { |west, south, east, north|
    lon_match =
      if west > east
        "(max_lon >= :west OR min_lon <= :east)"
      else
        "(max_lon >= :west AND min_lon <= :east)"
      end
    where(
      "#{lon_match} AND max_lat >= :south AND min_lat <= :north",
      west: west, east: east, south: south, north: north
    )
  }

  # ---- Deep copy (save to library, calendar join) ------------------------
  # Attributes carried onto a deep copy: the parsed GPX facts and display
  # metadata, plus everything the Route Planner persisted (§9) so a joined
  # drawn ride stays fully editable in the joiner's library. Ownership,
  # timestamps, source and the completed flag reset.
  DEEP_COPY_ATTRIBUTES = %w[
    title description distance elevation_gain elevation_loss min_elevation
    max_elevation duration tier sport_type routing_profile planner_geometry
  ].freeze

  # Build (unsaved) a duplicate of this route owned by +owner+. The GPX file
  # and the static map thumb are re-attached byte-for-byte under the copy's
  # own blobs, so the copy and the original never share state — editing,
  # re-uploading or deleting one can never affect the other. Call save! on
  # the result.
  def deep_copy_for(owner)
    owner.routes.build(
      attributes.slice(*DEEP_COPY_ATTRIBUTES).merge(
        "source" => drawn? ? "drawn" : "upload",
        "completed" => false
      )
    ).tap do |copy|
      # Buffer the bytes up front: the copy's uploads are deferred until its
      # save!, by which time a Tempfile opened here would already be closed.
      # GPX files and map renders are small, so buffering is safe.
      if gpx_file.attached?
        copy.gpx_file.attach(
          io: StringIO.new(gpx_file.download),
          filename: gpx_file.filename,
          content_type: gpx_file.content_type
        )
      end

      if static_map.attached?
        copy.static_map.attach(
          io: StringIO.new(static_map.download),
          filename: static_map.filename,
          content_type: static_map.content_type
        )
      end

      copy_planner_collections(copy)
    end
  end

  # Average speed in km/h implied by distance and moving time. Derived on the
  # fly — the detail page's linked Est. Duration / Moving Pace inputs both
  # just rewrite +duration+. Nil when either input is missing or zero.
  def moving_pace
    return if distance.blank? || distance.zero? || duration.blank? || duration.zero?

    distance / (duration / 3600.0)
  end

  # Moving time used for calendar end-time math. Zero/nil durations (GPX
  # files without usable timestamps) fall back to the 1-hour default —
  # `0.presence` is 0, so a bare `duration.presence || default` would compute
  # end == start and trip the entry's end-time validation.
  DEFAULT_MOVING_DURATION = 1.hour

  def moving_duration
    duration.to_i.positive? ? duration : DEFAULT_MOVING_DURATION
  end

  # Parse the attached GPX file and populate stats fields
  def parse_gpx!
    return unless gpx_file.attached?

    gpx_file.open do |file|
      gpx = GPX::GPXFile.new(gpx_file: file.path)
      self.distance = gpx.distance&.to_f
      self.duration = gpx.duration&.to_i

      elevations = gpx.tracks.flat_map(&:points).map(&:elevation).compact
      if elevations.any?
        self.min_elevation = elevations.min
        self.max_elevation = elevations.max
        # GPS altitude jitter must be smoothed away before the delta sums,
        # or every wiggle is counted as phantom climb/descent. The same
        # ElevationStats math serves the Route Planner's drawn routes, so an
        # uploaded and a drawn ride always agree on what a metre of climbing
        # is.
        smoothed = Map::ElevationStats.smooth(elevations)
        self.elevation_gain = Map::ElevationStats.gain(smoothed)
        self.elevation_loss = Map::ElevationStats.loss(smoothed)
      end

      # The full-resolution track as [lon, lat, ele] triplets — bounds and
      # the stored map geometry derive from this one array. (Step 2: thumbs
      # are captured client-side after upload — see
      # app/javascript/map/route_thumb_capture.js — never during the parse.)
      points = gpx.tracks.flat_map(&:points).filter_map do |point|
        next unless point.lon && point.lat

        [ point.lon, point.lat, point.elevation ]
      end
      # Map page (technote.MYMAP-FEATURE.md §5.1): capture the bounding box
      # from the very same trackpoints the thumb renders, so the viewport
      # query never has to open GPX blobs to know where a route lives.
      assign_map_bounds(points)
      # Map page (§5/§9): the downsampled line + profile chart are derived
      # once here and persisted in map_geometry, so map requests never parse
      # GPX blobs and cache warmth cannot change their latency.
      # Presentation-only: the stats above remain full-series computations
      # and nothing ever reads map_geometry back into them.
      self.map_geometry = Map::TrackGeometry.build(points)

      self.title ||= gpx.name.presence || self.title.presence || gpx_file.filename&.base.presence || "Untitled Route"
      save!
    end
  end

  # All usable trackpoints as [lon, lat, ele] triplets read fresh from the
  # stored GPX — the geometry source for the map backfills and the map
  # feature's self-heal (technote §5: GeoJSON is generated server-side; the
  # browser never downloads raw GPX files). Streams the document once via
  # Map::TrackExtractor instead of building the gpx gem's full point tree —
  # ~0.2s per multi-megabyte track instead of ~1.2s. ele is nil for
  # trackpoints without an <ele> element; the elevation profile filters
  # those out. Empty (not nil) without a GPX, so callers can iterate
  # unconditionally.
  def track_coordinates
    return [] unless gpx_file.attached?

    gpx_file.open { |file| Map::TrackExtractor.extract(file) }
  end

  # The stored bounding box as a GeoJSON-style [west, south, east, north]
  # array, or nil before the GPX has been parsed (bounds columns are set
  # only by parse_gpx! / the backfill task).
  def bounds_array
    return if min_lat.nil? || min_lon.nil?

    [ min_lon, min_lat, max_lon, max_lat ]
  end

  # Bounding-box column assignments for +coords+ ([lon, lat(, ele)] tuples) —
  # shared by parse_gpx! and the map-bounds backfill task so both write
  # identical values.
  def self.map_bounds_from(coords)
    lons = coords.map(&:first)
    lats = coords.map { |coord| coord[1] }
    {
      min_lon: lons.min, max_lon: lons.max,
      min_lat: lats.min, max_lat: lats.max
    }
  end

  private

  # Store the track's geographic bounding box (§5.1). coords are [lon, lat]
  # pairs; empty input (no usable trackpoints) leaves the columns nil, which
  # with_track and the viewport query treat as "not on the map".
  def assign_map_bounds(coords)
    return if coords.blank?

    assign_attributes(Route.map_bounds_from(coords))
  end

  # Deep-copy the Route Planner collections (technote.ROUTE-DRAW.md §9) onto
  # +copy+: ordered RW, SP with their segment associations, POIs with their
  # metadata and imagery. Plain row copies — the copy owns its own planner
  # state exactly like it owns its own GPX bytes, so editing one can never
  # move the other's waypoints.
  def copy_planner_collections(copy)
    key_map = {}
    routing_waypoints.each do |waypoint|
      duplicate = copy.routing_waypoints.build(lat: waypoint.lat, lon: waypoint.lon, position: waypoint.position)
      key_map[waypoint.id] = duplicate
    end
    shaping_points.each do |point|
      copy.shaping_points.build(
        segment_index: point.segment_index, position: point.position,
        lat: point.lat, lon: point.lon
      )
    end
    pois.each do |poi|
      duplicate = copy.pois.build(
        lat: poi.lat, lon: poi.lon, title: poi.title,
        description: poi.description, external_url: poi.external_url,
        routing_waypoint: poi.routing_waypoint && key_map[poi.routing_waypoint.id]
      )
      next unless poi.image.attached?

      duplicate.image.attach(
        io: StringIO.new(poi.image.download),
        filename: poi.image.filename,
        content_type: poi.image.content_type
      )
    end
  end
end
