defmodule DocumentComplianceEngine.Organizations.Actions.AcceptPendingInvitationTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.DocumentJobs
  alias DocumentComplianceEngine.Organizations

  test "joins the invited organization when a pending invite matches the user's email" do
    organization = organization_fixture()
    inviter = user_fixture(%{organization_id: organization.id})
    invitee = user_fixture(%{organization_id: nil})

    {:ok, _invitation} = Organizations.invite_member(inviter, invitee.email)

    assert {:ok, :joined} = Organizations.accept_pending_invitation(invitee)

    assert {:ok, updated_invitee} = Accounts.get_user(invitee.id)
    assert updated_invitee.organization_id == organization.id
  end

  test "backfills the invitee's previously-orphaned document_jobs on join" do
    organization = organization_fixture()
    inviter = user_fixture(%{organization_id: organization.id})
    invitee = user_fixture(%{organization_id: nil})

    {:ok, orphaned} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "invite-backfill-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: invitee.id,
        organization_id: nil
      })

    {:ok, _invitation} = Organizations.invite_member(inviter, invitee.email)
    assert {:ok, :joined} = Organizations.accept_pending_invitation(invitee)

    assert {:ok, backfilled} = DocumentJobs.get_document_job(orphaned.id)
    assert backfilled.organization_id == organization.id
  end

  test "does nothing when there's no pending invite for that email" do
    user = user_fixture(%{organization_id: nil})

    assert {:ok, :no_pending_invite} = Organizations.accept_pending_invitation(user)

    assert {:ok, unchanged} = Accounts.get_user(user.id)
    assert unchanged.organization_id == nil
  end

  test "is idempotent — a user already in an organization is left alone" do
    user = user_fixture()
    original_organization_id = user.organization_id

    # Simulated directly via the repository, bypassing InviteMember's own
    # "already_in_an_organization" guard — this represents a pending
    # invite that predates the user joining a different organization by
    # some other path, not a state InviteMember itself can produce.
    other_organization = organization_fixture()
    other_inviter = user_fixture(%{organization_id: other_organization.id})

    {:ok, _invitation} =
      DocumentComplianceEngine.Organizations.Repository.insert_invitation(%{
        email: user.email,
        organization_id: other_organization.id,
        invited_by_user_id: other_inviter.id
      })

    assert {:ok, :already_in_organization} = Organizations.accept_pending_invitation(user)

    assert {:ok, unchanged} = Accounts.get_user(user.id)
    assert unchanged.organization_id == original_organization_id
  end
end
