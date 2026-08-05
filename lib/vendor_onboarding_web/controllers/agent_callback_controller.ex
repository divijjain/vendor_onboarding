defmodule VendorOnboardingWeb.AgentCallbackController do
  use VendorOnboardingWeb, :controller

  def create(conn, params) do
    case VendorOnboarding.handle_agent_callback(params) do
      {:ok, onboarding} ->
        conn
        |> put_status(:ok)
        |> json(%{id: onboarding.id, status: onboarding.status})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: VendorOnboardingWeb.ChangesetJSON.errors(changeset)})
    end
  end
end
