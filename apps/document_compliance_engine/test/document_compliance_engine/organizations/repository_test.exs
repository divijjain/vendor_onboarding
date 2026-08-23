defmodule DocumentComplianceEngine.Organizations.RepositoryTest do
  use DocumentComplianceEngine.DataCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.Organizations.Repository

  describe "insert_organization/1" do
    test "creates an organization with a name" do
      assert {:ok, organization} = Repository.insert_organization(%{name: "Acme Corp"})
      assert organization.name == "Acme Corp"
    end

    test "requires a name" do
      assert {:error, changeset} = Repository.insert_organization(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get_organization/1" do
    test "returns {:ok, organization} for an existing id" do
      {:ok, organization} = Repository.insert_organization(%{name: "Acme Corp"})
      assert {:ok, found} = Repository.get_organization(organization.id)
      assert found.id == organization.id
    end

    test "returns {:error, :not_found} for a missing id" do
      assert Repository.get_organization(-1) == {:error, :not_found}
    end
  end

  describe "insert_invitation/1" do
    test "creates a pending invite" do
      organization = organization_fixture()
      inviter = user_fixture(%{organization_id: organization.id})

      assert {:ok, invitation} =
               Repository.insert_invitation(%{
                 email: "Invitee@Example.com",
                 organization_id: organization.id,
                 invited_by_user_id: inviter.id
               })

      assert invitation.email == "invitee@example.com"
      assert invitation.accepted_at == nil
    end

    test "enforces one pending invite per email" do
      organization = organization_fixture()
      inviter = user_fixture(%{organization_id: organization.id})

      attrs = %{
        email: "dup@example.com",
        organization_id: organization.id,
        invited_by_user_id: inviter.id
      }

      assert {:ok, _} = Repository.insert_invitation(attrs)
      assert {:error, changeset} = Repository.insert_invitation(attrs)
      assert %{email: ["already has a pending invite"]} = errors_on(changeset)
    end

    test "allows a new invite for an email whose previous invite was already accepted" do
      organization = organization_fixture()
      inviter = user_fixture(%{organization_id: organization.id})

      attrs = %{
        email: "again@example.com",
        organization_id: organization.id,
        invited_by_user_id: inviter.id
      }

      {:ok, first} = Repository.insert_invitation(attrs)
      {:ok, _accepted} = Repository.accept_invitation(first)

      assert {:ok, _second} = Repository.insert_invitation(attrs)
    end
  end

  describe "get_pending_invitation_by_email/1" do
    test "finds the pending invite, case-insensitively" do
      organization = organization_fixture()
      inviter = user_fixture(%{organization_id: organization.id})

      {:ok, invitation} =
        Repository.insert_invitation(%{
          email: "case@example.com",
          organization_id: organization.id,
          invited_by_user_id: inviter.id
        })

      assert %{id: id} = Repository.get_pending_invitation_by_email("CASE@example.com")
      assert id == invitation.id
    end

    test "returns nil once accepted" do
      organization = organization_fixture()
      inviter = user_fixture(%{organization_id: organization.id})

      {:ok, invitation} =
        Repository.insert_invitation(%{
          email: "accept-me@example.com",
          organization_id: organization.id,
          invited_by_user_id: inviter.id
        })

      {:ok, _} = Repository.accept_invitation(invitation)

      assert Repository.get_pending_invitation_by_email("accept-me@example.com") == nil
    end

    test "returns nil when there's no invite at all" do
      assert Repository.get_pending_invitation_by_email("nobody@example.com") == nil
    end
  end

  describe "list_pending_by_organization/1" do
    test "lists only pending invites for that organization" do
      organization = organization_fixture()
      other_organization = organization_fixture()
      inviter = user_fixture(%{organization_id: organization.id})

      {:ok, pending} =
        Repository.insert_invitation(%{
          email: "pending@example.com",
          organization_id: organization.id,
          invited_by_user_id: inviter.id
        })

      {:ok, accepted} =
        Repository.insert_invitation(%{
          email: "accepted@example.com",
          organization_id: organization.id,
          invited_by_user_id: inviter.id
        })

      {:ok, _} = Repository.accept_invitation(accepted)

      {:ok, _other_org_invite} =
        Repository.insert_invitation(%{
          email: "elsewhere@example.com",
          organization_id: other_organization.id,
          invited_by_user_id: inviter.id
        })

      assert [found] = Repository.list_pending_by_organization(organization.id)
      assert found.id == pending.id
    end
  end
end
