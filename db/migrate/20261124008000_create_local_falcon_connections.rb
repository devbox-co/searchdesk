class CreateLocalFalconConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :local_falcon_connections do |t|
      t.references :site, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :client_id, :callback_url, :place_id, :verified_name, :status, :state_digest, :sync_key
      t.bigint :initiator_id
      t.text :verifier, :access_token, :refresh_token, :last_error
      t.datetime :state_expires_at, :token_expires_at, :synced_at, :last_attempt_at
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
  end
end
