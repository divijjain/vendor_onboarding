defmodule VendorOnboarding.Repo.Migrations.CreateVendorOnboardings do
  use Ecto.Migration

  def change do
    create table(:vendor_onboardings) do
      add :status, :string, null: false, default: "received"
      add :thread_id, :string
      add :idempotency_key, :string, null: false

      add :company_name, :string
      add :tax_id, :binary
      add :payment_terms, :text
      add :liability_clauses, :text

      add :document_paths, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vendor_onboardings, [:idempotency_key])
    create index(:vendor_onboardings, [:status])
    create index(:vendor_onboardings, [:thread_id])
  end
end
