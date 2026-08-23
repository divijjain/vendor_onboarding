defmodule DocumentComplianceEngine.Organizations.Schema.Organization do
  @moduledoc """
  A business customer's shared account — the isolation boundary for
  `document_jobs` once a `User` has joined one. See
  `DocumentComplianceEngine.Organizations` for how a user gets attached.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "organizations" do
    field :name, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          name: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def create_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
