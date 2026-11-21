# A Shaping Point (SP) — a drag-created routing constraint on one specific
# segment of a drawn route (technote.ROUTE-DRAW.md §3.3). SPs participate in
# the BRouter calculation but are not user-facing waypoints: they stay
# associated with the segment they were dragged from (+segment_index+, the
# 0-based index among the route's segments, loop closing segment included)
# and keep their ordering within it (+position+). Both indexes together are
# the SP-to-segment association that must survive saving and reopening.
class ShapingPoint < ApplicationRecord
  belongs_to :route

  validates :lat, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }
  validates :lon, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :segment_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # [lat, lon] pair — the shape the editor state and the routing adapter speak.
  def coordinates
    [ lat, lon ]
  end
end
