module SeoSkills
  class LinkCheckFinding
    attr_reader :outcome, :checked_at

    HEADINGS = {
      "contextual" => "Keep the existing link",
      "navigation_only" => "Consider a link in the main text",
      "missing" => "Review one possible link",
      "broken_target" => "Fix the destination first",
      "unverifiable" => "Unable to verify the link"
    }.freeze

    def initialize(result, checked_at)
      @result = result
      @checked_at = checked_at
      @outcome = HEADINGS.key?(result["outcome"]) ? result["outcome"] : "unverifiable"
    end

    def heading
      HEADINGS.fetch(outcome)
    end

    def evidence
      case outcome
      when "contextual"
        location = @result["section"].presence
        location = location ? "under “#{location}”" : "in the main text"
        "#{link_label} #{location} opens the chosen page."
      when "navigation_only"
        "#{link_label} in #{navigation_area} opens the chosen page. Searchdesk found no matching link in the main text it could read."
      when "missing"
        "The chosen page opens. Searchdesk found no link to it in the public HTML it could read on the ranking page."
      when "broken_target"
        status = @result["target_status"].presence
        status ? "The chosen page returned HTTP #{status}." : "The chosen page could not be opened."
      else
        @result["reason"].presence || "Searchdesk could not confirm the link from the public pages."
      end
    end

    def next_step
      case outcome
      when "contextual"
        "Leave this link in place. You can mark the action reviewed."
      when "navigation_only", "missing"
        "If a link in the main text would help a reader, ask for one draft with the section, current sentence, proposed linked words and destination. Send it to the owner for approval."
      when "broken_target"
        "Confirm the intended destination with the owner and restore it or choose a working replacement. Run the link check again after the fix."
      else
        "Open both pages as a visitor and follow the link if you see one. Record what opens before proposing an edit."
      end
    end

    def checked_label
      checked_at.strftime("%-d %b %Y at %H:%M %Z")
    end

    private

    def link_label
      anchor = @result["anchor"].presence
      anchor ? "The link “#{anchor}”" : "The link"
    end

    def navigation_area
      { "Header" => "the header", "Footer" => "the footer", "Sidebar" => "the sidebar" }.fetch(@result["placement"], "the navigation")
    end
  end
end
