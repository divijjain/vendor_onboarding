defmodule VendorOnboarding.DocumentTypes.Schema.DocumentType do
  @moduledoc """
  A configurable document type: what a `DocumentJob` claims to be (its
  `document_type_slug`), what fields extraction is meant to produce for it,
  and which validation tools apply. `extraction_schema`/`validation_rules`
  are stored but not yet read by the agent pipeline — `OnboardingReactor`
  still runs today's fixed contract+W9 extraction regardless of the
  document type on the job. See CONTEXT.md's dated entry: this table is a
  data-model generalization step, not a rewrite of the agent brain.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "document_types" do
    field :slug, :string
    field :name, :string
    field :extraction_schema, :map, default: %{}
    field :validation_rules, {:array, :map}, default: []

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          slug: String.t() | nil,
          name: String.t() | nil,
          extraction_schema: map(),
          validation_rules: [map()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for creating or updating a document type."
  def changeset(document_type, attrs) do
    document_type
    |> cast(attrs, [:slug, :name, :extraction_schema, :validation_rules])
    |> validate_required([:slug, :name])
    |> unique_constraint(:slug)
  end
end
