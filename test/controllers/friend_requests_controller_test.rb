# frozen_string_literal: true

require "test_helper"

class FriendRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    @other = User.create!(valid_user_attributes(email: "other@example.com"))
    sign_in @user
  end

  # ---- create (send a request from the popup) -------------------------------

  test "create sends a pending request and repaints the popup row" do
    assert_difference -> { Friendship.pending.count }, 1 do
      post friend_requests_url, params: { friend_id: @other.id },
           headers: { "ACCEPT" => Mime[:turbo_stream].to_s }
    end

    assert_response :success
    assert_equal Mime[:turbo_stream], response.media_type
    assert_match "Requested", response.body
    request_row = Friendship.pending.sole
    assert_equal @user.id, request_row.user_id
    assert_equal @other.id, request_row.friend_id
    assert_not @user.friends_with?(@other)
  end

  test "create falls back to a redirect for plain HTML submissions" do
    post friend_requests_url, params: { friend_id: @other.id }

    assert_redirected_to friends_url
    assert_equal 1, Friendship.pending.count
  end

  test "create is idempotent — re-adding never duplicates the request" do
    Friendship.send_request!(@user, @other)

    assert_no_difference -> { Friendship.count } do
      post friend_requests_url, params: { friend_id: @other.id }
    end

    assert_redirected_to friends_url
  end

  test "create auto-accepts when the other side already requested first" do
    Friendship.send_request!(@other, @user)

    post friend_requests_url, params: { friend_id: @other.id },
         headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :success
    assert @user.friends_with?(@other)
    assert_equal 2, Friendship.count
    assert_equal 0, Friendship.pending.count
    assert_match "Friends", response.body
  end

  test "create refuses to request yourself" do
    assert_no_difference -> { Friendship.count } do
      post friend_requests_url, params: { friend_id: @user.id }
    end

    assert_response :not_found
  end

  test "create requires an existing user" do
    post friend_requests_url, params: { friend_id: 0 }

    assert_response :not_found
  end

  # ---- update (accept an incoming request) ----------------------------------

  test "update accepts the incoming request for the recipient" do
    pending_request = Friendship.send_request!(@other, @user)

    assert_difference -> { Friendship.accepted.count }, 2 do
      patch friend_request_url(pending_request),
            headers: { "ACCEPT" => Mime[:turbo_stream].to_s }
    end

    assert_response :success
    assert @user.friends_with?(@other)
    assert @other.friends_with?(@user)
    # The stream prepends the friend card to the grid…
    assert_match "friends-grid", response.body
    assert_match "friend_card_user_#{@other.id}", response.body
    # …and repaints the pending section.
    assert_match "pending-requests", response.body
  end

  test "update falls back to a redirect for plain HTML submissions" do
    pending_request = Friendship.send_request!(@other, @user)

    patch friend_request_url(pending_request)

    assert_redirected_to friends_url
    assert @user.friends_with?(@other)
  end

  test "update is forbidden for anyone but the recipient" do
    pending_request = Friendship.send_request!(@user, @other) # my outgoing

    patch friend_request_url(pending_request)

    assert_response :not_found
    assert_not @user.friends_with?(@other)
  end

  test "update refuses rows that are not pending" do
    Friendship.connect!(@other, @user)
    accepted_edge = @other.friendships.first # other -> user

    patch friend_request_url(accepted_edge)

    assert_response :not_found
  end

  # ---- destroy (decline an incoming request) ---------------------------------

  test "destroy declines the incoming request" do
    pending_request = Friendship.send_request!(@other, @user)

    assert_difference -> { Friendship.count }, -1 do
      delete friend_request_url(pending_request),
             headers: { "ACCEPT" => Mime[:turbo_stream].to_s }
    end

    assert_response :success
    assert_not @user.friends_with?(@other)
    assert_equal 0, Friendship.pending.count
  end

  test "destroy falls back to a redirect for plain HTML submissions" do
    pending_request = Friendship.send_request!(@other, @user)

    delete friend_request_url(pending_request)

    assert_redirected_to friends_url
    assert_equal 0, Friendship.count
  end

  test "destroy is forbidden for anyone but the recipient" do
    pending_request = Friendship.send_request!(@user, @other)

    assert_no_difference -> { Friendship.count } do
      delete friend_request_url(pending_request)
    end

    assert_response :not_found
  end

  test "actions redirect guests to sign in" do
    sign_out @user
    pending_request = Friendship.send_request!(@other, @user)

    post friend_requests_url, params: { friend_id: @other.id }
    assert_redirected_to new_user_session_path

    patch friend_request_url(pending_request)
    assert_redirected_to new_user_session_path

    delete friend_request_url(pending_request)
    assert_redirected_to new_user_session_path
  end
end
