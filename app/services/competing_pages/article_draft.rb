module CompetingPages
  class ArticleDraft
    def self.call(**options)
      new(**options).call
    end

    def initialize(site:, page:, google:, link:, homepage:)
      @site, @page, @google, @link, @homepage = site, page, google, link, homepage
    end

    def call
      case @page["status"]
      when "redirected" then moved_page
      when "observed" then readable_page
      else
        report("review", "Check the article address first.",
          @page["reason"].presence || "Searchdesk could not read a public article at the captured address.",
          "Check that the address opens the intended page before placing a link.")
      end
    end

    private

    def moved_page
      hops = Array(@page["redirects"])
      destination = @page["destination"] || {}
      verified = destination["status"] == "observed" && destination["http_status"] == 200
      direct = hops.one? && [301, 308].include?(hops.first["status"]) &&
        Tracking::ResultUrl.same_page?(hops.first["location"], destination["url"])
      canonical = Tracking::ResultUrl.same_page?(destination["canonical"], destination["url"])
      routes = hops.map { |hop| "#{hop['url']} → HTTP #{hop['status']} → #{hop['location']}" }
      link_note = "The captured address forwards visitors before an article opens. There is no article body in which to place a homepage link."
      unless direct && verified && canonical && !Tracking::ResultUrl.same_page?(destination["url"], @homepage) && related_destination?(destination)
        reason = "The article address redirects. Confirm the intended destination, redirect type and final page before requesting a website edit."
        return report("review", "Review the redirect with your developer.", reason, link_note,
          notes: routes + ["Open the original address and verify the final page and its canonical URL."])
      end

      edits = optional_destination_edit(destination)
      reason = "The address permanently sends visitors to a working page on the same topic. The destination names itself as the canonical URL."
      notes = routes + ["Verify that #{destination['url']} returns HTTP 200 and declares that exact URL as its canonical.",
        "Keep the existing redirect. The saved result describes the old address. Check which URL appears in the next saved search."]
      if edits.any?
        notes << "The optional wording applies only to #{destination['url']}. Have the clinic approve it before publication."
      end
      report("keep", "Keep the redirect to the existing destination.", reason, link_note,
        edits: edits, notes: notes, guidance: edits.any?)
    end

    # Shared subject vocabulary, beyond the business and town, supports keeping a
    # redirect. A working redirect by itself does not establish editorial intent.
    def related_destination?(destination)
      words = ->(text) { text.to_s.downcase.scan(/[[:alpha:]]{4,}/).uniq }
      generic = words.call([@site.name, @site.location, "with from about guide blog article page home what when does treatment treatments service services"].join(" "))
      source = words.call(@google["title"])
      target = words.call([destination["title"], destination["h1"]].join(" "))
      ((source & target) - generic).any?
    end

    def optional_destination_edit(destination)
      return [] unless @site.rank_country_code == "GB" && @site.language.to_s.start_with?("en")
      before = destination["description"].to_s
      lead, rest = before.split(/\?\s+/, 2)
      return [] unless rest&.end_with?(".") && ListingDraft::UK_MEDICINE.match?(lead) && !ListingDraft::UK_MEDICINE.match?(rest)
      return [] unless rest.match?(/\bconsultation\b/i) && !ListingDraft::PROMOTIONAL.match?(rest)
      body = Array(destination["headings"]) + Array(destination["paragraphs"]) + Array(destination["excerpts"])
      return [] unless body.any? { |text| text.match?(/\bconsultation\b/i) }

      [{"label" => "Optional destination meta description", "before" => before, "after" => rest}]
    end

    def readable_page
      base = ListingDraft.new(site: @site, page: @page.merge("excerpts" => @page["paragraphs"]),
        target: @page["url"], google: @google).call
      edits = %w[title description].filter_map do |field|
        replacement = base[field]
        next if replacement.blank? || @page[field] == replacement
        {"label" => field == "title" ? "Article page title" : "Article meta description",
          "before" => @page[field], "after" => replacement}
      end
      link_note, add_link = homepage_link
      if edits.any?
        report("proposed", "Improve the article wording first.", base.fetch("reason"), link_note,
          edits: edits, guidance: base["guidance_url"].present?)
      elsif add_link
        report("proposed", "Add one homepage link in the article.", "The article names the business where a reader could use a link to learn more.", link_note)
      elsif base["status"] == "unavailable"
        report("review", "Review the article wording.", base.fetch("reason"), link_note)
      else
        report("keep", "Keep the article wording for now.", "A single search capture gives no reason on its own to rewrite the article.", link_note)
      end
    end

    def homepage_link
      case @link["outcome"]
      when "contextual"
        ["Keep the existing article link “#{@link['anchor']}” to #{@homepage}.", false]
      when "missing", "navigation_only"
        intro = @link["outcome"] == "navigation_only" ? "The verified homepage link is outside the article text. " : ""
        paragraph = placement_paragraph
        if paragraph && @site.language.to_s.start_with?("en")
          anchor = "About #{@site.name}"
          ["#{intro}After the paragraph “#{paragraph}”, add a link labelled “#{anchor}” to #{@homepage}.", true]
        else
          ["#{intro}A useful place in the article for a homepage link could not be identified. Leave the article links as they are.", false]
        end
      when "broken_target"
        ["Check the homepage address. The requested homepage returned an error.", false]
      else
        ["Searchdesk could not verify the homepage link. Check the article in the website editor before adding one.", false]
      end
    end

    def placement_paragraph
      return if @site.name.blank?
      paras = Array(@page["paragraphs"])
      brand = /(?<![[:alnum:]])#{Regexp.escape(@site.name)}(?![[:alnum:]])/i
      paras.find { |p| p.length.between?(30, 300) && p.match?(brand) && !ListingDraft::BOILERPLATE.match?(p) && paras.count(p) == 1 }
    end

    def report(status, decision, reason, link_instruction, edits: [], notes: [], guidance: false)
      scope = [@google["keyword"], @google["device"], @google["location"], @google["captured_at"]].compact_blank.join(" · ")
      search = "Saved Google result: #{scope} (position #{@google['position']})" if scope.present? && @google["position"]
      instructions = [search, "Captured URL: #{@google['url']}", decision, reason, link_instruction, *notes].compact
      edits.each do |edit|
        instructions << "#{edit['label']}\nCurrent: #{edit['before'].presence || '(missing)'}\nProposed: #{edit['after']}"
      end
      if guidance
        instructions << "Review the wording against UK advertising guidance before publishing: #{ListingDraft::ASA_GUIDANCE}"
      end
      if status == "proposed" || edits.any?
        instructions << "After approval, check the agreed wording and any link on the published page. Recheck the same keyword and device in the next saved result."
      end
      {"status" => status, "decision" => decision, "reason" => reason, "link_instruction" => link_instruction,
        "edits" => edits, "instructions" => instructions.join("\n\n")}.tap do |draft|
        draft["guidance_url"] = ListingDraft::ASA_GUIDANCE if guidance
      end
    end
  end
end
