class SeoWorkflowSchedule < ApplicationRecord
  belongs_to :site

  validates :template_key, inclusion: { in: ->(_) { SeoWorkflows::Catalogue::TEMPLATES.values.select { |template| template.available? && template.cadence != :on_demand }.map(&:key) } }

  def run_due!(now: Time.current)
    template = SeoWorkflows::Catalogue.fetch(template_key)
    local_time = now.in_time_zone(site.time_zone)
    return if local_time.hour < (template_key == "R3" ? 10 : 8)

    day = template.period_on(local_time.to_date)
    return unless day && created_at.in_time_zone(site.time_zone).to_date <= day + 1

    existing = site.seo_workflow_runs.find_by(template_key: template_key, site_host: site.host, period_on: day)
    if (existing.nil? || existing.status == "missing_evidence") &&
        LocalSeoData::Collection.scheduled?(site, template_key) && self.class.exists?(id)
      capture = LocalSeoData::Collection.call(site: site, template: template, day: day)
      return if capture == :pending
    end

    if template_key == "R1" && existing&.status == "complete" &&
        site.source_snapshots.where("updated_at > ? AND updated_at <= ?", existing.updated_at, now).where(
          "metrics->>'kind' = 'review_activity' AND metrics->>'host' = ? AND metrics->>'period_on' = ? AND metrics->>'state' = 'captured'",
          site.host, day.iso8601).exists?
      with_lock { existing.refresh_weekly_report!(now: now) }
      return
    end

    with_lock { SeoWorkflowRun.generate!(site: site, template: template, day: day, now: now) }
  rescue ActiveRecord::RecordNotFound
    raise if self.class.exists?(id)
  end
end
