class SeoAiVisibilitySampleJob < ApplicationJob
  def perform(snapshot_id, owner_id)
    snapshot = SourceSnapshot.find_by(id: snapshot_id)
    SeoWorkflows::AiVisibilitySample.perform(snapshot, owner_id) if snapshot
  end
end
