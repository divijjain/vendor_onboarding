defmodule VendorOnboardingWeb.DashboardLive do
  use VendorOnboardingWeb, :live_view

  alias VendorOnboarding.{DocumentJobs, DocumentTypes, SystemHealth}

  @health_refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(VendorOnboarding.PubSub, "vendor_onboarding")
      schedule_health_refresh()
    end

    {:ok,
     socket
     |> assign(document_types: DocumentTypes.list_document_types(), selected_document_type: nil)
     |> assign(document_jobs: DocumentJobs.list_document_jobs_with_latest_run())
     |> assign(health: SystemHealth.snapshot())}
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Document Jobs
        <:subtitle>Status updates arrive live via PubSub — no need to refresh.</:subtitle>
      </.header>

      <div id="system-health" class="stats shadow mb-4">
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
          <div class="stat-value text-lg"><.mcp_status_badge status={@health.tax_api_status} /></div>
        </div>
        <div class="stat">
          <div class="stat-title">Sanctions DB MCP</div>
          <div class="stat-value text-lg">
            <.mcp_status_badge status={@health.sanctions_db_status} />
          </div>
        </div>
      </div>

      <form id="document-type-filter" phx-change="filter">
        <.input
          type="select"
          name="document_type_slug"
          value={@selected_document_type}
          prompt="All document types"
          options={Enum.map(@document_types, &{&1.name, &1.slug})}
        />
      </form>

      <.table id="document_jobs" rows={@document_jobs} row_id={&"document_jobs-#{&1.id}"}>
        <:col :let={document_job} label="ID">{document_job.id}</:col>
        <:col :let={document_job} label="Status">
          <.status_badge status={document_job.status} />
        </:col>
        <:col :let={document_job} label="Document type">{document_job.document_type_slug}</:col>
        <:col :let={document_job} label="Company">{document_job.company_name}</:col>
        <:col :let={document_job} label="Updated">{document_job.updated_at}</:col>
        <:action :let={document_job}>
          <.link
            :if={document_job.status == :needs_review}
            navigate={~p"/document_jobs/#{document_job.id}"}
          >
            Review
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
