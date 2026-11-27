module AiAssistant
  module EvidenceText
    private

    # Only intentionally selected project text is eligible. File paths, query strings,
    # contact data and credentials can also appear inside otherwise public text fields.
    def clean(value)
      value.to_s.squish.gsub(%r{https?://[^\s]+}i) { |url| public_path(url) || "[link omitted]" }
        .gsub(%r{(?:[A-Z]:\\|/(?:Users|home|private|var|tmp|mnt|root|app)/|(?:seo-work|private|\.\.?)/)\S+}i, "[path omitted]")
        .gsub(/[\w.+%-]+@[\w.-]+\.[\w-]+/i, "[email omitted]")
        .gsub(/\b(?:sk-|AIza)[\w-]{12,}\b/, "[credential omitted]")
        .gsub(/(?<!\d)(?:\+\d{1,3}[ -]?)?(?:\(?\d{3,5}\)?[ -]?){2,3}\d{2,5}(?!\d)/, "[number omitted]")
        .first(280)
    end

    def public_path(value)
      url = Tracking::ResultUrl.parse(value)
      return unless url && Tracking::ResultUrl.host_matches?(@site.host, url.host)
      path = url.path.presence || "/"
      return if path.match?(%r{(?:^|/)(?:wp-admin|wp-login\.php|private|admin|account|patient|patients|enquiries|portal)(?:/|$)|@|%40}i)
      path.first(180)
    end
  end
end
