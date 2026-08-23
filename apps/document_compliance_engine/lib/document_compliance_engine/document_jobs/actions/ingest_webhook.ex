defmodule DocumentComplianceEngine.DocumentJobs.Actions.IngestWebhook do
  @moduledoc """
  Idempotency check, document-type resolution, document storage, row
  creation, and job enqueue for an incoming webhook payload. Payload shape
  is `{"document_type_slug": ..., "documents": {role => base64, ...}, "owner_email": ...}` —
  the `documents` map's keys must exactly match the resolved document
  type's `extraction_schema` roles. `owner_email` is required on every
  call site (the real webhook, the MCP `trigger_run` tool, and the
  dashboard's manual-upload form, which injects the signed-in user's own
  email) — it's resolved to a `User` via `Accounts.get_or_create_user_by_email/1`
  and stamped as the new row's `owner_user_id`, auto-provisioning a
  not-yet-logged-in account if this is the first time that email has been
  seen. `organization_id` is stamped alongside it from that owner's own
  `organization_id` — genuinely `nil` whenever the owner hasn't joined an
  organization yet (`Organizations.Actions.JoinOrganization` backfills
  this column once they do). Called only via
  `DocumentComplianceEngine.DocumentJobs.ingest_webhook/1`.
  """

  alias DocumentComplianceEngine.Accounts
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
      with {:ok, document_type_slug, documents, owner_email} <- decode_payload(raw_payload),
           {:ok, document_type} <- fetch_document_type(document_type_slug),
           :ok <- validate_roles(documents, document_type.extraction_schema),
           {:ok, owner} <- get_or_create_owner(owner_email),
           {:ok, document_paths} <- store_documents(idempotency_key, documents),
           {:ok, document_job} <-
             Repository.insert(%{
               idempotency_key: idempotency_key,
               document_paths: document_paths,
               document_type_slug: document_type.slug,
               owner_user_id: owner.id,
               organization_id: owner.organization_id
             }) do
        AgentRuns.enqueue_trigger(document_job.id)
        {:ok, document_job}
      end
    end
  end

  defp decode_payload(raw_payload) do
    with {:ok,
          %{
            "document_type_slug" => slug,
            "documents" => documents,
            "owner_email" => owner_email
          }}
         when is_map(documents) and is_binary(owner_email) <- Jason.decode(raw_payload),
         {:ok, decoded} <- decode_documents(documents) do
      {:ok, slug, decoded, owner_email}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp get_or_create_owner(owner_email) do
    case Accounts.get_or_create_user_by_email(owner_email) do
      {:ok, user} -> {:ok, user}
      {:error, _reason} -> {:error, :invalid_payload}
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
