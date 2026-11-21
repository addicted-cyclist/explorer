# A Routing Waypoint (RW) — the user-defined control points of a drawn route
# (technote.ROUTE-DRAW.md §3.2). RWs determine the logical structure and
# sequence of a route: every one of them participates in the BRouter
# calculation, and their order defines the segment sequence. The coordinates
# live here, fully independent from the calculated geometry stored on the
# route (planner_geometry / GPX), so editing never has to reverse-engineer
# control points out of a track.
class RoutingWaypoint < ApplicationRecord
  belongs_to :route

  # Optional POI born from "convert this RW into a POI" (§3.2). Removing the
  # RW nullifies the link (on_delete: :nullify) — the POI itself survives as
  # a free-floating POI with its coordinates and metadata intact (§3.4).
  has_one :poi, class_name: "RoutePoi", dependent: :nullify

  validates :lat, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }
  validates :lon, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # [lat, lon] pair — the shape the editor state and the routing adapter speak.
  def coordinates
    [ lat, lon ]
  end
end
