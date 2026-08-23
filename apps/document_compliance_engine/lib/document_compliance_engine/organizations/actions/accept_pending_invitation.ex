defmodule DocumentComplianceEngine.Organizations.Actions.AcceptPendingInvitation do
  @moduledoc """
  Called only from the Google OAuth callback path
  (`DocumentComplianceEngineWeb.AuthController.callback/2`), never from
  webhook/MCP ingestion — accepting an invite must only ever happen as a
  side effect of a real, authenticated Google login for that exact email,
  never from an unauthenticated payload naming someone else's invited
  address. Idempotent: a user who already belongs to an organization is
  left alone.
  """

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.Organizations.Actions.JoinOrganization
  alias DocumentComplianceEngine.Organizations.Repository

  @spec call(Accounts.Schema.User.t()) ::
          {:ok, :already_in_organization | :no_pending_invite | :joined} | {:error, term()}
  def call(%{organization_id: organization_id}) when not is_nil(organization_id) do
    {:ok, :already_in_organization}
  end

  def call(user) do
    case Repository.get_pending_invitation_by_email(user.email) do
      nil ->
        {:ok, :no_pending_invite}

      invitation ->
        with {:ok, _invitation} <- Repository.accept_invitation(invitation),
             {:ok, _user} <- JoinOrganization.call(user, invitation.organization_id) do
          {:ok, :joined}
        end
    end
  end
end
