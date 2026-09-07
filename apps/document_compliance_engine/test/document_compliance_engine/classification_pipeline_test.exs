defmodule DocumentComplianceEngine.ClassificationPipelineTest do
  @moduledoc """
  End-to-end proof of the thing classification exists for: a caller who
  does not know what they are sending. Every test here posts a webhook
  payload with **no `document_type_slug`**, against the real seeded
  document-type registry, and asserts on what the job became.
  """

  use DocumentComplianceEngine.DataCase, async: false
  use Oban.Testing, repo: DocumentComplianceEngine.Repo

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  @invoice_text """
  INVOICE

  Bill To: Buyer Inc.
  Vendor: Acme Corp
  Invoice Number: INV-1001
  Amount Due: 1,000.00
  Due Date: 2026-09-01
  """

  # Clears *both* the invoice and receipt shape gates, so the deterministic
  # pre-filter can't pick a winner and the classifier is actually consulted —
  # while still being invoice-shaped enough that extraction runs once the
  # classifier proposes `invoice`.
  @ambiguous_text """
  INVOICE / RECEIPT

  Bill To: Buyer Inc.
  Vendor: Acme Corp
  Invoice Number: INV-1001
  Amount Due: 1,000.00
  Due Date: 2026-09-01

  Thank you for your payment. Change due: 0.00
  """

  # Neither an invoice nor anything else in the registry.
  @resume_text """
  Dear Hiring Manager,

  I am writing to express my enthusiasm for the Software Engineer position.
  I believe I would be a strong addition to your team.

  Sincerely,
  A Candidate
  """

  defp ingest(text, overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          "documents" => %{"document" => Base.encode64(text)},
          "owner_email" => "classify-#{System.unique_integer([:positive])}@example.com"
        },
        overrides
      )

    {:ok, document_job} = DocumentJobs.ingest_webhook(Jason.encode!(payload))

    on_exit(fn ->
      document_job.document_paths
      |> Map.values()
      |> List.first()
      |> Path.dirname()
      |> File.rm_rf()
    end)

    document_job
  end

  defp stub_invoice_extraction do
    stub_defaults(
      extract: fn "invoice", _response_model, _text ->
        {:ok,
         %{
           vendor_name: "Acme Corp",
           invoice_number: "INV-1001",
           amount: "1,000.00",
           due_date: "2026-09-01"
         }}
      end
    )
  end

  test "ingests with no document_type_slug and leaves the column blank until the agent runs" do
    stub_invoice_extraction()

    document_job = ingest(@invoice_text)

    assert document_job.document_type_slug == nil
    assert document_job.document_paths |> Map.keys() == ["document"]
  end

  test "classifies, extracts under the classified type, approves, and records the slug" do
    stub_invoice_extraction()

    document_job = ingest(@invoice_text)

    assert {:ok, _run} = AgentRuns.trigger_agent_run(document_job.id)
    assert {:ok, updated} = DocumentJobs.get_document_job(document_job.id)

    # The invoice keywords clear only the invoice type's own shape signals,
    # so this classified deterministically — no LLM call was needed.
    assert updated.document_type_slug == "invoice"
    assert updated.status == :approved

    # The document was uploaded as "document" and extracted as the invoice
    # type's "invoice" role: TypeResolution re-keyed it.
    assert {:ok, run} = AgentRuns.get_latest_for_document_job(document_job.id)
    assert run.extracted_fields["invoice"]["vendor_name"] == "Acme Corp"
  end

  test "an unclassifiable document halts for review with nothing extracted and no type recorded" do
    stub_defaults(
      classify: fn _text, _candidates ->
        {:ok, %{slug: "unknown", confidence: 0.0, reasoning: "This is a cover letter"}}
      end,
      draft_explanation: fn findings -> findings end
    )

    document_job = ingest(@resume_text)

    assert {:ok, _run} = AgentRuns.trigger_agent_run(document_job.id)
    assert {:ok, updated} = DocumentJobs.get_document_job(document_job.id)

    assert updated.status == :needs_review
    # Deliberately still blank: an unclassified job is not mislabelled to
    # make the column non-null.
    assert updated.document_type_slug == nil

    assert {:ok, run} = AgentRuns.get_latest_for_document_job(document_job.id)
    assert run.explanation =~ "Could not determine what kind of document this is"
    assert run.explanation =~ "This is a cover letter"
    assert run.extracted_fields == %{}
  end

  test "a low-confidence classification halts for review, having extracted on its best guess" do
    stub_defaults(
      classify: fn _text, _candidates ->
        {:ok, %{slug: "invoice", confidence: 0.4, reasoning: "could be a receipt"}}
      end,
      extract: fn "invoice", _response_model, _text ->
        {:ok,
         %{
           vendor_name: "Acme Corp",
           invoice_number: "INV-1001",
           amount: "1,000.00",
           due_date: "2026-09-01"
         }}
      end,
      draft_explanation: fn findings -> findings end
    )

    document_job = ingest(@ambiguous_text)

    assert {:ok, _run} = AgentRuns.trigger_agent_run(document_job.id)
    assert {:ok, updated} = DocumentJobs.get_document_job(document_job.id)

    assert updated.status == :needs_review
    # The proposed type is recorded — it's what the run actually used, and
    # what the reviewer is being asked to confirm.
    assert updated.document_type_slug == "invoice"

    assert {:ok, run} = AgentRuns.get_latest_for_document_job(document_job.id)
    assert run.explanation =~ "Classified as invoice with low confidence"
    assert run.explanation =~ "could be a receipt"

    # The evidence the reviewer needs: extracted under the proposed type.
    assert run.extracted_fields["invoice"]["vendor_name"] == "Acme Corp"
  end

  test "the reviewer approving a low-confidence classification resumes to approved" do
    stub_defaults(
      classify: fn _text, _candidates ->
        {:ok, %{slug: "invoice", confidence: 0.4, reasoning: "could be a receipt"}}
      end,
      extract: fn "invoice", _response_model, _text ->
        {:ok,
         %{
           vendor_name: "Acme Corp",
           invoice_number: "INV-1001",
           amount: "1,000.00",
           due_date: "2026-09-01"
         }}
      end,
      draft_explanation: fn findings -> findings end
    )

    document_job = ingest(@ambiguous_text)

    # Drained rather than called directly, so this test covers the real
    # worker path on both sides of the pause: ingestion's enqueued trigger
    # job, then the resume job the reviewer's decision enqueues.
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :agent_runs)
    assert {:ok, %{status: :needs_review}} = DocumentJobs.get_document_job(document_job.id)

    # The existing review path, unchanged: same decision vocabulary, same
    # audit record, same resume worker.
    assert {:ok, _job} =
             AgentRuns.resume_review(
               document_job.id,
               :approved,
               "reviewer@example.com",
               "Yes, an invoice"
             )

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :agent_runs)

    assert {:ok, updated} = DocumentJobs.get_document_job(document_job.id)
    assert updated.status == :approved
    assert updated.document_type_slug == "invoice"
  end

  test "a caller-supplied slug is still honoured and never re-derived" do
    test_pid = self()

    stub_defaults(
      classify: fn _text, _candidates -> send(test_pid, :classifier_called) end,
      extract: fn "invoice", _response_model, _text ->
        {:ok,
         %{
           vendor_name: "Acme Corp",
           invoice_number: "INV-1001",
           amount: "1,000.00",
           due_date: "2026-09-01"
         }}
      end
    )

    document_job =
      ingest(@invoice_text, %{
        "document_type_slug" => "invoice",
        "documents" => %{"invoice" => Base.encode64(@invoice_text)}
      })

    assert document_job.document_type_slug == "invoice"
    assert {:ok, _run} = AgentRuns.trigger_agent_run(document_job.id)
    assert {:ok, %{status: :approved}} = DocumentJobs.get_document_job(document_job.id)

    refute_received :classifier_called
  end
end
