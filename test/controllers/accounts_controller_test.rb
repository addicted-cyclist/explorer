# frozen_string_literal: true

require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
  end

  # ---- Phase 9 — public calendar share (kept from the share-only page) -----

  test "show renders the full settings page with all sections" do
    get account_path

    assert_response :success
    assert_select "h1", text: "My account"
    assert_select "h2", text: "Profile & Personal Info"
    assert_select "h2", text: "Sharing & Privacy"
    assert_select "h2", text: "Security & Password"
    assert_select "h2", text: "Connected Accounts"
    assert_select "h2", text: "Danger Zone"
    assert_match "@#{@user.username}", response.body
    assert_match "Private — only friends can view", response.body
    # No share link while the calendar is private
    assert_select ".account__share", count: 0
  end

  test "update turns the calendar public, generating a share token" do
    patch account_path, params: { user: { calendar_public: "1" } }

    assert_redirected_to account_path
    assert_match(/calendar is public/, flash[:notice])
    @user.reload
    assert @user.calendar_public?
    assert @user.public_token.present?

    get account_path
    assert_match public_calendar_url(@user.public_token), response.body
  end

  test "update turns the calendar private again, clearing the token" do
    @user.update!(calendar_public: true)

    patch account_path, params: { user: { calendar_public: "0" } }

    assert_redirected_to account_path
    assert_match(/calendar is private/, flash[:notice])
    @user.reload
    refute @user.calendar_public?
    assert_nil @user.public_token
  end

  # ---- Phase 12 — profile editor ---------------------------------------------

  test "update applies the profile fields" do
    patch account_path, params: {
      user: { first_name: "Alex", last_name: "Antoni", username: "alex_antoni",
              email: "alex@example.com" }
    }

    assert_redirected_to account_path
    assert_match(/profile has been updated/i, flash[:notice])
    @user.reload
    assert_equal "Alex", @user.first_name
    assert_equal "alex@example.com", @user.email
  end

  test "update rejects an invalid username with the error summary" do
    patch account_path, params: { user: { username: "bad name!" } }

    assert_response :unprocessable_entity
    assert_match "Username can only contain letters, numbers and underscores", response.body
    assert_equal valid_user_attributes[:username], @user.reload.username
  end

  test "update rejects a username that is already taken (case-insensitive)" do
    User.create!(valid_user_attributes(email: "other@example.com", username: "taken_name"))

    patch account_path, params: { user: { username: "TAKEN_NAME" } }

    assert_response :unprocessable_entity
    assert_equal valid_user_attributes[:username], @user.reload.username
  end

  test "update ignores password fields (no mass assignment)" do
    patch account_path, params: { user: { first_name: "Newname", password: "hijacked123" } }

    assert_redirected_to account_path
    @user.reload
    assert_equal "Newname", @user.first_name
    assert @user.valid_password?("password123")
  end

  # ---- Phase 12 — avatar -------------------------------------------------------

  test "update attaches an avatar upload" do
    patch account_path, params: { user: { avatar: avatar_upload } }

    assert_redirected_to account_path
    assert @user.reload.avatar.attached?

    get account_path
    assert_select "img.account-avatar__img"
    # The avatar must point at the cacheable signed-id endpoint, never at
    # ActiveStorage's redirect chain (re-fetched on every page view).
    assert_select %(img.account-avatar__img[src^="/avatars/"])
    assert_no_match %r{/rails/active_storage/}, response.body
  end

  test "update rejects an avatar that is not real image content" do
    patch account_path, params: { user: { avatar: avatar_upload("notes.png", "text/plain",
                                                                content: "definitely not an image") } }

    assert_response :unprocessable_entity
    assert_match "Avatar must be a JPG, PNG or WebP image", response.body
    refute @user.reload.avatar.attached?
  end

  test "remove avatar purges the attachment" do
    @user.update!(avatar: avatar_upload)

    delete avatar_account_path

    assert_redirected_to account_path
    assert_match(/avatar has been removed/, flash[:notice])
    refute @user.reload.avatar.attached?
  end


  # ---- Phase 12 — password change ---------------------------------------------

  test "password change with the correct current password" do
    patch password_account_path, params: {
      user: { current_password: "password123", password: "brandnew123",
              password_confirmation: "brandnew123" }
    }

    assert_redirected_to account_path
    assert_match(/password has been changed/, flash[:notice])
    assert @user.reload.valid_password?("brandnew123")
  end

  test "password change requires the current password" do
    patch password_account_path, params: {
      user: { current_password: "wrong", password: "brandnew123",
              password_confirmation: "brandnew123" }
    }

    assert_response :unprocessable_entity
    assert @user.reload.valid_password?("password123")
  end

  test "password change follows Devise length rules" do
    patch password_account_path, params: {
      user: { current_password: "password123", password: "short",
              password_confirmation: "short" }
    }

    assert_response :unprocessable_entity
    assert_match "Password is too short", response.body
    assert @user.reload.valid_password?("password123")
  end

  test "password change requires a matching confirmation" do
    patch password_account_path, params: {
      user: { current_password: "password123", password: "brandnew123",
              password_confirmation: "different" }
    }

    assert_response :unprocessable_entity
    assert @user.reload.valid_password?("password123")
  end

  # ---- Phase 12 — account deletion ---------------------------------------------

  test "destroy deletes the account and cascades both friendship directions" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com", username: "friend_rider"))
    Friendship.connect!(@user, friend)
    # Incoming request: a row where the account is the friend_id target —
    # the edge that used to trip the FK constraint on delete.
    requester = User.create!(valid_user_attributes(email: "requester@example.com", username: "requester"))
    Friendship.send_request!(requester, @user)
    @user.routes.create!(title: "Ridge loop")

    assert_difference "User.count", -1 do
      assert_difference "Friendship.count", -3 do
        delete account_path
      end
    end

    assert_redirected_to unauthenticated_root_path
    assert_match(/account has been deleted/, flash[:notice])
    assert_not User.exists?(@user.id)
    assert_empty Friendship.where(user_id: @user.id)
    assert_empty Friendship.where(friend_id: @user.id)
    # Signed out on the way out
    get account_path
    assert_redirected_to new_user_session_path
  end

  test "guests are redirected to sign in" do
    sign_out @user

    get account_path

    assert_redirected_to new_user_session_path
  end

  private

  # A tiny PNG fixture handle; original_filename/content_type are what the
  # controller sees, exactly like a browser would send them. `content:`
  # swaps in custom bytes (like gpx_fixture_upload) — used to fake a
  # non-image upload, which ActiveStorage's identify step then sniffs.
  def avatar_upload(name = "avatar.png", content_type = "image/png", content: nil)
    if content
      dir = Dir.mktmpdir("explorer-test")
      path = File.join(dir, "payload.bin")
      File.write(path, content)
    else
      path = Rails.root.join("test/fixtures/files/avatar.png")
    end

    Rack::Test::UploadedFile.new(path.to_s, content_type, false, original_filename: name)
  end
end
