# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  protected

  # Allow the profile fields (first_name / last_name / username) on sign-up.
  def sign_up_params
    params.require(:user).permit(:first_name, :last_name, :username, :email,
                                 :password, :password_confirmation)
  end
end
