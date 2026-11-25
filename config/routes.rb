Rails.application.routes.draw do
  get "up", to: "rails/health#show", as: :rails_health_check
  root "overviews#show"
  get "dashboard", to: "overviews#show", as: :dashboard
  get "schedules", to: "schedules#show", as: :schedules
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
  resource :site_audit, only: %i[show create] do
    patch :schedule
  end
  get "maps/:id/street.png", to: "street_maps#show", as: :street_map, constraints: { id: /\d+/ }, format: false
  resources :source_snapshots, only: %i[index show]
  resources :project_tasks, only: %i[index show update]
  resources :project_imports, only: %i[new create]
  resources :actions, only: %i[index update], controller: "keyword_actions"
  post "actions/:id/draft", to: "action_drafts#create", as: :action_draft
  get "actions/:id/draft", to: "action_drafts#show"
  resource :wording_setting, only: %i[show update]
  get "assistant", to: "assistants#show", as: :assistant
  post "assistant/questions", to: "assistants#ask", as: :assistant_questions
  get "assistant/runs/:id", to: "assistants#run", as: :assistant_run
  delete "assistant/runs/:id", to: "assistants#erase"
  delete "assistant/history", to: "assistants#clear", as: :assistant_history
  get "assistant/settings", to: "assistant_settings#show", as: :assistant_settings
  patch "assistant/settings/site", to: "assistant_settings#update", as: :assistant_site_settings
  patch "assistant/settings/connection", to: "assistant_settings#update_connection", as: :assistant_connection
  delete "assistant/settings/connection", to: "assistant_settings#disconnect"
  post "assistant/settings/test", to: "assistant_settings#test_connection", as: :test_assistant_connection
  get "catalogue", to: "integrations#catalogue", as: :public_catalogue
  resources :integrations, only: %i[index show update]
  resource :search_console, only: %i[show update destroy], controller: "search_console" do
    patch :market
    post :authorize
    get :callback
    post :sync
  end
  resource :local_falcon_connection, only: %i[show update destroy] do
    post :authorize
    get :callback
    post :sync
  end
  resource :analytics, only: %i[show update destroy], controller: "analytics" do
    post :authorize
    get :callback
    post :sync
  end
end
