defmodule VendorOnboarding.Repo.Migrations.AddW9CompanyNameToVendorOnboardings do
  use Ecto.Migration

  def change do
    alter table(:vendor_onboardings) do
      add :w9_company_name, :string
    end
  end
end
