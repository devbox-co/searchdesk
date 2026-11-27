module SeoWorkflowsHelper
  SEO_STAGES = [
    { id: "collect", name: "Get your data", icon: :integrations, detail: "Connect Google data, Maps scans and keyword tracking." },
    { id: "review", name: "Review changes", icon: :search, detail: "Check page comparisons, site audits and daily briefs." },
    { id: "act", name: "Take action", icon: :tasks, detail: "Decide what to change and check the results." }
  ].freeze

  def seo_status(label, tone)
    icon = { good: :check, active: :clock, warning: :flag, idle: :minus }.fetch(tone)
    tag.span(class: "schedule-pill schedule-pill--#{tone} seo-status") do
      safe_join([ui_icon(icon, size: 13), label])
    end
  end

  def seo_item_date(value)
    day = value.is_a?(Date) ? value : value.in_time_zone(current_site.time_zone).to_date
    time_tag(day, day.strftime("%-d %b %Y"))
  end
  def seo_report_status(run, now: Time.current)
    label, tone = {
      "complete" => ["Ready", :good],
      "missing_evidence" => ["Needs evidence", :warning],
      "awaiting_approval" => ["Awaiting owner approval", :warning],
      "approved" => ["Approved", :good],
      "rejected" => ["Rejected", :idle],
      "expired" => ["Review expired", :idle],
      "delivered" => ["Delivery recorded", :good]
    }.fetch(run.effective_status(now: now))
    seo_status(label, tone)
  end

end
