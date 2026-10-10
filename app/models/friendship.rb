# A directed friendship edge. The friends feature (Phase 10) stores one row
# per direction; Phase 6 only reads them to gate the route detail page.
class Friendship < ApplicationRecord
  belongs_to :user
  belongs_to :friend, class_name: "User"

  STATUSES = %w[accepted pending].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :friend_id }
  validate :not_self_friendship

  scope :accepted, -> { where(status: "accepted") }
  scope :pending, -> { where(status: "pending") }

  # Create the mutual pair (one row per direction) so both sides can read
  # the relationship with a single-direction query.
  def self.connect!(user, friend, status: "accepted")
    user.friendships.create!(friend: friend, status: status)
    friend.friendships.create!(friend: user, status: status)
  end

  # Phase 11 — the "Add" button behind the Find friends popup. "Add" starts a
  # *pending* request: exactly one directed row (sender -> recipient). It is
  # idempotent (re-adding is a no-op), no-ops for existing friendships, and
  # auto-accepts when the other side already asked first (two requests
  # crossing mid-flight collapse into an instant friendship).
  def self.send_request!(sender, recipient)
    accepted.find_by(user_id: sender.id, friend_id: recipient.id) ||
      accepted.find_by(user_id: recipient.id, friend_id: sender.id) ||
      pending.find_by(user_id: sender.id, friend_id: recipient.id) ||
      pending.find_by(user_id: recipient.id, friend_id: sender.id)&.tap(&:accept!) ||
      sender.friendships.create!(friend: recipient, status: "pending")
  end

  def pending?
    status == "pending"
  end

  def accepted?
    status == "accepted"
  end

  # Accept a pending request: this row flips to accepted and the mirror row
  # (recipient -> sender) is created, restoring the two-row invariant that
  # accepted friendships are stored in both directions. Idempotent: accepting
  # an already-accepted edge is a no-op.
  def accept!
    return self if accepted?
    raise ActiveRecord::RecordInvalid, "only pending requests can be accepted" unless pending?

    transaction do
      update!(status: "accepted")
      mirror = friend.friendships.find_or_initialize_by(friend: user)
      mirror.status = "accepted"
      mirror.save!
    end
    self
  end

  private

  def not_self_friendship
    errors.add(:friend, "can't be yourself") if user == friend
  end
end
