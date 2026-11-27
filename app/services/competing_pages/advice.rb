module CompetingPages
  class Advice
    include Rails.application.routes.url_helpers
    include AiAssistant::EvidenceText

    VERSION = "competing-pages-v1"
    RESPONSE_FORMAT = "competing_page_decision_v2"
    PLAYBOOK = YAML.safe_load_file(Rails.root.join("config/assistant_playbooks/competing_pages_v1.yml")).freeze
    ACTIONS = PLAYBOOK.fetch("actions").freeze
    CHOICES = {"open" => "Leave the review open", "monitor" => "Monitor for now"}.freeze

    def self.digest(finding)
      Digest::SHA256.hexdigest(JSON.generate([VERSION, finding.id, finding.keyword_id, finding.level,
        canonical(finding.evidence)]))
    end

    def self.canonical(value)
      case value
      when Hash then value.sort.to_h.transform_values { |field| canonical(field) }
      when Array then value.map { |field| canonical(field) }
      else value
      end
    end
    private_class_method :canonical

    def self.build(finding:, setting:)
      new(finding, setting).build
    end

    def initialize(finding, setting)
      @finding, @setting = finding, setting
      @evidence = finding.evidence
      @site = finding.site
      @clicks = @evidence.fetch("clicks")
      @switches = @evidence.fetch("switch_count")
      @pages = @evidence.fetch("pages")
    end

    def build
      access = AiAssistant::EvidenceAccess.new(@site, @setting)
      grant = access.grant("gsc")
      unless @setting&.site_id == @site.id && @setting.enabled? && @setting.share_google? && grant &&
          @finding.active? && @finding.kind == "competing_pages" && @finding.keyword_id &&
          @evidence["property"] == @site.search_console_connection&.property &&
          @evidence["country"] == SearchConsole::DailyPositions.country_for(@site)
        raise ArgumentError, "Weekly search evidence is unavailable for AI advice."
      end
      access.record(sources: ["google"], grants: {"gsc" => grant}, keywords: [@finding.keyword_id], findings: [@finding.id])
      facts = [fact("F1", lead_summary, "cp-weeks"), fact("F2", click_summary, "cp-clicks")]
      before, after = @clicks.values_at("previous_impressions", "current_impressions")
      if before && after
        facts << fact("F3", "Google showed the site #{before} times in the first period and #{after} times in the second.", "cp-clicks")
      end
      if @pages.include?(@evidence["preferred_url"])
        facts << fact("F4", "The owner has already chosen one of these pages for this search.", "cp-pages")
      end
      # Store the receipt with the evidence so response validation uses the exact choices offered at dispatch.
      facts.first["eligible_decisions"] = eligible_decisions
      facts.first["few_clicks"] = @clicks["trend"] == "down" && @clicks["previous"].to_i < 10
      facts.first["scope"] = @evidence.slice("device", "country").merge("query" => clean(@evidence["query"]).gsub(/\bbearer\s+\S+/i, "[credential omitted]"),
        "previous_period" => @clicks.values_at("previous_start", "previous_end"),
        "current_period" => @clicks.values_at("current_start", "current_end"))
      {"schema" => AiAssistant::Evidence::SCHEMA, "site_id" => @site.id,
        "day" => @clicks.fetch("current_end"), "access" => access.metadata, "facts" => facts}
    end

    def self.request(facts)
      keys = facts.first.fetch("eligible_decisions")
      schema = {type: "object", additionalProperties: false, required: ["decision_key"],
        properties: {decision_key: {type: "string", enum: keys}}}
      context = {search: facts.first.fetch("scope"), facts: facts.map { |fact| fact.slice("id", "text", "source") },
        eligible_options: ACTIONS.slice(*keys)}
      [PLAYBOOK.fetch("instruction"), context, schema]
    end

    def self.render(selection, facts)
      return unless selection.is_a?(Hash) && selection.key?("decision_key") && (selection.keys - %w[decision_key fact_ids]).empty?
      key = selection["decision_key"]
      return unless facts.first&.fetch("eligible_decisions", [])&.include?(key) && (option = ACTIONS[key])

      available = facts.pluck("id")
      # An in-flight request from the previous format can still finish. Only server-owned
      # citations are rendered. Previously published answers already contain their citations.
      if selection.key?("fact_ids")
        legacy_ids = selection["fact_ids"]
        return unless legacy_ids.is_a?(Array) && legacy_ids.size.between?(1, 3) &&
          legacy_ids.uniq == legacy_ids && (legacy_ids - available).empty?
      end
      ids = case key
      when "inspect_listing", "check_listing_position" then %w[F1 F2 F3]
      when "check_preferred_page" then %w[F1 F4]
      when "compare_visibility" then available.include?("F3") ? %w[F1 F2 F3] : %w[F1 F2]
      when "monitor", "check_new_leader" then %w[F1 F2]
      else ["F1"]
      end
      return unless (ids - available).empty?

      reason = option.fetch("reason")
      if %w[check_new_leader monitor].include?(key) && facts.first["few_clicks"]
        reason = "Very few clicks separate the two periods. One small drop gives you little reason to edit the pages yet."
      end
      device = facts.first.dig("scope", "device")
      return unless %w[desktop mobile].include?(device)

      {"decision_key" => key, "owner_choice" => option.fetch("owner_choice"), "decision" => CHOICES.fetch(option.fetch("owner_choice")),
        "reason" => reason, "next_step" => option.fetch("next_step").gsub("%{device}", device), "revisit" => option.fetch("revisit"), "fact_ids" => ids}
    end

    def self.fallback(facts)
      key = facts.first&.dig("eligible_decisions")&.first
      return {} unless key
      render({"decision_key" => key}, facts) || {}
    end

    private

    def fact(id, text, anchor)
      {"id" => id, "text" => text, "source" => "Google Search Console", "url" => competing_page_path(@finding, anchor: anchor)}
    end

    def lead_summary
      return "These two addresses could point to the same page." if address_variants?
      return "The weekly readings are too thin to establish whether the pages trade places." if @finding.level == "limited"
      case @switches
      when 0 then "The two pages never traded the lead in consecutive weeks with a clear result."
      when 1 then "The clearest run of weeks showed a single change in the leading page."
      else "The two pages traded the lead #{@switches} times in a run of comparable weeks."
      end
    end

    def click_summary
      before, after = @clicks.values_at("previous", "current")
      return "Google reported too few weekly click totals to compare the two periods." unless before && after
      return "The site received #{before} #{'click'.pluralize(before)} in each four-week period for this search." if before == after
      "Clicks to the site #{after < before ? 'fell' : 'rose'} from #{before} to #{after} across the two four-week periods."
    end

    def address_variants?
      addresses = @pages.map { |url| Tracking::ResultUrl.parse(url) }
      addresses.size == 2 && addresses.all? && Tracking::ResultUrl.host_matches?(addresses.first.host, addresses.last.host) &&
        addresses.first.path.delete_suffix("/") == addresses.last.path.delete_suffix("/")
    end

    def eligible_decisions
      return %w[verify_addresses monitor] if address_variants?
      return %w[monitor] if @finding.level == "limited"
      if @finding.level == "review"
        options = ["compare_purposes"]
        options << "check_preferred_page" if @pages.include?(@evidence["preferred_url"])
        options << "monitor" unless @clicks["material_decline"]
        return options
      end
      return %w[check_new_leader monitor] if @switches == 1
      if @clicks["material_decline"]
        before, after = @clicks.values_at("previous_impressions", "current_impressions")
        return %w[inspect_listing check_listing_position] if before.to_i.positive? && after && after >= before
        return %w[compare_visibility monitor]
      end
      %w[monitor]
    end
  end
end
