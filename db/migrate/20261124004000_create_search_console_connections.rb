class CreateSearchConsoleConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :search_console_connections do |t|
      t.references :site, null: false, foreign_key: true, index: { unique: true }
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at
      t.jsonb :allowed_properties, default: [], null: false
      t.string :property
      t.string :status, null: false, default: "disconnected"
      t.string :last_error
      t.datetime :synced_at
      t.date :data_through
      t.datetime :sync_started_at
      t.string :sync_key
      t.jsonb :report, default: {}, null: false
      t.timestamps
    end
    create_table :search_console_grants do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :state_digest, null: false, index: { unique: true }
      t.text :verifier, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    create_table :search_console_reports do |t|
      t.references :search_console_connection, null: false, foreign_key: { on_delete: :cascade }, index: { name: "index_gsc_reports_on_connection" }
      t.string :property, null: false
      t.date :period_end, null: false
      t.jsonb :report, null: false
      t.timestamps
    end
    add_index :search_console_reports, [:search_console_connection_id, :property, :period_end], unique: true, name: "index_gsc_reports_by_binding_and_period"
  end
end
