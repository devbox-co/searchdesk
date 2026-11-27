module CompetingPages
  # Both checks update one finding's saved report. Reserve it briefly, fetch public
  # pages outside the transaction and only save if the ranking evidence still matches.
  class ListingRefresh
    def self.call(finding:, version:, identity:)
      token = SecureRandom.uuid
      key = finding.with_lock do
        current = identity.call
        raise ListingCheck::Stale unless current && version == finding.updated_at.iso8601(6)
        raise ListingCheck::Busy if finding.listing_check_token && finding.listing_check_started_at&.after?(2.minutes.ago)
        finding.update_columns(listing_check_token: token, listing_check_started_at: Time.current)
        current
      end
      report = yield(key)
      finding.with_lock do
        raise ListingCheck::Stale unless finding.listing_check_token == token && identity.call == key
        finding.update_columns(listing_check: report, listing_check_token: nil, listing_check_started_at: nil)
      end
      report
    ensure
      if token && finding.listing_check_token == token
        SiteFinding.where(id: finding.id, listing_check_token: token).update_all(listing_check_token: nil, listing_check_started_at: nil)
      end
    end
  end
end
