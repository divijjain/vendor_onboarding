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
  """

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
