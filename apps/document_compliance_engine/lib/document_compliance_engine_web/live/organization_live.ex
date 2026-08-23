defmodule DocumentComplianceEngineWeb.OrganizationLive do
  use DocumentComplianceEngineWeb, :live_view

  alias DocumentComplianceEngine.Organizations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_organization(socket)}
  end

  defp assign_organization(socket) do
    organization_id = socket.assigns.current_user.organization_id

    assign(socket,
      organization: Organizations.get_organization(organization_id) |> unwrap(),
      members: Organizations.list_members(organization_id),
      pending_invitations: Organizations.list_pending_invitations(organization_id)
    )
  end

  defp unwrap({:ok, organization}), do: organization

  @impl true
  def handle_event("invite", %{"email" => email}, socket) do
    case Organizations.invite_member(socket.assigns.current_user, email) do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> assign_organization()
         |> put_flash(
           :info,
           "Invited #{email} — tell them to sign in with Google using that address."
         )}

      {:error, :already_in_an_organization} ->
        {:noreply, put_flash(socket, :error, "#{email} already belongs to an organization.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not send invite: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        {@organization.name}
        <:subtitle>Every member of this organization sees the same document_jobs.</:subtitle>
      </.header>

      <div class="card bg-base-200 shadow">
        <div class="card-body">
          <h2 class="card-title">Invite a teammate</h2>
          <p class="text-sm opacity-70">
            Creates the invite — no email is sent. Tell them to sign in with Google using that
            exact address, and they'll join automatically.
          </p>
          <form id="invite-member-form" phx-submit="invite" class="flex gap-2 items-end max-w-md">
            <.input
              type="email"
              name="email"
              value=""
              label="Email"
              placeholder="teammate@example.com"
              required
            />
            <.button variant="primary" phx-disable-with="Inviting...">Invite</.button>
          </form>
        </div>
      </div>

      <div class="mt-6">
        <h2 class="text-lg font-semibold mb-2">Members</h2>
        <.table id="members" rows={@members} row_id={&"member-#{&1.id}"}>
          <:col :let={member} label="Email">{member.email}</:col>
          <:col :let={member} label="Name">{member.name}</:col>
          <:col :let={member} label="Joined">{member.inserted_at}</:col>
        </.table>
      </div>

      <div :if={@pending_invitations != []} class="mt-6">
        <h2 class="text-lg font-semibold mb-2">Pending invites</h2>
        <.table id="pending-invitations" rows={@pending_invitations} row_id={&"invitation-#{&1.id}"}>
          <:col :let={invitation} label="Email">{invitation.email}</:col>
          <:col :let={invitation} label="Invited">{invitation.inserted_at}</:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end
end
