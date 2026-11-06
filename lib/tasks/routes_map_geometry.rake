# frozen_string_literal: true

namespace :routes do
  desc "Backfill stored map geometry (drawn line + profile chart) for routes parsed before the column existed"
  task backfill_map_geometry: :environment do
    # Idempotent scope: routes with a GPX but no stored geometry yet, so
    # re-running retries exactly the routes a previous run could not read.
    # (A route whose GPX yields no usable trackpoints stores the nil-geometry
    # hash instead of staying nil — the map feature's self-heal then never
    # re-attempts it on every request.)
    scope = Route.joins(:gpx_file_attachment).where(map_geometry: nil)
    processed = updated = skipped = failed = 0

    scope.find_each do |route|
      processed += 1
      geometry = Map::TrackGeometry.build(route.track_coordinates)
      if geometry["coordinates"]
        # update_columns: a pure derived-data backfill must not bump
        # updated_at (fragment caches keyed on the route stay valid) and has
        # nothing for validations to say about a JSON blob.
        route.update_columns(map_geometry: geometry)
        updated += 1
      else
        route.update_columns(map_geometry: geometry)
        skipped += 1
        warn "Skipped route ##{route.id} (#{route.title}): no drawable trackpoints."
      end
    rescue StandardError => e
      failed += 1
      warn "Failed route ##{route.id} (#{route.title}): #{e.class} #{e.message}"
    end

    puts "Processed #{processed} routes: #{updated} geometry stored, #{skipped} skipped, #{failed} failed."
  end
end
