module AiAssistant
  class Evidence
    include Rails.application.routes.url_helpers
    include ActionView::Helpers::TextHelper
    include ActionView::RecordIdentifier
    include EvidenceSources
    include EvidenceText

    SCHEMA = 1
    SOURCES = {"manual" => "Manual import", "demo" => "Simulated demonstration", "dataforseo" => "DataForSEO"}.freeze
    TOPICS = {
      google_search: /\bgsc\b|search console|impressions?|clicks? from search/,
      weekly_clicks: /(?=.*\b(?:week|weekly|weeks|7[ -]days?)\b)(?=.*\bclicks?\b)/,
      traffic: /\bga4\b|analytics|traffic|sessions?|visits?|enquir|leads?|conversions?/,
      maps: /maps?|local pack|falcon|grid|business profile|\bgbp\b/,
      campaign: /semrush|campaign position/,
      actions: /action|task|prioriti[sz]e|check first|do (first|next)|next step|work on|page match|wrong page/,
      profile: /business|goals?|services?|priorit|target market|about (us|the site)/,
      rankings: /rank|keyword|position|winning page|which page|tracking|baseline|changed|movement/
    }.freeze
    MAX_FACTS = 26

    def self.build(site:, setting:, question:, day:, kind:, parent: nil)
      raise ArgumentError, "Site settings do not belong to this site" unless site.persisted? && setting&.site_id == site.id
      new(Site.find(site.id), setting, question, day.to_date, kind, parent).build
    end

    def self.visible?(site:, setting:, evidence:)
      EvidenceAccess.visible?(site:, setting:, evidence:)
    end

    def initialize(site, setting, question, day, kind, parent)
      @site, @setting, @day = site, setting, day
      @brief = kind.to_s == "brief"
      @question = question.to_s.first(2_000).downcase
      @playbook = Playbooks.for_question(@question)
      unless @brief
        if @question.match?(/\byesterday\b/)
          @day -= 1
        elsif (stamp = @question[/\bon (\d{4}-\d{2}-\d{2})\b/, 1])
          date = Date.iso8601(stamp) rescue nil
          @day = date if date && date <= @day
        end
      end
      @parent_question = parent.question.to_s.first(2_000).downcase if parent && parent.site_id == site.id &&
        !parent.erased_at && self.class.visible?(site:, setting:, evidence: parent.evidence)
      @facts = []
      @access = EvidenceAccess.new(site, setting)
    end

    def build
      keywords = @site.keywords.order(priority: :desc, phrase: :asc).to_a
      @terms = matching_terms(keywords, @question)
      @terms = matching_terms(keywords, @parent_question) if @terms.empty? && @parent_question.present? && follow_up?
      @topics = TOPICS.filter_map { |topic, pattern| topic if @question.match?(pattern) }
      @topics |= TOPICS.filter_map { |topic, pattern| topic if @parent_question.match?(pattern) } if @parent_question && follow_up?
      @topics << :weekly_clicks if @playbook&.key.to_s == "weekly_clicks"
      if (@topics & [:maps, :campaign, :traffic]).any? && !@topics.include?(:google_search)
        @topics.delete(:weekly_clicks)
      end
      @topics |= [:traffic, :google_search, :maps] if @question.match?(/finding us|visibility|more people/)
      if @question.include?(@site.name.downcase) && @question.match?(/tell me about|what.*know|what.*do|overview/)
        @topics |= [:profile, :rankings]
      end
      @topics << :rankings if @topics.empty? || (@terms.any? && (@topics - [:profile]).empty?)

      if (@topics & [:google_search, :weekly_clicks, :campaign, :maps]).any? && !@question.match?(/dataforseo|local organic|manual import|all sources/)
        @topics.delete(:rankings)
      end

      read_rankings if @brief || (@topics & [:rankings, :actions]).any?
      read_actions if @brief || @topics.include?(:actions)
      read_profile if @brief || @topics.include?(:profile) || @topics.include?(:actions)
      read_weekly_clicks if @brief || @topics.include?(:weekly_clicks)
      read_google_search if @brief || (@topics.include?(:google_search) && !@topics.include?(:weekly_clicks))
      read_traffic if @brief || @topics.include?(:traffic)
      read_maps if @brief || @topics.include?(:maps)
      read_campaign if @brief || @topics.include?(:campaign)
      @facts.select! { |fact, _references| @playbook.matches?(fact) } if @playbook && !@brief
      facts = select_facts
      {"schema" => SCHEMA, "site_id" => @site.id, "day" => @day.iso8601, "facts" => facts, "access" => @access.metadata}
    end

    private

    def follow_up?
      !@playbook && @question.match?(/\b(it|that|those|this|they|them|there|instead|also|why)\b|what about|how about/)
    end

    def matching_terms(keywords, question)
      return [] if Playbooks.for_question(question)
      words = " #{question.to_s.gsub(/[^\p{L}\p{N}]+/, ' ').squish} "
      exact = keywords.select { |kw| words.include?(" #{kw.phrase.downcase.gsub(/[^\p{L}\p{N}]+/, ' ').squish} ") }.map(&:phrase)
      return exact if exact.any?
      # A shortened service name such as "boiler" may be shared by several
      # local terms. Only expand on words actually present in the watchlist.
      stop = %w[where what when which near best today this that about your service services company ranking rank rankings how with from have local]
      stop += @site.location.downcase.scan(/[\p{L}\p{N}]+/)
      tokens = words.split.uniq.select { |word| word.length > 2 } - stop
      return [] if tokens.empty?
      matches = keywords.map do |kw|
        overlap = kw.phrase.downcase.scan(/[\p{L}\p{N}]+/).uniq & tokens
        [kw.phrase, overlap.length]
      end
      best = matches.map(&:last).max.to_i
      best.positive? ? matches.select { |_phrase, score| score == best }.map(&:first) : []
    end

    def for_terms(rows)
      return rows if @terms.empty?
      rows.select { |row| @terms.any? { |term| term.casecmp?(yield(row).to_s) } }
    end

    def fact(text, source, url, measured_rank: nil, **references)
      item = {"text" => text.squish.first(780), "source" => source, "url" => url}
      item["measured_rank"] = measured_rank unless measured_rank.nil?
      @facts << [item, references]
    end

    def select_facts
      # Reserve one citation per source before filling the remaining slots in reading order.
      indices = (0...@facts.size).to_a
      first_by_source = indices.uniq { |index| @facts[index].first.fetch("source") }
      (first_by_source | indices).first(MAX_FACTS).sort.map.with_index(1) do |index, number|
        fact, references = @facts[index]
        @access.record(**references)
        fact.merge("id" => "F#{number}")
      end
    end

    def read_profile
      text = "#{clean(@site.name)} tracks #{@site.host} in #{clean(@site.location)}. The search language is #{@site.language}."
      fact(text, "Project settings", rankings_path(source: "local", day: @day))
      fields = {services: "Services", priorities: "Business priorities", enquiry_definition: "Definition of a useful enquiry"}
      fields.each do |key, label|
        next if @setting.public_send(key).blank?
        fact("#{label} from the owner’s brief — #{clean(@setting.public_send(key))}.", "Owner's project brief", assistant_settings_path, profile: key)
      end
    end

    def read_rankings
      device = %w[desktop mobile].select { |d| @question.match?(/\b#{d}\b/) }
      @rank_rows = Tracking::Dashboard.rows(site: @site, date: @day, device: device.one? ? device.first : "all")
      @rank_rows = for_terms(@rank_rows) { |row| row[:keyword].phrase }
      groups = @rank_rows.group_by { |row| [row[:series].source, row[:series].settings["location"], row[:series].settings["depth"]] }
      groups.each do |(source, location, depth), rows|
        states = rows.map { |r| r[:status] }.tally
        others = states.except("ranked", "outside", "incomplete")
        changes = rows.map { |r| r[:transition] }.tally
        compared = changes.except(:baseline, :unavailable)
        movement = compared.any? ? compared.map { |k, n| "#{n} #{k.to_s.humanize.downcase.tr('_', ' ')}" }.join(", ") :
          "Movement needs observations on two comparable dates"
        devices = rows.map { |r| r[:series].device }.uniq.sort.join(" and ")
        text = "On #{@day} in #{clean(location)}, Google organic tracking on #{devices} covered #{pluralize(rows.size, "keyword-device check")} across #{pluralize(rows.uniq { |r| r[:keyword].id }.size, "keyword")}. " \
          "#{states.fetch('ranked', 0)} numeric positions, #{states.fetch('outside', 0)} verified outside the top #{depth}, #{states.fetch('incomplete', 0)} incomplete. " \
          "#{others.map { |status, n| "#{n} #{status.humanize.downcase}. " }.join}#{rows.count { |r| r[:baseline] }} usable baselines. #{movement.capitalize}."
        incomplete = rows.select { |r| r[:status] == "incomplete" }.filter_map { |r| r[:observation]&.coverage }.minmax
        if incomplete.first
          depth_label = incomplete.first == incomplete.last ? incomplete.first : incomplete.join("–")
          text << " Incomplete checks reached #{depth_label} of the first #{depth} positions."
        end
        fact(text, SOURCES.fetch(source), rankings_path(source: "local", day: @day, device: rows.first[:series].device),
          measured_rank: states.key?("ranked") || states.key?("outside"),
          keywords: rows.map { |r| r[:keyword].id }, observations: rows.flat_map { |r| [r[:observation]&.id, r[:baseline]&.id] }.compact)
      end
      if groups.empty?
        fact("No local organic tracking series found in the selected scope for #{@day}.", "Rankings", rankings_path(source: "local", day: @day))
      end
      sorted = @rank_rows.sort_by do |r|
        order = case @question
        when /best.rank|highest.rank|top.rank|ranks? best/ then r[:rank] || Float::INFINITY
        when /worst.rank|lowest.rank/ then r[:rank] ? -r[:rank] : Float::INFINITY
        when /gains?|improv/ then r[:change] ? -r[:change] : Float::INFINITY
        when /declin|drop|lost|fallen/ then r[:change] || Float::INFINITY
        else -r[:change].to_i.abs
        end
        [order, r[:actions].empty? ? 1 : 0, -r[:keyword].priority, r[:keyword].phrase, r[:series].device]
      end
      sorted.first(@brief || @topics.include?(:actions) ? 4 : 10).each { |r| read_rank(r) }
    end

    def read_rank(row)
      term, series, observation, baseline = row.values_at(:keyword, :series, :observation, :baseline)
      reading = case row[:status]
      when "ranked" then "ranked at position #{row[:rank]}"
      when "outside" then "verified outside the top #{observation.coverage}"
      when "incomplete" then "incomplete coverage through #{observation.coverage}, without an exact rank"
      else "#{row[:status].humanize.downcase}, with no reading"
      end
      start = if baseline
        value = baseline.position ? "position #{baseline.position}" : "outside the top #{baseline.coverage}"
        "The baseline on #{baseline.day} was #{value}."
      else
        "No usable baseline."
      end
      parts = ["“#{clean(term.phrase)}” had a #{series.device} Google organic check in #{clean(series.settings['location'])} on #{@day} (#{reading}).", start]
      if (change = row[:change])
        parts << case change <=> 0
        when 1 then "Up #{pluralize(change, 'place')} since baseline."
        when -1 then "Down #{pluralize(change.abs, 'place')} since baseline."
        else "Unchanged since baseline."
        end
      end
      parts << "Latest comparable reading was #{row[:as_of]}." if row[:as_of] && row[:as_of] < @day
      winner = public_path(row[:winning_url])
      preferred = public_path(observation&.preferred_url || term.preferred_page_on(@day))
      parts << "Winning page #{winner}." if winner
      parts << "Preferred page #{preferred}." if preferred
      fact(parts.join(" "), SOURCES.fetch(series.source), rankings_path(source: "local", day: @day, device: series.device, anchor: dom_id(series)),
        measured_rank: %w[ranked outside].include?(row[:status]),
        keywords: [term.id], observations: [observation&.id, baseline&.id].compact)
    end

    def read_actions
      rows = Array(@rank_rows).flat_map { |row| row[:actions].map { |action| [action, row] } }
      rows.group_by { |action, _row| action.kind }.each do |kind, pairs|
        next unless %w[page_match rank_drop].include?(kind)
        grouped = pairs.group_by { |_action, row| row[:keyword] }
        label = kind == "page_match" ? "preferred-page checks" : "checks for sustained rank drops"
        source = "Keyword actions"
        fact("#{pairs.size} currently open device readings for #{pluralize(grouped.size, "distinct keyword")} have #{label}, observed by #{@day}.",
          source, actions_path, actions: pairs.map { |action, _row| action.id })
        grouped.first(3).each do |keyword, readings|
          scopes = readings.map { |action, row| "#{row[:series].device} on #{action.observed_on}" }.join(", ")
          suggested = kind == "page_match" ? "Check that the observed page answers the search before changing the preferred page." :
            "Review comparable daily observations and the affected page."
          action_url = actions_path(keyword_id: keyword.id, anchor: dom_id(readings.first.first))
          fact("“#{clean(keyword.phrase)}” has #{label} on #{scopes}. #{suggested}", source, action_url,
            actions: readings.map { |action, _row| action.id })
        end
      end
      if rows.empty?
        fact("No currently open keyword actions with a reading through #{@day} in the selected keyword and device scope.", "Keyword actions", actions_path)
      end
      @site.project_tasks.with_current_status(ProjectTask::ACTIONABLE_STATES).by_priority.limit(3).each do |task|
        fact("“#{clean(task.title)}” is a #{clean(task.priority.downcase)} priority project task. Its current status is #{clean(task.effective_status.humanize.downcase)}.",
          "Project tasks", project_task_path(task), tasks: [task.id])
      end
    end
  end
end
