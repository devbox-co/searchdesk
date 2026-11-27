class AddSeoProviderDelivery < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :seo_slack_webhook, :text
    add_column :sites, :seo_slack_revision, :string
    add_column :seo_workflow_notifications, :slack_revision, :string
    add_column :seo_workflow_notifications, :slack_status, :string, null: false, default: "off"
    add_column :seo_workflow_notifications, :slack_attempted_at, :datetime
    add_index :seo_workflow_notifications, [:slack_status, :id]

    create_table :business_profile_connections do |t|
      t.references :site, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.text :refresh_token, null: false
      t.string :grant_revision, null: false
      t.string :account_id
      t.string :location_id
      t.string :site_host, null: false
      t.timestamps
    end

    create_table :business_profile_publications do |t|
      t.references :seo_workflow_run, null: false, foreign_key: { on_delete: :cascade }
      t.integer :row_index, null: false
      t.references :confirmed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :status, null: false
      t.string :grant_revision, null: false
      t.text :provider_reference
      t.datetime :attempted_at, null: false
      t.timestamps
      t.index [:seo_workflow_run_id, :row_index], unique: true, name: "index_business_profile_publications_on_draft"
    end
  end
end
