module SeoWorkflows
  module Catalogue
    PREVIEW_KEYS = %w[M1 M4 M5 E3 E4 R1 R2 R4 P2].freeze
    Template = Data.define(:key, :name, :tier, :cadence, :reader, :limitation) do
      def available? = reader.present?

      def period_on(day)
        case cadence
        when :daily then day
        when :weekly then day.beginning_of_week - 1
        when :monthly then day.beginning_of_month - 1
        when :quarterly then day.beginning_of_quarter - 1
        end
      end

      def period_start(day)
        case cadence
        when :weekly then day.beginning_of_week
        when :monthly then day.beginning_of_month
        when :quarterly then day.beginning_of_quarter
        else day
        end
      end
    end

    # Local SEO Skills task IDs and tiers, pinned in docs/seo-workflows.md.
    TEMPLATES = [
      Template.new("M1", "Weekly rankings monitor", :autonomous, :weekly, :rankings, "Uses saved organic rankings and comparable Local Falcon grids. Imports are also supported."),
      Template.new("M2", "Review velocity monitor", :autonomous, :weekly, :reviews, "Compares weekly review counts from DataForSEO, Local SEO Data or authorised imports and flags review issues."),
      Template.new("M3", "Business Profile change monitor", :autonomous, :daily, :profile_changes, "Compares verified daily Google Business Profile samples and authorised field exports."),
      Template.new("M4", "Local Services Ads rankings monitor", :autonomous, :weekly, :lsa, "Compares dedicated Local SEO Data scans, imported positions and matches from saved Google Local Services panels."),
      Template.new("M5", "AI visibility monitor", :autonomous, :monthly, :ai_visibility, "Compares imported mentions and citations. Uses saved Google AI Overview links and ChatGPT, Gemini and Perplexity samples when available."),
      Template.new("E1", "Business Profile post drafts", :queue, :monthly, :post_drafts, "Builds an owner-reviewed post draft from supplied public service details. Publication is manual."),
      Template.new("E2", "Review response drafts", :queue, :weekly, :reply_drafts, "Builds a draft reply from the rating and a local reference. Publication is manual."),
      Template.new("E3", "Citation audit", :autonomous, :quarterly, :citations, "Audits directory name, address and phone checks from Local SEO Data or authorised imports."),
      Template.new("E4", "Local page content audit", :queue, :quarterly, :audit, "Queues assigned landing-page findings and drafts from the owner’s brief. Publication is manual."),
      Template.new("R1", "Weekly performance report", :autonomous, :weekly, :report, "Compares saved rankings, Maps visibility and review activity across adjacent weeks."),
      Template.new("R2", "Monthly client report", :notify, :monthly, :report, "The owner reviews the report and records manual delivery or confirms email delivery on an enabled installation."),
      Template.new("R3", "Multi-location rollup", :autonomous, :monthly, :rollup, "Compares saved monthly reports across opted-in locations and flags shared issues."),
      Template.new("R4", "Quarterly business review", :queue, :quarterly, :report, "Uses saved rankings, crawls, AI visibility and comparable local pack results for an internal review."),
      Template.new("P1", "Prospect audit", :autonomous, :on_demand, :prospect, "Runs a live public website audit or summarises authorised prospect imports."),
      Template.new("P2", "Competitor market monitor", :autonomous, :monthly, :competitors, "Compares same-market Google local pack samples and authorised competitor imports.")
    ].index_by(&:key).freeze

    def self.fetch(key) = TEMPLATES.fetch(key)
  end
end
