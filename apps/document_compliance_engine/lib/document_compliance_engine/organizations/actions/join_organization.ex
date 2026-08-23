defmodule DocumentComplianceEngine.Organizations.Actions.JoinOrganization do
  @moduledoc """
  Shared step behind both ways a user ends up in an organization
  (`CreateOrganization`, `AcceptPendingInvitation`): stamp the user's
  `organization_id`, then backfill any of their document_jobs that were
  pre-provisioned by a webhook's `owner_email` before this org existed —
  otherwise those rows stay permanently orphaned (`organization_id: nil`)
  with no path to ever becoming visible.
  """

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.DocumentJobs

  @spec call(Accounts.Schema.User.t(), pos_integer()) ::
          {:ok, Accounts.Schema.User.t()} | {:error, term()}
  def call(user, organization_id) do
    with {:ok, updated_user} <- Accounts.set_organization_id(user, organization_id) do
      DocumentJobs.backfill_organization_id_for_owner(user.id, organization_id)
      {:ok, updated_user}
    end
  end
end
