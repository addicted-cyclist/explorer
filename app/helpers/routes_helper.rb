module RoutesHelper
  include ActionView::Helpers::NumberHelper

  # 428.4 -> "428.4", 1240.0 -> "1,240.0"; nil -> an em dash
  def format_distance(km)
    return "&mdash;".html_safe if km.blank? || km.zero?

    number_with_precision(km, precision: 1, delimiter: ",")
  end

  # 1240.0 -> "+1,240" (design shows a leading plus on elevation figures)
  def format_elevation(meters)
    return "&mdash;".html_safe if meters.blank? || meters.zero?

    "+#{number_with_delimiter(meters.round)}"
  end

  # 11220 -> "3.1 h", 2700 -> "45 min", nil/0 -> an em dash
  def format_duration(seconds)
    return "&mdash;".html_safe if seconds.blank? || seconds.zero?

    if seconds >= 3600
      "#{number_with_precision(seconds / 3600.0, precision: 1)} h"
    else
      "#{(seconds / 60.0).round} min"
    end
  end

  # 86400 -> "1 day ago" (Rails helper) with an em dash fallback
  def uploaded_ago(route)
    return "&mdash;".html_safe if route.created_at.blank?

    time_ago_in_words(route.created_at)
  end

  def sport_type_label(route)
    route.sport_type.presence || "Ride"
  end
end
