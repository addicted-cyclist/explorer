# Phase 7: read-only friends directory feeding the calendar's friend view.
# Phase 11: the directory becomes the friends page — rich week cards with
# each friend's last completed ride, the Find friends popup (every account
# with its relationship state) and the pending-request section. All card
# datasets are loaded batched (one query per dataset, never per friend).
class FriendsController < ApplicationController
  def index
    @friends = current_user.friends.order(:username)
    @friend_cards = User.friend_cards_for(@friends, Date.current.all_week)
    @riding_count = @friend_cards.values.count { |card| card.week_count.positive? }

    @incoming_requests = current_user.incoming_requests.includes(:user).order(created_at: :desc)
    @requester_sports = User.sport_types_by_id(@incoming_requests.map(&:user_id))

    @candidates = User.where.not(id: current_user.id).order(:username)
    @candidate_edges = current_user.friend_edges_for(@candidates)
  end
end
