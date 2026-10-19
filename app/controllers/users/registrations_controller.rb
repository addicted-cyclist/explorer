# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  # email verification: a new account starts hard-gated, so mint
  # and email the first 6-digit code right after Devise saves the user.
  # Devise's default sign-in + redirect then hands over to ApplicationController,
  # which bounces every app page to the standalone gate until verified.
  def create
    super do |resource|
      resource.deliver_verification_code if resource.persisted?
    end
  end

  protected

  # Allow the profile fields (first_name / last_name / username) on sign-up.
  def sign_up_params
    params.require(:user).permit(:first_name, :last_name, :username, :email,
                                 :password, :password_confirmation)
  end
end
