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

  # 30.0 -> "30", 27.5 -> "27.5"; nil/0 -> an em dash (design: plain km/h)
  def format_pace(kmh)
    return "&mdash;".html_safe if kmh.blank? || kmh.zero?

    rounded = kmh.round(1)
    (rounded % 1).zero? ? rounded.round.to_s : rounded.to_s
  end

  # 22500 -> "6h 15m", 2700 -> "45m"; nil/0 -> "" (input value / compact label)
  def format_duration_input(seconds)
    return "" if seconds.blank? || seconds.zero?

    hours, remainder = seconds.divmod(3600)
    minutes = (remainder / 60.0).round
    hours += 1 if minutes == 60
    minutes = 0 if minutes == 60
    if hours.positive?
      minutes.positive? ? "#{hours}h #{minutes}m" : "#{hours}h"
    else
      "#{minutes}m"
    end
  end

  # "Tier 1 - Easy" … select pairs; the model stores the plain tier name
  def tier_options
    Route::TIERS.each_with_index.map { |tier, index| [ "Tier #{index + 1} - #{tier}", tier ] }
  end

  # Start times offered by the calendar picker (half hours intervals)
  def calendar_start_time_options
    (0..23).flat_map { |hour| [ sprintf("%02d:00", hour), sprintf("%02d:30", hour) ] }
  end

  # Src for the gpx.studio iframe embed (technote Phase 6 integration code).
  # The embed fetches the GPX cross-origin, so it must point at the
  # CORS-enabled public /gpx/ endpoint rather than the authed blob URL.
  def gpx_studio_embed_src(route)
    return unless route.gpx_file.attached?

    options = {
      files: [ gpx_file_url(route.gpx_file.blob.signed_id, route.gpx_file.filename.to_s) ],
      directionMarkers: true,
      theme: "light"
    }
    "https://gpx.studio/embed?options=#{URI.encode_www_form_component(options.to_json)}"
  end
end
