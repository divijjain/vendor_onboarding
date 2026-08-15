defmodule VendorOnboarding.AgentRuns.Actions.TriggerAgentRunTest do
  # async: false — stubs the agent pipeline via shared Application env.
  use VendorOnboarding.DataCase, async: false

  alias VendorOnboarding.Agent.Schemas.{ContractExtraction, EntityMatchResult, W9Extraction}
  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.DocumentJobs

  setup do
    dir =
      System.tmp_dir!()
      |> Path.join("trigger_agent_run_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    contract_path = Path.join(dir, "contract.pdf")
    w9_path = Path.join(dir, "w9.pdf")
    File.write!(contract_path, "contract text")
    File.write!(w9_path, "w9 text")
    on_exit(fn -> File.rm_rf!(dir) end)

    stub_agent(
      agent_extract_contract: fn _text ->
        {:ok,
         %ContractExtraction{
           company_name: "Acme Corp",
           payment_terms: "Net 30",
           liability_clauses: "Standard."
         }}
      end,
      agent_extract_w9: fn _text ->
        {:ok, %W9Extraction{company_name: "Acme Corp", tax_id: "12-3456789"}}
      end,
      agent_entity_match: fn _contract_name, _w9_name ->
        {:ok, %EntityMatchResult{match: true, explanation: "same entity"}}
      end,
      agent_validate_tax_id: fn _tax_id -> {:ok, %{valid: true}} end,
      agent_screen_vendor: fn _name -> {:ok, %{flagged: false, reason: nil}} end
    )

    %{document_paths: %{"contract" => contract_path, "w9" => w9_path}}
  end

  defp stub_agent(overrides) do
    Enum.each(overrides, fn {key, fun} -> Application.put_env(:vendor_onboarding, key, fun) end)

    on_exit(fn ->
      Enum.each(overrides, fn {key, _fun} -> Application.delete_env(:vendor_onboarding, key) end)
    end)
  end

  defp insert_document_job(key, document_paths) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{idempotency_key: key, document_paths: document_paths})

    document_job
  end

  test "starts a run, runs the agent pipeline synchronously, and lands the document_job at its final status",
       %{document_paths: paths} do
    document_job = insert_document_job("trigger-1", paths)

    assert {:ok, agent_run} = AgentRuns.trigger_agent_run(document_job.id)
    assert agent_run.document_job_id == document_job.id

    # The pipeline runs to completion inside trigger_agent_run/1 now (no
    # separate HTTP callback arriving later), so by the time this returns
    # the document_job is already at its FINAL status, not still :processing.
    assert {:ok, updated_document_job} = DocumentJobs.get_document_job(document_job.id)
    assert updated_document_job.status == :approved

    assert {:ok, updated_run} = AgentRuns.get_latest_for_document_job(document_job.id)
    assert updated_run.status == :approved
    assert updated_run.company_name == "Acme Corp"
    assert updated_run.tax_id == "12-3456789"
  end

  test "still creates a run row when a document is missing, and the pipeline reports :failed" do
    document_job =
      insert_document_job("trigger-2", %{
        "contract" => "/no/such/file.pdf",
        "w9" => "/no/such/w9.pdf"
      })

    assert {:ok, _agent_run} = AgentRuns.trigger_agent_run(document_job.id)

    assert {:ok, updated_document_job} = DocumentJobs.get_document_job(document_job.id)
    assert updated_document_job.status == :failed
  end

  test "returns {:error, :not_found} for a missing document_job" do
    assert {:error, :not_found} = AgentRuns.trigger_agent_run(-1)
  end
end
