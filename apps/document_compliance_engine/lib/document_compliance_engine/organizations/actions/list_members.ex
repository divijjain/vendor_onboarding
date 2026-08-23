defmodule DocumentComplianceEngine.Organizations.Actions.ListMembers do
  @moduledoc "For the organization's team page — every user who has joined."

  alias DocumentComplianceEngine.Accounts

  @spec call(pos_integer()) :: [Accounts.Schema.User.t()]
  def call(organization_id) do
    Accounts.list_users_by_organization(organization_id)
  end
end
