defmodule VendorOnboarding.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: VendorOnboarding.Vault
end
