Rails.application.routes.draw do
  get "up", to: "rails/health#show", as: :rails_health_check
  root "dashboard#index"
  get "dashboard", to: "dashboard#index", as: :dashboard
  get "rankings", to: "dashboard#index", as: :rankings
  get "signup", to: "registrations#new"
  post "signup", to: "registrations#create"
  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy"
  get "onboarding", to: "onboarding#new"
  post "onboarding", to: "onboarding#create"
  post "sites/:id/select", to: "sites#select", as: :select_site
  resource :email_verification, only: %i[new create]
  get "email_verification/:token", to: "email_verifications#show", as: :verify_email
  post "email_verification/:token", to: "email_verifications#confirm"
  resources :workspace_members, only: %i[index create update destroy]
  resources :password_resets, only: %i[new create edit update], param: :token
  resources :keywords, only: %i[new create show update] do
    patch :preferred_page, on: :member
    resources :rank_imports, only: %i[new create]
  end
  resources :actions, only: %i[index update], controller: "keyword_actions"
  post "actions/:id/draft", to: "action_drafts#create", as: :action_draft
  get "actions/:id/draft", to: "action_drafts#show"
  resource :wording_setting, only: %i[show update]
  get "catalogue", to: "integrations#catalogue", as: :public_catalogue
  resources :integrations, only: %i[index show update]
  resource :search_console, only: %i[show update destroy], controller: "search_console" do
    post :authorize
    get :callback
    post :sync
  end
end
