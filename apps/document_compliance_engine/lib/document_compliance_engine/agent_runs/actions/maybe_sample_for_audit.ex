defmodule DocumentComplianceEngine.AgentRuns.Actions.MaybeSampleForAudit do
  @moduledoc """
  Called by `HandleAgentCallback` after every run result is written back.
  Only a run that reached `:approved` with **no `thread_id`** is
  eligible — `thread_id` is only ever set by a halt (see
  `Agent.Run.handle_result/3`), so its absence is the reliable signal
  that no human ever paused on this run before it auto-approved. A run
  that was `:needs_review`'d and later approved by a human already has
  the strongest possible check (a human looked at it directly) and is
  deliberately not eligible for resampling here.

  `@audit_sample_rate` is a probability, not a queue depth target —
  `:rand.uniform() < rate` means a `rate` of `0.0` never samples and
  `1.0` always does, both fully deterministic, which is what lets tests
  pin this behavior without a separate injected random function.
  """

  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository, as: AuditSamplesRepository
  alias DocumentComplianceEngine.AgentRuns.Schema.AgentRun

  @spec call(AgentRun.t()) :: :ok
  def call(%AgentRun{status: :approved, thread_id: nil} = agent_run) do
    if :rand.uniform() < sample_rate() do
      case AuditSamplesRepository.insert(%{
             document_job_id: agent_run.document_job_id,
             agent_run_id: agent_run.id,
             status: :pending
           }) do
        {:ok, _audit_sample} -> :ok
        # `agent_run_id` is unique — only reachable if this run was already
        # sampled (shouldn't happen, `agent_runs` rows aren't re-approved
        # in place), safe to ignore rather than fail the whole callback.
        {:error, %Ecto.Changeset{}} -> :ok
      end
    else
      :ok
    end
  end

  def call(%AgentRun{}), do: :ok

  defp sample_rate do
    Application.get_env(:document_compliance_engine, :audit_sample_rate, 0.0)
  end
end
