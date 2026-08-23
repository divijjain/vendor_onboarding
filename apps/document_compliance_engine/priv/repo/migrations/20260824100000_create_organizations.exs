defmodule DocumentComplianceEngine.Repo.Migrations.CreateOrganizations do
  @moduledoc """
  A business customer's shared account — the isolation boundary moves here
  from the individual Google account (`users`) once this exists. See
  CONTEXT.md's dated entry on organizations/invitations.
  """

  use Ecto.Migration

  def change do
    create table(:organizations) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
