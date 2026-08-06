defmodule VendorOnboardingWeb.DashboardLive do
  use VendorOnboardingWeb, :live_view

  alias VendorOnboarding.Onboardings

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(VendorOnboarding.PubSub, "vendor_onboarding")
    end

    {:ok, assign(socket, onboardings: Onboardings.list_onboardings_with_latest_run())}
  end

  @impl true
  def handle_info({:status_updated, id}, socket) do
    {:noreply, update(socket, :onboardings, &reload_row(&1, id))}
  end

  defp reload_row(onboardings, id) do
    case Onboardings.reload_onboarding_row(id) do
      {:ok, updated} -> replace_or_prepend(onboardings, updated)
      {:error, :not_found} -> onboardings
    end
  end

  defp replace_or_prepend(onboardings, updated) do
    if Enum.any?(onboardings, &(&1.id == updated.id)) do
      Enum.map(onboardings, fn o -> if o.id == updated.id, do: updated, else: o end)
    else
      [updated | onboardings]
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Vendor Onboardings
        <:subtitle>Status updates arrive live via PubSub — no need to refresh.</:subtitle>
      </.header>

      <.table id="onboardings" rows={@onboardings}>
        <:col :let={onboarding} label="ID">{onboarding.id}</:col>
        <:col :let={onboarding} label="Status">
          <.status_badge status={onboarding.status} />
        </:col>
        <:col :let={onboarding} label="Company">{onboarding.company_name}</:col>
        <:col :let={onboarding} label="Updated">{onboarding.updated_at}</:col>
        <:action :let={onboarding}>
          <.link :if={onboarding.status == :needs_review} navigate={~p"/onboardings/#{onboarding.id}"}>
            Review
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
