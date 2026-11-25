# A Point of Interest (POI) on a drawn route (technote.ROUTE-DRAW.md §3.4) —
# a user annotation with its own coordinates and metadata that NEVER affects
# the route geometry: POIs are calculated around, not through. Stored fully
# independently from Shaping Points. The optional +routing_waypoint+ link
# marks a POI that was converted from an RW; deleting the RW nullifies the
# link instead of destroying the POI, and creating/editing POIs never
# triggers a route recalculation.
class RoutePoi < ApplicationRecord
  belongs_to :route
  belongs_to :routing_waypoint, optional: true

  # Popover imagery — uploaded through the planner's image endpoint and
  # attached by signed_id on save. Viewed inside the POI popup (§7).
  #
  # Note: the save payload's `image_signed_id` is NOT this model's attribute —
  # Planner::RouteSaver keeps it local and attaches the blob to the row it
  # created, so nothing here needs to accept it.
  has_one_attached :image

  validates :lat, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }
  validates :lon, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :title, length: { maximum: 200 }
  validates :external_url, length: { maximum: 1024 }, allow_nil: true

  # [lat, lon] pair — the shape the editor state and the routing adapter speak.
  def coordinates
    [ lat, lon ]
  end
end
