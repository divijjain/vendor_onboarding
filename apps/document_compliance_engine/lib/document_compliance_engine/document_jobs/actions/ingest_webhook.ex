defmodule DocumentComplianceEngine.DocumentJobs.Actions.IngestWebhook do
  @moduledoc """
  Idempotency check, document-type resolution, document storage, row
  creation, and job enqueue for an incoming webhook payload. Payload shape
  is `{"document_type_slug": ..., "documents": {role => base64, ...}}` —
  the `documents` map's keys must exactly match the resolved document
  type's `extraction_schema` roles. Called only via
  `DocumentComplianceEngine.DocumentJobs.ingest_webhook/1`.
  """

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs.{Idempotency, Repository}
  alias DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob
  alias DocumentComplianceEngine.DocumentTypes
  alias DocumentComplianceEngine.Storage

  @spec call(binary()) ::
          {:ok, DocumentJob.t()}
          | {:error, :duplicate | :invalid_payload | :unknown_document_type | Ecto.Changeset.t()}
  def call(raw_payload) when is_binary(raw_payload) do
    idempotency_key = Idempotency.hash(raw_payload)

    if Repository.get_by_idempotency_key(idempotency_key) do
      {:error, :duplicate}
    else
      with {:ok, document_type_slug, documents} <- decode_payload(raw_payload),
           {:ok, document_type} <- fetch_document_type(document_type_slug),
           :ok <- validate_roles(documents, document_type.extraction_schema),
           {:ok, document_paths} <- store_documents(idempotency_key, documents),
           {:ok, document_job} <-
             Repository.insert(%{
               idempotency_key: idempotency_key,
               document_paths: document_paths,
               document_type_slug: document_type.slug
             }) do
        AgentRuns.enqueue_trigger(document_job.id)
        {:ok, document_job}
      end
    end
  end

  defp decode_payload(raw_payload) do
    with {:ok, %{"document_type_slug" => slug, "documents" => documents}}
         when is_map(documents) <- Jason.decode(raw_payload),
         {:ok, decoded} <- decode_documents(documents) do
      {:ok, slug, decoded}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp decode_documents(documents) do
    Enum.reduce_while(documents, {:ok, %{}}, fn {role, b64}, {:ok, acc} ->
      case Base.decode64(b64) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, role, bytes)}}
        :error -> {:halt, {:error, :invalid_payload}}
      end
    end)
  end

  defp fetch_document_type(slug) do
    case DocumentTypes.get_document_type_by_slug(slug) do
      nil -> {:error, :unknown_document_type}
      document_type -> {:ok, document_type}
    end
  end

  defp validate_roles(documents, extraction_schema) do
    expected = extraction_schema |> Map.keys() |> MapSet.new()
    actual = documents |> Map.keys() |> MapSet.new()

    if MapSet.equal?(expected, actual), do: :ok, else: {:error, :invalid_payload}
  end

  defp store_documents(idempotency_key, documents) do
    Enum.reduce_while(documents, {:ok, %{}}, fn {role, bytes}, {:ok, acc} ->
      case Storage.store("#{idempotency_key}/#{role}.pdf", bytes) do
        {:ok, path} -> {:cont, {:ok, Map.put(acc, role, path)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
