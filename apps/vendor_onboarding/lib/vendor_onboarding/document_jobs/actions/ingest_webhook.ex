defmodule VendorOnboarding.DocumentJobs.Actions.IngestWebhook do
  @moduledoc """
  Idempotency check, document storage, row creation, and job enqueue for
  an incoming vendor webhook payload. Called only via `VendorOnboarding.DocumentJobs.ingest_webhook/1`.
  """

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.DocumentJobs.{Idempotency, Repository}
  alias VendorOnboarding.DocumentJobs.Schema.DocumentJob
  alias VendorOnboarding.Storage

  @spec call(binary()) ::
          {:ok, VendorOnboarding.DocumentJobs.Schema.DocumentJob.t()}
          | {:error, :duplicate | :invalid_payload | Ecto.Changeset.t()}
  def call(raw_payload) when is_binary(raw_payload) do
    idempotency_key = Idempotency.hash(raw_payload)

    if Repository.get_by_idempotency_key(idempotency_key) do
      {:error, :duplicate}
    else
      with {:ok, documents} <- decode_payload(raw_payload),
           {:ok, document_paths} <- store_documents(idempotency_key, documents),
           {:ok, document_job} <-
             Repository.insert(%{
               idempotency_key: idempotency_key,
               document_paths: document_paths,
               # Every payload today is a fixed contract+W9 bundle — decode_payload/1
               # only knows how to parse that shape. Extending ingestion to accept a
               # document type per request means branching decode/store here too,
               # not just widening this field.
               document_type_slug: DocumentJob.default_document_type_slug()
             }) do
        AgentRuns.enqueue_trigger(document_job.id)
        {:ok, document_job}
      end
    end
  end

  defp decode_payload(raw_payload) do
    with {:ok, %{"contract" => contract_b64, "w9" => w9_b64}} <- Jason.decode(raw_payload),
         {:ok, contract} <- Base.decode64(contract_b64),
         {:ok, w9} <- Base.decode64(w9_b64) do
      {:ok, %{contract: contract, w9: w9}}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp store_documents(idempotency_key, %{contract: contract, w9: w9}) do
    with {:ok, contract_path} <- Storage.store("#{idempotency_key}/contract.pdf", contract),
         {:ok, w9_path} <- Storage.store("#{idempotency_key}/w9.pdf", w9) do
      {:ok, %{"contract" => contract_path, "w9" => w9_path}}
    end
  end
end
