module CalendarsHelper
  # DOM id of a calendar day column — the target of the Turbo Stream fragment
  # swaps (allocate / update_entry / remove_entry / toggle_completed).
  def calendar_day_dom_id(date)
    "wc-day-#{date.strftime('%Y%m%d')}"
  end

  # Entries scheduled on +date+, within-day order (no start time sinks last).
  # Reads the controller-provided @week_entries so show views and stream
  # templates share one code path.
  def calendar_day_entries(date)
    @week_entries.select { |entry| entry.scheduled_on == date }.sort_by(&:calendar_sort_key)
  end

  # True when +entry+ — a friend's scheduled ride — already has my joined
  # copy: the dock swaps to the inert "Joined" button instead of the popover.
  # Reads the controller-provided @joined_origin_ids (nil outside friend view).
  def calendar_entry_joined?(entry)
    @joined_origin_ids&.include?(entry.id) || false
  end

  # "Oct 19 – Oct 25, 2026" range label for the toolbar chip.
  def calendar_week_label(week_start)
    "#{week_start.strftime('%b %-d')} – #{(week_start + 6).strftime('%b %-d, %Y')}"
  end

  # Per-day distance chip: summed route kilometres ("0 km" on rest days).
  def calendar_day_km(entries)
    "#{format_distance(entries.sum { |entry| entry.route.distance.to_f })} km"
  end

  # Weekday/dow accent on cards, chips and day columns.
  def calendar_tier_class(tier)
    case tier
    when "Easy" then "c-success"
    when "Moderate" then "c-primary"
    when "Hard", "Alpine" then "c-accent"
    else "c-tertiary"
    end
  end

  # Toolbar "Today" shortcut only shows when another week is rendered.
  def calendar_off_week?(week_start)
    week_start != Date.current.beginning_of_week
  end

  # Nav/toolbar href for stepping weeks, friend-view aware.
  def calendar_week_path_for(week_start)
    if @is_friend_view
      friend_calendar_path(@friend.username, week: week_start.iso8601)
    else
      calendar_path(week: week_start.iso8601)
    end
  end

  # ---- Phase 8 — mobile weekly calendar -----------------------------------

  # DOM id of a mobile weekly calendar day panel — the .mob-wc mirror of
  # calendar_day_dom_id, target of the same Turbo Stream repaints
  # (allocate / update_entry / remove_entry / toggle_completed / join).
  def calendar_mobile_day_dom_id(date)
    "mob-week-day-#{date.strftime('%Y%m%d')}"
  end

  # Compact week range for the mobile nav pill ("Oct 19 – 25"; the month is
  # spelled out again when the week straddles two months).
  def calendar_week_label_short(week_start)
    week_end = week_start + 6
    if week_start.month == week_end.month
      "#{week_start.strftime('%b %-d')} – #{week_end.strftime('%-d')}"
    else
      "#{week_start.strftime('%b %-d')} – #{week_end.strftime('%b %-d')}"
    end
  end

  # Mobile day-strip chip: summed route kilometres ("108.4k") or "Rest" on
  # empty days.
  def calendar_day_km_short(date)
    km = calendar_day_entries(date).sum { |entry| entry.route.distance.to_f }
    km.zero? ? "Rest" : "#{format_distance(km)}k"
  end

  # Day the mobile layout opens on: the first planned day of the week, else
  # today when the rendered week contains it, else the week start.
  def calendar_mobile_initial_date
    planned = (@week_start..(@week_start + 6)).detect { |date| calendar_day_entries(date).any? }
    today = Date.current if Date.current.between?(@week_start, @week_start + 6)
    planned || today || @week_start
  end

  # ISO dates with scheduled entries in the rendered week — booked-day dots
  # for the mobile schedule sheet's month grid.
  def calendar_booked_dates_json
    @week_entries.map { |entry| entry.scheduled_on.iso8601 }.uniq.to_json
  end

  # Mobile page title, mirroring the desktop hero heading.
  def calendar_title
    @is_friend_view ? "#{@friend.name}'s Calendar" : "My Calendar"
  end

  # Short display name ("Marc") for the mobile friend-view headers.
  def calendar_short_name(user)
    user.name.to_s.split(" ").first.presence || user.username
  end

  # Two-letter avatar initials (header widget, friends list).
  def calendar_initials(user)
    "#{user.first_name[0].to_s.upcase}#{user.last_name[0].to_s.upcase}"
  end
end
