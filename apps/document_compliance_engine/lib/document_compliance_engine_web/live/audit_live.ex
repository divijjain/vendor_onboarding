defmodule DocumentComplianceEngineWeb.AuditLive do
  use DocumentComplianceEngineWeb, :live_view

  alias DocumentComplianceEngine.AgentRuns

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_audits(socket)}
  end

  defp assign_audits(socket) do
    organization_id = socket.assigns.current_user.organization_id

    assign(socket,
      pending_audits: AgentRuns.list_pending_audits(organization_id),
      reviewed_audits: AgentRuns.list_reviewed_audits(organization_id)
    )
  end

  @impl true
  def handle_event(
        "submit_audit",
        %{
          "audit_sample_id" => audit_sample_id,
          "decision" => decision,
          "reviewer" => reviewer,
          "notes" => notes
        },
        socket
      ) do
    case AgentRuns.record_audit_review(
           String.to_integer(audit_sample_id),
           socket.assigns.current_user.organization_id,
           String.to_existing_atom(decision),
           reviewer,
           notes
         ) do
      {:ok, _audit_sample} ->
        {:noreply,
         socket
         |> assign_audits()
         |> put_flash(:info, "Audit recorded.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not record audit: #{inspect(reason)}")}
    end
  end

  defp company_name(agent_run) do
    agent_run.company_name || agent_run.w9_company_name ||
      agent_run.extracted_fields
      |> Map.values()
      |> Enum.find_value(& &1["company_name"])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Audit queue
        <:subtitle>
          Post-hoc spot-check of runs the agent auto-approved with no human in the loop.
        </:subtitle>
      </.header>

      <div :if={@pending_audits == []} class="text-center py-12 opacity-60">
        <.icon name="hero-clipboard-document-check" class="size-10 mx-auto mb-2" />
        <p>No samples awaiting audit.</p>
        <p class="text-sm">
          A configured percentage of fully-automated approvals land here for review.
        </p>
      </div>

      <div :for={row <- @pending_audits} class="card bg-base-200 shadow mb-4">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title">
              {company_name(row.agent_run) || "Document job ##{row.document_job.id}"}
            </h2>
            <.link
              navigate={~p"/document_jobs/#{row.document_job.id}"}
              class="link link-primary text-sm"
            >
              View full run
            </.link>
          </div>
          <p class="text-sm opacity-70">
            Document type: {row.document_job.document_type_slug} — sampled {row.audit_sample.inserted_at}
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-2 text-sm">
            <p :if={row.agent_run.company_name}>
              <span class="font-semibold">Contract — company:</span> {row.agent_run.company_name}
            </p>
            <p :if={row.agent_run.w9_company_name}>
              <span class="font-semibold">W-9 — company:</span> {row.agent_run.w9_company_name}
            </p>
            <p :if={row.agent_run.payment_terms}>
              <span class="font-semibold">Payment terms:</span> {row.agent_run.payment_terms}
            </p>
            <div :for={{role, fields} <- row.agent_run.extracted_fields}>
              <p :for={{field, value} <- fields}>
                <span class="font-semibold capitalize">{role} — {field}:</span> {value}
              </p>
            </div>
          </div>

          <form
            id={"audit-form-#{row.audit_sample.id}"}
            phx-submit="submit_audit"
            class="flex flex-col gap-2 max-w-md mt-2"
          >
            <input type="hidden" name="audit_sample_id" value={row.audit_sample.id} />
            <.input
              type="text"
              name="reviewer"
              value=""
              label="Reviewer"
              placeholder="Your name"
              required
            />
            <.input
              type="textarea"
              name="notes"
              value=""
              label="Notes"
              placeholder="What did you check, and what did you find?"
            />
            <div class="flex gap-2">
              <.button name="decision" value="confirmed" variant="primary">
                Confirm — approval was correct
              </.button>
              <.button name="decision" value="discrepancy">
                Flag discrepancy
              </.button>
            </div>
          </form>
        </div>
      </div>

      <div :if={@reviewed_audits != []} class="mt-6">
        <h2 class="text-lg font-semibold mb-2">Recently audited</h2>
        <div :for={audit_sample <- @reviewed_audits} class="card bg-base-200 shadow mb-2">
          <div class="card-body py-3">
            <div class="flex items-center gap-2 text-sm">
              <.status_badge status={audit_sample.status} />
              <span class="opacity-70">document_job #{audit_sample.document_job_id}</span>
              <span class="opacity-70">by {audit_sample.reviewer}</span>
              <span class="opacity-50 text-xs">{audit_sample.reviewed_at}</span>
            </div>
            <p :if={audit_sample.notes} class="text-sm">{audit_sample.notes}</p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
