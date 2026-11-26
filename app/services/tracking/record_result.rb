module Tracking
  class RecordResult
    class Error < ArgumentError; end

    def self.call(series:, captured_at:, items:, expected_day: nil, reference: nil, metadata: {})
      raise Error, "Capture is in the future" if captured_at > Time.current + 5.minutes
      captured_at = captured_at.round(6)
      day = series.date_in_zone(captured_at)
      raise Error, "Capture date does not match its scheduled day" if expected_day && expected_day != day
      raise Error, "Capture predates enrolment" if day < series.enrolled_on
      attributes = observation_attributes(series:, captured_at:, day:, items:)
      coverage = attributes.fetch(:coverage)
      status = attributes.fetch(:status)
      evidence = metadata.except(GooglePlacement::KEY).merge("method" => series.settings.fetch("method"), "reference" => reference,
        "series_fingerprint" => series.fingerprint).compact
      if series.source == "dataforseo"
        placement = GooglePlacement.read(items:, organic: attributes, depth: series.settings.fetch("depth"),
          profile: GooglePlacement.profile_for(series.site))
        evidence[GooglePlacement::KEY] = placement if placement
      end
      attributes[:evidence] = evidence

      series.with_lock do
        raise Error, "Series is paused or archived" if series.paused || series.archived_at
        slot = series.daily_slots.find_or_create_by!(day: day)
        previous = slot.rank_observation
        if previous
          same = attributes.except(:evidence).all? { |field, value| previous.public_send(field) == value }
          return previous if same
          raise Error, "This day already has a different observation" unless previous.status == "incomplete" && coverage > previous.coverage
        end
        observation = previous || slot.build_rank_observation
        observation.update!(attributes)
        slot.update!(status: status, reason: status == "incomplete" ? "Only #{coverage} consecutive organic positions were verified" : nil)
        if status != "incomplete"
          series.update!(baseline_observation: observation) unless series.baseline_observation_id
          ActionRules.call(observation)
        end
        observation
      end
    end

    def self.observation_attributes(series:, captured_at:, day:, items:)
      raise Error, "Expected an array of result items" unless items.is_a?(Array) && items.length <= 500

      limit = series.settings.fetch("depth")
      urls = {}
      items.each do |item|
        raise Error, "Invalid item" unless item.is_a?(Hash)
        next unless item["type"] == "organic"
        rank = Integer(item["rank_group"].to_s, 10, exception: false)
        raise Error, "Invalid organic position" unless rank&.positive?
        next if rank > limit
        url = ResultUrl.parse(item["url"])
        raise Error, "Invalid organic result URL" unless url && item["url"].bytesize <= 4096
        raise Error, "Duplicate organic position" if urls.key?(rank)
        urls[rank] = url
      end

      coverage = (1..limit).take_while { |rank| urls.key?(rank) }.size
      matching = (1..coverage).select { |rank| ResultUrl.host_matches?(series.settings.fetch("host"), urls.fetch(rank).host) }
      winner = matching.first
      preferred_url = series.keyword.preferred_page_on(day)
      preferred = matching.find { |rank| ResultUrl.same_page?(preferred_url, urls.fetch(rank).to_s) }
      status = winner ? "ranked" : (coverage == limit ? "outside" : "incomplete")
      {
        captured_at: captured_at, position: winner, preferred_position: preferred, preferred_url: preferred_url,
        winning_url: winner && urls.fetch(winner).to_s, coverage: coverage, status: status, source: series.source
      }
    end
  end
end
