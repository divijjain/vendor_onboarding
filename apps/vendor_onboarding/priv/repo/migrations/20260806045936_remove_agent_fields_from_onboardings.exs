defmodule VendorOnboarding.Repo.Migrations.RemoveAgentFieldsFromOnboardings do
  use Ecto.Migration

  def change do
    alter table(:onboardings) do
      remove :thread_id, :string
      remove :company_name, :string
      remove :w9_company_name, :string
      remove :tax_id, :binary
      remove :payment_terms, :string
      remove :liability_clauses, :string
      remove :explanation, :string
    end
  end
end
