defmodule VendorOnboarding.Repo.Migrations.AddExplanationToVendorOnboardings do
  use Ecto.Migration

  def change do
    alter table(:vendor_onboardings) do
      add :explanation, :text
    end
  end
end
