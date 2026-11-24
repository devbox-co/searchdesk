Rails.application.config.to_prepare do
  SeoSkills::Registry::ENTRIES.each_key { |id| SeoSkills::Registry.fetch(id) }
end
