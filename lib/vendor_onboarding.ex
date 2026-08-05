defmodule VendorOnboarding do
  @moduledoc """
  Public API for the vendor onboarding domain. `defdelegate` only — no logic here.
  """

  alias VendorOnboarding.Actions.{HandleAgentCallback, IngestWebhook, TriggerAgentRun}
  alias VendorOnboarding.Repository

  defdelegate get_onboarding(id), to: Repository, as: :get
  defdelegate get_onboarding!(id), to: Repository, as: :get!
  defdelegate list_onboardings(opts \\ []), to: Repository, as: :list
  defdelegate ingest_webhook(raw_payload), to: IngestWebhook, as: :call
  defdelegate trigger_agent_run(onboarding_id), to: TriggerAgentRun, as: :call
  defdelegate handle_agent_callback(params), to: HandleAgentCallback, as: :call
end
