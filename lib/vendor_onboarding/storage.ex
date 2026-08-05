defmodule VendorOnboarding.Storage do
  @moduledoc """
  Document storage boundary. The adapter is a config swap — local disk for
  dev/test, S3 (or equivalent) later — per CONTEXT.md's storage decision.
  """

  @callback store(path :: String.t(), content :: binary()) :: {:ok, String.t()} | {:error, term()}

  @spec store(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def store(path, content), do: adapter().store(path, content)

  defp adapter do
    Application.get_env(:vendor_onboarding, :storage_adapter, VendorOnboarding.Storage.LocalDisk)
  end
end
