defmodule DocumentComplianceEngine.Repo.Migrations.CreateInvitations do
  @moduledoc """
  A pending (or already-accepted) invite to join an organization by email.
  Plain integer references (`organization_id`, `invited_by_user_id`), no
  `references()` — same convention as every other cross-context id in
  this app (`document_jobs.owner_user_id`, `audit_samples.document_job_id`).

  The partial unique index — only over rows where `accepted_at IS NULL` —
  enforces "at most one pending invite per email" without blocking that
  same email from later being invited again after leaving (not itself
  supported yet, but not accidentally prevented by the index either).
  Must be given an explicit name so the changeset's `unique_constraint/3`
  can reference it exactly: the default derived name
  (`invitations_email_index`) does not match a custom-named partial index.
  """

  use Ecto.Migration

  def change do
    create table(:invitations) do
      add :email, :string, null: false
      add :organization_id, :integer, null: false
      add :invited_by_user_id, :integer, null: false
      add :accepted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:email],
             where: "accepted_at IS NULL",
             name: :invitations_email_pending_index
           )

    create index(:invitations, [:organization_id])
  end
end
