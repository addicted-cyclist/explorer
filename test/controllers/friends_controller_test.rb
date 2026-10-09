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
    # Exactly one friend card (the pal); the stranger only ever surfaces
    # inside the Find friends popup (data-candidate), never as a card.
    assert_equal 1, response.body.scan("friends__card\"").size
    assert_no_match(/data-search="[^"]*#{Regexp.escape(stranger.username)}/, response.body)
    assert_match(/data-candidate="[^"]*#{Regexp.escape(stranger.username)}/, response.body)
  end

  test "index shows incoming requests with meta and hides outgoing ones" do
    sender = User.create!(valid_user_attributes(email: "sender@example.com"))
    sender.routes.create!(title: "Gravel Grinder", sport_type: "Gravel")
    Friendship.send_request!(sender, @user)
    outgoing = User.create!(valid_user_attributes(email: "outgoing@example.com"))
    Friendship.send_request!(@user, outgoing)

    get friends_url

    assert_response :success
    assert_match "Pending Requests", response.body
    assert_match "Rides Gravel", response.body
    assert_match "Sent", response.body
    # The pending section lists only incoming requests — my own outgoing
    # request never shows up there to accept.
    section = response.body[/id="pending-requests".*?<\/section>/m]
    assert section.present?
    assert_match(/#{Regexp.escape(sender.username)}/, section)
    assert_no_match(/#{Regexp.escape(outgoing.username)}/, section)
  end

  test "index renders the last completed ride with date and week count" do
    pal = User.create!(valid_user_attributes(email: "pal@example.com"))
    Friendship.connect!(pal, @user)
    ride = pal.routes.create!(title: "Sunrise Loop", distance: 42.0,
                              elevation_gain: 650.0, duration: 5400,
                              sport_type: "Road", tier: "Moderate")
    pal.calendar_entries.create!(route: ride, scheduled_on: Date.current,
                                 start_time: Time.current.change(hour: 7),
                                 end_time: Time.current.change(hour: 9),
                                 completed: true)

    get friends_url

    assert_response :success
    assert_match "Last completed ride", response.body
    assert_match "Sunrise Loop", response.body
    assert_match "Today", response.body
    assert_match "Moderate", response.body
    assert_match "routes this week", response.body
    assert_match "1 riding this week", response.body
  end

  test "index falls back to the last completed library route" do
    pal = User.create!(valid_user_attributes(email: "pal@example.com"))
    Friendship.connect!(pal, @user)
    pal.routes.create!(title: "Done In Library", completed: true)

    get friends_url

    assert_response :success
    assert_match "Done In Library", response.body
  end

  test "index renders the empty card for an athlete without completed rides" do
    pal = User.create!(valid_user_attributes(email: "pal@example.com"))
    Friendship.connect!(pal, @user)
    pal.routes.create!(title: "Planned Not Ridden")

    get friends_url

    assert_response :success
    assert_match "No rides yet", response.body
    assert_match "No completed rides yet", response.body
    assert_match "New athlete", response.body
    assert_no_match(/Planned Not Ridden/, response.body)
    assert_match "0 routes this week", response.body
  end

  test "index renders the popup with every relationship state" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com"))
    outgoing = User.create!(valid_user_attributes(email: "outgoing@example.com"))
    requester = User.create!(valid_user_attributes(email: "requester@example.com"))
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    Friendship.connect!(@user, friend)
    Friendship.send_request!(@user, outgoing)
    Friendship.send_request!(requester, @user)

    get friends_url

    assert_response :success
    assert_match "Find friends", response.body
    assert_match(/>Add<\/button>/, response.body) # stranger row
    assert_match(/Requested/, response.body) # outgoing row
    assert_match(/>Accept<\/button>/, response.body) # incoming row
    assert_match "Already friends", response.body # friend row
  end

  test "index redirects guests to sign in" do
    sign_out @user

    get friends_url

    assert_redirected_to new_user_session_path
  end
end
