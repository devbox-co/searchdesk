module OverviewsHelper
  def overview_filter_path(**options)
    dashboard_path(request.query_parameters.slice("metric", "rank_device", "map_scan").symbolize_keys.merge(options))
  end

  def period_change(current, previous)
    return if current.nil? || !previous&.positive?
    delta = (current - previous) * 100.0 / previous
    return "Unchanged from prior 28 days" if delta.zero?
    value = number_to_percentage(delta.abs, precision: 1, strip_insignificant_zeros: true)
    "#{delta.positive? ? 'Up' : 'Down'} #{value} vs prior 28 days"
  end

  # Keep the horizontal axis continuous across days Google omitted, but start a
  # new stroke after each gap. A one-day sample is drawn as a point.
  def daily_plot(days)
    values = days.filter_map { |row| row[:value] }
    return if values.empty?
    power = 10**Math.log10([values.max, 1].max).floor
    top = [1, 2, 4, 6, 8, 10].map { |n| power * n }.find { |n| n >= values.max }
    points = days.each_with_index.map do |row, index|
      next if row[:value].nil?
      x = 51 + 525.0 * index / [days.size - 1, 1].max
      y = 140 - 110.0 * row[:value] / top
      row.merge(x: x.round(1), y: y.round(1))
    end
    { top: top, segments: points.chunk_while { |a,b| a && b }.to_a.reject { |chunk| chunk.first.nil? } }
  end

  def rank_bands(rows)
    counts = Hash.new(0)
    rows.each do |row|
      band = case row[:rank]
      when 1..3 then :three
      when 4..10 then :ten
      when 11..30 then :thirty
      else row[:status] == "outside" ? :outside : :unknown
      end
      counts[band] += 1
    end
    counts
  end
end
