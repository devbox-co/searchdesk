class CreateAiAssistant < ActiveRecord::Migration[8.1]
  def change
    %i[search_console_connections local_falcon_connections].each do |table|
      add_column table, :ai_grant_revision, :uuid, null: false, default: -> { "gen_random_uuid()" }
    end

    create_table :ai_connections do |t|
      t.references :workspace, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.text :api_key
      t.string :project_label
      t.integer :monthly_budget_cents, null: false, default: 0
      t.uuid :revision, null: false
      t.string :status, null: false, default: "untested"
      t.datetime :last_verified_at
      t.timestamps
    end
    add_check_constraint :ai_connections, "monthly_budget_cents >= 0", name: "ai_budget_nonnegative"

    create_table :ai_settings do |t|
      t.references :site, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      %i[enabled managers_enabled daily_brief_enabled share_google share_maps share_semrush].each do |flag|
        t.boolean flag, null: false, default: false
      end
      t.text :services, :priorities, :enquiry_definition
      t.uuid :revision, null: false
      t.timestamps
    end

    create_table :ai_runs do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :parent, foreign_key: { to_table: :ai_runs, on_delete: :nullify }
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.text :question
      t.date :report_on, null: false
      t.uuid :connection_revision, :setting_revision
      t.string :recipe_version, :model, :failure_code, :provider_request_id
      t.string :request_key, null: false
      t.jsonb :evidence, :answer, null: false, default: {}
      t.bigint :reserved_microusd, null: false, default: 0
      t.bigint :actual_microusd
      t.integer :input_tokens, :output_tokens
      t.datetime :attempted_at, :finished_at, :erased_at
      t.timestamps
    end
    add_index :ai_runs, [:site_id, :request_key], unique: true
    add_index :ai_runs, [:site_id, :report_on], unique: true, where: "kind = 'brief'", name: "one_ai_brief_per_day"
    add_index :ai_runs, [:site_id, :attempted_at], where: "attempted_at IS NOT NULL"
    add_index :ai_runs, [:status, :created_at], where: "status IN ('pending','running')"
  end
end
