defmodule VendorOnboardingWeb.WebhookController do
  use VendorOnboardingWeb, :controller

  def create(conn, _params) do
    case VendorOnboarding.DocumentJobs.ingest_webhook(conn.assigns.raw_body) do
      {:ok, document_job} ->
        conn
        |> put_status(:created)
        |> json(%{id: document_job.id, status: document_job.status})

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
