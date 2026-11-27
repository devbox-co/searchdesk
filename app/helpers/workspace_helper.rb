module WorkspaceHelper
  def ranking_page_label(url)
    uri = Tracking::ResultUrl.parse(url)
    return url unless uri
    return "Homepage" if ["", "/"].include?(uri.path) && !uri.query

    uri.request_uri
  end

  def rank_value(rank, status, fallback: "No reading")
    return "##{rank}" if rank.present?
    status.to_s == "outside" ? "Outside 30" : fallback
  end

  def rank_icon_text(icon, text, size: 16)
    safe_join([ui_icon(icon, size: size), tag.span(text)], " ")
  end

  def rank_page_link(url)
    parsed = Tracking::ResultUrl.parse(url)
    return unless parsed && Tracking::ResultUrl.host_matches?(current_site.host, parsed.host)

    link_to parsed.to_s, target: "_blank", rel: "noopener noreferrer", class: "rank-page-link",
      aria: { label: "Open ranking page #{parsed} in a new tab" } do
      safe_join([tag.span(ranking_page_label(parsed.to_s)), ui_icon(:external_link, size: 12)], " ")
    end
  end

  def rank_feature_badge(feature, show_label: false)
    return if feature.blank?
    style, icon = case feature.downcase
    when "local pack" then ["map", :map_pin]
    when "ai overview" then ["ai", :sparkles]
    else ["other", :layers]
    end
    compact = !show_label && style != "other"
    text = tag.span(feature, class: ("rank-sr-only" if compact))
    tag.span(safe_join([ui_icon(icon, size: 14), text], " "),
      class: "rank-feature rank-feature--#{style}#{" rank-feature--icon" if compact}", title: feature)
  end

  def rank_change_badge(state, label)
    tone, icon = case state.to_s
    when "up", "entered" then ["up", :trend_up]
    when "down", "left" then ["down", :trend_down]
    when "baseline" then ["start", :flag]
    when "unchanged", "outside_both" then ["same", :minus]
    else ["unknown", nil]
    end
    content = if %w[up down].include?(state.to_s)
      direction, magnitude = label.split(" ", 2)
      safe_join([ui_icon(icon, size: 15), tag.span("#{direction} ", class: "rank-sr-only"), tag.span(magnitude)])
    elsif icon
      rank_icon_text(icon, label, size: 14)
    else
      label
    end
    tag.span(content, class: "rank-change rank-change--#{tone}", title: label)
  end

  def movement_label(row)
    case row[:transition].to_s
    when "up" then "Up #{row[:change].to_i.abs}"
    when "down" then "Down #{row[:change].to_i.abs}"
    when "unchanged" then "No change"
    when "entered" then "Entered top 30"
    when "left" then "Left top 30"
    when "outside_both" then "Outside both days"
    when "baseline" then "Starting point"
    else "No comparison"
    end
  end

  def numeric_rank_change(delta, starting_label: nil, precision: 0)
    return rank_change_badge(:baseline, starting_label) if starting_label
    return rank_change_badge(:unavailable, "No comparison") if delta.nil?
    rounded = delta.round(precision)
    return rank_change_badge(:unchanged, "No change") if rounded.zero?
    amount = number_with_precision(rounded.abs, precision: precision, strip_insignificant_zeros: true)
    rank_change_badge(rounded.positive? ? :up : :down, "#{rounded.positive? ? 'Up' : 'Down'} #{amount}")
  end

  def gsc_position_change(row)
    starting = row.dig(:current, :position) && row.dig(:baseline, :date) == row.dig(:current, :date)
    numeric_rank_change(row[:change], starting_label: ("Starting point" if starting), precision: 2)
  end

  def compact_date(date)
    date&.strftime("%d %b %Y")
  end
end
