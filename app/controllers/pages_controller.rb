class PagesController < ApplicationController
  # Landing page: marketing root shown to signed-out visitors
  # (root "pages#landing", as: :unauthenticated_root).
  skip_before_action :authenticate_user!, only: :landing

  def landing
  end
end
