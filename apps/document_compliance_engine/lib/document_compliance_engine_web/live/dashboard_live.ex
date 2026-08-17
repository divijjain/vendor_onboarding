defmodule DocumentComplianceEngineWeb.DashboardLive do
  use DocumentComplianceEngineWeb, :live_view

  alias DocumentComplianceEngine.{DocumentJobs, DocumentTypes, SystemHealth}

  @health_refresh_interval :timer.seconds(5)

  # Which document type each upload role belongs to, and its label — the
  # dashboard's manual-test upload only knows about the two document types
  # that exist today. Mirrors the same "known roles get dedicated handling,
  # nothing generic" tradeoff `Agent.Run.@known_roles` already makes; full
  # N-document-type upload genericity is out of scope for a manual-test tool.
  @upload_roles [
    {:contract, "vendor_contract_w9", "Contract document"},
    {:w9, "vendor_contract_w9", "W-9 document"},
    {:invoice, "invoice", "Invoice document"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DocumentComplianceEngine.PubSub, "document_compliance_engine")
      schedule_health_refresh()
    end

    socket =
      Enum.reduce(@upload_roles, socket, fn {ref, _slug, _label}, socket ->
        # .pdf is real now (PdfText runs it through pdftotext before
        # extraction — see CONTEXT.md) — text-layer PDFs only, no OCR yet
        # for a scanned/image-only PDF, still a documented, separate gap.
        allow_upload(socket, ref, accept: ~w(.txt .pdf), max_entries: 1)
      end)

    {:ok,
     socket
     |> assign(document_types: DocumentTypes.list_document_types(), selected_document_type: nil)
     |> assign(document_jobs: DocumentJobs.list_document_jobs_with_latest_run())
     |> assign(health: SystemHealth.snapshot())
     |> assign(upload_document_type: nil)}
  end

  @impl true
  def handle_info({:status_updated, id}, socket) do
    {:noreply, update(socket, :document_jobs, &reload_row(&1, id))}
  end

  @impl true
  def handle_info(:refresh_health, socket) do
    schedule_health_refresh()
    {:noreply, assign(socket, health: SystemHealth.snapshot())}
  end

  defp schedule_health_refresh do
    Process.send_after(self(), :refresh_health, @health_refresh_interval)
  end

  @impl true
  def handle_event("filter", %{"document_type_slug" => slug}, socket) do
    selected = if slug == "", do: nil, else: slug

    {:noreply,
     socket
     |> assign(selected_document_type: selected)
     |> assign(
       document_jobs:
         DocumentJobs.list_document_jobs_with_latest_run(document_type_slug: selected)
     )}
  end

  @impl true
  def handle_event("upload_type_change", %{"document_type_slug" => slug}, socket) do
    {:noreply, assign(socket, upload_document_type: presence(slug))}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref, "role" => role}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(role), ref)}
  end

  @impl true
  def handle_event("submit_upload", _params, socket) do
    {:noreply, submit_upload(socket)}
  end

  defp submit_upload(socket) do
    slug = socket.assigns.upload_document_type
    roles = roles_for(slug)

    case consume_documents(socket, roles) do
      {:ok, documents} ->
        %{"document_type_slug" => slug, "documents" => documents}
        |> Jason.encode!()
        |> DocumentJobs.ingest_webhook()
        |> handle_ingest_result(socket)

      :missing_files ->
        put_flash(
          socket,
          :error,
          "Select a document type and a file for every required document."
        )
    end
  end

  defp consume_documents(_socket, []), do: :missing_files

  defp consume_documents(socket, roles) do
    documents =
      Map.new(roles, fn {ref, _label} ->
        bytes =
          consume_uploaded_entries(socket, ref, fn %{path: path}, _entry ->
            {:ok, File.read!(path)}
          end)

        {Atom.to_string(ref), List.first(bytes)}
      end)

    if Enum.any?(documents, fn {_role, bytes} -> is_nil(bytes) end) do
      :missing_files
    else
      {:ok, Map.new(documents, fn {role, bytes} -> {role, Base.encode64(bytes)} end)}
    end
  end

  defp handle_ingest_result({:ok, document_job}, socket) do
    socket
    |> update(:document_jobs, &reload_row(&1, document_job.id))
    |> assign(upload_document_type: nil)
    |> put_flash(:info, "Document job ##{document_job.id} submitted.")
  end

  defp handle_ingest_result({:error, :duplicate}, socket) do
    put_flash(
      socket,
      :error,
      "Duplicate upload -- identical to a previously submitted document job."
    )
  end

  defp handle_ingest_result({:error, reason}, socket) do
    put_flash(socket, :error, "Could not process upload: #{inspect(reason)}")
  end

  defp roles_for(nil), do: []

  defp roles_for(slug) do
    for {ref, ^slug, label} <- @upload_roles, do: {ref, label}
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  @upload_slugs @upload_roles |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  defp upload_type_options(document_types) do
    document_types
    |> Enum.filter(&(&1.slug in @upload_slugs))
    |> Enum.map(&{&1.name, &1.slug})
  end

  defp upload_error_message(:too_large), do: "File is too large"
  defp upload_error_message(:not_accepted), do: "Only .txt or .pdf files are accepted"
  defp upload_error_message(:too_many_files), do: "Only one file allowed"
  defp upload_error_message(other), do: to_string(other)

  defp reload_row(document_jobs, id) do
    case DocumentJobs.reload_document_job_row(id) do
      {:ok, updated} -> replace_or_prepend(document_jobs, updated)
      {:error, :not_found} -> document_jobs
    end
  end

  defp replace_or_prepend(document_jobs, updated) do
    if Enum.any?(document_jobs, &(&1.id == updated.id)) do
      Enum.map(document_jobs, fn o -> if o.id == updated.id, do: updated, else: o end)
    else
      [updated | document_jobs]
    end
  end

  defp status_counts(document_jobs) do
    Enum.frequencies_by(document_jobs, & &1.status)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :counts, status_counts(assigns.document_jobs))

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Document Jobs
        <:subtitle>Updates automatically as documents move through review.</:subtitle>
      </.header>

      <div class="stats shadow w-full">
        <div class="stat">
          <div class="stat-title">Total</div>
          <div class="stat-value text-2xl">{length(@document_jobs)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Needs review</div>
          <div class="stat-value text-2xl text-warning">{@counts[:needs_review] || 0}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Approved</div>
          <div class="stat-value text-2xl text-success">{@counts[:approved] || 0}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Needs attention</div>
          <div class="stat-value text-2xl text-error">
            {(@counts[:rejected] || 0) + (@counts[:failed] || 0)}
          </div>
        </div>
      </div>

      <div class="card bg-base-200 shadow">
        <div class="card-body">
          <h2 class="card-title">Submit a document</h2>
          <p class="text-sm opacity-70">
            Upload a document to run it through the compliance pipeline. .txt or .pdf (text-layer PDFs only — no OCR for scanned documents yet).
          </p>
          <form id="manual-upload-form" phx-change="upload_type_change" phx-submit="submit_upload">
            <.input
              type="select"
              name="document_type_slug"
              value={@upload_document_type}
              prompt="Choose a document type"
              options={upload_type_options(@document_types)}
            />

            <div :for={{ref, label} <- roles_for(@upload_document_type)} class="mt-3">
              <label class="label">{label}</label>
              <.live_file_input upload={@uploads[ref]} />
              <div :for={entry <- @uploads[ref].entries} class="flex items-center gap-2 text-sm mt-1">
                {entry.client_name}
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  phx-value-role={ref}
                  class="btn btn-xs btn-ghost"
                >
                  Remove
                </button>
              </div>
              <p :for={err <- upload_errors(@uploads[ref])} class="text-error text-sm mt-1">
                {upload_error_message(err)}
              </p>
            </div>

            <.button :if={@upload_document_type} phx-disable-with="Submitting..." class="mt-4">
              Submit document
            </.button>
          </form>
        </div>
      </div>

      <div class="flex items-center justify-between mt-4">
        <h2 class="text-lg font-semibold">Documents</h2>
        <form id="document-type-filter" phx-change="filter">
          <.input
            type="select"
            name="document_type_slug"
            value={@selected_document_type}
            prompt="All document types"
            options={Enum.map(@document_types, &{&1.name, &1.slug})}
          />
        </form>
      </div>

      <div :if={@document_jobs == []} class="text-center py-12 opacity-60">
        <p>No documents yet.</p>
        <p class="text-sm">Submit one above to see it move through the pipeline.</p>
      </div>

      <.table
        :if={@document_jobs != []}
        id="document_jobs"
        rows={@document_jobs}
        row_id={&"document_jobs-#{&1.id}"}
      >
        <:col :let={document_job} label="Company">{document_job.company_name}</:col>
        <:col :let={document_job} label="Document type">{document_job.document_type_slug}</:col>
        <:col :let={document_job} label="Status">
          <.status_badge status={document_job.status} />
        </:col>
        <:col :let={document_job} label="Updated">{document_job.updated_at}</:col>
        <:col :let={document_job} label="Ref">
          <span class="text-xs opacity-50">#{document_job.id}</span>
        </:col>
        <:action :let={document_job}>
          <.link navigate={~p"/document_jobs/#{document_job.id}"} class="link link-primary">
            {if document_job.status == :needs_review, do: "Review", else: "View"}
          </.link>
        </:action>
      </.table>

      <details class="collapse collapse-arrow bg-base-200 border border-base-300 mt-8">
        <summary class="collapse-title text-sm font-medium opacity-70">System status</summary>
        <div class="collapse-content">
          <div id="system-health" class="stats stats-vertical sm:stats-horizontal shadow mt-2">
            <div class="stat">
              <div class="stat-title">BEAM processes</div>
              <div class="stat-value text-lg">{@health.beam_process_count}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Oban queue depth</div>
              <div class="stat-value text-lg">{@health.oban_queue_depth}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Active agent runs</div>
              <div class="stat-value text-lg">{@health.active_agent_runs}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Tax API MCP</div>
              <div class="stat-value text-lg">
                <.mcp_status_badge status={@health.tax_api_status} />
              </div>
            </div>
            <div class="stat">
              <div class="stat-title">Sanctions DB MCP</div>
              <div class="stat-value text-lg">
                <.mcp_status_badge status={@health.sanctions_db_status} />
              </div>
            </div>
          </div>
        </div>
      </details>
    </Layouts.app>
    """
  end
end
