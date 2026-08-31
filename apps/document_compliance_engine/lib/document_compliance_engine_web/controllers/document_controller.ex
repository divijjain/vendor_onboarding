defmodule DocumentComplianceEngineWeb.DocumentController do
  @moduledoc """
  Serves a document_job's original stored bytes back to a signed-in
  reviewer, so `ReviewLive` can render the actual document instead of only
  the `PdfText` transcript of it.

  A controller rather than part of `ReviewLive` because LiveView can't send
  a binary response. That means the `live_session` `on_mount` hooks don't
  apply, so authentication comes from the `:require_authenticated_user`
  plug pipeline and *authorization* from the organization-scoped
  `DocumentJobs.get_document_job/2` — the same boundary `ReviewLive` uses.
  Scoping happens in the query, not as a check after an unscoped fetch, so
  another organization's id can't be probed: a wrong organization returns
  exactly the 404 a missing row does.
  """

  use DocumentComplianceEngineWeb, :controller

  alias DocumentComplianceEngine.DocumentJobs

  def show(conn, %{"id" => id, "role" => role}) do
    with {:ok, document_job} <-
           DocumentJobs.get_document_job(id, conn.assigns.current_user.organization_id),
         {:ok, {bytes, content_type}} <- DocumentJobs.read_raw_document(document_job, role) do
      send_document(conn, bytes, content_type, role)
    else
      _error -> not_found(conn)
    end
  end

  # Unrecognized bytes are served as a plain-text *attachment*, never
  # inline — an unsniffable blob rendered in the browser is an XSS shape,
  # and these bytes originate from a webhook payload.
  defp send_document(conn, bytes, :unknown, role) do
    conn
    |> put_resp_content_type("text/plain", nil)
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(role, "bin")}"))
    |> send_resp(200, bytes)
  end

  defp send_document(conn, bytes, content_type, role) do
    conn
    |> put_resp_content_type(content_type, nil)
    |> put_resp_header(
      "content-disposition",
      ~s(inline; filename="#{filename(role, extension(content_type))}")
    )
    |> send_resp(200, bytes)
  end

  # `role` is a `documents` map key from the webhook payload, so it's
  # caller-controlled and must not reach a response header unsanitized.
  defp filename(role, extension) do
    "#{String.replace(role, ~r/[^A-Za-z0-9_-]/, "_")}.#{extension}"
  end

  defp extension("application/pdf"), do: "pdf"
  defp extension("image/png"), do: "png"
  defp extension("image/jpeg"), do: "jpg"

  # Layouts are disabled deliberately — the `:browser` pipeline's root
  # layout expects a full page's assigns, and this is an error body.
  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_root_layout(html: false)
    |> put_layout(false)
    |> put_view(DocumentComplianceEngineWeb.ErrorHTML)
    |> render(:"404")
  end
end
