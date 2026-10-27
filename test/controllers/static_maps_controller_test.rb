# frozen_string_literal: true

require "test_helper"

# The cacheable endpoint behind route_static_map_thumb (every card that shows
# a route's map image). Instead of ActiveStorage's redirect-to-a-5-minute-URL
# chain (re-fetched inside fragment-cached cards), the blob streams directly
# with a year-long immutable cache, so the browser fetches each thumb once
# and then never asks again.
class StaticMapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    @route = @user.routes.create!(source: "upload", title: "Ridge loop")
    @route.gpx_file.attach(gpx_fixture_upload("ridge_loop.gpx"))
    @route.static_map.attach(static_map_upload)
  end

  test "serves the map bytes inline with an immutable year-long cache" do
    get route_static_map_path(@route.static_map.blob.signed_id)

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal "inline", response.headers["Content-Disposition"].split(";").first
    # Rails normalizes Cache-Control directives on commit (canonical order:
    # max-age first), so assert the directive set, not the raw ordering.
    assert_equal "public, max-age=#{1.year.to_i}, immutable".split(", ").sort,
                 response.headers["Cache-Control"].split(", ").sort
    assert_equal File.binread(Rails.root.join("test/fixtures/files/avatar.png")), response.body
  end

  test "guests may fetch thumbs (the public calendar share renders them)" do
    get route_static_map_path(@route.static_map.blob.signed_id)

    assert_response :success
  end

  test "a re-attach rotates the URL, so caches can never serve stale bytes" do
    old_path = route_static_map_path(@route.static_map.blob.signed_id)

    @route.static_map.attach(static_map_upload)

    assert_not_equal old_path, route_static_map_path(@route.reload.static_map.blob.signed_id)
  end

  test "tampered signed ids 404" do
    get route_static_map_path("not-a-signature")

    assert_response :not_found
  end

  test "purged thumbs 404 instead of serving a dangling blob" do
    signed_id = @route.static_map.blob.signed_id
    @route.static_map.purge

    get route_static_map_path(signed_id)

    assert_response :not_found
  end

  test "non-thumb blobs (e.g. the route's GPX) are refused" do
    get route_static_map_path(@route.gpx_file.blob.signed_id)

    assert_response :not_found
  end

  private

  # Any PNG payload works: the endpoint streams blobs verbatim, it never
  # decodes them. Reuses the avatar fixture's bytes.
  def static_map_upload
    Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/avatar.png").to_s, "image/png", false,
      original_filename: "static-map.png"
    )
  end
end
