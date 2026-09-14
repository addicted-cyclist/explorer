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

  # Create the mutual pair (one row per direction) so both sides can read
  # the relationship with a single-direction query.
  def self.connect!(user, friend, status: "accepted")
    user.friendships.create!(friend: friend, status: status)
    friend.friendships.create!(friend: user, status: status)
  end

  private

  def not_self_friendship
    errors.add(:friend, "can't be yourself") if user == friend
  end
end
