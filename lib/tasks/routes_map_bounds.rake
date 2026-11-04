# frozen_string_literal: true

namespace :routes do
  desc "Backfill map bounding boxes for routes parsed before the map feature existed"
  task backfill_map_bounds: :environment do
    # Idempotent scope: routes with a GPX but no bounding box yet, so
    # re-running retries exactly the routes a previous run could not read.
    scope = Route.joins(:gpx_file_attachment).where(min_lat: nil)
    processed = updated = skipped = failed = 0

    scope.find_each do |route|
      processed += 1
      coords = route.track_coordinates
      if coords.size >= 2
        # update_columns: a pure derived-data backfill must not bump
        # updated_at (fragment caches keyed on the route stay valid) and has
        # nothing for validations to say about four floats.
        route.update_columns(Route.map_bounds_from(coords))
        updated += 1
      else
        skipped += 1
        warn "Skipped route ##{route.id} (#{route.title}): no usable trackpoints."
      end
    rescue StandardError => e
      failed += 1
      warn "Failed route ##{route.id} (#{route.title}): #{e.class} #{e.message}"
    end

    puts "Processed #{processed} routes: #{updated} bounds set, #{skipped} skipped, #{failed} failed."
  end
end
