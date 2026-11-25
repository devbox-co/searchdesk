module SiteAuditsHelper
  def audit_time(timestamp)
    timestamp&.in_time_zone(current_site.time_zone)&.strftime("%d %b %Y, %H:%M %Z")
  end

  def audit_status(audit)
    { "queued" => "Queued", "running" => "Crawling", "complete" => "Complete",
      "partial" => "Partial crawl", "failed" => "Failed" }.fetch(audit.status, "Unknown")
  end

  def audit_page_link(path, checked_url = nil)
    return path unless path.is_a?(String) && path.match?(%r{\A/(?!/)[^\\?#[:cntrl:]]*\z})
    url = Tracking::ResultUrl.parse(checked_url || "https://#{current_site.host}#{path}")
    return path unless url && Tracking::ResultUrl.host_matches?(current_site.host, url.host) &&
      url.port == url.default_port && !url.query && !url.fragment && url.path == path

    link_to path, url.to_s, target: "_blank", rel: "noopener noreferrer"
  end

  def audit_google_url(report, property)
    "https://search.google.com/search-console/#{report}?#{URI.encode_www_form(resource_id: property)}"
  end

  def audit_stat_value(key, value)
    return "Unavailable" if value.nil?
    case key
    when "ctr" then number_to_percentage(value * 100, precision: 1)
    when "position" then number_with_precision(value, precision: 1)
    else number_with_delimiter(value)
    end
  end
end
