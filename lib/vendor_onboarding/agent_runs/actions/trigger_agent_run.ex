defmodule VendorOnboarding.AgentRuns.Actions.TriggerAgentRun do
  @moduledoc """
  Called from `TriggerAgentRunWorker`. Reads the onboarding (via
  `Onboardings`'s public API, never its schema), starts a new run row, and
  calls the Python agent service. The eventual result comes back via
  `HandleAgentCallback`, not this action's return value.
  """

  alias VendorOnboarding.AgentRuns.{AgentService, Repository}
  alias VendorOnboarding.Onboardings

  @spec call(pos_integer()) ::
          {:ok, VendorOnboarding.AgentRuns.Schema.AgentRun.t()} | {:error, term()}
  def call(onboarding_id) do
    with {:ok, onboarding} <- Onboardings.get_onboarding(onboarding_id),
         {:ok, agent_run} <-
           Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing}),
         {:ok, _response} <-
           AgentService.trigger(%{
             onboarding_id: onboarding.id,
             document_paths: onboarding.document_paths
           }),
         {:ok, _onboarding} <- Onboardings.update_status(onboarding.id, :processing) do
      {:ok, agent_run}
    end
  end
end
