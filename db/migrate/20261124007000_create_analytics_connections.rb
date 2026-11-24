class CreateAnalyticsConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_connections do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at
      t.string :grant_key, null: false
      t.string :status, null: false, default: "choose_property"
      t.string :property_id
      t.string :property_name
      t.string :property_zone
      t.string :verified_host
      t.jsonb :stream_ids, null: false, default: []
      t.string :sync_key
      t.datetime :sync_started_at
      t.datetime :synced_at
      t.string :last_error
      t.jsonb :report, null: false, default: {}
      t.timestamps
    end

    create_table :analytics_grants do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :state_digest, null: false, index: { unique: true }
      t.text :verifier, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
  end
end
