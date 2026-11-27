class SeoCompetitorEvidenceJob < ApplicationJob
  def perform(site_id, series_id, owner_id)
    site = Site.find_by(id: site_id)
    return [] unless site

    Tracking::SerpEvidenceRecovery.call(site: site, series_id: series_id, owner_id: owner_id, feature: "P2")
  end
end
