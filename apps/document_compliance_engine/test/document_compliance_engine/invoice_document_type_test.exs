defmodule DocumentComplianceEngine.InvoiceDocumentTypeTest do
  @moduledoc """
  End-to-end proof that the pipeline is genuinely document-type-generic:
  `invoice` (one document, no entity-match, a single sanctions-screen rule)
  runs through ingestion and the agent pipeline exactly like
  `vendor_contract_w9`, with nothing document-type-specific in the code
  path — only the seeded `document_types` row differs.
  """

  use DocumentComplianceEngine.DataCase, async: false

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  defp stub_agent(overrides) do
    Enum.each(overrides, fn {key, fun} ->
      Application.put_env(:document_compliance_engine, key, fun)
    end)

    on_exit(fn ->
      Enum.each(overrides, fn {key, _fun} ->
        Application.delete_env(:document_compliance_engine, key)
      end)
    end)
  end

  # `invoice_text` is hashed against `AgentFakes`-style extract stubs below
  # by `Checks.grounded_extraction_checks/2` — it must actually contain
  # whatever the stub claims to have extracted, or the run halts for
  # review instead of following the rule-based path each test means to
  # exercise (see checks.ex).
  defp ingest_invoice(invoice_text) do
    raw_payload =
      Jason.encode!(%{
        "document_type_slug" => "invoice",
        "documents" => %{"invoice" => Base.encode64(invoice_text)}
      })

    {:ok, document_job} = DocumentJobs.ingest_webhook(raw_payload)

    on_exit(fn -> document_job.document_paths["invoice"] |> Path.dirname() |> File.rm_rf() end)

    document_job
  end

  test "auto-approves an invoice with a clean sanctions screen" do
    stub_agent(
      agent_extract: fn "invoice", _schema, _text ->
        {:ok,
         %{
           vendor_name: "Acme Corp",
           invoice_number: "INV-1001",
           amount: "1000.00",
           due_date: "2026-09-01"
         }}
      end,
      agent_screen_vendor: fn _name -> {:ok, %{flagged: false, reason: nil}} end
    )

    document_job =
      ingest_invoice("""
      INVOICE
      Vendor: Acme Corp
      Invoice Number: INV-1001
      Amount: 1000.00
      Due Date: 2026-09-01
      """)

    assert {:ok, agent_run} = AgentRuns.trigger_agent_run(document_job.id)

    assert {:ok, updated_job} = DocumentJobs.get_document_job(document_job.id)
    assert updated_job.status == :approved

    assert {:ok, updated_run} = AgentRuns.get_latest_for_document_job(document_job.id)
    assert updated_run.id == agent_run.id
    assert updated_run.status == :approved
    # No dedicated columns for this type — the generic column carries it.
    assert updated_run.company_name == nil

    assert updated_run.extracted_fields == %{
             "invoice" => %{
               "vendor_name" => "Acme Corp",
               "invoice_number" => "INV-1001",
               "amount" => "1000.00",
               "due_date" => "2026-09-01"
             }
           }
  end

  test "halts for review when the vendor hits the sanctions screen" do
    stub_agent(
      agent_extract: fn "invoice", _schema, _text ->
        {:ok,
         %{
           vendor_name: "Blocked Vendor LLC",
           invoice_number: "INV-2002",
           amount: "500.00",
           due_date: "2026-09-15"
         }}
      end,
      agent_screen_vendor: fn _name ->
        {:ok, %{flagged: true, reason: "Matched watchlist entry"}}
      end,
      agent_draft_explanation: fn findings -> "Explanation: #{findings}" end
    )

    document_job =
      ingest_invoice("""
      INVOICE
      Vendor: Blocked Vendor LLC
      Invoice Number: INV-2002
      Amount: 500.00
      Due Date: 2026-09-15
      """)

    assert {:ok, _agent_run} = AgentRuns.trigger_agent_run(document_job.id)

    assert {:ok, updated_job} = DocumentJobs.get_document_job(document_job.id)
    assert updated_job.status == :needs_review

    assert {:ok, updated_run} = AgentRuns.get_latest_for_document_job(document_job.id)
    assert updated_run.status == :needs_review
    assert updated_run.thread_id == "document_job-#{document_job.id}"
    assert updated_run.explanation =~ "Sanctions screening hit: Matched watchlist entry"
  end
end
