class RecordVerifiedRankLocation < ActiveRecord::Migration[8.1]
  def change
    add_column :sites, :rank_country_code, :string, limit: 2
    add_column :sites, :rank_location_verified_at, :datetime
    add_column :sites, :rank_location_name, :string
  end
end
