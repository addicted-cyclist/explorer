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
    # Exactly one friend card (the pal), and no directory preload: other
    # accounts surface only through the candidates search endpoint.
    assert_equal 1, response.body.scan("friends__card\"").size
    assert_no_match(/#{Regexp.escape(stranger.username)}/, response.body)
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
    assert_match "Last completed route", response.body
    assert_match "Sunrise Loop", response.body
    assert_match "Today", response.body
    assert_match "Moderate", response.body
    assert_match "routes this week", response.body
    assert_match "1 active explorer this week", response.body
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
    assert_match "No completed rides yet", response.body
    assert_match "New athlete", response.body
    assert_no_match(/Planned Not Ridden/, response.body)
    assert_match "0 routes this week", response.body
  end

  test "index ships the popup empty and never preloads other accounts" do
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    get friends_url

    assert_response :success
    assert_match "Find friends", response.body
    # The popup rests on its prompt; the candidates endpoint supplies rows
    # only once the user types a qualifying query.
    assert_match "Type at least 3 characters", response.body
    assert_no_match(/friends-find__row/, response.body)
    assert_no_match(/#{Regexp.escape(stranger.username)}/, response.body)
  end

  # ---- candidates — the popup's live search ---------------------------------

  test "candidates search finds athletes by first, last, username and full name" do
    alice = User.create!(valid_user_attributes(email: "alice@example.com",
                                               first_name: "Alice", last_name: "Wonder",
                                               username: "alice_wanders"))
    User.create!(valid_user_attributes(email: "bob@example.com",
                                       first_name: "Bob", last_name: "Builder",
                                       username: "builderbob"))

    get candidates_friends_url(q: "alice"), headers: turbo_frame_headers

    assert_response :success
    assert_match(/#{Regexp.escape(alice.username)}/, response.body)
    assert_no_match(/builderbob/, response.body)

    get candidates_friends_url(q: "WON"), headers: turbo_frame_headers # case-insensitive last name
    assert_match(/#{Regexp.escape(alice.username)}/, response.body)

    get candidates_friends_url(q: "ders"), headers: turbo_frame_headers # username fragment
    assert_match(/#{Regexp.escape(alice.username)}/, response.body)

    get candidates_friends_url(q: "alice wonder"), headers: turbo_frame_headers # joined full name
    assert_match(/#{Regexp.escape(alice.username)}/, response.body)
  end

  test "candidates search treats LIKE wildcards as literal text" do
    User.create!(valid_user_attributes(email: "zoe@example.com",
                                       first_name: "Zoe", last_name: "Zoom",
                                       username: "zo_zoom"))

    # "%%%" passes the 3-character gate; unescaped it would match every
    # account and turn the popup into a directory dump.
    get candidates_friends_url(q: "%%%"), headers: turbo_frame_headers

    assert_response :success
    assert_match "No explorers match", response.body
    assert_no_match(/zo_zoom/, response.body)
  end

  test "candidates search renders every relationship state" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com",
                                                first_name: "Zachary", last_name: "Pal",
                                                username: "zachary_pal"))
    outgoing = User.create!(valid_user_attributes(email: "outgoing@example.com",
                                                  first_name: "Zachary", last_name: "Asked",
                                                  username: "zachary_asked"))
    requester = User.create!(valid_user_attributes(email: "requester@example.com",
                                                   first_name: "Zachary", last_name: "Offer",
                                                   username: "zachary_offer"))
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com",
                                                  first_name: "Zachary", last_name: "New",
                                                  username: "zachary_new"))

    Friendship.connect!(@user, friend)
    Friendship.send_request!(@user, outgoing)
    Friendship.send_request!(requester, @user)

    get candidates_friends_url(q: "zachary"), headers: turbo_frame_headers

    assert_response :success
    assert_equal 4, response.body.scan("friends-find__row").size
    assert_match(/>Add<\/button>/, response.body) # stranger row
    assert_match(/Requested/, response.body) # outgoing row
    assert_match(/>Accept<\/button>/, response.body) # incoming row
    assert_match "Already friends", response.body # friend row
  end

  test "candidates answers short queries with a hint and no rows" do
    User.create!(valid_user_attributes(email: "zoe@example.com",
                                       first_name: "Zoe", last_name: "Quinn",
                                       username: "zoe_quinn"))

    get candidates_friends_url, headers: turbo_frame_headers

    assert_response :success
    assert_match "Type at least 3 characters", response.body
    assert_no_match(/friends-find__row/, response.body)

    get candidates_friends_url(q: "zo"), headers: turbo_frame_headers

    assert_response :success
    assert_match "Type at least 3 characters", response.body
    assert_no_match(/friends-find__row/, response.body)
  end

  test "candidates caps results at twenty and offers to refine" do
    21.times do |i|
      User.create!(valid_user_attributes(email: "crowd#{i}@example.com",
                                         first_name: "Crowd", last_name: "Member",
                                         username: "crowdmember#{i}"))
    end

    get candidates_friends_url(q: "crowd"), headers: turbo_frame_headers

    assert_response :success
    assert_equal 20, response.body.scan("friends-find__row").size
    assert_match "keep typing", response.body
  end

  test "candidates bounces plain visits back to the friends page" do
    get candidates_friends_url(q: "anything")

    assert_redirected_to friends_url
  end

  test "candidates redirects guests to sign in" do
    sign_out @user

    get candidates_friends_url(q: "anything"), headers: turbo_frame_headers

    assert_redirected_to new_user_session_path
  end

  test "index redirects guests to sign in" do
    sign_out @user

    get friends_url

    assert_redirected_to new_user_session_path
  end

  private

  # The popup only answers Turbo Frame navigations — mirror the header the
  # results frame adds to its requests.
  def turbo_frame_headers
    { "Turbo-Frame" => "find-friends-results" }
  end
end
