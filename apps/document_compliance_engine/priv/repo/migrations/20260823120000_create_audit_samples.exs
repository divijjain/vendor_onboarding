defmodule DocumentComplianceEngine.Repo.Migrations.CreateAuditSamples do
  @moduledoc """
  Post-hoc audit trail for auto-approved agent runs: a run that went
  straight to `:approved` with no human ever in the loop has a
  configured probability of being sampled here for a compliance officer
  to spot-check after the fact. Mutable (unlike `review_decisions`,
  which is append-only) — a sample starts `pending` and is later updated
  in place once reviewed, since there's exactly one outcome per sample,
  not a history of them.
  """

  use Ecto.Migration

  def change do
    create table(:audit_samples) do
      add :document_job_id, :integer, null: false
      add :agent_run_id, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :reviewer, :string
      add :notes, :text
      add :reviewed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:audit_samples, [:agent_run_id])
    create index(:audit_samples, [:status])
    create index(:audit_samples, [:document_job_id])
  end
end
