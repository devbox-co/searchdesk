module SeoWorkflows
  class LandingPageDrafts
    def initialize(brief, crawl_path, host:)
      @brief = brief
      @host = host
      @crawl_path = crawl_path
      @pages = brief.metrics.fetch("records").index_by { |record| record.fetch("page") }
    end

    def for_page(page)
      brief = @pages[page["path"]]
      return [] unless brief && page["html"] == true && !Array(page["issues"]).include?("noindex")

      drafts = []
      if brief["heading"] && page["h1_count"] == 0
        drafts << draft(page, "Main heading draft", brief.fetch("heading"))
      end
      if brief["paragraph"] && page["main_word_count"].is_a?(Integer) && page["main_word_count"] < 500
        drafts << draft(page, "Local paragraph draft", brief.fetch("paragraph"))
      end
      if brief["storefront"]
        if page["structured_markup_present"] == false
          drafts << draft(page, "LocalBusiness JSON-LD draft", JSON.pretty_generate(brief.fetch("storefront")))
        elsif page["local_business_fingerprint"].is_a?(Hash)
          drafts << compare_business(page, brief.fetch("storefront"))
        else
          drafts << evidence("Storefront schema check", "#{page.fetch('path')} · Confirm the existing structured markup before making changes.")
        end
      end
      drafts
    end

    private

    def compare_business(page, storefront)
      markup = SiteAudits::LocalBusinessMarkup
      expected = markup.fingerprint(storefront, @host)
      expected.delete("businessType") if storefront["@type"] == "LocalBusiness"
      observed = page.fetch("local_business_fingerprint")
      new_fields = expected.keys & markup::EXTENDED_FIELDS
      older = page["local_business_evidence_version"].to_i < markup::EVIDENCE_VERSION
      unavailable = older ? new_fields : []
      checked = expected.except(*unavailable)
      missing = checked.keys - observed.keys
      unreadable = checked.keys.select { |field| observed.key?(field) && observed[field].nil? }
      mismatches = (checked.keys - missing - unreadable).reject do |field|
        if field == "businessType"
          (checked.fetch(field) - Array(observed.fetch(field))).empty?
        else
          checked.fetch(field) == observed.fetch(field)
        end
      end
      message = "#{page.fetch('path')} · "
      if mismatches.empty? && missing.empty? && unreadable.empty?
        message += unavailable.any? ? "The fields checked match the owner’s brief. " :
          "The supported fields in the owner’s brief match the observed entity. "
      end
      message += "Review mismatched fields: #{labels(mismatches)}. " if mismatches.any?
      message += "Fields missing from the observed entity: #{labels(missing)}. " if missing.any?
      message += "Markup could not be compared for: #{labels(unreadable)}. " if unreadable.any?
      message += "Run a fresh crawl to compare: #{labels(unavailable)}." if unavailable.any?
      evidence("Storefront schema check", message.strip)
    end

    def labels(fields)
      fields.map { |field| SiteAudits::LocalBusinessMarkup::FIELD_LABELS.fetch(field) { field.underscore.humanize } }.join(", ")
    end

    def evidence(label, text)
      { "source" => label, "text" => text, "path" => @crawl_path, "brief_id" => @brief.id }
    end

    def draft(page, label, body)
      evidence(label, page.fetch("path")).merge("draft" => body)
    end
  end
end
