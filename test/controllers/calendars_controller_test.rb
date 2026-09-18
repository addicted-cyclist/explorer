# frozen_string_literal: true

require "test_helper"

class CalendarsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
    @route = @user.routes.create!(source: "upload", title: "Ridge loop", duration: 1_800)
  end

  test "allocate creates a calendar entry with the picked date and start time" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30" }

    assert_redirected_to route_path(@route)
    entry = @user.calendar_entries.sole
    assert_equal Date.new(2026, 10, 28), entry.scheduled_on
    assert_equal 9, entry.start_time.hour
    assert_equal 30, entry.start_time.min
    assert_equal 10, entry.end_time.hour # 09:30 + the route's 1800s duration
  end

  test "allocate moves the existing entry instead of duplicating it" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30" }
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-11-02", start_time: "07:00" }
    assert_equal 1, @user.calendar_entries.count
    entry = @user.calendar_entries.sole
    assert_equal Date.new(2026, 11, 2), entry.scheduled_on
    assert_equal 7, entry.start_time.hour
  end

  test "allocate falls back to the default start time and a one hour duration" do
    @route.update_columns(duration: nil)

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28" }

    entry = @user.calendar_entries.sole
    assert_equal 8, entry.start_time.hour
    assert_equal 9, entry.end_time.hour
  end

  test "allocate treats a zero duration like a missing one" do
    @route.update_columns(duration: 0) # 0.presence is 0 and used to trip end-time validation

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28" }

    entry = @user.calendar_entries.sole
    assert_equal 8, entry.start_time.hour
    assert_equal 9, entry.end_time.hour
  end

  test "allocate with a blank date asks for a valid date instead of a validation dump" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "" }

    assert_redirected_to route_path(@route)
    assert_match(/Pick a valid date/, flash[:alert])
    assert_empty @user.calendar_entries.reload
  end

  test "allocate with an unparsable date redirects with an alert and stores nothing" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "not-a-date", start_time: "08:00" }

    assert_redirected_to route_path(@route)
    assert_match(/Pick a valid date/, flash[:alert])
    assert_empty @user.calendar_entries.reload
  end

  test "allocate 404s for a route the user does not own" do
    owner = User.create!(valid_user_attributes(email: "owner@example.com"))
    other = owner.routes.create!(source: "upload", title: "Not mine")

    post allocate_calendar_path, params: { route_id: other.id, scheduled_on: "2026-10-28", start_time: "08:00" }

    assert_response :not_found
  end

  test "remove_entry deletes the route's calendar entry" do
    @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                   start_time: "08:00", end_time: "08:30")

    delete remove_entry_calendar_path, params: { route_id: @route.id }

    assert_redirected_to route_path(@route)
    assert_equal "Removed \"Ridge loop\" from your calendar.", flash[:notice]
    assert_empty @user.calendar_entries.reload
  end

  # ---- Phase 7: the weekly grid --------------------------------------------

  test "show renders my week with the current Monday as the default week" do
    get calendar_url

    assert_response :success
    assert_select "h1", text: "My Calendar"
    assert_select "section.wc-day", count: 7
    monday = Date.current.beginning_of_week
    assert_select "section[id=?]", "wc-day-#{monday.strftime('%Y%m%d')}"
    assert_select "form[data-calendar-dnd-target=allocateForm]"
    assert_select "form[data-calendar-dnd-target=removeForm]"
    # Locks the markup <-> JS contract: dropOnDay reads the column's date param
    assert_select "section.wc-day[data-calendar-dnd-date-param]", count: 7
    monday = Date.current.beginning_of_week
    assert_select "section[id=?][data-calendar-dnd-date-param=?]",
                  "wc-day-#{monday.strftime('%Y%m%d')}", monday.iso8601
  end

  test "show monday-starts whatever week is requested" do
    get calendar_url, params: { week: "2026-10-21" } # a Wednesday

    assert_response :success
    assert_select ".wc-toolbar__range", text: /Oct 19 – Oct 25, 2026/
    assert_select "section[id=wc-day-20261019]"
    assert_select "section[id=wc-day-20261025]"
  end

  test "show groups entries per day and totals the weekly telemetry" do
    @route.update!(distance: 21.5)
    other = @user.routes.create!(source: "upload", title: "Valley loop", duration: 3_600, distance: 42.2)
    monday = Date.current.beginning_of_week
    @user.calendar_entries.create!(route: @route, scheduled_on: monday, start_time: "08:00", end_time: "08:30")
    @user.calendar_entries.create!(route: other, scheduled_on: monday, start_time: "17:00", end_time: "18:00")
    @user.calendar_entries.create!(route: other, scheduled_on: monday + 2, start_time: "09:00", end_time: "10:00")

    get calendar_url

    assert_response :success
    assert_select "section[id=?]", "wc-day-#{monday.strftime('%Y%m%d')}" do
      assert_select "article.wc-entry", count: 2
      # Card contract: hover X unschedules, time row opens the editor,
      # checkbox toggles completed back onto the visited week
      assert_select %(button[data-action~="calendar-dnd#removeEntry"][data-route-id])
      assert_select %(button[data-action~="entry-time-editor#open"])
      assert_select "button.wc-entry__check"
      # The X lives in the floating bottom dock, revealed on card hover
      assert_select "article.wc-entry > .wc-entry__dock .wc-entry__remove", count: 2
    end
    assert_match "63.7 km", response.body # 21.5 + 42.2
  end

  test "show lists the whole library in the sidebar for my view" do
    @user.routes.create!(source: "upload", title: "Unscheduled route")

    get calendar_url

    assert_response :success
    assert_select "article.wc-route-card", count: 2
    assert_match "Unscheduled route", response.body
    assert_match "Drag any route onto a calendar day", response.body
    # Nav: my calendar stays on My calendar, Friends stays inactive
    assert_select %(a.app-nav__link--active[href="#{calendar_path}"]), text: "My calendar"
    assert_select %(a.app-nav__link--active[href="#{friends_path}"]), count: 0
  end

  test "show arms the Import CTA and renders the shared upload modal" do
    get calendar_url

    assert_response :success
    assert_select "a.wc-sidebar__cta[data-modal-open=upload]"
    assert_select "div#upload-modal[data-modal-id=upload]"
    assert_select %(form[action="#{routes_path}"][method=post][enctype="multipart/form-data"])
    assert_select "input[type=file][name=?]", "route[gpx_files][]"
    # Calendar origin markers: the import lands back on the visited week
    assert_select %(input[type=hidden][name=from_calendar][value="1"])
    assert_select %(input[type=hidden][name=week][value="#{Date.current.beginning_of_week.iso8601}"])
  end

  # ---- Phase 7: friend view --------------------------------------------------

  test "show renders an accepted friend's calendar read-only" do
    friend = User.create!(valid_user_attributes(email: "friend@example.com"))
    Friendship.connect!(friend, @user)
    friend_route = friend.routes.create!(source: "upload", title: "Friend ridge", duration: 3_600, distance: 32.0)
    friend.calendar_entries.create!(route: friend_route, scheduled_on: Date.current.beginning_of_week + 1,
                                    start_time: "07:30", end_time: "08:30")

    get friend_calendar_path(friend.username)

    assert_response :success
    assert_select "h1", text: "#{friend.name}'s Calendar"
    assert_match friend.name, response.body
    assert_select "section.wc-day", count: 7
    assert_select "article.wc-entry", count: 1
    # The sidebar narrows to this week's routes and gains the GPX affordance
    assert_select "article.wc-route-card", count: 1
    assert_match "Friend ridge", response.body
    assert_select ".wc-gpx-btn", count: 1
    # Read-only: no drag sources, no transport forms, no import hint, no upload modal
    assert_select "form[data-calendar-dnd-target=allocateForm]", count: 0
    assert_select "article[draggable=true]", count: 0
    assert_select ".wc-sidebar__cta", count: 0
    assert_select "#upload-modal", count: 0
    # Entry cards stay read-only: no completed checkbox, no unschedule X, no editor trigger
    assert_select "article.wc-entry .wc-entry__check", count: 0
    assert_select "article.wc-entry .wc-entry__remove", count: 0
    # The Join action lives in the same floating bottom dock
    assert_select "article.wc-entry > .wc-entry__dock .wc-join__btn", count: 1
    # Nav: a friend's week view highlights Friends, not My calendar
    assert_select %(a.app-nav__link--active[href="#{friends_path}"]), text: "Friends"
    assert_select %(a.app-nav__link--active[href="#{calendar_path}"]), count: 0
  end

  test "show 404s a stranger's calendar" do
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    get friend_calendar_path(stranger.username)

    assert_response :not_found
  end

  test "show 404s a pending friendship's calendar" do
    pending_friend = User.create!(valid_user_attributes(email: "pending@example.com"))
    Friendship.connect!(pending_friend, @user, status: "pending")

    get friend_calendar_path(pending_friend.username)

    assert_response :not_found
  end

  test "friend calendar redirects guests to sign in" do
    sign_out @user

    get friend_calendar_path("anyone")

    assert_redirected_to new_user_session_path
  end

  # ---- Phase 7: calendar-originated Turbo Streams -----------------------------

  test "allocate from the grid streams the day column and telemetry" do
    @route.update!(distance: 21.5)

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30",
                                           from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_equal Mime[:turbo_stream], response.media_type
    assert_match(/action="replace" target="wc-day-20261028"/, response.body)
    assert_match(/action="replace" target="wc-telemetry"/, response.body)
    assert_equal 1, @user.calendar_entries.count
  end

  test "allocate from the grid without turbo falls back to the visited week" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30",
                                           from_calendar: "1", week: "2026-10-26" }

    assert_redirected_to calendar_path(week: "2026-10-26")
  end

  test "allocate moving a scheduled route streams the vacated day too" do
    @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 27),
                                   start_time: "08:00", end_time: "08:30")

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-29", start_time: "09:30",
                                           from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_match(/target="wc-day-20261027"/, response.body)
    assert_match(/target="wc-day-20261029"/, response.body)
    assert_equal 1, @user.calendar_entries.count
    assert_equal Date.new(2026, 10, 29), @user.calendar_entries.sole.scheduled_on
  end

  test "allocate failure from the grid bounces back to the week with an alert" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "not-a-date",
                                           from_calendar: "1", week: "2026-10-26" }

    assert_redirected_to calendar_path(week: "2026-10-26")
    assert_predicate flash[:alert], :present?
    assert_empty @user.calendar_entries.reload
  end

  test "update_entry streams the repainted day column" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30")

    patch update_entry_calendar_path, params: { entry_id: entry.id, start_time: "09:15",
                                                from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="wc-day-20261028"/, response.body)
    entry.reload
    assert_equal 9, entry.start_time.hour
    assert_equal 15, entry.start_time.min
    assert_equal 45, entry.end_time.min # 09:15 + the route's 1800s duration
  end

  test "update_entry without turbo falls back to a redirect" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30")

    patch update_entry_calendar_path, params: { entry_id: entry.id, start_time: "10:00",
                                                from_calendar: "1", week: "2026-10-26" }

    assert_redirected_to calendar_path(week: "2026-10-26")
    assert_equal 10, entry.reload.start_time.hour
  end

  test "update_entry keeps end after start when the route duration is zero" do
    @route.update_columns(duration: 0)
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30")

    patch update_entry_calendar_path, params: { entry_id: entry.id, start_time: "09:15" }

    entry.reload
    assert_equal 9, entry.start_time.hour
    assert_equal 15, entry.start_time.min
    assert_equal 10, entry.end_time.hour # 09:15 + the 1-hour fallback
  end

  test "update_entry 404s for another user's entry" do
    owner = User.create!(valid_user_attributes(email: "owner2@example.com"))
    other_route = owner.routes.create!(source: "upload", title: "Not mine")
    entry = owner.calendar_entries.create!(route: other_route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "09:00")

    patch update_entry_calendar_path, params: { entry_id: entry.id, start_time: "10:00" }

    assert_response :not_found
  end

  test "remove_entry from the grid streams the emptied day and keeps the route" do
    @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                   start_time: "08:00", end_time: "08:30")

    delete remove_entry_calendar_path, params: { route_id: @route.id, from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="wc-day-20261028"/, response.body)
    assert_match(/action="replace" target="wc-telemetry"/, response.body)
    assert_empty @user.calendar_entries.reload
    assert_predicate @user.routes.exists?(@route.id), :present? # unscheduled, not deleted
  end

  # ---- Phase 7: joining a friend's ride ---------------------------------------

  test "join deep-copies the friend's route and books my own entry" do
    friend = User.create!(valid_user_attributes(email: "joinfriend@example.com"))
    Friendship.connect!(friend, @user)
    friend_route = create_friend_route_with_gpx(friend)
    friend_entry = friend.calendar_entries.create!(route: friend_route, scheduled_on: Date.new(2026, 10, 27),
                                                   start_time: "07:30", end_time: "09:30")

    assert_difference -> { @user.routes.count }, +1 do
      assert_difference -> { @user.calendar_entries.count }, +1 do
        post join_calendar_path, params: { entry_id: friend_entry.id, week: "2026-10-26" },
              headers: { "ACCEPT" => Mime[:turbo_stream].to_s }
      end
    end

    assert_response :ok
    # Joined mechanic: the dock swaps to the inert "Joined" button — no
    # popover, no CTA form (the CTA needs @week_start, which stream renders
    # must not depend on)
    assert_match "Joined", response.body
    assert_match "wc-join--joined", response.body
    assert_no_match /wc-popover/, response.body
    assert_no_match /Join Route/, response.body
    mine = @user.calendar_entries.sole
    assert_equal friend_entry.id, mine.origin_entry_id # links back = state survives reloads
    assert_not_equal friend_route.id, mine.route.id
    assert_equal friend_route.title, mine.route.title
    assert_equal "upload", mine.route.source
    assert_not mine.route.completed?
    assert_equal Date.new(2026, 10, 27), mine.scheduled_on
    assert_equal 7, mine.start_time.hour
    assert_equal 30, mine.start_time.min
    assert_equal 9, mine.end_time.hour # keeps the friend's slot
    # The copy owns its own blob: same bytes, different storage row
    assert_predicate mine.route.gpx_file, :attached?
    assert_not_equal friend_route.gpx_file.blob.id, mine.route.gpx_file.blob.id
    assert_equal friend_route.gpx_file.checksum, mine.route.gpx_file.checksum
  end

  test "join without turbo redirects back to the friend's calendar" do
    friend = User.create!(valid_user_attributes(email: "joinfriend2@example.com"))
    Friendship.connect!(friend, @user)
    friend_route = create_friend_route_with_gpx(friend)
    friend_entry = friend.calendar_entries.create!(route: friend_route, scheduled_on: Date.new(2026, 10, 27),
                                                   start_time: "07:30", end_time: "08:30")

    post join_calendar_path, params: { entry_id: friend_entry.id, week: "2026-10-26" }

    assert_redirected_to friend_calendar_path(friend.username, week: "2026-10-26")
    assert_match(/You joined/, flash[:notice])
    # The setup route plus the joined copy
    assert_equal 2, @user.routes.count
  end

  test "joined state survives a page reload of the friend's calendar" do
    friend = User.create!(valid_user_attributes(email: "joinreload@example.com"))
    Friendship.connect!(friend, @user)
    friend_route = create_friend_route_with_gpx(friend)
    friend_entry = friend.calendar_entries.create!(route: friend_route, scheduled_on: Date.new(2026, 10, 27),
                                                   start_time: "07:30", end_time: "08:30")

    post join_calendar_path, params: { entry_id: friend_entry.id, week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }
    assert_response :ok

    get friend_calendar_path(friend.username, week: "2026-10-26")

    # The dock holds the joined state across renders: no Join button or
    # popover markup is rendered for the already-joined ride
    assert_match "wc-join--joined", response.body
    assert_no_match /wc-popover/, response.body
    assert_no_match /Join Route/, response.body
  end

  test "joining the same ride twice does not duplicate the copy" do
    friend = User.create!(valid_user_attributes(email: "joindup@example.com"))
    Friendship.connect!(friend, @user)
    friend_route = create_friend_route_with_gpx(friend)
    friend_entry = friend.calendar_entries.create!(route: friend_route, scheduled_on: Date.new(2026, 10, 27),
                                                   start_time: "07:30", end_time: "08:30")

    post join_calendar_path, params: { entry_id: friend_entry.id, week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_difference -> { @user.routes.count }, 0 do
      assert_difference -> { @user.calendar_entries.count }, 0 do
        post join_calendar_path, params: { entry_id: friend_entry.id, week: "2026-10-26" },
              headers: { "ACCEPT" => Mime[:turbo_stream].to_s }
      end
    end

    assert_response :ok
    assert_match "wc-join--joined", response.body
    assert_equal friend_entry.id, @user.calendar_entries.sole.origin_entry_id
  end

  test "join 404s outside an accepted friendship and stores nothing" do
    stranger = User.create!(valid_user_attributes(email: "stranger2@example.com"))
    stranger_route = stranger.routes.create!(source: "upload", title: "Secret trail")
    entry = stranger.calendar_entries.create!(route: stranger_route, scheduled_on: Date.new(2026, 10, 27),
                                              start_time: "07:30", end_time: "08:30")

    post join_calendar_path, params: { entry_id: entry.id }

    assert_response :not_found
    # Nothing joined: the library still holds only the setup route
    assert_equal 1, @user.routes.count
    assert_empty @user.calendar_entries.reload
  end

  private

  # Friend-owned route with an attached, parsed GPX file (mirrors the helper
  # in RoutesControllerTest).
  def create_friend_route_with_gpx(user)
    user.routes.create!(source: "upload", title: "Mont Blanc ridge").tap do |route|
      route.gpx_file.attach(
        io: File.open(gpx_fixture_upload("exploration.gpx").path),
        filename: "exploration.gpx",
        content_type: "application/gpx+xml"
      )
      route.parse_gpx!
      route.reload
    end
  end
end
