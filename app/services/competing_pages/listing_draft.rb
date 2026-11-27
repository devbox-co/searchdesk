module CompetingPages
  class ListingDraft
    UK_MEDICINE = /\b(?:botox|botulinum toxin|anti[-\s]wrinkle injections?)\b/i
    ASA_GUIDANCE = "https://www.asa.org.uk/advice-online/beauty-and-cosmetics-botulinum-toxin-products.html"
    PROMOTIONAL = /\b(?:premier|world[- ]class|best[- ]in[- ]class|guaranteed|unrivalled|unrivaled|number one)\b/i

    BOILERPLATE = /\b(?:cookies?|privacy policy|terms (?:and|of)|careers?|job vacancy|subscribe|limited time|discount|testimonials?|newsletter)\b/i

    def initialize(site:, page:, target:, google:)
      @site, @page, @target, @google = site, page, target, google
      @uk = site.rank_country_code == "GB"
    end

    def call
      return unavailable("Read the public page successfully before giving the developer new wording.") unless @page["status"] == "observed"
      if %w[title description].any? { |field| %w[multiple too_long].include?(@page.dig("field_states", field)) }
        return unavailable("Ask your developer to check the title and description tags in the page source. Searchdesk could not identify one reliable value for each.")
      end
      title, description = @page.values_at("title", "description")
      restricted = @uk && [description, title].any? { |text| UK_MEDICINE.match?(text.to_s) }
      next_title = title
      if title.blank? || unsafe_wording?(title)
        heading = @page["h1"]
        return unavailable("Ask your developer for a factual title based on the main heading and the business name.") if heading.blank? || unsafe_wording?(heading)
        next_title = heading.include?(@site.name) || unsafe_wording?(@site.name) ? heading : "#{heading} | #{@site.name}"
      end
      next_description = description
      if description.blank? || unsafe_wording?(description)
        next_description = suggested_excerpt
        return unavailable("Ask the page owner for one factual sentence describing what a visitor can do on this page.") unless next_description
      end
      changed = next_title != title || next_description != description
      reason = if restricted
        "The current wording names or refers to a prescription-only treatment. Use a factual description from the page and have the clinic approve it."
      elsif changed
        "Use concrete details already on the page so a visitor can tell what to expect."
      else
        "The page already describes its subject. This check gives no clear reason to rewrite its title or description."
      end
      result = {"status" => changed ? "proposed" : "keep", "title" => next_title, "description" => next_description, "reason" => reason}
      result["guidance_url"] = ASA_GUIDANCE if restricted
      lines = ["Page: #{@target}", reason]
      if @google["status"] == "target_not_seen"
        lines << "This page was absent from the saved local search sample. Its Google title and snippet could not be compared."
      elsif @google["status"] == "unavailable"
        lines << "Google’s displayed wording could not be verified for this check. The suggestion uses the public page."
      end
      lines << "#{title == next_title ? 'Keep' : 'Set'} the page title exactly as follows:\n#{next_title}"
      lines << "#{description == next_description ? 'Keep' : 'Set'} the meta description exactly as follows:\n#{next_description}"
      if changed
        lines << "After owner approval, update the specified metadata in the website editor. Verify the public page has one title and one meta description with the agreed text."
      end
      if restricted
        lines << "Review this wording against UK advertising guidance: #{ASA_GUIDANCE}"
        if UK_MEDICINE.match?(@page["h1"].to_s)
          lines << "The main heading also refers to the treatment. Flag it for a separate clinic review. Google can draw wording from the visible page as well."
        end
      end
      lines << "Review the next saved #{@google['device'].presence || 'Google'} result for this same page and search. Google may choose different wording."
      result.merge("instructions" => lines.join("\n\n"))
    end

    private

    def unsafe_wording?(text)
      PROMOTIONAL.match?(text) || (@uk && UK_MEDICINE.match?(text))
    end

    # Reuse a complete, factual passage already published by the business.
    def suggested_excerpt
      city = @site.location.to_s.split(",").first.to_s.strip
      topic = [@page["title"], @page["h1"], @site.name].compact.join(" ").downcase.scan(/[[:alpha:]]{3,}/).uniq
      topic -= city.downcase.scan(/[[:alpha:]]+/) + %w[and the for with from page home website your our welcome]
      options = Array(@page["excerpts"]).select do |text|
        text.is_a?(String) && text.length.between?(50, 180) && text.end_with?(".") && !unsafe_wording?(text) &&
          !BOILERPLATE.match?(text) && (topic & text.downcase.scan(/[[:alpha:]]{3,}/)).any?
      end
      options.max_by do |text|
        [city.present? && text.downcase.include?(city.downcase) ? 1 : 0, text.downcase.include?(@site.name.downcase) ? 1 : 0]
      end
    end

    def unavailable(reason)
      {"status" => "unavailable", "reason" => reason, "instructions" => "Page: #{@target}\n\n#{reason}"}
    end
  end
end
