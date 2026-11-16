# frozen_string_literal: true

module Map
  # Server-side parameter matching for the "Find new routes" flow
  # (design-refs/stitch_explorer_v0.14): narrows a route scope by sport
  # category, distance range, elevation-gain cap and duration range, so the
  # matching semantics live in exactly one place — the drawer's "N routes
  # match current filters" count must agree with what the map draws.
  #
  # Semantics:
  #   * sport_type is free text on the route ("Road Cycling", "Gravel 50k",
  #     "MTB", "Mountain biking", "Ride", ...), so categories match through
  #     case-insensitive ILIKE patterns instead of exact values.
  #   * Open-ended bounds are simply absent keys — the client omits the
  #     param when a slider thumb parks on its end ("180+ km", "3,000+ m").
  #   * Routes with NULL stats drop out of an active comparison on their own
  #     (NULL >= x is never true in SQL): an unmeasured route can never
  #     claim to satisfy a filter it has no data for. With no filters at
  #     all the scope passes through untouched.
  #
  # Every condition is parameterized (bound arrays / where hashes) — request
  # data never reaches the SQL text.
  class RouteFinder
    # Sport category → ILIKE patterns over routes.sport_type.
    SPORT_PATTERNS = {
      "road" => [ "%road%" ],
      "gravel" => [ "%gravel%" ],
      "mtb" => [ "%mtb%", "%mountain%", "%cross%" ]
    }.freeze

    # Keys the finder understands; anything else is dropped, so a stale or
    # hostile client can never smuggle arbitrary column filters through.
    FILTER_KEYS = %i[
      sport_type distance_min distance_max
      elevation_max duration_min duration_max
    ].freeze

    class << self
      # Filtered relation. +filters+ is a symbol-keyed, already-validated
      # hash (MapsController#set_recommendation_filters); unknown keys are
      # ignored and absent bounds mean "open".
      def call(scope, filters:)
        filters = filters.slice(*FILTER_KEYS).compact
        scope = filter_sport(scope, filters[:sport_type])
        scope = filter_range(scope, :distance, filters[:distance_min],
                             filters[:distance_max])
        scope = filter_range(scope, :elevation_gain, nil,
                             filters[:elevation_max])
        filter_range(scope, :duration, filters[:duration_min],
                     filters[:duration_max])
      end

      private

      def filter_sport(scope, category)
        patterns = SPORT_PATTERNS[category]
        return scope unless patterns

        scope.where("routes.sport_type ILIKE ANY (ARRAY[?])", patterns)
      end

      # Inclusive min/max bounds as beginless/endless ranges; NULL stats
      # never satisfy an active comparison.
      def filter_range(scope, column, min, max)
        scope = scope.where(routes: { column => min.. }) if min
        scope = scope.where(routes: { column => ..max }) if max
        scope
      end
    end
  end
end
