defmodule DocumentComplianceEngine.Repo.Migrations.AddOwnerUserIdToDocumentJobs do
  @moduledoc """
  Per-account data isolation: every document_job now belongs to exactly
  one `users` row. Deliberately a plain integer with no `references()` —
  same convention already used for cross-context ids elsewhere
  (`review_decisions.document_job_id`, `audit_samples.document_job_id`/
  `agent_run_id`), since `Accounts` and `DocumentJobs` are separate
  contexts. `null: false` with no backfill: this app has no real
  production data yet, so existing dev rows are cleared via
  `mix ecto.reset` rather than migrated.
  """

  use Ecto.Migration

  def change do
    alter table(:document_jobs) do
      add :owner_user_id, :integer, null: false
    end

    create index(:document_jobs, [:owner_user_id])
  end
end
