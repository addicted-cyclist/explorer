class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :routes, dependent: :destroy
  has_many :calendar_entries, dependent: :destroy

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
  # then delegate to Devise's own instruction-sending flow.
  def self.send_reset_password_instructions(attributes = {})
    login = attributes[:email].to_s.strip
    recoverable = find_for_authentication(email: login) if login.present?
    return super unless recoverable

    recoverable.send_reset_password_instructions
  end

  # Display name for the account menu: full name, falling back to username
  def name
    [ first_name, last_name ].join(" ").strip.presence || username
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
