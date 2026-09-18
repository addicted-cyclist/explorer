# frozen_string_literal: true

require "test_helper"

class FriendsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
  end

  test "index lists accepted friends and nobody else" do
    pal = User.create!(valid_user_attributes(email: "pal@example.com"))
    Friendship.connect!(pal, @user)
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    get friends_url

    assert_response :success
    assert_match(/#{Regexp.escape(pal.username)}/, response.body)
    assert_no_match(/#{Regexp.escape(stranger.username)}/, response.body)
  end

  test "index redirects guests to sign in" do
    sign_out @user

    get friends_url

    assert_redirected_to new_user_session_path
  end
end
