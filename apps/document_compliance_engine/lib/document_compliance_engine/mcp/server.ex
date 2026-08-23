defmodule DocumentComplianceEngine.Mcp.Server do
  @moduledoc """
  Exposes the document-compliance pipeline itself over MCP: trigger a run,
  poll a document_job's status, and approve/reject a paused review — the
  same three actions available from the webhook endpoint and `ReviewLive`,
  now reachable by an agent instead of only a human in a browser or a
  webhook sender.

  A real, separate concern from `apps/tax_api`/`apps/sanctions_db`: those
  are external tools the agent *consults* during a run (so they stay
  genuinely separate OTP applications — see the architecture note in
  CLAUDE.md/CONTEXT.md). This server is the reverse direction — a new
  control-plane surface for *driving* the pipeline, the same category as
  `WebhookController` and `ReviewLive`. It therefore lives inside this app
  and calls `DocumentJobs`/`AgentRuns`'s public APIs directly, exactly like
  those do, rather than running as its own deployable — the whole reason
  the previous separate `agent_service` was collapsed into this app was to
  avoid exactly that HTTP hop for in-process control flow (see CONTEXT.md).
  It's mounted on the existing Phoenix endpoint (forwarded from the router
  at `/mcp`), not a second Bandit listener on its own port, for the same
  reason.

  Every handler here is a thin delegation to a context's public API, same
  discipline as a LiveView `handle_event` — no `Repo.*`, no business logic.

  Tax ID is deliberately never returned by any tool here — `get_document_job_status`
  omits it from `extracted_fields`/`extraction_metadata` even though the
  same data appears in `ReviewLive` for an authenticated human reviewer;
  an MCP response has a wider, less controlled audience (whatever calls
  this tool, and wherever it logs the result), so the same PII discipline
  that already keeps Tax ID off `extracted_fields`/`extraction_metadata`
  (see `Agent.Run.stringify_metadata/1`) is applied one step further here.
  """

  use Hermes.Server,
    name: "document-compliance-engine",
    version: "1.0.0",
    capabilities: [:tools]

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs
  alias Hermes.Server.Response

  @impl true
  def init(_client_info, frame) do
    frame =
      frame
      |> register_tool("trigger_run",
        input_schema: %{
          document_type_slug:
            {:required, :string, description: "e.g. \"vendor_contract_w9\" or \"invoice\""},
          documents:
            {:required, {:map, :string, :string},
             description:
               "Map of document role name to base64-encoded document bytes. Roles must " <>
                 "exactly match the document type's extraction_schema roles."},
          owner_email:
            {:required, :string,
             description:
               "Account this document_job belongs to — auto-provisioned if it's never " <>
                 "been seen before. Not itself authenticated by this tool call; this server " <>
                 "has no auth of its own, see CLAUDE.md."}
        },
        annotations: %{read_only: false},
        description:
          "Start a new document-compliance run. Stores the documents, enqueues extraction " <>
            "and validation, and returns immediately with a document_job_id — use " <>
            "get_document_job_status to poll for the outcome."
      )
      |> register_tool("get_document_job_status",
        input_schema: %{
          document_job_id: {:required, :integer, description: "id returned by trigger_run"}
        },
        annotations: %{read_only: true},
        description:
          "Poll a document_job's status: its aggregate status, the latest run's extracted " <>
            "fields and confidence/source-grounding metadata, the explanation if it's " <>
            "paused for human review, and the history of any review decisions."
      )
      |> register_tool("submit_review_decision",
        input_schema: %{
          document_job_id: {:required, :integer},
          decision: {:required, {:enum, ["approved", "rejected"]}},
          reviewer: {:required, :string, description: "Name or identifier of the reviewer"},
          rationale: {:required, :string, description: "Why this decision was made"}
        },
        annotations: %{read_only: false},
        description:
          "Approve or reject a document_job that's paused with status needs_review. " <>
            "Records an audit entry and resumes the agent run with the decision — only " <>
            "valid while the job's status is needs_review."
      )

    {:ok, frame}
  end

  @impl true
  def handle_tool_call(
        "trigger_run",
        %{document_type_slug: slug, documents: documents, owner_email: owner_email},
        frame
      ) do
    {:reply, trigger_run(slug, documents, owner_email), frame}
  end

  def handle_tool_call("get_document_job_status", %{document_job_id: id}, frame) do
    {:reply, get_document_job_status(id), frame}
  end

  def handle_tool_call(
        "submit_review_decision",
        %{document_job_id: id, decision: decision, reviewer: reviewer, rationale: rationale},
        frame
      ) do
    {:reply, submit_review_decision(id, decision, reviewer, rationale), frame}
  end

  defp trigger_run(document_type_slug, documents, owner_email) do
    payload =
      Jason.encode!(%{
        "document_type_slug" => document_type_slug,
        "documents" => documents,
        "owner_email" => owner_email
      })

    case DocumentJobs.ingest_webhook(payload) do
      {:ok, document_job} ->
        Response.json(Response.tool(), %{
          document_job_id: document_job.id,
          status: to_string(document_job.status)
        })

      {:error, :duplicate} ->
        Response.json(Response.tool(), %{status: "duplicate_ignored"})

      {:error, :invalid_payload} ->
        error(
          "invalid_payload: documents must be valid base64 and their roles must " <>
            "exactly match the document type's extraction_schema roles"
        )

      {:error, :unknown_document_type} ->
        error("unknown_document_type: #{document_type_slug}")

      {:error, %Ecto.Changeset{}} ->
        error("could not create document_job from the given input")
    end
  end

  defp get_document_job_status(document_job_id) do
    with {:ok, document_job} <- DocumentJobs.get_document_job(document_job_id) do
      Response.json(Response.tool(), %{
        document_job_id: document_job.id,
        document_type_slug: document_job.document_type_slug,
        status: to_string(document_job.status),
        run: run_payload(document_job_id),
        review_decisions: review_decisions_payload(document_job_id)
      })
    else
      {:error, :not_found} -> error("document_job #{document_job_id} not found")
    end
  end

  defp run_payload(document_job_id) do
    case AgentRuns.get_latest_for_document_job(document_job_id) do
      {:ok, run} ->
        %{
          status: to_string(run.status),
          thread_id: run.thread_id,
          explanation: run.explanation,
          extracted_fields: extracted_fields(run),
          extraction_metadata: redact_tax_id(run.extraction_metadata)
        }

      {:error, :not_found} ->
        nil
    end
  end

  # `vendor_contract_w9`'s fields live on AgentRun's own dedicated columns
  # (see `Agent.Run.extracted_payload/2`), not the generic `extracted_fields`
  # map — those columns don't exist for `extracted_fields` to already
  # contain them, so they're merged in here the same way `ReviewLive`
  # displays them. Tax ID is the one dedicated column deliberately excluded.
  defp extracted_fields(run) do
    run.extracted_fields
    |> redact_tax_id()
    |> merge_role("contract", %{
      "company_name" => run.company_name,
      "payment_terms" => run.payment_terms,
      "liability_clauses" => run.liability_clauses
    })
    |> merge_role("w9", %{"company_name" => run.w9_company_name})
  end

  defp merge_role(fields, role, dedicated_fields) do
    present = dedicated_fields |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    if present == %{},
      do: fields,
      else: Map.update(fields, role, present, &Map.merge(&1, present))
  end

  # Tax ID never leaves this server — see moduledoc. `extracted_fields`/
  # `extraction_metadata` are already generic per-role maps (no fixed
  # `w9`/`tax_id` keys guaranteed), so this is a blanket key-name filter
  # rather than a role-specific one.
  defp redact_tax_id(fields) do
    Map.new(fields, fn {role, role_fields} -> {role, Map.delete(role_fields, "tax_id")} end)
  end

  defp review_decisions_payload(document_job_id) do
    document_job_id
    |> AgentRuns.list_review_decisions()
    |> Enum.map(fn decision ->
      %{
        decision: to_string(decision.decision),
        reviewer: decision.reviewer,
        rationale: decision.rationale,
        inserted_at: DateTime.to_iso8601(decision.inserted_at)
      }
    end)
  end

  defp submit_review_decision(document_job_id, decision, reviewer, rationale) do
    case AgentRuns.resume_review(
           document_job_id,
           String.to_existing_atom(decision),
           reviewer,
           rationale
         ) do
      {:ok, document_job} ->
        Response.json(Response.tool(), %{
          document_job_id: document_job.id,
          status: "queued_for_resume"
        })

      {:error, :not_found} ->
        error("document_job #{document_job_id} not found")

      {:error, :not_awaiting_review} ->
        error("document_job #{document_job_id} is not currently awaiting review")

      {:error, _reason} ->
        error("could not record review decision")
    end
  end

  defp error(message), do: Response.error(Response.tool(), message)
end
