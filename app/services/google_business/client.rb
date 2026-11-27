module GoogleBusiness
  class Client < GoogleReadOnly::Client
    class ReviewChanged < AccessError; end

    INFO = "https://mybusinessbusinessinformation.googleapis.com/v1"
    PROFILE = "https://mybusiness.googleapis.com/v4"
    SCOPE = "https://www.googleapis.com/auth/business.manage"
    CALLBACK_ROUTE = :callback_business_profile_url
    CLIENT_ID_ENV = "GOOGLE_BUSINESS_CLIENT_ID"
    CLIENT_SECRET_ENV = "GOOGLE_BUSINESS_CLIENT_SECRET"
    GOOGLE_ID = /\A[0-9]{1,30}\z/
    REVIEW_ID = /\A[A-Za-z0-9_-]{1,160}\z/
    RATINGS = %w[ONE TWO THREE FOUR FIVE].each_with_index.to_h.transform_values { |index| index + 1 }.freeze

    def token(refresh_token)
      data = refresh(refresh_token)
      # A refresh response may omit unchanged scopes.
      raise AccessError, "Reconnect the Business Profile grant." if data.key?("scope") && !data["scope"].split.include?(SCOPE)

      data
    end

    def profile(token:, account_id:, location_id:, host:)
      raise Error, "Enter valid Google account and location IDs." unless [account_id, location_id].all? { |id| GOOGLE_ID.match?(id.to_s) }

      # Check the actual account/location pairing, not just OAuth visibility of
      # a location that may be accessible through a different account.
      scope = "name,title,websiteUri,categories,regularHours"
      page_token = nil
      10.times do
        params = { readMask: scope, pageSize: 100, pageToken: page_token }.compact
        data = json_request("#{INFO}/accounts/#{account_id}/locations?#{URI.encode_www_form(params)}", token: token)
        location = Array(data["locations"]).grep(Hash).find { |row| row["name"] == "locations/#{location_id}" }
        if location
          website = URI.parse(location["websiteUri"].to_s)
          unless website.is_a?(URI::HTTP) && website.userinfo.nil? && Tracking::ResultUrl.host_matches?(host, website.host)
            raise AccessError, "The Business Profile website does not match the selected site."
          end
          return location.slice("title", "websiteUri", "categories", "regularHours")
        end
        page_token = data["nextPageToken"].presence
        break unless page_token
      end
      raise AccessError, "The location is unavailable under that Google account."
    rescue URI::Error
      raise AccessError, "The Business Profile has no matching website."
    end

    def reviews(token:, parent:)
      data = json_request("#{PROFILE}/#{valid_parent(parent)}/reviews?pageSize=50&orderBy=updateTime%20desc&" \
        "fields=reviews(reviewId,starRating,updateTime,reviewReply(updateTime)),nextPageToken", token: token)
      Array(data["reviews"]).grep(Hash).filter_map do |row|
        id = row["reviewId"]
        rating = RATINGS[row["starRating"]]
        next unless REVIEW_ID.match?(id.to_s) && rating

        { "reference" => id, "rating" => rating, "updated_at" => row["updateTime"], "answered" => row["reviewReply"].present? }
      end
    end

    def create_post(token:, parent:, text:)
      parent = valid_parent(parent)
      result = json_request("#{PROFILE}/#{parent}/localPosts", token: token,
        json: { languageCode: "en", summary: text, topicType: "STANDARD" })
      name = result["name"].to_s
      raise Error, "Google did not return a publication receipt." unless name.match?(%r{\A#{Regexp.escape(parent)}/localPosts/[A-Za-z0-9_-]+\z})

      name
    end

    def reply(token:, parent:, review_id:, rating:, text:)
      raise Error, "Invalid Google review reference." unless REVIEW_ID.match?(review_id.to_s)

      url = "#{PROFILE}/#{valid_parent(parent)}/reviews/#{review_id}"
      review = json_request("#{url}?fields=reviewId,starRating,reviewReply(updateTime)", token: token)
      unless review["reviewId"] == review_id && RATINGS[review["starRating"]] == rating && review["reviewReply"].blank?
        raise ReviewChanged, "The review changed or already has a reply."
      end
      result = json_request("#{url}/reply", token: token, json: { comment: text }, http_method: Net::HTTP::Put)
      raise Error, "Google did not confirm the reply." unless result["comment"] == text && result["updateTime"].present?

      "#{parent}/reviews/#{review_id}"
    end

    private

    def valid_parent(value)
      return value if value.match?(%r{\Aaccounts/[0-9]{1,30}/locations/[0-9]{1,30}\z})

      raise Error, "Invalid Google Business Profile location."
    end
  end
end
