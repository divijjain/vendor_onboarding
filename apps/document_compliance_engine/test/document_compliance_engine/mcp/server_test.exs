defmodule DocumentComplianceEngine.Mcp.ServerTest do
  use DocumentComplianceEngine.DataCase, async: true
  use Oban.Testing, repo: DocumentComplianceEngine.Repo

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.AgentRuns.Workers.{ResumeAgentRunWorker, TriggerAgentRunWorker}
  alias DocumentComplianceEngine.DocumentJobs
  alias DocumentComplianceEngine.Mcp.Server
  alias Hermes.Server.Frame

  defp unique_owner_email, do: "mcp-#{System.unique_integer([:positive])}@example.com"

  defp call_tool(name, args) do
    assert {:reply, response, _frame} = Server.handle_tool_call(name, args, Frame.new())
    assert [%{"type" => "text", "text" => text}] = response.content

    # Error responses (Response.error/2) are plain text, not JSON — only
    # decode on the success path.
    result = if response.isError, do: text, else: Jason.decode!(text)
    {result, response.isError}
  end

  defp needs_review_document_job(overrides \\ %{}) do
    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: "mcp-server-test-#{System.unique_integer([:positive])}",
        document_paths: %{},
        document_type_slug: "vendor_contract_w9",
        owner_user_id: user_fixture().id
      })

    {:ok, run} =
      AgentRuns.Repository.insert(%{document_job_id: document_job.id, status: :processing})

    {:ok, _run} =
      AgentRuns.Repository.update_result(
        run,
        Map.merge(
          %{status: :needs_review, thread_id: "document_job-#{document_job.id}"},
          overrides
        )
      )

    {:ok, document_job} = DocumentJobs.update_status(document_job.id, :needs_review)
    document_job
  end

  describe "trigger_run" do
    test "creates a document_job and enqueues the agent run" do
      documents = %{"invoice" => Base.encode64("Invoice from Acme Corp.")}

      {result, is_error} =
        call_tool("trigger_run", %{
          document_type_slug: "invoice",
          documents: documents,
          owner_email: unique_owner_email()
        })

      refute is_error
      assert result["status"] == "received"
      assert is_integer(result["document_job_id"])

      assert_enqueued(
        worker: TriggerAgentRunWorker,
        args: %{document_job_id: result["document_job_id"]}
      )

      {:ok, document_job} = DocumentJobs.get_document_job(result["document_job_id"])
      on_exit(fn -> document_job.document_paths["invoice"] |> Path.dirname() |> File.rm_rf() end)
    end

    test "ignores a repeated payload as a duplicate" do
      documents = %{"invoice" => Base.encode64("Invoice from Acme Corp, take two.")}

      args = %{
        document_type_slug: "invoice",
        documents: documents,
        owner_email: unique_owner_email()
      }

      {first, false} = call_tool("trigger_run", args)
      {:ok, document_job} = DocumentJobs.get_document_job(first["document_job_id"])
      on_exit(fn -> document_job.document_paths["invoice"] |> Path.dirname() |> File.rm_rf() end)

      {second, is_error} = call_tool("trigger_run", args)
      refute is_error
      assert second == %{"status" => "duplicate_ignored"}
    end

    test "returns a domain error for an unknown document_type_slug" do
      documents = %{"invoice" => Base.encode64("irrelevant")}

      {result, is_error} =
        call_tool("trigger_run", %{
          document_type_slug: "not_a_real_type",
          documents: documents,
          owner_email: unique_owner_email()
        })

      assert is_error
      assert result =~ "unknown_document_type"
    end

    test "returns a domain error when document roles don't match the schema" do
      documents = %{"wrong_role" => Base.encode64("irrelevant")}

      {result, is_error} =
        call_tool("trigger_run", %{
          document_type_slug: "invoice",
          documents: documents,
          owner_email: unique_owner_email()
        })

      assert is_error
      assert result =~ "invalid_payload"
    end
  end

  describe "get_document_job_status" do
    test "returns a domain error for an unknown document_job_id" do
      {result, is_error} = call_tool("get_document_job_status", %{document_job_id: -1})
      assert is_error
      assert result =~ "not found"
    end

    test "reports run: nil when no agent_run exists yet" do
      {:ok, document_job} =
        DocumentJobs.Repository.insert(%{
          idempotency_key: "mcp-server-test-no-run",
          document_paths: %{},
          document_type_slug: "invoice",
          owner_user_id: user_fixture().id
        })

      {result, false} = call_tool("get_document_job_status", %{document_job_id: document_job.id})
      assert result["status"] == "received"
      assert result["run"] == nil
    end

    test "merges dedicated w9/contract columns into extracted_fields and reports metadata, review decisions" do
      document_job =
        needs_review_document_job(%{
          company_name: "Acme Corp",
          w9_company_name: "Totally Different LLC",
          payment_terms: "Net 30",
          liability_clauses: "Standard.",
          explanation: "Names do not match.",
          extraction_metadata: %{
            "contract" => %{
              "company_name" => %{"confidence" => 0.9, "source_quote" => "Acme Corp"}
            }
          }
        })

      {:ok, _decision} =
        AgentRuns.ReviewDecisions.Repository.insert(%{
          document_job_id: document_job.id,
          thread_id: "document_job-#{document_job.id}",
          decision: :rejected,
          reviewer: "Jane Reviewer",
          rationale: "Names don't match.",
          evidence: "Names do not match."
        })

      {result, false} = call_tool("get_document_job_status", %{document_job_id: document_job.id})

      assert result["status"] == "needs_review"
      assert result["run"]["explanation"] == "Names do not match."
      assert result["run"]["extracted_fields"]["contract"]["company_name"] == "Acme Corp"
      assert result["run"]["extracted_fields"]["contract"]["payment_terms"] == "Net 30"
      assert result["run"]["extracted_fields"]["w9"]["company_name"] == "Totally Different LLC"

      assert result["run"]["extraction_metadata"]["contract"]["company_name"]["confidence"] ==
               0.9

      assert [decision] = result["review_decisions"]
      assert decision["decision"] == "rejected"
      assert decision["reviewer"] == "Jane Reviewer"
    end

    test "never exposes tax_id, even if it's present in extracted_fields or extraction_metadata" do
      document_job =
        needs_review_document_job(%{
          extracted_fields: %{"w9" => %{"tax_id" => "12-3456789"}},
          extraction_metadata: %{
            "w9" => %{"tax_id" => %{"confidence" => 1.0, "source_quote" => "12-3456789"}}
          }
        })

      {result, false} = call_tool("get_document_job_status", %{document_job_id: document_job.id})

      refute Map.has_key?(result["run"]["extracted_fields"]["w9"], "tax_id")
      refute Map.has_key?(result["run"]["extraction_metadata"]["w9"], "tax_id")
      refute inspect(result) =~ "12-3456789"
    end
  end

  describe "submit_review_decision" do
    test "enqueues a resume with the decision and records an audit entry" do
      document_job = needs_review_document_job()

      {result, false} =
        call_tool("submit_review_decision", %{
          document_job_id: document_job.id,
          decision: "approved",
          reviewer: "mcp-agent",
          rationale: "Looks correct."
        })

      assert result["status"] == "queued_for_resume"

      assert_enqueued(
        worker: ResumeAgentRunWorker,
        args: %{document_job_id: document_job.id, decision: "approved"}
      )

      assert [decision] = AgentRuns.list_review_decisions(document_job.id)
      assert decision.reviewer == "mcp-agent"
    end

    test "returns a domain error when the document_job isn't awaiting review" do
      {:ok, document_job} =
        DocumentJobs.Repository.insert(%{
          idempotency_key: "mcp-server-test-not-review-#{System.unique_integer([:positive])}",
          document_paths: %{},
          document_type_slug: "vendor_contract_w9",
          owner_user_id: user_fixture().id
        })

      {result, is_error} =
        call_tool("submit_review_decision", %{
          document_job_id: document_job.id,
          decision: "approved",
          reviewer: "x",
          rationale: "x"
        })

      assert is_error
      assert result =~ "not currently awaiting review"
    end

    test "returns a domain error for an unknown document_job_id" do
      {result, is_error} =
        call_tool("submit_review_decision", %{
          document_job_id: -1,
          decision: "approved",
          reviewer: "x",
          rationale: "x"
        })

      assert is_error
      assert result =~ "not found"
    end
  end
end
