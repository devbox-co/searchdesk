require "digest"

module SeoWorkflows
  class PageComparison
    class Unavailable < StandardError; end

    PROVIDER = "Landing page comparisons"
    DAILY_LIMIT = 3
    TITLE = "Landing page comparison"
    SIDES = { "own" => "Your page", "competitor" => "Competitor page" }.freeze

    def self.scope(site)
      site.source_snapshots.where(provider: PROVIDER).where("metrics->>'host' = ?", site.host)
    end

    def self.request(site:, owner_id:, own_url:, competitor_url:)
      snapshot = nil
      site.with_lock do
        unless site.workspace.memberships.exists?(user_id: owner_id, role: "owner")
          raise Unavailable, "A workspace owner must request the comparison."
        end

        urls = urls_for(site, own_url, competitor_url)
        day = Time.current.in_time_zone(site.time_zone).to_date
        records = scope(site).where(created_at: day.in_time_zone(site.time_zone)...(day + 1).in_time_zone(site.time_zone))
        fingerprint = Digest::SHA256.hexdigest(urls.values.map(&:to_s).to_json)
        identity = "page-comparison-#{day}-#{fingerprint}"
        snapshot = records.find_by(external_id: identity)
        return snapshot if snapshot
        raise Unavailable, "This site has reached today's page comparison limit." if records.count >= DAILY_LIMIT

        snapshot = records.create!(external_id: identity, title: TITLE, observed_on: day,
          scope: "One public HTML reading per page. Content counts cover the main landmark when it can be identified.",
          metrics: { "host" => site.host, "status" => "queued", "urls" => urls.transform_values(&:to_s) })
      end
      raise ActiveJob::EnqueueError unless SeoPageComparisonJob.perform_later(snapshot.id, owner_id)

      snapshot
    rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError
      snapshot.update!(metrics: snapshot.metrics.merge("status" => "unavailable"))
      raise Unavailable, "The page comparison could not be queued."
    end

    def self.perform(snapshot, owner_id)
      site = snapshot.site
      urls = snapshot.with_lock do
        metrics = snapshot.metrics
        next unless snapshot.provider == PROVIDER && metrics["status"] == "queued"

        if metrics["host"] == site.host && site.workspace.memberships.exists?(user_id: owner_id, role: "owner")
          begin
            urls = urls_for(site, *metrics.fetch("urls").values_at(*SIDES.keys))
            snapshot.update!(metrics: metrics.merge("status" => "checking"))
            next urls
          rescue Unavailable
            # The site or address became ineligible while queued.
          end
        end

        snapshot.update!(metrics: metrics.merge("status" => "cancelled"))
        nil
      end
      return unless urls

      pages = urls.transform_values { |uri| SiteAudits::PageSignals.new(uri).call }
      count = pages.count { |_, page| page["status"] == "observed" }
      snapshot.update!(observed_on: Time.current.in_time_zone(site.time_zone).to_date,
        metrics: snapshot.metrics.merge("status" => %w[unavailable partial complete].fetch(count), "pages" => pages))
    end

    def self.status_text(snapshot)
      case snapshot.metrics["status"]
      when "queued" then "Queued for the worker."
      when "checking" then snapshot.updated_at > 5.minutes.ago ? "Checking pages." : "The check did not finish."
      when "complete" then "Both public pages were read."
      when "partial" then "Only one page could be read."
      when "cancelled" then "Cancelled because the site or approval changed."
      else "The comparison is unavailable."
      end
    end

    def self.urls_for(site, own_url, competitor_url)
      competitor_host = Tracking::ResultUrl.parse(competitor_url)&.host
      own = public_page(site.host, own_url)
      rival = public_page(competitor_host, competitor_url) if competitor_host
      unless own && rival && !Tracking::ResultUrl.host_matches?(own.host, rival.host)
        raise Unavailable, "Enter an HTTPS page on this site and an HTTPS page on a different public domain, without query parameters."
      end

      { "own" => own, "competitor" => rival }
    end

    def self.public_page(host, url)
      return unless url.is_a?(String) && url.start_with?("https://")

      SiteAudits::PublicUrl.new(host, https_only: true).resolve(url, base: "https://#{host}/")
    end
    private_class_method :urls_for, :public_page
  end
end
