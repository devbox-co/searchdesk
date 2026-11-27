class CreateSiteFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :site_findings do |t|
      t.references :site, null: false, foreign_key: {on_delete: :cascade}
      t.references :keyword, foreign_key: {on_delete: :nullify}
      t.string :kind, null: false
      t.string :fingerprint, null: false
      t.string :level, null: false
      t.boolean :active, null: false, default: true
      t.string :disposition, null: false, default: "open"
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_index :site_findings, [:site_id, :kind, :fingerprint], unique: true
    add_index :site_findings, [:site_id, :active, :kind, :level]
  end
end
