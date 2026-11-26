class CreateSiteAudits < ActiveRecord::Migration[8.1]
  def change
    create_table :site_audits do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.string :host, null: false
      t.string :status, null: false, default: "queued"
      t.jsonb :report, null: false, default: {}
      t.string :failure_reason
      t.datetime :started_at, :finished_at
      t.timestamps
      t.index [:site_id, :created_at]
      t.index :site_id, unique: true, where: "status IN ('queued','running')", name: "one_active_site_audit"
    end
  end
end
