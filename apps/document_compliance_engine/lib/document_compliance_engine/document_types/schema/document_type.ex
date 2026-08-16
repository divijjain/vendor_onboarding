defmodule DocumentComplianceEngine.DocumentTypes.Schema.DocumentType do
  @moduledoc """
  A configurable document type: what a `DocumentJob` claims to be (its
  `document_type_slug`), what fields extraction is meant to produce for it,
  and which validation rules apply. `extraction_schema` is a map of
  document role => field name => Ecto type (currently only `"string"`);
  `validation_rules` is a list of typed rule maps (`entity_match` or
  `mcp_tool`) interpreted by `Agent.Checks.validate_all/2`. Both are
  resolved by `Agent.Run` and passed into `Agent.DocumentReactor` as plain
  inputs — genuinely read by the agent pipeline, not just stored config.
  See CONTEXT.md's dated entries for the generalization history.
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
