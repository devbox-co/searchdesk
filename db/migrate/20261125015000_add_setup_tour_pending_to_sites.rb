class AddSetupTourPendingToSites < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :setup_tour_pending, :boolean, default: false, null: false
  end
end
