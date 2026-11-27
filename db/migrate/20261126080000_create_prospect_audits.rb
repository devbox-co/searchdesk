class CreateProspectAudits < ActiveRecord::Migration[8.1]
  def change
    create_table :prospect_audits do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :site_host, null: false
      t.string :target_host, null: false
      t.string :business_name, null: false
      t.string :market, null: false
      t.string :keyword, null: false
      t.date :requested_on, null: false
      t.string :website_status, default: "queued", null: false
      t.jsonb :website_report, default: {}, null: false
      t.string :provider_status, default: "off", null: false
      t.string :provider_job_id
      t.integer :provider_poll_count, default: 0, null: false
      t.datetime :next_poll_at
      t.jsonb :provider_report, default: {}, null: false
      t.timestamps

      t.index [:site_id, :site_host, :requested_on], name: "index_prospect_audits_on_site_and_day"
      t.index [:site_id, :site_host, :requested_on, :target_host, :business_name, :market, :keyword],
        unique: true, name: "index_prospect_audits_on_daily_scope"
    end
  end
end
