defmodule DocumentComplianceEngine.Accounts.Schema.User do
  @moduledoc """
  A signed-in (or pre-provisioned) account. `google_sub` is `nil` until
  this email's first successful Google login — a webhook's `owner_email`
  can create a row with only `email` set, well before anyone ever signs
  in with that address.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :google_sub, :string
    field :name, :string
    field :avatar_url, :string
    field :organization_id, :integer

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          email: String.t() | nil,
          google_sub: String.t() | nil,
          name: String.t() | nil,
          avatar_url: String.t() | nil,
          organization_id: pos_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for pre-provisioning a user by email alone (webhook/MCP/manual-upload owner resolution)."
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:email)
  end

  @doc "Changeset for linking (or updating) a Google login onto an existing or new row."
  def google_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :google_sub, :name, :avatar_url])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :google_sub])
    |> unique_constraint(:email)
    |> unique_constraint(:google_sub)
  end

  @doc """
  Changeset for joining an organization — either by creating one (the
  first person at a business customer) or by accepting a pending invite.
  Deliberately its own changeset, separate from `email_changeset`/
  `google_changeset`, so neither of those can ever accidentally cast
  `organization_id`.
  """
  def organization_changeset(user, attrs) do
    cast(user, attrs, [:organization_id])
  end

  defp normalize_email(nil), do: nil
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
