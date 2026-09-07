defmodule DocumentComplianceEngine.DocumentTypes.Schema.DocumentType do
  @moduledoc """
  A configurable document type: what a `DocumentJob` claims to be (its
  `document_type_slug`), what fields extraction is meant to produce for it,
  and which validation rules apply. `extraction_schema` is a map of
  document role => field name => field spec (`Agent.ExtractionSchema`),
  each spec naming a declared type (`Agent.FieldTypes.known/0` —
  `"string"`, `"number"`, `"date"`, …; the type drives how
  `Extraction.extract_all/3` asks for the field, never how the value is
  written back) and optionally a semantic description of what the field
  means on this kind of document. `description` is the same thing one
  level up: what this kind of document *is*, written to be reasoned over
  and not just read.
  `validation_rules` is a list of typed rule maps (`entity_match` or
  `mcp_tool`) interpreted by `Agent.Checks.validate_all/4`. `shape_signals`
  is an optional per-role config (`%{"keywords" => [...], "min_matches" =>
  n}`) `Extraction.extract_all/3` checks before spending an LLM call on a
  role — a role with no entry is unrestricted. All three are resolved by
  `Agent.Run` and passed into `Agent.DocumentReactor` as plain inputs —
  genuinely read by the agent pipeline, not just stored config. See
  CONTEXT.md's dated entries for the generalization history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "document_types" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :extraction_schema, :map, default: %{}
    field :validation_rules, {:array, :map}, default: []
    field :shape_signals, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          slug: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          extraction_schema: map(),
          validation_rules: [map()],
          shape_signals: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for creating or updating a document type."
  def changeset(document_type, attrs) do
    document_type
    |> cast(attrs, [
      :slug,
      :name,
      :description,
      :extraction_schema,
      :validation_rules,
      :shape_signals
    ])
    |> validate_required([:slug, :name])
    |> unique_constraint(:slug)
  end
end
