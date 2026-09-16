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

  resources :routes, except: %i[new] do
    member do
      patch :toggle_completed
      get :download
      post :save
    end
  end

  # Public, tokenized GPX streaming for the gpx.studio embed. The signed_id
  # is the capability token and the response carries CORS headers, so the
  # embed (served from gpx.studio) can fetch the file without a session.
  # OPTIONS is matched too because Chrome's Private Network Access sends a
  # preflight for the loopback/dev-host fetch.
  match "gpx/:signed_id/*filename", to: "gpx_files#show", via: %i[get options], as: :gpx_file, format: false

  resource :calendar, only: %i[show] do
    collection do
      post "allocate"
      patch "update_entry"
      delete "remove_entry"
      post "join"
    end
  end

  # A friend's week view (Phase 7). GET-only and placed after the resource,
  # so it can never shadow the collection's POST/PATCH/DELETE actions.
  get "calendar/:username", to: "calendars#show", as: :friend_calendar

  # Friends directory (Phase 7 ships the read-only list; management later).
  get "friends", to: "friends#index", as: :friends

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
