class AddListingCheckToSiteFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :site_findings, :listing_check, :jsonb
    add_column :site_findings, :listing_check_token, :string
    add_column :site_findings, :listing_check_started_at, :datetime
  end
end
