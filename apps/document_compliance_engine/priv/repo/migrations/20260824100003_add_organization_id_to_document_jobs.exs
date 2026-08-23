defmodule DocumentComplianceEngine.Repo.Migrations.AddOrganizationIdToDocumentJobs do
  @moduledoc """
  The real isolation boundary going forward — a denormalized copy of the
  owning user's `organization_id`, stamped at ingestion time. Deliberately
  nullable, unlike `owner_user_id`'s `NOT NULL`: a webhook can
  pre-provision an owner (by `owner_email`) who has no organization yet,
  leaving this `nil` until that person's first login creates or joins
  one — at which point `DocumentJobs.backfill_organization_id_for_owner/2`
  fills it in for their existing rows. See CONTEXT.md's dated entry.
  """

  use Ecto.Migration

  def change do
    alter table(:document_jobs) do
      add :organization_id, :integer
    end

    create index(:document_jobs, [:organization_id])
  end
end
