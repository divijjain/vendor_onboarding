defmodule DocumentComplianceEngine.Encrypted.Binary do
  use Cloak.Ecto.Binary, vault: DocumentComplianceEngine.Vault
end
