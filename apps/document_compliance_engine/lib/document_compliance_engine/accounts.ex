defmodule DocumentComplianceEngine.Accounts do
  @moduledoc """
  Public API for the accounts domain. `defdelegate` only — no logic here.
  Owns the `users` table: whoever can sign in with Google, and whoever a
  webhook/MCP/manual-upload payload names as a document_job's owner.
  """

  alias DocumentComplianceEngine.Accounts.Actions.{FindOrCreateFromGoogle, GetOrCreateByEmail}
  alias DocumentComplianceEngine.Accounts.Repository

  defdelegate get_user(id), to: Repository, as: :get
  defdelegate get_user_by_email(email), to: Repository, as: :get_by_email
  defdelegate get_or_create_user_by_email(email), to: GetOrCreateByEmail, as: :call
  defdelegate find_or_create_user_from_google(attrs), to: FindOrCreateFromGoogle, as: :call
  defdelegate set_organization_id(user, organization_id), to: Repository

  defdelegate list_users_by_organization(organization_id),
    to: Repository,
    as: :list_by_organization_id
end
