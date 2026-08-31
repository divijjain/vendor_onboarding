defmodule DocumentComplianceEngine.PromExTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.PromEx
  alias DocumentComplianceEngine.PromEx.Plugins.Agent, as: AgentPlugin

  # PromEx itself is disabled in test (config/test.exs — its poller isn't
  # Ecto Sandbox-safe, confirmed by actually leaving it enabled and hitting
  # a real connection-ownership race), so there's no live `/metrics` server
  # to hit here. These are structural checks instead: real telemetry-event
  # coverage for the metrics themselves lives in `agent/run_test.exs` and
  # `agent/mcp_client_test.exs`, which attach directly to the same events
  # this plugin declares and don't depend on PromEx being enabled at all.

  test "the custom agent plugin is registered" do
    assert AgentPlugin in PromEx.plugins()
  end

  test "event_metrics/1 builds without raising, for both telemetry events this app emits" do
    group = AgentPlugin.event_metrics([])
    metric_names = Enum.map(group.metrics, & &1.name)

    assert [:document_compliance_engine, :agent_run, :duration, :milliseconds] in metric_names
    assert [:document_compliance_engine, :agent_run, :count] in metric_names
    assert [:document_compliance_engine, :mcp_call, :duration, :milliseconds] in metric_names
    assert [:document_compliance_engine, :mcp_call, :count] in metric_names
  end

  test "polling_metrics/1 wires active_runs to the plugin's own measurement function" do
    group = AgentPlugin.polling_metrics([])

    assert group.measurements_mfa == {AgentPlugin, :execute_polling_metrics, []}
    assert [:document_compliance_engine, :agent, :active_runs] == hd(group.metrics).name
  end
end
