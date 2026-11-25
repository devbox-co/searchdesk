class CreateLocalFalconStreetMaps < ActiveRecord::Migration[8.1]
  def change
    create_table :local_falcon_street_maps do |t|
      t.references :source_snapshot, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :report_key, null: false
      t.binary :png
      t.datetime :retry_after
      t.timestamps
    end
  end
end
