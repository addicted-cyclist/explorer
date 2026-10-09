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

  # ---- Phase 11 — find-friends relationship states --------------------------

  test "friend_edges_for maps every candidate to their relationship edge" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com"))
    outgoing = User.create!(valid_user_attributes(email: "outgoing@example.com"))
    requester = User.create!(valid_user_attributes(email: "requester@example.com"))
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    Friendship.connect!(@user, friend)
    Friendship.send_request!(@user, outgoing)
    Friendship.send_request!(requester, @user)

    edges = @user.friend_edges_for([ friend, outgoing, requester, stranger ])

    assert_predicate edges[friend.id], :accepted?
    assert_equal @user.id, edges[outgoing.id].user_id
    assert_predicate edges[outgoing.id], :pending?
    assert_equal requester.id, edges[requester.id].user_id
    assert_predicate edges[requester.id], :pending?
    assert_nil edges[stranger.id]
  end

  test "friendship_state_with reports the four relationship states" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com"))
    outgoing = User.create!(valid_user_attributes(email: "outgoing@example.com"))
    requester = User.create!(valid_user_attributes(email: "requester@example.com"))
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    Friendship.connect!(@user, friend)
    Friendship.send_request!(@user, outgoing)
    Friendship.send_request!(requester, @user)

    assert_equal :friends, @user.friendship_state_with(friend)
    assert_equal :outgoing_pending, @user.friendship_state_with(outgoing)
    assert_equal :incoming_pending, @user.friendship_state_with(requester)
    assert_equal :none, @user.friendship_state_with(stranger)
  end

  # ---- Phase 11 — friends page card data ------------------------------------

  test "friend_cards_for prefers completed entries and falls back to completed routes" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com"))
    inactive = User.create!(valid_user_attributes(email: "inactive@example.com"))

    old_route = friend.routes.create!(title: "Old Loop", distance: 21.4,
                                      elevation_gain: 412.0, duration: 3600,
                                      completed: true)
    friend.calendar_entries.create!(route: old_route, scheduled_on: 8.days.ago,
                                    start_time: Time.current.change(hour: 8),
                                    end_time: Time.current.change(hour: 9),
                                    completed: true)
    friend.calendar_entries.create!(route: friend.routes.create!(title: "Recent Loop"),
                                    scheduled_on: Date.current,
                                    start_time: Time.current.change(hour: 7),
                                    end_time: Time.current.change(hour: 9),
                                    completed: true)
    inactive.routes.create!(title: "Library Ride", completed: true)
    library_ride = inactive.routes.last

    cards = User.friend_cards_for([ friend, inactive ], Date.current.all_week)

    card = cards.fetch(friend.id)
    assert_equal "Recent Loop", card.last_ride.title
    assert_equal Date.current, card.ride_date
    assert_equal 1, card.week_count

    empty_card = cards.fetch(inactive.id)
    assert_equal "Library Ride", empty_card.last_ride.title
    # No scheduled date: the label falls back to the completion touch.
    assert_equal library_ride.updated_at.to_date, empty_card.ride_date
    assert_equal 0, empty_card.week_count
  end

  test "sport_types_by_id collects distinct sports per user" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com"))
    friend.routes.create!(title: "Road A", sport_type: "Road", completed: true)
    friend.routes.create!(title: "Road B", sport_type: "Road")
    friend.routes.create!(title: "Gravel A", sport_type: "Gravel")

    map = User.sport_types_by_id([ friend.id ])

    assert_equal [ "Gravel", "Road" ], map.fetch(friend.id).sort
  end
end
