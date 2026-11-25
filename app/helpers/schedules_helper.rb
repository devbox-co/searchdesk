module SchedulesHelper
  def schedule_timestamp(value)
    return if value.nil?

    if value.is_a?(Date) && !value.is_a?(DateTime)
      tag.time(value.strftime("%-d %b %Y"), datetime: value.iso8601)
    else
      local = value.in_time_zone(current_site.time_zone)
      tag.time(local.strftime("%-d %b %Y, %H:%M %Z"), datetime: local.iso8601)
    end
  end
end
