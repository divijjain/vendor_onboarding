defmodule DocumentComplianceEngine.Organizations.Actions.InviteMemberTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.Organizations

  test "creates a pending invite for the given email" do
    inviter = user_fixture()

    assert {:ok, invitation} = Organizations.invite_member(inviter, "new@example.com")
    assert invitation.email == "new@example.com"
    assert invitation.organization_id == inviter.organization_id
    assert invitation.invited_by_user_id == inviter.id
  end

  test "rejects inviting an email that already belongs to an organization" do
    inviter = user_fixture()
    already_member = user_fixture()

    assert {:error, :already_in_an_organization} =
             Organizations.invite_member(inviter, already_member.email)
  end

  test "rejects a duplicate pending invite for the same email" do
    inviter = user_fixture()
    {:ok, _first} = Organizations.invite_member(inviter, "dup@example.com")

    assert {:error, changeset} = Organizations.invite_member(inviter, "dup@example.com")

    assert %{email: ["already has a pending invite"]} =
             DocumentComplianceEngine.DataCase.errors_on(changeset)
  end
end
