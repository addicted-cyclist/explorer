# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# ---- Phase 11 — demo social graph (development only, idempotent) -----------
# Gives the friends page something to show: two accepted friends (Morgan
# rides this week with a completed ride; Casey only has a completed library
# route), one zero-activity athlete (the empty card variant) and one pending
# incoming request. Sign in as riley@example.com / password123.
if Rails.env.development?
  demo_user = lambda do |username, first, last|
    User.find_or_create_by!(email: "#{username}@example.com") do |user|
      user.username = username
      user.first_name = first
      user.last_name = last
      user.password = "password123"
    end
  end

  me = demo_user.call("riley", "Riley", "Rider")
  rider = demo_user.call("morgan", "Morgan", "Vale")
  planner = demo_user.call("casey", "Casey", "Brook")
  newcomer = demo_user.call("avery", "Avery", "Stone")

  # A wider pond for the Find friends search demo — athletes riley is not
  # connected to yet (type "ala", "jor", "nin"… in the popup).
  demo_user.call("alana", "Alana", "Vega")
  demo_user.call("jordan", "Jordan", "Reyes")
  demo_user.call("tara", "Tara", "Quinn")
  demo_user.call("milo", "Milo", "Banks")
  demo_user.call("nina", "Nina", "Cho")
  demo_user.call("oscar", "Oscar", "Wilde")

  Friendship.connect!(me, rider) unless me.friends_with?(rider)
  Friendship.connect!(me, planner) unless me.friends_with?(planner)
  # Idempotent by design: a repeated seed run returns the existing request.
  Friendship.send_request!(newcomer, me)

  # Morgan rides this week: today's ride already completed, one still planned.
  morgan_route = rider.routes.find_or_create_by!(title: "Ridgeline Loop") do |route|
    route.distance = 48.3
    route.elevation_gain = 812.0
    route.duration = 7200
    route.sport_type = "Road"
    route.tier = "Moderate"
  end
  unless rider.calendar_entries.exists?(route: morgan_route)
    rider.calendar_entries.create!(
      route: morgan_route, scheduled_on: Date.current,
      start_time: Time.current.change(hour: 8),
      end_time: Time.current.change(hour: 10),
      completed: true
    )
    rider.calendar_entries.create!(
      route: morgan_route, scheduled_on: 2.days.from_now,
      start_time: Time.current.change(hour: 8),
      end_time: Time.current.change(hour: 10),
      completed: false
    )
  end

  # Casey plans only: a completed library route, never scheduled.
  planner.routes.find_or_create_by!(title: "Gravel Meridian") do |route|
    route.distance = 62.7
    route.elevation_gain = 1044.0
    route.duration = 10_800
    route.sport_type = "Gravel"
    route.tier = "Hard"
    route.completed = true
  end
end
