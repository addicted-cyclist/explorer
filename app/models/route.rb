class Route < ApplicationRecord
  belongs_to :user

  has_one_attached :gpx_file
  has_many :calendar_entries, dependent: :destroy

  # Difficulty label shown as the primary badge on library cards
  TIERS = %w[Easy Moderate Hard Alpine].freeze

  validates :title, presence: true, length: { maximum: 200 }
  validates :source, inclusion: { in: %w[upload google_drive], allow_nil: true }
  validates :tier, inclusion: { in: TIERS, allow_nil: true }
  validates :sport_type, length: { maximum: 40 }, allow_nil: true

  SOURCES = %w[upload google_drive].freeze

  # Source predicates used by the library cards and import stats
  def google_drive?
    source == "google_drive"
  end

  def upload?
    source == "upload"
  end

  # ---- Track thumbnail (route library) ----------------------------------
  # The parsed track is downsampled and projected into this fixed viewBox;
  # the stored string is only the SVG path data ("M x,y L x,y …").
  TRACK_SVG_VIEWBOX = "0 0 100 60".freeze
  TRACK_SVG_MAX_POINTS = 200
  TRACK_SVG_PADDING = 4.0

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
        self.elevation_gain = compute_elevation_gain(elevations)
        self.elevation_loss = compute_elevation_loss(elevations)
      end

      self.track_svg = build_track_svg(gpx.tracks.flat_map(&:points))
      self.title ||= gpx.name.presence || self.title.presence || gpx_file.filename&.base.presence || "Untitled Route"
      save!
    end
  end

  private

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

  # Build the thumbnail polyline: downsample the track, project it with an
  # equirectangular projection (longitude shrunk by cos of the mean latitude),
  # then fit it aspect-preserving into the fixed viewBox. Returns the SVG path
  # data string, or nil when the track has fewer than two usable points.
  def build_track_svg(points)
    coords = points.filter_map { |p| [ p.lon, p.lat ] if p.lon && p.lat }
    return if coords.size < 2

    coords = downsample_track(coords, TRACK_SVG_MAX_POINTS)

    mean_lat = coords.sum { |_, lat| lat } / coords.size
    cos_lat = Math.cos(mean_lat * Math::PI / 180.0)
    projected = coords.map { |lon, lat| [ lon * cos_lat, lat ] }

    min_x, max_x = projected.map(&:first).minmax
    min_y, max_y = projected.map(&:last).minmax
    span_x = max_x - min_x
    span_y = max_y - min_y
    return if span_x <= 0 && span_y <= 0

    viewbox_w = TRACK_SVG_VIEWBOX.split(" ")[2].to_f
    viewbox_h = TRACK_SVG_VIEWBOX.split(" ")[3].to_f
    drawable_w = viewbox_w - (TRACK_SVG_PADDING * 2)
    drawable_h = viewbox_h - (TRACK_SVG_PADDING * 2)

    # Uniform scale (preserves the track's aspect ratio), centered in the box
    scale_x = span_x.positive? ? drawable_w / span_x : Float::INFINITY
    scale_y = span_y.positive? ? drawable_h / span_y : Float::INFINITY
    scale = [ scale_x, scale_y ].min
    offset_x = (viewbox_w - (span_x * scale)) / 2.0
    offset_y = (viewbox_h - (span_y * scale)) / 2.0

    # SVG y grows downward, latitude grows upward -> flip y
    segments = projected.map do |x, y|
      px = (offset_x + ((x - min_x) * scale)).round(1)
      py = (viewbox_h - (offset_y + ((y - min_y) * scale))).round(1)
      "#{px},#{py}"
    end

    "M#{segments.shift} L#{segments.join(' ')}"
  end

  # Thin out the coordinate list so at most +max+ points remain, keeping the
  # first and last points of the track.
  def downsample_track(coords, max)
    return coords if coords.size <= max

    stride = (coords.size.to_f / max).ceil
    sampled = coords.each_slice(stride).map(&:first)
    sampled[-1] = coords[-1]
    sampled
  end
end
