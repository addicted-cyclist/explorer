Rails.application.routes.draw do
  devise_for :users, controllers: { registrations: "users/registrations" }

  # Public read-only calendar via shareable token (no auth)
  get "c/:token", to: "public_calendar#show", as: :public_calendar

  authenticated :user do
    root "routes#index", as: :authenticated_root
  end

  unauthenticated do
    root "pages#landing", as: :unauthenticated_root
  end

  resources :routes

  resource :calendar, only: %i[show] do
    collection do
      post "allocate"
      patch "update_entry"
      delete "remove_entry"
    end
  end

  namespace :google_drive do
    get "connect"
    get "callback"
    get "files"
    post "import"
  end

  resource :account, only: %i[show update], controller: :accounts

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
