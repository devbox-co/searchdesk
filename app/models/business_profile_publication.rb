class BusinessProfilePublication < ApplicationRecord
  class NotEligible < StandardError; end

  belongs_to :seo_workflow_run
  belongs_to :confirmed_by, class_name: "User", optional: true
  self.filter_attributes += [:grant_revision, :provider_reference]

  def self.draft(run, index)
    return unless run.status == "approved" && index.is_a?(Integer) && index >= 0

    text = run.result[index]&.fetch("text", nil).to_s
    return if text.blank? || text.length > 1_500

    case run.template_key
    when "E1"
      { text: text }
    when "E2"
      match = text.match(/\A([A-Za-z0-9_-]{1,160}) · ([1-5]) out of 5 · (.+)\z/)
      { review_id: match[1], rating: match[2].to_i, text: match[3] } if match
    end
  end

  def self.confirm!(run:, index:, user:, expected_grant:, client: GoogleBusiness::Client.new)
    input = nil
    connection = nil
    receipt = run.with_lock do
      input = draft(run, index)
      site = Site.find(run.site_id)
      connection = site.business_profile_connection
      unless input && site.host == run.site_host && connection&.connected? &&
          connection.grant_revision == expected_grant &&
          Membership.exists?(workspace_id: site.workspace_id, role: "owner", user: user)
        raise NotEligible, "The approved draft or selected location changed. Review the current page before publishing."
      end

      find_by(seo_workflow_run: run, row_index: index) ||
        create!(seo_workflow_run: run, row_index: index, confirmed_by: user, status: "sending",
          grant_revision: connection.grant_revision, attempted_at: Time.current)
    end
    return receipt unless receipt.previously_new_record?

    write_started = false
    begin
      connection.with_lock do
        site = Site.find(run.site_id)
        unless connection.connected? && connection.grant_revision == receipt.grant_revision && site.host == run.site_host &&
            Membership.exists?(workspace_id: site.workspace_id, role: "owner", user: user)
          raise NotEligible, "The location connection is no longer active."
        end

        token = connection.access_token!(client)
        client.profile(token: token, account_id: connection.account_id, location_id: connection.location_id, host: site.host)
        write_started = true
        reference = if input.key?(:review_id)
          client.reply(token: token, parent: connection.parent, **input)
        else
          client.create_post(token: token, parent: connection.parent, **input)
        end
        receipt.update!(status: "published", provider_reference: reference)
        SeoWorkflowNotification.record!(run: run, kind: "published")
      end
    rescue GoogleBusiness::Client::ReviewChanged
      receipt.update!(status: "blocked")
    rescue GoogleReadOnly::Client::Error, ActiveRecord::RecordNotFound, NotEligible
      receipt.update!(status: write_started ? "uncertain" : "blocked")
    end
    receipt
  end
end
