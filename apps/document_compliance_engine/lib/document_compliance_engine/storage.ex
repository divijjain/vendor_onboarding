defmodule DocumentComplianceEngine.Storage do
  @moduledoc """
  Document storage boundary. The adapter is a config swap — local disk for
  dev/test, S3 (or equivalent) later — per CONTEXT.md's storage decision.
  """

  @callback store(path :: String.t(), content :: binary()) :: {:ok, String.t()} | {:error, term()}
  @callback read(path :: String.t()) :: {:ok, binary()} | {:error, term()}

  @spec store(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def store(path, content), do: adapter().store(path, content)

  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  def read(path), do: adapter().read(path)

  defp adapter do
    Application.get_env(
      :document_compliance_engine,
      :storage_adapter,
      DocumentComplianceEngine.Storage.LocalDisk
    )
  end
end
