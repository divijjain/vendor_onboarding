defmodule VendorOnboarding.AgentRuns.Repository do
  @moduledoc """
  The only module that touches `VendorOnboarding.Repo` for the `agent_runs`
  table. No coordination, no HTTP calls, no reaching into `DocumentJobs`'s schema.
  """

  import Ecto.Query

  alias VendorOnboarding.Repo
  alias VendorOnboarding.AgentRuns.Schema.AgentRun

  @spec insert(map()) :: {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %AgentRun{}
    |> AgentRun.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec update_result(AgentRun.t(), map()) ::
          {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def update_result(%AgentRun{} = agent_run, attrs) do
    agent_run
    |> AgentRun.result_changeset(attrs)
    |> Repo.update()
  end

  @spec get_latest_for_document_job(pos_integer()) :: {:ok, AgentRun.t()} | {:error, :not_found}
  def get_latest_for_document_job(document_job_id) do
    AgentRun
    |> where(document_job_id: ^document_job_id)
    |> latest_first()
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      agent_run -> {:ok, agent_run}
    end
  end

  @doc """
  Latest run per document_job id, batched to avoid an N+1 when the dashboard
  lists many document_jobs at once. Returns `%{document_job_id => AgentRun.t()}`.
  """
  @spec latest_by_document_job_ids([pos_integer()]) :: %{pos_integer() => AgentRun.t()}
  def latest_by_document_job_ids(ids) do
    AgentRun
    |> where([r], r.document_job_id in ^ids)
    |> distinct(asc: :document_job_id)
    |> order_by(asc: :document_job_id, desc: :inserted_at, desc: :id)
    |> Repo.all()
    |> Map.new(&{&1.document_job_id, &1})
  end

  # `inserted_at` is only second-granularity (timestamps(type: :utc_datetime)),
  # so two runs created within the same second would tie without `:id` as a
  # tie-breaker — `:id` is monotonically increasing regardless.
  defp latest_first(query), do: order_by(query, desc: :inserted_at, desc: :id)

  @doc "Count of runs currently mid-pipeline — for the operational health panel."
  @spec count_active() :: non_neg_integer()
  def count_active do
    AgentRun
    |> where(status: :processing)
    |> Repo.aggregate(:count)
  end
end
