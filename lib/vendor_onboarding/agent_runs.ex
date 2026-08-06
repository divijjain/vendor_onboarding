defmodule VendorOnboarding.AgentRuns do
  @moduledoc """
  Public API for the agent-orchestration domain. `defdelegate` only — no
  logic here. Owns the `agent_runs` table: the extracted/validated output
  of each run against a given onboarding, including history across
  re-runs. See `VendorOnboarding.Onboardings` for the ingestion record.
  """

  alias VendorOnboarding.AgentRuns.Actions.{HandleAgentCallback, ResumeReview, TriggerAgentRun}
  alias VendorOnboarding.AgentRuns.Repository
  alias VendorOnboarding.AgentRuns.Workers.TriggerAgentRunWorker

  defdelegate get_latest_for_onboarding(onboarding_id), to: Repository
  defdelegate latest_by_onboarding_ids(ids), to: Repository
  defdelegate enqueue_trigger(onboarding_id), to: TriggerAgentRunWorker, as: :enqueue
  defdelegate trigger_agent_run(onboarding_id), to: TriggerAgentRun, as: :call
  defdelegate handle_agent_callback(params), to: HandleAgentCallback, as: :call
  defdelegate resume_review(onboarding_id, decision), to: ResumeReview, as: :call
end
