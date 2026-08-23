defmodule DocumentComplianceEngine.Repo.Migrations.AddOrganizationIdToUsers do
  @moduledoc """
  One organization per user, set once — either by creating a new
  organization (the first person at a business customer) or by accepting
  a pending invite (everyone after that). Nullable: a signed-in user can
  legitimately have no organization yet, gated by `UserAuth`'s
  `:ensure_organization` on_mount hook.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :organization_id, :integer
    end

    create index(:users, [:organization_id])
  end
end
