require "digest"

module SearchConsole
  class DailyPositions
    METHOD = "gsc_web_exact_query_property_all_devices_v1"
    ZONE = "America/Los_Angeles"
    COUNTRIES = YAML.safe_load_file(Rails.root.join("config/search_console_country_codes.yml")).freeze
    BASES = %w[complete_ui_report final_api].freeze

    def self.country_for(site)
      COUNTRIES[site.rank_country_code.to_s.upcase]
    end

    def self.scope_for(site)
      site.source_snapshots.where(provider: "gsc")
        .where("metrics->>'series_method' = ? AND metrics->>'country' = ?", METHOD, country_for(site))
        .where("metrics->>'source_basis' IN (?) AND metrics->>'search_type' = 'web' AND metrics->>'device_scope' = 'all'", BASES)
    end

    def self.remove_live!(site)
      site.source_snapshots.where(provider: "gsc").where("external_id LIKE 'daily-position-%' AND metrics->>'source_basis' = 'final_api' AND metrics->>'series_method' = ?", METHOD).delete_all
    end

    # Scope-preserving GSC snapshots. Each keyword/property/country/month has one
    # live record. Only the refreshed interval is replaced. Historical UI receipts stay intact.
    def self.persist!(site:, property:, country:, terms:, start_day:, end_day:, rows:)
      return unless country && start_day && end_day && terms.any?
      grouped = rows.group_by { |row| [row.fetch("keyword"), row.fetch("date")[0, 7]] }
      months = (start_day..end_day).map { |date| date.strftime("%Y-%m") }.uniq
      terms.each do |phrase|
        months.each do |month|
          id = "daily-position-#{Digest::SHA256.hexdigest(JSON.generate([METHOD, property, country, phrase, month]))}"
          fresh = grouped.fetch([phrase, month], [])
          snapshot = site.source_snapshots.find_by(provider: "gsc", external_id: id)
          previous = snapshot&.metrics&.fetch("daily", []) || []
          kept = previous.reject { |row| row.fetch("date").between?(start_day.iso8601, end_day.iso8601) }
          days = (kept + fresh.map { |row| row.except("keyword") }).sort_by { |row| row.fetch("date") }
          month_start = Date.iso8601("#{month}-01")
          from = [start_day, month_start].max
          through = [end_day, month_start.end_of_month].min
          snapshot ||= site.source_snapshots.new(provider: "gsc", external_id: id)
          queried = (Array(snapshot.metrics["queried_days"]) | (from..through).map(&:iso8601)).sort
          snapshot.assign_attributes(title: "Daily Search Console positions · #{phrase} · #{month}", keyword: phrase,
            observed_on: Date.iso8601(queried.last),
            scope: "#{property} · #{country} · Google Web · exact query · all devices · property aggregation · Pacific dates",
            metrics: { "series_method" => METHOD, "property" => property, "country" => country, "device_scope" => "all",
              "search_type" => "web", "source_basis" => "final_api", "daily" => days, "queried_days" => queried,
              "start" => queried.first, "end" => queried.last })
          snapshot.save! if snapshot.changed?
        end
      end
    end
  end
end
