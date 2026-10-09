class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :routes, dependent: :destroy
  has_many :calendar_entries, dependent: :destroy
  has_many :friendships, dependent: :destroy
  has_many :accepted_friendships, -> { accepted }, class_name: "Friendship", inverse_of: :user
  has_many :friends, through: :accepted_friendships, source: :friend
  # Phase 11 — pending requests: incoming ones address me as :friend_id,
  # outgoing ones as :user_id (the Friendship default foreign key).
  has_many :incoming_requests, -> { pending }, class_name: "Friendship", foreign_key: :friend_id
  has_many :outgoing_requests, -> { pending }, class_name: "Friendship", dependent: :destroy

  validates :first_name, :last_name, presence: true, length: { maximum: 50 }
  validates :username, presence: true,
                       uniqueness: { case_sensitive: false },
                       length: { in: 3..30 },
                       format: {
                         with: /\A[a-zA-Z0-9_]+\z/,
                         message: "can only contain letters, numbers and underscores"
                       }

  # Generate or clear public_token based on calendar_public toggle
  before_save :ensure_public_token

  # Sign-in accepts email OR username: the sign-in form posts the handle as
  # :email (Devise's default authentication key), so match it against both
  # columns case-insensitively.
  def self.find_for_authentication(warden_conditions)
    login = warden_conditions[:email].to_s.strip
    return nil if login.blank?

    where(arel_table[:email].lower.eq(login.downcase))
      .or(where(arel_table[:username].lower.eq(login.downcase)))
      .first
  end

  # The reset form accepts email OR username (like sign-in), but Devise only
  # looks up by email: resolve the submitted handle to the account first,
  # then delegate to Devise's own instruction-sending flow. Must return the
  # record (like Devise's own class method) — PasswordsController reads
  # `resource.errors` on the return value, so returning the Mail::Message
  # the instance method emits would crash it.
  def self.send_reset_password_instructions(attributes = {})
    login = attributes[:email].to_s.strip
    recoverable = find_for_authentication(email: login) if login.present?
    return super unless recoverable

    recoverable.send_reset_password_instructions
    recoverable
  end

  # Display name for the account menu: full name, falling back to username
  def name
    [ first_name, last_name ].join(" ").strip.presence || username
  end

  # True when an accepted friendship links this user and +other+ in either
  # direction. Gates the read-only route detail view (Phase 6 other-user view).
  def friends_with?(other)
    return false if other.nil? || other == self

    Friendship.accepted.exists?(user_id: id, friend_id: other.id) ||
      Friendship.accepted.exists?(user_id: other.id, friend_id: id)
  end

  # Phase 11 — the Find friends popup renders a button per candidate, so the
  # page needs the current relationship for every user in one round trip.
  # Returns { candidate.id => Friendship edge or nil } covering both
  # directions of my edges; the view derives the button state from the edge.
  def friend_edges_for(users)
    edges = Friendship.where(user_id: id).or(Friendship.where(friend_id: id))
    states = users.index_by(&:id).transform_values { nil }
    edges.find_each do |edge|
      other_id = edge.user_id == id ? edge.friend_id : edge.user_id
      next unless states.key?(other_id)

      # Accepted wins if a stale pending row ever coexists with it.
      current = states[other_id]
      states[other_id] = edge if current.nil? || edge.accepted?
    end
    states
  end

  # Single-candidate convenience over friend_edges_for (used by the Turbo
  # Streams that repaint one row): :friends, :incoming_pending,
  # :outgoing_pending or :none.
  def friendship_state_with(other)
    edge = friend_edges_for([ other ])[other.id]
    return :none if edge.nil?
    return :friends if edge.accepted?

    edge.user_id == id ? :outgoing_pending : :incoming_pending
  end

  # ---- Phase 11 — friends page card data -----------------------------------

  # Everything one friend card renders: the friend, their last completed
  # ride (route + display date) and this week's scheduled ride count.
  FriendCard = Struct.new(:friend, :last_ride, :ride_date, :week_count, keyword_init: true)

  # Card data for a whole friends circle, batched by design (Phase 0
  # capacity): one query per dataset regardless of friend count.
  #
  # "Last completed ride" has two sources, in priority order:
  #   1. the latest calendar entry marked done with a non-future scheduled
  #      date — a real ride with a real date;
  #   2. a library route toggled "Done" without ever being scheduled — its
  #      label date falls back to the completion touch (updated_at).
  # Athletes with neither render the empty card variant. Returns
  # { friend.id => User::FriendCard } preserving +users+ order.
  def self.friend_cards_for(users, week_range)
    users_by_id = users.index_by(&:id)
    return {} if users_by_id.empty?

    user_ids = users_by_id.keys

    # Source 1: latest completed entry per friend, ordered latest-first so
    # the first hit per user wins.
    last_entries = {}
    CalendarEntry.where(user_id: user_ids, completed: true)
                 .where(scheduled_on: ..Date.current)
                 .includes(:route)
                 .order(scheduled_on: :desc, start_time: :desc)
                 .each { |entry| last_entries[entry.user_id] ||= entry }

    # Source 2: friends without an entry-ride fall back to their library.
    remaining_ids = user_ids - last_entries.keys
    last_routes = {}
    if remaining_ids.any?
      Route.where(user_id: remaining_ids, completed: true)
           .order(updated_at: :desc)
           .each { |route| last_routes[route.user_id] ||= route }
    end

    week_counts = CalendarEntry.where(user_id: user_ids)
                               .between(week_range)
                               .group(:user_id).count

    users_by_id.transform_values do |friend|
      entry = last_entries[friend.id]
      ride = entry&.route || last_routes[friend.id]
      ride_date = entry ? entry.scheduled_on : ride&.updated_at&.to_date
      FriendCard.new(
        friend: friend,
        last_ride: ride,
        ride_date: ride_date,
        week_count: week_counts[friend.id].to_i
      )
    end
  end

  # Distinct sport types per user id — the "Rides Road & Gravel" meta line
  # on pending request cards — batched into one query.
  def self.sport_types_by_id(user_ids)
    Route.where(user_id: user_ids)
         .where.not(sport_type: [ nil, "" ])
         .distinct.pluck(:user_id, :sport_type)
         .each_with_object({}) do |(user_id, sport_type), map|
      (map[user_id] ||= []) << sport_type
    end
  end

  private

  def ensure_public_token
    if calendar_public? && public_token.blank?
      self.public_token = SecureRandom.urlsafe_base64(32)
    elsif !calendar_public?
      self.public_token = nil
    end
  end
end
