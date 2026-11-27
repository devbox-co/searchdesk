require "csv"

module SeoWorkflows
  class EvidenceImport
    class InvalidExport < StandardError; end

    PROVIDER = "SEO task evidence"
    KINDS = {
      "manual" => "Manual evidence",
      "gbp" => "Business Profile export",
      "citations" => "Citation export",
      "reviews" => "Review export",
      "geogrid" => "Geogrid export",
      LandingPageBrief::KIND => "Landing page brief"
    }.merge(SignalExport::TYPES, StructuredEvidence::TYPES).freeze
    MAX_BYTES = 256.kilobytes
    MAX_ROWS = 2_000

    def self.call(site:, kind:, observed_on:, upload:)
      raise InvalidExport, "Choose an evidence type and a CSV or JSON export." unless KINDS.key?(kind) &&
        upload.is_a?(ActionDispatch::Http::UploadedFile)

      day = Date.iso8601(observed_on.to_s)
      raise InvalidExport, "The observation date must be on or before today." if day > Time.current.in_time_zone(site.time_zone).to_date
      bytes = upload.read(MAX_BYTES + 1).to_s
      raise InvalidExport, "Use a non-empty export up to 256 KiB." if bytes.empty? || bytes.bytesize > MAX_BYTES
      bytes = bytes.dup.force_encoding(Encoding::UTF_8)
      raise InvalidExport, "The export must be UTF-8." unless bytes.valid_encoding?

      identity = { provider: PROVIDER, external_id: "v1-#{kind}-#{Digest::SHA256.hexdigest(bytes)}-#{day}-#{Digest::SHA256.hexdigest(site.host).first(16)}" }
      site.source_snapshots.find_by(identity) || site.source_snapshots.create_or_find_by!(identity) do |record|
        summary = new(bytes.delete_prefix("\uFEFF"), kind).summary(site: site, observed_on: day)
        record.assign_attributes(title: KINDS.fetch(kind), observed_on: day,
          scope: "Operator-supplied export for #{site.host}. Derived counts describe the supplied rows.",
          metrics: summary.merge("kind" => kind, "host" => site.host))
      end
    rescue Date::Error
      raise InvalidExport, "Enter an observation date in YYYY-MM-DD format."
    rescue CSV::MalformedCSVError, JSON::ParserError
      raise InvalidExport, "The file is not a valid export for the selected evidence type."
    end

    def initialize(content, kind)
      @content, @kind = content, kind
    end

    def summary(site:, observed_on:)
      rows, columns = parse
      values = case @kind
      when LandingPageBrief::KIND
        LandingPageBrief.summarize(site, rows)
      when "reviews"
        summarize_reviews(rows)
      when "geogrid"
        summarize_geogrid(rows)
      when "citations"
        summarize_citations(rows)
      else
        if StructuredEvidence::TYPES.key?(@kind)
          raise InvalidExport, "Use at most 100 rows for this evidence type." if rows.size > 100
          StructuredEvidence.summarize(@kind, rows, observed_on)
        elsif SignalExport::TYPES.key?(@kind)
          raise InvalidExport, "Use at most 100 rows for this evidence type." if rows.size > 100
          SignalExport.summarize(@kind, rows)
        else
          {}
        end
      end
      { "export_rows" => rows.size, "column_count" => columns }.merge(values)
    end

    private

    def parse
      rows, columns = if @kind == "reviews" && @content.lstrip.start_with?("[", "{")
        data = JSON.parse(@content)
        data = data["reviews"] if data.is_a?(Hash)
        raise InvalidExport, "Expected a review list." unless data.is_a?(Array) && data.all?(Hash)

        [data, data.flat_map(&:keys).uniq.size]
      else
        csv = CSV.parse(@content, headers: true, header_converters: ->(name) { name.to_s.strip.downcase })
        [csv.map(&:to_h), csv.headers.size]
      end
      raise InvalidExport, "Use an export with 1 to 2,000 data rows." unless (1..MAX_ROWS).cover?(rows.size)

      [rows, columns]
    end

    def summarize_reviews(rows)
      ratings = rows.filter_map do |row|
        value = row["rating"] || row["stars"] || row["score"] || row["starRating"]
        name = %w[ONE TWO THREE FOUR FIVE].index(value.to_s.upcase)
        rating = name ? name + 1 : Float(value, exception: false)
        rating if rating&.between?(1, 5)
      end
      raise InvalidExport, "Expected a rating from one to five." if ratings.empty?

      { "rated_rows" => ratings.size, "average_rating" => (ratings.sum.to_f / ratings.size).round(2) }
    end

    def summarize_geogrid(rows)
      samples = rows.filter_map do |row|
        rank = Integer(row["rank"] || row["position"] || row["pos"] || row["ranking"], exception: false)
        rank if rank&.positive?
      end
      raise InvalidExport, "Expected a rank or position column with positive integers." if samples.empty?

      { "ranked_samples" => samples.size, "top_three_samples" => samples.count { |rank| rank <= 3 } }
    end

    def summarize_citations(rows)
      # Store bounded counts only. Directory names, links and business identity
      # can appear in the source export but do not belong in this summary.
      count = rows.count { |row| (row["directory"] || row["site"] || row["source"]).present? }
      raise InvalidExport, "Expected a directory, site or source column." if count.zero?

      { "directory_rows" => count,
        "rows_with_reported_status" => rows.count { |row| (row["status"] || row["listing_status"] || row["accuracy"]).present? } }
    end
  end
end
