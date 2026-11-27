class SeoWorkflowCollectionJob < ApplicationJob
  def perform(site_id, template_key, period_on, owner_id)
    site = Site.find_by(id: site_id)
    return unless site && site.workspace.memberships.exists?(user_id: owner_id, role: "owner")

    template = SeoWorkflows::Catalogue.fetch(template_key)
    day = Time.current.in_time_zone(site.time_zone).to_date
    period = template.period_on(day)
    return unless period&.iso8601 == period_on

    capture = LocalSeoData::Collection.call(site: site, template: template, day: period)
    SeoWorkflowRun.generate!(site: site, template: template, day: period) unless capture == :pending && !(template_key == "M2" && LocalSeoData::Collection.data_for_seo?(site, template_key))
  end
end
