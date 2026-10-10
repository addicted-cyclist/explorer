# Phase 7: read-only friends directory feeding the calendar's friend view.
# Phase 11: the directory becomes the friends page — rich week cards with
# each friend's last completed ride, the pending-request section and the
# Find friends popup. The popup no longer preloads every account: it live
# searches through #candidates (min 3 characters, capped results), so the
# page payload stays flat no matter how big the app grows. All card datasets
# are loaded batched (one query per dataset, never per friend).
class FriendsController < ApplicationController
  CANDIDATES_LIMIT = 20
  MIN_QUERY_LENGTH = 3

  def index
    @friends = current_user.friends.order(:username)
    @friend_cards = User.friend_cards_for(@friends, Date.current.all_week)
    @riding_count = @friend_cards.values.count { |card| card.week_count.positive? }

    @incoming_requests = current_user.incoming_requests.includes(:user).order(created_at: :desc)
    @requester_sports = User.sport_types_by_id(@incoming_requests.map(&:user_id))
  end

  # Live search for the Find friends popup (the popup's Turbo Frame target).
  # Only frame navigations get results; anything else bounces back to the
  # friends page. Short queries answer with a hint instead of a query.
  def candidates
    return redirect_to friends_path unless turbo_frame_request?

    @query = params[:q].to_s.strip
    too_short = @query.length < MIN_QUERY_LENGTH
    matches = too_short ? User.none : User.search_candidates(current_user, @query, limit: CANDIDATES_LIMIT + 1)

    @has_more = matches.size > CANDIDATES_LIMIT
    @candidates = matches.first(CANDIDATES_LIMIT)
    @candidate_edges = current_user.friend_edges_for(@candidates)
  end
end
