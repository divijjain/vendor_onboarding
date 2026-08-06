defmodule VendorOnboarding.AgentRuns.Repository do
  @moduledoc """
  The only module that touches `VendorOnboarding.Repo` for the `agent_runs`
  table. No coordination, no HTTP calls, no reaching into `Onboardings`'s schema.
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

  @spec get_latest_for_onboarding(pos_integer()) :: {:ok, AgentRun.t()} | {:error, :not_found}
  def get_latest_for_onboarding(onboarding_id) do
    AgentRun
    |> where(vendor_onboarding_id: ^onboarding_id)
    |> latest_first()
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      agent_run -> {:ok, agent_run}
    end
  end

  @doc """
  Latest run per onboarding id, batched to avoid an N+1 when the dashboard
  lists many onboardings at once. Returns `%{onboarding_id => AgentRun.t()}`.
  """
  @spec latest_by_onboarding_ids([pos_integer()]) :: %{pos_integer() => AgentRun.t()}
  def latest_by_onboarding_ids(ids) do
    AgentRun
    |> where([r], r.vendor_onboarding_id in ^ids)
    |> distinct(asc: :vendor_onboarding_id)
    |> order_by(asc: :vendor_onboarding_id, desc: :inserted_at, desc: :id)
    |> Repo.all()
    |> Map.new(&{&1.vendor_onboarding_id, &1})
  end

  # `inserted_at` is only second-granularity (timestamps(type: :utc_datetime)),
  # so two runs created within the same second would tie without `:id` as a
  # tie-breaker — `:id` is monotonically increasing regardless.
  defp latest_first(query), do: order_by(query, desc: :inserted_at, desc: :id)
end
