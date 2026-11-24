module SeoSkills
  class ActionReview
    def self.for(kind)
      recipe = Registry.fetch("action_review")
      [recipe[:version], recipe[:contents][kind]]
    end
  end
end
