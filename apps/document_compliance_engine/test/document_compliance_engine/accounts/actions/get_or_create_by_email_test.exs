defmodule DocumentComplianceEngine.Accounts.Actions.GetOrCreateByEmailTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.Accounts

  test "creates a new user on first sight of an email" do
    assert {:ok, user} = Accounts.get_or_create_user_by_email("new@example.com")
    assert user.email == "new@example.com"
    assert user.google_sub == nil
  end

  test "reuses the existing user on a repeat email" do
    assert {:ok, first} = Accounts.get_or_create_user_by_email("repeat@example.com")
    assert {:ok, second} = Accounts.get_or_create_user_by_email("repeat@example.com")
    assert first.id == second.id
  end
end
