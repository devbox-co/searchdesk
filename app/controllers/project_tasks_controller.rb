class ProjectTasksController < ApplicationController
  before_action :require_site_manager, only: :update
  before_action :load_task, only: [:show, :update]

  def index
    scope = current_site.project_tasks
    @statuses = scope.distinct.pluck(ProjectTask::EFFECTIVE_STATUS).sort
    @priorities = scope.distinct.order(:priority).pluck(:priority)
    rows = scope.order(:title, :id)
    rows = rows.with_current_status(params[:status]) if params[:status].present?
    rows = rows.where(priority: params[:priority]) if params[:priority].present?
    if params[:q].present?
      match = "%#{ProjectTask.sanitize_sql_like(params[:q].to_s.strip)}%"
      rows = rows.where("title ILIKE ? OR external_id ILIKE ?", match, match)
    end
    @page = params[:page].to_s.to_i.clamp(1, 100_000)
    @records = rows.offset((@page - 1) * 50).limit(51).to_a
    @more = @records.length > 50
    @records.pop if @more
  end

  def show
  end

  def update
    values = params.require(:project_task).permit(:working_status, :owner_note)
    values[:working_status] = values[:working_status].presence if values.key?(:working_status)
    if @task.update(values)
      redirect_to project_task_path(@task), notice: "Task changes saved."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def load_task
    @task = current_site.project_tasks.find(params[:id])
  end
end
