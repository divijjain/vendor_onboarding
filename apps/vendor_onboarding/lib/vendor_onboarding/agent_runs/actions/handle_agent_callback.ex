defmodule VendorOnboarding.AgentRuns.Actions.HandleAgentCallback do
  @moduledoc """
  Writes an agent run's result back onto the current run row, mirrors the
  status onto the document_job (via `DocumentJobs`'s public API), and
  broadcasts via PubSub so the LiveView dashboard can react. Called
  directly by `VendorOnboarding.Agent.Run` when the agent pipeline
  finishes or pauses.
  """

  alias VendorOnboarding.AgentRuns.Repository
  alias VendorOnboarding.DocumentJobs

  @result_fields ~w(status thread_id company_name w9_company_name tax_id payment_terms liability_clauses explanation)

  @spec call(map()) ::
          {:ok, VendorOnboarding.AgentRuns.Schema.AgentRun.t()}
          | {:error, :not_found | Ecto.Changeset.t()}
  def call(%{"document_job_id" => document_job_id} = params) do
    with {:ok, agent_run} <- Repository.get_latest_for_document_job(document_job_id),
         {:ok, updated} <- Repository.update_result(agent_run, result_attrs(params)),
         {:ok, _document_job} <- DocumentJobs.update_status(document_job_id, updated.status) do
      Phoenix.PubSub.broadcast(
        VendorOnboarding.PubSub,
        "vendor_onboarding",
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
