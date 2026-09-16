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

  # Two-letter avatar initials (header widget, friends list).
  def calendar_initials(user)
    "#{user.first_name[0].to_s.upcase}#{user.last_name[0].to_s.upcase}"
  end
end
