defmodule DocumentComplianceEngine.AccountsFixtures do
  @moduledoc """
  Test helper for creating a `User` — every `document_jobs` row now
  requires an `owner_user_id`, so any test inserting one directly needs a
  real user to attach it to. `user_fixture/1` also auto-creates and joins
  a fresh organization by default, since every gated route now also
  requires `organization_id` — two independent `user_fixture()` calls
  land in two different organizations by construction, preserving the
  existing "isolated by default" test semantics without every test
  needing to know about organizations explicitly.
  """

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.Organizations.Repository, as: OrganizationsRepository

  @doc """
  Creates (or reuses) a user for the given email, unique per call by
  default. Joins a fresh organization unless `:organization_id` is given
  (pass an existing id to put two users in the same organization, or
  `nil` for a user with no organization yet — the pre-`:ensure_organization`
  bootstrap state).
  """
  def user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email, "user-#{System.unique_integer([:positive])}@example.com")
    {:ok, user} = Accounts.get_or_create_user_by_email(email)

    case Map.get(attrs, :organization_id, :auto) do
      :auto ->
        {:ok, user} = Accounts.set_organization_id(user, organization_fixture().id)
        user

      nil ->
        user

      organization_id ->
        {:ok, user} = Accounts.set_organization_id(user, organization_id)
        user
    end
  end

  @doc "Creates a bare organization — no members."
  def organization_fixture(attrs \\ %{}) do
    name = Map.get(attrs, :name, "Org #{System.unique_integer([:positive])}")
    {:ok, organization} = OrganizationsRepository.insert_organization(%{name: name})
    organization
  end
end
