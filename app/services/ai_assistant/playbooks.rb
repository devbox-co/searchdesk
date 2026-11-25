require "yaml"

module AiAssistant
  class Playbooks
    VERSION = "v1"
    Playbook = Data.define(:key, :title, :question, :sources, :next_step, :instruction) do
      def matches?(fact)
        return false unless sources.include?(fact["source"]) && fact["text"].present?

        case key
        when "priority" then !fact["text"].start_with?("No currently open")
        when "movement"
          # Older saved briefs carry the original reading text without a type flag.
          fact.fetch("measured_rank") { fact["text"].match?(/\((?:ranked at position \d+|verified outside the top \d+)\)/) }
        when "search_performance" then fact["text"].start_with?("Google web search, all countries and devices,")
        else true
        end
      end
    end

    CATALOGUE = YAML.safe_load_file(Rails.root.join("config", "assistant_playbooks", "#{VERSION}.yml")).map do |key, row|
      Playbook.new(key:, title: row.fetch("title"), question: row.fetch("question"), sources: row.fetch("sources").freeze,
        next_step: row.fetch("next_step"), instruction: row.fetch("instruction"))
    end.index_by(&:key).freeze

    def self.find(key)
      CATALOGUE[key]
    end

    def self.for_question(text)
      question = text.to_s.strip
      CATALOGUE.values.find { |playbook| playbook.question.casecmp?(question) }
    end

    def self.for_facts(facts)
      CATALOGUE.values.select { |playbook| facts.any? { |fact| playbook.matches?(fact) } }
    end

    def self.for_request(kind:, question:, facts:)
      return [] if kind == "test"
      available = for_facts(facts)
      selected = for_question(question) if kind == "question"
      selected ? available.intersection([selected]) : available
    end
  end
end
