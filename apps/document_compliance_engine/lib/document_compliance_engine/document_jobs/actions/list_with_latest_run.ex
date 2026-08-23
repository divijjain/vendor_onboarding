defmodule DocumentComplianceEngine.DocumentJobs.Actions.ListWithLatestRun do
  @moduledoc """
  Dashboard read model: document_jobs joined with each one's latest agent
  run. `run/1` batches the `AgentRuns` lookup (not N+1) for the full list;
  `reload/1` does the single-row equivalent for a PubSub-triggered row
  refresh. Each context is queried separately and merged here in
  DocumentJobs (the context that owns the list) — never via a query that
  reaches into AgentRuns's schema directly.
  """

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs.Repository

  @spec run(pos_integer(), keyword()) :: [map()]
  def run(organization_id, opts \\ []) do
    document_jobs = Repository.list(organization_id, opts)
    ids = Enum.map(document_jobs, & &1.id)
    latest_runs = AgentRuns.latest_by_document_job_ids(ids)

    Enum.map(document_jobs, &build_row(&1, Map.get(latest_runs, &1.id)))
  end

  @spec reload(pos_integer(), pos_integer()) :: {:ok, map()} | {:error, :not_found}
  def reload(id, organization_id) do
    with {:ok, document_job} <- Repository.get(id, organization_id) do
      agent_run =
        case AgentRuns.get_latest_for_document_job(id) do
          {:ok, run} -> run
          {:error, :not_found} -> nil
        end

      {:ok, build_row(document_job, agent_run)}
    end
  end

  defp build_row(document_job, agent_run) do
    %{
      id: document_job.id,
      status: document_job.status,
      document_type_slug: document_job.document_type_slug,
      company_name: display_name(agent_run),
      updated_at: document_job.updated_at
    }
  end

  # `agent_run.company_name` only ever gets populated for the
  # `vendor_contract_w9` type (see `Agent.Run.@known_roles`) — any other
  # document type's fields land in `extracted_fields` instead, so the
  # dashboard's "Company" column would otherwise show blank even when
  # extraction genuinely succeeded. `invoice` is the one other type that
  # exists today; a real vendor name there is worth surfacing the same
  # way. Same "known types get dedicated handling" tradeoff the rest of
  # the dashboard already makes, not a generic field-guessing heuristic.
  defp display_name(nil), do: nil
  defp display_name(%{company_name: name}) when not is_nil(name), do: name
  defp display_name(%{extracted_fields: fields}), do: get_in(fields, ["invoice", "vendor_name"])
end
