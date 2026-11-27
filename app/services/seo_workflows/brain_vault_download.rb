require "open3"

module SeoWorkflows
  class BrainVaultDownload
    class Unavailable < StandardError; end
    class NoEvidence < StandardError; end

    def self.build(site, origin:)
      bundle = JSON.pretty_generate(EvidenceBundle.new(site).build)
      as_of = Time.current.in_time_zone(site.time_zone).to_date.iso8601
      archive, _, status = Open3.capture3("python3", "-E", "-s", "-B",
        Rails.root.join("lib/seo_brain/pack_vault.py").to_s, "/opt/local-seo-brain", site.host, origin, as_of,
        stdin_data: bundle, binmode: true)
      raise NoEvidence if status.exitstatus == 3
      raise Unavailable unless status.success?

      archive
    rescue Errno::ENOENT
      raise Unavailable
    end
  end
end
