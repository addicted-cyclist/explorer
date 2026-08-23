class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :routes, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }

  # Generate or clear public_token based on calendar_public toggle
  before_save :ensure_public_token

  private

  def ensure_public_token
    if calendar_public? && public_token.blank?
      self.public_token = SecureRandom.urlsafe_base64(32)
    elsif !calendar_public?
      self.public_token = nil
    end
  end
end