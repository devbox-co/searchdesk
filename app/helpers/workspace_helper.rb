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

  def movement_label(row)
    case row[:transition].to_s
    when "up" then "Up #{row[:change].to_i.abs}"
    when "down" then "Down #{row[:change].to_i.abs}"
    when "unchanged" then "No change"
    when "entered" then "Entered top 30"
    when "left" then "Left top 30"
    when "outside_both" then "Outside both days"
    when "baseline" then "Starting point"
    else "—"
    end
  end

  def gsc_position_change(row)
    delta = row[:change]
    return "Starting point" if row.dig(:current, :position) && row.dig(:baseline, :date) == row.dig(:current, :date)
    return "—" if delta.nil?
    return "No change" if delta.round(2).zero?

    "#{delta.positive? ? 'Up' : 'Down'} #{number_with_precision(delta.abs, precision: 2, strip_insignificant_zeros: true)}"
  end

  def compact_date(date)
    date&.strftime("%d %b %Y")
  end
end
