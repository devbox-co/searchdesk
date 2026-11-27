require "digest"
require "uri"

module SeoWorkflows
  class AiVisibilitySample
    class Unavailable < StandardError; end

    PROVIDER = "DataForSEO AI responses"
    GOOGLE = "google_ai_overviews"
    MODELS = { GOOGLE => "Google Search", "gemini" => "gemini-2.5-flash", "perplexity" => "sonar", "chatgpt" => "gpt-4.1-mini" }.freeze
    LABELS = { GOOGLE => "Google AI Overview", "gemini" => "Gemini", "perplexity" => "Perplexity", "chatgpt" => "ChatGPT" }.freeze

    def self.configured_for?(site)
      ENV["DATAFORSEO_AI_SITE_ID"] == site.id.to_s && ENV["DATAFORSEO_AI_SITE_HOST"] == site.host &&
        Tracking::DataForSeo.enabled?
    end

    def self.status_text(snapshot)
      metrics = snapshot.metrics
      case metrics["status"]
      when "queued"
        snapshot.created_at.utc.to_date == Time.current.utc.to_date ? "Queued for the worker." : "Queued sample expired."
      when "collecting"
        snapshot.updated_at > 5.minutes.ago ? "Awaiting the provider response." : "Provider response unconfirmed."
      when "cancelled" then "Cancelled because the approval or configuration changed."
      when "captured"
        if metrics["engine"] == GOOGLE
          return "No AI Overview was returned for this search." if metrics["overview_coverage"] == "no_overview"
          return "AI Overview content could not be confirmed for this search." if metrics["overview_coverage"] == "unavailable"
        end
        return "No usable citation URLs returned." if metrics["site_cited"].nil?

        "Site link observed: #{metrics['site_cited'] ? 'yes' : 'no'} across #{metrics.fetch('citation_count')} usable citation URLs."
      else
        "Provider response unconfirmed."
      end
    end

    def self.web_settings(site)
      return unless configured_for?(site)

      country, prompt = ENV.values_at("DATAFORSEO_AI_WEB_COUNTRY", "DATAFORSEO_AI_WEB_PROMPT").map(&:to_s)
      engines = ENV["DATAFORSEO_AI_WEB_ENGINES"].to_s.split(",").map(&:strip).uniq & MODELS.keys
      location = google_location(site, country)
      engines -= [GOOGLE] unless location
      return unless engines.any? && valid_input?(country, prompt)

      { country: country, prompt: prompt, engines: engines, revision: Digest::SHA256.hexdigest([country, prompt, location].to_json) }
    end

    def self.request(site:, owner_id:, engine:, revision:)
      settings = web_settings(site)
      unless settings && settings.fetch(:engines).include?(engine) && settings.fetch(:revision) == revision
        raise Unavailable, "The sample configuration changed. Review the current prompt and try again."
      end

      snapshot = reserve(site:, owner_id:, engine:, country: settings.fetch(:country), prompt: settings.fetch(:prompt), status: "queued")
      raise ActiveJob::EnqueueError unless SeoAiVisibilitySampleJob.perform_later(snapshot.id, owner_id)
      snapshot
    rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError
      snapshot.update!(metrics: snapshot.metrics.merge("status" => "unconfirmed"))
      raise Unavailable, "The sample could not be queued. The attempt remains reserved."
    end

    def self.perform(snapshot, owner_id)
      site = snapshot.site
      ready = snapshot.with_lock do
        metrics = snapshot.metrics
        next false unless snapshot.provider == PROVIDER && metrics["status"] == "queued"

        settings = web_settings(site)
        allowed = settings && metrics["host"] == site.host && site.workspace.memberships.exists?(user_id: owner_id, role: "owner") &&
          settings.fetch(:country) == metrics["country"] && settings.fetch(:engines).include?(metrics["engine"]) &&
          Digest::SHA256.hexdigest(settings.fetch(:prompt)) == metrics["prompt_digest"] &&
          MODELS[metrics["engine"]] == metrics["model"] && snapshot.created_at.utc.to_date == Time.current.utc.to_date &&
          (metrics["engine"] != GOOGLE || google_location(site, metrics["country"]) == metrics.slice("location_code", "location"))
        snapshot.update!(metrics: metrics.merge("status" => allowed ? "collecting" : "cancelled"))
        settings if allowed
      end
      return unless ready

      capture(snapshot, engine: snapshot.metrics.fetch("engine"), country: ready.fetch(:country), prompt: ready.fetch(:prompt))
    rescue Unavailable
      snapshot.update!(metrics: snapshot.metrics.merge("status" => "unconfirmed"))
    end

    def self.call(site:, owner_id:, engine:, country:, prompt:)
      snapshot = reserve(site:, owner_id:, engine:, country:, prompt:, status: "unconfirmed")
      capture(snapshot, engine:, country:, prompt:)
    end

    def self.reserve(site:, owner_id:, engine:, country:, prompt:, status:)
      unless configured_for?(site) && site.workspace.memberships.exists?(user_id: owner_id, role: "owner")
        raise Unavailable, "Paid sampling requires a configured site and current workspace owner."
      end
      unless MODELS.key?(engine) && valid_input?(country, prompt)
        raise Unavailable, "Choose Google AI Overviews, ChatGPT, Gemini or Perplexity, a two-letter country and a public prompt of up to 488 characters."
      end

      location = {}
      if engine == GOOGLE
        location = google_location(site, country)
        raise Unavailable, "Verify the Google search market for the selected site and country first." unless location
        if URI::DEFAULT_PARSER.unescape(prompt).scrub.match?(Tracking::DataForSeo::PREMIUM_OPERATOR)
          raise Unavailable, "Use a public search question within the standard Google sample budget."
        end
      end

      now = Time.current
      identity = { provider: PROVIDER, external_id: "#{engine}-#{now.utc.to_date}" }
      SourceSnapshot.transaction do
        Tracking::DataForSeoBudget.lock!
        if site.source_snapshots.exists?(identity)
          raise Unavailable, "This engine already has a sample or a reserved attempt for today (UTC)."
        end
        if Tracking::DataForSeoBudget.daily_full?(now) || Tracking::DataForSeoBudget.rolling_full?(now)
          raise Unavailable, "The configured DataForSEO task limit has been reached."
        end

        title = engine == GOOGLE ? "Google AI Overview search sample" : "#{LABELS.fetch(engine)} response sample"
        site.source_snapshots.create!(**identity, title: title,
          observed_on: now.in_time_zone(site.time_zone).to_date,
          scope: "One DataForSEO API response for the approved public prompt and country. Gemini receives the country as prompt context.",
          metrics: { "host" => site.host, "engine" => engine, "country" => country, "model" => MODELS.fetch(engine),
            "prompt_digest" => Digest::SHA256.hexdigest(prompt), "status" => status }.merge(location))
      end
    end

    def self.valid_input?(country, prompt)
      country.match?(/\A[A-Z]{2}\z/) && (1..488).cover?(prompt.length) &&
        prompt == prompt.strip && !prompt.match?(/[[:cntrl:]]/)
    end

    def self.google_location(site, country)
      return unless site.rank_location_verified_at && site.rank_country_code == country &&
        site.rank_location_code.to_i.positive? && site.rank_location_name.present?

      { "location_code" => site.rank_location_code, "location" => site.rank_location_name }
    end

    def self.capture(snapshot, engine:, country:, prompt:)
      return capture_google(snapshot, prompt) if engine == GOOGLE

      model = MODELS.fetch(engine)
      reference, result = Tracking::DataForSeo.new.llm_response(engine: engine, model: model, country: country, prompt: prompt)
      sections = result.fetch("items").filter_map do |item|
        item["sections"] if item.is_a?(Hash) && item["type"] == "message" && item["sections"].is_a?(Array)
      end.flatten(1)
      unless sections.any? { |section| section.is_a?(Hash) && section["type"] == "text" }
        raise Unavailable, "The provider returned no text section. This attempt stays reserved."
      end
      citations = sections.grep(Hash).flat_map { |section| Array(section["annotations"]) }.grep(Hash).filter_map do |annotation|
        url = engine == "gemini" ? annotation["direct_url"] : annotation["url"]
        uri = URI.parse(url.to_s)
        uri.host.downcase.delete_suffix(".").delete_prefix("www.") if uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo
      rescue URI::Error
        nil
      end
      host = snapshot.metrics.fetch("host").delete_prefix("www.")
      snapshot.update!(metrics: snapshot.metrics.merge(
        "status" => "captured", "model" => result.fetch("model_name"), "provider_reference" => reference, "citation_count" => citations.size,
        "site_cited" => citations.empty? ? nil : citations.any? { |name| name == host || name.end_with?(".#{host}") }
      ))
      snapshot
    rescue Tracking::DataForSeo::Unavailable
      raise Unavailable, "The provider response could not be confirmed. This attempt stays reserved to avoid a duplicate charge."
    end

    def self.capture_google(snapshot, prompt)
      metrics = snapshot.metrics
      reference, result = Tracking::DataForSeo.new.google_overview(keyword: prompt, location_code: metrics.fetch("location_code"))
      evidence = Tracking::GoogleAiOverview.sample(result, host: metrics.fetch("host"))
      snapshot.update!(metrics: metrics.merge("status" => "captured", "provider_reference" => reference,
        "overview_coverage" => evidence.fetch("coverage"), "citation_count" => evidence.fetch("citation_count", 0),
        "site_cited" => evidence["site_link_observed"], "device" => "desktop"))
      snapshot
    end

    private_class_method :reserve, :valid_input?, :capture, :google_location, :capture_google
  end
end
