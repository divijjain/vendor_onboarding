defmodule DocumentComplianceEngine.Repo.Migrations.CreateReviewDecisions do
  @moduledoc """
  An append-only audit log of human approve/reject decisions on paused
  agent runs: who decided, what evidence was in front of them, and why.
  Deliberately a separate table from `agent_runs` rather than columns on
  it — a later re-run overwrites `agent_runs`' status, but the decision
  that led to a resume must stay intact regardless of what happens after.
  Lives in the default schema (unlike `run_checkpoints`): this is
  business/compliance data meant to be queried and reported on, not
  internal reactor-serialization state.
  """

  use Ecto.Migration

  def change do
    create table(:review_decisions) do
      add :document_job_id, :integer, null: false
      add :thread_id, :string, null: false
      add :decision, :string, null: false
      add :reviewer, :string, null: false
      add :rationale, :text, null: false
      # Snapshot of the agent's explanation at decision time — what the
      # reviewer actually had in front of them, not a live join against
      # `agent_runs` that could drift after a later re-run.
      add :evidence, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:review_decisions, [:document_job_id])
  end
end
