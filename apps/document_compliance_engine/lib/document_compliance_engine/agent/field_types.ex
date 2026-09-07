defmodule DocumentComplianceEngine.Agent.FieldTypes do
  @moduledoc """
  The declared-type vocabulary for a document type's `extraction_schema`
  (`%{role => %{field => type}}`).

  Every field's type used to be the literal `"string"` — the only value the
  table was ever seeded with, and the only one `Extraction` could handle
  (it pattern-matched the literal, so anything else was a
  `FunctionClauseError`). A declared type gives the extraction prompt
  something concrete to ask for per field, and gives a format check
  something to check *against* — there is nothing to validate the shape of
  a value that was only ever declared "text".

  **A declared type never changes the wire type of an extracted value —
  every field still comes back from the model as a verbatim string.** That
  is deliberate and load-bearing, not an unfinished edge: `Checks.
  grounded_extraction_checks/3` proves a value against its source document
  by substring match, so an `amount` coerced to `1234.56` from the
  document's `"1,234.56"` would stop being findable in the text it came
  from and would be reported as a possible hallucination. The type says
  *what to look for*, never *how to write it down*.

  **What is a type, and what is a `validation_rules` entry.** A type
  describes how a value is written, and is declared once on the field. An
  identifier scheme — an EIN, IBAN, VAT ID, VIN, card number — is instead a
  claim about what a value *is*, is issuer- or jurisdiction-specific, and
  stays `"string"` plus an opt-in `format`/`regex`/`mcp_tool` rule naming
  the sharper check. That is exactly where `tax_id` deliberately still
  sits: `"string"`, with the EIN regex pre-filter in `Extraction` and the
  `validate_tax_id` MCP rule in `Checks` doing the real work.

  Each type name here other than `"string"` is deliberately *also* a
  `FormatValidators` validator name (enforced at compile time below) —
  that's what keeps this vocabulary closed and non-arbitrary rather than a
  list of adjectives, and it's what will let a format check be derived from
  a declared type without a second lookup table. Only `monetary_amount` and
  `date` are exercised by the two seeded document types today; the rest are
  the remainder of that same closed set.

  That invariant earned its keep immediately: `invoice.amount` was first
  typed `number`, and the scanned eval fixtures (which write `"$1,275.00"`
  where the plain-text ones write `"1,000.00"`) failed against a bare
  number check. Because a type has to name a real validator, the gap
  surfaced as "there is no validator for what an invoice amount actually
  is" rather than as a plausible-looking type that quietly checked the
  wrong thing — `monetary_amount` was added to `FormatValidators` and the
  field retyped.

  This module owns the vocabulary itself; `ExtractionSchema` owns the
  config shape a type is declared in, and is where a whole schema's types
  get validated before a run spends anything on them. An unrecognized
  type is a config bug, not a failed check — surfaced loudly, the same way
  `Checks` surfaces an unknown `format` validator name, rather than being
  silently treated as free text, which would let an operator believe a
  field is typed when nothing reads that type.
  """

  alias DocumentComplianceEngine.Agent.FormatValidators

  # `type => prompt hint`. `"string"` maps to `nil` on purpose: a field with
  # no real type declared gets no parenthetical in the prompt, so a document
  # type that declares nothing but strings produces a byte-identical prompt
  # to the untyped one it had before — the existing eval numbers still
  # describe it.
  @types %{
    "string" => nil,
    "number" => "a number",
    "monetary_amount" => "a monetary amount, with any currency symbol the document writes",
    "date" => "a date",
    "currency" => "a currency, such as the code EUR or the symbol $",
    "email" => "an email address",
    "phone" => "a phone number",
    "uri" => "a URL"
  }

  # See the moduledoc: a type name is a FormatValidators validator name, or
  # "string" (which has no shape to check). Checked here so the two
  # vocabularies can't silently drift apart.
  for {type, _hint} <- @types, type != "string" do
    unless type in FormatValidators.known() do
      raise "field type #{inspect(type)} has no FormatValidators counterpart"
    end
  end

  @doc "Every type an `extraction_schema` field may declare."
  @spec known() :: [String.t()]
  def known, do: @types |> Map.keys() |> Enum.sort()

  @doc "Whether `type` is part of the vocabulary."
  @spec known?(term()) :: boolean()
  def known?(type), do: is_map_key(@types, type)

  @doc """
  The prompt phrasing for a type, or `nil` for `"string"` and for anything
  outside the vocabulary — callers render no type hint at all in those
  cases rather than inventing one.
  """
  @spec describe(term()) :: String.t() | nil
  def describe(type) when is_binary(type), do: Map.get(@types, type)
  def describe(_type), do: nil

  @doc """
  The `FormatValidators` validator that checks a value of this type, or
  `nil` when there is nothing to check — `"string"` (free text has no shape)
  and anything outside the vocabulary.

  The mapping is name identity, and the compile-time check above is what
  keeps it that way: a type is *defined* as a format validator plus prompt
  phrasing, so this is a lookup rather than a second table that could
  disagree with the first.
  """
  @spec format_validator(term()) :: String.t() | nil
  def format_validator("string"), do: nil
  def format_validator(type) when is_binary(type), do: if(known?(type), do: type)
  def format_validator(_type), do: nil
end
