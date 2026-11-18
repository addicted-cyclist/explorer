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
  #     case-insensitive ILIKE patterns instead of exact values — see
  #     SPORT_CATEGORIES, the single definition of the categories themselves.
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
    # Sport categories — the SINGLE SOURCE OF TRUTH for the whole "Find new
    # routes" flow. The modal's segment buttons (maps/show.html.erb via
    # MapsHelper#find_sport_categories), the drawer's chip copy (shipped to
    # the my-map controller as a Stimulus value) and the SQL matching below
    # all read from this hash, so adding a category is a one-line change.
    #
    # label:    UI copy ("Road", "Gravel", "MTB").
    # patterns: ILIKE patterns over routes.sport_type, which is FREE TEXT on
    #           the route ("Road Cycling", "Gravel 50k", "MTB",
    #           "Mountain biking", "Ride", ...), so categories match through
    #           case-insensitive patterns instead of exact values.
    # default:  true for the category a route with a BLANK sport_type belongs
    #           to. The UI has always displayed such routes as "Road bike"
    #           (RoutesHelper#sport_type_label, and the map drawer's own
    #           fallback), so the matcher must agree — otherwise a route's
    #           badge says "Road bike" while the Road filter hides it.
    #           Exactly one category is the default.
    SPORT_CATEGORIES = {
      "road" => { label: "Road", patterns: [ "%road%" ], default: true },
      "gravel" => { label: "Gravel", patterns: [ "%gravel%" ] },
      "mtb" => { label: "MTB", patterns: [ "%mtb%", "%mountain%", "%cross%" ] }
    }.freeze


    # Derived from SPORT_CATEGORIES — the matching code and the controller's
    # validation both read the patterns through this name.
    SPORT_PATTERNS = SPORT_CATEGORIES.transform_values { |category| category[:patterns] }.freeze

    # The category blank sport_type values resolve to (the one the UI labels
    # such routes with). Nil only if no category declares default: true.
    SPORT_DEFAULT_CATEGORY = SPORT_CATEGORIES.find { |_, category| category[:default] }&.first

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

      # One category's rows: the ILIKE pattern match, UNIONed with the blank
      # sport_type rows when this category is the display default (see
      # SPORT_CATEGORIES[:default]). The union keeps the route's badge and the
      # filter in agreement — a route the UI labels "Road bike" is a Road
      # match. Written as two independent predicates inside one where clause
      # (not .or) so it composes with every other scope on +scope+ — .or
      # would reject a structurally-incompatible relation such as one built
      # with includes/joins by the controller.
      def filter_sport(scope, category)
        patterns = SPORT_PATTERNS[category]
        return scope unless patterns

        if SPORT_DEFAULT_CATEGORY == category
          scope.where(
            "routes.sport_type ILIKE ANY (ARRAY[?]) OR routes.sport_type IS NULL " \
            "OR routes.sport_type = ''",
            patterns
          )
        else
          scope.where("routes.sport_type ILIKE ANY (ARRAY[?])", patterns)
        end
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
