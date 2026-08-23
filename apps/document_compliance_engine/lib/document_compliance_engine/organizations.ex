defmodule DocumentComplianceEngine.Organizations do
  @moduledoc """
  Public API for the organizations domain. `defdelegate` only — no logic
  here. Owns the `organizations` and `invitations` tables: a business
  customer's shared account, and the pending-invite-by-email mechanism
  that gets a user attached to one.
  """

  alias DocumentComplianceEngine.Organizations.Actions.{
    AcceptPendingInvitation,
    CreateOrganization,
    InviteMember,
    ListMembers
  }

  alias DocumentComplianceEngine.Organizations.Repository

  defdelegate get_organization(id), to: Repository
  defdelegate create_organization(user, name), to: CreateOrganization, as: :call
  defdelegate accept_pending_invitation(user), to: AcceptPendingInvitation, as: :call
  defdelegate invite_member(inviter, email), to: InviteMember, as: :call
  defdelegate list_members(organization_id), to: ListMembers, as: :call

  defdelegate list_pending_invitations(organization_id),
    to: Repository,
    as: :list_pending_by_organization
end
