class CreateSeoWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :seo_workflow_schedules do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.string :template_key, null: false
      t.timestamps
      t.index [:site_id, :template_key], unique: true
    end

    create_table :seo_workflow_runs do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.string :template_key, null: false
      t.string :site_host, null: false
      t.date :period_on, null: false
      t.string :status, null: false
      t.jsonb :result, default: [], null: false
      t.references :reviewed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :reviewed_at
      t.references :delivered_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :delivered_at
      t.timestamps
      t.index [:site_id, :template_key, :site_host, :period_on], name: "index_seo_workflow_runs_on_period_identity", unique: true
    end
  end
end
