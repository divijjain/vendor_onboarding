defmodule DocumentComplianceEngineWeb.CreateOrganizationLive do
  use DocumentComplianceEngineWeb, :live_view

  alias DocumentComplianceEngine.Organizations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, name: "")}
  end

  @impl true
  def handle_event("create", %{"name" => name}, socket) do
    case Organizations.create_organization(socket.assigns.current_user, name) do
      {:ok, _organization} ->
        # A full redirect, not push_navigate/2 — /document_jobs lives in a
        # different live_session (:require_authenticated_user vs. this
        # page's :require_no_organization), and redirect/2 is guaranteed
        # to force a real reconnect across that boundary.
        {:noreply,
         socket
         |> put_flash(:info, "Organization created.")
         |> redirect(to: ~p"/document_jobs")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create organization: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Create your organization
        <:subtitle>
          You'll be its first member — invite teammates once it's set up.
        </:subtitle>
      </.header>

      <form id="create-organization-form" phx-submit="create" class="flex flex-col gap-2 max-w-md">
        <.input
          type="text"
          name="name"
          value={@name}
          label="Organization name"
          placeholder="Acme Corp"
          required
        />
        <.button variant="primary" phx-disable-with="Creating..." class="mt-2">
          Create organization
        </.button>
      </form>
    </Layouts.app>
    """
  end
end
