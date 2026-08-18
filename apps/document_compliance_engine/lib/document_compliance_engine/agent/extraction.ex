defmodule DocumentComplianceEngine.Agent.Extraction do
  @moduledoc """
  Agent 1: one structured-output LLM call per document role, with the
  fields to extract driven by the document type's `extraction_schema`
  (a map of field name => Ecto type, e.g. `%{"company_name" => "string"}`)
  instead of a hardcoded response model per document type. Roles are
  extracted concurrently (`Task.async_stream`) to preserve the wall-clock
  behavior of what used to be two separate, independent Reactor steps.

  Uses Instructor's schemaless-Ecto response models (a plain
  `%{field_atom => type_atom}` map, not a compiled `Ecto.Schema` module) so
  the response shape can be built at runtime from `document_types` config.

  Overridable via application config so tests never need a real OpenAI key.

  `tax_id` gets a regex pre-filter ahead of the LLM call (see
  `maybe_regex_extract/2`): an EIN has a genuinely rigid, unambiguous format
  (`\\d{2}-\\d{7}`), so when it appears exactly once in the source text
  there's no real accuracy tradeoff to skipping the LLM for that one field —
  see `CONTEXT.md`'s dated entry for the research this is based on. Proven
  narrowly on `tax_id` first rather than generalized to every field, the
  same "prove it on one real case before building the abstraction" approach
  used for the document-type generalization itself.

  Two more guards, added after a real case (an uploaded résumé extracted
  as a fabricated invoice — see CONTEXT.md's dated entry) exposed that
  extraction had no way to admit a field wasn't there:

    - `shape_matches?/2`: a deterministic, zero-LLM-cost pre-filter. If a
      document type configures `shape_signals` for a role (a keyword list
      and minimum match count) and the source text doesn't hit that
      threshold, extraction is skipped entirely for that role — every
      field comes back `nil`, same as an honest "not present" answer.
    - The `"NOT_PRESENT"` sentinel in `complete/3`:
      Instructor's schemaless response model unconditionally runs
      `Ecto.Changeset.validate_required/2` on every field (no override hook
      exists for the map-based path this module uses), so the model is
      otherwise structurally forbidden from returning a blank/absent value
      — it has to invent *something* to satisfy the changeset. Prompting it
      to emit a fixed sentinel string instead, then converting that sentinel
      to `nil` after the fact, is the narrowest way to let the model be
      honest about absence without fighting Instructor's validation.

  Both converge on the same signal (`nil`), which `Checks.
  extraction_completeness_checks/1` turns into a halt when too much of a
  role's extraction comes back empty — one mechanism, two ways to reach it.

  **Confidence + source-location grounding.** Every field extracted via a
  real LLM call also comes back with a self-reported `confidence` (0.0-1.0)
  and `source_quote` (the verbatim span of the document the model says
  supports the value) — asked for as flat companion fields (`<field>_confidence`,
  `<field>_source_quote`) rather than a nested per-field structure, because
  Instructor's schemaless response model only supports flat Ecto types, not
  embedded maps (same "no compiled module" constraint that shapes
  `to_response_model/1`). A regex-resolved field (`tax_id`) gets a
  synthesized `confidence: 1.0` and `source_quote` equal to the matched
  text — it's deterministically grounded, no model guess involved. A
  shape-gate-skipped field gets `confidence: nil`/`source_quote: nil` — not
  "low confidence," genuinely not attempted. `Checks.low_confidence_checks/2`
  is the deterministic gate that acts on this; it's a *complementary*
  signal to `grounded_extraction_checks/3`'s external verbatim check, not a
  replacement — a model's self-reported confidence is exactly the kind of
  thing this project is generally skeptical of taking at face value (see
  the cross-provider judge, the deterministic checks elsewhere in this
  module), so it adds a check rather than becoming the primary one.
  """

  @tax_id_pattern ~r/\b\d{2}-\d{7}\b/
  @not_present_sentinel "NOT_PRESENT"

  @type field_metadata :: %{confidence: float() | nil, source_quote: String.t() | nil}

  @spec extract_all(
          %{String.t() => String.t()},
          %{String.t() => %{String.t() => String.t()}},
          %{String.t() => map()}
        ) ::
          {:ok, %{String.t() => map()}, %{String.t() => %{atom() => field_metadata()}}}
          | {:error, term()}
  def extract_all(documents, extraction_schema, shape_signals \\ %{}) do
    extraction_schema
    |> Task.async_stream(
      fn {role, field_types} ->
        case Map.fetch(documents, role) do
          {:ok, text} ->
            {role, extract_or_skip(role, field_types, text, shape_signals[role])}

          :error ->
            {role, {:error, {:missing_document, role}}}
        end
      end,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, %{}, %{}}, fn
      {:ok, {role, {:ok, fields, metadata}}}, {:ok, facc, macc} ->
        {:cont, {:ok, Map.put(facc, role, fields), Map.put(macc, role, metadata)}}

      {:ok, {_role, {:error, reason}}}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp extract_or_skip(role, field_types, text, shape) do
    if shape_matches?(text, shape) do
      extract(role, field_types, text)
    else
      not_attempted = %{confidence: nil, source_quote: nil}

      fields = Map.new(field_types, fn {field, _type} -> {String.to_atom(field), nil} end)

      metadata =
        Map.new(field_types, fn {field, _type} -> {String.to_atom(field), not_attempted} end)

      {:ok, fields, metadata}
    end
  end

  @doc """
  Deterministic, zero-LLM-cost shape gate for a role's source text.
  `shape` is `nil`/absent (unconfigured — always passes, opt-in per
  document type) or `%{"keywords" => [...], "min_matches" => n}`: passes
  when at least `min_matches` of `keywords` appear anywhere in the text.
  """
  @spec shape_matches?(String.t(), map() | nil) :: boolean()
  def shape_matches?(_text, nil), do: true
  def shape_matches?(_text, shape) when map_size(shape) == 0, do: true

  def shape_matches?(text, %{"keywords" => keywords, "min_matches" => min_matches}) do
    normalized = normalize(text)
    matches = Enum.count(keywords, &String.contains?(normalized, normalize(&1)))
    matches >= min_matches
  end

  defp normalize(text), do: text |> String.downcase() |> String.replace(~r/\s+/, " ")

  @spec extract(String.t(), %{String.t() => String.t()}, String.t()) ::
          {:ok, map(), %{atom() => field_metadata()}} | {:error, term()}
  def extract(role, field_types, text) do
    case maybe_regex_extract(field_types, text) do
      {:resolved, field, value, remaining} when map_size(remaining) == 0 ->
        {:ok, %{field => value}, %{field => regex_metadata(value)}}

      {:resolved, field, value, remaining} ->
        with {:ok, llm_fields, llm_metadata} <- complete_or_fake(role, remaining, text) do
          {:ok, Map.put(llm_fields, field, value),
           Map.put(llm_metadata, field, regex_metadata(value))}
        end

      :unresolved ->
        complete_or_fake(role, field_types, text)
    end
  end

  # A regex-resolved value is deterministically grounded — the matched
  # text *is* the source quote, no model self-assessment involved.
  defp regex_metadata(value), do: %{confidence: 1.0, source_quote: value}

  @doc """
  Pure, deterministic pre-filter for `tax_id`: resolves it directly when
  the EIN pattern appears exactly once in the source text (zero or
  multiple matches is ambiguous — never guess, fall through to the LLM
  for the whole field).
  """
  @spec maybe_regex_extract(%{String.t() => String.t()}, String.t()) ::
          {:resolved, atom(), String.t(), %{String.t() => String.t()}} | :unresolved
  def maybe_regex_extract(field_types, text) do
    if Map.has_key?(field_types, "tax_id") do
      case Regex.scan(@tax_id_pattern, text) do
        [[match]] -> {:resolved, :tax_id, match, Map.delete(field_types, "tax_id")}
        _ -> :unresolved
      end
    else
      :unresolved
    end
  end

  # The fake path (tests) keeps the original flat `%{field => value}`
  # response shape and knows nothing about confidence/source_quote — a
  # fake may optionally return `{:ok, fields, metadata}` to exercise that,
  # but `{:ok, fields}` (every existing fake) still works, just with no
  # metadata. Only the real Instructor path (`complete/3`) ever builds the
  # richer response model.
  defp complete_or_fake(role, field_types, text) do
    case Application.get_env(:document_compliance_engine, :agent_extract) do
      nil ->
        complete(role, field_types, text)

      fun ->
        response_model = to_response_model(field_types)

        case fun.(role, response_model, text) do
          {:ok, fields, metadata} -> {:ok, fields, metadata}
          {:ok, fields} -> {:ok, fields, %{}}
          error -> error
        end
    end
  end

  defp to_response_model(field_types) do
    Map.new(field_types, fn {field, "string"} -> {String.to_atom(field), :string} end)
  end

  defp to_metadata_response_model(field_types) do
    Enum.reduce(field_types, %{}, fn {field, "string"}, acc ->
      atom = String.to_atom(field)

      acc
      |> Map.put(atom, :string)
      |> Map.put(confidence_key(atom), :float)
      |> Map.put(quote_key(atom), :string)
    end)
  end

  defp confidence_key(field), do: :"#{field}_confidence"
  defp quote_key(field), do: :"#{field}_source_quote"

  defp prompt(role, field_types) do
    fields = field_types |> Map.keys() |> Enum.join(", ")

    "Extract the following fields from this #{role} document, verbatim as written: #{fields}. " <>
      "For each field named <field>, also provide <field>_confidence (a number from 0.0 to " <>
      "1.0 for how confident you are the value is correct and actually present in the " <>
      "document) and <field>_source_quote (the exact verbatim sentence or phrase from the " <>
      "document that supports the value — an empty string if the field is not present). " <>
      "If a field is not actually present in this document, output exactly the string " <>
      "\"#{@not_present_sentinel}\" for it — never guess or infer a value from unrelated content.\n\n"
  end

  defp complete(role, field_types, text) do
    response_model = to_metadata_response_model(field_types)

    case Instructor.chat_completion(
           model: "gpt-4o-mini",
           response_model: response_model,
           max_retries: 1,
           messages: [%{role: "user", content: prompt(role, field_types) <> text}]
         ) do
      {:ok, raw} ->
        {fields, metadata} = raw |> denote_missing() |> split_metadata(field_types)
        {:ok, fields, metadata}

      error ->
        error
    end
  end

  defp split_metadata(raw, field_types) do
    Enum.reduce(field_types, {%{}, %{}}, fn {field, "string"}, {fields, metadata} ->
      atom = String.to_atom(field)

      entry = %{
        confidence: Map.get(raw, confidence_key(atom)),
        source_quote: Map.get(raw, quote_key(atom))
      }

      {Map.put(fields, atom, Map.get(raw, atom)), Map.put(metadata, atom, entry)}
    end)
  end

  @doc """
  Converts the `#{@not_present_sentinel}` sentinel (see moduledoc) back to
  a real `nil`, so nothing downstream of extraction ever needs to know the
  sentinel exists — it's purely a workaround for Instructor's schemaless
  changeset otherwise refusing a blank field.
  """
  @spec denote_missing(map()) :: map()
  def denote_missing(fields) do
    Map.new(fields, fn
      {field, @not_present_sentinel} -> {field, nil}
      pair -> pair
    end)
  end
end
