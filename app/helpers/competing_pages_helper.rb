module CompetingPagesHelper
  def competition_country(code)
    { "GBR" => "United Kingdom", "USA" => "United States", "AUS" => "Australia", "CAN" => "Canada", "IRL" => "Ireland" }.fetch(code, code)
  end

  def competition_period(first, last)
    return unless first.present? && last.present?
    from, to = [first, last].map { |date| Date.iso8601(date.to_s) }
    start_format = from.year == to.year ? "%-d %b" : "%-d %b %Y"
    "#{from.strftime(start_format)} – #{to.strftime('%-d %b %Y')}"
  end

  def competition_clicks(clicks)
    case clicks.fetch("trend")
    when "down" then pluralize(clicks.fetch("change").abs, "fewer click", "fewer clicks")
    when "up" then pluralize(clicks.fetch("change").abs, "more click", "more clicks")
    when "flat" then "Clicks held steady"
    else "Click trend unknown"
    end
  end

  def competition_switches(finding)
    count = finding.evidence.fetch("switch_count")
    return "The lead changed once in consecutive weeks" if count == 1
    return "The lead changed #{count} times in consecutive weeks" if count > 1
    return "Too few clear readings to identify a switch" if finding.level == "limited"
    "No lead switch between these pages in consecutive weeks"
  end

  def competition_decision(disposition)
    { "open" => "Awaiting your decision", "monitor" => "Monitoring", "accepted_overlap" => "Keeping both pages" }.fetch(disposition)
  end

  def competition_pair_link(url, pair)
    return unless CompetingPages::Comparison.public_page(url, current_site.host)
    labels = (pair | [url]).index_with { |page| competition_path_label(page) }
    label = labels.fetch(url)
    label = url if label.blank? || labels.values.count { |other| other.casecmp?(label) } > 1
    link_to label, url, target: "_blank", rel: "noopener noreferrer", class: "rank-page-link", title: url
  end

  def competition_path_label(url)
    path = Tracking::ResultUrl.parse(url)&.path
    return "Homepage" if path.blank? || path == "/"
    slug = path.split("/").last.to_s
    URI::DEFAULT_PARSER.unescape(slug).scrub.tr("-_", "  ").squish.sub(/\A./, &:upcase)
  end

  def listing_page_link(url)
    safe_url = CompetingPages::Comparison.public_page(url, current_site.host)
    safe_url ? link_to(url, safe_url, target: "_blank", rel: "noopener noreferrer") : url
  end

  def listing_check_time(value)
    return if value.blank?
    local = Time.iso8601(value).in_time_zone(current_site.time_zone)
    tag.time(local.strftime("%-d %b %Y, %H:%M %Z"), datetime: local.iso8601)
  end

  def listing_search_scope(google, device)
    location = google["location"].to_s.split(",").map(&:strip).join(", ")
    language = google["language"]
    language = language == "en" ? "English" : language&.upcase
    [google.fetch("device", device).capitalize, location, language].compact_blank.join(" · ")
  end

  def listing_field_comparison(field, comparison)
    label = field == "title" ? "title" : "description"
    case comparison[field]
    when "matches" then "The #{label} matches."
    when "different" then "The #{label} differs."
    when "truncated" then "The captured #{label} matches the start of the page’s #{label}."
    else "There isn’t enough text to compare the #{label}."
    end
  end

  def listing_field_value(source, field, google:)
    label = field == "title" ? "title" : "description"
    if google
      source[field].presence || "#{field == 'title' ? 'Title' : 'Snippet'} unavailable in this capture."
    else
      case source.dig("field_states", field)
      when "multiple" then "The page contains multiple #{label} tags."
      when "empty" then "The #{label} tag is empty."
      when "too_long" then "The #{label} is too long to display in full."
      else source[field].presence || "No #{field == 'title' ? 'page title' : 'meta description'} found."
      end
    end
  end

  def competition_week_state(state)
    { "tie" => "Too close to call", "sparse" => "No clear lead", "partial" => "Incomplete report",
      "unreported" => "No reading" }.fetch(state, "No clear leader")
  end
end
