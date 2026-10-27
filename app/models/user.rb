class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable,
         :registerable,
         :recoverable,
         :validatable,
         :timeoutable

  has_many :routes, dependent: :destroy
  has_many :calendar_entries, dependent: :destroy
  has_many :friendships, dependent: :destroy
  has_many :accepted_friendships, -> { accepted }, class_name: "Friendship", inverse_of: :user
  has_many :friends, through: :accepted_friendships, source: :friend
  # Phase 11 — pending requests: incoming ones address me as :friend_id,
  # outgoing ones as :user_id (the Friendship default foreign key).
  has_many :incoming_requests, -> { pending }, class_name: "Friendship", foreign_key: :friend_id
  has_many :outgoing_requests, -> { pending }, class_name: "Friendship", dependent: :destroy
  # Phase 12 — friendship rows where I am the :friend_id target (accepted
  # edges opened by the other side + pending requests sent to me). Without
  # cascading these too, the friend_id FK constraint blocks account deletion.
  has_many :incoming_friendships, class_name: "Friendship", foreign_key: :friend_id,
           dependent: :destroy

  # Phase 12 — profile avatar (Active Storage). No variants: image_processing
  # is not in the Gemfile, so views crop with object-fit: cover instead.
  has_one_attached :avatar

  validates :first_name, :last_name, presence: true, length: { maximum: 50 }
  validates :username, presence: true,
                       uniqueness: { case_sensitive: false },
                       length: { in: 3..30 },
                       format: {
                         with: /\A[a-zA-Z0-9_]+\z/,
                         message: "can only contain letters, numbers and underscores"
                       }

  # Phase 12 — avatar rules shown on the account page: JPG/PNG/WebP, ≤ 5 MB.
  AVATAR_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  AVATAR_MAX_BYTES = 5.megabytes

  validate :validate_avatar_format, if: -> { avatar.attached? }

  # Generate or clear public_token based on calendar_public toggle
  before_save :ensure_public_token

  # An email change drops the verified state (and any outstanding
  # code) so a fresh code must confirm the new address. persisted? keeps the
  # callback off creation, where the email always "changes" from nil - new
  # accounts start unverified by design anyway.
  before_save :reset_email_verification,
              if: -> { persisted? && will_save_change_to_email? }

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

  # ---- email verification (6-digit code) ---------------------------
  # Custom flow instead of Devise :confirmable (technote.FEATURES.md): new
  # accounts are hard-gated behind the code modal, while legacy accounts
  # (email_verification_soft, backfilled true in the migration) keep the
  # dismissable nag. Only a peppered HMAC digest of the code is stored —
  # never the plaintext.

  EMAIL_CODE_LENGTH = 6
  EMAIL_CODE_TTL = 10.minutes
  EMAIL_CODE_RESEND_COOLDOWN = 1.minute
  EMAIL_CODE_MAX_ATTEMPTS = 5

  # How long the soft (legacy) nag stays dismissed after "Verify later".
  EMAIL_VERIFICATION_SNOOZE_HOURS = 24

  def email_verified?
    email_verified_at.present?
  end

  def email_verification_soft?
    email_verification_soft
  end

  def email_verification_hard?
    !email_verification_soft?
  end

  # True when there is no live code: none sent yet, past the TTL, or the
  # attempt budget burned. Drives the lazy legacy send and the resend UI.
  def email_code_stale?
    verification_code_digest.blank? || verification_code_sent_at.blank? ||
      verification_code_sent_at.before?(EMAIL_CODE_TTL.ago) ||
      verification_code_attempts >= EMAIL_CODE_MAX_ATTEMPTS
  end

  # Seconds until "Resend code" may fire again (0 = ready now). The modal's
  # countdown is seeded from the same value the server enforces.
  def email_code_cooldown_left
    return 0 if verification_code_sent_at.blank?

    left = (verification_code_sent_at + EMAIL_CODE_RESEND_COOLDOWN - Time.current).ceil
    left.positive? ? left : 0
  end

  # Mints a fresh zero-padded code, stores only its digest and returns the
  # plaintext — whose only consumer is the verification email.
  def generate_email_verification_code!
    code = format("%0#{EMAIL_CODE_LENGTH}d", SecureRandom.random_number(10**EMAIL_CODE_LENGTH))
    update_columns(verification_code_digest: email_code_digest(code),
                   verification_code_sent_at: Time.current,
                   verification_code_attempts: 0)
    code
  end

  # Mint + deliver in one call. A dead SMTP relay must not 500 a sign-up or
  # an app page load — the account can always request a fresh code from the
  # modal, so delivery failures are logged and swallowed.
  def deliver_verification_code
    code = generate_email_verification_code!
    UserMailer.verification_code(self, code).deliver_now
    code
  rescue StandardError => e
    Rails.logger.warn("Verification email could not be sent: #{e.class}: #{e.message}")
    code
  end

  # Checks a submitted code. :ok verifies the account and clears the code;
  # :invalid counts an attempt (wrong or malformed input); :expired means
  # the TTL passed; :exhausted means five bad tries burned the budget and a
  # fresh code must be requested.
  def verify_email_code!(code)
    return :invalid if code.to_s.scan(/\d/).join.length != EMAIL_CODE_LENGTH
    return :exhausted if verification_code_attempts >= EMAIL_CODE_MAX_ATTEMPTS
    return :expired if verification_code_sent_at.blank? || verification_code_sent_at.before?(EMAIL_CODE_TTL.ago)

    if ActiveSupport::SecurityUtils.secure_compare(email_code_digest(code), verification_code_digest.to_s)
      update_columns(email_verified_at: Time.current,
                     verification_code_digest: nil,
                     verification_code_sent_at: nil,
                     verification_code_attempts: 0)
      :ok
    else
      update_columns(verification_code_attempts: verification_code_attempts + 1)
      :invalid
    end
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
    return {} if users.empty?

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

  # Phase 11 — server-side search behind the Find friends popup: the popup
  # no longer preloads every account, it queries as you type (the caller
  # enforces the minimum length and the result cap). Matches the term
  # case-insensitively against first name, last name, the joined full name
  # and the @username. Excludes only +owner+ — friends and pending rows stay
  # searchable so their rows can render the Friends/Requested/Accept states.
  # Pass limit + 1 to detect truncation cheaply.
  def self.search_candidates(owner, term, limit:)
    pattern = "%#{sanitize_sql_like(term)}%"
    where.not(id: owner.id)
         .where("first_name ILIKE :pattern OR last_name ILIKE :pattern " \
                "OR username ILIKE :pattern " \
                "OR (first_name || ' ' || last_name) ILIKE :pattern", pattern: pattern)
         .order(:username)
         .limit(limit)
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
                 .includes(route: { static_map_attachment: :blob })
                 .order(scheduled_on: :desc, start_time: :desc)
                 .each { |entry| last_entries[entry.user_id] ||= entry }

    # Source 2: friends without an entry-ride fall back to their library.
    remaining_ids = user_ids - last_entries.keys
    last_routes = {}
    if remaining_ids.any?
      Route.where(user_id: remaining_ids, completed: true)
           .includes(static_map_attachment: :blob)
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

  # Account-page avatar guard: content type and size, checked on attach
  # (and on every save while an avatar is attached).
  def validate_avatar_format
    return unless avatar.attached?

    unless avatar.blob.content_type.in?(AVATAR_CONTENT_TYPES)
      errors.add(:avatar, "must be a JPG, PNG or WebP image")
    end
    return if avatar.blob.byte_size <= AVATAR_MAX_BYTES

    errors.add(:avatar, "is too large (maximum is 5 MB)")
  end

  # peppered HMAC digest of a verification code: the database only
  # ever stores this, never the plaintext (brute-forcing 10^6 codes needs
  # the pepper, i.e. secret_key_base).
  def email_code_digest(code)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, code.to_s)
  end

  # an email change un-trusts the address: drop the verified flag
  # and any outstanding code so the next visit sends a fresh one to the new
  # address (account page edit or the modal's change-email form).
  def reset_email_verification
    self.email_verified_at = nil
    self.verification_code_digest = nil
    self.verification_code_sent_at = nil
    self.verification_code_attempts = 0
  end
end
