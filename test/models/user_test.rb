# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
  end

  # ---- Phase 9 — public share token (ensure_public_token callback) ---------

  test "making the calendar public generates an unguessable share token" do
    @user.update!(calendar_public: true)

    assert_predicate @user, :calendar_public?
    assert @user.public_token.present?
    # urlsafe_base64(32) → 43-char token, no "+" or "/" to mangle URLs
    assert_match(/\A[\w-]{43}\z/, @user.public_token)
  end

  test "re-saving a public calendar keeps the same token" do
    @user.update!(calendar_public: true)
    token = @user.public_token

    @user.update!(first_name: "Renamed")

    assert_equal token, @user.reload.public_token
  end

  test "making the calendar private clears the token, killing old share links" do
    @user.update!(calendar_public: true)
    @user.update!(calendar_public: false)

    assert_not_predicate @user, :calendar_public?
    assert_nil @user.public_token
  end

  test "re-enabling the share mints a fresh token" do
    @user.update!(calendar_public: true)
    stale_token = @user.public_token
    @user.update!(calendar_public: false)
    @user.update!(calendar_public: true)

    assert_not_equal stale_token, @user.public_token
  end
end
