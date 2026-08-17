defmodule DocumentComplianceEngineWeb.ReviewLive do
  use DocumentComplianceEngineWeb, :live_view

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DocumentComplianceEngine.PubSub, "document_compliance_engine")
    end

    {:ok, assign_document_job_and_run(socket, id)}
  end

  defp assign_document_job_and_run(socket, id) do
    document_job = DocumentJobs.get_document_job!(id)

    agent_run =
      case AgentRuns.get_latest_for_document_job(id) do
        {:ok, run} -> run
        {:error, :not_found} -> nil
      end

    assign(socket,
      document_job: document_job,
      agent_run: agent_run,
      documents: DocumentJobs.read_documents(document_job)
    )
  end

  @impl true
  def handle_info({:status_updated, id}, socket) do
    {:noreply, maybe_reload(socket, id)}
  end

  defp maybe_reload(socket, id) do
    if socket.assigns.document_job.id == id do
      assign_document_job_and_run(socket, id)
    else
      socket
    end
  end

  @impl true
  def handle_event("approve", _params, socket), do: submit_decision(socket, :approved)

  @impl true
  def handle_event("reject", _params, socket), do: submit_decision(socket, :rejected)

  @impl true
  def handle_event("retry", _params, socket) do
    # Same `enqueue_trigger/1` the original webhook ingest uses — the
    # stored documents and document_type_slug are already on the
    # document_job row, so a retry is just running the pipeline again
    # against them, not a new ingestion.
    case AgentRuns.enqueue_trigger(socket.assigns.document_job.id) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Retry queued — the agent will run again shortly.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue retry: #{inspect(reason)}")}
    end
  end

  defp submit_decision(socket, decision) do
    document_job_id = socket.assigns.document_job.id

    case AgentRuns.resume_review(document_job_id, decision) do
      {:ok, _document_job} ->
        {:noreply,
         put_flash(socket, :info, "Decision submitted — waiting for the agent to resume.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not submit decision: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Review DocumentJob #{@document_job.id}
        <:subtitle>
          <.status_badge status={@document_job.status} />
        </:subtitle>
      </.header>

      <div :if={@documents != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div :for={{role, text} <- @documents} class="card bg-base-200 shadow">
          <div class="card-body">
            <h2 class="card-title capitalize">{role}</h2>
            <pre class="whitespace-pre-wrap text-sm font-mono">{text}</pre>
          </div>
        </div>
      </div>

      <div
        :if={@agent_run && (@agent_run.company_name || @agent_run.w9_company_name)}
        class="grid grid-cols-2 gap-4"
      >
        <.list>
          <:item title="Contract — company name">{@agent_run.company_name}</:item>
          <:item title="Contract — payment terms">{@agent_run.payment_terms}</:item>
          <:item title="Contract — liability clauses">
            {@agent_run.liability_clauses}
          </:item>
        </.list>
        <.list>
          <:item title="W-9 — company name">{@agent_run.w9_company_name}</:item>
          <:item title="W-9 — Tax ID">{@agent_run.tax_id}</:item>
        </.list>
      </div>

      <div :if={@agent_run && @agent_run.extracted_fields != %{}}>
        <.list :for={{role, fields} <- @agent_run.extracted_fields}>
          <:item :for={{field, value} <- fields} title={"#{role} — #{field}"}>{value}</:item>
        </.list>
      </div>

      <.list>
        <:item title="Agent's explanation">{@agent_run && @agent_run.explanation}</:item>
      </.list>

      <div :if={@document_job.status == :needs_review} class="flex gap-2">
        <.button phx-click="approve" variant="primary">Approve</.button>
        <.button phx-click="reject">Reject</.button>
      </div>

      <div :if={@document_job.status == :failed} class="flex gap-2">
        <.button phx-click="retry" variant="primary">Retry</.button>
      </div>

      <p
        :if={@document_job.status not in [:needs_review, :failed]}
        class="text-sm text-base-content/70"
      >
        This document job is no longer awaiting review.
      </p>
    </Layouts.app>
    """
  end
end
