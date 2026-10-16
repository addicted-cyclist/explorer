# frozen_string_literal: true

require "test_helper"

# The cacheable avatar endpoint behind .account-avatar__img. Instead of
# ActiveStorage's redirect-to-a-5-minute-URL chain (re-fetched on every page
# view), the blob streams directly with a year-long immutable cache, so the
# browser fetches each avatar once and then never asks again.
class AvatarsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    @user.avatar.attach(avatar_upload)
  end

  test "serves the avatar bytes inline with an immutable year-long cache" do
    get user_avatar_path(@user.avatar.blob.signed_id)

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal "inline", response.headers["Content-Disposition"].split(";").first
    # Rails normalizes Cache-Control directives on commit (canonical order:
    # max-age first), so assert the directive set, not the raw ordering.
    assert_equal "public, max-age=#{1.year.to_i}, immutable".split(", ").sort,
                 response.headers["Cache-Control"].split(", ").sort
    assert_equal File.binread(Rails.root.join("test/fixtures/files/avatar.png")), response.body
  end

  test "guests may fetch avatars (the public calendar renders the owner's pip)" do
    get user_avatar_path(@user.avatar.blob.signed_id)

    assert_response :success
  end

  test "a re-upload rotates the URL, so caches can never serve stale bytes" do
    old_path = user_avatar_path(@user.avatar.blob.signed_id)

    @user.avatar.attach(avatar_upload)

    assert_not_equal old_path, user_avatar_path(@user.avatar.blob.signed_id)
  end

  test "tampered signed ids 404" do
    get user_avatar_path("not-a-signature")

    assert_response :not_found
  end

  test "purged avatars 404 instead of serving a dangling blob" do
    signed_id = @user.avatar.blob.signed_id
    @user.avatar.purge

    get user_avatar_path(signed_id)

    assert_response :not_found
  end

  test "non-avatar blobs (e.g. a route's GPX) are refused" do
    route = @user.routes.create!(source: "upload", title: "Ridge loop")
    route.gpx_file.attach(gpx_fixture_upload("ridge_loop.gpx"))

    get user_avatar_path(route.gpx_file.blob.signed_id)

    assert_response :not_found
  end

  private

  def avatar_upload
    Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/avatar.png").to_s, "image/png", false,
      original_filename: "avatar.png"
    )
  end
end
