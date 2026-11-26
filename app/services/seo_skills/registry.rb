module SeoSkills
  class Registry
    # Code owns both paths and class names. Requests cannot select new resources.
    ENTRIES = {
      "action_review" => ["v1", "SeoSkills::ActionReview", "steps.yml"],
      "business_wording" => ["v1", "SeoSkills::WordingClient", "prompt.txt"]
    }.freeze

    def self.fetch(id)
      # The initializer resolves both entries before the app accepts requests.
      @recipes ||= {}
      @recipes[id] ||= load_recipe(id)
    end

    def self.load_recipe(id)
      version, handler, file = ENTRIES.fetch(id)
      directory = Rails.root.join("config", "seo_skills", id, version)
      manifest = YAML.safe_load_file(directory.join("manifest.yml"))
      expected = { "id" => id, "version" => version, "handler" => handler, "resource" => file }
      raise ArgumentError, "Invalid registered skill #{id}" unless manifest.slice(*expected.keys) == expected

      contents = directory.join(file).read
      data = file.end_with?(".yml") ? YAML.safe_load(contents).fetch("steps") : contents
      { version: "#{id}/#{version}", handler: handler.constantize, contents: data.freeze }.freeze
    end
    private_class_method :load_recipe
  end
end
