class AddMapGridToSourceSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :source_snapshots, :map_grid, :jsonb
  end
end
