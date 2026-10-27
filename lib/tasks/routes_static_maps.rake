# frozen_string_literal: true

namespace :routes do
  desc "Attach Mapbox static map thumbs to routes parsed before the feature existed"
  task backfill_static_maps: :environment do
    unless Mapbox::StaticImage.access_token
      abort "No Mapbox token configured (credentials :mapbox/:access_token or ENV MAPBOX_ACCESS_TOKEN) — nothing to fetch."
    end

    # The service reports render failures via Rails.logger.warn, which in dev
    # only lands in log/development.log. Broadcast to stderr as well so a
    # skipped route's actual reason (HTTP status, timeout) is visible right
    # next to the task's own "Skipped route ..." lines.
    Rails.logger = ActiveSupport::BroadcastLogger.new(Rails.logger, ActiveSupport::Logger.new($stderr))

    # Idempotent scope: routes with a GPX but no thumb yet, so re-running the
    # task retries exactly the routes a previous run could not attach.
    scope = Route.joins(:gpx_file_attachment).where.missing(:static_map_attachment)
    processed = attached = skipped = failed = 0

    scope.find_each do |route|
      processed += 1
      # Thumb-only on purpose: generate_static_map! reads just the trackpoints
      # and never re-runs the stats parse, so durations edited by hand on the
      # detail page survive the backfill untouched.
      route.generate_static_map!
      if route.static_map.attached?
        attached += 1
      else
        skipped += 1
        warn "Skipped route ##{route.id} (#{route.title}): no usable track or Mapbox request failed."
      end
    rescue StandardError => e
      failed += 1
      warn "Failed route ##{route.id} (#{route.title}): #{e.class} #{e.message}"
    end

    puts "Processed #{processed} routes: #{attached} thumbs attached, #{skipped} skipped, #{failed} failed."
  end
end
