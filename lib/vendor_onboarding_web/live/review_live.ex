defmodule VendorOnboardingWeb.ReviewLive do
  use VendorOnboardingWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(VendorOnboarding.PubSub, "vendor_onboarding")
    end

    {:ok, assign(socket, onboarding: VendorOnboarding.get_onboarding!(id))}
  end

  @impl true
  def handle_info({:status_updated, id}, socket) do
    {:noreply, maybe_reload(socket, id)}
  end

  defp maybe_reload(socket, id) do
    if socket.assigns.onboarding.id == id do
      assign(socket, onboarding: VendorOnboarding.get_onboarding!(id))
    else
      socket
    end
  end

  @impl true
  def handle_event("approve", _params, socket), do: submit_decision(socket, :approved)

  @impl true
  def handle_event("reject", _params, socket), do: submit_decision(socket, :rejected)

  defp submit_decision(socket, decision) do
    onboarding_id = socket.assigns.onboarding.id

    case VendorOnboarding.resume_review(onboarding_id, decision) do
      {:ok, _onboarding} ->
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
        Review Onboarding #{@onboarding.id}
        <:subtitle>
          <.status_badge status={@onboarding.status} />
        </:subtitle>
      </.header>

      <div class="grid grid-cols-2 gap-4">
        <.list>
          <:item title="Contract — company name">{@onboarding.company_name}</:item>
          <:item title="Contract — payment terms">{@onboarding.payment_terms}</:item>
          <:item title="Contract — liability clauses">{@onboarding.liability_clauses}</:item>
        </.list>
        <.list>
          <:item title="W-9 — company name">{@onboarding.w9_company_name}</:item>
          <:item title="W-9 — Tax ID">{@onboarding.tax_id}</:item>
        </.list>
      </div>

      <.list>
        <:item title="Agent's explanation">{@onboarding.explanation}</:item>
      </.list>

      <div :if={@onboarding.status == :needs_review} class="flex gap-2">
        <.button phx-click="approve" variant="primary">Approve</.button>
        <.button phx-click="reject">Reject</.button>
      </div>

      <p :if={@onboarding.status != :needs_review} class="text-sm text-base-content/70">
        This onboarding is no longer awaiting review.
      </p>
    </Layouts.app>
    """
  end
end
