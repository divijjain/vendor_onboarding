defmodule DocumentComplianceEngineWeb.ReviewLive do
  use DocumentComplianceEngineWeb, :live_view

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    organization_id = socket.assigns.current_user.organization_id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        DocumentComplianceEngine.PubSub,
        AgentRuns.pubsub_topic(organization_id)
      )
    end

    {:ok, assign_document_job_and_run(socket, id)}
  end

  defp assign_document_job_and_run(socket, id) do
    document_job = DocumentJobs.get_document_job!(id, socket.assigns.current_user.organization_id)

    agent_run =
      case AgentRuns.get_latest_for_document_job(id) do
        {:ok, run} -> run
        {:error, :not_found} -> nil
      end

    assign(socket,
      document_job: document_job,
      agent_run: agent_run,
      documents: DocumentJobs.read_documents(document_job),
      review_decisions: AgentRuns.list_review_decisions(id)
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
  def handle_event(
        "submit_decision",
        %{"decision" => decision, "reviewer" => reviewer, "rationale" => rationale},
        socket
      ) do
    submit_decision(socket, String.to_existing_atom(decision), reviewer, rationale)
  end

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

  # Flattens `extraction_metadata` into displayable rows, dropping fields
  # with nothing to show (a shape-gate-skipped field has both confidence
  # and source_quote nil — genuinely not attempted, not worth a row).
  defp extraction_rows(extraction_metadata) do
    for {role, fields} <- extraction_metadata,
        {field, %{"confidence" => confidence, "source_quote" => source_quote}} <- fields,
        not is_nil(confidence) or source_quote not in [nil, ""] do
      %{role: role, field: field, confidence: confidence, source_quote: source_quote}
    end
  end

  # `:unknown` (unsniffable bytes) renders no viewer at all — the
  # transcript is all we can safely show for it.
  defp image?(content_type) when is_binary(content_type),
    do: String.starts_with?(content_type, "image/")

  defp image?(_content_type), do: false

  defp format_confidence(nil), do: "confidence n/a"
  defp format_confidence(confidence), do: "#{round(confidence * 100)}% confidence"

  defp confidence_class(confidence) when is_number(confidence) and confidence < 0.7,
    do: "text-error font-semibold"

  defp confidence_class(_confidence), do: "text-success"

  defp submit_decision(socket, decision, reviewer, rationale) do
    document_job_id = socket.assigns.document_job.id

    case AgentRuns.resume_review(document_job_id, decision, reviewer, rationale) do
      {:ok, _document_job} ->
        {:noreply,
         socket
         |> assign(review_decisions: AgentRuns.list_review_decisions(document_job_id))
         |> put_flash(:info, "Decision submitted — waiting for the agent to resume.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not submit decision: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Review DocumentJob #{@document_job.id}
        <:subtitle>
          <.status_badge status={@document_job.status} />
        </:subtitle>
      </.header>

      <div :if={@documents != []} class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div :for={doc <- @documents} class="card bg-base-200 shadow">
          <div class="card-body">
            <h2 class="card-title capitalize">{doc.role}</h2>

            <img
              :if={image?(doc.content_type)}
              src={~p"/document_jobs/#{@document_job.id}/documents/#{doc.role}"}
              alt={"Original #{doc.role} document"}
              class="max-w-full rounded border border-base-300"
            />

            <iframe
              :if={doc.content_type == "application/pdf"}
              src={~p"/document_jobs/#{@document_job.id}/documents/#{doc.role}"}
              title={"Original #{doc.role} document"}
              class="w-full h-96 rounded border border-base-300"
            ></iframe>

            <details>
              <summary class="cursor-pointer text-sm opacity-70">
                Extracted text (what the agent read)
              </summary>
              <pre class="whitespace-pre-wrap text-sm font-mono mt-2">{doc.text}</pre>
            </details>
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

      <div :if={@agent_run} class="mt-2">
        <% rows = extraction_rows(@agent_run.extraction_metadata) %>
        <div :if={rows != []}>
          <h2 class="text-lg font-semibold mb-2">Extraction confidence &amp; source grounding</h2>
          <div :for={row <- rows} class="text-sm mb-2">
            <span class="font-semibold capitalize">{row.role} — {row.field}:</span>
            <span class={confidence_class(row.confidence)}>{format_confidence(row.confidence)}</span>
            <p :if={row.source_quote && row.source_quote != ""} class="text-xs opacity-70 italic ml-2">
              "{row.source_quote}"
            </p>
          </div>
        </div>
      </div>

      <.list>
        <:item title="Agent's explanation">{@agent_run && @agent_run.explanation}</:item>
      </.list>

      <form
        :if={@document_job.status == :needs_review}
        id="review-decision-form"
        phx-submit="submit_decision"
        class="flex flex-col gap-2 max-w-md"
      >
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
          name="rationale"
          value=""
          label="Rationale"
          placeholder="Why are you approving or rejecting this?"
          required
        />
        <div class="flex gap-2">
          <.button name="decision" value="approved" variant="primary">Approve</.button>
          <.button name="decision" value="rejected">Reject</.button>
        </div>
      </form>

      <div :if={@document_job.status == :failed} class="flex gap-2">
        <.button phx-click="retry" variant="primary">Retry</.button>
      </div>

      <p
        :if={@document_job.status not in [:needs_review, :failed]}
        class="text-sm text-base-content/70"
      >
        This document job is no longer awaiting review.
      </p>

      <div :if={@review_decisions != []} class="mt-6">
        <h2 class="text-lg font-semibold mb-2">Review history</h2>
        <div :for={decision <- @review_decisions} class="card bg-base-200 shadow mb-2">
          <div class="card-body py-3">
            <div class="flex items-center gap-2 text-sm">
              <span class="font-semibold capitalize">{decision.decision}</span>
              <span class="opacity-70">by {decision.reviewer}</span>
              <span class="opacity-50 text-xs">{decision.inserted_at}</span>
            </div>
            <p class="text-sm"><span class="font-semibold">Rationale:</span> {decision.rationale}</p>
            <p :if={decision.evidence} class="text-sm opacity-70">
              <span class="font-semibold">Evidence at the time:</span> {decision.evidence}
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
