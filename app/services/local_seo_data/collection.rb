module LocalSeoData
  class Collection
    PROVIDER = "Local SEO Data"
    KINDS = { "M2" => "review_activity", "M3" => "gbp_monitor", "M4" => "dedicated_lsa", "E3" => "citation_audit" }.freeze

    def self.enabled?(site, task)
      return DataForSeoCollection.enabled?(site, task) if data_for_seo?(site, task)

      ENV["LOCALSEODATA_API_KEY"].present? && ENV["LOCALSEODATA_SITE_ID"] == site.id.to_s &&
        ENV["LOCALSEODATA_SITE_HOST"] == site.host && KINDS.key?(task) &&
        ENV["LOCALSEODATA_ALLOWED_TASKS"].to_s.split(",").map(&:strip).include?(task) &&
        settings(site, task).present?
    end

    def self.scheduled?(site, task)
      return DataForSeoCollection.enabled?(site, task) && ENV["DATAFORSEO_#{task}_SCHEDULED"] == "true" if data_for_seo?(site, task)

      enabled?(site, task) && ENV["LOCALSEODATA_SCHEDULED_TASKS"].to_s.split(",").map(&:strip).include?(task)
    end

    def self.settings(site, task)
      return LocalServices.settings if task == "M4"

      name = ENV["LOCALSEODATA_BUSINESS_NAME"].to_s.strip
      return if name.blank? || name.length > 160

      if %w[M2 M3].include?(task)
        place = ENV["LOCALSEODATA_PLACE_ID"].to_s.strip
        location = ENV["LOCALSEODATA_LOCATION"].to_s.strip
        return unless place.match?(/\A[A-Za-z0-9_-]{10,160}\z/) && location.present? && location.length <= 160

        payload = { business_name: name, location: location, place_id: place }
        payload.merge!(sort: "newest", limit: Reviews::LIMIT) if task == "M2"
        payload
      elsif task == "E3"
        address = ENV["LOCALSEODATA_ADDRESS"].to_s.strip
        phone = ENV["LOCALSEODATA_PHONE"].to_s.strip
        return unless address.present? && address.length <= 250 && phone.match?(/\A[+0-9() .-]{7,35}\z/) &&
          phone.count("0-9").between?(7, 15)

        { business_name: name, address: address, phone: phone, website: "https://#{site.host}",
          directories: Citations::DIRECTORIES.keys, industry: "none" }
      end
    end

    def self.receipt(site, task, day)
      return unless KINDS.key?(task)

      providers = %w[M2 M3].include?(task) ? [PROVIDER, DataForSeoCollection::PROVIDER] : [PROVIDER]
      site.source_snapshots.where(provider: providers, external_id: "#{task}-#{day}").order(:id).first
    end

    def self.data_for_seo?(site, task)
      %w[M2 M3].include?(task) && DataForSeoCollection.bound?(site, task)
    end

    def self.call(site:, template:, day:)
      task = template.key
      return unless enabled?(site, task)

      if data_for_seo?(site, task)
        collector = task == "M2" ? DataForSeoReviews : DataForSeoProfile
        return collector.collect(site, template, day)
      end

      input = settings(site, task)
      scope = case task
      when "M3"
        Digest::SHA256.hexdigest([site.host, input.fetch(:place_id)].to_json)
      when "M4"
        LocalServices.scope_digest(site, input)
      else
        Digest::SHA256.hexdigest(input.to_json)
      end
      metrics = { "kind" => KINDS.fetch(task), "host" => site.host, "period_on" => day.iso8601,
        "scope_digest" => scope, "state" => "collecting" }
      metrics["sandbox"] = ENV["LOCALSEODATA_API_KEY"].start_with?("sk_test_") if %w[M3 M4].include?(task)
      metrics.merge!("query" => input.fetch(:keyword), "market" => input.fetch(:location)) if task == "M4"
      return if %w[M2 M3].include?(task) && receipt(site, task, day)&.provider == DataForSeoCollection::PROVIDER

      snapshot = site.source_snapshots.create_or_find_by!(provider: PROVIDER, external_id: "#{task}-#{day}") do |record|
        record.assign_attributes(title: "#{template.name} · provider collection",
          observed_on: Time.current.in_time_zone(site.time_zone).to_date,
          scope: "Local SEO Data sample for #{site.host} and the reporting period ending #{day}.", metrics: metrics)
      end
      unless snapshot.previously_new_record?
        return :pending if snapshot.metrics["state"] == "collecting" && snapshot.updated_at > 10.minutes.ago

        return
      end

      request = task == "M4" ? input.slice(:keyword, :location) : input
      data = Client.new.collect(task, request)
      summary = case task
      when "M2" then Reviews.summarize(data, day: day, zone: site.time_zone, place_id: input.fetch(:place_id))
      when "M3" then BusinessProfile.summary(data, place_id: input.fetch(:place_id), site: site)
      when "M4" then LocalServices.summarize(data, input: input, site: site)
      when "E3" then Citations.summarize(data)
      end
      snapshot.update!(metrics: metrics.merge(summary).merge("state" => "captured"))
      nil
    rescue Client::Unavailable
      snapshot.update!(metrics: metrics.merge("state" => "unconfirmed"))
      nil
    end
  end
end
