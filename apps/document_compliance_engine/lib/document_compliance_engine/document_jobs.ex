defmodule DocumentComplianceEngine.DocumentJobs do
  @moduledoc """
  Public API for the document-ingestion domain. `defdelegate` only — no
  logic here. Owns the `document_jobs` table: what came in, its document
  type, and the aggregate status. See `DocumentComplianceEngine.AgentRuns` for the
  agent's extracted/validated output.
  """

  alias DocumentComplianceEngine.DocumentJobs.Actions.{
    IngestWebhook,
    ListWithLatestRun,
    ReadDocuments,
    ReadRawDocument
  }

  alias DocumentComplianceEngine.DocumentJobs.Repository

  defdelegate get_document_job(id), to: Repository, as: :get
  defdelegate get_document_job(id, organization_id), to: Repository, as: :get
  defdelegate get_document_job!(id, organization_id), to: Repository, as: :get!
  defdelegate get_document_jobs_by_ids(ids), to: Repository, as: :get_by_ids

  defdelegate list_document_job_ids_for_organization(organization_id),
    to: Repository,
    as: :list_ids_for_organization

  defdelegate list_document_jobs(organization_id, opts \\ []), to: Repository, as: :list

  defdelegate list_document_jobs_with_latest_run(organization_id, opts \\ []),
    to: ListWithLatestRun,
    as: :run

  defdelegate reload_document_job_row(id, organization_id), to: ListWithLatestRun, as: :reload
  defdelegate update_status(id, status), to: Repository
  defdelegate ingest_webhook(raw_payload), to: IngestWebhook, as: :call
  defdelegate read_documents(document_job), to: ReadDocuments, as: :call
  defdelegate read_raw_document(document_job, role), to: ReadRawDocument, as: :call

  defdelegate backfill_organization_id_for_owner(owner_user_id, organization_id),
    to: Repository
end
