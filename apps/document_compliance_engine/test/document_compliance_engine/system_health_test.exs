defmodule DocumentComplianceEngine.SystemHealthTest do
  use DocumentComplianceEngine.DataCase, async: false

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns.Repository, as: AgentRunsRepository
  alias DocumentComplianceEngine.DocumentJobs.Repository, as: DocumentJobsRepository
  alias DocumentComplianceEngine.SystemHealth

  setup do
    on_exit(fn ->
      Application.delete_env(:document_compliance_engine, :system_health_mcp_check_fun)
    end)
  end

  defp put_mcp_check(fun) do
    Application.put_env(:document_compliance_engine, :system_health_mcp_check_fun, fun)
  end

  test "snapshot/1 reports live BEAM/Oban/agent-run figures and MCP status" do
    put_mcp_check(fn
      "http://localhost:8010/" -> {:ok, %Req.Response{status: 404}}
      "http://localhost:8011/" -> {:error, :econnrefused}
    end)

    owner = user_fixture()

    {:ok, document_job} =
      DocumentJobsRepository.insert(%{
        idempotency_key: "health-1",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id
      })

    {:ok, _run} =
      AgentRunsRepository.insert(%{document_job_id: document_job.id, status: :processing})

    snapshot = SystemHealth.snapshot(owner.id)

    assert snapshot.beam_process_count > 0
    assert snapshot.oban_queue_depth >= 0
    assert snapshot.active_agent_runs >= 1
    assert snapshot.pending_audits == 0
    assert snapshot.tax_api_status == :up
    assert snapshot.sanctions_db_status == :down
  end

  test "snapshot/1 marks a server down when the check errors" do
    put_mcp_check(fn _url -> {:error, :timeout} end)

    snapshot = SystemHealth.snapshot(user_fixture().id)

    assert snapshot.tax_api_status == :down
    assert snapshot.sanctions_db_status == :down
  end
end
