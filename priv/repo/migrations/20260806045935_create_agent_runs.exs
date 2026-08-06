defmodule VendorOnboarding.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs) do
      add :vendor_onboarding_id, references(:onboardings, on_delete: :delete_all), null: false

      add :status, :string, null: false, default: "processing"
      add :thread_id, :string

      add :company_name, :string
      add :w9_company_name, :string
      add :tax_id, :binary
      add :payment_terms, :string
      add :liability_clauses, :string
      add :explanation, :string

      timestamps(type: :utc_datetime)
    end

    create index(:agent_runs, [:vendor_onboarding_id])
    create index(:agent_runs, [:thread_id])
    create index(:agent_runs, [:status])
  end
end
