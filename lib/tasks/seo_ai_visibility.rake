namespace :seo do
  desc "Collect one owner-approved paid AI response sample (public prompt on stdin)"
  task sample_ai_visibility: :environment do
    abort "Set DATAFORSEO_AI_APPROVED=true after the owner approves the exact public prompt." unless ENV["DATAFORSEO_AI_APPROVED"] == "true"

    site = Site.find_by(id: ENV["DATAFORSEO_AI_SITE_ID"]) || abort("Configure DATAFORSEO_AI_SITE_ID.")
    prompt = $stdin.read(2_001).chomp
    result = SeoWorkflows::AiVisibilitySample.call(site: site, owner_id: ENV["DATAFORSEO_AI_OWNER_ID"],
      country: ENV.fetch("DATAFORSEO_AI_COUNTRY", ""), engine: ENV.fetch("DATAFORSEO_AI_ENGINE", ""), prompt: prompt)
    puts "Saved AI response evidence at /source_snapshots/#{result.id}."
  rescue SeoWorkflows::AiVisibilitySample::Unavailable => error
    abort error.message
  end
end
