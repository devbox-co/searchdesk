module SeoWorkflows
  class ProfileMonitor
    include Rails.application.routes.url_helpers

    def initialize(site, day)
      @site, @day = site, day
    end

    def rows
      current = LocalSeoData::Collection.receipt(@site, "M3", @day)
      return [] unless current && current.metrics["host"] == @site.host && current.metrics["state"] == "captured"

      previous = @site.source_snapshots.where(provider: current.provider, observed_on: (@day - 30)...@day)
        .where("metrics->>'host' = ? AND metrics->>'scope_digest' = ?", @site.host, current.metrics.fetch("scope_digest"))
        .where("metrics->>'kind' = 'gbp_monitor' AND metrics->>'state' = 'captured' AND metrics->>'sandbox' = ?",
          current.metrics.fetch("sandbox").to_s)
        .order(observed_on: :desc, id: :desc).first
      fields = current.metrics.fetch("fields")
      before = previous&.metrics&.fetch("fields", {}) || {}
      comparable = fields.keys & before.keys
      changes = comparable.select { |field| fields.fetch(field) != before.fetch(field) }
      text = "Checked #{fields.size} of #{LocalSeoData::BusinessProfile::LABELS.size} monitored fields on #{current.observed_on}."
      if previous && comparable.any?
        text += " Compared #{comparable.size} fields with #{previous.observed_on}."
        text += " No changes observed in comparable fields." if changes.empty?
      elsif previous
        text += " No covered fields overlap the previous reading. This sample establishes a baseline for its covered fields."
      else
        text += " This sample establishes a baseline. A second verified reading is required for comparison."
      end
      output = { "source" => current.metrics["sandbox"] ? "Local SEO Data · profile sandbox" : "#{current.provider} · Business Profile",
        "text" => text, "path" => source_snapshot_path(current),
        "baseline_path" => previous ? source_snapshot_path(previous) : nil,
        "attention" => changes.any? && !current.metrics["sandbox"] }.compact
      unless changes.empty?
        details = LocalSeoData::BusinessProfile::LABELS.filter_map do |field, label|
          next unless changes.include?(field)

          old_value = before.fetch(field).fetch("present")
          new_value = fields.fetch(field).fetch("present")
          status = if old_value && !new_value
            "returned empty"
          elsif !old_value && new_value
            "now shown"
          else
            "changed"
          end
          "#{label} #{status}"
        end
        output["text"] += " #{details.join(', ')}. Check whether these changes were expected."
      end
      [output]
    end
  end
end
