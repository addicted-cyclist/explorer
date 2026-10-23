class CalendarEntry < ApplicationRecord
  belongs_to :user
  belongs_to :route

  # Set when this entry was created by joining a friend's scheduled ride —
  # the link that keeps the dock's Join → Joined state stable across renders.
  belongs_to :origin_entry, class_name: "CalendarEntry", optional: true

  # Scheduled on a concrete calendar date; start/end are times of day on
  # that date (the detail page's month grid + start-time picker).
  validates :scheduled_on, presence: true
  validates :start_time, presence: true
  validates :end_time, presence: true
  validate :end_time_after_start_time

  scope :between, ->(range) { where(scheduled_on: range) }

  def day_name
    scheduled_on ? scheduled_on.strftime("%A") : "Unknown"
  end

  # Sort key for calendar rendering: date first, then the start time; entries
  # without a start time sink to the bottom of their day.
  def calendar_sort_key
    [ scheduled_on, start_time ? start_time.seconds_since_midnight : Float::INFINITY ]
  end

  # The entry a route's add-to-calendar picker manages: the next upcoming
  # one, else the most recent — so the popover keeps an entry to reschedule
  # or remove even when every ride is in the past. Nil when the route was
  # never scheduled.
  def self.tracked_by_route(route, owner)
    tracked_entry_from(owner.calendar_entries.where(route: route).order(:scheduled_on, :start_time))
  end

  # The .tracked_by_route policy applied to a preloaded, ordered list — the
  # library grid resolves every card's picker state from one query
  # (RoutesController#index) instead of one per route.
  def self.tracked_entry_from(entries)
    entries = entries.to_a
    entries.select { |entry| entry.scheduled_on >= Date.current }
           .min_by(&:calendar_sort_key) ||
      entries.max_by(&:calendar_sort_key)
  end

  # Join a scheduled ride (friend view / public share): deep-copies the
  # origin's route into +owner+'s library (own GPX blob, see
  # Route#deep_copy_for) and books +owner+'s own entry on the same date and
  # time, linked back via origin_entry so the Join docks keep their "Joined"
  # state across renders. Idempotent: a repeated join of the same ride
  # (double POST, stale UI) never deep-copies twice — the existing copy is
  # returned as-is. A ride that already lives on +owner+'s calendar can
  # never be copied (technote.BUGS.md 4): the origin owner joining their own
  # ride on the public share, or any copy whose ancestry touches one of
  # +owner+'s entries (copies of copies, sibling branches of one join
  # chain), raises ActiveRecord::RecordInvalid before any route is copied.
  # Raises ActiveRecord::RecordInvalid on a bad booking.
  def self.join_ride!(origin_entry, owner:)
    existing = owner.calendar_entries.find_by(origin_entry_id: origin_entry.id)
    return existing if existing

    if ride_already_on_calendar?(origin_entry, owner)
      rejected = new(user: owner, origin_entry: origin_entry)
      rejected.errors.add(:base, "This ride is already on your calendar")
      raise ActiveRecord::RecordInvalid.new(rejected)
    end

    route = origin_entry.route.deep_copy_for(owner)
    route.save!
    owner.calendar_entries.create!(
      route: route,
      origin_entry: origin_entry,
      scheduled_on: origin_entry.scheduled_on,
      start_time: origin_entry.start_time,
      # A joined ride is a fresh plan — never born completed, even when the
      # origin ride (or its route) is already done.
      completed: false,
      # The joined entry keeps the origin's scheduled slot; if the origin's
      # end time is missing (legacy rows), rebuild it from the copy's moving
      # duration.
      end_time: origin_entry.end_time || origin_entry.start_time + route.moving_duration
    )
  end

  # True when the ride +entry+ belongs to is already booked on +owner+'s
  # calendar: either one of +owner+'s own entries sits anywhere in +entry+'s
  # origin chain (the origin owner on their own public share, or a copy of
  # their ride), or one of +owner+'s joined copies shares an ancestor with
  # +entry+'s chain — the same ride reached through another branch of the
  # join chain. The copy-side ancestry is walked one level per query (never
  # one query per copy), so the cost is bounded by chain depth, not by how
  # many rides +owner+ has already joined.
  def self.ride_already_on_calendar?(entry, owner)
    target_chain = origin_chain(entry)
    return true if target_chain.any? { |chain_entry| chain_entry.user_id == owner.id }

    target_ids = target_chain.map(&:id)
    seen_ids = target_ids.dup
    frontier_ids = owner.calendar_entries.where.not(origin_entry_id: nil)
                                              .pluck(:origin_entry_id).uniq
    until frontier_ids.empty?
      # Detect before de-duplicating: a re-encountered ancestor can still be
      # the shared ride the check exists for.
      return true if frontier_ids.any? { |id| target_ids.include?(id) }

      fresh_ids = frontier_ids - seen_ids
      break if fresh_ids.empty?

      seen_ids += fresh_ids
      frontier_ids = CalendarEntry.where(id: fresh_ids).pluck(:origin_entry_id).compact.uniq
    end
    false
  end

  # +entry+'s join lineage: itself plus every entry reached by following
  # origin_entry links upward. A dangling link (the pointed-to entry was
  # destroyed) ends the walk; the seen-check keeps it cycle-proof.
  def self.origin_chain(entry)
    chain = []
    seen = []
    current = entry
    while current && seen.exclude?(current.id)
      seen << current.id
      chain << current
      current = current.origin_entry_id && CalendarEntry.find_by(id: current.origin_entry_id)
    end
    chain
  end

  # ---- ride identity (join-tree roots) ---------------------------------------

  # Ride identity: for each of +entries+, the id of its join-tree root — the
  # ride's original entry (or the highest surviving ancestor when that
  # original was deleted). Every entry of one ride resolves to the same root
  # however the ride was joined. One query per ancestry level for the whole
  # batch, never per entry; a dangling origin ends its chain and the
  # in-memory resolution is seen-guarded against corrupt cycles.
  def self.ride_roots_for(entries)
    nodes = entries.index_by(&:id)
    walk_up_ancestry!(nodes)
    resolve_ride_roots(nodes)
  end

  # Ride-wide attendance for a batch of entries: for each entry id, the
  # ride's original entry (:author — the join-tree root, whose owner is the
  # person the popover names even on a joined copy) and the number of
  # distinct OTHER riders on the same ride (:participants — every user
  # holding an entry anywhere in the tree: the author, sibling branches,
  # copies of copies). Walks ancestry upward, then the whole tree downward
  # from the roots, one level per query — bounded by tree depth, never by
  # ride or joiner count.
  def self.ride_attendance_for(entries)
    nodes = entries.index_by(&:id)
    walk_up_ancestry!(nodes)
    root_of = resolve_ride_roots(nodes)

    riders = Hash.new { |hash, root_id| hash[root_id] = [] }
    nodes.each_value { |node| riders[root_of[node.id]] << node.user_id }

    # Down from the roots: the rest of each ride's tree — sibling branches
    # the batch's own ancestry never touched.
    frontier_ids = nodes.values.select { |node| root_of[node.id] == node.id }.map(&:id)
    until frontier_ids.empty?
      children = CalendarEntry.where(origin_entry_id: frontier_ids)
                              .where.not(id: nodes.keys).to_a
      break if children.empty?

      children.each do |child|
        nodes[child.id] = child
        root_of[child.id] = root_of[child.origin_entry_id]
        riders[root_of[child.id]] << child.user_id
      end
      frontier_ids = children.map(&:id)
    end

    # One query for every ride author's user — the popover renders the
    # author's initials and name per card and must never query per card.
    roots = nodes.values.select { |node| root_of[node.id] == node.id }
    authors = User.where(id: roots.map(&:user_id)).index_by(&:id)
    roots.each { |root| root.user = authors[root.user_id] if authors.key?(root.user_id) }

    entries.to_h do |entry|
      root_id = root_of[entry.id]
      [ entry.id, { author: nodes[root_id], participants: riders[root_id].uniq.size - 1 } ]
    end
  end

  # Ids of +entries+ whose ride +user+ already attends — by ride identity,
  # not by entry: the ride's original owner, a join via the original, a
  # sibling branch or a copy of a copy all count, matching
  # ride_already_on_calendar?'s join guard. Both sides resolve through
  # ride_roots_for, so the cost stays level-batched.
  def self.joined_entry_ids(entries, user)
    # My own originals are their own ride roots; joined copies walk up.
    my_ride_ids = user.calendar_entries.where(origin_entry_id: nil).pluck(:id)
    my_ride_ids += ride_roots_for(user.calendar_entries.where.not(origin_entry_id: nil)).values.uniq

    roots = ride_roots_for(entries)
    entries.filter_map { |entry| my_ride_ids.include?(roots[entry.id]) ? entry.id : nil }
  end

  # Load every ancestor of +nodes+' entries into +nodes+ (id => entry), one
  # level per query. Only loaded entries' parents queue up, so a dangling
  # origin (deleted ancestor) ends its chain instead of looping forever.
  private_class_method def self.walk_up_ancestry!(nodes)
    pending_ids = nodes.values.filter_map(&:origin_entry_id).uniq - nodes.keys
    until pending_ids.empty?
      found = CalendarEntry.where(id: pending_ids).to_a
      found.each { |parent| nodes[parent.id] = parent }
      pending_ids = found.filter_map(&:origin_entry_id).uniq - nodes.keys
    end
  end

  # Map every entry in +nodes+ to its ride root id: follow origin links in
  # memory (all ancestors are loaded by then) until the chain tops out. The
  # seen-check keeps corrupt, cyclic data bounded.
  private_class_method def self.resolve_ride_roots(nodes)
    root_of = {}
    nodes.each_value do |node|
      next if root_of.key?(node.id)

      chain = []
      seen_ids = []
      current = node
      until current.nil? || root_of.key?(current.id) || seen_ids.include?(current.id)
        seen_ids << current.id
        chain << current
        current = current.origin_entry_id && nodes[current.origin_entry_id]
      end
      root_id = current && root_of[current.id]
      root_id ||= chain.last.id
      chain.each { |chain_node| root_of[chain_node.id] = root_id }
    end
    root_of
  end

  private

  # end_time is a bare time-of-day (no date column) and the app only derives
  # it as start + the route's moving duration — so an end earlier than the
  # start is a midnight-crossing ride (end on the next day), never garbage.
  # Only an end equal to the start (zero duration) is invalid.
  def end_time_after_start_time
    return if start_time.blank? || end_time.blank?

    errors.add(:end_time, "must be after start time") if end_time == start_time
  end
end
