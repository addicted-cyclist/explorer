# frozen_string_literal: true

require "test_helper"

class FriendshipTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(valid_user_attributes)
    @friend = User.create!(valid_user_attributes(email: "friend@example.com"))
  end

  test "connect! creates the mutual pair and both sides read it" do
    Friendship.connect!(@user, @friend)

    assert_equal 2, Friendship.count
    assert @user.friends_with?(@friend)
    assert @friend.friends_with?(@user)
    assert_includes @user.friends, @friend
    assert_includes @friend.friends, @user
  end

  test "friends_with? is false for strangers, yourself and pending requests" do
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    assert_not @user.friends_with?(stranger)
    assert_not @user.friends_with?(@user)
    assert_not @user.friends_with?(nil)

    @user.friendships.create!(friend: @friend, status: "pending")
    assert_not @user.friends_with?(@friend)
  end

  test "rejects self-friendships, duplicates and unknown statuses" do
    friendship = @user.friendships.build(friend: @user)
    assert_not friendship.valid?

    Friendship.connect!(@user, @friend)
    assert_not @user.friendships.build(friend: @friend).valid?

    friendship = @user.friendships.build(friend: @friend, status: "maybe")
    assert_not friendship.valid?
  end

  # ---- Phase 11 — pending requests ------------------------------------------

  test "send_request! creates exactly one directed pending row" do
    request = Friendship.send_request!(@user, @friend)

    assert_equal 1, Friendship.count
    assert_predicate request, :pending?
    assert_equal @user.id, request.user_id
    assert_equal @friend.id, request.friend_id
    assert_not @user.friends_with?(@friend)
  end

  test "send_request! is idempotent for repeated requests" do
    first = Friendship.send_request!(@user, @friend)
    again = Friendship.send_request!(@user, @friend)

    assert_equal first.id, again.id
    assert_equal 1, Friendship.count
  end

  test "send_request! no-ops when the pair is already friends" do
    Friendship.connect!(@user, @friend)

    edge = Friendship.send_request!(@user, @friend)

    assert_predicate edge, :accepted?
    assert_equal 2, Friendship.count
  end

  test "send_request! auto-accepts when the recipient already asked first" do
    Friendship.send_request!(@friend, @user)

    edge = Friendship.send_request!(@user, @friend)

    assert_predicate edge.reload, :accepted?
    assert @user.friends_with?(@friend)
    assert @friend.friends_with?(@user)
    assert_equal 2, Friendship.count
  end

  test "accept! flips the row and restores the two-row invariant" do
    request = Friendship.send_request!(@user, @friend)

    request.accept!

    assert_predicate request.reload, :accepted?
    assert_equal 2, Friendship.count
    assert Friendship.accepted.exists?(user_id: @user.id, friend_id: @friend.id)
    assert Friendship.accepted.exists?(user_id: @friend.id, friend_id: @user.id)
    assert @user.friends_with?(@friend)
  end

  test "accept! is a no-op on an already accepted edge" do
    Friendship.connect!(@user, @friend)
    edge = @user.friendships.first

    assert_same edge, edge.accept!
    assert_equal 2, Friendship.count
  end
end
