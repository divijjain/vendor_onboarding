defmodule VendorOnboarding.SystemHealthTest do
  use VendorOnboarding.DataCase, async: false

  alias VendorOnboarding.AgentRuns.Repository, as: AgentRunsRepository
  alias VendorOnboarding.DocumentJobs.Repository, as: DocumentJobsRepository
  alias VendorOnboarding.SystemHealth

  setup do
    on_exit(fn -> Application.delete_env(:vendor_onboarding, :system_health_mcp_check_fun) end)
  end

  defp put_mcp_check(fun) do
    Application.put_env(:vendor_onboarding, :system_health_mcp_check_fun, fun)
  end

  test "snapshot/0 reports live BEAM/Oban/agent-run figures and MCP status" do
    put_mcp_check(fn
      "http://localhost:8010/" -> {:ok, %Req.Response{status: 404}}
      "http://localhost:8011/" -> {:error, :econnrefused}
    end)

    {:ok, document_job} =
      DocumentJobsRepository.insert(%{idempotency_key: "health-1", document_paths: %{}})

    {:ok, _run} =
      AgentRunsRepository.insert(%{document_job_id: document_job.id, status: :processing})

    snapshot = SystemHealth.snapshot()

    assert snapshot.beam_process_count > 0
    assert snapshot.oban_queue_depth >= 0
    assert snapshot.active_agent_runs >= 1
    assert snapshot.tax_api_status == :up
    assert snapshot.sanctions_db_status == :down
  end

  test "snapshot/0 marks a server down when the check errors" do
    put_mcp_check(fn _url -> {:error, :timeout} end)

    snapshot = SystemHealth.snapshot()

    assert snapshot.tax_api_status == :down
    assert snapshot.sanctions_db_status == :down
  end
end
