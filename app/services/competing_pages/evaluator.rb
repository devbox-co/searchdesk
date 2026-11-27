module CompetingPages
  class Evaluator
    WEEKS = 8

    def self.call(site:, property:, country:)
      site.with_lock do
        connection = SearchConsoleConnection.lock.find_by(site: site, property: property)
        next unless connection&.status == "connected" && country.present? && country == SearchConsole::DailyPositions.country_for(site)
        next unless SearchConsole::Client.matches?(property, site.host)

        # A receipt represents Monday through Sunday in Google's reporting zone.
        last_week = SearchConsole::CompetingPageSync.latest_week(connection.data_through)
        findings = SiteFinding.competing_pages.where(site: site)
        current_ids = []
        if last_week
          weeks = Array.new(WEEKS) { |i| last_week - (WEEKS - 1 - i) * 7 }
          keywords = SearchConsole::CompetingPageSync.tracked_keywords(site).group_by { |keyword| keyword.phrase.downcase }
          weekly_groups = SearchConsolePageWeek.where(site: site, property: property, country: country,
            query: keywords.keys, device: SearchConsolePageWeek::DEVICES, week_start: weeks.first..weeks.last).group_by { |r| [r.query, r.device] }
          weekly_groups.each do |(query, device), reports|
            keyword = keywords[query]&.first
            evidence = Comparison.new(host: site.host, weeks: weeks, reports: reports).call
            next unless evidence

            evidence.merge!("query" => query, "device" => device, "property" => property, "country" => country,
              "preferred_url" => Comparison.public_page(keyword.preferred_url, site.host))
            fingerprint = Digest::SHA256.hexdigest(JSON.generate([property, country, query, device, evidence.fetch("pages")]))
            finding = findings.find_or_initialize_by(fingerprint: fingerprint)
            # The same decision continues across weekly snapshots. Reopen when new evidence
            # first establishes repeated switches or newly combines them with falling clicks.
            if finding.persisted? && evidence["level"] == "review" &&
                (finding.level != "review" || (evidence.dig("clicks", "material_decline") && !finding.evidence.dig("clicks", "material_decline")))
              finding.disposition = "open"
            end
            finding.assign_attributes(keyword: keyword, level: evidence.fetch("level"), active: true, evidence: evidence)
            finding.save! if finding.changed?
            current_ids << finding.id
          end
        end
        findings.current.where.not(id: current_ids).update_all(active: false, updated_at: Time.current)
        current_ids.length
      end
    end
  end
end
