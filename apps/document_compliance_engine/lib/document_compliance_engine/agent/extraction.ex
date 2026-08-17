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
  """

  @tax_id_pattern ~r/\b\d{2}-\d{7}\b/

  @spec extract_all(%{String.t() => String.t()}, %{String.t() => %{String.t() => String.t()}}) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def extract_all(documents, extraction_schema) do
    extraction_schema
    |> Task.async_stream(
      fn {role, field_types} ->
        case Map.fetch(documents, role) do
          {:ok, text} -> {role, extract(role, field_types, text)}
          :error -> {role, {:error, {:missing_document, role}}}
        end
      end,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {role, {:ok, fields}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, role, fields)}}
      {:ok, {_role, {:error, reason}}}, _acc -> {:halt, {:error, reason}}
    end)
  end

  @spec extract(String.t(), %{String.t() => String.t()}, String.t()) ::
          {:ok, map()} | {:error, term()}
  def extract(role, field_types, text) do
    case maybe_regex_extract(field_types, text) do
      {:resolved, field, value, remaining} when map_size(remaining) == 0 ->
        {:ok, %{field => value}}

      {:resolved, field, value, remaining} ->
        with {:ok, llm_fields} <- complete_or_fake(role, remaining, text) do
          {:ok, Map.put(llm_fields, field, value)}
        end

      :unresolved ->
        complete_or_fake(role, field_types, text)
    end
  end

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

  defp complete_or_fake(role, field_types, text) do
    response_model = to_response_model(field_types)

    case Application.get_env(:document_compliance_engine, :agent_extract) do
      nil -> complete(response_model, prompt(role, field_types) <> text)
      fun -> fun.(role, response_model, text)
    end
  end

  defp to_response_model(field_types) do
    Map.new(field_types, fn {field, "string"} -> {String.to_atom(field), :string} end)
  end

  defp prompt(role, field_types) do
    fields = field_types |> Map.keys() |> Enum.join(", ")
    "Extract the following fields from this #{role} document, verbatim as written: #{fields}.\n\n"
  end

  defp complete(response_model, content) do
    Instructor.chat_completion(
      model: "gpt-4o-mini",
      response_model: response_model,
      max_retries: 1,
      messages: [%{role: "user", content: content}]
    )
  end
end
