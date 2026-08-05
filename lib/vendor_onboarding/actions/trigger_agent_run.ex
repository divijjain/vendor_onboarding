defmodule VendorOnboarding.Actions.TriggerAgentRun do
  @moduledoc """
  Called from `TriggerAgentRunWorker`. Reads the row, calls the Python
  agent service, and marks it `:processing` while the (async) run is in
  flight. The eventual result comes back via `HandleAgentCallback`, not
  this action's return value.
  """

  alias VendorOnboarding.{AgentService, Repository}

  @spec call(pos_integer()) ::
          {:ok, VendorOnboarding.Schema.VendorOnboarding.t()} | {:error, term()}
  def call(onboarding_id) do
    with {:ok, onboarding} <- Repository.get(onboarding_id),
         {:ok, _response} <-
           AgentService.trigger(%{
             onboarding_id: onboarding.id,
             document_paths: onboarding.document_paths
           }) do
      Repository.update_agent_result(onboarding, %{status: :processing})
    end
  end
end
