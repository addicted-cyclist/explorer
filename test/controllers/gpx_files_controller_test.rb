# frozen_string_literal: true

require "test_helper"

class GpxFilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    @route = @user.routes.create!(source: "upload", title: "Ridge loop")
    @route.gpx_file.attach(
      io: File.open(Rails.root.join("test/fixtures/files/exploration.gpx")),
      filename: "exploration.gpx",
      content_type: "application/gpx+xml"
    )
  end

  # The gpx.studio embed fetches the file cross-origin without a session, so
  # the signed_id alone must grant access (no sign-in) with permissive CORS —
  # including the Private Network Access grant, because the embed is a public
  # page fetching our loopback/dev host.
  test "streams the gpx publicly with cors headers and no sign-in only for https://gpx.studio" do
    get gpx_file_path(@route.gpx_file.blob.signed_id, "exploration.gpx")

    assert_response :success
    assert_equal "https://gpx.studio", response.headers["Access-Control-Allow-Origin"]
    assert_match(/inline/, response.headers["Content-Disposition"])
    assert_match(/<gpx/i, response.body)
  end

  # Chrome's PNA preflight for the embed's loopback fetch. It must succeed
  # unconditionally — a bogus signed_id must not 404 the grant.
  test "grants the private network access preflight only for https://gpx.studio" do
    process :options, gpx_file_path("bogus-signature", "exploration.gpx")

    assert_response :no_content
    assert_equal "https://gpx.studio", response.headers["Access-Control-Allow-Origin"]
    assert_match(/GET, OPTIONS/, response.headers["Access-Control-Allow-Methods"])
  end

  test "404s on a tampered signed id" do
    get gpx_file_path("bogus-signature", "exploration.gpx")

    assert_response :not_found
  end
end
