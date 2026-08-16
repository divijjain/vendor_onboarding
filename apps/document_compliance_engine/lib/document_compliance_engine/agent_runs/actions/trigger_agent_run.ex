defmodule DocumentComplianceEngine.AgentRuns.Actions.TriggerAgentRun do
  @moduledoc """
  Called from `TriggerAgentRunWorker`. Reads the document_job (via
  `DocumentJobs`'s public API, never its schema), starts a new run row, and
  runs the agent pipeline. The eventual result comes back via
  `Agent.Run` reporting to `HandleAgentCallback`, not this action's
  return value — `Agent.Run.trigger/2` runs the pipeline to completion
  before returning, but that's still off the web/LiveView process since
  this whole action only ever runs inside an Oban job.
  """

  alias DocumentComplianceEngine.Agent
  alias DocumentComplianceEngine.AgentRuns.Repository
  alias DocumentComplianceEngine.DocumentJobs

  @spec call(pos_integer()) ::
          {:ok, DocumentComplianceEngine.AgentRuns.Schema.AgentRun.t()} | {:error, term()}
  def call(document_job_id) do
    with {:ok, document_job} <- DocumentJobs.get_document_job(document_job_id),
         {:ok, agent_run} <-
           Repository.insert(%{document_job_id: document_job.id, status: :processing}),
         {:ok, _document_job} <- DocumentJobs.update_status(document_job.id, :processing) do
      :ok =
        Agent.Run.trigger(
          document_job.id,
          document_job.document_type_slug,
          document_job.document_paths
        )

      {:ok, agent_run}
    end
  end
end
