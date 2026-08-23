defmodule DocumentComplianceEngine.Accounts.Repository do
  @moduledoc """
  The only module that touches `DocumentComplianceEngine.Repo` for the
  `users` table.
  """

  import Ecto.Query

  alias DocumentComplianceEngine.Repo
  alias DocumentComplianceEngine.Accounts.Schema.User

  @spec get(pos_integer()) :: {:ok, User.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @spec get_by_email(String.t()) :: User.t() | nil
  def get_by_email(email) do
    Repo.get_by(User, email: normalize_email(email))
  end

  @spec get_by_google_sub(String.t()) :: User.t() | nil
  def get_by_google_sub(google_sub) do
    Repo.get_by(User, google_sub: google_sub)
  end

  @spec insert_by_email(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def insert_by_email(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @spec link_google(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def link_google(%User{} = user, attrs) do
    user
    |> User.google_changeset(attrs)
    |> Repo.update()
  end

  @spec insert_from_google(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def insert_from_google(attrs) do
    %User{}
    |> User.google_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Called only by `Organizations`'s actions — writes a field `Accounts` owns on their behalf."
  @spec set_organization_id(User.t(), pos_integer()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_organization_id(%User{} = user, organization_id) do
    user
    |> User.organization_changeset(%{organization_id: organization_id})
    |> Repo.update()
  end

  @doc "Every member of an organization, for the team/members page."
  @spec list_by_organization_id(pos_integer()) :: [User.t()]
  def list_by_organization_id(organization_id) do
    User
    |> where(organization_id: ^organization_id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
