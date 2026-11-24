class CreateWorkspaceAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.integer :session_version, null: false, default: 1
      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :workspaces do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :memberships do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false
      t.timestamps
    end
    add_index :memberships, [:workspace_id, :user_id], unique: true
    add_check_constraint :memberships, "role IN ('owner','manager','viewer')", name: "membership_role_valid"

    create_table :sites do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.string :host, null: false
      t.string :location, null: false
      t.string :language, null: false, default: "en"
      t.string :time_zone, null: false, default: "Europe/London"
      t.string :tracking_mode, null: false, default: "manual"
      t.timestamps
    end
    add_index :sites, [:workspace_id, :host], unique: true
    add_check_constraint :sites, "tracking_mode IN ('manual','demo','dataforseo')", name: "site_tracking_mode_valid"
  end
end
