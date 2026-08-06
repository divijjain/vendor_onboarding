defmodule VendorOnboarding.Onboardings.Idempotency do
  @moduledoc """
  Pure hash computation — no DB, no side effects. See `Repository` for
  the uniqueness check this key is used against.
  """

  @spec hash(binary()) :: String.t()
  def hash(raw_payload) when is_binary(raw_payload) do
    :crypto.hash(:sha256, raw_payload) |> Base.encode16(case: :lower)
  end
end
