class SeoWorkflowSchedule < ApplicationRecord
  belongs_to :site

  validates :template_key, inclusion: { in: ->(_) { SeoWorkflows::Catalogue::TEMPLATES.values.select { |template| template.available? && template.cadence != :on_demand }.map(&:key) } }

  def next_check(now:, latest_run:)
    template = SeoWorkflows::Catalogue.fetch(template_key)
    today = now.in_time_zone(site.time_zone).to_date
    period = template.period_on(today)
    if enabled_for?(period) && (latest_run&.period_on != period || latest_run.status == "missing_evidence")
      earliest = check_time(today)
      return earliest if earliest > now
      return
    end

    following = case template.cadence
    when :daily then today.tomorrow
    when :weekly then today.beginning_of_week + 7
    when :monthly then today.beginning_of_month.next_month
    when :quarterly then today.beginning_of_quarter.next_quarter
    end
    check_time(following) if following
  end

  def run_due!(now: Time.current)
    template = SeoWorkflows::Catalogue.fetch(template_key)
    local_time = now.in_time_zone(site.time_zone)
    return if local_time < check_time(local_time.to_date)

    day = template.period_on(local_time.to_date)
    return unless enabled_for?(day)

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
  private

  def check_time(day)
    day.in_time_zone(site.time_zone).change(hour: template_key == "R3" ? 10 : 8)
  end

  def enabled_for?(period)
    period && created_at.in_time_zone(site.time_zone).to_date <= period + 1
  end
end
