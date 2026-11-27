module SeoSkills
  class ActionGuide
    attr_reader :headline, :meaning, :steps, :winning_url, :preferred_url

    SOURCES = { "dataforseo" => "DataForSEO", "manual" => "Manual import", "demo" => "Simulated demo" }.freeze
    CHOICE_LABELS = {
      "keep_preferred" => "Keep the page I chose in Searchdesk",
      "prefer_ranking" => "Use the page Google showed"
    }.freeze

    def initialize(action:, draft:, historical:)
      @site = action.keyword.site
      @draft = draft
      @snapshot = draft&.input_snapshot.presence || ActionDraft.snapshot(action)
      @evidence = @snapshot.fetch("evidence", {})
      @kind = @snapshot["kind"]
      @phrase = @snapshot["phrase"].to_s.squish
      @device = @snapshot["device"].to_s.squish
      @source = @evidence["source"].presence || action.tracking_series.source
      @winning_url = site_url(@evidence["winning_url"])
      @preferred_url = site_url(@evidence["preferred_url"])
      @steps = []
      return unless supported?

      reassigned = @kind == "page_match" && preferred_url && !Tracking::ResultUrl.same_page?(preferred_url, action.keyword.preferred_url)
      if @source == "demo"
        limited_review("Try the review with the demo data",
          "This example uses simulated search results.",
          "Practise the decision", "Read the example and identify what you would check on a real site.",
          "Use a real reading for website work", "Open a keyword with a measured result when you are ready to review a live page.",
          "Explain how you would investigate this example. Use it as a demonstration only.")
      elsif action.status == "resolved"
        limited_review("This action has been reviewed",
          "These are the details of an earlier review.",
          "Check what happened next", "Look at the later complete results for this search on #{@device}.",
          "Reopen if needed", "If the issue still applies, find this action under Reviewed and choose Reopen.",
          "Summarise what the saved review found and whether later checks show it still applies. Share the evidence before proposing further work.")
      elsif historical || action.tracking_series.archived_at.present?
        limited_review("Check whether this still needs attention",
          "The saved result describes an earlier check for “#{@phrase}”.",
          "Find a recent result", "Open the keyword history and look for the latest complete check on the same device in the same location.",
          "Compare before acting", "If the issue persists, review the latest page and ranking together. If it has cleared, mark this action reviewed.",
          "Compare this saved observation with the latest complete result for the same search, location and device. Tell me whether the issue persists and what you recommend. Wait for my approval before changing the website.")
      elsif reassigned
        limited_review("Check the new page choice first",
          "This result used the preferred page saved at the time.",
          "Open the current keyword settings", "Look at the preferred page in the keyword history.",
          "Check a result after the change", "Compare the page in the next complete check with your current choice. If they match, mark the action reviewed.",
          "Check the current preferred-page setting and a complete result recorded after the setting changed. Tell me whether the old recommendation still applies before suggesting a website edit.")
      elsif @kind == "page_match"
        prepare_page_match
      else
        prepare_rank_drop
      end
      if reassigned
        note = "The preferred-page setting has changed since this check."
        @meaning += " #{note}"
        @request = "#{note} #{@request}"
      end
    end

    def supported?
      %w[page_match rank_drop].include?(@kind)
    end

    def choice_available?
      @choice_available == true
    end

    def saved_choice_label
      CHOICE_LABELS[@draft&.owner_choice]
    end

    def link_check_available?
      choice_available? && @draft.owner_choice != "prefer_ranking"
    end

    def saved_link_finding
      return unless @draft&.link_checked_at && @draft.link_check_result.present?
      @saved_link_finding ||= LinkCheckFinding.new(@draft.link_check_result, @draft.link_checked_at.in_time_zone(@site.time_zone))
    end

    def redirected_destination
      return unless link_check_available? && saved_link_finding
      final = site_url(@draft.link_check_result["final_target_url"])
      final unless final == preferred_url
    end

    def handoff
      return unless supported?
      if link_check_available? && (finding = saved_link_finding)
        return [
          "Link check for #{@site.name} · “#{@phrase}”",
          ("The owner chose to keep the preferred page." if @draft.owner_choice == "keep_preferred"),
          "Page Google showed — #{winning_url}\nChosen page in Searchdesk — #{preferred_url}",
          ("Final destination after redirect — #{redirected_destination}" if redirected_destination),
          "Searchdesk checked #{finding.checked_label}. #{finding.evidence}",
          ("Confirm which page best serves this search with the owner before acting." if @draft.owner_choice.blank?),
          finding.next_step
        ].compact.join("\n\n")
      end
      if choice_available? && @draft.owner_choice.present?
        return [
          "Task for #{@site.name} · “#{@phrase}”",
          @meaning,
          "Page Google showed — #{winning_url}\nChosen page in Searchdesk — #{preferred_url}",
          ("Note saved with this decision\n#{@draft.owner_choice_note}" if @draft.owner_choice_note.present?),
          @request
        ].compact.join("\n\n")
      end

      place = @snapshot["location"].to_s.split(",").map(&:strip).reject(&:blank?).join(", ")
      position = Integer(@evidence["position"], exception: false)
      lines = [
        "Please review “#{@phrase}” for #{@site.name} (#{@site.host}).",
        "", @request, "",
        "Saved #{@device} search check on #{@snapshot['observed_on']} · #{SOURCES.fetch(@source, 'Saved observation')}",
        ("Search checked from #{place}" if place.present?),
        (@kind == "page_match" ? "The action flagged a different page from the preferred page." : "The action flagged two daily rankings below the starting position."),
        ("Recorded Google organic position — #{position}" if position&.positive?),
        ("Page shown — #{winning_url}" if winning_url),
        ("Preferred page at the time — #{preferred_url}" if preferred_url)
      ]
      lines.compact.join("\n")
    end

    private

    def site_url(value)
      return unless value.is_a?(String) && !value.match?(/[\\[:cntrl:]]/)
      uri = Tracking::ResultUrl.parse(value)
      value if uri && uri.port == uri.default_port && Tracking::ResultUrl.host_matches?(@site.host, uri.host)
    end

    def limited_review(headline, meaning, heading, step, next_heading, next_step, request)
      @headline = headline
      @meaning = meaning
      @steps = [[heading, step], [next_heading, next_step]]
      @request = request
    end

    def prepare_page_match
      unless winning_url && preferred_url && !Tracking::ResultUrl.same_page?(winning_url, preferred_url)
        limited_review("Confirm the two pages for this search",
          "The saved details do not identify two different pages on your website.",
          "Check the search result", "Open the keyword history and find the page recorded for “#{@phrase}” on #{@device}.",
          "Check your preferred page", "Open Change preferred page on the keyword screen to see which address you want to track. Compare the two once you have both.",
          "Find the page recorded for this search and the page selected in Searchdesk. Return both addresses and explain which best answers the search before proposing a change.")
        return
      end

      @choice_available = @draft&.persisted?
      case @draft&.owner_choice
      when "keep_preferred"
        if saved_link_finding
          @headline = "Link check for “#{@phrase}”"
          @meaning = "The owner chose to keep the preferred page for this search."
          @steps = []
          return
        end
        @headline = "Check the link to your chosen page"
        @meaning = "The owner chose to keep the preferred page for “#{@phrase}”."
        @steps = [
          ["Check for an existing link", "Use the website link check above to find out how readers reach your preferred page."],
          ["Review the result", "Keep a useful link in place. If a change would help, share the instructions below with your developer or AI agent."]
        ]
        @request = [
          "In the main text of the page Google showed, check for a link to the chosen page. Follow it. If it already helps readers, send the exact linked words and their location. That completes the task.",
          "If readers would benefit from a new or clearer link, draft one change. Name the section and paragraph, show the current and proposed sentence, and identify the exact linked words and destination URL. If a link would add no value, explain why.",
          "Return any draft to the owner for approval before editing the website."
        ].join("\n\n")
        return
      when "prefer_ranking"
        @headline = "Use the page Google showed for future checks"
        @meaning = "The owner chose the page Google showed for “#{@phrase}” as the better fit."
        @steps = [
          ["Review the tracking address", "Open Review preferred page setting below. Choose Change preferred page and save the address labelled Page Google showed."],
          ["Confirm the change", "Open the keyword again and check the saved address. You can also send the instructions below to someone who manages Searchdesk for you."]
        ]
        @request = "In Searchdesk, open the keyword “#{@phrase}”, choose Change preferred page and save the address labelled Page Google showed. Reopen the keyword and confirm the saved URL to the owner. If you only have view access, send the owner the URL to save."
        return
      end

      @headline = "Choose where someone searching for “#{@phrase}” should land"
      @meaning = "Google showed a different page on your website from the one you chose in Searchdesk."
      if saved_link_finding
        @steps = [["Choose which page best answers the search", "Review both pages with the owner and use the link check above to decide the next step."]]
        return
      end
      @steps = [
        ["Open both pages", "Read the heading and first paragraph on each page. If someone searched for “#{@phrase}”, which page helps them do what they came for, such as get an answer, book or buy?"],
        ["If the page Google showed is the better fit", "Open the keyword in Searchdesk, choose Change preferred page and save that page’s address. Future checks will use your choice."],
        ["If your chosen page is the better fit", "Check whether the page Google showed already links to it. If a link would help readers, ask for a draft that shows exactly where it would go and what it would say."],
        ["Check the result", "After an approved edit, open the link as a visitor. Watch which page appears in the next complete #{@device} checks. Mark this action reviewed once you’ve made your decision."]
      ]
      @request = [
        "Compare the two pages and recommend which one should appear for this search. Give a reason from each page.",
        "If the page Google showed is the better fit, give me the address to save as the preferred page in Searchdesk.",
        "If the preferred page is the better fit, check for an existing link from the other page. If a link would help, send the exact link text, destination and placement for approval. If the existing link already does that job, say so.",
        "After any approved edit, check the link on the public page, record the date and compare the next complete rankings for the same search, location and device."
      ].join("\n\n")
    end

    def prepare_rank_drop
      unless @evidence.values_at("baseline_observation_id", "previous_observation_id", "observation_id").all?(&:present?)
        limited_review("Check the ranking history first",
          "This action flags a possible drop. Its saved details are missing part of the comparison.",
          "Find the starting position", "Open the keyword history for “#{@phrase}” on #{@device}.",
          "Compare the next readings", "Find the two checks that raised the action. If either is missing, wait for complete results before deciding on a page edit.",
          "Locate the original position and both daily checks in the history for this search, device and location. Return the positions, dates and pages you can confirm before recommending an edit.")
        return
      end

      @headline = "Check what changed for “#{@phrase}”"
      @meaning = "For two days in a row, this search ranked at least three places below where it started on #{@device}."
      @steps = [
        ["Look at the page that ranked", "Open the keyword history. Compare the page in the first complete check with the pages in the two lower results."],
        ["Choose what to investigate", "If a different page appeared, compare which page answers the search better. If the same page appeared, check whether its content or links changed around that time."],
        ["Decide whether an edit would help", "Ask for one specific improvement backed by what you found. If there is no clear problem on the page, watch the next complete checks."],
        ["Follow up", "After any approved edit, open the page as a visitor, record the edit date and compare later #{@device} results for this search in the same location."]
      ]
      @request = "Compare the starting check with the two lower daily checks. Report the dates, positions and page that appeared each time. " \
        "Review the page and any recent edits for a specific issue that could affect this search. Return one proposed change with the exact page and wording or explain why monitoring makes more sense. " \
        "Send your recommendation for approval before editing. After any approved change, verify it on the public page and compare the next complete checks for the same search, location and device."
    end
  end
end
