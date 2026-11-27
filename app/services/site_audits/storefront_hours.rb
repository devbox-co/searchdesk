module SiteAudits
  module StorefrontHours
    DAYS = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].freeze
    SHORT_DAYS = DAYS.index_by { |day| day.first(2) }.freeze
    MAX_PERIODS = 28
    MAX_ROWS = MAX_PERIODS * DAYS.size
    TIME_PATTERN = /(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?/

    def self.parse_text(value)
      return unless value.is_a?(String) && value.bytesize <= 1024

      entries = value.split("|", -1).map(&:strip)
      return unless entries.size.between?(1, MAX_PERIODS)

      periods = entries.map do |entry|
        match = /\A([A-Za-z,\-]+)\s+(#{TIME_PATTERN})-(#{TIME_PATTERN})\z/.match(entry)
        return unless match

        days = match[1].split(",", -1).flat_map { |part| text_days(part) }
        return if days.empty? || days.include?(nil)

        { "dayOfWeek" => days, "opens" => match[2], "closes" => match[3] }
      end
      normalize(periods)
    end

    def self.normalize(periods)
      entries = Array.wrap(periods)
      return unless entries.size.between?(1, MAX_ROWS)

      weekly = entries.grep(Hash).reject { |item| item["validFrom"].present? || item["validThrough"].present? }
      return if weekly.empty? || entries.any? { |item| !item.is_a?(Hash) }

      rows = weekly.flat_map do |item|
        names = Array.wrap(item["dayOfWeek"]).map { |day| day.to_s.sub(%r{\Ahttps?://schema\.org/}, "") }
        opens, closes = %w[opens closes].map { |key| normalize_time(item[key]) }
        return if !opens || !closes || names.empty? || names.size > DAYS.size || (names - DAYS).any?
        return if opens == closes && opens != "00:00:00"

        # Google represents a closed day by omitting it or by using midnight for both values.
        opens == closes ? [] : names.map { |day| [day, opens, closes] }
      end
      rows.uniq.sort_by { |day, opens, closes| [DAYS.index(day), opens, closes] }
    end

    def self.specifications(rows)
      rows.group_by { |_, opens, closes| [opens, closes] }.map do |(opens, closes), days|
        { "@type" => "OpeningHoursSpecification", "dayOfWeek" => days.map(&:first), "opens" => opens, "closes" => closes }
      end.presence || DAYS.map do |day|
        { "@type" => "OpeningHoursSpecification", "dayOfWeek" => day, "opens" => "00:00:00", "closes" => "00:00:00" }
      end
    end

    def self.text_days(part)
      return [SHORT_DAYS[part]] unless part.include?("-")

      first, last, extra = part.split("-", -1)
      starts, ends = DAYS.index(SHORT_DAYS[first]), DAYS.index(SHORT_DAYS[last])
      return [nil] if extra || !starts || !ends

      starts <= ends ? DAYS[starts..ends] : DAYS.drop(starts) + DAYS.take(ends + 1)
    end

    def self.normalize_time(time)
      return unless time.is_a?(String) && time.match?(/\A#{TIME_PATTERN}\z/)

      time.length == 5 ? "#{time}:00" : time
    end

    private_class_method :text_days, :normalize_time
  end
end
