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

      generate_static_map!(track_coords(gpx))
      self.title ||= gpx.name.presence || self.title.presence || gpx_file.filename&.base.presence || "Untitled Route"
      save!
    end
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
