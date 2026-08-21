class Route < ApplicationRecord
  belongs_to :user

  has_one_attached :gpx_file

  validates :title, presence: true, length: { maximum: 200 }
  validates :source, inclusion: { in: %w[upload google_drive], allow_nil: true }

  SOURCES = %w[upload google_drive].freeze

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

      self.title ||= gpx.name.presence || "Untitled Route"
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
end