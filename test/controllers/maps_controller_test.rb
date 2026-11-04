# frozen_string_literal: true

require "test_helper"

# The My Map page and its two GeoJSON endpoints (technote.MYMAP-FEATURE.md
# §4/§5). The suite pins the authorization contract: own routes are always
# the viewer's (private included), and the public query returns ONLY routes
# that are publicly viewable under the Phase 9 rules (owner's calendar share
# live + scheduled) intersecting the requested viewport.
class MapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @viewer = User.create!(valid_user_attributes)
    sign_in @viewer

    @public_owner = User.create!(valid_user_attributes(email: "public@example.com", username: "public_rider"))
    @public_owner.update!(calendar_public: true)
    @public_route = tracked_route(@public_owner, "Public coastal loop")
    # Public visibility (Phase 9) = live share + the ride scheduled on the
    # owner's own calendar — give the fixture route its entry.
    @public_owner.calendar_entries.create!(route: @public_route, scheduled_on: Date.current + 1,
                                           start_time: "08:00", end_time: "10:00")
    @hidden_library_route = @public_owner.routes.create!(source: "upload", title: "Unscheduled ride")
    attach_track(@hidden_library_route)

    @private_owner = User.create!(valid_user_attributes(email: "private@example.com", username: "shy_rider"))
    @private_route = tracked_route(@private_owner, "Secret alpine pass")

    @own_route = tracked_route(@viewer, "My Zurich loop")
  end

  # ---- page ----------------------------------------------------------------

  test "the map page requires sign-in" do
    sign_out @viewer

    get map_path
    assert_redirected_to new_user_session_path
  end

  test "the map page renders with the map workspace and nav highlighting" do
    get map_path

    assert_response :success
    assert_select "div[data-controller=\"my-map\"]"
    assert_select "nav.app-nav a.app-nav__link--active", text: "My Map"
  end

  # ---- own routes (§4.1) ---------------------------------------------------

  test "own routes returns every route of the viewer, private included" do
    get own_map_routes_path, headers: { Accept: "application/json" }

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "FeatureCollection", payload["type"]
    assert_equal 1, payload["features"].size

    properties = payload["features"].first["properties"]
    assert_equal @own_route.id, properties["id"]
    assert_equal "My Zurich loop", properties["title"]
    assert_equal true, properties["own"]
    assert_equal route_path(@own_route), properties["url"]
  end

  test "own routes never includes anyone else's routes" do
    get own_map_routes_path, headers: { Accept: "application/json" }

    payload = JSON.parse(response.body)
    ids = payload["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @public_route.id
    assert_not_includes ids, @private_route.id
    assert_not_includes ids, @hidden_library_route.id
  end

  test "own routes flags which of the viewer's rides are publicly scheduled" do
    @viewer.update!(calendar_public: true)
    @viewer.calendar_entries.create!(route: @own_route, scheduled_on: Date.current + 1,
                                     start_time: "08:00", end_time: "10:00")

    get own_map_routes_path, headers: { Accept: "application/json" }

    properties = JSON.parse(response.body)["features"].first["properties"]
    assert_equal true, properties["public"]
  end

  # ---- public routes (§4.2/§5.1) --------------------------------------------

  test "public routes returns other users' public rides intersecting the viewport" do
    get public_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    assert_response :success
    payload = JSON.parse(response.body)
    ids = payload["features"].map { |feature| feature["properties"]["id"] }

    assert_includes ids, @public_route.id
    # Phase 9 visibility contract in SQL: unscheduled library rides and
    # private-calendar owners stay invisible even inside the viewport.
    assert_not_includes ids, @hidden_library_route.id
    assert_not_includes ids, @private_route.id
    assert payload["features"].all? { |feature| feature["properties"]["own"] == false }
  end

  test "public routes excludes the viewer's own public ride (it ships via own routes)" do
    @viewer.update!(calendar_public: true)
    @viewer.calendar_entries.create!(route: @own_route, scheduled_on: Date.current + 1,
                                     start_time: "08:00", end_time: "10:00")

    get public_map_routes_path, params: viewport, headers: { Accept: "application/json" }

    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @own_route.id
  end

  test "public routes skips rides outside the requested viewport" do
    get public_map_routes_path, params: {
      west: "0.0", south: "10.0", east: "1.0", north: "11.0"
    }, headers: { Accept: "application/json" }

    payload = JSON.parse(response.body)
    assert_equal "FeatureCollection", payload["type"]
    assert_empty payload["features"]
  end

  test "public routes requires sign-in" do
    sign_out @viewer

    get public_map_routes_path, params: viewport
    assert_redirected_to new_user_session_path
  end

  test "public routes answers 400 for malformed bounds" do
    get public_map_routes_path, params: {
      west: "not-a-number", south: "47.0", east: "9.0", north: "48.0"
    }, headers: { Accept: "application/json" }

    assert_response :bad_request
    assert JSON.parse(response.body)["error"].present?
  end

  test "public routes answers 400 for inverted latitude bounds" do
    get public_map_routes_path, params: {
      west: "8.0", south: "48.0", east: "9.0", north: "47.0"
    }, headers: { Accept: "application/json" }

    assert_response :bad_request
  end

  # ---- delta loading (exclude_ids) --------------------------------------------

  test "public routes omits routes the client already loaded" do
    other = tracked_route(@public_owner, "Second public climb")
    @public_owner.calendar_entries.create!(route: other, scheduled_on: Date.current + 2,
                                           start_time: "08:00", end_time: "10:00")

    get public_map_routes_path,
        params: viewport.merge(exclude_ids: @public_route.id.to_s),
        headers: { Accept: "application/json" }

    assert_response :success
    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_not_includes ids, @public_route.id
    assert_includes ids, other.id
    # Exclusion never widens visibility: the Phase 9 rules still hide the
    # unscheduled library ride and the private owner's track.
    assert_not_includes ids, @hidden_library_route.id
    assert_not_includes ids, @private_route.id
  end

  test "public routes ignores exclude_ids matching nothing" do
    get public_map_routes_path,
        params: viewport.merge(exclude_ids: "99999999"),
        headers: { Accept: "application/json" }

    assert_response :success
    ids = JSON.parse(response.body)["features"].map { |feature| feature["properties"]["id"] }
    assert_includes ids, @public_route.id
  end

  test "public routes answers 400 for malformed exclude_ids" do
    get public_map_routes_path,
        params: viewport.merge(exclude_ids: "1,not-an-id"),
        headers: { Accept: "application/json" }

    assert_response :bad_request
    assert JSON.parse(response.body)["error"].present?
  end

  private

  def viewport
    # Zurich-area box covering the exploration.gpx fixture track.
    { west: "8.0", south: "47.0", east: "9.0", north: "48.0" }
  end

  # A route with an attached, parsed GPX (bounds captured by the parse).
  def tracked_route(owner, title)
    route = owner.routes.create!(source: "upload", title: title)
    attach_track(route)
    route
  end

  def attach_track(route)
    route.gpx_file.attach(gpx_fixture_upload("exploration.gpx"))
    route.parse_gpx!
  end
end
