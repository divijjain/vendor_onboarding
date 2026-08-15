defmodule VendorOnboarding.DocumentJobs do
  @moduledoc """
  Public API for the document-ingestion domain. `defdelegate` only — no
  logic here. Owns the `document_jobs` table: what came in, its document
  type, and the aggregate status. See `VendorOnboarding.AgentRuns` for the
  agent's extracted/validated output.
  """

  alias VendorOnboarding.DocumentJobs.Actions.{IngestWebhook, ListWithLatestRun}
  alias VendorOnboarding.DocumentJobs.Repository

  defdelegate get_document_job(id), to: Repository, as: :get
  defdelegate get_document_job!(id), to: Repository, as: :get!
  defdelegate list_document_jobs(opts \\ []), to: Repository, as: :list
  defdelegate list_document_jobs_with_latest_run(opts \\ []), to: ListWithLatestRun, as: :run
  defdelegate reload_document_job_row(id), to: ListWithLatestRun, as: :reload
  defdelegate update_status(id, status), to: Repository
  defdelegate ingest_webhook(raw_payload), to: IngestWebhook, as: :call
end
