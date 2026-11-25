module AiAssistant
  # Both new and previously published briefs retain the evidence the model selected.
  # Present that snapshot in plain language without fetching today's measurements.
  class OwnerBrief
    Reading = Data.define(:headline, :meaning, :action, :action_fact, :facts, :priority, :original_text)

    attr_reader :readings

    def initialize(run)
      facts = Array(run.evidence["facts"]).index_by { |fact| fact["id"] }
      @readings = Array(run.answer["findings"]).filter_map do |finding|
        cited = Array(finding["fact_ids"]).uniq.filter_map { |id| facts[id] }
        original = finding["text"].to_s
        if (comparison = BriefSourceReading.comparison(cited))
          Reading.new(**comparison, facts: cited, original_text: original)
        elsif (selected = cited.filter_map { |fact| self.class.for_fact(fact) }.min_by(&:priority))
          selected.with(facts: cited, original_text: original)
        elsif original.present? || cited.any?
          legacy_reading(original, cited)
        end
      end
    end

    def lead
      readings.first
    end

    def first_action
      readings.select { |reading| reading.action.present? }.min_by(&:priority)
    end

    def self.for_fact(fact)
      summary = BriefRankingReading.for(fact) || BriefSourceReading.for(fact)
      return unless summary

      Reading.new(**summary, action_fact: fact, facts: [fact], original_text: fact["text"])
    end

    private

    def legacy_reading(original, cited)
      short = original.squish
      simple = short.present? && short.size <= 135 && !short.match?(%r{\d{4}-\d\d-\d\d|https?://|/\S+/})
      title = cited.first&.fetch("source", nil).presence || "Saved finding"
      meaning = simple ? short : "Open the saved details for this finding."
      Reading.new(headline: title, meaning: meaning, action: nil, action_fact: nil, facts: cited,
        priority: 100, original_text: original)
    end
  end
end
