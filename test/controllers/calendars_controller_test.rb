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
    assert_not entry.completed? # fresh entries are never born completed
    assert_equal 9, entry.start_time.hour
    assert_equal 30, entry.start_time.min
    assert_equal 10, entry.end_time.hour # 09:30 + the route's 1800s duration
  end

  test "allocate books another entry for an already scheduled route" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30" }
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-11-02", start_time: "07:00" }

    assert_equal 2, @user.calendar_entries.count
    assert_equal [ Date.new(2026, 10, 28), Date.new(2026, 11, 2) ],
                 @user.calendar_entries.order(:scheduled_on).pluck(:scheduled_on)
    assert_equal 7, @user.calendar_entries.find_by(scheduled_on: Date.new(2026, 11, 2)).start_time.hour
  end

  test "allocate with the picker's tracked entry reschedules it instead of duplicating" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.current + 3,
                                           start_time: "08:00", end_time: "09:00")

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: (Date.current + 5).iso8601,
                                           start_time: "09:30", entry_id: entry.id, picker_mode: "chip" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_equal 1, @user.calendar_entries.count # moved, not stacked
    entry.reload
    assert_equal Date.current + 5, entry.scheduled_on
    assert_equal "09:30", entry.start_time.strftime("%H:%M")
    # The day it left repaints alongside the new day, and the chip keeps
    # managing the same (moved) entry.
    assert_match(/action="replace" target="wc-day-#{(Date.current + 3).strftime('%Y%m%d')}"/, response.body)
    assert_match(/action="replace" target="wc-day-#{(Date.current + 5).strftime('%Y%m%d')}"/, response.body)
    assert_match "Added to #{(Date.current + 5).strftime('%b %-d')}", response.body
  end

  test "allocate with a tracked entry can change just its start time" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30")

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28",
                                           start_time: "09:30", entry_id: entry.id }

    assert_redirected_to route_path(@route)
    assert_equal 1, @user.calendar_entries.count
    assert_equal "09:30", entry.reload.start_time.strftime("%H:%M")
    assert_equal "10:00", entry.end_time.strftime("%H:%M") # end recomputed from the duration
  end

  test "allocate with someone else's entry falls back to booking a fresh one" do
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))
    foreign = stranger.calendar_entries.create!(
      route: stranger.routes.create!(source: "upload", title: "Not mine"),
      scheduled_on: Date.new(2026, 10, 28), start_time: "08:00", end_time: "08:30"
    )

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-11-02",
                                           start_time: "08:00", entry_id: foreign.id }

    assert_redirected_to route_path(@route)
    mine = @user.calendar_entries.sole
    assert_equal Date.new(2026, 11, 2), mine.scheduled_on
    assert_not_equal foreign.id, mine.id
    assert_equal Date.new(2026, 10, 28), foreign.reload.scheduled_on # untouched
  end

  test "allocating a completed route books a fresh, not-completed entry" do
    @route.update!(completed: true)

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "08:00" }

    entry = @user.calendar_entries.sole
    assert_not entry.completed?
    assert_predicate @route.reload, :completed? # the library badge is untouched
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

  test "allocate books an overnight ride whose end wraps past midnight" do
    @route.update_columns(duration: nil) # the one-hour default, as in the reported case

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28",
                                           start_time: "23:30" }

    assert_redirected_to route_path(@route)
    entry = @user.calendar_entries.sole
    assert_equal "23:30", entry.start_time.strftime("%H:%M")
    # 23:30 + the one-hour moving duration lands on the next day's 00:30 —
    # an end before the start is a midnight-crossing ride, not garbage.
    assert_equal "00:30", entry.end_time.strftime("%H:%M")
    assert_nil flash[:alert]
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

  test "remove_entry deletes only the requested entry and keeps its siblings" do
    kept = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 27),
                                          start_time: "08:00", end_time: "08:30")
    removed = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                             start_time: "08:00", end_time: "08:30")

    delete remove_entry_calendar_path, params: { entry_id: removed.id }

    assert_redirected_to route_path(@route)
    assert_equal "Removed \"Ridge loop\" from your calendar.", flash[:notice]
    assert_empty @user.calendar_entries.where(id: removed.id)
    assert_not_empty @user.calendar_entries.where(id: kept.id)
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
      # Card contract: hover X unschedules this entry, time row opens the
      # editor, checkbox toggles this entry's completed flag
      assert_select %(button[data-action~="calendar-dnd#removeEntry"][data-entry-id])
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

  # ---- Phase 0 capacity: lazy mobile routes list ----------------------------

  test "mobile routes list frame serves the whole library for my view" do
    @user.routes.create!(source: "upload", title: "Pool route", duration: 1_800)

    get routes_list_calendar_path

    assert_response :success
    assert_select "turbo-frame#mob-routes-list"
    assert_match "Pool route", response.body
    # My-view card contract: a Schedule button per route opens the sheet
    assert_select %(button[data-action~="mob-sheet#open"]), count: 2
  end

  test "mobile routes list endpoint requires sign in" do
    sign_out @user

    get routes_list_calendar_path

    assert_redirected_to new_user_session_path
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

  # prepare_friend_view 404s strangers/pending friends; the show rescue
  # converts that into a friendly bounce back to my calendar (kept on
  # purpose — see the rescue's comment in the controller).
  test "show bounces a stranger's calendar back to mine with an alert" do
    stranger = User.create!(valid_user_attributes(email: "stranger@example.com"))

    get friend_calendar_path(stranger.username)

    assert_redirected_to calendar_path
    assert_match(/Can not get access to stranger's calendar!/, flash[:alert])
  end

  test "show bounces a pending friendship's calendar back to mine with an alert" do
    pending_friend = User.create!(valid_user_attributes(email: "pending@example.com"))
    Friendship.connect!(pending_friend, @user, status: "pending")

    get friend_calendar_path(pending_friend.username)

    assert_redirected_to calendar_path
    assert_match(/Can not get access to stranger's calendar!/, flash[:alert])
  end

  test "friend calendar redirects guests to sign in" do
    sign_out @user

    get friend_calendar_path("anyone")

    assert_redirected_to new_user_session_path
  end

  # ---- Phase 9: public share ------------------------------------------------

  test "my calendar shows the Share calendar button while the share is on" do
    @user.update!(calendar_public: true)

    get calendar_path

    assert_response :success
    assert_select ".wc-share-btn", text: /Share calendar/
    assert_match public_calendar_url(@user.public_token), response.body
  end

  test "my calendar hides the Share button while the calendar is private" do
    get calendar_path

    assert_response :success
    assert_select ".wc-share-btn", count: 0
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

  test "allocate from the grid books a second entry on an already scheduled day" do
    @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                   start_time: "08:00", end_time: "08:30")

    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30",
                                           from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="wc-day-20261028"/, response.body)
    assert_equal 2, @user.calendar_entries.count
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

  # ---- Per-entry completion (one-way sync into routes.completed) --------------

  test "toggle_completed flips the entry and promotes a not-yet-done route" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30")
    assert_not @route.completed?

    patch toggle_completed_calendar_path, params: { entry_id: entry.id, from_calendar: "1", week: "2026-10-26" }

    assert_redirected_to calendar_path(week: "2026-10-26")
    assert entry.reload.completed?
    assert_predicate @route.reload, :completed?
  end

  test "toggle_completed from the grid streams the day column repaint" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30")

    patch toggle_completed_calendar_path, params: { entry_id: entry.id, from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_equal Mime[:turbo_stream], response.media_type
    assert_match(/action="replace" target="wc-day-20261028"/, response.body)
    assert_match(/action="replace" target="mob-week-day-20261028"/, response.body)
    assert entry.reload.completed?
  end

  test "unchecking an entry never clears the route's completed state" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30", completed: true)
    @route.update!(completed: true)

    patch toggle_completed_calendar_path, params: { entry_id: entry.id, from_calendar: "1", week: "2026-10-26" }

    assert_not entry.reload.completed?
    assert_predicate @route.reload, :completed?
  end

  test "completing another entry of an already done route only flips that entry" do
    @route.update!(completed: true)
    first = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 27),
                                           start_time: "08:00", end_time: "08:30", completed: true)
    second = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                            start_time: "08:00", end_time: "08:30")

    patch toggle_completed_calendar_path, params: { entry_id: second.id, from_calendar: "1", week: "2026-10-26" }

    assert second.reload.completed?
    assert_predicate first.reload, :completed?
    assert_predicate @route.reload, :completed? # untouched — already done
  end

  test "toggle_completed 404s for another user's entry" do
    owner = User.create!(valid_user_attributes(email: "toggleowner@example.com"))
    other_route = owner.routes.create!(source: "upload", title: "Not mine")
    entry = owner.calendar_entries.create!(route: other_route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "09:00")

    patch toggle_completed_calendar_path, params: { entry_id: entry.id }

    assert_response :not_found
  end

  test "remove_entry from the grid streams the emptied day and keeps the route" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "08:30")

    delete remove_entry_calendar_path, params: { entry_id: entry.id, from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="wc-day-20261028"/, response.body)
    assert_match(/action="replace" target="wc-telemetry"/, response.body)
    assert_empty @user.calendar_entries.reload
    assert_predicate @user.routes.exists?(@route.id), :present? # unscheduled, not deleted
  end

  # ---- Routes pages: the add-to-calendar picker repaints -----------------------

  test "allocate from a library card repaints that card's picker" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: Date.current.iso8601,
                                           start_time: "08:00", picker_mode: "card" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="calendar_picker_route_#{@route.id}"/, response.body)
    # Card variant: the committed date prefills the (icon-only) picker.
    # [^>]* — Rails renders name, id, then value on hidden inputs.
    assert_match(/name="scheduled_on"[^>]*value="#{Date.current.iso8601}"/, response.body)
    assert_no_match /Added to/, response.body
  end

  test "allocate from the detail page chip repaints its label" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: Date.current.iso8601,
                                           start_time: "08:00", picker_mode: "chip" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="calendar_picker_route_#{@route.id}"/, response.body)
    assert_match "Added to #{Date.current.strftime('%b %-d')}", response.body
    # The repainted picker commits (Done) against the fresh entry, so a
    # second commit reschedules it instead of stacking a duplicate.
    assert_match(/name="entry_id"[^>]*value="\d+"/, response.body)
  end

  test "remove_entry from a library card repaints the picker without the removed entry" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.current + 3,
                                           start_time: "08:00", end_time: "09:00")

    delete remove_entry_calendar_path, params: { entry_id: entry.id, picker_mode: "card" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="calendar_picker_route_#{@route.id}"/, response.body)
    # Nothing tracked anymore: the picker is back to its empty default
    # (nil hidden values render without a value attribute at all).
    assert_no_match(/name="scheduled_on"[^>]*value=/, response.body)
    assert_no_match(/name="entry_id"[^>]*value=/, response.body)
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

  # ---- Phase 8: mobile weekly calendar ---------------------------------------

  test "show renders the mobile week layout beside the desktop grid" do
    @route.update!(distance: 21.5)
    monday = Date.current.beginning_of_week
    @user.calendar_entries.create!(route: @route, scheduled_on: monday, start_time: "08:00", end_time: "08:30")

    get calendar_url

    assert_response :success
    assert_select "section.mob-wc[data-mob-week-initial-date-value]"
    # One strip pill and one day panel per weekday, keyed like the desktop columns
    assert_select "button.mob-wc__pill[data-date]", count: 7
    assert_select "article[id=?]", "mob-week-day-#{monday.strftime('%Y%m%d')}" do
      assert_select "article.mob-wc__entry", count: 1
      assert_select %(button[data-action~="mob-sheet#open"][data-mob-sheet-id-param="add-route"])
    end
    # KPI tiles carry the mobile telemetry id the streams repaint
    assert_select "div[id=mob-week-kpi-container]"
    # Both bottom sheets ship hidden until mob-sheet opens them
    assert_select %(div.mob-sheet[data-sheet-id="add-route"][aria-hidden="true"])
    assert_select %(div.mob-sheet[data-sheet-id="schedule-route"][aria-hidden="true"])
    # A successful Turbo submit closes both sheets; the close event then
    # resets the picker state inside mob-week
    assert_select %(form[data-action~="turbo:submit-end->mob-sheet#onSubmitEnd"]), count: 2
    assert_select %(section.mob-wc[data-action~="mob-sheet:closed->mob-week#onSheetClosed"])
    # Signed-in shell renders the mobile bottom nav
    assert_select "nav.app-nav-mobile a", count: 4
  end

  test "mobile day panel swaps to the swipe slider with dot navigation" do
    other = @user.routes.create!(source: "upload", title: "Valley loop", duration: 3_600)
    monday = Date.current.beginning_of_week
    @user.calendar_entries.create!(route: @route, scheduled_on: monday, start_time: "08:00", end_time: "08:30")
    @user.calendar_entries.create!(route: other, scheduled_on: monday, start_time: "17:00", end_time: "18:00")

    get calendar_url

    assert_select "article[id=?]", "mob-week-day-#{monday.strftime('%Y%m%d')}" do
      assert_select %(div[data-controller="mob-slider"] div[data-mob-slider-target="track"]) do
        assert_select "div.mob-wc__slider-slide > article.mob-wc__entry", count: 2
      end
      assert_select "button.mob-wc__slider-dot", count: 2
    end
  end

  test "same-day same-time entries keep their slide order across a completed toggle" do
    other = @user.routes.create!(source: "upload", title: "Valley loop", duration: 3_600)
    monday = Date.current.beginning_of_week
    older = @user.calendar_entries.create!(route: @route, scheduled_on: monday,
                                           start_time: "08:00", end_time: "08:30")
    newer = @user.calendar_entries.create!(route: other, scheduled_on: monday,
                                           start_time: "08:00", end_time: "08:30")
    # dom_id(entry, :mob_entry) as the _entry_card partial renders it.
    expected = %W[mob_entry_calendar_entry_#{older.id} mob_entry_calendar_entry_#{newer.id}]

    get calendar_url

    # Same day AND start time: creation order decides — and must survive the
    # UPDATE a completed toggle performs (heap order used to reshuffle it).
    assert_equal expected,
                 css_select("div.mob-wc__slider-slide > article.mob-wc__entry").map { |el| el["id"] }

    patch toggle_completed_calendar_path, params: { entry_id: older.id, from_calendar: "1" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }
    assert_response :ok

    get calendar_url

    assert_equal expected,
                 css_select("div.mob-wc__slider-slide > article.mob-wc__entry").map { |el| el["id"] }
  end

  test "mobile friend view swaps my actions for read-only ones" do
    friend = User.create!(valid_user_attributes(email: "mobilefriend@example.com"))
    Friendship.connect!(friend, @user)
    friend_route = create_friend_route_with_gpx(friend)
    friend.calendar_entries.create!(route: friend_route,
                                    scheduled_on: Date.current.beginning_of_week + 1,
                                    start_time: "07:30", end_time: "08:30")

    get friend_calendar_path(friend.username, week: Date.current.beginning_of_week.iso8601)

    assert_response :success
    # No scheduling affordances in the friend view
    assert_select "section.mob-wc" do
      assert_select "button.mob-wc__addtile", count: 0
      assert_select "div.mob-sheet", count: 0
    end
    assert_select "article[id=?]",
                  "mob-week-day-#{(Date.current.beginning_of_week + 1).strftime('%Y%m%d')}" do
      assert_select "button", text: /Join ride/
    end
    # The friend's week routes list downloads GPX instead of scheduling
    assert_select %(a.mob-wc__route-btn[href^="#{download_route_path(friend_route)}"])
  end

  test "allocate from the grid also streams the mobile day panel and KPI tiles" do
    post allocate_calendar_path, params: { route_id: @route.id, scheduled_on: "2026-10-28", start_time: "09:30",
                                           from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="mob-week-day-20261028"/, response.body)
    assert_match(/action="update" target="mob-week-kpi-container"/, response.body)
  end

  test "remove_entry from the grid also streams the mobile day panel and KPI tiles" do
    entry = @user.calendar_entries.create!(route: @route, scheduled_on: Date.new(2026, 10, 28),
                                           start_time: "08:00", end_time: "09:00")

    delete remove_entry_calendar_path, params: { entry_id: entry.id, from_calendar: "1", week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="mob-week-day-20261028"/, response.body)
    assert_match(/action="update" target="mob-week-kpi-container"/, response.body)
  end

  test "join streams the mobile day panel too" do
    friend = User.create!(valid_user_attributes(email: "mobilejoin@example.com"))
    Friendship.connect!(friend, @user)
    friend_route = create_friend_route_with_gpx(friend)
    friend_entry = friend.calendar_entries.create!(route: friend_route, scheduled_on: Date.new(2026, 10, 27),
                                                   start_time: "07:30", end_time: "08:30")

    post join_calendar_path, params: { entry_id: friend_entry.id, week: "2026-10-26" },
          headers: { "ACCEPT" => Mime[:turbo_stream].to_s }

    assert_response :ok
    assert_match(/action="replace" target="mob-week-day-20261027"/, response.body)
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
