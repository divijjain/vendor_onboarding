defmodule VendorOnboardingWeb.ReviewLive do
  use VendorOnboardingWeb, :live_view

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.Onboardings

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(VendorOnboarding.PubSub, "vendor_onboarding")
    end

    {:ok, assign_onboarding_and_run(socket, id)}
  end

  defp assign_onboarding_and_run(socket, id) do
    onboarding = Onboardings.get_onboarding!(id)

    agent_run =
      case AgentRuns.get_latest_for_onboarding(id) do
        {:ok, run} -> run
        {:error, :not_found} -> nil
      end

    assign(socket, onboarding: onboarding, agent_run: agent_run)
  end

  @impl true
  def handle_info({:status_updated, id}, socket) do
    {:noreply, maybe_reload(socket, id)}
  end

  defp maybe_reload(socket, id) do
    if socket.assigns.onboarding.id == id do
      assign_onboarding_and_run(socket, id)
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

    case AgentRuns.resume_review(onboarding_id, decision) do
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
          <:item title="Contract — company name">{@agent_run && @agent_run.company_name}</:item>
          <:item title="Contract — payment terms">{@agent_run && @agent_run.payment_terms}</:item>
          <:item title="Contract — liability clauses">
            {@agent_run && @agent_run.liability_clauses}
          </:item>
        </.list>
        <.list>
          <:item title="W-9 — company name">{@agent_run && @agent_run.w9_company_name}</:item>
          <:item title="W-9 — Tax ID">{@agent_run && @agent_run.tax_id}</:item>
        </.list>
      </div>

      <.list>
        <:item title="Agent's explanation">{@agent_run && @agent_run.explanation}</:item>
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
