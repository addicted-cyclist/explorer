# Phase 7: read-only friends directory feeding the calendar's friend view.
# Friendship management (requests, pending state) arrives in a later phase.
class FriendsController < ApplicationController
  def index
    @friends = current_user.friends.order(:username)
  end
end
