defmodule VendorOnboardingWeb.AgentCallbackController do
  use VendorOnboardingWeb, :controller

  def create(conn, params) do
    case VendorOnboarding.AgentRuns.handle_agent_callback(params) do
      {:ok, agent_run} ->
        conn
        |> put_status(:ok)
        |> json(%{onboarding_id: agent_run.vendor_onboarding_id, status: agent_run.status})

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
