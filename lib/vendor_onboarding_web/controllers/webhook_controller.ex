defmodule VendorOnboardingWeb.WebhookController do
  use VendorOnboardingWeb, :controller

  def create(conn, _params) do
    case VendorOnboarding.Onboardings.ingest_webhook(conn.assigns.raw_body) do
      {:ok, onboarding} ->
        conn
        |> put_status(:created)
        |> json(%{id: onboarding.id, status: onboarding.status})

      {:error, :duplicate} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "duplicate_ignored"})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_payload"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: VendorOnboardingWeb.ChangesetJSON.errors(changeset)})
    end
  end
end
