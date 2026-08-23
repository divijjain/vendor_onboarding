defmodule DocumentComplianceEngine.Organizations.Repository do
  @moduledoc """
  The only module that touches `DocumentComplianceEngine.Repo` for the
  `organizations` and `invitations` tables.
  """

  import Ecto.Query

  alias DocumentComplianceEngine.Repo
  alias DocumentComplianceEngine.Organizations.Schema.{Invitation, Organization}

  @spec insert_organization(map()) :: {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def insert_organization(attrs) do
    %Organization{}
    |> Organization.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec get_organization(pos_integer()) :: {:ok, Organization.t()} | {:error, :not_found}
  def get_organization(id) do
    case Repo.get(Organization, id) do
      nil -> {:error, :not_found}
      organization -> {:ok, organization}
    end
  end

  @spec insert_invitation(map()) :: {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def insert_invitation(attrs) do
    %Invitation{}
    |> Invitation.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc "The one pending (unaccepted) invite for this email, if any — at most one, by construction."
  @spec get_pending_invitation_by_email(String.t()) :: Invitation.t() | nil
  def get_pending_invitation_by_email(email) do
    normalized = email |> String.trim() |> String.downcase()

    Invitation
    |> where([i], i.email == ^normalized and is_nil(i.accepted_at))
    |> Repo.one()
  end

  @spec accept_invitation(Invitation.t()) :: {:ok, Invitation.t()} | {:error, Ecto.Changeset.t()}
  def accept_invitation(%Invitation{} = invitation) do
    invitation
    |> Invitation.accept_changeset()
    |> Repo.update()
  end

  @spec list_pending_by_organization(pos_integer()) :: [Invitation.t()]
  def list_pending_by_organization(organization_id) do
    Invitation
    |> where([i], i.organization_id == ^organization_id and is_nil(i.accepted_at))
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end
end
