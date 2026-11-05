class Route < ApplicationRecord
  belongs_to :user

  has_one_attached :gpx_file
  # Thumbnail: a real map image rendered by the Mapbox Static Images API at
  # parse time and stored as a blob (see Mapbox::StaticImage). Cards render it
  # through the cacheable /route_thumbs/:signed_id endpoint; routes without
  # one (parsed before the feature existed, or no Mapbox token) show the
  # fallback route icon.
  has_one_attached :static_map
  has_many :calendar_entries, dependent: :destroy

  # Difficulty label shown as the primary badge on library cards
  TIERS = %w[Easy Moderate Hard Alpine].freeze

  validates :title, presence: true, length: { maximum: 200 }
  validates :source, inclusion: { in: %w[upload google_drive], allow_nil: true }
  validates :tier, inclusion: { in: TIERS, allow_nil: true }
  validates :sport_type, length: { maximum: 40 }, allow_nil: true
  # Moving time in seconds, parsed from the GPX and editable on the detail
  # page (drives the derived moving pace — see #moving_pace).
  validates :duration, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }

  SOURCES = %w[upload google_drive].freeze

  # Source predicates used by the library cards and import stats
  def google_drive?
    source == "google_drive"
  end

  def upload?
    source == "upload"
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
  # metadata. Ownership, timestamps, source and the completed flag reset.
  DEEP_COPY_ATTRIBUTES = %w[
    title description distance elevation_gain elevation_loss min_elevation
    max_elevation duration tier sport_type
  ].freeze

  # Build (unsaved) a duplicate of this route owned by +owner+. The GPX file
  # and the static map thumb are re-attached byte-for-byte under the copy's
  # own blobs, so the copy and the original never share state — editing,
  # re-uploading or deleting one can never affect the other. Call save! on
  # the result.
  def deep_copy_for(owner)
    owner.routes.build(
      attributes.slice(*DEEP_COPY_ATTRIBUTES).merge(
        "source" => "upload",
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

      next unless static_map.attached?

      copy.static_map.attach(
        io: StringIO.new(static_map.download),
        filename: static_map.filename,
        content_type: static_map.content_type
      )
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

  # Trackpoints per smoothing window for elevation stats: a centered moving
  # average over 5 readings strips the GPS altitude jitter that would
  # otherwise be summed up as phantom climb/descent (see smooth_elevations).
  ELEVATION_SMOOTHING_WINDOW = 5

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
        # or every wiggle is counted as phantom climb/descent.
        smoothed = smooth_elevations(elevations)
        self.elevation_gain = compute_elevation_gain(smoothed)
        self.elevation_loss = compute_elevation_loss(smoothed)
      end

      # The full-resolution track as [lon, lat, ele] triplets — bounds, the
      # stored map geometry and the thumb all derive from this one array.
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

      generate_static_map!(points.map { |lon, lat, _ele| [ lon, lat ] })

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

  # Generate and attach the Mapbox static map thumb for this route. +coords+
  # is the track's [lon, lat] pairs; pass nil to have them read from the
  # attached GPX (the backfill task does this for routes parsed before the
  # feature existed). Idempotent — a route that already has a thumb is left
  # alone — and safe to call when Mapbox is unavailable: the service returns
  # nil, no thumb is attached, and the route keeps its fallback icon. Never
  # touches the parsed stats (distance/duration/elevations): a backfill must
  # not clobber durations edited by hand on the detail page. +coords+ is the
  # track's [lon, lat] pairs — pass nil to have them read from the attached
  # GPX (the backfill task does this for routes parsed before the feature
  # existed); an empty array (no usable trackpoints) simply skips the thumb.
  def generate_static_map!(coords = nil)
    return if static_map.attached?

    if coords.nil?
      return unless gpx_file.attached?

      coords = gpx_file.open do |file|
        track_coords(GPX::GPXFile.new(gpx_file: file.path))
      end
    end
    return if coords.size < 2

    attachable = Mapbox::StaticImage.attachable(coords)
    static_map.attach(attachable) if attachable
  end

  private

  # Store the track's geographic bounding box (§5.1). coords are [lon, lat]
  # pairs; empty input (no usable trackpoints) leaves the columns nil, which
  # with_track and the viewport query treat as "not on the map".
  def assign_map_bounds(coords)
    return if coords.blank?

    assign_attributes(Route.map_bounds_from(coords))
  end

  # The GPX track's usable points as [lon, lat] pairs — the one extraction
  # shared by the stats parse and the standalone thumb generation.
  def track_coords(gpx)
    gpx.tracks.flat_map(&:points).filter_map { |p| [ p.lon, p.lat ] if p.lon && p.lat }
  end

  # Centered moving average over ELEVATION_SMOOTHING_WINDOW points. Raw GPS
  # altitude readings jitter by several meters between trackpoints; feeding
  # that noise to compute_elevation_gain/loss counts every wiggle as real
  # climb/descent and wildly inflates the stats. The window shrinks at the
  # track ends (mean of the available neighbours), so the result always has
  # the same length as the input. Series shorter than three points have no
  # meaningful jitter to smooth and are returned unchanged.
  def smooth_elevations(elevations)
    return elevations if elevations.size < 3

    half = ELEVATION_SMOOTHING_WINDOW / 2
    elevations.each_index.map do |i|
      window = elevations[[ i - half, 0 ].max..[ i + half, elevations.size - 1 ].min]
      window.sum.to_f / window.size
    end
  end

  def compute_elevation_gain(elevations)
    gain = 0.0
    elevations.each_cons(2) do |a, b|
      gain += (b - a) if b > a
    end
    gain
  end

  def compute_elevation_loss(elevations)
    loss = 0.0
    elevations.each_cons(2) do |a, b|
      loss += (a - b) if a > b
    end
    loss
  end
end
