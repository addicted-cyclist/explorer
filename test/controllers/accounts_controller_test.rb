# frozen_string_literal: true

require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
  end

  test "show renders the profile summary and the public calendar card" do
    get account_path

    assert_response :success
    assert_select "h1", text: "My account"
    assert_select "h2", text: "Profile"
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

  test "update only permits the share toggle (no mass assignment)" do
    patch account_path, params: { user: { calendar_public: "1", username: "hijacked" } }

    assert_redirected_to account_path
    @user.reload
    assert_equal valid_user_attributes[:username], @user.username
  end

  test "guests are redirected to sign in" do
    sign_out @user

    get account_path

    assert_redirected_to new_user_session_path
  end
end
