defmodule DocumentComplianceEngine.PromEx.Plugins.Agent do
  @moduledoc """
  Domain metrics for the agent pipeline — the things `PromEx.Plugins.Oban`
  can't see because they're facts about a `document_job`/`agent_run`, not
  about a job's execution inside Oban. `Plugins.Oban` (already included in
  `DocumentComplianceEngine.PromEx.plugins/0`) covers queue depth and job
  duration; this plugin covers pipeline outcome and MCP tool-call health.

  Event metrics come from the `:telemetry.span/3` calls in `Agent.Run`
  (`[:document_compliance_engine, :agent_run, :stop]`) and `Agent.McpClient`
  (`[:document_compliance_engine, :mcp_call, :stop]`) — both tag by
  `status`/`document_type_slug`/`tool` only, never `document_job_id`. See
  the comment on `Agent.Run.trigger/3` for why: a Prometheus label must
  come from a small, fixed set of values, or every new document mints a
  permanent new time series (a real, common way to accidentally take down
  a Prometheus server, not a hypothetical one).
  """

  use PromEx.Plugin

  alias DocumentComplianceEngine.AgentRuns

  @agent_run_event [:document_compliance_engine, :agent_run, :stop]
  @mcp_call_event [:document_compliance_engine, :mcp_call, :stop]
  @polling_event [:document_compliance_engine, :agent, :polling]

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :document_compliance_engine_agent_event_metrics,
      [
        distribution(
          [:document_compliance_engine, :agent_run, :duration, :milliseconds],
          event_name: @agent_run_event,
          measurement: :duration,
          description: "Duration of one full agent pipeline run (trigger or resume).",
          tags: [:status, :document_type_slug],
          tag_values: &agent_run_tags/1,
          unit: {:native, :millisecond},
          reporter_options: [
            buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000]
          ]
        ),
        counter(
          [:document_compliance_engine, :agent_run, :count],
          event_name: @agent_run_event,
          description: "Count of agent pipeline runs completed, by final status.",
          tags: [:status, :document_type_slug],
          tag_values: &agent_run_tags/1
        ),
        distribution(
          [:document_compliance_engine, :mcp_call, :duration, :milliseconds],
          event_name: @mcp_call_event,
          measurement: :duration,
          description: "Duration of one call to a tax_api/sanctions_db MCP tool.",
          tags: [:tool, :status],
          tag_values: &mcp_call_tags/1,
          unit: {:native, :millisecond},
          reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]]
        ),
        counter(
          [:document_compliance_engine, :mcp_call, :count],
          event_name: @mcp_call_event,
          description: "Count of MCP tool calls, by tool and outcome.",
          tags: [:tool, :status],
          tag_values: &mcp_call_tags/1
        )
      ]
    )
  end

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 10_000)

    Polling.build(
      :document_compliance_engine_agent_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_polling_metrics, []},
      [
        last_value(
          [:document_compliance_engine, :agent, :active_runs],
          event_name: @polling_event,
          measurement: :active_runs,
          description:
            "Number of agent runs currently paused awaiting human review — a business " <>
              "fact Oban's own queue-depth metrics can't see, since these jobs already " <>
              "finished executing as far as Oban is concerned."
        )
      ]
    )
  end

  @doc false
  def execute_polling_metrics do
    :telemetry.execute(@polling_event, %{active_runs: AgentRuns.count_active()}, %{})
  end

  defp agent_run_tags(%{status: status, document_type_slug: slug}) do
    %{status: to_string(status || "unknown"), document_type_slug: slug || "unknown"}
  end

  defp mcp_call_tags(%{tool: tool, status: status}) do
    %{tool: to_string(tool), status: to_string(status)}
  end
end
