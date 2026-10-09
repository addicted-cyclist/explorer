# View helpers for the friends page and the Find friends popup (Phase 11).
module FriendsHelper
  # Label for a completed-ride date: relative inside the last week ("Today",
  # "Yesterday", "3 days ago"), calendar-style after that ("Sep 20").
  def ride_date_label(date)
    return "&mdash;".html_safe if date.blank?

    days = (Date.current - date).to_i
    return "Today" if days <= 0
    return "Yesterday" if days == 1
    return "#{days} days ago" if days <= 6

    date.strftime("%b %-d")
  end

  # Meta line on a pending request card:
  # "Sent 2 hours ago • Rides Road & Gravel" (sports part omitted when the
  # requester has no routes yet).
  def friend_request_meta(request, sports)
    meta = "Sent #{time_ago_in_words(request.created_at)} ago"
    return meta if sports.blank?

    "#{meta} • Rides #{sports.to_sentence}"
  end

  # Button state for a Find friends popup row, derived from the friendship
  # edge (nil = strangers). Direction decides between Requested and Accept.
  def friend_edge_state(edge)
    return :none if edge.nil?
    return :friends if edge.accepted?

    edge.user_id == current_user.id ? :outgoing_pending : :incoming_pending
  end
end
