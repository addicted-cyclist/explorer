# Phase 11 — the pending-request lifecycle behind the friends page: create
# sends a request from the Find friends popup, update accepts an incoming
# one, destroy declines it. Turbo Streams repaint the affected fragments
# (popup row, pending section, friends grid); plain HTML falls back to a
# redirect for no-JS submissions.
class FriendRequestsController < ApplicationController
  def create
    @candidate = User.find(params[:friend_id])
    raise ActiveRecord::RecordNotFound if @candidate == current_user

    # Idempotent: re-adding, an existing friendship or a crossed pair of
    # requests all resolve through send_request! (the last auto-accepts).
    Friendship.send_request!(current_user, @candidate)
    @edge = current_user.friend_edges_for([ @candidate ])[@candidate.id]

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to friends_path }
    end
  end

  def update
    @request = my_pending_request
    new_friend = @request.user
    @card = User.friend_cards_for([ new_friend ], Date.current.all_week).fetch(new_friend.id)
    @request.accept!
    @remaining_requests = fresh_incoming_requests
    @sports_by_user = User.sport_types_by_id(@remaining_requests.map(&:user_id))

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to friends_path }
    end
  end

  def destroy
    @request = my_pending_request
    @request.destroy!
    @remaining_requests = fresh_incoming_requests
    @sports_by_user = User.sport_types_by_id(@remaining_requests.map(&:user_id))

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to friends_path }
    end
  end

  private

  # Only the recipient may act on a pending request — acting on someone
  # else's (or on a non-pending row) is a 404, never a silent success.
  def my_pending_request
    friend_request = Friendship.pending.find(params[:id])
    raise ActiveRecord::RecordNotFound unless friend_request.friend_id == current_user.id

    friend_request
  end

  def fresh_incoming_requests
    current_user.incoming_requests.includes(:user).order(created_at: :desc)
  end
end
