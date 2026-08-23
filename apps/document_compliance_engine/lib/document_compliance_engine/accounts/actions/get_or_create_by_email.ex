defmodule DocumentComplianceEngine.Accounts.Actions.GetOrCreateByEmail do
  @moduledoc """
  Resolves an `owner_email` (from a webhook payload, the MCP `trigger_run`
  tool, or the dashboard's manual-upload path) to a `User`, auto-provisioning
  a `google_sub: nil` row if this email has never been seen before. Never
  touches `google_sub` — that only ever gets set by a real Google login,
  see `FindOrCreateFromGoogle`.
  """

  alias DocumentComplianceEngine.Accounts.Repository

  @spec call(String.t()) ::
          {:ok, DocumentComplianceEngine.Accounts.Schema.User.t()} | {:error, term()}
  def call(email) when is_binary(email) do
    case Repository.get_by_email(email) do
      nil -> Repository.insert_by_email(%{email: email})
      user -> {:ok, user}
    end
  end
end
