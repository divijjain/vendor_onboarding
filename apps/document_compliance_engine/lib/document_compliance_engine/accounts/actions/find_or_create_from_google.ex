defmodule DocumentComplianceEngine.Accounts.Actions.FindOrCreateFromGoogle do
  @moduledoc """
  Resolves a completed Google login to a `User`. Looks up by `google_sub`
  first (an already-linked account); if that's new, looks up by email —
  a webhook's `owner_email` may have pre-provisioned this exact address
  before its owner ever signed in — and **links** that row (sets
  `google_sub`/`name`/`avatar_url` on it) rather than inserting a
  duplicate. Only creates a brand new row when neither match exists.
  """

  alias DocumentComplianceEngine.Accounts.Repository

  @spec call(map()) :: {:ok, DocumentComplianceEngine.Accounts.Schema.User.t()} | {:error, term()}
  def call(%{email: email, google_sub: google_sub} = attrs) do
    attrs = Map.take(attrs, [:email, :google_sub, :name, :avatar_url])

    case Repository.get_by_google_sub(google_sub) do
      nil -> find_by_email_or_create(email, attrs)
      user -> Repository.link_google(user, attrs)
    end
  end

  defp find_by_email_or_create(email, attrs) do
    case Repository.get_by_email(email) do
      nil -> Repository.insert_from_google(attrs)
      user -> Repository.link_google(user, attrs)
    end
  end
end
