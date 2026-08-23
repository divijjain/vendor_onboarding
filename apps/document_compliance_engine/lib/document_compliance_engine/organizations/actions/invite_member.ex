defmodule DocumentComplianceEngine.Organizations.Actions.InviteMember do
  @moduledoc """
  Any member of an organization can invite a teammate by email — no
  admin/member role distinction (deliberately, see CONTEXT.md's dated
  entry). Creating the `invitations` row is the whole feature: no email
  is actually sent, the inviter is expected to tell the invitee
  out-of-band to sign in with that address.
  """

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.Organizations.Repository

  @spec call(Accounts.Schema.User.t(), String.t()) ::
          {:ok, DocumentComplianceEngine.Organizations.Schema.Invitation.t()}
          | {:error, :already_in_an_organization | Ecto.Changeset.t()}
  def call(%{organization_id: organization_id} = inviter, email)
      when not is_nil(organization_id) do
    case Accounts.get_user_by_email(email) do
      %{organization_id: existing_org_id} when not is_nil(existing_org_id) ->
        {:error, :already_in_an_organization}

      _ ->
        Repository.insert_invitation(%{
          email: email,
          organization_id: organization_id,
          invited_by_user_id: inviter.id
        })
    end
  end
end
