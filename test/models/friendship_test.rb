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
end
