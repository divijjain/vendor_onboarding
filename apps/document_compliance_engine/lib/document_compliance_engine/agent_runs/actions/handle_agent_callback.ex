defmodule DocumentComplianceEngine.AgentRuns.Actions.HandleAgentCallback do
  @moduledoc """
  Writes an agent run's result back onto the current run row, mirrors the
  status onto the document_job (via `DocumentJobs`'s public API), and
  broadcasts via PubSub so the LiveView dashboard can react. Called
  directly by `DocumentComplianceEngine.Agent.Run` when the agent pipeline
  finishes or pauses.

  Broadcasts on the document_job's own organization-scoped topic (see
  `PubSubTopic`) — never a flat, globally-shared topic — so a status
  update physically never reaches another organization's connected
  LiveView process.
  """

  alias DocumentComplianceEngine.AgentRuns.Actions.MaybeSampleForAudit
  alias DocumentComplianceEngine.AgentRuns.PubSubTopic
  alias DocumentComplianceEngine.AgentRuns.Repository
  alias DocumentComplianceEngine.DocumentJobs

  @result_fields ~w(status thread_id company_name w9_company_name tax_id payment_terms liability_clauses explanation extracted_fields extraction_metadata)

  @spec call(map()) ::
          {:ok, DocumentComplianceEngine.AgentRuns.Schema.AgentRun.t()}
          | {:error, :not_found | Ecto.Changeset.t()}
  def call(%{"document_job_id" => document_job_id} = params) do
    with {:ok, agent_run} <- Repository.get_latest_for_document_job(document_job_id),
         {:ok, updated} <- Repository.update_result(agent_run, result_attrs(params)),
         {:ok, document_job} <- DocumentJobs.update_status(document_job_id, updated.status) do
      :ok = MaybeSampleForAudit.call(updated)

      Phoenix.PubSub.broadcast(
        DocumentComplianceEngine.PubSub,
        PubSubTopic.for_organization(document_job.organization_id),
        {:status_updated, updated.document_job_id}
      )

      {:ok, updated}
    end
  end

  defp result_attrs(params) do
    params
    |> Map.take(@result_fields)
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end
end
