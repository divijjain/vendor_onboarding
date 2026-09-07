defmodule DocumentComplianceEngine.Agent.ExtractionSchema do
  @moduledoc """
  Owns the shape of a document type's `extraction_schema` config, so the
  four modules that read it (`Extraction`, `Checks`, `Agent.Run`,
  `DocumentJobs.Actions.IngestWebhook`) never each reach into its
  structure by hand.

      %{
        "invoice" => %{
          "amount" => %{
            "type" => "monetary_amount",
            "description" => "The total amount payable on this invoice, ..."
          },
          ...
        }
      }

  A field's value used to be the bare type string (`"monetary_amount"`).
  It became a map so a field can carry a **semantic description** next to
  its type — a sentence saying what the field *means* on this kind of
  document, in the operator's words rather than the field name's.

  **What a description is for.** `invoice_number` is guessable from the
  name; `reference` on a payment advice is not, and neither is which of
  three dates on a purchase order counts as *the* delivery date. The
  description goes into the extraction prompt per field
  (`Extraction.prompt/2`), which is a real accuracy lever on exactly the
  fields whose names are ambiguous — the case where the model is otherwise
  guessing from a single word. `DocumentType.description` is the same idea
  one level up, for the document type as a whole.

  **A description says what a field means, never what it should look
  like.** Not a style preference — a measured failure. `tax_id`'s first
  description said "written as two digits, a hyphen, then seven digits",
  and the eval corpus caught `malformed-03` (whose W-9 states `123456789`
  with no hyphen) coming back as `12-3456789`: the model reformatted the
  value to match the description, overriding the prompt's "copy the value
  exactly as the document writes it" and turning a correctly-extracted
  malformed value into an ungrounded one. Everything a description puts
  in front of the model is an instruction, including the parts that only
  looked like context. Format belongs to the field's declared type and to
  `format`/`regex` rules, which *check* a value without ever telling the
  model what to produce.

  Descriptions are optional per field: an unambiguous field name is
  allowed to stand on its own rather than being padded with a sentence
  that restates it, and a document type written before this existed still
  loads. A field spec that isn't a map, or that names no type at all, is
  a config bug and is reported as one — see `validate/1`.
  """

  alias DocumentComplianceEngine.Agent.FieldTypes

  @type field_spec :: %{String.t() => String.t()}
  @type field_specs :: %{String.t() => field_spec()}
  @type t :: %{String.t() => field_specs()}

  @doc "Every document role the schema describes (`\"contract\"`, `\"w9\"`, …)."
  @spec roles(t()) :: [String.t()]
  def roles(schema), do: Map.keys(schema)

  @doc "The field specs for one role, or an empty map when the role is unknown."
  @spec fields(t(), String.t()) :: field_specs()
  def fields(schema, role), do: Map.get(schema, role, %{})

  @doc """
  The declared type of one field spec (`FieldTypes.known/0`), or `nil`
  when the spec is malformed — callers that only care about the type
  treat `nil` as "nothing declared" rather than crashing, since
  `validate/1` is what surfaces malformed config loudly and runs first.
  """
  @spec type(term()) :: String.t() | nil
  def type(%{"type" => type}) when is_binary(type), do: type
  def type(_spec), do: nil

  @doc "The field's semantic description, or `nil` when it has none."
  @spec description(term()) :: String.t() | nil
  def description(%{"description" => description})
      when is_binary(description) and description != "",
      do: description

  def description(_spec), do: nil

  @doc """
  Checks a whole `extraction_schema` before anything is spent on it.
  Returns the first offender:

    - `{:error, {:invalid_field_spec, role, field}}` — the spec isn't a
      map naming a type. The bare-string form this config used before
      descriptions existed lands here, which is deliberate: it reads as
      "this row was never migrated", the true diagnosis, rather than
      being silently accepted by a compatibility branch that would then
      have to live here forever.
    - `{:error, {:unknown_field_type, role, field, type}}` — the spec
      names a type outside `FieldTypes`' vocabulary.

  Both are config bugs, surfaced the same way `Checks` surfaces an
  unknown `format` validator name rather than being quietly degraded to
  untyped text.
  """
  @spec validate(t()) ::
          :ok
          | {:error, {:invalid_field_spec, String.t(), String.t()}}
          | {:error, {:unknown_field_type, String.t(), String.t(), term()}}
  def validate(schema) do
    Enum.reduce_while(schema, :ok, fn {role, field_specs}, :ok ->
      case Enum.find_value(field_specs, &field_error(role, &1)) do
        nil -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp field_error(role, {field, spec}) do
    case type(spec) do
      nil ->
        {:error, {:invalid_field_spec, role, field}}

      type ->
        unless FieldTypes.known?(type), do: {:error, {:unknown_field_type, role, field, type}}
    end
  end
end
