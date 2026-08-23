defmodule DocumentComplianceEngine.Organizations.Schema.Invitation do
  @moduledoc """
  A pending (or already-accepted) invite to join an organization by
  email. `accepted_at` stays `nil` until a matching Google login accepts
  it — see `Organizations.Actions.AcceptPendingInvitation`. Plain integer
  `organization_id`/`invited_by_user_id`, no `references()`, same
  convention as every other cross-context id in this app.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "invitations" do
    field :email, :string
    field :organization_id, :integer
    field :invited_by_user_id, :integer
    field :accepted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          email: String.t() | nil,
          organization_id: pos_integer() | nil,
          invited_by_user_id: pos_integer() | nil,
          accepted_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for creating a new invite."
  def create_changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :organization_id, :invited_by_user_id])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :organization_id, :invited_by_user_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> unique_constraint(:email,
      name: :invitations_email_pending_index,
      message: "already has a pending invite"
    )
  end

  @doc "Changeset for accepting an invite — stamps accepted_at, nothing else changes."
  def accept_changeset(invitation) do
    change(invitation, accepted_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp normalize_email(nil), do: nil
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
