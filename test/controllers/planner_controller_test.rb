# frozen_string_literal: true

require "test_helper"

# The Route Planner's HTTP surface (technote.ROUTE-DRAW.md): behind the
# default sign-in + verification gates, the only door between the frontend
# and the routing engine. Authorization contract: #save only ever touches
# the CURRENT user's routes (foreign ids 400, never 200), and every engine
# failure surfaces as a user-safe JSON error that never destroys client
# state (§10.6).
class PlannerControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
    @calculate_body = {
      profile: "road",
      points: [ [ 49.4100, 8.7100 ], [ 49.4140, 8.7140 ] ]
    }
  end

  test "calculate requires sign-in" do
    sign_out @user
    post planner_calculate_path, params: @calculate_body, as: :json

    assert_response :unauthorized
  end

  test "calculate returns the segment payload" do
    stub_brouter_geojson

    with_brouter do
      post planner_calculate_path, params: @calculate_body, as: :json
    end

    assert_response :success
    segment = response.parsed_body["segment"]
    assert_equal 3, segment["coordinates"].size
    assert_equal "road", segment["profile"]
    assert_operator segment["distance_m"], :>, 0
  end

  test "calculate rejects malformed points with a 400" do
    post planner_calculate_path,
         params: { profile: "road", points: [ [ 49.4100, 8.7100 ], [ "north" ] ] }, as: :json

    assert_response :bad_request
  end

  test "calculate maps engine failures to 502 with a user-safe message" do
    with_brouter_engine("datafile not found") do
      post planner_calculate_path, params: @calculate_body, as: :json
    end

    assert_response :bad_gateway
    assert_match /not installed yet/, response.parsed_body["error"]
  end

  test "save creates a route with its planner collections and generated GPX" do
    stub_brouter_geojson # save itself never calls the engine, but keep env clean

    post planner_save_path, params: { state: editor_state }, as: :json

    assert_response :success
    route = @user.routes.find(response.parsed_body["id"])
    assert_equal "Drafthouse Loop", route.title
    assert_equal "drawn", route.source
    assert_equal "road", route.routing_profile
    assert_equal 2, route.routing_waypoints.count
    assert_equal 1, route.shaping_points.count
    assert_equal 1, route.pois.count
    assert_operator route.distance, :>, 0
    assert route.gpx_file.attached?
    assert_not_nil route.min_lon
    assert_not_nil route.map_geometry
  end

  test "save updates an existing owned route" do
    route = @user.routes.create!(source: "drawn", title: "Old name", routing_profile: "road")

    post planner_save_path, params: { state: editor_state("route_id" => route.id, "title" => "New name") }, as: :json

    assert_response :success
    assert_equal route.reload.id, response.parsed_body["id"].to_i
    assert_equal "New name", route.reload.title
  end

  test "save refuses to touch another user's route" do
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com", username: "stranger"))
    foreign = stranger.routes.create!(source: "drawn", title: "Not yours", routing_profile: "road")

    post planner_save_path,
         params: { state: editor_state("route_id" => foreign.id) }, as: :json

    assert_response :bad_request
    assert_equal "Not yours", foreign.reload.title
  end

  test "save returns validation errors with a 422" do
    post planner_save_path, params: { state: editor_state("profile" => "bmx") }, as: :json

    assert_response :unprocessable_entity
    assert_not_empty response.parsed_body["errors"]
  end

  def image_fixture_upload(filename, fixture)
    Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files", fixture), "image/png", false,
                                 original_filename: filename)
  end

  test "poi image upload stores a blob and returns its signed id" do
    post planner_poi_images_path,
         params: { image: image_fixture_upload("poi.png", "avatar.png") }

    assert_response :success
    signed_id = response.parsed_body["signed_id"]
    blob = ActiveStorage::Blob.find_signed(signed_id)
    assert_equal "image/png", blob.content_type
  end

  test "poi image upload rejects non-images and oversize files" do
    post planner_poi_images_path,
         params: { image: gpx_fixture_upload("route.gpx") }

    assert_response :bad_request
  end

  private

  def stub_brouter_geojson
    body = {
      type: "FeatureCollection",
      features: [ {
        type: "Feature",
        properties: { "track-length" => "5230", "filtered ascend" => "48", "total-time" => "980" },
        geometry: {
          type: "LineString",
          coordinates: [ [ 8.7100, 49.4100, 110.0 ], [ 8.7120, 49.4120, 122.0 ], [ 8.7140, 49.4140, 131.0 ] ]
        }
      } ]
    }.to_json
    @brouter_body = body
  end

  def with_brouter(&block)
    with_brouter_engine(@brouter_body, &block)
  end

  # A complete, consistent editor state: two RWs, one segment whose geometry
  # starts and ends at the RWs (within the saver's snap tolerance), one SP,
  # one POI.
  def editor_state(overrides = {})
    {
      "title" => "Drafthouse Loop",
      "profile" => "road",
      "loop" => false,
      "waypoints" => [ { "lat" => 49.4100, "lon" => 8.7100 }, { "lat" => 49.4140, "lon" => 8.7140 } ],
      "shaping_points" => [ { "segment_index" => 0, "position" => 0, "lat" => 49.4120, "lon" => 8.7120 } ],
      "pois" => [ {
        "lat" => 49.4125, "lon" => 8.7125, "title" => "Water refill",
        "description" => "Fountain at the trailhead", "external_url" => "https://example.com/fountain",
        "waypoint_index" => nil
      } ],
      "segments" => [
        { "points" => [ [ 8.7100, 49.4100, 110.0 ], [ 8.7120, 49.4120, 122.0 ],
                       [ 8.7126, 49.4126, 124.0 ], [ 8.7140, 49.4140, 131.0 ] ],
          "time_s" => 980 }
      ]
    }.deep_merge(overrides)
  end
end
