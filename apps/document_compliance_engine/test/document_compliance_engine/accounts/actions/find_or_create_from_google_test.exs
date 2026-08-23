defmodule DocumentComplianceEngine.Accounts.Actions.FindOrCreateFromGoogleTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.Accounts

  defp google_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        email: "google@example.com",
        google_sub: "google-sub-1",
        name: "Someone",
        avatar_url: nil
      },
      overrides
    )
  end

  test "creates a brand new user when neither google_sub nor email is known" do
    assert {:ok, user} = Accounts.find_or_create_user_from_google(google_attrs())
    assert user.email == "google@example.com"
    assert user.google_sub == "google-sub-1"
  end

  test "returns the same user on a repeat login (matched by google_sub)" do
    assert {:ok, first} = Accounts.find_or_create_user_from_google(google_attrs())
    assert {:ok, second} = Accounts.find_or_create_user_from_google(google_attrs())
    assert first.id == second.id
  end

  test "links a pre-provisioned (webhook owner_email) user instead of creating a duplicate" do
    {:ok, pre_provisioned} = Accounts.get_or_create_user_by_email("pre-provisioned@example.com")
    assert pre_provisioned.google_sub == nil

    assert {:ok, linked} =
             Accounts.find_or_create_user_from_google(
               google_attrs(%{email: "pre-provisioned@example.com", google_sub: "new-sub"})
             )

    assert linked.id == pre_provisioned.id
    assert linked.google_sub == "new-sub"
  end

  test "updates name/avatar_url on a repeat login" do
    {:ok, _first} = Accounts.find_or_create_user_from_google(google_attrs(%{name: "Old Name"}))

    assert {:ok, updated} =
             Accounts.find_or_create_user_from_google(google_attrs(%{name: "New Name"}))

    assert updated.name == "New Name"
  end
end
