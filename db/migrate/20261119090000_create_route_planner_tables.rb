class CreateRoutePlannerTables < ActiveRecord::Migration[7.2]
  def change
    # Route planner columns on the existing route row (technote.ROUTE-DRAW.md
    # §3.1): the active routing profile and the persisted per-segment
    # calculated geometry (GPX is generated from it, but is never the sole
    # source of truth for editing — §9).
    add_column :routes, :routing_profile, :string
    add_column :routes, :planner_geometry, :jsonb

    # Routing Waypoints (§3.2): user-defined control points, stored
    # independently from the calculated geometry. +position+ is the order in
    # the route and determines the segment sequence.
    create_table :routing_waypoints do |t|
      t.references :route, null: false, foreign_key: true
      t.integer :position, null: false
      t.float :lat, null: false
      t.float :lon, null: false

      t.timestamps
    end
    add_index :routing_waypoints, %i[route_id position], unique: true

    # Shaping Points (§3.3): drag-created routing constraints. Each belongs
    # to a specific segment (between two consecutive RW) and keeps its
    # ordering within that segment — the pair of indexes is the SP-to-segment
    # association that must survive saving and reopening (§5.2).
    create_table :shaping_points do |t|
      t.references :route, null: false, foreign_key: true
      t.integer :segment_index, null: false
      t.integer :position, null: false
      t.float :lat, null: false
      t.float :lon, null: false

      t.timestamps
    end
    add_index :shaping_points, %i[route_id segment_index position],
              name: "index_shaping_points_on_route_segment_position"

    # Points of Interest (§3.4): user annotations that never affect routing.
    # +routing_waypoint_id+ is the optional "converted from this RW" link —
    # nullable, and nullified (never deleted) when the RW goes away.
    create_table :route_pois do |t|
      t.references :route, null: false, foreign_key: true
      t.references :routing_waypoint, null: true, foreign_key: { on_delete: :nullify }
      t.float :lat, null: false
      t.float :lon, null: false
      t.string :title
      t.text :description
      t.string :external_url

      t.timestamps
    end
  end
end
