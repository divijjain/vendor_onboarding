defmodule DocumentComplianceEngine.Accounts.RepositoryTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.Accounts.Repository

  describe "insert_by_email/1" do
    test "creates a user with no google_sub" do
      assert {:ok, user} = Repository.insert_by_email(%{email: "Foo@Example.com"})
      assert user.email == "foo@example.com"
      assert user.google_sub == nil
    end

    test "requires a well-formed email" do
      assert {:error, changeset} = Repository.insert_by_email(%{email: "not-an-email"})
      assert %{email: ["has invalid format"]} = errors_on(changeset)
    end

    test "enforces a unique email, case-insensitively" do
      assert {:ok, _} = Repository.insert_by_email(%{email: "dup@example.com"})
      assert {:error, changeset} = Repository.insert_by_email(%{email: "DUP@example.com"})
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "get_by_email/1" do
    test "finds a user regardless of case" do
      {:ok, user} = Repository.insert_by_email(%{email: "case@example.com"})
      assert %{id: id} = Repository.get_by_email("CASE@example.com")
      assert id == user.id
    end

    test "returns nil when no user matches" do
      assert Repository.get_by_email("missing@example.com") == nil
    end
  end

  describe "get_by_google_sub/1" do
    test "finds a user linked to that sub" do
      {:ok, user} = Repository.insert_from_google(%{email: "g@example.com", google_sub: "sub-1"})
      assert %{id: id} = Repository.get_by_google_sub("sub-1")
      assert id == user.id
    end

    test "returns nil when no user matches" do
      assert Repository.get_by_google_sub("missing-sub") == nil
    end
  end

  describe "insert_from_google/1" do
    test "requires both email and google_sub" do
      assert {:error, changeset} =
               Repository.insert_from_google(%{email: "only-email@example.com"})

      assert %{google_sub: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces a unique google_sub" do
      assert {:ok, _} =
               Repository.insert_from_google(%{email: "a@example.com", google_sub: "dup-sub"})

      assert {:error, changeset} =
               Repository.insert_from_google(%{email: "b@example.com", google_sub: "dup-sub"})

      assert %{google_sub: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "link_google/2" do
    test "sets google_sub/name/avatar_url on an existing (pre-provisioned) user" do
      {:ok, user} = Repository.insert_by_email(%{email: "linkme@example.com"})

      assert {:ok, linked} =
               Repository.link_google(user, %{
                 email: "linkme@example.com",
                 google_sub: "new-sub",
                 name: "Linked Person",
                 avatar_url: "https://example.com/a.png"
               })

      assert linked.id == user.id
      assert linked.google_sub == "new-sub"
      assert linked.name == "Linked Person"
    end
  end

  describe "get/1" do
    test "returns {:error, :not_found} for a missing id" do
      assert Repository.get(-1) == {:error, :not_found}
    end
  end
end
