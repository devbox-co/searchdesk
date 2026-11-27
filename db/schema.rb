# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_26_080000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "action_drafts", force: :cascade do |t|
    t.bigint "keyword_action_id", null: false
    t.string "skill_version", null: false
    t.string "input_digest", null: false
    t.jsonb "instructions", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "input_snapshot", default: {}, null: false
    t.string "owner_choice"
    t.string "owner_choice_note", limit: 1000
    t.jsonb "link_check_result", default: {}, null: false
    t.datetime "link_checked_at"
    t.datetime "link_check_started_at"
    t.index ["keyword_action_id", "skill_version", "input_digest"], name: "unique_action_draft_input", unique: true
    t.index ["keyword_action_id"], name: "index_action_drafts_on_keyword_action_id"
    t.check_constraint "owner_choice::text = ANY (ARRAY['keep_preferred'::character varying, 'prefer_ranking'::character varying]::text[])", name: "action_draft_owner_choice_valid"
  end

  create_table "ai_connections", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.text "api_key"
    t.string "project_label"
    t.integer "monthly_budget_cents", default: 0, null: false
    t.uuid "revision", null: false
    t.string "status", default: "untested", null: false
    t.datetime "last_verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id"], name: "index_ai_connections_on_workspace_id", unique: true
    t.check_constraint "monthly_budget_cents >= 0", name: "ai_budget_nonnegative"
  end

  create_table "ai_runs", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "user_id"
    t.bigint "parent_id"
    t.string "kind", null: false
    t.string "status", default: "pending", null: false
    t.text "question"
    t.date "report_on", null: false
    t.uuid "connection_revision"
    t.uuid "setting_revision"
    t.string "recipe_version"
    t.string "model"
    t.string "failure_code"
    t.string "provider_request_id"
    t.string "request_key", null: false
    t.jsonb "evidence", default: {}, null: false
    t.jsonb "answer", default: {}, null: false
    t.bigint "reserved_microusd", default: 0, null: false
    t.bigint "actual_microusd"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.datetime "attempted_at"
    t.datetime "finished_at"
    t.datetime "erased_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "site_finding_id"
    t.string "page_advice_digest", limit: 64
    t.index ["parent_id"], name: "index_ai_runs_on_parent_id"
    t.index ["site_finding_id"], name: "index_ai_runs_on_site_finding_id"
    t.index ["site_id", "attempted_at"], name: "index_ai_runs_on_site_id_and_attempted_at", where: "(attempted_at IS NOT NULL)"
    t.index ["site_id", "report_on", "recipe_version"], name: "one_ai_brief_per_day_and_recipe", unique: true, where: "((kind)::text = 'brief'::text)", nulls_not_distinct: true
    t.index ["site_id", "request_key"], name: "index_ai_runs_on_site_id_and_request_key", unique: true
    t.index ["site_id"], name: "index_ai_runs_on_site_id"
    t.index ["status", "created_at"], name: "index_ai_runs_on_status_and_created_at", where: "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('running'::character varying)::text]))"
    t.index ["user_id"], name: "index_ai_runs_on_user_id"
  end

  create_table "ai_settings", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.boolean "enabled", default: false, null: false
    t.boolean "managers_enabled", default: false, null: false
    t.boolean "daily_brief_enabled", default: false, null: false
    t.boolean "share_google", default: false, null: false
    t.boolean "share_maps", default: false, null: false
    t.boolean "share_semrush", default: false, null: false
    t.text "services"
    t.text "priorities"
    t.text "enquiry_definition"
    t.uuid "revision", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_ai_settings_on_site_id", unique: true
  end

  create_table "analytics_connections", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.text "access_token"
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.string "grant_key", null: false
    t.string "status", default: "choose_property", null: false
    t.string "property_id"
    t.string "property_name"
    t.string "property_zone"
    t.string "verified_host"
    t.jsonb "stream_ids", default: [], null: false
    t.string "sync_key"
    t.datetime "sync_started_at"
    t.datetime "synced_at"
    t.string "last_error"
    t.jsonb "report", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_analytics_connections_on_site_id", unique: true
  end

  create_table "analytics_grants", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "user_id", null: false
    t.string "state_digest", null: false
    t.text "verifier", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_analytics_grants_on_site_id"
    t.index ["state_digest"], name: "index_analytics_grants_on_state_digest", unique: true
    t.index ["user_id"], name: "index_analytics_grants_on_user_id"
  end

  create_table "business_profile_connections", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.text "refresh_token", null: false
    t.string "grant_revision", null: false
    t.string "account_id"
    t.string "location_id"
    t.string "site_host", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_business_profile_connections_on_site_id", unique: true
  end

  create_table "business_profile_publications", force: :cascade do |t|
    t.bigint "seo_workflow_run_id", null: false
    t.integer "row_index", null: false
    t.bigint "confirmed_by_id"
    t.string "status", null: false
    t.string "grant_revision", null: false
    t.text "provider_reference"
    t.datetime "attempted_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["confirmed_by_id"], name: "index_business_profile_publications_on_confirmed_by_id"
    t.index ["seo_workflow_run_id", "row_index"], name: "index_business_profile_publications_on_draft", unique: true
    t.index ["seo_workflow_run_id"], name: "index_business_profile_publications_on_seo_workflow_run_id"
  end

  create_table "daily_slots", force: :cascade do |t|
    t.bigint "tracking_series_id", null: false
    t.date "day", null: false
    t.string "status", default: "pending", null: false
    t.string "reason"
    t.string "task_id"
    t.datetime "attempted_at"
    t.datetime "last_queued_at"
    t.datetime "retry_after"
    t.integer "poll_attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "attempt_key"
    t.index ["attempt_key"], name: "index_daily_slots_on_attempt_key", unique: true, where: "(attempt_key IS NOT NULL)"
    t.index ["status", "retry_after"], name: "index_daily_slots_on_status_and_retry_after"
    t.index ["task_id"], name: "index_daily_slots_on_task_id", unique: true, where: "(task_id IS NOT NULL)"
    t.index ["tracking_series_id", "day"], name: "index_daily_slots_on_tracking_series_id_and_day", unique: true
    t.index ["tracking_series_id"], name: "index_daily_slots_on_tracking_series_id"
  end

  create_table "keyword_actions", force: :cascade do |t|
    t.bigint "tracking_series_id", null: false
    t.string "kind", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.string "status", default: "open", null: false
    t.date "observed_on", null: false
    t.jsonb "evidence", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tracking_series_id", "kind"], name: "index_keyword_actions_on_tracking_series_id_and_kind", unique: true
    t.index ["tracking_series_id"], name: "index_keyword_actions_on_tracking_series_id"
  end

  create_table "keyword_page_assignments", force: :cascade do |t|
    t.bigint "keyword_id", null: false
    t.date "effective_on", null: false
    t.string "url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["keyword_id", "effective_on"], name: "index_keyword_page_assignments_on_keyword_id_and_effective_on", unique: true
    t.index ["keyword_id"], name: "index_keyword_page_assignments_on_keyword_id"
  end

  create_table "keywords", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "phrase", null: false
    t.string "preferred_url"
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "phrase"], name: "index_keywords_on_site_id_and_phrase", unique: true
    t.index ["site_id"], name: "index_keywords_on_site_id"
  end

  create_table "local_falcon_connections", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "client_id"
    t.string "callback_url"
    t.string "place_id"
    t.string "verified_name"
    t.string "status"
    t.string "state_digest"
    t.string "sync_key"
    t.bigint "initiator_id"
    t.text "verifier"
    t.text "access_token"
    t.text "refresh_token"
    t.text "last_error"
    t.datetime "state_expires_at"
    t.datetime "token_expires_at"
    t.datetime "synced_at"
    t.datetime "last_attempt_at"
    t.jsonb "result", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "ai_grant_revision", default: -> { "gen_random_uuid()" }, null: false
    t.index ["site_id"], name: "index_local_falcon_connections_on_site_id", unique: true
  end

  create_table "local_falcon_street_maps", force: :cascade do |t|
    t.bigint "source_snapshot_id", null: false
    t.string "report_key", null: false
    t.binary "png"
    t.datetime "retry_after"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source_snapshot_id"], name: "index_local_falcon_street_maps_on_source_snapshot_id", unique: true
  end

  create_table "login_sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_login_sessions_on_user_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.bigint "user_id", null: false
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.index ["workspace_id", "user_id"], name: "index_memberships_on_workspace_id_and_user_id", unique: true
    t.index ["workspace_id"], name: "index_memberships_on_workspace_id"
    t.check_constraint "role::text = ANY (ARRAY['owner'::character varying::text, 'manager'::character varying::text, 'viewer'::character varying::text])", name: "membership_role_valid"
  end

  create_table "project_tasks", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "external_id", null: false
    t.string "title", null: false
    t.string "status", null: false
    t.string "priority", null: false
    t.text "summary"
    t.text "source_path"
    t.string "working_status"
    t.text "owner_note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "external_id"], name: "index_project_tasks_on_site_id_and_external_id", unique: true
    t.index ["site_id"], name: "index_project_tasks_on_site_id"
  end

  create_table "prospect_audits", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "requested_by_id"
    t.string "site_host", null: false
    t.string "target_host", null: false
    t.string "business_name", null: false
    t.string "market", null: false
    t.string "keyword", null: false
    t.date "requested_on", null: false
    t.string "website_status", default: "queued", null: false
    t.jsonb "website_report", default: {}, null: false
    t.string "provider_status", default: "off", null: false
    t.string "provider_job_id"
    t.integer "provider_poll_count", default: 0, null: false
    t.datetime "next_poll_at"
    t.jsonb "provider_report", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["requested_by_id"], name: "index_prospect_audits_on_requested_by_id"
    t.index ["site_id", "site_host", "requested_on", "target_host", "business_name", "market", "keyword"], name: "index_prospect_audits_on_daily_scope", unique: true
    t.index ["site_id", "site_host", "requested_on"], name: "index_prospect_audits_on_site_and_day"
    t.index ["site_id"], name: "index_prospect_audits_on_site_id"
  end

  create_table "rank_observations", force: :cascade do |t|
    t.bigint "daily_slot_id", null: false
    t.datetime "captured_at", null: false
    t.string "status", null: false
    t.integer "position"
    t.integer "preferred_position"
    t.string "winning_url"
    t.string "preferred_url"
    t.integer "coverage", null: false
    t.string "source", null: false
    t.jsonb "evidence", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["daily_slot_id"], name: "index_rank_observations_on_daily_slot_id", unique: true
  end

  create_table "search_console_connections", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.text "access_token"
    t.text "refresh_token"
    t.datetime "token_expires_at"
    t.jsonb "allowed_properties", default: [], null: false
    t.string "property"
    t.string "status", default: "disconnected", null: false
    t.string "last_error"
    t.datetime "synced_at"
    t.date "data_through"
    t.datetime "sync_started_at"
    t.string "sync_key"
    t.jsonb "report", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "ai_grant_revision", default: -> { "gen_random_uuid()" }, null: false
    t.string "page_week_sync_key"
    t.datetime "page_week_attempted_at"
    t.datetime "page_week_synced_at"
    t.string "page_week_error"
    t.index ["site_id"], name: "index_search_console_connections_on_site_id", unique: true
  end

  create_table "search_console_grants", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "user_id", null: false
    t.string "state_digest", null: false
    t.text "verifier", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_search_console_grants_on_site_id"
    t.index ["state_digest"], name: "index_search_console_grants_on_state_digest", unique: true
    t.index ["user_id"], name: "index_search_console_grants_on_user_id"
  end

  create_table "search_console_page_weeks", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "property", null: false
    t.string "country", limit: 3, null: false
    t.string "query", null: false
    t.string "device", null: false
    t.date "week_start", null: false
    t.jsonb "pages", default: [], null: false
    t.bigint "clicks"
    t.bigint "impressions"
    t.boolean "partial", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "property", "country", "query", "device", "week_start"], name: "unique_search_console_page_week", unique: true
    t.index ["site_id"], name: "index_search_console_page_weeks_on_site_id"
  end

  create_table "search_console_reports", force: :cascade do |t|
    t.bigint "search_console_connection_id", null: false
    t.string "property", null: false
    t.date "period_end", null: false
    t.jsonb "report", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["search_console_connection_id", "property", "period_end"], name: "index_gsc_reports_by_binding_and_period", unique: true
    t.index ["search_console_connection_id"], name: "index_gsc_reports_on_connection"
  end

  create_table "seo_workflow_notifications", force: :cascade do |t|
    t.bigint "seo_workflow_run_id", null: false
    t.bigint "recipient_id"
    t.string "kind", null: false
    t.string "email_status", default: "off", null: false
    t.datetime "email_attempted_at"
    t.datetime "email_sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "slack_revision"
    t.string "slack_status", default: "off", null: false
    t.datetime "slack_attempted_at"
    t.index ["email_status", "id"], name: "index_seo_workflow_notifications_on_email_status_and_id"
    t.index ["recipient_id"], name: "index_seo_workflow_notifications_on_recipient_id"
    t.index ["seo_workflow_run_id", "kind"], name: "index_seo_workflow_notifications_on_event", unique: true
    t.index ["seo_workflow_run_id"], name: "index_seo_workflow_notifications_on_seo_workflow_run_id"
    t.index ["slack_status", "id"], name: "index_seo_workflow_notifications_on_slack_status_and_id"
  end

  create_table "seo_workflow_report_deliveries", force: :cascade do |t|
    t.bigint "seo_workflow_run_id", null: false
    t.bigint "requested_by_id"
    t.text "recipient", null: false
    t.string "status", default: "preview", null: false
    t.datetime "attempted_at"
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["requested_by_id"], name: "index_seo_workflow_report_deliveries_on_requested_by_id"
    t.index ["seo_workflow_run_id"], name: "index_seo_workflow_report_deliveries_on_seo_workflow_run_id", unique: true
    t.index ["status", "id"], name: "index_seo_workflow_report_deliveries_on_status_and_id"
  end

  create_table "seo_workflow_runs", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "template_key", null: false
    t.string "site_host", null: false
    t.date "period_on", null: false
    t.string "status", null: false
    t.jsonb "result", default: [], null: false
    t.bigint "reviewed_by_id"
    t.datetime "reviewed_at"
    t.bigint "delivered_by_id"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["delivered_by_id"], name: "index_seo_workflow_runs_on_delivered_by_id"
    t.index ["reviewed_by_id"], name: "index_seo_workflow_runs_on_reviewed_by_id"
    t.index ["site_id", "template_key", "site_host", "period_on"], name: "index_seo_workflow_runs_on_period_identity", unique: true
    t.index ["site_id"], name: "index_seo_workflow_runs_on_site_id"
  end

  create_table "seo_workflow_schedules", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "template_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "template_key"], name: "index_seo_workflow_schedules_on_site_id_and_template_key", unique: true
    t.index ["site_id"], name: "index_seo_workflow_schedules_on_site_id"
  end

  create_table "site_audits", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "host", null: false
    t.string "status", default: "queued", null: false
    t.jsonb "report", default: {}, null: false
    t.string "failure_reason"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "trigger_kind", default: "manual", null: false
    t.index ["site_id", "created_at"], name: "index_site_audits_on_site_id_and_created_at"
    t.index ["site_id"], name: "index_site_audits_on_site_id"
    t.index ["site_id"], name: "one_active_site_audit", unique: true, where: "((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text]))"
  end

  create_table "site_findings", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "keyword_id"
    t.string "kind", null: false
    t.string "fingerprint", null: false
    t.string "level", null: false
    t.boolean "active", default: true, null: false
    t.string "disposition", default: "open", null: false
    t.jsonb "evidence", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "listing_check"
    t.string "listing_check_token"
    t.datetime "listing_check_started_at"
    t.index ["keyword_id"], name: "index_site_findings_on_keyword_id"
    t.index ["site_id", "active", "kind", "level"], name: "index_site_findings_on_site_id_and_active_and_kind_and_level"
    t.index ["site_id", "kind", "fingerprint"], name: "index_site_findings_on_site_id_and_kind_and_fingerprint", unique: true
    t.index ["site_id"], name: "index_site_findings_on_site_id"
  end

  create_table "site_report_links", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "provider", limit: 48, null: false
    t.string "url", limit: 512, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "provider"], name: "index_site_report_links_on_site_id_and_provider", unique: true
    t.index ["site_id"], name: "index_site_report_links_on_site_id"
  end

  create_table "sites", force: :cascade do |t|
    t.bigint "workspace_id", null: false
    t.string "name", null: false
    t.string "host", null: false
    t.string "location", null: false
    t.string "language", default: "en", null: false
    t.string "time_zone", default: "Europe/London", null: false
    t.string "tracking_mode", default: "manual", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "rank_location_code"
    t.string "rank_country_code", limit: 2
    t.datetime "rank_location_verified_at"
    t.string "rank_location_name"
    t.boolean "weekly_site_audit_enabled", default: false, null: false
    t.boolean "setup_tour_pending", default: false, null: false
    t.boolean "seo_workflow_rollup_enabled", default: false, null: false
    t.bigint "seo_workflow_email_owner_id"
    t.text "seo_slack_webhook"
    t.string "seo_slack_revision"
    t.index ["seo_workflow_email_owner_id"], name: "index_sites_on_seo_workflow_email_owner_id"
    t.index ["workspace_id", "host"], name: "index_sites_on_workspace_id_and_host", unique: true
    t.index ["workspace_id"], name: "index_sites_on_workspace_id"
    t.check_constraint "tracking_mode::text = ANY (ARRAY['manual'::character varying::text, 'demo'::character varying::text, 'dataforseo'::character varying::text])", name: "site_tracking_mode_valid"
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "source_snapshots", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "provider", null: false
    t.string "external_id", null: false
    t.string "title", null: false
    t.date "observed_on", null: false
    t.text "scope", null: false
    t.jsonb "metrics", default: {}, null: false
    t.text "source_url"
    t.text "source_path"
    t.string "keyword"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "map_grid"
    t.index ["site_id", "observed_on"], name: "index_source_snapshots_on_site_id_and_observed_on"
    t.index ["site_id", "provider", "external_id"], name: "index_source_snapshots_on_site_id_and_provider_and_external_id", unique: true
    t.index ["site_id"], name: "index_source_snapshots_on_site_id"
  end

  create_table "tracking_series", force: :cascade do |t|
    t.bigint "keyword_id", null: false
    t.string "device", null: false
    t.string "source", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "fingerprint", null: false
    t.date "enrolled_on", null: false
    t.boolean "paused", default: false, null: false
    t.datetime "archived_at"
    t.bigint "baseline_observation_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["keyword_id", "device"], name: "index_tracking_series_on_keyword_id_and_device", unique: true, where: "(archived_at IS NULL)"
    t.index ["keyword_id"], name: "index_tracking_series_on_keyword_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.integer "session_version", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "email_verified_at"
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "wording_runs", force: :cascade do |t|
    t.bigint "wording_setting_id", null: false
    t.string "revision", null: false
    t.string "status", default: "pending", null: false
    t.string "model"
    t.datetime "attempted_at"
    t.integer "choice"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "skill_version", default: "business_wording/v1", null: false
    t.index ["wording_setting_id", "revision"], name: "index_wording_runs_on_wording_setting_id_and_revision", unique: true
    t.index ["wording_setting_id"], name: "index_wording_runs_on_wording_setting_id"
  end

  create_table "wording_settings", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.text "phrases", default: "", null: false
    t.boolean "enabled", default: false, null: false
    t.string "revision", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_wording_settings_on_site_id", unique: true
  end

  create_table "workspaces", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "action_drafts", "keyword_actions", on_delete: :cascade
  add_foreign_key "ai_connections", "workspaces", on_delete: :cascade
  add_foreign_key "ai_runs", "ai_runs", column: "parent_id", on_delete: :nullify
  add_foreign_key "ai_runs", "site_findings", on_delete: :nullify
  add_foreign_key "ai_runs", "sites", on_delete: :cascade
  add_foreign_key "ai_runs", "users", on_delete: :nullify
  add_foreign_key "ai_settings", "sites", on_delete: :cascade
  add_foreign_key "analytics_connections", "sites", on_delete: :cascade
  add_foreign_key "analytics_grants", "sites", on_delete: :cascade
  add_foreign_key "analytics_grants", "users", on_delete: :cascade
  add_foreign_key "business_profile_connections", "sites", on_delete: :cascade
  add_foreign_key "business_profile_publications", "seo_workflow_runs", on_delete: :cascade
  add_foreign_key "business_profile_publications", "users", column: "confirmed_by_id", on_delete: :nullify
  add_foreign_key "daily_slots", "tracking_series"
  add_foreign_key "keyword_actions", "tracking_series"
  add_foreign_key "keyword_page_assignments", "keywords"
  add_foreign_key "keywords", "sites"
  add_foreign_key "local_falcon_connections", "sites", on_delete: :cascade
  add_foreign_key "local_falcon_street_maps", "source_snapshots", on_delete: :cascade
  add_foreign_key "login_sessions", "users"
  add_foreign_key "memberships", "users"
  add_foreign_key "memberships", "workspaces"
  add_foreign_key "project_tasks", "sites", on_delete: :cascade
  add_foreign_key "prospect_audits", "sites", on_delete: :cascade
  add_foreign_key "prospect_audits", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "rank_observations", "daily_slots"
  add_foreign_key "search_console_connections", "sites"
  add_foreign_key "search_console_grants", "sites", on_delete: :cascade
  add_foreign_key "search_console_grants", "users", on_delete: :cascade
  add_foreign_key "search_console_page_weeks", "sites", on_delete: :cascade
  add_foreign_key "search_console_reports", "search_console_connections", on_delete: :cascade
  add_foreign_key "seo_workflow_notifications", "seo_workflow_runs", on_delete: :cascade
  add_foreign_key "seo_workflow_notifications", "users", column: "recipient_id", on_delete: :nullify
  add_foreign_key "seo_workflow_report_deliveries", "seo_workflow_runs", on_delete: :cascade
  add_foreign_key "seo_workflow_report_deliveries", "users", column: "requested_by_id", on_delete: :nullify
  add_foreign_key "seo_workflow_runs", "sites", on_delete: :cascade
  add_foreign_key "seo_workflow_runs", "users", column: "delivered_by_id", on_delete: :nullify
  add_foreign_key "seo_workflow_runs", "users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "seo_workflow_schedules", "sites", on_delete: :cascade
  add_foreign_key "site_audits", "sites", on_delete: :cascade
  add_foreign_key "site_findings", "keywords", on_delete: :nullify
  add_foreign_key "site_findings", "sites", on_delete: :cascade
  add_foreign_key "site_report_links", "sites", on_delete: :cascade
  add_foreign_key "sites", "users", column: "seo_workflow_email_owner_id", on_delete: :nullify
  add_foreign_key "sites", "workspaces"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "source_snapshots", "sites", on_delete: :cascade
  add_foreign_key "tracking_series", "keywords"
  add_foreign_key "tracking_series", "rank_observations", column: "baseline_observation_id", on_delete: :nullify
  add_foreign_key "wording_runs", "wording_settings", on_delete: :cascade
  add_foreign_key "wording_settings", "sites", on_delete: :cascade
end
