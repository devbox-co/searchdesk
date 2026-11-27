module Tracking
  module DataForSeoBudget
    def self.lock!
      DailySlot.connection.execute("SELECT pg_advisory_xact_lock(624003017)")
    end

    def self.daily_full?(time)
      window = (time.utc.beginning_of_day..)
      full?(DailySlot.where(attempted_at: window), workflow_attempts.where(created_at: window), DataForSeo.daily_task_limit)
    end

    def self.rolling_full?(time)
      cutoff = time.utc - 31.days
      full?(DailySlot.where("attempted_at > ?", cutoff), workflow_attempts.where("created_at > ?", cutoff),
        DataForSeo.rolling_task_limit)
    end

    def self.workflow_attempts
      managed = SourceSnapshot.where(provider: LocalSeoData::DataForSeoCollection::PROVIDER)
        .where("metrics->>'kind' IN ('gbp_monitor', 'review_activity')")
      managed.or(SourceSnapshot.where(provider: SeoWorkflows::AiVisibilitySample::PROVIDER))
    end

    def self.full?(slots, profiles, limit)
      return true if limit.zero?

      rank_attempts = slots.count
      rank_attempts >= limit || profiles.offset(limit - rank_attempts - 1).exists?
    end
    private_class_method :workflow_attempts, :full?
  end
end
