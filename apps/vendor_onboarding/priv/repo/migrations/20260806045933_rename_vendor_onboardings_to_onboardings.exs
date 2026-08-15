defmodule VendorOnboarding.Repo.Migrations.RenameVendorOnboardingsToOnboardings do
  use Ecto.Migration

  def change do
    rename table(:vendor_onboardings), to: table(:onboardings)

    # Renaming a table does not rename its indexes/constraints in Postgres —
    # left as vendor_onboardings_* they'd silently stop matching
    # `unique_constraint/2`'s default name-derivation (`onboardings_*`),
    # turning a handled duplicate-key error into an unhandled exception.
    rename_index("vendor_onboardings_idempotency_key_index", "onboardings_idempotency_key_index")
    rename_index("vendor_onboardings_status_index", "onboardings_status_index")
    rename_index("vendor_onboardings_pkey", "onboardings_pkey")
  end

  defp rename_index(old_name, new_name) do
    execute(
      "ALTER INDEX #{old_name} RENAME TO #{new_name}",
      "ALTER INDEX #{new_name} RENAME TO #{old_name}"
    )
  end
end
