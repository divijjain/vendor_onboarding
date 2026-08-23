defmodule DocumentComplianceEngine.Organizations.Actions.CreateOrganization do
  @moduledoc """
  The bootstrap path: the first person at a business customer, with no
  one to invite them yet, names their own organization and becomes its
  first (and so far only) member.
  """

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.Organizations.Actions.JoinOrganization
  alias DocumentComplianceEngine.Organizations.Repository

  @spec call(Accounts.Schema.User.t(), String.t()) ::
          {:ok, DocumentComplianceEngine.Organizations.Schema.Organization.t()} | {:error, term()}
  def call(user, name) do
    with {:ok, organization} <- Repository.insert_organization(%{name: name}),
         {:ok, _user} <- JoinOrganization.call(user, organization.id) do
      {:ok, organization}
    end
  end
end
